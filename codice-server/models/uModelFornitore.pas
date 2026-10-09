unit uModelFornitore;

interface

uses
  System.SysUtils,
  System.Variants,
  System.Generics.Collections,
  Data.DB, System.JSON, System.DateUtils,
  DbU;

type
  TFornitore = class
  private
    FID: Integer;
    FRagioneSociale: string;
    FPartitaIva: string;
    FEmail: string;
    FTelefono: string;
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
    property RagioneSociale: string read FRagioneSociale write FRagioneSociale;
    property PartitaIva: string read FPartitaIva write FPartitaIva;
    property Email: string read FEmail write FEmail;
    property Telefono: string read FTelefono write FTelefono;
    property Via: string read FVia write FVia;
    property Citta: string read FCitta write FCitta;
    property Provincia: string read FProvincia write FProvincia;
    property Cap: string read FCap write FCap;
    property Paese: string read FPaese write FPaese;

    // Campi di audit: sola lettura, gestiti dal database (default/trigger)
    property CreatoIl: TDateTime read FCreatoIl;
    property AggiornatoIl: TDateTime read FAggiornatoIl;

    // Operazioni CRUD
    class function GetByID(AID: Integer): TFornitore;
    class function GetAll: TObjectList<TFornitore>;
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
    'SELECT id, ragione_sociale, partita_iva, email, telefono, ' +
    'via, citta, provincia, cap, paese, creato_il, aggiornato_il ' +
    'FROM fornitori ';

{ TFornitore }

constructor TFornitore.Create;
begin
  inherited Create;
  FID := 0;
  FPaese := 'Italia'; // replica il DEFAULT lato database per i nuovi record
end;

procedure TFornitore.LoadFromDataSet(ADataSet: TDataSet);
begin
  FID             := ADataSet.FieldByName('id').AsInteger;
  FRagioneSociale := ADataSet.FieldByName('ragione_sociale').AsString;
  FPartitaIva     := ADataSet.FieldByName('partita_iva').AsString;
  FEmail          := ADataSet.FieldByName('email').AsString;
  FTelefono       := ADataSet.FieldByName('telefono').AsString;
  FVia            := ADataSet.FieldByName('via').AsString;
  FCitta          := ADataSet.FieldByName('citta').AsString;
  FProvincia      := ADataSet.FieldByName('provincia').AsString;
  FCap            := ADataSet.FieldByName('cap').AsString;
  FPaese          := ADataSet.FieldByName('paese').AsString;
  FCreatoIl       := ADataSet.FieldByName('creato_il').AsDateTime;
  FAggiornatoIl   := ADataSet.FieldByName('aggiornato_il').AsDateTime;
end;

class function TFornitore.GetByID(AID: Integer): TFornitore;
var
  LAutoQuery: TAutoQuery;
begin
  Result := nil;

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE id = :id', [AID]);
  try
    if not LAutoQuery.Query.IsEmpty then
    begin
      Result := TFornitore.Create;
      Result.LoadFromDataSet(LAutoQuery.Query);
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TFornitore.GetAll: TObjectList<TFornitore>;
var
  LAutoQuery: TAutoQuery;
  LFornitore: TFornitore;
begin
  Result := TObjectList<TFornitore>.Create(True); // possiede gli oggetti

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'ORDER BY ragione_sociale');
  try
    while not LAutoQuery.Query.Eof do
    begin
      LFornitore := TFornitore.Create;
      LFornitore.LoadFromDataSet(LAutoQuery.Query);
      Result.Add(LFornitore);
      LAutoQuery.Query.Next;
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TFornitore.Delete(AID: Integer): Boolean;
begin
  Result := TDB.GetInstance.executeQuery(
    'DELETE FROM fornitori WHERE id = :id', [AID]);
end;

function TFornitore.Insert: Integer;
var
  LAutoQuery: TAutoQuery;
