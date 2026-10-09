unit uPianificatore;

// Pianificatore: Planner e Completer.
// Il modello non esegue tool e non vede dati: trasforma la richiesta in un PIANO, cioe' un
// esito e un elenco di passi.
// esito: 'operativa' (servono dati o operazioni), 'conversazionale' (saluti, domande
// sull'assistente), 'fuori_ambito' (argomenti estranei al gestionale).
// risposta: testo per l'utente, solo se l'esito non e' operativa.
// passi: solo se operativa; per ogni passo un'azione a parole e, se il modello sa gia'
// quale tool usare (uno dei "tool noti"), tool e argomenti. Con il tool il passo e'
// CONCRETO, senza e' ASTRATTO e va completato.
// Due chiamate: PLANNER (storico + richiesta -> piano) e COMPLETER (solo se ci sono passi
// astratti: stessa conversazione del Planner piu' i tool candidati del retrieval; sceglie
// tool e argomenti). Il Completer e' una continuazione, cosi' il motore riusa la cache.
// Entrambe usano l'output vincolato (schema_risposta).
// Questa unit non chiama il modello: prepara le richieste e legge le risposte, controllando
// solo la FORMA (tool, parametri e riferimenti li controlla il validatore). La chiamata la
// fa uServiziAgente. I testi dei prompt stanno in uPromptPianificatore.pas.

interface

uses
  System.SysUtils,
  System.JSON,
  System.Generics.Collections;

const
  ESITO_OPERATIVA = 'operativa';
  ESITO_CONVERSAZIONALE = 'conversazionale';
  ESITO_FUORI_AMBITO = 'fuori_ambito';

type
  // Risposta non conforme alla forma richiesta. Codici: PIANO_NON_CONFORME,
  // PASSO_INCOMPLETO, PASSO_DOPPIO.
  EContrattoPiano = class(Exception)
  private
    FCodice: string;
    FMessaggio: string;
  public
    constructor Create(const ACodice, AMessaggio: string);
    property Codice: string read FCodice;
    property Messaggio: string read FMessaggio;
  end;

  TPasso = class
  public
    Id: Integer;
    Azione: string;
    // '' = passo astratto (nessun tool scelto).
    Tool: string;
    // nil se il passo e' astratto. Di proprieta' del passo.
    Argomenti: TJSONObject;
    // Passi precedenti di cui questo usa il risultato.
    Dipendenze: TArray<Integer>;
    destructor Destroy; override;
    function Concreto: Boolean;
    // {"id","azione","tool","argomenti","dipendenze"} - del chiamante.
    function ToJSON: TJSONObject;
  end;

  TPiano = class
  public
    Esito: string;
    // Solo per gli esiti non operativi.
    Risposta: string;
    Passi: TObjectList<TPasso>;
    constructor Create;
    destructor Destroy; override;
    // {"esito","risposta","passi"} - del chiamante.
    function ToJSON: TJSONObject;
  end;

  // Tool candidati per un passo astratto (li produce il retrieval).
  TCandidatiPasso = record
    Id: Integer;
    Azione: string;
    Tool: TArray<string>;
  end;

  TPianificatore = class
  public
    // Prompt di sistema comune a tutte le fasi: identita', data di oggi
    // (AAAA-MM-GG) ed elenco dei provider con la loro descrizione.
    class function PromptBase(const AOggi: string): string;

    // Come un tool viene mostrato al modello: nome, descrizione, effetto, schema di input
    // (server + vincoli del contratto) e di output. Solleva un'eccezione se il tool non e'
    // nel catalogo o non ha un contratto.
    class function ToolPerLLM(const ANomeTool: string): TJSONObject;

    // True se il tool esiste nel catalogo e ha un contratto.
    class function ToolConosciuto(const ANomeTool: string): Boolean;

    // Schema di input effettivo (server + vincoli del contratto, con la chiave interna
    // x_almeno_uno) e di output, usati da validatore ed esecutore. Sollevano un'eccezione
    // se il tool e' sconosciuto.
    class function SchemaInputTool(const ANomeTool: string): TJSONObject;
    class function SchemaOutputTool(const ANomeTool: string): TJSONObject;

    // PLANNER. Richiesta per TClientLLM.Completa: { messages: [sistema, utente],
    // schema_risposta }.
    // AStorico: turni precedenti in testo. AToolNoti: tool gia' usati con successo; solo
    // con questi il modello puo' scrivere tool e argomenti direttamente (gli altri sono
    // ignorati).
    class function RichiestaPiano(const AStorico, ADomanda, AOggi: string;
      const AToolNoti: TArray<string>): TJSONObject;

    // Testo restituito dal modello (choices[0].message.content; '' se manca).
    class function TestoRisposta(ARisposta: TJSONObject): string;

    // Controlla la FORMA del piano e lo costruisce. Solleva EContrattoPiano
    // (PIANO_NON_CONFORME). Il risultato e' del chiamante.
    class function LeggiPiano(const ATesto: string): TPiano;

    // COMPLETER. Richiesta per TClientLLM.Completa.
    // AMessaggiPiano: messaggi del Planner piu' il messaggio 'assistant' con il piano
    // com'e' stato scritto (copiati).
    // ACandidati: una voce per passo astratto, in ordine.
    class function RichiestaCompletamento(AMessaggiPiano: TJSONArray;
      const ACandidati: TArray<TCandidatiPasso>): TJSONObject;

    // Legge la risposta del Completer e scrive tool e argomenti nei passi astratti. Deve
    // coprire esattamente i passi di ACandidati: PIANO_NON_CONFORME se tocca altri passi o
    // e' malformata, PASSO_INCOMPLETO se ne salta uno, PASSO_DOPPIO se ne duplica uno. In
    // caso di errore il piano non cambia.
    class procedure ApplicaCompletamento(APiano: TPiano; const ATesto: string;
      const ACandidati: TArray<TCandidatiPasso>);

    // Seconda e ultima richiesta al Completer dopo un PASSO_DOPPIO: la stessa richiesta,
    // piu' la risposta data e un messaggio che spiega l'errore. ARichiesta e' copiata.
    class function RichiestaCorrezioneCompletamento(ARichiesta: TJSONObject;
      const ARispostaPrecedente, AProblema: string): TJSONObject;
  end;

