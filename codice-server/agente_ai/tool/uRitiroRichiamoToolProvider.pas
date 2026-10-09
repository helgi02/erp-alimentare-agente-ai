unit uRitiroRichiamoToolProvider;

// Tool MCP dello scenario 1 (ritiro/richiamo prodotti non conformi). Provider dinamico
// perche' apri_non_conformita_materia_prima riceve un array vero di codici lotto (vedi
// uFilesToolsProvider).
// 1. apri_non_conformita_materia_prima (scrittura): da uno o piu' codici di lotto di
// materia prima (testo, es. "LMP-MP005-002", mai l'id numerico, che l'utente non conosce)
// risale la filiera fino ai lotti di prodotto finito raggiunti e apre una non conformita'
// per ogni lotto (TServizioRitiroRichiamo.ApriRitiro). Non invia email ne' documenti: e'
// solo il passo di apertura.
// 2. trova_ordini_spedizioni_lotto_prodotto_finito (lettura): dati gli id dei lotti di
// prodotto finito, sempre quelli restituiti dal tool 1 in "lotti_prodotto_finito_id",
// restituisce gli ordini di vendita e le spedizioni (DDT di uscita) gia' emesse.
// Le description sono molto esplicite perche' il modello (Qwen 9B locale) tende a credere
// che aprire la non conformita' concluda l'intero richiamo, ad agire alla prima menzione
// senza attendere la conferma e a confondere codice lotto e id.
// La risoluzione codice -> id sta solo qui: il servizio lavora per id, la conversione e' un
// problema di trasporto. Si cerca il codice e si usa il risultato se e' uno solo, senza
// match parziale (un codice lotto non ha un "quasi uguale").
// TLottoMateriaPrima.GetByCodiceLottoGlobale puo' dare piu' risultati: il codice e' univoco
// solo per coppia (materia_prima_id, codice_lotto) (uq_lotto_materia_prima). Se ambiguo o
// non trovato, "richiede_disambiguazione" con "campo": "codici_lotto_materia_prima", e i
// candidati riportano la materia prima, unico modo per distinguerli.

interface

uses
  System.SysUtils,
  System.Generics.Collections,
  JsonDataObjects,
  MVCFramework.MCP.ToolProvider,
  uContrattiTool,
  uModelLottoMateriaPrima,
  uModelMateriaPrima,
  uServiziRitiroRichiamo;

type
  TRitiroRichiamoToolProvider = class(TMCPToolProvider)
  public
    function GetDynamicToolDefs: TArray<TMCPDynamicToolDef>; override;
    function InvokeDynamic(const AToolName: string;
      AArguments: TJDOJsonObject): TMCPToolResult; override;
    // Contratti dei tool per il pianificatore (vedi uContrattiTool.pas e il fondo di questa
    // unit).
    class function ContrattiTool: TArray<TContrattoTool>;
  end;

implementation

// Legge "codici_lotto_materia_prima" (obbligatorio): array di stringhe, almeno una. Gli
// errori di formato diventano TMCPToolResult.Error.
function LeggiCodiciLotto(AArguments: TJDOJsonObject): TArray<string>;
var
  LArray: TJDOJsonArray;
  LCodici: TArray<string>;
  I: Integer;
begin
  if not (AArguments.Contains('codici_lotto_materia_prima') and
          (AArguments.Types['codici_lotto_materia_prima'] = jdtArray)) then
    raise Exception.Create(
      'Parametro "codici_lotto_materia_prima" mancante o non valido: deve essere un array di ' +
      'codici lotto (stringhe), es. ["LMP-MP005-002"]. MAI un id numerico.');

  LArray := AArguments.A['codici_lotto_materia_prima'];
  if LArray.Count = 0 then
    raise Exception.Create(
      '"codici_lotto_materia_prima" e'' vuoto: serve almeno un codice lotto.');

  SetLength(LCodici, LArray.Count);
  for I := 0 to LArray.Count - 1 do
  begin
    if LArray.Types[I] <> jdtString then
      raise Exception.CreateFmt(
        'Elemento %d di "codici_lotto_materia_prima" non e'' una stringa: atteso il codice ' +
        'lotto testuale (es. "LMP-MP005-002"), non un id numerico.', [I]);
    if Trim(LArray.S[I]) = '' then
      raise Exception.CreateFmt(
        'Elemento %d di "codici_lotto_materia_prima" e'' vuoto.', [I]);
    LCodici[I] := Trim(LArray.S[I]);
  end;

  Result := LCodici;
