unit uNavigazioneToolProvider;

// Tool MCP generico apri_vista: il modello chiede di aprire una schermata del gestionale
// per un'entita', senza che questo file sappia nulla di ricette o vendite.
// Provider dinamico: "vista" e "motivo" sarebbero RTTI, ma "parametri" e' un oggetto la cui
// forma dipende dalla vista scelta, quindi non ha un tipo Pascal fisso (GetDynamicToolDefs
// + InvokeDynamic).
// Le viste valide vengono solo da TRegistroViste (popolato in FormCreate dai provider di
// scenario). La stessa fonte serve per la descrizione del tool e per la validazione, quindi
// non possono disallinearsi. Con il registro vuoto ogni chiamata restituisce "nessuna vista
// disponibile": corretto, non un bug.
// Execute non ha logica ne' accesso al DB: valida la vista e i parametri obbligatori e fa
// eco della richiesta. La navigazione la fa il frontend, leggendo tool_calls nella risposta
// "concluso" di POST /api/ai/turni/passo: serve una chiamata ad apri_vista con esito "ok",
// senza un canale separato.

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
    // Contratti dei tool per il pianificatore (vedi uContrattiTool.pas e il fondo di questa
    // unit).
    class function ContrattiTool: TArray<TContrattoTool>;
  end;

implementation

// Nomi di vista registrati, separati da virgola: stessi nomi nella descrizione del tool e
// negli errori.
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

// Una riga per vista con le chiavi richieste, per la descrizione del tool.
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

// Chiavi richieste assenti in AParametri, per un errore puntuale.
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

  // Nessuna scrittura: eco della richiesta validata. "parametri" e' ricostruito da testo
  // (Parse su ToJSON) perche' appartiene ad AArguments: riassegnarlo farebbe condividere lo
  // stesso sotto-oggetto a due proprietari.
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

// Contratti (vedi uContrattiTool.pas). Gli schemi di output descrivono le risposte
// costruite sopra: se cambia una risposta, va cambiato anche lo schema.

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