// JSON scritto come json.dumps di Python con ensure_ascii=False (", " fra gli elementi, ":
// " dopo le chiavi, accenti non trasformati in \uXXXX), per avere prompt identici carattere
// per carattere a quelli di riferimento.
function JSONComePython(AValore: TJSONValue): string;

implementation

uses
  System.Generics.Defaults,
  uSchemaJSON,
  uCatalogoTool,
  uContrattiTool,
  uRegistroProviderMCP,
  uPromptPianificatore;

function StringaJSON(const ATesto: string): string;
var
  LBuilder: TStringBuilder;
  LCarattere: Char;
begin
  LBuilder := TStringBuilder.Create;
  try
    LBuilder.Append('"');
    for LCarattere in ATesto do
      case LCarattere of
        '"': LBuilder.Append('\"');
        '\': LBuilder.Append('\\');
        #8:  LBuilder.Append('\b');
        #9:  LBuilder.Append('\t');
        #10: LBuilder.Append('\n');
        #12: LBuilder.Append('\f');
        #13: LBuilder.Append('\r');
      else
        if LCarattere < #32 then
          LBuilder.Append('\u').Append(LowerCase(IntToHex(Ord(LCarattere), 4)))
        else
          LBuilder.Append(LCarattere);
      end;
    LBuilder.Append('"');
    Result := LBuilder.ToString;
  finally
    LBuilder.Free;
  end;
end;

function JSONComePython(AValore: TJSONValue): string;
var
  LPezzi: TList<string>;
  LCoppia: TJSONPair;
  LTipo: string;
  i: Integer;
begin
  LTipo := TipoJSON(AValore);
  if LTipo = '' then
    Exit('null');
  if LTipo = 'string' then
    Exit(StringaJSON(AValore.Value));
  if (LTipo = 'integer') or (LTipo = 'number') then
    Exit(AValore.ToString);
  if LTipo = 'boolean' then
  begin
    if TJSONBool(AValore).AsBoolean then
      Exit('true');
    Exit('false');
  end;

  LPezzi := TList<string>.Create;
  try
    if LTipo = 'object' then
    begin
      for LCoppia in TJSONObject(AValore) do
        LPezzi.Add(StringaJSON(LCoppia.JsonString.Value) + ': ' + JSONComePython(LCoppia.JsonValue));
      Result := '{' + string.Join(', ', LPezzi.ToArray) + '}';
    end
    else
    begin
      for i := 0 to TJSONArray(AValore).Count - 1 do
        LPezzi.Add(JSONComePython(TJSONArray(AValore).Items[i]));
      Result := '[' + string.Join(', ', LPezzi.ToArray) + ']';
    end;
  finally
    LPezzi.Free;
  end;
