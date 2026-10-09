unit uRitiroRichiamoToolProvider;

(* ============================================================================
  TRitiroRichiamoToolProvider — tool MCP per lo scenario 1 del tirocinio
  (ritiro/richiamo di prodotti non conformi). Due tool, provider "dinamico"
  (RegisterDynamicProvider, non RegisterToolProvider) per lo stesso motivo di
  TFilesToolsProvider/TRicetteToolProvider: apri_non_conformita_materia_prima
  riceve un array vero di codici lotto, non esprimibile con gli attributi
  [MCPTool]/[MCPParam] via RTTI (vedi il commento in testa a
  uFilesToolsProvider.pas).

  ── I due tool ───────────────────────────────────────────────────────────
  1. apri_non_conformita_materia_prima (SCRITTURA): dati uno o piu' CODICI
     di lotto di materia prima (testo, es. "LMP-MP005-002" — MAI l'id
     numerico: e' il modello a doverlo ricevere dall'utente, che non
     conosce e non deve inventare id di database), risale la filiera fino
     ai lotti di prodotto finito raggiunti e apre una non conformita' per
     ciascun lotto di materia prima (TServizioRitiroRichiamo.ApriRitiro).
     NON invia email, non genera documenti di compliance, non avvisa
     ASL/clienti: e' solo il passo di apertura/tracciamento, il resto del
     processo (scenario successivo, non ancora implementato) e' fuori da
     questo tool.
  2. trova_ordini_spedizioni_lotto_prodotto_finito (sola lettura): dati uno
     o piu' id di lotto di prodotto finito — SEMPRE quelli restituiti da
     apri_non_conformita_materia_prima in "lotti_prodotto_finito_id", mai
     digitati o dedotti dall'utente — restituisce gli ordini di vendita che
     lo referenziano e le eventuali spedizioni (DDT di uscita) gia'
     emesse.

  ── Perche' le description sotto sono cosi' esplicite ─────────────────────
  Il modello di inferenza (Qwen 9B locale via LM Studio, vedi le note di
  progetto) e' piccolo: senza istruzioni molto dirette tende a (a) credere
  che aprire la non conformita' concluda l'intero processo di ritiro/
  richiamo (invio email comprese, che qui non esistono), (b) agire alla
  prima menzione del problema invece di aspettare una conferma esplicita
  dell'utente prima di scrivere nel DB, (c) confondere codice lotto testuale
  e id numerico nonostante il nome del parametro. Stesso principio gia'
  applicato in uRicetteToolProvider.pas (vedi il commento su
  escludi_allergene_codice/cerca_componenti_ricetta): meglio essere
  ridondanti nella description che scoprire il fraintendimento in una
  demo/valutazione.

  ── Risoluzione codice_lotto -> id: SOLO qui, non nel Services ────────────
  TServizioRitiroRichiamo (services/uServiziRitiroRichiamo.pas) lavora per
  id numerici (TArray<Integer>): e' il suo dominio naturale, quello delle
  query e delle FK. La conversione testo->id e' un problema di TRASPORTO
  (il modello parla per codici, il DB per id), quindi resta confinata qui:
  niente classi TRisoluzioneXxx/TCandidatoXxx parallele a quelle di
  uServiziVendite.pas — sarebbe struttura in piu' per un caso che e' solo
  "cerca il codice, se ne trovi esattamente uno usa quello, altrimenti
  segnala" (nessun fallback a match parziale: un codice lotto non ha una
  nozione sensata di "quasi uguale", a differenza di una ragione sociale).
  RisolviCodiceLotto sotto fa questo, chiamando direttamente
  TLottoMateriaPrima.GetByCodiceLottoGlobale (models/
  uModelLottoMateriaPrima.pas) — che puo' restituire piu' di un risultato,
  perche' codice_lotto e' univoco solo per coppia (materia_prima_id,
  codice_lotto), non globalmente (vincolo uq_lotto_materia_prima).
  Ambiguo o non trovato -> stessa forma "richiede_disambiguazione" gia'
  usata da get_list_vendite/uRicetteToolProvider, cosi' il frontend la
  riconosce senza bisogno di sapere da quale tool arriva; qui il campo
  "campo" vale "codici_lotto_materia_prima" (il nome del parametro reale) e
  i candidati riportano anche la materia prima di appartenenza (unico modo
  per l'utente di distinguere due lotti con lo stesso codice appartenenti a
  materie prime diverse).
  ============================================================================ *)

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
    // Contratti dei tool di questo provider per il pianificatore: schema del
    // risultato, lettura/scrittura, conferma, vincoli sugli input (vedi
    // agente_ai/tool/uContrattiTool.pas e la sezione in fondo a questa unit).
    class function ContrattiTool: TArray<TContrattoTool>;
  end;

implementation

