unit uModelStabilimento;

interface

uses
  System.SysUtils,
  System.Generics.Collections,
  Data.DB, System.JSON, System.DateUtils,
  DbU;

type
  // Rappresenta uno stabilimento produttivo dell'azienda. E' identificato
  // nello schema ER dal solo codice CE (codice di riconoscimento
  // dello stabilimento ai sensi del Reg. CE 853/2004), senza una
  // denominazione propria: e' il dato che compare in etichetta e nei
  // documenti di richiamo (scenario "ritiro/richiamo prodotti non
  // conformi"), quindi va trattato come chiave di business oltre che
  // come semplice attributo descrittivo.
  TStabilimento = class
  private
    FID: Integer;
    FCodiceCE: string;
    FVia: string;
    FCitta: string;
    FProvincia: string;
    FCap: string;
    FPaese: string;
    FCreatoIl: TDateTime;
    FAggiornatoIl: TDateTime;

    procedure LoadFromDataSet(ADataSet: TDataSet);
  public
    constructor Create;

    property ID: Integer read FID write FID;
    property CodiceCE: string read FCodiceCE write FCodiceCE;
    property Via: string read FVia write FVia;
    property Citta: string read FCitta write FCitta;
    property Provincia: string read FProvincia write FProvincia;
    property Cap: string read FCap write FCap;
    property Paese: string read FPaese write FPaese;

    // Campi di audit: sola lettura, gestiti dal database (default/trigger
    // trg_stabilimenti_aggiornato_il)
    property CreatoIl: TDateTime read FCreatoIl;
    property AggiornatoIl: TDateTime read FAggiornatoIl;

    // Operazioni CRUD
    class function GetByID(AID: Integer): TStabilimento;
    class function GetByCodiceCE(const ACodiceCE: string): TStabilimento;
    class function GetAll: TObjectList<TStabilimento>;
    class function Delete(AID: Integer): Boolean;

    function Insert: Integer;   // restituisce l'ID generato
    function Update: Boolean;
    function Save: Boolean;     // Insert o Update a seconda che FID sia valorizzato
    function ToJSONObject: TJSONObject;
    procedure FromJSONObject(AJSON: TJSONObject);

  end;

implementation

const
  SQL_SELECT_BASE =
    'SELECT id, codice_ce, via, citta, provincia, cap, paese, ' +
    'creato_il, aggiornato_il ' +
    'FROM stabilimenti ';

{ TStabilimento }

constructor TStabilimento.Create;
begin
  inherited Create;
  FID := 0;
  FPaese := 'Italia'; // replica il DEFAULT lato database per i nuovi record
end;

procedure TStabilimento.LoadFromDataSet(ADataSet: TDataSet);
begin
  FID        := ADataSet.FieldByName('id').AsInteger;
  FCodiceCE  := ADataSet.FieldByName('codice_ce').AsString;
  FVia       := ADataSet.FieldByName('via').AsString;
  FCitta     := ADataSet.FieldByName('citta').AsString;
  FProvincia := ADataSet.FieldByName('provincia').AsString;
  FCap       := ADataSet.FieldByName('cap').AsString;
  FPaese     := ADataSet.FieldByName('paese').AsString;
  FCreatoIl     := ADataSet.FieldByName('creato_il').AsDateTime;
  FAggiornatoIl := ADataSet.FieldByName('aggiornato_il').AsDateTime;
end;

class function TStabilimento.GetByID(AID: Integer): TStabilimento;
var
  LAutoQuery: TAutoQuery;
begin
  Result := nil;

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE id = :id', [AID]);
  try
    if not LAutoQuery.Query.IsEmpty then
    begin
      Result := TStabilimento.Create;
      Result.LoadFromDataSet(LAutoQuery.Query);
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TStabilimento.GetByCodiceCE(const ACodiceCE: string): TStabilimento;
var
  LAutoQuery: TAutoQuery;
begin
  Result := nil;

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE codice_ce = :codice_ce', [ACodiceCE]);
  try
    if not LAutoQuery.Query.IsEmpty then
    begin
      Result := TStabilimento.Create;
      Result.LoadFromDataSet(LAutoQuery.Query);
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TStabilimento.GetAll: TObjectList<TStabilimento>;
var
  LAutoQuery: TAutoQuery;
  LStabilimento: TStabilimento;