end;

// Voce "function" del catalogo per ANome (name, description, parameters).
// Riferimento interno al catalogo: non va liberato. nil se non c'e'.
function FunzioneDelCatalogo(const ANome: string): TJSONObject;
var
  LVoce, LFunzione: TJSONValue;
begin
  Result := nil;
  for LVoce in TCatalogoTool.Definizioni do
  begin
    if not (LVoce is TJSONObject) then
      Continue;
    LFunzione := TJSONObject(LVoce).GetValue('function');
    if (LFunzione is TJSONObject) and (TestoCampo(TJSONObject(LFunzione), 'name') = ANome) then
      Exit(TJSONObject(LFunzione));
  end;
end;

function Messaggio(const ARuolo, AContenuto: string): TJSONObject;
begin
  Result := TJSONObject.Create.AddPair('role', ARuolo).AddPair('content', AContenuto);
end;

function ElencoNomi(const ANomi: TArray<string>): string;
var
  LArray: TJSONArray;
  LNome: string;
begin
  LArray := TJSONArray.Create;
  try
    for LNome in ANomi do
      LArray.Add(LNome);
    Result := LArray.ToString;
  finally
    LArray.Free;
  end;
end;

constructor EContrattoPiano.Create(const ACodice, AMessaggio: string);
begin
  inherited Create(ACodice + ': ' + AMessaggio);
  FCodice := ACodice;
  FMessaggio := AMessaggio;
end;

destructor TPasso.Destroy;
begin
  Argomenti.Free;
  inherited;
end;

function TPasso.Concreto: Boolean;
begin
  Result := Tool <> '';
end;

function TPasso.ToJSON: TJSONObject;
var
  LDipendenze: TJSONArray;
  LDipendenza: Integer;
begin
  Result := TJSONObject.Create;
  Result.AddPair('id', TJSONNumber.Create(Id));
  Result.AddPair('azione', Azione);
  if Concreto then
    Result.AddPair('tool', Tool)
  else
    Result.AddPair('tool', TJSONNull.Create);
  if Argomenti <> nil then
    Result.AddPair('argomenti', Argomenti.Clone as TJSONValue)
  else
    Result.AddPair('argomenti', TJSONNull.Create);
  LDipendenze := TJSONArray.Create;
  for LDipendenza in Dipendenze do
    LDipendenze.Add(LDipendenza);
  Result.AddPair('dipendenze', LDipendenze);
end;

constructor TPiano.Create;
begin
  inherited;
  Passi := TObjectList<TPasso>.Create(True);
end;

destructor TPiano.Destroy;
begin
  Passi.Free;
  inherited;
end;

function TPiano.ToJSON: TJSONObject;
var
  LPassi: TJSONArray;
  LPasso: TPasso;
begin
  Result := TJSONObject.Create;
  Result.AddPair('esito', Esito);
  if Risposta <> '' then
    Result.AddPair('risposta', Risposta)
  else
    Result.AddPair('risposta', TJSONNull.Create);
  LPassi := TJSONArray.Create;
  for LPasso in Passi do
    LPassi.AddElement(LPasso.ToJSON);
  Result.AddPair('passi', LPassi);
end;

class function TPianificatore.PromptBase(const AOggi: string): string;
var
  LProvider: TDescrizioneProviderMCP;
begin
  Result := PROMPT_BASE_INIZIO + AOggi + PROMPT_BASE_DOPO_DATA;
  for LProvider in TRegistroProviderMCP.Tutte do
    Result := Result + '- ' + LProvider.Nome + ': ' + LProvider.Descrizione + #10;
end;

class function TPianificatore.ToolConosciuto(const ANomeTool: string): Boolean;
var
  LContratto: TContrattoTool;
begin
  Result := (FunzioneDelCatalogo(ANomeTool) <> nil) and
    TRegistroContrattiTool.Trova(ANomeTool, LContratto);
end;

class function TPianificatore.SchemaInputTool(const ANomeTool: string): TJSONObject;
var
  LFunzione: TJSONObject;
  LContratto: TContrattoTool;