{ Funzioni di supporto, private all'unit }

// Legge il parametro "codici_lotto_materia_prima", OBBLIGATORIO: un array
// di stringhe (codici lotto), almeno una. Stesso principio di validazione
// di LeggiSostituzioni/LeggiAggiunte in uRicetteToolProvider.pas: eccezioni
// di formato, imputabili al modello, che InvokeDynamic trasforma in
// TMCPToolResult.Error senza lasciarle propagare come errore di trasporto.
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

// Legge il parametro "lotti_prodotto_finito_id", OBBLIGATORIO: un array di
// id numerici di lotto di prodotto finito. A differenza di
// "codici_lotto_materia_prima" questi arrivano gia' come id — SEMPRE
// quelli restituiti da apri_non_conformita_materia_prima in
// "lotti_prodotto_finito_id" (vedi il commento in testa alla unit),
// MAI digitati o dedotti dall'utente/dal modello - non c'e' nessun
// "codice" testuale di lotto di prodotto finito da risolvere qui.
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

// Risolve UN codice lotto in un id numerico. Restituisce True e ALottoID
// valorizzato se la risoluzione ha successo (esattamente un match).
// Restituisce False se il codice e' ambiguo (piu' materie prime diverse
// hanno un lotto con questo codice) o non trovato: in tal caso
// AProblemaJSON (di proprieta' del CHIAMANTE, che deve aggiungerlo
// all'array "problemi" e liberarlo) e' il singolo oggetto-problema gia'
// pronto, stessa forma {"campo","valore_cercato","tipo","candidati"} usata
// da CostruisciRispostaDisambiguazione in uVenditeToolProvider.pas.
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

    // Zero o piu' di un candidato: stessa forma di problema usata dagli
    // altri tool provider del progetto, cosi' il frontend la riconosce
    // senza sapere da quale tool arriva (components/chat.js,
    // aggiungiScelteDisambiguazione). "campo" = nome del parametro reale
    // del tool, non un nome interno.
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

      // Denominazione della materia prima: e' l'UNICO modo per l'utente di
      // distinguere due candidati che hanno letteralmente lo stesso
      // codice_lotto ma appartengono a materie prime diverse (vedi
      // commento in testa alla unit) - senza questo campo la disambiguazione
      // mostrerebbe due righe identiche, inutile per scegliere.
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

// True se AArray (array JSON di interi) contiene gia' AValore. Serve a
// costruire senza doppioni l'elenco aggregato "lotti_prodotto_finito_id"
// di apri_non_conformita_materia_prima: gli array sono piccoli (pochi lotti
// per richiamo), una ricerca lineare basta e non richiede un dizionario.
function ContieneIntero(AArray: TJDOJsonArray; AValore: Integer): Boolean;
var
  J: Integer;
begin
  for J := 0 to AArray.Count - 1 do
    if AArray.I[J] = AValore then
      Exit(True);
  Result := False;
end;

// Risolve TUTTI i codici lotto passati, aggregando OGNI problema invece di
// fermarsi al primo - stesso principio di TServizioVendite.InterrogaVendite
// (uServiziVendite.pas): un modello locale che sbaglia due codici su tre
// deve poterli correggere entrambi nel turno successivo, non scoprirli uno
// alla volta. Restituisce True (e ALottiID valorizzato) solo se TUTTI i
// codici sono stati risolti; altrimenti False e AProblemiJSON contiene un
// oggetto-problema per ciascun codice non risolto (il chiamante libera
// AProblemiJSON dopo averlo consumato).
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

// ---------------------------------------------------------------------------
// COMUNICAZIONI AI CLIENTI dentro trova_ordini_spedizioni_lotto_prodotto_finito.
// Oltre al dettaglio ordini/spedizioni, il risultato porta "comunicazioni":
// una voce per ogni email da mandare, nella forma che il provider "email" sa
// comporre e inviare, {"email","modello","variabili"} (vedi
// uEmailToolProvider.pas, anteprima_email_da_modello / invia_email_da_modello).
//
// Divisione dei compiti:
//  - QUI (dominio ritiro/richiamo) si decide CHI avvisare e CON QUALE modello:
//    merce gia' spedita -> richiamo, merce non ancora spedita -> ritiro;
//  - il testo sta nella tabella modelli_email (scripts/004_modelli_email.sql);
//  - il provider "email" compone e spedisce, senza sapere nulla di lotti.
//
// PERCHE' NON UN TOOL A PARTE (03/10/2026). La prima versione era un terzo
// tool, trova_clienti_da_avvisare_lotto_prodotto_finito. Nel primo run
// (delphi_20261003_131516) non e' mai stato scelto: stesso input e domanda
// quasi uguale ("a chi e' arrivato?" / "chi dobbiamo avvisare?"), quindi
// Planner e retrieval prendevano sempre questo tool, piu' noto, e poi
// cercavano "comunicazioni" in un risultato che non le aveva. Due tool quasi
// uguali sono proprio cio' che il principio "pochi tool generici" vuole
// evitare: ora la risposta alla seconda domanda sta nel risultato della prima.
//
// I due codici qui sotto devono esistere nella tabella modelli_email, e le
// variabili (ragione_sociale, motivo, elenco_prodotti) devono essere quelle
// usate nei due testi.
// ---------------------------------------------------------------------------
const
  MODELLO_EMAIL_MERCE_SPEDITA = 'richiamo_merce_spedita';
  MODELLO_EMAIL_MERCE_NON_SPEDITA = 'ritiro_merce_non_spedita';
  // Usato quando "motivo" non viene passato: il modello di email ha bisogno
  // di un valore, e una frase generica e' meglio di un invio bloccato.
  MOTIVO_EMAIL_GENERICO = 'difetto riscontrato su una materia prima utilizzata nella produzione';

// Aggiunge ad ARoot "comunicazioni" e i due conteggi. Solleva un'eccezione se
// la lettura fallisce (il chiamante la trasforma in errore del tool).
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
    // Creato subito: "comunicazioni" deve esserci anche quando e' vuoto.
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

{ TRitiroRichiamoToolProvider }

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

    // Risoluzione codice -> id (vedi commento in testa alla unit): se
    // qualche codice non si risolve, niente scrittura - stesso principio
    // "tutto o niente" gia' seguito da TServizioVendite.InterrogaVendite,
    // qui pero' a protezione di una SCRITTURA (aprire una non conformita'
    // sul lotto sbagliato sarebbe un errore di dominio grave, non solo un
    // dato mancante).
    if not RisolviCodiciLotto(LCodiciLotto, LLottiMateriaPrimaID, LProblemiJSON) then
    begin
      // Stessa forma "richiede_disambiguazione" degli altri tool provider
      // del progetto (vedi RisolviProdottoFinito in
      // uRicetteToolProvider.pas): LRoot prende possesso di LProblemiJSON
      // nel momento dell'assegnazione a LRoot.A['problemi'], quindi
      // liberare LRoot piu' sotto libera anche l'array - nessun Free
      // separato su LProblemiJSON.
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

        // Elenco AGGREGATO in radice: tutti i lotti di prodotto finito raggiunti, da tutte le
        // non conformita' aperte, senza doppioni (due lotti di materia prima possono finire
        // nello stesso lotto di prodotto finito). E' l'input diretto di
        // trova_ordini_spedizioni_lotto_prodotto_finito: con il pianificatore il collegamento
        // fra i due tool e' il riferimento "$1.lotti_prodotto_finito_id", che deve puntare a un
        // array semplice di interi - il contratto dei riferimenti non appiattisce gli array di
        // array (non_conformita_aperte[*].lotti_prodotto_finito_id). Il dettaglio per non
        // conformita' resta invariato sopra.
        LArrayTuttiPF := LRoot.A['lotti_prodotto_finito_id'];
        for LNCAperta in LEsitoApertura.NonConformitaAperte do
          for I := 0 to Length(LNCAperta.LottiProdottoFinitoIDs) - 1 do
            if not ContieneIntero(LArrayTuttiPF, LNCAperta.LottiProdottoFinitoIDs[I]) then
              LArrayTuttiPF.Add(LNCAperta.LottiProdottoFinitoIDs[I]);

        // "aperture_vista": per ogni non conformita' aperta, la vista
        // Tracciabilita' del lotto di materia prima da cui e' partita (l'albero
        // di propagazione verso semilavorati, prodotti finiti, ordini). E' un
        // ARRAY perche' una sola chiamata puo' aprire piu' non conformita';
        // ogni voce ha la forma {"vista","parametri"} di "apertura_vista"
        // (vedi uRicetteToolProvider). "modalita":"pulsante" = la chat mostra
        // un pulsante per voce invece di navigare da sola; "riferimento" e' il
        // testo che distingue un pulsante dall'altro.
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

        // Clienti da avvisare, pronti per il provider "email" (vedi
        // AggiungiComunicazioni).
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
    // Non dovrebbe succedere (TMCPServer.RegisterDynamicProvider dispatcha
    // solo i nomi restituiti da GetDynamicToolDefs), ma un fallback
    // esplicito e' piu' sicuro di un case senza else - stesso pattern gia'
    // usato in uFilesToolsProvider.pas/uRicetteToolProvider.pas.
    Result := TMCPToolResult.Error(Format(
      '"%s" non e'' un tool gestito da questo provider.', [AToolName]));
end;

// ---------------------------------------------------------------------------
// CONTRATTI DEI TOOL DI QUESTO PROVIDER (tappa 2 del porting del pianificatore,
// vedi agente_ai/tool/uContrattiTool.pas). Portati da mcp_delphi.py del prototipo:
// DEFINIZIONI (output_schema, effetto, conferma), INTEGRAZIONI_INPUT (vincoli
// sugli input) e ALMENO_UNO. Gli schemi di output descrivono le risposte
// costruite piu' sopra in questa unit: se cambia una risposta, va cambiato
// anche il suo schema qui sotto. Il test scripts/prototipo_pianificatore/tests/
// test_contratti_delphi.py li confronta con quelli del prototipo.
// ---------------------------------------------------------------------------

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
    // "comunicazioni": elementi {"email","modello","variabili"}, la stessa
    // forma che il parametro "messaggi" del provider email dichiara nel suo
    // contratto (VINCOLO_MESSAGGI in uEmailToolProvider.pas): e' cio' che
    // rende valido il riferimento "messaggi": "$N.comunicazioni".
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
