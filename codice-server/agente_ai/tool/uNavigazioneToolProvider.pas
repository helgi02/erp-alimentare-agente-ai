unit uNavigazioneToolProvider;

(* ============================================================================
  TNavigazioneToolProvider — tool MCP generico apri_vista: permette al
  modello di segnalare "apri questa schermata del gestionale, per questa
  entita'", senza che questo file sappia nulla di ricette, vendite o
  ritiro/richiamo.

  ── Perche' e' un tool "dinamico" (come TFilesToolsProvider) ────────────────
  I parametri "vista" (string) e "motivo" (string) sarebbero esprimibili
  anche come argomenti Pascal via RTTI ([MCPTool]/[MCPParam], vedi
  TVenditeToolProvider), ma "parametri" no: e' un oggetto la cui FORMA
  (quali chiavi contiene) dipende da QUALE vista e' stata scelta — non c'e'
  un tipo Pascal fisso dietro. Per questo, come generate_csv/generate_pdf,
  il tool si dichiara con GetDynamicToolDefs e si esegue con InvokeDynamic,
  leggendo "arguments" a mano con l'API di JsonDataObjects.

  ── Da dove viene sapere QUALI viste esistono ───────────────────────────────
  Da TRegistroViste (common/uRegistroViste.pas), popolato ESPLICITAMENTE in
  uFrmMain.FormCreate da ciascun tool provider di scenario che possiede una
  vista sensata da aprire (non tutti: e' il singolo provider a deciderlo in
  base al proprio dominio, vedi commento in testa a uRegistroViste.pas).
  Questo file legge SOLO quel registro, sia per costruire la descrizione del
  tool (cosi' il modello sa quali nomi di vista sono validi e cosa serve per
  ciascuna) sia per validare la richiesta in InvokeDynamic — stessa fonte
  per le due cose, per costruzione non possono disallinearsi.

  Finche' nessun tool provider di scenario registra ancora una vista (cioe'
  finche' TRicetteToolProvider, che possiedera' 'ricetta_prodotto_finito',
  non esiste), questo tool e' gia' presente e funzionante ma il registro e'
  vuoto: qualunque chiamata restituisce l'errore "nessuna vista disponibile"
  invece di un crash — comportamento corretto, non un bug.

  ── Cosa fa DAVVERO Execute (poco) ──────────────────────────────────────────
  Nessuna logica applicativa, nessun accesso al DB: solo validazione (la
  vista richiesta esiste? i parametri obbligatori per quella vista ci sono
  tutti?) e poi eco della richiesta in un tool_result JSON. La vera
  navigazione la esegue il FRONTEND, leggendo il campo tool_calls della
  risposta finale (stato "concluso") di POST /api/ai/turni/passo (vedi AIAgentControllerU e il
  commento li' sopra su tool_calls) e trovandoci una chiamata ad apri_vista
  con esito "ok": e' un segnale che attraversa la stessa risposta HTTP
  gia' usata per il testo della conversazione, non serve un canale a parte
  (nessun websocket/push: la conversazione e' gia' request/response
  sincrona all'interno dello stesso giro).
  ============================================================================ *)

interface

uses
  System.SysUtils,
  JsonDataObjects,
  MVCFramework.MCP.ToolProvider,
  uContrattiTool,
  uRegistroViste;

type
  TNavigazioneToolProvider = class(TMCPToolProvider)
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

// Elenco dei nomi di vista registrati, separati da virgola — usato sia nella
// descrizione del tool sia nei messaggi di errore di InvokeDynamic, cosi'
// il modello vede sempre gli stessi nomi validi in entrambi i posti.
function ElencoNomiViste: string;
var
  LViste: TArray<TDefinizioneVista>;
  LNomi: TArray<string>;
  I: Integer;
begin
  LViste := TRegistroViste.GetAll;
  if Length(LViste) = 0 then
    Exit('(nessuna vista disponibile al momento)');

  SetLength(LNomi, Length(LViste));
  for I := 0 to High(LViste) do
    LNomi[I] := LViste[I].Nome;

  Result := string.Join(', ', LNomi);
end;

// Una riga descrittiva per vista, con le sue chiavi richieste — righe unite
// da GetDynamicToolDefs per formare la parte "elenco viste" della
// descrizione del tool.
function DescriviVista(const AVista: TDefinizioneVista): string;
var
  LChiaviTesto: string;
begin
  if Length(AVista.ChiaviRichieste) = 0 then
    LChiaviTesto := 'nessuno'
  else
    LChiaviTesto := string.Join(', ', AVista.ChiaviRichieste);

  Result := Format('- "%s": %s (parametri richiesti: %s)',
    [AVista.Nome, AVista.Descrizione, LChiaviTesto]);
end;

// Le chiavi di ADefinizione.ChiaviRichieste assenti in AParametri, nell'ordine
// in cui compaiono nella definizione — usata da InvokeDynamic per costruire
// un messaggio di errore puntuale invece di un generico "parametri non validi".
function ChiaviMancanti(const ADefinizione: TDefinizioneVista;
  AParametri: TJDOJsonObject): TArray<string>;
var
  LChiave: string;
  LMancanti: TArray<string>;
begin
  LMancanti := [];
  for LChiave in ADefinizione.ChiaviRichieste do
    if not AParametri.Contains(LChiave) then
      LMancanti := LMancanti + [LChiave];

  Result := LMancanti;
end;

{ TNavigazioneToolProvider }

function TNavigazioneToolProvider.GetDynamicToolDefs: TArray<TMCPDynamicToolDef>;

  function DefParam(const AName, ADescription: string; ARequired: Boolean;
    const AJsonSchemaType: string): TMCPDynamicParamDef;
  begin
    Result.Name := AName;
    Result.Description := ADescription;
    Result.Required := ARequired;
    Result.JsonSchemaType := AJsonSchemaType;
  end;

  function DescriviTutteLeViste: string;
  var
    LViste: TArray<TDefinizioneVista>;
    LRighe: TArray<string>;
    LVista: TDefinizioneVista;
  begin
    LViste := TRegistroViste.GetAll;

    if Length(LViste) = 0 then
      Exit('Nessuna vista disponibile.');

    LRighe := [];
    for LVista in LViste do
      LRighe := LRighe + [DescriviVista(LVista)];

    Result := string.Join(#10, LRighe);
  end;

begin
  SetLength(Result, 1);

  Result[0].Name := 'apri_vista';
  Result[0].Description :=
    'Apre nel gestionale la vista indicata, permettendo all''utente di visualizzare ' +
    'il risultato di un''operazione. La vista deve essere una di quelle elencate ' +
    'di seguito:'#10 +
    DescriviTutteLeViste;

  Result[0].ControllerClassName := 'TNavigazioneToolProvider';

  Result[0].Params := TArray<TMCPDynamicParamDef>.Create(
    DefParam(
      'vista',
      'Nome esatto della vista da aprire, scelto tra quelle elencate nella descrizione del tool.',
      True,
      'string'
    ),
    DefParam(
      'parametri',
      'Parametri richiesti dalla vista scelta, secondo la relativa definizione nell''elenco delle viste.',
      True,
      'object'
    ),
    DefParam(
      'motivo',
      'Motivo dell''apertura della vista, opzionale.',
      False,
      'string'
    )
  );
end;

function TNavigazioneToolProvider.InvokeDynamic(const AToolName: string;
  AArguments: TJDOJsonObject): TMCPToolResult;
var
  LNomeVista: string;
  LDefinizione: TDefinizioneVista;
  LParametri: TJDOJsonObject;
  LMancanti: TArray<string>;
  LRisultato: TJDOJsonObject;
begin
  if AArguments = nil then
    Exit(TMCPToolResult.Error(
      'Argomenti mancanti: servono "vista" e "parametri". Viste disponibili: ' +
      ElencoNomiViste + '.'));

  LNomeVista := Trim(AArguments.S['vista']);
  if LNomeVista = '' then
    Exit(TMCPToolResult.Error(
      'Parametro "vista" mancante o vuoto. Viste disponibili: ' + ElencoNomiViste + '.'));

  if not TRegistroViste.Find(LNomeVista, LDefinizione) then
    Exit(TMCPToolResult.Error(Format(
      '"%s" non e'' una vista conosciuta. Viste disponibili: %s.',
      [LNomeVista, ElencoNomiViste])));

  if not (AArguments.Contains('parametri') and (AArguments.Types['parametri'] = jdtObject)) then
    Exit(TMCPToolResult.Error(Format(
      'Parametro "parametri" mancante o non e'' un oggetto. La vista "%s" richiede: %s.',
      [LNomeVista, string.Join(', ', LDefinizione.ChiaviRichieste)])));

  LParametri := AArguments.O['parametri'];

  LMancanti := ChiaviMancanti(LDefinizione, LParametri);
  if Length(LMancanti) > 0 then
    Exit(TMCPToolResult.Error(Format(
      'Parametri mancanti per la vista "%s": %s.',
      [LNomeVista, string.Join(', ', LMancanti)])));

  // Nessuna scrittura, nessun accesso al DB: solo eco della richiesta gia'
  // validata. "parametri" viene ricostruito da testo (Parse su ToJSON)
  // invece di essere riassegnato per riferimento: LParametri appartiene ad
  // AArguments (di proprieta' del chiamante), stesso principio "si passa
  // per il testo fra oggetti JSON di proprieta' diverse" gia' seguito in
  // uMCPBridge fra System.JSON e JsonDataObjects — qui evita che due
  // oggetti (AArguments e LRisultato) finiscano a condividere lo stesso
  // sotto-oggetto con proprietari diversi.
  LRisultato := TJDOJsonObject.Create;
  try
    LRisultato.S['esito'] := 'ok';
    LRisultato.S['vista'] := LNomeVista;
    LRisultato.O['parametri'] := TJDOJsonObject.Parse(LParametri.ToJSON) as TJDOJsonObject;
    if AArguments.Contains('motivo') then
      LRisultato.S['motivo'] := AArguments.S['motivo'];

    Result := TMCPToolResult.Text(LRisultato.ToJSON);
  finally
    LRisultato.Free;
  end;
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
  SCHEMA_OUTPUT_APRI_VISTA =
    '{"type":"object","properties":{"esito":{"type":"string","enum":["ok"]},' +
    '"vista":{"type":"string"},"parametri":{"type":"object"}},"required":["esito",' +
    '"vista","parametri"]}';

class function TNavigazioneToolProvider.ContrattiTool: TArray<TContrattoTool>;
begin
  Result := TArray<TContrattoTool>.Create(
    ContrattoTool('apri_vista', etLettura, False,
      SCHEMA_OUTPUT_APRI_VISTA));
end;

end.