begin
  LFunzione := FunzioneDelCatalogo(ANomeTool);
  if (LFunzione = nil) or not TRegistroContrattiTool.Trova(ANomeTool, LContratto) then
    raise Exception.CreateFmt('Il tool "%s" non e'' nel catalogo o non ha un contratto.', [ANomeTool]);
  if LFunzione.GetValue('parameters') is TJSONObject then
    Result := SchemaInputEffettivo(LContratto, TJSONObject(LFunzione.GetValue('parameters')))
  else
    Result := SchemaInputEffettivo(LContratto, nil);
end;

class function TPianificatore.SchemaOutputTool(const ANomeTool: string): TJSONObject;
var
  LContratto: TContrattoTool;
begin
  if not TRegistroContrattiTool.Trova(ANomeTool, LContratto) then
    raise Exception.CreateFmt('Il tool "%s" non ha un contratto.', [ANomeTool]);
  Result := TJSONObject.ParseJSONValue(LContratto.OutputSchema) as TJSONObject;
end;

class function TPianificatore.ToolPerLLM(const ANomeTool: string): TJSONObject;
var
  LFunzione, LSchemaInput: TJSONObject;
  LContratto: TContrattoTool;
  LParametri: TJSONValue;
  LRimossa: TJSONPair;
begin
  LFunzione := FunzioneDelCatalogo(ANomeTool);
  if (LFunzione = nil) or not TRegistroContrattiTool.Trova(ANomeTool, LContratto) then
    raise Exception.CreateFmt('Il tool "%s" non e'' nel catalogo o non ha un contratto.', [ANomeTool]);

  LParametri := LFunzione.GetValue('parameters');
  if LParametri is TJSONObject then
    LSchemaInput := SchemaInputEffettivo(LContratto, TJSONObject(LParametri))
  else
    LSchemaInput := SchemaInputEffettivo(LContratto, nil);
  // Le chiavi interne (prefisso x_) servono al validatore, non al modello.
  LRimossa := LSchemaInput.RemovePair('x_almeno_uno');
  LRimossa.Free;

  Result := TJSONObject.Create;
  Result.AddPair('nome', ANomeTool);
  Result.AddPair('descrizione', TestoCampo(LFunzione, 'description'));
  Result.AddPair('effetto', EffettoInTesto(LContratto.Effetto));
  Result.AddPair('input_schema', LSchemaInput);
  Result.AddPair('output_schema', TJSONObject.ParseJSONValue(LContratto.OutputSchema));
end;

// Schema dell'output del Planner. "tool" puo' essere solo null o il nome di
// un tool noto: il modello non puo' scrivere un tool che non ha mai usato.
function SchemaPiano(const AToolNoti: TArray<string>): TJSONObject;
const
  SCHEMA =
    '{"type":"object","properties":{' +
    '"esito":{"type":"string","enum":["operativa","conversazionale","fuori_ambito"]},' +
    '"risposta":{"anyOf":[{"type":"null"},{"type":"string"}]},' +
    '"passi":{"type":"array","items":{"type":"object","properties":{' +
    '"id":{"type":"integer"},"azione":{"type":"string"},' +
    '"dipendenze":{"type":"array","items":{"type":"integer"}},' +
    '"tool":@@TOOL@@,' +
    '"argomenti":{"anyOf":[{"type":"null"},{"type":"object"}]}},' +
    '"required":["id","azione","dipendenze","tool","argomenti"]}}},' +
    '"required":["esito","risposta","passi"]}';
var
  LTool: string;
begin
  if Length(AToolNoti) = 0 then
    LTool := '{"type":"null"}'
  else
    LTool := '{"anyOf":[{"type":"null"},{"type":"string","enum":' + ElencoNomi(AToolNoti) + '}]}';
  Result := TJSONObject.ParseJSONValue(StringReplace(SCHEMA, '@@TOOL@@', LTool, [])) as TJSONObject;
end;

class function TPianificatore.RichiestaPiano(const AStorico, ADomanda, AOggi: string;
  const AToolNoti: TArray<string>): TJSONObject;
var
  LNoti: TArray<string>;
  LNome, LSistema: string;
  LTool: TJSONObject;
  LMessaggi: TJSONArray;
