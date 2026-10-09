unit uContrattiTool;

// Contratti dei tool per il pianificatore.
// Il server MCP dichiara per ogni tool nome, descrizione e schema di input. Al
// pianificatore servono in piu': OutputSchema (forma del risultato, per controllare i
// riferimenti fra i passi prima di eseguire e il risultato dopo), Effetto (lettura o
// scrittura), RichiedeConferma (una scrittura parte solo dopo la conferma dell'utente) e i
// vincoli sugli input che lo schema del server non esprime (forma degli elementi di un
// array, gruppi "serve almeno uno fra").
// Ogni provider dichiara i contratti dei propri tool in ContrattiTool, nella stessa unit
// che costruisce le risposte: chi cambia una risposta ha il contratto sotto gli occhi. Qui
// ci sono solo i tipi comuni, il registro e la composizione dello schema di input.
// Registra va chiamato solo all'avvio, in FormCreate, accanto alla registrazione del
// provider MCP; poi il registro e' solo letto, anche da piu' thread, senza lock.

interface

uses
  System.SysUtils,
  System.JSON,
  System.Generics.Collections;

type
  TEffettoTool = (etLettura, etScrittura);

  // Vincolo su un parametro: frammento di JSON Schema aggiunto a quello del server. Es. per
  // "lotti_prodotto_finito_id" (per il server solo "array"):
  // {"minItems":1,"items":{"type":"integer","minimum":1}}.
  TVincoloParametro = record
    Parametro: string;
    Schema: string;      // testo JSON
  end;

  TContrattoTool = record
    Nome: string;
    Effetto: TEffettoTool;
    // Solo per le scritture.
    RichiedeConferma: Boolean;
    // JSON Schema del risultato con esito positivo (disambiguazioni ed errori hanno una
    // forma comune e non stanno qui). "required" elenca i campi sempre presenti: gli unici
    // a cui un piano puo' fare riferimento.
    OutputSchema: string;
    VincoliInput: TArray<TVincoloParametro>;
    // Ogni gruppo elenca parametri di cui ne serve almeno uno (es. prodotto_finito_id
    // oppure nome_prodotto).
    AlmenoUno: TArray<TArray<string>>;
  end;

  TRegistroContrattiTool = class
  private
    class var FContratti: TList<TContrattoTool>;
    class constructor Create;
    class destructor Destroy;
  public
    // Registra i contratti di un provider. Solleva un'eccezione, fermando l'avvio, se un
    // nome e' vuoto o duplicato o uno schema non e' un oggetto JSON: un contratto sbagliato
    // deve emergere subito, non al primo piano che lo usa.
    class procedure Registra(const AContratti: TArray<TContrattoTool>);
    // False se nessun provider ha dichiarato un contratto per ANome.
    class function Trova(const ANome: string; out AContratto: TContrattoTool): Boolean;
    class function Tutti: TArray<TContrattoTool>;
  end;

// Costruttori per scrivere i contratti in forma compatta; AVincoliInput e AAlmenoUno si
// omettono se non servono.
function VincoloParametro(const AParametro, ASchema: string): TVincoloParametro;
function ContrattoTool(const ANome: string; AEffetto: TEffettoTool;
  ARichiedeConferma: Boolean; const AOutputSchema: string;
  const AVincoliInput: TArray<TVincoloParametro> = nil;
  const AAlmenoUno: TArray<TArray<string>> = nil): TContrattoTool;

function EffettoInTesto(AEffetto: TEffettoTool): string;

// Schema di input effettivo di un tool: quello del server (ASchemaServer, resta del
// chiamante) completato con i vincoli del contratto. Le chiavi del frammento sostituiscono
// o si aggiungono a quelle del parametro; i gruppi "almeno uno" vanno sotto "x_almeno_uno"
// (il prefisso x_ segna le chiavi non standard, da non mandare al modello). Solleva
// un'eccezione se un vincolo nomina un parametro che il server non dichiara.
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