end;

// Legge "lotti_prodotto_finito_id" (obbligatorio): array di id, sempre quelli restituiti da
// apri_non_conformita_materia_prima, mai digitati o dedotti: per questi lotti non c'e' un
// codice testuale da risolvere.
function LeggiIdLottiProdottoFinito(AArguments: TJDOJsonObject): TArray<Integer>;
var
  LArray: TJDOJsonArray;
  LIDs: TArray<Integer>;
  I: Integer;
begin
  if not (AArguments.Contains('lotti_prodotto_finito_id') and
          (AArguments.Types['lotti_prodotto_finito_id'] = jdtArray)) then
    raise Exception.Create(
      'Parametro "lotti_prodotto_finito_id" mancante o non valido: deve essere un array di id ' +
      'numerici di lotto di prodotto finito, presi da "lotti_prodotto_finito_id" restituito da ' +
      'apri_non_conformita_materia_prima.');

  LArray := AArguments.A['lotti_prodotto_finito_id'];
  if LArray.Count = 0 then
    raise Exception.Create(
      '"lotti_prodotto_finito_id" e'' vuoto: serve almeno un id.');

  SetLength(LIDs, LArray.Count);
  for I := 0 to LArray.Count - 1 do
  begin
    if not (LArray.Types[I] in [jdtInt, jdtLong]) then
      raise Exception.CreateFmt(
        'Elemento %d di "lotti_prodotto_finito_id" non e'' un numero intero.', [I]);
    LIDs[I] := LArray.I[I];
  end;

  Result := LIDs;
end;

// Risolve un codice lotto in id. True con ALottoID se c'e' esattamente un match. Se False
// (ambiguo o non trovato), AProblemaJSON (da aggiungere a "problemi" e liberare a cura del
// chiamante) e' il problema gia' pronto, nella forma
// {"campo","valore_cercato","tipo","candidati"} di uVenditeToolProvider.
function RisolviCodiceLotto(const ACodiceLotto: string; out ALottoID: Integer;
  out AProblemaJSON: TJDOJsonObject): Boolean;
var
  LCandidati: TObjectList<TLottoMateriaPrima>;
  LLotto: TLottoMateriaPrima;
  LMateriaPrima: TMateriaPrima;
  LArrayCandidati: TJDOJsonArray;
  LCandObj: TJDOJsonObject;
begin
  AProblemaJSON := nil;

  LCandidati := TLottoMateriaPrima.GetByCodiceLottoGlobale(ACodiceLotto);
  try
    if LCandidati.Count = 1 then
    begin
      ALottoID := LCandidati[0].ID;
      Exit(True);
    end;

    // Stessa forma di problema degli altri provider, riconosciuta dal frontend (chat.js,
    // aggiungiScelteDisambiguazione). "campo" e' il nome del parametro reale.
    AProblemaJSON := TJDOJsonObject.Create;
    AProblemaJSON.S['campo'] := 'codici_lotto_materia_prima';
    AProblemaJSON.S['valore_cercato'] := ACodiceLotto;
    if LCandidati.Count = 0 then
      AProblemaJSON.S['tipo'] := 'non_trovato'
    else
      AProblemaJSON.S['tipo'] := 'ambiguo';

    LArrayCandidati := AProblemaJSON.A['candidati'];
    for LLotto in LCandidati do
    begin
      LCandObj := LArrayCandidati.AddObject;
      LCandObj.I['id'] := LLotto.ID;
      LCandObj.S['codice_lotto'] := LLotto.CodiceLotto;

      // Denominazione della materia prima: senza, due candidati con lo stesso codice_lotto
      // sembrerebbero identici.
      LMateriaPrima := TMateriaPrima.GetByID(LLotto.MateriaPrimaID);
      if LMateriaPrima <> nil then
      try
        LCandObj.S['materia_prima'] := LMateriaPrima.Denominazione;
      finally
        LMateriaPrima.Free;
      end;

      LCandObj.S['data_scadenza'] := DateToStr(LLotto.DataScadenza);
    end;

    Result := False;
  finally
    LCandidati.Free;
  end;