begin
  LNoti := nil;
  for LNome in AToolNoti do
    if ToolConosciuto(LNome) then
      LNoti := LNoti + [LNome];

  LSistema := PromptBase(AOggi) + PROMPT_SEZIONE_PIANO;
  if Length(LNoti) = 0 then
    LSistema := LSistema + PROMPT_PIANO_SENZA_TOOL_NOTI
  else
  begin
    LSistema := LSistema + PROMPT_PIANO_TOOL_NOTI;
    for LNome in LNoti do
    begin
      LTool := ToolPerLLM(LNome);
      try
        LSistema := LSistema + JSONComePython(LTool) + #10;
      finally
        LTool.Free;
      end;
    end;
  end;

  LMessaggi := TJSONArray.Create;
  LMessaggi.AddElement(Messaggio('system', LSistema));
  LMessaggi.AddElement(Messaggio('user',
    PROMPT_MESSAGGIO_PIANO_STORICO + AStorico + PROMPT_MESSAGGIO_PIANO_RICHIESTA + ADomanda));

  Result := TJSONObject.Create;
  Result.AddPair('messages', LMessaggi);
  Result.AddPair('schema_risposta', TJSONObject.Create
    .AddPair('nome', 'piano')
    .AddPair('schema', SchemaPiano(LNoti)));
end;

class function TPianificatore.TestoRisposta(ARisposta: TJSONObject): string;
var
  LScelte, LMessaggio, LContenuto: TJSONValue;
begin
  Result := '';
  if ARisposta = nil then
    Exit;
  LScelte := ARisposta.GetValue('choices');
  if not (LScelte is TJSONArray) or (TJSONArray(LScelte).Count = 0) or
     not (TJSONArray(LScelte).Items[0] is TJSONObject) then
    Exit;
  LMessaggio := TJSONObject(TJSONArray(LScelte).Items[0]).GetValue('message');
  if not (LMessaggio is TJSONObject) then
    Exit;
  LContenuto := TJSONObject(LMessaggio).GetValue('content');
  if (LContenuto <> nil) and not (LContenuto is TJSONNull) then
    Result := LContenuto.Value;
end;

// True se AValore e' assente o null (il modello scrive null per "niente").
function Assente(AValore: TJSONValue): Boolean;
begin
  Result := (AValore = nil) or (AValore is TJSONNull);
end;

class function TPianificatore.LeggiPiano(const ATesto: string): TPiano;
var
  LRadice, LValore, LTool, LArgomenti, LDipendenze, LId: TJSONValue;
  LOggetto, LPassoJSON: TJSONObject;
  LPassi: TJSONArray;
  LEsito, LRisposta, LAzione: string;
  LPasso: TPasso;
  i, j: Integer;