begin
  // creato_il e aggiornato_il NON compaiono tra i campi inseriti:
  // sono valorizzati dal DEFAULT del database (now())
  LAutoQuery := TDB.GetInstance.getQueryResult(
    'INSERT INTO fornitori ' +
    '(ragione_sociale, partita_iva, email, telefono, via, citta, provincia, cap, paese) ' +
    'VALUES (:ragione_sociale, :partita_iva, :email, :telefono, :via, :citta, :provincia, :cap, :paese) ' +
    'RETURNING id, creato_il, aggiornato_il',
    [FRagioneSociale, FPartitaIva, FEmail, FTelefono, FVia, FCitta, FProvincia, FCap, FPaese]);
  try
    FID           := LAutoQuery.Query.FieldByName('id').AsInteger;
    FCreatoIl     := LAutoQuery.Query.FieldByName('creato_il').AsDateTime;
    FAggiornatoIl := LAutoQuery.Query.FieldByName('aggiornato_il').AsDateTime;
    Result := FID;
  finally
    LAutoQuery.Free;
  end;
end;

function TFornitore.Update: Boolean;
var
  LAutoQuery: TAutoQuery;
begin
  // aggiornato_il NON viene impostato esplicitamente: il trigger
  // trg_fornitori_aggiornato_il lo valorizza automaticamente.
  // Lo rileggiamo tramite RETURNING per mantenere l'oggetto coerente
  // con lo stato effettivo sul database.
  LAutoQuery := TDB.GetInstance.getQueryResult(
    'UPDATE fornitori SET ragione_sociale = :ragione_sociale, partita_iva = :partita_iva, ' +
    'email = :email, telefono = :telefono, via = :via, citta = :citta, ' +
    'provincia = :provincia, cap = :cap, paese = :paese ' +
    'WHERE id = :id ' +
    'RETURNING aggiornato_il',
    [FRagioneSociale, FPartitaIva, FEmail, FTelefono, FVia, FCitta, FProvincia, FCap, FPaese, FID]);
  try
    Result := not LAutoQuery.Query.IsEmpty;
    if Result then
      FAggiornatoIl := LAutoQuery.Query.FieldByName('aggiornato_il').AsDateTime;
  finally
    LAutoQuery.Free;
  end;
end;

function TFornitore.Save: Boolean;
begin
  if FID = 0 then
  begin
    Insert;
    Result := FID > 0;
  end
  else
    Result := Update;
end;

function TFornitore.ToJSONObject: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('id', TJSONNumber.Create(FID));
  Result.AddPair('ragione_sociale', FRagioneSociale);
  Result.AddPair('partita_iva', FPartitaIva);
  Result.AddPair('email', FEmail);
  Result.AddPair('telefono', FTelefono);
  Result.AddPair('via', FVia);
  Result.AddPair('citta', FCitta);
  Result.AddPair('provincia', FProvincia);
  Result.AddPair('cap', FCap);
  Result.AddPair('paese', FPaese);
  Result.AddPair('creato_il', DateToISO8601(FCreatoIl));
  Result.AddPair('aggiornato_il', DateToISO8601(FAggiornatoIl));
end;

procedure TFornitore.FromJSONObject(AJSON: TJSONObject);
begin
  // id, creato_il, aggiornato_il NON vengono letti dal payload in ingresso:
  // sono gestiti dal database, mai dal client
  if AJSON.TryGetValue<string>('ragione_sociale', FRagioneSociale) then ;
  if AJSON.TryGetValue<string>('partita_iva', FPartitaIva) then ;
  if AJSON.TryGetValue<string>('email', FEmail) then ;
  if AJSON.TryGetValue<string>('telefono', FTelefono) then ;
  if AJSON.TryGetValue<string>('via', FVia) then ;
  if AJSON.TryGetValue<string>('citta', FCitta) then ;
  if AJSON.TryGetValue<string>('provincia', FProvincia) then ;
  if AJSON.TryGetValue<string>('cap', FCap) then ;
  if AJSON.TryGetValue<string>('paese', FPaese) then ;
end;

end.