end;

// True se l'array JSON di interi contiene gia' AValore (ricerca lineare, gli array sono
// piccoli).
function ContieneIntero(AArray: TJDOJsonArray; AValore: Integer): Boolean;
var
  J: Integer;
begin
  for J := 0 to AArray.Count - 1 do
    if AArray.I[J] = AValore then
      Exit(True);
  Result := False;
end;

// Risolve tutti i codici aggregando ogni problema invece di fermarsi al primo (come
// TServizioVendite.InterrogaVendite): il modello puo' correggerli tutti al turno dopo. True
// solo se tutti risolti; altrimenti AProblemiJSON ha un problema per codice (lo libera il
// chiamante).
function RisolviCodiciLotto(const ACodici: TArray<string>; out ALottiID: TArray<Integer>;
  out AProblemiJSON: TJDOJsonArray): Boolean;
var
  LCodice: string;
  LLottoID: Integer;
  LProblemaJSON: TJDOJsonObject;
  LTuttiRisolti: Boolean;
begin
  ALottiID := [];
  AProblemiJSON := TJDOJsonArray.Create;
  LTuttiRisolti := True;

  for LCodice in ACodici do
  begin
    if RisolviCodiceLotto(LCodice, LLottoID, LProblemaJSON) then
      ALottiID := ALottiID + [LLottoID]
    else
    begin
      LTuttiRisolti := False;
      AProblemiJSON.Add(LProblemaJSON);
    end;
  end;

  Result := LTuttiRisolti;
end;

// Comunicazioni ai clienti dentro trova_ordini_spedizioni_lotto_prodotto_finito. Il
// risultato porta "comunicazioni": una voce per ogni email da mandare, nella forma
// {"email","modello","variabili"} del provider email (uEmailToolProvider.pas).
// Qui si decide chi avvisare e con quale modello (gia' spedita -> richiamo, non ancora
// spedita -> ritiro); il testo sta in modelli_email (scripts/004_modelli_email.sql); il
// provider email compone e spedisce.
// Perche' non un tool a parte (03/10/2026): un tool
// trova_clienti_da_avvisare_lotto_prodotto_finito non e' mai stato scelto, perche' domanda
// e input erano quasi uguali a questo e il Planner prendeva sempre il piu' noto, cercando
// poi "comunicazioni" in un risultato che non le aveva. Due tool quasi uguali sono quello
// che il principio "pochi tool generici" vuole evitare.
// I due codici modello devono esistere in modelli_email, e le variabili (ragione_sociale,
// motivo, elenco_prodotti) devono essere quelle dei due testi.
const
  MODELLO_EMAIL_MERCE_SPEDITA = 'richiamo_merce_spedita';
  MODELLO_EMAIL_MERCE_NON_SPEDITA = 'ritiro_merce_non_spedita';
  // Usato se "motivo" manca: meglio una frase generica che un invio bloccato.
  MOTIVO_EMAIL_GENERICO = 'difetto riscontrato su una materia prima utilizzata nella produzione';

// Aggiunge ad ARoot "comunicazioni" e i due conteggi. Solleva un'eccezione se la lettura
// fallisce (diventa errore del tool).
procedure AggiungiComunicazioni(ARoot: TJDOJsonObject;
  const ALottiProdottoFinitoID: TArray<Integer>; const AMotivo: string);
var
  LComunicazioni: TObjectList<TComunicazioneCliente>;
  LComunicazione: TComunicazioneCliente;
  LObj: TJDOJsonObject;
  LArray: TJDOJsonArray;
  LMotivo: string;
  LSpedite, LNonSpedite: Integer;