begin
  LRadice := TJSONObject.ParseJSONValue(ATesto);
  try
    if LRadice = nil then
      raise EContrattoPiano.Create('PIANO_NON_CONFORME', 'JSON non valido');
    if not (LRadice is TJSONObject) then
      raise EContrattoPiano.Create('PIANO_NON_CONFORME', 'il piano non e'' un oggetto');
    LOggetto := TJSONObject(LRadice);

    LEsito := TestoCampo(LOggetto, 'esito');
    if (LEsito <> ESITO_OPERATIVA) and (LEsito <> ESITO_CONVERSAZIONALE) and
       (LEsito <> ESITO_FUORI_AMBITO) then
      raise EContrattoPiano.Create('PIANO_NON_CONFORME', Format('esito ''%s'' non valido', [LEsito]));

    LValore := LOggetto.GetValue('passi');
    LPassi := nil;
    if not Assente(LValore) then
    begin
      if not (LValore is TJSONArray) then
        raise EContrattoPiano.Create('PIANO_NON_CONFORME', 'passi non e'' un array');
      LPassi := TJSONArray(LValore);
    end;

    LRisposta := '';
    if LEsito = ESITO_OPERATIVA then
    begin
      if (LPassi = nil) or (LPassi.Count = 0) then
        raise EContrattoPiano.Create('PIANO_NON_CONFORME', 'esito operativa senza passi');
    end
    else
    begin
      LValore := LOggetto.GetValue('risposta');
      if (TipoJSON(LValore) <> 'string') or (Trim(LValore.Value) = '') then
        raise EContrattoPiano.Create('PIANO_NON_CONFORME', Format('esito %s senza risposta', [LEsito]));
      LRisposta := LValore.Value;
      // Un piano non operativo non esegue niente, anche se il modello ha
      // scritto dei passi.
      LPassi := nil;
    end;

    Result := TPiano.Create;
    try
      Result.Esito := LEsito;
      Result.Risposta := LRisposta;

      if LPassi <> nil then
        for i := 0 to LPassi.Count - 1 do
        begin
          if not (LPassi.Items[i] is TJSONObject) then
            raise EContrattoPiano.Create('PIANO_NON_CONFORME', Format('passo %d non e'' un oggetto', [i + 1]));
          LPassoJSON := TJSONObject(LPassi.Items[i]);

          LValore := LPassoJSON.GetValue('azione');
          if (TipoJSON(LValore) <> 'string') or (Trim(LValore.Value) = '') then
            raise EContrattoPiano.Create('PIANO_NON_CONFORME', Format('passo %d senza azione', [i + 1]));
          LAzione := Trim(LValore.Value);

          LTool := LPassoJSON.GetValue('tool');
          LArgomenti := LPassoJSON.GetValue('argomenti');
          // Tool senza argomenti (o viceversa): si tratta come astratto
          // invece di scartare il piano. Lo completeranno retrieval e Completer.
          if Assente(LTool) <> Assente(LArgomenti) then
          begin
            LTool := nil;
            LArgomenti := nil;
          end;
          if not Assente(LArgomenti) and not (LArgomenti is TJSONObject) then
            raise EContrattoPiano.Create('PIANO_NON_CONFORME',
              Format('passo %d: argomenti non e'' un oggetto', [i + 1]));

          LDipendenze := LPassoJSON.GetValue('dipendenze');
          if not Assente(LDipendenze) then
          begin
            if not (LDipendenze is TJSONArray) then
              raise EContrattoPiano.Create('PIANO_NON_CONFORME',
                Format('passo %d: dipendenze non valide', [i + 1]));
            for j := 0 to TJSONArray(LDipendenze).Count - 1 do
              if TipoJSON(TJSONArray(LDipendenze).Items[j]) <> 'integer' then
                raise EContrattoPiano.Create('PIANO_NON_CONFORME',
                  Format('passo %d: dipendenze non valide', [i + 1]));
          end;

          LId := LPassoJSON.GetValue('id');
          if TipoJSON(LId) <> 'integer' then
            raise EContrattoPiano.Create('PIANO_NON_CONFORME', Format('passo %d: id mancante', [i + 1]));

          LPasso := TPasso.Create;
          Result.Passi.Add(LPasso);
          LPasso.Id := TJSONNumber(LId).AsInt;
          LPasso.Azione := LAzione;
          if not Assente(LTool) then
          begin
            LPasso.Tool := LTool.Value;
            LPasso.Argomenti := LArgomenti.Clone as TJSONObject;
          end;
          if not Assente(LDipendenze) then
            for j := 0 to TJSONArray(LDipendenze).Count - 1 do
              LPasso.Dipendenze := LPasso.Dipendenze +
                [TJSONNumber(TJSONArray(LDipendenze).Items[j]).AsInt];
        end;
    except
      Result.Free;
      raise;
    end;
  finally
    LRadice.Free;
  end;
end;

// Schema dell'output del Completer: solo gli id dei passi astratti, solo i
// tool candidati.
function SchemaCompletamento(const ACandidati: TArray<TCandidatiPasso>): TJSONObject;
var
  LIds: TArray<Integer>;
  LNomi: TList<string>;
  LOrdinati: TArray<string>;
  LVoce: TCandidatiPasso;
  LNome, LElencoId: string;
  LId: Integer;
begin
  LNomi := TList<string>.Create;
  try
    LIds := nil;
    for LVoce in ACandidati do
    begin
      LIds := LIds + [LVoce.Id];
      for LNome in LVoce.Tool do
        if not LNomi.Contains(LNome) then
          LNomi.Add(LNome);
    end;
    LOrdinati := LNomi.ToArray;
  finally
    LNomi.Free;
  end;
  // Ordine per codice dei caratteri, come sorted() di Python.
  TArray.Sort<string>(LOrdinati, TComparer<string>.Construct(
    function(const L, R: string): Integer
    begin
      Result := CompareStr(L, R);
    end));
  TArray.Sort<Integer>(LIds);

  LElencoId := '';
  for LId in LIds do
  begin
    if LElencoId <> '' then
      LElencoId := LElencoId + ',';
    LElencoId := LElencoId + IntToStr(LId);
  end;

  Result := TJSONObject.ParseJSONValue(
    '{"type":"object","properties":{"passi":{"type":"array","items":{"type":"object","properties":{' +
    '"id":{"type":"integer","enum":[' + LElencoId + ']},' +
    '"tool":{"type":"string","enum":' + ElencoNomi(LOrdinati) + '},' +
    '"argomenti":{"type":"object"}},"required":["id","tool","argomenti"]}}},' +
    '"required":["passi"]}') as TJSONObject;
