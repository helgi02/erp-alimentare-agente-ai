unit uEmailToolProvider;

(* ============================================================================
  TEmailToolProvider - tool MCP per le email. Provider generico: non sa nulla
  di clienti, lotti o richiami; riceve indirizzi e contenuti gia' decisi da
  altri (l'utente, il modello, un altro tool) e li spedisce.

  -- I tre tool --------------------------------------------------------------
  1. invia_email (SCRITTURA con conferma)
     Email LIBERA: oggetto e testo li scrive il modello. Un solo messaggio,
     tutti i destinatari nel campo "A".
  2. anteprima_email_da_modello (lettura)
     Email a TESTO FISSO: compone, senza inviare, una email per ogni elemento
     di "messaggi" a partire da un modello della tabella modelli_email
     (services/uServiziModelliEmail.pas) e restituisce le bozze.
  3. invia_email_da_modello (SCRITTURA con conferma)
     Come il 2, ma invia: una email SEPARATA per ogni elemento (un
     destinatario non vede gli altri).

  -- Perche' due strade: libera e da modello ---------------------------------
  Il testo libero va bene per un messaggio occasionale che l'utente rilegge.
  Per le comunicazioni ufficiali (ritiro/richiamo) si e' scelto il testo
  fisso: e' deterministico (stessa situazione = stesso testo), si modifica
  nel database senza ricompilare ed e' classificato per categoria. Li' il
  modello di linguaggio non scrive nulla: decide solo QUANDO chiamare i tool.

  -- Come arrivano i "messaggi" ----------------------------------------------
  Ogni elemento e' {"email", "modello", "variabili"}: a chi, con quale
  modello, con quali valori per i segnaposto. Di norma non li scrive il
  modello di linguaggio: li prepara un tool di dominio e il piano li passa
  per riferimento, es.
      "messaggi": "$1.comunicazioni"
  (da trova_ordini_spedizioni_lotto_prodotto_finito). E' quel tool a
  sapere quale modello tocca a quale cliente; qui si compone e si spedisce.

  -- Correzioni dell'utente sull'anteprima ------------------------------------
  Nella chat le bozze dell'anteprima sono MODIFICABILI. Le email corrette a
  mano non ripassano da qui (invia_email_da_modello le ricomporrebbe dal
  modello, perdendo le correzioni): il pulsante "Invia" del modulo chiama
  direttamente POST /api/email/invio (controllers/uControllerEmail.pas).
  invia_email_da_modello resta per l'invio chiesto a parole, senza modifiche.

  -- Anteprima e invio danno lo stesso testo ---------------------------------
  Entrambi passano da ComponiMessaggi: stessi messaggi + stesso modello =
  stesso testo. Non serve salvare le bozze fra l'anteprima e l'invio.

  -- Scritture con conferma --------------------------------------------------
  I due tool di invio non scrivono nel database, ma hanno un effetto che non
  si annulla e che esce dall'azienda: nel contratto sono etScrittura con
  conferma, e il pianificatore si ferma prima di eseguirli.

  -- Provider "dinamico" -----------------------------------------------------
  "destinatari" e "messaggi" sono array veri: GetDynamicToolDefs +
  InvokeDynamic, come TRitiroRichiamoToolProvider e TFilesToolsProvider.

  L'invio vero e' in services/Service.EmailServer.pas (TEmailServer), la
  configurazione nella sezione [SMTP] dell'ini (TConfig.SMTP).
  ============================================================================ *)

interface

uses
  System.SysUtils,
  System.Generics.Collections,
  JsonDataObjects,
  MVCFramework.MCP.ToolProvider,
  uContrattiTool,
  uServiziModelliEmail,
  Service.EmailServer;

type
  TEmailToolProvider = class(TMCPToolProvider)
  public
    function GetDynamicToolDefs: TArray<TMCPDynamicToolDef>; override;
    function InvokeDynamic(const AToolName: string;
      AArguments: TJDOJsonObject): TMCPToolResult; override;
    // Contratti dei tool per il pianificatore (vedi agente_ai/tool/
    // uContrattiTool.pas e la sezione in fondo a questa unit).
    class function ContrattiTool: TArray<TContrattoTool>;
  end;

implementation

const
  TOOL_INVIA_EMAIL = 'invia_email';
  TOOL_ANTEPRIMA_DA_MODELLO = 'anteprima_email_da_modello';
  TOOL_INVIA_DA_MODELLO = 'invia_email_da_modello';

  // Tetti prudenziali: una sola conferma non deve poter far partire
  // centinaia di email.
  MAX_DESTINATARI = 50;
  MAX_MESSAGGI = 100;

type
  // Un messaggio da modello gia' composto, pronto per anteprima o invio.
  TMessaggioComposto = record
    Email: string;
    Modello: string;
    Categoria: string;
    Composta: TEmailComposta;
  end;

{ Funzioni di supporto, private all'unit }

// Legge "destinatari" (invia_email): array di indirizzi, almeno uno. Toglie
// i doppioni (senza distinguere maiuscole/minuscole). Solleva un'eccezione
// con un messaggio leggibile dal modello se qualcosa non va.
//
// Tolleranza: se arriva una STRINGA invece di un array (errore frequente
// dei modelli piccoli con un solo destinatario) la si accetta, anche con piu'
// indirizzi separati da virgola o punto e virgola.
function LeggiDestinatari(AArguments: TJDOJsonObject): TArray<string>;
var
  LGrezzi, LPuliti: TArray<string>;
  LArray: TJDOJsonArray;
  LIndirizzo, LGiaPresente: string;
  LDoppione: Boolean;
  I: Integer;
begin
  if not AArguments.Contains('destinatari') then
    raise Exception.Create('Parametro "destinatari" mancante: serve un array con almeno un indirizzo email.');

  case AArguments.Types['destinatari'] of
    jdtArray:
      begin
        LArray := AArguments.A['destinatari'];
        SetLength(LGrezzi, LArray.Count);
        for I := 0 to LArray.Count - 1 do
        begin
          if LArray.Types[I] <> jdtString then
            raise Exception.CreateFmt(
              'Elemento %d di "destinatari" non e'' una stringa: atteso un indirizzo email.', [I]);
          LGrezzi[I] := LArray.S[I];
        end;
      end;
    jdtString:
      LGrezzi := AArguments.S['destinatari'].Split([',', ';']);
  else
    raise Exception.Create('"destinatari" deve essere un array di indirizzi email.');
  end;

  LPuliti := [];
  for I := 0 to High(LGrezzi) do
  begin
    LIndirizzo := Trim(LGrezzi[I]);
    if LIndirizzo = '' then
      Continue;
    if not TEmailServer.IndirizzoValido(LIndirizzo) then
      raise Exception.CreateFmt(
        '"%s" non e'' un indirizzo email valido. In "destinatari" vanno solo indirizzi ' +
        '(es. nome@dominio.it), non nomi o id: l''indirizzo di un cliente e'' nel campo ' +
        '"email" restituito da get_cliente.', [LIndirizzo]);

    LDoppione := False;
    for LGiaPresente in LPuliti do
      if SameText(LGiaPresente, LIndirizzo) then
        LDoppione := True;
    if not LDoppione then
      LPuliti := LPuliti + [LIndirizzo];
  end;

  if Length(LPuliti) = 0 then
    raise Exception.Create('"destinatari" e'' vuoto: serve almeno un indirizzo email.');
  if Length(LPuliti) > MAX_DESTINATARI then
    raise Exception.CreateFmt(
      'Troppi destinatari (%d): al massimo %d per messaggio.', [Length(LPuliti), MAX_DESTINATARI]);

  Result := LPuliti;
end;

// Legge "messaggi" e compone OGNI email dal suo modello. Regola "tutto o
// niente": al primo messaggio che non si puo' comporre (indirizzo non
// valido, modello inesistente, valore mancante) solleva un'eccezione, e il
// chiamante non invia nulla. Meglio nessuna email che meta' dei clienti
// avvisati e l'altra meta' no senza che l'utente lo abbia deciso.
function ComponiMessaggi(AArguments: TJDOJsonObject): TArray<TMessaggioComposto>;
var
  LArray: TJDOJsonArray;
  LElemento, LVariabiliJSON: TJDOJsonObject;
  LVariabili: TDictionary<string, string>;
  LModelli: TDictionary<string, TModelloEmail>;   // letti una volta per codice
  LModello: TModelloEmail;
  LCodice, LErrore: string;
  I, J: Integer;
begin
  if not (AArguments.Contains('messaggi') and (AArguments.Types['messaggi'] = jdtArray)) then
    raise Exception.Create(
      'Parametro "messaggi" mancante o non valido: deve essere un array di oggetti ' +
      '{"email","modello","variabili"}, di norma preso dal risultato di un altro tool ' +
      '(es. "comunicazioni" di trova_ordini_spedizioni_lotto_prodotto_finito).');

  LArray := AArguments.A['messaggi'];
  if LArray.Count = 0 then
    raise Exception.Create('"messaggi" e'' vuoto: non c''e'' nessuna email da comporre.');
  if LArray.Count > MAX_MESSAGGI then
    raise Exception.CreateFmt('Troppi messaggi (%d): al massimo %d per chiamata.',
      [LArray.Count, MAX_MESSAGGI]);

  SetLength(Result, LArray.Count);
  LModelli := TDictionary<string, TModelloEmail>.Create;
  LVariabili := TDictionary<string, string>.Create;
  try
    for I := 0 to LArray.Count - 1 do
    begin
      if LArray.Types[I] <> jdtObject then
        raise Exception.CreateFmt('Elemento %d di "messaggi" non e'' un oggetto.', [I]);
      LElemento := LArray.O[I];

      Result[I].Email := Trim(LElemento.S['email']);
      if not TEmailServer.IndirizzoValido(Result[I].Email) then
        raise Exception.CreateFmt(
          'Elemento %d di "messaggi": "%s" non e'' un indirizzo email valido.',
          [I, Result[I].Email]);

      LCodice := LowerCase(Trim(LElemento.S['modello']));
      if LCodice = '' then
        raise Exception.CreateFmt('Elemento %d di "messaggi": manca "modello".', [I]);
      if not LModelli.TryGetValue(LCodice, LModello) then
      begin
        if not TServizioModelliEmail.Trova(LCodice, LModello) then
          raise Exception.CreateFmt(
            'Il modello di email "%s" non esiste. Modelli disponibili: %s.',
            [LCodice, TServizioModelliEmail.CodiciDisponibili]);
        LModelli.Add(LCodice, LModello);
      end;
      Result[I].Modello := LModello.Codice;
      Result[I].Categoria := LModello.Categoria;

      // "variabili": oggetto libero nome -> valore. I numeri diventano
      // testo; i nomi si confrontano in minuscolo con i segnaposto.
      LVariabili.Clear;
      if LElemento.Contains('variabili') and (LElemento.Types['variabili'] = jdtObject) then
      begin
        LVariabiliJSON := LElemento.O['variabili'];
        for J := 0 to LVariabiliJSON.Count - 1 do
          LVariabili.AddOrSetValue(LowerCase(LVariabiliJSON.Names[J]),
            LVariabiliJSON.Items[J].Value);
      end;

      if not TServizioModelliEmail.Componi(LModello, LVariabili, Result[I].Composta, LErrore) then
        raise Exception.CreateFmt('Elemento %d di "messaggi" (%s): %s',
          [I, Result[I].Email, LErrore]);
    end;
  finally
    LVariabili.Free;
    LModelli.Free;
  end;
end;

// --- invia_email: email libera ---------------------------------------------
function EseguiInviaEmail(AArguments: TJDOJsonObject): TMCPToolResult;
var
  LDestinatari: TArray<string>;
  LOggetto, LCorpo, LErrore, LIndirizzo: string;
  LRoot: TJDOJsonObject;
begin
  // 1. Validazione degli argomenti: errori imputabili al modello, restituiti
  //    come errore del tool (il modello li legge e puo' correggersi).
  try
    LDestinatari := LeggiDestinatari(AArguments);
  except
    on E: Exception do
      Exit(TMCPToolResult.Error(E.Message));
  end;

  // L'oggetto e' un'intestazione del messaggio: deve stare su una riga sola.
  LOggetto := AArguments.S['oggetto'];
  LOggetto := StringReplace(LOggetto, #13, ' ', [rfReplaceAll]);
  LOggetto := Trim(StringReplace(LOggetto, #10, ' ', [rfReplaceAll]));
  if LOggetto = '' then
    Exit(TMCPToolResult.Error('Parametro "oggetto" mancante o vuoto.'));

  LCorpo := AArguments.S['corpo'];
  if Trim(LCorpo) = '' then
    Exit(TMCPToolResult.Error('Parametro "corpo" mancante o vuoto: scrivi il testo dell''email.'));

  // 2. Configurazione: controllata prima di tentare la connessione, cosi'
  //    "manca la sezione [SMTP]" non si confonde con un errore di rete.
  if not TEmailServer.Configurato(LErrore) then
    Exit(TMCPToolResult.Error(LErrore));

  // 3. Invio. Un solo messaggio: i destinatari vanno in un'unica
  //    intestazione "A", separati da virgola. Default(TEmailAllegato) =
  //    allegato vuoto, cioe' nessun allegato. Il testo semplice diventa HTML
  //    (TEmailServer spedisce sempre HTML).
  if not TEmailServer.InviaConAllegato(string.Join(', ', LDestinatari), LOggetto,
    TServizioModelliEmail.TestoComeHtml(LCorpo), Default(TEmailAllegato), LErrore) then
    Exit(TMCPToolResult.Error('Invio dell''email non riuscito: ' + LErrore));

  // 4. Esito: si ripete A CHI e con quale oggetto e' partita, cosi' la
  //    risposta finale all'utente si basa su cio' che e' stato fatto davvero.
  LRoot := TJDOJsonObject.Create;
  try
    LRoot.S['esito'] := 'ok';
    for LIndirizzo in LDestinatari do
      LRoot.A['destinatari'].Add(LIndirizzo);
    LRoot.S['oggetto'] := LOggetto;
    Result := TMCPToolResult.Text(LRoot.ToJSON);
  finally
    LRoot.Free;
  end;
end;

// --- anteprima_email_da_modello: compone e mostra, non invia ----------------
function EseguiAnteprimaDaModello(AArguments: TJDOJsonObject): TMCPToolResult;
var
  LMessaggi: TArray<TMessaggioComposto>;
  LMessaggio: TMessaggioComposto;
  LRoot, LBozza: TJDOJsonObject;
  LBozze: TJDOJsonArray;
begin
  try
    LMessaggi := ComponiMessaggi(AArguments);
  except
    on E: Exception do
      Exit(TMCPToolResult.Error(E.Message));
  end;

  LRoot := TJDOJsonObject.Create;
  try
    LRoot.S['esito'] := 'ok';
    LRoot.I['totale'] := Length(LMessaggi);
    LBozze := LRoot.A['bozze'];
    for LMessaggio in LMessaggi do
    begin
      LBozza := LBozze.AddObject;
      LBozza.S['email'] := LMessaggio.Email;
      LBozza.S['modello'] := LMessaggio.Modello;
      LBozza.S['categoria'] := LMessaggio.Categoria;
      LBozza.S['oggetto'] := LMessaggio.Composta.Oggetto;
      LBozza.S['corpo'] := LMessaggio.Composta.Corpo;
    end;
    Result := TMCPToolResult.Text(LRoot.ToJSON);
  finally
    LRoot.Free;
  end;
end;

// --- invia_email_da_modello: compone e invia, una email per messaggio -------
function EseguiInviaDaModello(AArguments: TJDOJsonObject): TMCPToolResult;
var
  LMessaggi: TArray<TMessaggioComposto>;
  LMessaggio: TMessaggioComposto;
  LRoot, LRiga: TJDOJsonObject;
  LDettaglio: TJDOJsonArray;
  LErrore, LPrimoErrore: string;
  LInviate, LNonInviate: Integer;
  LInviata: Boolean;
begin
  // 1. Prima si compone TUTTO: se anche un solo messaggio non si puo'
  //    comporre non parte nulla (vedi ComponiMessaggi).
  try
    LMessaggi := ComponiMessaggi(AArguments);
  except
    on E: Exception do
      Exit(TMCPToolResult.Error(E.Message + ' Nessuna email e'' stata inviata.'));
  end;

  if not TEmailServer.Configurato(LErrore) then
    Exit(TMCPToolResult.Error(LErrore));

  // 2. Invio, un messaggio alla volta. Da qui in poi un errore riguarda la
  //    SINGOLA email (casella rifiutata, connessione caduta): le altre si
  //    tentano comunque e l'esito riporta, riga per riga, che cosa e'
  //    partito e che cosa no. E' l'utente a decidere se ritentare.
  LInviate := 0;
  LNonInviate := 0;
  LPrimoErrore := '';
  LRoot := TJDOJsonObject.Create;
  try
    LRoot.S['esito'] := 'ok';
    LDettaglio := LRoot.A['dettaglio'];
    for LMessaggio in LMessaggi do
    begin
      LInviata := TEmailServer.InviaConAllegato(LMessaggio.Email,
        LMessaggio.Composta.Oggetto, LMessaggio.Composta.CorpoHtml,
        Default(TEmailAllegato), LErrore);
      if LInviata then
        Inc(LInviate)
      else
      begin
        Inc(LNonInviate);
        if LPrimoErrore = '' then
          LPrimoErrore := LErrore;
      end;

      LRiga := LDettaglio.AddObject;
      LRiga.S['email'] := LMessaggio.Email;
      LRiga.S['modello'] := LMessaggio.Modello;
      LRiga.S['oggetto'] := LMessaggio.Composta.Oggetto;
      LRiga.B['inviata'] := LInviata;
      LRiga.S['errore'] := LErrore;      // vuoto se inviata
    end;
    LRoot.I['inviate'] := LInviate;
    LRoot.I['non_inviate'] := LNonInviate;

    // Nessuna email partita: e' un fallimento del tool, non un esito "ok".
    if LInviate = 0 then
      Exit(TMCPToolResult.Error('Nessuna email inviata. Primo errore: ' + LPrimoErrore));

    Result := TMCPToolResult.Text(LRoot.ToJSON);
  finally
    LRoot.Free;
  end;
end;

{ TEmailToolProvider }

function TEmailToolProvider.GetDynamicToolDefs: TArray<TMCPDynamicToolDef>;
const
  DESCRIZIONE_MESSAGGI =
    'Array delle email da comporre, una per elemento: {"email": indirizzo del destinatario, ' +
    '"modello": codice del modello di testo, "variabili": oggetto con i valori da inserire ' +
    'nel testo}. NON scriverlo a mano: usa cosi'' com''e'' l''array preparato da un altro ' +
    'tool, es. il campo "comunicazioni" di trova_ordini_spedizioni_lotto_prodotto_finito.';

  function DefParam(const AName, ADescription: string; ARequired: Boolean;
    const AJsonSchemaType: string): TMCPDynamicParamDef;
  begin
    Result.Name := AName;
    Result.Description := ADescription;
    Result.Required := ARequired;
    Result.JsonSchemaType := AJsonSchemaType;
  end;

begin
  SetLength(Result, 3);

  Result[0].Name := TOOL_INVIA_EMAIL;
  Result[0].Description :=
    'Invia UNA email, con oggetto e testo LIBERI scritti da te, a uno o piu'' destinatari: ' +
    'tutti ricevono lo stesso messaggio e vedono gli altri destinatari. QUESTO TOOL INVIA ' +
    'DAVVERO il messaggio e non si puo'' annullare: usalo solo quando l''utente chiede ' +
    'esplicitamente di inviare una email. Oggetto e testo li scrivi tu per intero, in ' +
    'italiano, completi e pronti da leggere: il destinatario non vede la conversazione. Gli ' +
    'indirizzi sono SOLO quelli indicati dall''utente o letti da un altro tool (es. il campo ' +
    '"email" di get_cliente): non inventarli mai. Non allega file. NON usarlo per le ' +
    'comunicazioni di ritiro/richiamo ai clienti: quelle hanno un testo fisso e si inviano ' +
    'con invia_email_da_modello.';
  Result[0].ControllerClassName := 'TEmailToolProvider';
  Result[0].Params := TArray<TMCPDynamicParamDef>.Create(
    DefParam('destinatari',
      'Array di indirizzi email, almeno uno (es. ["nome@dominio.it"]). Solo indirizzi: non ' +
      'nomi, ragioni sociali o id.', True, 'array'),
    DefParam('oggetto', 'Oggetto dell''email: una riga breve.', True, 'string'),
    DefParam('corpo',
      'Testo completo dell''email, con saluto iniziale e firma. Testo semplice (gli a capo ' +
      'sono rispettati) oppure HTML.', True, 'string')
  );

  Result[1].Name := TOOL_ANTEPRIMA_DA_MODELLO;
  Result[1].Description :=
    'Mostra in ANTEPRIMA, senza inviare nulla, le email a testo fisso che verrebbero spedite: ' +
    'una per ogni elemento di "messaggi", composta dal modello indicato. Sola lettura. Usalo ' +
    'quando l''utente vuole vedere o controllare le comunicazioni (es. di ritiro/richiamo ai ' +
    'clienti) prima di inviarle. Il testo NON lo scrivi tu: viene dal modello salvato nel ' +
    'gestionale. ' +
    // 04/10/2026 (run 4, caso S1-F): il modello pianificava la sola anteprima
    // e cercava i messaggi in un passo del turno precedente. La dipendenza e'
    // una proprieta' del tool, quindi sta qui e non in un esempio del prompt.
    'Per le comunicazioni di ritiro/richiamo servono SEMPRE DUE passi nello stesso piano: ' +
    'passo 1 trova_ordini_spedizioni_lotto_prodotto_finito sui lotti di prodotto finito ' +
    'coinvolti, passo 2 questo tool con "messaggi" = "$1.comunicazioni". Vale anche se la ' +
    'ricerca e'' gia'' stata fatta in un turno precedente: si ripete.';
  Result[1].ControllerClassName := 'TEmailToolProvider';
  Result[1].Params := TArray<TMCPDynamicParamDef>.Create(
    DefParam('messaggi', DESCRIZIONE_MESSAGGI, True, 'array'));

  Result[2].Name := TOOL_INVIA_DA_MODELLO;
  Result[2].Description :=
    'INVIA DAVVERO le email a testo fisso: una email separata per ogni elemento di ' +
    '"messaggi", composta dal modello indicato (lo stesso testo che mostra ' +
    'anteprima_email_da_modello). Non si puo'' annullare: usalo solo quando l''utente chiede ' +
    'esplicitamente di inviare le comunicazioni (es. di ritiro/richiamo ai clienti). Il testo ' +
    'NON lo scrivi tu. Il risultato dice, per ogni destinatario, se l''email e'' partita.';
  Result[2].ControllerClassName := 'TEmailToolProvider';
  Result[2].Params := TArray<TMCPDynamicParamDef>.Create(
    DefParam('messaggi', DESCRIZIONE_MESSAGGI, True, 'array'));
end;

function TEmailToolProvider.InvokeDynamic(const AToolName: string;
  AArguments: TJDOJsonObject): TMCPToolResult;
begin
  if AArguments = nil then
    Exit(TMCPToolResult.Error('Argomenti mancanti per "' + AToolName + '".'));

  // Un tool = una funzione qui sopra: InvokeDynamic smista soltanto.
  if SameText(AToolName, TOOL_INVIA_EMAIL) then
    Result := EseguiInviaEmail(AArguments)
  else if SameText(AToolName, TOOL_ANTEPRIMA_DA_MODELLO) then
    Result := EseguiAnteprimaDaModello(AArguments)
  else if SameText(AToolName, TOOL_INVIA_DA_MODELLO) then
    Result := EseguiInviaDaModello(AArguments)
  else
    Result := TMCPToolResult.Error(Format(
      '"%s" non e'' un tool gestito da questo provider.', [AToolName]));
end;

// ---------------------------------------------------------------------------
// CONTRATTI DEI TOOL (vedi agente_ai/tool/uContrattiTool.pas). Gli schemi di
// output descrivono le risposte "ok" costruite qui sopra: se cambia una
// risposta va cambiato anche il suo schema.
//
// I vincoli aggiungono cio' che lo schema del server (solo "array") non dice.
// VINCOLO_MESSAGGI dichiara la forma degli elementi: e' cio' che permette al
// validatore del piano di accettare "messaggi": "$1.comunicazioni" solo se
// il tool sorgente produce davvero oggetti {"email","modello","variabili"}.
// "variabili" resta un oggetto libero: i nomi dipendono dal modello scelto e
// li controlla TServizioModelliEmail.Componi.
// ---------------------------------------------------------------------------

const
  SCHEMA_OUTPUT_INVIA_EMAIL =
    '{"type":"object","properties":{"esito":{"type":"string","enum":["ok"]},' +
    '"destinatari":{"type":"array","items":{"type":"string"}},' +
    '"oggetto":{"type":"string"}},"required":["esito","destinatari","oggetto"]}';

  SCHEMA_OUTPUT_ANTEPRIMA_DA_MODELLO =
    '{"type":"object","properties":{"esito":{"type":"string","enum":["ok"]},' +
    '"totale":{"type":"integer"},"bozze":{"type":"array","items":{"type":"object",' +
    '"properties":{"email":{"type":"string"},"modello":{"type":"string"},' +
    '"categoria":{"type":"string"},"oggetto":{"type":"string"},"corpo":{"type":"string"}},' +
    '"required":["email","modello","categoria","oggetto","corpo"]}}},' +
    '"required":["esito","totale","bozze"]}';

  SCHEMA_OUTPUT_INVIA_DA_MODELLO =
    '{"type":"object","properties":{"esito":{"type":"string","enum":["ok"]},' +
    '"dettaglio":{"type":"array","items":{"type":"object","properties":{' +
    '"email":{"type":"string"},"modello":{"type":"string"},"oggetto":{"type":"string"},' +
    '"inviata":{"type":"boolean"},"errore":{"type":"string"}},' +
    '"required":["email","modello","oggetto","inviata","errore"]}},' +
    '"inviate":{"type":"integer"},"non_inviate":{"type":"integer"}},' +
    '"required":["esito","dettaglio","inviate","non_inviate"]}';

  VINCOLO_DESTINATARI =
    '{"minItems":1,"items":{"type":"string","minLength":1}}';

  VINCOLO_MESSAGGI =
    '{"minItems":1,"items":{"type":"object","properties":{"email":{"type":"string"},' +
    '"modello":{"type":"string"},"variabili":{"type":"object"}},' +
    '"required":["email","modello","variabili"]}}';

class function TEmailToolProvider.ContrattiTool: TArray<TContrattoTool>;
begin
  Result := TArray<TContrattoTool>.Create(
    // etScrittura + conferma: vedi "Scritture con conferma" in testa.
    ContrattoTool(TOOL_INVIA_EMAIL, etScrittura, True,
      SCHEMA_OUTPUT_INVIA_EMAIL,
      TArray<TVincoloParametro>.Create(
        VincoloParametro('destinatari', VINCOLO_DESTINATARI))),
    ContrattoTool(TOOL_ANTEPRIMA_DA_MODELLO, etLettura, False,
      SCHEMA_OUTPUT_ANTEPRIMA_DA_MODELLO,
      TArray<TVincoloParametro>.Create(
        VincoloParametro('messaggi', VINCOLO_MESSAGGI))),
    ContrattoTool(TOOL_INVIA_DA_MODELLO, etScrittura, True,
      SCHEMA_OUTPUT_INVIA_DA_MODELLO,
      TArray<TVincoloParametro>.Create(
        VincoloParametro('messaggi', VINCOLO_MESSAGGI))));
end;

end.