begin
  LMotivo := Trim(AMotivo);
  if LMotivo = '' then
    LMotivo := MOTIVO_EMAIL_GENERICO;

  LComunicazioni := TServizioRitiroRichiamo.TrovaComunicazioniClienti(ALottiProdottoFinitoID);
  try
    LSpedite := 0;
    LNonSpedite := 0;
    // Creato subito: "comunicazioni" deve esserci anche se vuoto.
    LArray := ARoot.A['comunicazioni'];
    for LComunicazione in LComunicazioni do
    begin
      LObj := LArray.AddObject;
      LObj.S['email'] := LComunicazione.Email;
      if LComunicazione.MerceSpedita then
      begin
        LObj.S['modello'] := MODELLO_EMAIL_MERCE_SPEDITA;
        Inc(LSpedite);
      end
      else
      begin
        LObj.S['modello'] := MODELLO_EMAIL_MERCE_NON_SPEDITA;
        Inc(LNonSpedite);
      end;
      LObj.O['variabili'].S['ragione_sociale'] := LComunicazione.RagioneSociale;
      LObj.O['variabili'].S['motivo'] := LMotivo;
      LObj.O['variabili'].S['elenco_prodotti'] :=
        string.Join(#10, LComunicazione.Righe.ToArray);
    end;
    ARoot.I['clienti_merce_spedita'] := LSpedite;
    ARoot.I['clienti_merce_non_spedita'] := LNonSpedite;
  finally
    LComunicazioni.Free;
  end;
end;

function TRitiroRichiamoToolProvider.GetDynamicToolDefs: TArray<TMCPDynamicToolDef>;

  function DefParam(const AName, ADescription: string; ARequired: Boolean;
    const AJsonSchemaType: string): TMCPDynamicParamDef;
  begin
    Result.Name := AName;
    Result.Description := ADescription;
    Result.Required := ARequired;
    Result.JsonSchemaType := AJsonSchemaType;
  end;

begin
  SetLength(Result, 2);

  Result[0].Name := 'apri_non_conformita_materia_prima';
  Result[0].Description :=
    'Apre una non conformita'' per uno o piu'' lotti di materia prima non conformi e risale ' +
    'automaticamente ai lotti di prodotto finito raggiunti. QUESTO TOOL SCRIVE NEL DATABASE ' +
    'DATI REALI (apre una non conformita'' vera): chiamalo SOLO dopo che l''utente ha ' +
    'confermato esplicitamente di voler procedere con l''apertura/il ritiro per questo/i ' +
    'lotto/i - non alla prima segnalazione del problema (es. "abbiamo trovato un corpo ' +
    'estraneo nel lotto X" descrive un fatto, non e'' di per se'' un''istruzione ad agire: ' +
    'chiedi prima conferma). ' +
    'NON invia email, non genera documenti di compliance (scheda notifica ASL, modello di ' +
    'richiamo, ecc.) e non contatta clienti: fa SOLO apertura della non conformita'' e ' +
    'tracciamento dei prodotti raggiunti, non conclude il processo di ritiro/richiamo. ' +
    'Se l''utente vuole anche sapere se il prodotto e'' gia'' stato spedito a qualche cliente, ' +
    'usa il risultato di questo tool (campo "lotti_prodotto_finito_id" in radice: tutti i lotti ' +
    'raggiunti, senza doppioni; se vuoto non c''e'' nulla da verificare) come input di trova_ordini_spedizioni_lotto_prodotto_finito, in una ' +
    'chiamata separata - non in automatico, solo se serve davvero alla richiesta dell''utente. ' +
    'Se uno o piu'' codici in codici_lotto_materia_prima non corrispondono a esattamente un ' +
    'lotto (non trovato, oppure ambiguo perche'' piu'' materie prime diverse hanno un lotto con ' +
    'lo stesso codice), non apre nulla e restituisce "richiede_disambiguazione" con i ' +
    'candidati: mostrali all''utente e ripeti la chiamata con i codici corretti.';
  Result[0].ControllerClassName := 'TRitiroRichiamoToolProvider';
  Result[0].Params := TArray<TMCPDynamicParamDef>.Create(
    DefParam(
      'codici_lotto_materia_prima',
      'Array di codici lotto di materia prima, uno per ogni lotto non conforme. Deve contenere ' +
      'il CODICE testuale del lotto cosi'' come lo conosce l''utente (es. ["LMP-MP005-002"]), ' +
      'MAI un id numerico di database: l''utente non conosce e non deve fornire id interni.',
      True,
      'array'
    ),
    DefParam(
      'codice_non_conformita_base',
      'UN SOLO codice per la non conformita'' (es. "NC-2026-014"), anche se i lotti sono piu'' ' +
      'di uno: non generare piu'' codici diversi, uno per lotto - se i lotti sono piu'' di uno, ' +
      'il sistema aggiunge da solo un suffisso progressivo ("-1", "-2", ...) a questo stesso ' +
      'codice per ciascuna riga aperta.',
      True,
      'string'
    ),
    DefParam(
      'motivo_non_conformita',
      'Descrizione del motivo della non conformita'' (es. "corpo estraneo segnalato dal ' +
      'cliente"), la stessa per tutti i lotti di questa chiamata.',
      True,
      'string'
    )
  );

  Result[1].Name := 'trova_ordini_spedizioni_lotto_prodotto_finito';
  Result[1].Description :=
    'Dati uno o piu'' id di lotto di prodotto finito, restituisce gli ordini di vendita che li ' +
    'referenziano e le eventuali spedizioni (DDT di uscita) gia'' emesse per ciascun ordine - ' +
    'per sapere se e a quale cliente (campo cliente_id) il prodotto e'' gia'' stato consegnato. ' +
    'Sola lettura, non modifica nulla. Gli id in lotti_prodotto_finito_id NON vanno mai ' +
    'inventati ne'' chiesti in un altro formato all''utente: sono SEMPRE quelli gia'' presenti ' +
    'nel campo "lotti_prodotto_finito_id" restituito da apri_non_conformita_materia_prima per ' +
    'una non conformita'' aperta in questa stessa conversazione - se quel campo era vuoto, non ' +
    'chiamare questo tool, non c''e'' nessun prodotto finito da verificare. ' +
    'Un lotto senza ordini collegati restituisce un elenco vuoto, non e'' un errore. ' +
    'Il risultato contiene anche "comunicazioni": l''elenco dei CLIENTI DA AVVISARE, uno per ' +
    'email da mandare, gia'' con il testo fisso che gli spetta ("richiamo" se la merce gli e'' ' +
    'stata spedita, "ritiro" se e'' in un suo ordine non ancora spedito). Per mostrare o ' +
    'inviare quelle email passa "comunicazioni" COSI'' COM''E'' al parametro "messaggi" di ' +
    'anteprima_email_da_modello o di invia_email_da_modello. Se "comunicazioni" e'' vuoto non ' +
    'c''e'' nessun cliente da avvisare.';
  Result[1].ControllerClassName := 'TRitiroRichiamoToolProvider';
  Result[1].Params := TArray<TMCPDynamicParamDef>.Create(
    DefParam(
      'lotti_prodotto_finito_id',
      'Array di id numerici di lotto di prodotto finito, presi cosi'' come sono dal campo ' +
      '"lotti_prodotto_finito_id" restituito da apri_non_conformita_materia_prima. Non sono ' +
      'codici testuali e non vanno mai inventati.',
      True,
      'array'
    ),
    DefParam(
      'motivo',
      'Motivo della non conformita'' da riportare nelle email ai clienti, in una frase (lo ' +
      'stesso usato per aprire la non conformita''). Facoltativo: serve solo quando poi si ' +
      'preparano o si inviano le email.',
      False,
      'string'
    )
  );
end;

function TRitiroRichiamoToolProvider.InvokeDynamic(const AToolName: string;
  AArguments: TJDOJsonObject): TMCPToolResult;
var
  LCodiciLotto: TArray<string>;
  LLottiMateriaPrimaID: TArray<Integer>;
  LProblemiJSON: TJDOJsonArray;
  LEsitoApertura: TEsitoAperturaRitiro;
  LNCAperta: TNonConformitaAperta;
  LIdsProdottoFinito: TArray<Integer>;
  LEsitoClienti: TEsitoClientiPerLotti;
  LLottoConClienti: TLottoConClienti;
  LEsposizione: TEsposizioneOrdine;
  LSpedizione: TSpedizioneRiga;
  LRoot: TJDOJsonObject;
  LArrayNC, LArrayLottiPF, LArrayLotti, LArrayEsposizioni, LArraySpedizioni: TJDOJsonArray;
  LArrayTuttiPF: TJDOJsonArray;
  LObjNC, LObjLotto, LObjEsposizione, LObjSpedizione, LObjVista: TJDOJsonObject;
  I: Integer;
begin
  if AArguments = nil then
    Exit(TMCPToolResult.Error('Argomenti mancanti per "' + AToolName + '".'));

  if SameText(AToolName, 'apri_non_conformita_materia_prima') then
  begin
    try
      LCodiciLotto := LeggiCodiciLotto(AArguments);
    except
      on E: Exception do
        Exit(TMCPToolResult.Error(E.Message));
    end;

    if Trim(AArguments.S['codice_non_conformita_base']) = '' then
      Exit(TMCPToolResult.Error('Parametro "codice_non_conformita_base" mancante.'));
    if Trim(AArguments.S['motivo_non_conformita']) = '' then
      Exit(TMCPToolResult.Error('Parametro "motivo_non_conformita" mancante.'));

    // Se un codice non si risolve niente viene scritto (tutto o niente, come
    // InterrogaVendite): aprire una non conformita' sul lotto sbagliato sarebbe grave.
    if not RisolviCodiciLotto(LCodiciLotto, LLottiMateriaPrimaID, LProblemiJSON) then
    begin
      // Stessa forma "richiede_disambiguazione" degli altri provider. LRoot prende possesso
      // di LProblemiJSON all'assegnazione a A['problemi']: nessun Free separato.
      LRoot := TJDOJsonObject.Create;
      try
        LRoot.S['esito'] := 'richiede_disambiguazione';
        LRoot.A['problemi'] := LProblemiJSON;
        Exit(TMCPToolResult.Text(LRoot.ToJSON));
      finally
        LRoot.Free;
      end;
    end;

    try
      LEsitoApertura := TServizioRitiroRichiamo.ApriRitiro(
        AArguments.S['codice_non_conformita_base'], AArguments.S['motivo_non_conformita'],
        LLottiMateriaPrimaID);
    except
      on E: Exception do
        Exit(TMCPToolResult.Error(E.Message));
    end;

    try
      LRoot := TJDOJsonObject.Create;
      try
        LRoot.S['esito'] := 'ok';
        LArrayNC := LRoot.A['non_conformita_aperte'];
        for LNCAperta in LEsitoApertura.NonConformitaAperte do
        begin
          LObjNC := LArrayNC.AddObject;
          LObjNC.I['non_conformita_id'] := LNCAperta.NonConformitaID;
          LObjNC.S['codice_non_conformita'] := LNCAperta.CodiceNC;
          LObjNC.I['lotto_materia_prima_id'] := LNCAperta.LottoMateriaPrimaID;

          LArrayLottiPF := LObjNC.A['lotti_prodotto_finito_id'];
          for I := 0 to Length(LNCAperta.LottiProdottoFinitoIDs) - 1 do
            LArrayLottiPF.Add(LNCAperta.LottiProdottoFinitoIDs[I]);

          LObjNC.B['richiede_scheda_notifica_osa'] := LNCAperta.RichiedeSchedaNotificaOSA;
        end;

        // Elenco aggregato in radice: tutti i lotti di prodotto finito raggiunti, senza
        // doppioni (due lotti di materia prima possono finire nello stesso lotto). E'
        // l'input di trova_ordini_spedizioni_lotto_prodotto_finito via
        // "$1.lotti_prodotto_finito_id", che deve essere un array semplice di interi: i
        // riferimenti non appiattiscono array di array
        // (non_conformita_aperte[*].lotti_prodotto_finito_id).
        LArrayTuttiPF := LRoot.A['lotti_prodotto_finito_id'];
        for LNCAperta in LEsitoApertura.NonConformitaAperte do
          for I := 0 to Length(LNCAperta.LottiProdottoFinitoIDs) - 1 do
            if not ContieneIntero(LArrayTuttiPF, LNCAperta.LottiProdottoFinitoIDs[I]) then
              LArrayTuttiPF.Add(LNCAperta.LottiProdottoFinitoIDs[I]);

        // "aperture_vista": per ogni non conformita' aperta, la vista Tracciabilita' del
        // lotto di partenza. E' un array perche' una chiamata puo' aprirne piu'; forma
        // {"vista","parametri"} come "apertura_vista" (uRicetteToolProvider).
        // "modalita":"pulsante" = la chat mostra un pulsante per voce; "riferimento"
        // distingue un pulsante dall'altro.
        for LNCAperta in LEsitoApertura.NonConformitaAperte do
        begin
          LObjVista := LRoot.A['aperture_vista'].AddObject;
          LObjVista.S['vista'] := 'tracciabilita_lotto';
          LObjVista.S['modalita'] := 'pulsante';
          LObjVista.S['riferimento'] := LNCAperta.CodiceNC;
          LObjVista.O['parametri'].S['tipo_lotto'] := 'materia_prima';
          LObjVista.O['parametri'].I['lotto_id'] := LNCAperta.LottoMateriaPrimaID;
        end;

        Result := TMCPToolResult.Text(LRoot.ToJSON);
      finally
        LRoot.Free;
      end;
    finally
      LEsitoApertura.Free;
    end;
  end

  else if SameText(AToolName, 'trova_ordini_spedizioni_lotto_prodotto_finito') then
  begin
    try
      LIdsProdottoFinito := LeggiIdLottiProdottoFinito(AArguments);
    except
      on E: Exception do
        Exit(TMCPToolResult.Error(E.Message));
    end;

    try
      LEsitoClienti := TServizioRitiroRichiamo.TrovaClientiLottoProdottoFinito(LIdsProdottoFinito);
    except
      on E: Exception do
        Exit(TMCPToolResult.Error(E.Message));
    end;

    try
      LRoot := TJDOJsonObject.Create;
      try
        LRoot.S['esito'] := 'ok';
        LArrayLotti := LRoot.A['lotti'];
        for LLottoConClienti in LEsitoClienti.Lotti do
        begin
          LObjLotto := LArrayLotti.AddObject;
          LObjLotto.I['lotto_prodotto_finito_id'] := LLottoConClienti.LottoProdottoFinitoID;

          LArrayEsposizioni := LObjLotto.A['ordini'];
          for LEsposizione in LLottoConClienti.Esposizioni do
          begin
            LObjEsposizione := LArrayEsposizioni.AddObject;
            LObjEsposizione.I['ordine_vendita_riga_id'] := LEsposizione.OrdineVenditaRigaID;
            LObjEsposizione.I['ordine_vendita_id'] := LEsposizione.OrdineVenditaID;
            LObjEsposizione.S['numero_ordine'] := LEsposizione.NumeroOrdine;
            LObjEsposizione.I['cliente_id'] := LEsposizione.ClienteID;
            LObjEsposizione.F['quantita'] := LEsposizione.Quantita;

            LArraySpedizioni := LObjEsposizione.A['spedizioni'];
            for LSpedizione in LEsposizione.Spedizioni do
            begin
              LObjSpedizione := LArraySpedizioni.AddObject;
              LObjSpedizione.I['ddt_uscita_id'] := LSpedizione.DDTUscitaID;
              LObjSpedizione.S['numero_ddt'] := LSpedizione.NumeroDDT;
              LObjSpedizione.S['data_spedizione'] := DateToStr(LSpedizione.DataSpedizione);
              LObjSpedizione.F['quantita_spedita'] := LSpedizione.QuantitaSpedita;
            end;
          end;
        end;

        // Clienti da avvisare, pronti per il provider email (vedi AggiungiComunicazioni).
        try
          AggiungiComunicazioni(LRoot, LIdsProdottoFinito, AArguments.S['motivo']);
        except
          on E: Exception do
            Exit(TMCPToolResult.Error(E.Message));
        end;

        Result := TMCPToolResult.Text(LRoot.ToJSON);
      finally
        LRoot.Free;
      end;
    finally
      LEsitoClienti.Free;
    end;
  end

  else
    // Non dovrebbe succedere (si dispatchano solo i nomi di GetDynamicToolDefs), ma meglio
    // un fallback esplicito.
    Result := TMCPToolResult.Error(Format(
      '"%s" non e'' un tool gestito da questo provider.', [AToolName]));
end;

// Contratti (vedi uContrattiTool.pas). Gli schemi di output descrivono le risposte
// costruite sopra: se cambia una risposta, va cambiato anche lo schema.

const
  SCHEMA_OUTPUT_APRI_NON_CONFORMITA_MATERIA_PRIMA =
    '{"type":"object","properties":{"esito":{"type":"string","enum":["ok"]},' +
    '"non_conformita_aperte":{"type":"array","items":{"type":"object","properties":{"non_conformita_id":{"type":"in' +
    'teger"},"codice_non_conformita":{"type":"string"},"lotto_materia_prima_id":{"type":"integer"},' +
    '"lotti_prodotto_finito_id":{"type":"array","items":{"type":"integer"}},' +
    '"richiede_scheda_notifica_osa":{"type":"boolean"}},"required":["non_conformita_id",' +
    '"codice_non_conformita","lotto_materia_prima_id","lotti_prodotto_finito_id",' +
    '"richiede_scheda_notifica_osa"]}},"lotti_prodotto_finito_id":{"type":"array",' +
    '"items":{"type":"integer"}},"aperture_vista":{"type":"array","items":{"type":"object"}}},' +
    '"required":["esito","non_conformita_aperte",' +
    '"lotti_prodotto_finito_id"]}';

  VINCOLO_CODICI_LOTTO_MATERIA_PRIMA =
    '{"minItems":1,"items":{"type":"string","minLength":1}}';

  SCHEMA_OUTPUT_TROVA_ORDINI_SPEDIZIONI_LOTTO_PRODOTTO_FINITO =
    '{"type":"object","properties":{"esito":{"type":"string","enum":["ok"]},' +
    '"lotti":{"type":"array","items":{"type":"object","properties":{"lotto_prodotto_finito_id":{"type":"integer"},' +
    '"ordini":{"type":"array","items":{"type":"object","properties":{"ordine_vendita_riga_id":{"type":"integer"},' +
    '"ordine_vendita_id":{"type":"integer"},"numero_ordine":{"type":"string"},' +
    '"cliente_id":{"type":"integer"},"quantita":{"type":"number"},"spedizioni":{"type":"array",' +
    '"items":{"type":"object","properties":{"ddt_uscita_id":{"type":"integer"},' +
    '"numero_ddt":{"type":"string"},"data_spedizione":{"type":"string"},"quantita_spedita":{"type":"number"}},' +
    '"required":["ddt_uscita_id","numero_ddt","data_spedizione","quantita_spedita"]}}},' +
    '"required":["ordine_vendita_riga_id","ordine_vendita_id","numero_ordine",' +
    '"cliente_id","quantita","spedizioni"]}}},"required":["lotto_prodotto_finito_id",' +
    '"ordini"]}},' +
    // "comunicazioni": stessa forma del parametro "messaggi" del provider email
    // (VINCOLO_MESSAGGI in uEmailToolProvider.pas), che rende valido "messaggi":
    // "$N.comunicazioni".
    '"comunicazioni":{"type":"array","items":{"type":"object","properties":{' +
    '"email":{"type":"string"},"modello":{"type":"string"},"variabili":{"type":"object"}},' +
    '"required":["email","modello","variabili"]}},' +
    '"clienti_merce_spedita":{"type":"integer"},"clienti_merce_non_spedita":{"type":"integer"}},' +
    '"required":["esito","lotti","comunicazioni","clienti_merce_spedita",' +
    '"clienti_merce_non_spedita"]}';

  VINCOLO_LOTTI_PRODOTTO_FINITO_ID =
    '{"minItems":1,"items":{"type":"integer","minimum":1}}';

class function TRitiroRichiamoToolProvider.ContrattiTool: TArray<TContrattoTool>;
begin
  Result := TArray<TContrattoTool>.Create(
    ContrattoTool('apri_non_conformita_materia_prima', etScrittura, True,
      SCHEMA_OUTPUT_APRI_NON_CONFORMITA_MATERIA_PRIMA,
      TArray<TVincoloParametro>.Create(
        VincoloParametro('codici_lotto_materia_prima', VINCOLO_CODICI_LOTTO_MATERIA_PRIMA))),
    ContrattoTool('trova_ordini_spedizioni_lotto_prodotto_finito', etLettura, False,
      SCHEMA_OUTPUT_TROVA_ORDINI_SPEDIZIONI_LOTTO_PRODOTTO_FINITO,
      TArray<TVincoloParametro>.Create(
        VincoloParametro('lotti_prodotto_finito_id', VINCOLO_LOTTI_PRODOTTO_FINITO_ID))));
end;

end.