end;

class function TPianificatore.RichiestaCompletamento(AMessaggiPiano: TJSONArray;
  const ACandidati: TArray<TCandidatiPasso>): TJSONObject;
var
  LTesto: string;
  LVoce: TCandidatiPasso;
  LVisti: TList<string>;
  LNome: string;
  LDefinizione, LFunzione: TJSONValue;
  LTool: TJSONObject;
  LMessaggi: TJSONArray;
begin
  LVisti := TList<string>.Create;
  try
    LTesto := PROMPT_COMPLETAMENTO_INTESTAZIONE;
    for LVoce in ACandidati do
    begin
      LTesto := LTesto + Format('PASSO %d: %s', [LVoce.Id, LVoce.Azione]) + #10 +
        '  candidati: ' + string.Join(', ', LVoce.Tool) + #10;
      for LNome in LVoce.Tool do
        if not LVisti.Contains(LNome) then
          LVisti.Add(LNome);
    end;
    LTesto := LTesto + PROMPT_COMPLETAMENTO_SCHEMI;

    // Schemi nell'ordine del catalogo e non dei candidati, cosi' il testo non dipende dai
    // punteggi.
    for LDefinizione in TCatalogoTool.Definizioni do
    begin
      if not (LDefinizione is TJSONObject) then
        Continue;
      LFunzione := TJSONObject(LDefinizione).GetValue('function');
      if not (LFunzione is TJSONObject) then
        Continue;
      LNome := TestoCampo(TJSONObject(LFunzione), 'name');
      if not LVisti.Contains(LNome) then
        Continue;
      LTool := ToolPerLLM(LNome);
      try
        LTesto := LTesto + #10 + JSONComePython(LTool);
      finally
        LTool.Free;
      end;
    end;
  finally
    LVisti.Free;
  end;

  // Continuazione della conversazione del Planner: stessi messaggi, piu' uno.
  LMessaggi := AMessaggiPiano.Clone as TJSONArray;
  LMessaggi.AddElement(Messaggio('user', LTesto));

  Result := TJSONObject.Create;
  Result.AddPair('messages', LMessaggi);
  Result.AddPair('schema_risposta', TJSONObject.Create
    .AddPair('nome', 'completamento')
    .AddPair('schema', SchemaCompletamento(ACandidati)));
end;

class procedure TPianificatore.ApplicaCompletamento(APiano: TPiano; const ATesto: string;
  const ACandidati: TArray<TCandidatiPasso>);
var
  LRadice, LPassi, LVoce, LId: TJSONValue;
  LScelte: TDictionary<Integer, TJSONObject>;   // id del passo -> voce della risposta
  LCandidato: TCandidatiPasso;
  LPasso: TPasso;
  LMancanti, LDoppi: string;
  LAstratto: Boolean;
  i: Integer;
