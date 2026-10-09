unit uContrattiTool;

(* ============================================================================
  CONTRATTI DEI TOOL - tappa 2 del porting del pianificatore.

  -- Che cosa e' un contratto ------------------------------------------------
  Il server MCP dichiara, per ogni tool, nome, descrizione e schema dei
  parametri di INPUT (tools/list). Al pianificatore servono in piu' quattro
  informazioni che il protocollo non porta:

    1. OutputSchema      la forma del risultato quando il tool riesce. Serve a
                         controllare, PRIMA di eseguire, i riferimenti fra i
                         passi di un piano ("$1.lotti_prodotto_finito_id":
                         il campo esiste? e' del tipo che il parametro vuole?)
                         e, DOPO, che il risultato sia quello dichiarato.
    2. Effetto           lettura o scrittura sul database.
    3. RichiedeConferma  una scrittura parte solo dopo la conferma dell'utente.
    4. Vincoli sugli input che il tool controlla nel proprio codice ma che lo
       schema del server non esprime: la forma degli elementi di un array
       (VincoliInput) e i gruppi "serve almeno uno fra" (AlmenoUno).

  Nel prototipo Python queste informazioni stavano in un file solo
  (scripts/prototipo_pianificatore/pianificatore/mcp_delphi.py: DEFINIZIONI,
  INTEGRAZIONI_INPUT, ALMENO_UNO), perche' Delphi non le dichiarava.

  -- Dove sono scritte -------------------------------------------------------
  Ogni provider dichiara i contratti dei PROPRI tool nella class function
  ContrattiTool, nella stessa unit in cui costruisce le risposte (tools/
  u...ToolProvider.pas): chi cambia la forma di una risposta ha il contratto
  sotto gli occhi. Qui ci sono solo i tipi comuni, il registro in cui i
  provider vengono raccolti all'avvio e la funzione che compone lo schema di
  input effettivo. Nessun contratto e' scritto in questa unit.

  -- Ciclo di vita -----------------------------------------------------------
  TRegistroContrattiTool.Registra va chiamato solo all'avvio, in
  uFrmMain.FormCreate, accanto alla registrazione del provider nel server MCP
  (stesso principio di TRegistroProviderMCP). Da li' in poi il registro e'
  solo letto, anche da piu' thread: nessun lock.
  ============================================================================ *)

interface

uses
  System.SysUtils,
  System.JSON,
  System.Generics.Collections;

type
  TEffettoTool = (etLettura, etScrittura);

  // Vincolo su UN parametro di input: frammento di JSON Schema che si
  // aggiunge allo schema dichiarato dal server per quel parametro.
  // Es. per "lotti_prodotto_finito_id" (che il server dichiara solo come
  // "array"): {"minItems":1,"items":{"type":"integer","minimum":1}}.
  TVincoloParametro = record
    Parametro: string;
    Schema: string;      // testo JSON
  end;

  TContrattoTool = record
    Nome: string;
    Effetto: TEffettoTool;
    // Ha senso solo per le scritture; per le letture e' False.
    RichiedeConferma: Boolean;
    // JSON Schema (testo) del risultato con esito positivo. Disambiguazioni
    // ed errori hanno una forma comune a tutti i tool e non stanno qui.
    // "required" elenca i campi SEMPRE presenti: sono gli unici a cui un
    // piano puo' fare riferimento.
    OutputSchema: string;
    VincoliInput: TArray<TVincoloParametro>;
    // Ogni gruppo e' un elenco di parametri di cui ne serve almeno uno
    // (es. prodotto_finito_id oppure nome_prodotto).
    AlmenoUno: TArray<TArray<string>>;
  end;

  TRegistroContrattiTool = class
  private
    class var FContratti: TList<TContrattoTool>;
    class constructor Create;
    class destructor Destroy;
  public
    // Registra i contratti di un provider. Solleva un'eccezione, fermando
    // l'avvio del server, se un nome e' vuoto o gia' registrato o se uno
    // schema non e' un oggetto JSON valido: un contratto sbagliato deve
    // emergere subito, non al primo piano che lo usa.
    class procedure Registra(const AContratti: TArray<TContrattoTool>);
    // False se nessun provider ha dichiarato un contratto per ANome.
    class function Trova(const ANome: string; out AContratto: TContrattoTool): Boolean;
    class function Tutti: TArray<TContrattoTool>;
  end;

// Costruttori dei record, per scrivere i contratti nei provider in forma
// compatta. AVincoliInput e AAlmenoUno si omettono quando non servono.
function VincoloParametro(const AParametro, ASchema: string): TVincoloParametro;
function ContrattoTool(const ANome: string; AEffetto: TEffettoTool;
  ARichiedeConferma: Boolean; const AOutputSchema: string;
  const AVincoliInput: TArray<TVincoloParametro> = nil;
  const AAlmenoUno: TArray<TArray<string>> = nil): TContrattoTool;

function EffettoInTesto(AEffetto: TEffettoTool): string;

// Schema di input EFFETTIVO di un tool: quello dichiarato dal server
// (ASchemaServer, il campo "parameters"/"inputSchema"; resta del chiamante)
// completato con i vincoli del contratto. E' lo schema che il validatore del
// piano usera' per controllare gli argomenti. Stessa composizione di
// _input_schema in mcp_delphi.py:
//   - "type", "properties" e "required" sempre presenti;
//   - per ogni vincolo, le chiavi del frammento sostituiscono o si aggiungono
//     a quelle del parametro;
//   - i gruppi "almeno uno" finiscono sotto la chiave "x_almeno_uno" (il
//     prefisso x_ segna le chiavi che non sono JSON Schema standard e che
//     non vanno mandate al modello).
// Il risultato e' del chiamante. Solleva un'eccezione se un vincolo nomina
// un parametro che il server non dichiara.
function SchemaInputEffettivo(const AContratto: TContrattoTool;
  ASchemaServer: TJSONObject): TJSONObject;

implementation

function VincoloParametro(const AParametro, ASchema: string): TVincoloParametro;
begin
  Result.Parametro := AParametro;
  Result.Schema := ASchema;
end;

function ContrattoTool(const ANome: string; AEffetto: TEffettoTool;
  ARichiedeConferma: Boolean; const AOutputSchema: string;
  const AVincoliInput: TArray<TVincoloParametro>;
  const AAlmenoUno: TArray<TArray<string>>): TContrattoTool;
begin
  Result.Nome := ANome;
  Result.Effetto := AEffetto;
  Result.RichiedeConferma := ARichiedeConferma;
  Result.OutputSchema := AOutputSchema;
  Result.VincoliInput := AVincoliInput;
  Result.AlmenoUno := AAlmenoUno;
end;

function EffettoInTesto(AEffetto: TEffettoTool): string;
begin
  if AEffetto = etScrittura then
    Result := 'scrittura'
  else
    Result := 'lettura';
end;

// True se ATesto e' un oggetto JSON. Usata solo alla registrazione.
function OggettoJSONValido(const ATesto: string): Boolean;
var
  LValore: TJSONValue;
begin
  LValore := TJSONObject.ParseJSONValue(ATesto);
  try
    Result := LValore is TJSONObject;
  finally
    LValore.Free;
  end;
end;

function SchemaInputEffettivo(const AContratto: TContrattoTool;
  ASchemaServer: TJSONObject): TJSONObject;
var
  LProprieta, LParametro, LFrammento: TJSONObject;
  LVincolo: TVincoloParametro;
  LCoppia, LRimossa: TJSONPair;
  LGruppi, LGruppo: TJSONArray;
  LNomi: TArray<string>;
  LNome: string;
  i: Integer;
begin
  if ASchemaServer <> nil then
    Result := ASchemaServer.Clone as TJSONObject
  else
    Result := TJSONObject.Create;
  try
    if Result.GetValue('type') = nil then
      Result.AddPair('type', 'object');
    if not (Result.GetValue('properties') is TJSONObject) then
      Result.AddPair('properties', TJSONObject.Create);
    if Result.GetValue('required') = nil then
      Result.AddPair('required', TJSONArray.Create);
    LProprieta := TJSONObject(Result.GetValue('properties'));

    for LVincolo in AContratto.VincoliInput do
    begin
      if not (LProprieta.GetValue(LVincolo.Parametro) is TJSONObject) then
        raise Exception.CreateFmt(
          'Contratto di "%s": il vincolo sul parametro "%s" non corrisponde a nessun ' +
          'parametro dichiarato dal server.', [AContratto.Nome, LVincolo.Parametro]);
      LParametro := TJSONObject(LProprieta.GetValue(LVincolo.Parametro));

      LFrammento := TJSONObject.ParseJSONValue(LVincolo.Schema) as TJSONObject;
      try
        for i := 0 to LFrammento.Count - 1 do
        begin
          LCoppia := LFrammento.Pairs[i];
          // La chiave del frammento prevale su quella del server.
          LRimossa := LParametro.RemovePair(LCoppia.JsonString.Value);
          LRimossa.Free;
          LParametro.AddPair(LCoppia.JsonString.Value, LCoppia.JsonValue.Clone as TJSONValue);
        end;
      finally
        LFrammento.Free;
      end;
    end;

    if Length(AContratto.AlmenoUno) > 0 then
    begin
      LGruppi := TJSONArray.Create;
      Result.AddPair('x_almeno_uno', LGruppi);
      for LNomi in AContratto.AlmenoUno do
      begin
        LGruppo := TJSONArray.Create;
        LGruppi.AddElement(LGruppo);
        for LNome in LNomi do
          LGruppo.Add(LNome);
      end;
    end;
  except
    Result.Free;
    raise;
  end;
end;

{ TRegistroContrattiTool }

class constructor TRegistroContrattiTool.Create;
begin
  FContratti := TList<TContrattoTool>.Create;
end;

class destructor TRegistroContrattiTool.Destroy;
begin
  FContratti.Free;
end;

class procedure TRegistroContrattiTool.Registra(const AContratti: TArray<TContrattoTool>);
var
  LContratto, LEsistente: TContrattoTool;
  LVincolo: TVincoloParametro;
begin
  for LContratto in AContratti do
  begin
    if Trim(LContratto.Nome) = '' then
      raise Exception.Create('TRegistroContrattiTool.Registra: contratto senza nome del tool.');
    if Trova(LContratto.Nome, LEsistente) then
      raise Exception.CreateFmt(
        'TRegistroContrattiTool.Registra: il contratto di "%s" e'' gia'' registrato.',
        [LContratto.Nome]);
    if not OggettoJSONValido(LContratto.OutputSchema) then
      raise Exception.CreateFmt(
        'TRegistroContrattiTool.Registra: l''output_schema di "%s" non e'' un oggetto JSON valido.',
        [LContratto.Nome]);
    for LVincolo in LContratto.VincoliInput do
      if not OggettoJSONValido(LVincolo.Schema) then
        raise Exception.CreateFmt(
          'TRegistroContrattiTool.Registra: il vincolo di "%s" sul parametro "%s" non e'' un ' +
          'oggetto JSON valido.', [LContratto.Nome, LVincolo.Parametro]);
    FContratti.Add(LContratto);
  end;
end;

class function TRegistroContrattiTool.Trova(const ANome: string;
  out AContratto: TContrattoTool): Boolean;
var
  LContratto: TContrattoTool;
begin
  for LContratto in FContratti do
    if SameText(LContratto.Nome, ANome) then
    begin
      AContratto := LContratto;
      Exit(True);
    end;
  Result := False;
end;

class function TRegistroContrattiTool.Tutti: TArray<TContrattoTool>;
begin
  Result := FContratti.ToArray;
end;

end.