begin
  Result := TObjectList<TStabilimento>.Create(True); // possiede gli oggetti

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'ORDER BY codice_ce');
  try
    while not LAutoQuery.Query.Eof do
    begin
      LStabilimento := TStabilimento.Create;
      LStabilimento.LoadFromDataSet(LAutoQuery.Query);
      Result.Add(LStabilimento);
      LAutoQuery.Query.Next;
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TStabilimento.Delete(AID: Integer): Boolean;
begin
  // Stabilimento e' referenziato da LOTTI_SEMILAVORATI e
  // LOTTI_PRODOTTI_FINITI (campo stabilimento_id): in assenza di
  // ON DELETE CASCADE lato DB, la query fallisce se esistono lotti
  // prodotti in questo stabilimento. Comportamento voluto.
  Result := TDB.GetInstance.executeQuery(
    'DELETE FROM stabilimenti WHERE id = :id', [AID]);
end;

function TStabilimento.Insert: Integer;
var
  LAutoQuery: TAutoQuery;
begin
  // creato_il e aggiornato_il NON compaiono tra i campi inseriti:
  // sono valorizzati dal DEFAULT del database (now()).
  // codice_ce ha un vincolo UNIQUE (stabilimenti_codice_ce_key): un
  // eventuale duplicato solleva un'eccezione che va gestita a livello
  // di controller, come gia' fatto per partita_iva in TFornitore.
  LAutoQuery := TDB.GetInstance.getQueryResult(
    'INSERT INTO stabilimenti (codice_ce, via, citta, provincia, cap, paese) ' +
    'VALUES (:codice_ce, :via, :citta, :provincia, :cap, :paese) ' +
    'RETURNING id, creato_il, aggiornato_il',
    [FCodiceCE, FVia, FCitta, FProvincia, FCap, FPaese]);
  try
    FID           := LAutoQuery.Query.FieldByName('id').AsInteger;
    FCreatoIl     := LAutoQuery.Query.FieldByName('creato_il').AsDateTime;
    FAggiornatoIl := LAutoQuery.Query.FieldByName('aggiornato_il').AsDateTime;
    Result := FID;
  finally
    LAutoQuery.Free;
  end;
end;

function TStabilimento.Update: Boolean;
var
  LAutoQuery: TAutoQuery;
begin
  // aggiornato_il NON viene impostato esplicitamente: il trigger
  // trg_stabilimenti_aggiornato_il lo valorizza automaticamente.
  // Lo rileggiamo tramite RETURNING per mantenere l'oggetto coerente
  // con lo stato effettivo sul database.
  LAutoQuery := TDB.GetInstance.getQueryResult(
    'UPDATE stabilimenti SET codice_ce = :codice_ce, via = :via, citta = :citta, ' +
    'provincia = :provincia, cap = :cap, paese = :paese ' +
    'WHERE id = :id ' +
    'RETURNING aggiornato_il',
    [FCodiceCE, FVia, FCitta, FProvincia, FCap, FPaese, FID]);
  try
    Result := not LAutoQuery.Query.IsEmpty;
    if Result then
      FAggiornatoIl := LAutoQuery.Query.FieldByName('aggiornato_il').AsDateTime;
  finally
    LAutoQuery.Free;
  end;
end;

function TStabilimento.Save: Boolean;
begin
  if FID = 0 then
  begin
    Insert;
    Result := FID > 0;
  end
  else
    Result := Update;
end;

function TStabilimento.ToJSONObject: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('id', TJSONNumber.Create(FID));
  Result.AddPair('codice_ce', FCodiceCE);
  Result.AddPair('via', FVia);
  Result.AddPair('citta', FCitta);
  Result.AddPair('provincia', FProvincia);
  Result.AddPair('cap', FCap);
  Result.AddPair('paese', FPaese);
  Result.AddPair('creato_il', DateToISO8601(FCreatoIl));
  Result.AddPair('aggiornato_il', DateToISO8601(FAggiornatoIl));
end;

procedure TStabilimento.FromJSONObject(AJSON: TJSONObject);
begin
  // id NON viene letto dal payload in ingresso: e' gestito dal database,
  // mai dal client
  if AJSON.TryGetValue<string>('codice_ce', FCodiceCE) then ;
  if AJSON.TryGetValue<string>('via', FVia) then ;
  if AJSON.TryGetValue<string>('citta', FCitta) then ;
  if AJSON.TryGetValue<string>('provincia', FProvincia) then ;
  if AJSON.TryGetValue<string>('cap', FCap) then ;
  if AJSON.TryGetValue<string>('paese', FPaese) then ;
end;

end.