begin
  LDoppi := '';
  LRadice := TJSONObject.ParseJSONValue(ATesto);
  LScelte := TDictionary<Integer, TJSONObject>.Create;
  try
    if LRadice = nil then
      raise EContrattoPiano.Create('PIANO_NON_CONFORME', 'JSON non valido');
    LPassi := nil;
    if LRadice is TJSONObject then
      LPassi := TJSONObject(LRadice).GetValue('passi');
    if not (LPassi is TJSONArray) then
      raise EContrattoPiano.Create('PIANO_NON_CONFORME', 'completamento senza passi');

    for i := 0 to TJSONArray(LPassi).Count - 1 do
    begin
      LVoce := TJSONArray(LPassi).Items[i];
      if not (LVoce is TJSONObject) or
         (TipoJSON(TJSONObject(LVoce).GetValue('tool')) <> 'string') or
         not (TJSONObject(LVoce).GetValue('argomenti') is TJSONObject) then
        raise EContrattoPiano.Create('PIANO_NON_CONFORME',
          'passo di completamento malformato: ' + LVoce.ToString);

      LId := TJSONObject(LVoce).GetValue('id');
      LAstratto := False;
      if TipoJSON(LId) = 'integer' then
        for LCandidato in ACandidati do
          if LCandidato.Id = TJSONNumber(LId).AsInt then
            LAstratto := True;
      if not LAstratto then
        raise EContrattoPiano.Create('PIANO_NON_CONFORME',
          Format('il completamento tocca il passo %s, che non e'' astratto', [JSONComePython(LId)]));
      // Controllo di difesa: lo stesso passo scritto due volte e' ambiguo (ne' la prima ne'
      // l'ultima voce e' quella giusta), quindi il codice non sceglie: segnala PASSO_DOPPIO
      // e il turno chiede al modello di correggersi una volta
      // (TTurnoPianificato.PassoCompletamento).
      if LScelte.ContainsKey(TJSONNumber(LId).AsInt) then
      begin
        // Due voci identiche (stesso tool e stessi argomenti) non sono ambigue: la seconda
        // si ignora. Il confronto e' sul testo JSON: argomenti in ordine diverso risultano
        // diversi e passano dalla correzione.
        if (TestoCampo(LScelte[TJSONNumber(LId).AsInt], 'tool') = TestoCampo(TJSONObject(LVoce), 'tool')) and
           (LScelte[TJSONNumber(LId).AsInt].GetValue('argomenti').ToJSON =
            TJSONObject(LVoce).GetValue('argomenti').ToJSON) then
          Continue;
        // Ogni passo ambiguo compare una sola volta nel messaggio, anche se scritto piu'
        // volte.
        if not (', ' + LDoppi + ',').Contains(', ' + IntToStr(TJSONNumber(LId).AsInt) + ',') then
        begin
          if LDoppi <> '' then
            LDoppi := LDoppi + ', ';
          LDoppi := LDoppi + IntToStr(TJSONNumber(LId).AsInt);
        end;
      end
      else
        LScelte.Add(TJSONNumber(LId).AsInt, TJSONObject(LVoce));
    end;
    if LDoppi <> '' then
      raise EContrattoPiano.Create('PASSO_DOPPIO', 'piu'' voci per lo stesso passo: [' + LDoppi + ']');

    LMancanti := '';
    for LCandidato in ACandidati do
      if not LScelte.ContainsKey(LCandidato.Id) then
      begin
        if LMancanti <> '' then
          LMancanti := LMancanti + ', ';
        LMancanti := LMancanti + IntToStr(LCandidato.Id);
      end;
    if LMancanti <> '' then
      raise EContrattoPiano.Create('PASSO_INCOMPLETO', 'passi non completati: [' + LMancanti + ']');

    // Tutto in regola: solo ora si scrive nel piano.
    for LPasso in APiano.Passi do
      if not LPasso.Concreto and LScelte.ContainsKey(LPasso.Id) then
      begin
        LPasso.Tool := TestoCampo(LScelte[LPasso.Id], 'tool');
        LPasso.Argomenti.Free;
        LPasso.Argomenti := LScelte[LPasso.Id].GetValue('argomenti').Clone as TJSONObject;
      end;
  finally
    LScelte.Free;
    LRadice.Free;
  end;
end;

class function TPianificatore.RichiestaCorrezioneCompletamento(ARichiesta: TJSONObject;
  const ARispostaPrecedente, AProblema: string): TJSONObject;
var
  LMessaggi: TJSONValue;
begin
  // Stessi messaggi e schema della prima richiesta: il modello vede cosa ha scritto e
  // perche' non va.
  Result := ARichiesta.Clone as TJSONObject;
  LMessaggi := Result.GetValue('messages');
  if LMessaggi is TJSONArray then
  begin
    TJSONArray(LMessaggi).AddElement(Messaggio('assistant', ARispostaPrecedente));
    TJSONArray(LMessaggi).AddElement(Messaggio('user',
      'La risposta non e'' valida: ' + AProblema + '. Ogni passo deve comparire UNA SOLA volta, ' +
      'con UN SOLO tool. Per ciascun passo scegli il tool che esegue l''azione di quel passo e ' +
      'riscrivi la risposta completa, nello stesso formato.'));
  end;
end;

end.
