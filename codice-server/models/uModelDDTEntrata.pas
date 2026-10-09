unit uModelDDTEntrata;

interface

uses
  System.SysUtils,
  System.Generics.Collections,
  Data.DB, System.JSON, System.DateUtils,
  DbU;

type
  // Testata di un DDT di entrata da un fornitore (ddt_entrata). Le sue righe generano i
  // lotti di materia prima: e' l'origine documentale di ogni lotto, punto di partenza della
  // tracciabilita' a ritroso.
  // DataEmissione (il fornitore emette) e DataRicezione (la merce arriva) sono eventi
  // diversi: la prima serve alla tracciabilita' documentale, la seconda alla logistica.
  TDDTEntrata = class
  private
    FID: Integer;
    FNumeroDDT: string;
    FDataEmissione: TDateTime;
    FDataRicezione: TDateTime;
    FFornitoreID: Integer;
    FNote: string;
    FCreatoIl: TDateTime;
    FAggiornatoIl: TDateTime;

    procedure LoadFromDataSet(ADataSet: TDataSet);
  public
    constructor Create;

    property ID: Integer read FID write FID;
    property NumeroDDT: string read FNumeroDDT write FNumeroDDT;
    property DataEmissione: TDateTime read FDataEmissione write FDataEmissione;
    property DataRicezione: TDateTime read FDataRicezione write FDataRicezione;
    property FornitoreID: Integer read FFornitoreID write FFornitoreID;
    property Note: string read FNote write FNote;

    property CreatoIl: TDateTime read FCreatoIl;
    property AggiornatoIl: TDateTime read FAggiornatoIl;

    class function GetByID(AID: Integer): TDDTEntrata;
    class function GetByNumero(const ANumeroDDT: string; AFornitoreID: Integer): TDDTEntrata;
    class function GetAll: TObjectList<TDDTEntrata>;
    class function GetByFornitore(AFornitoreID: Integer): TObjectList<TDDTEntrata>;
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
    'SELECT id, numero_ddt, data_emissione, data_ricezione, fornitore_id, ' +
    'note, creato_il, aggiornato_il ' +
    'FROM ddt_entrata ';

constructor TDDTEntrata.Create;
begin
  inherited Create;
  FID := 0;
end;

procedure TDDTEntrata.LoadFromDataSet(ADataSet: TDataSet);
begin
  FID            := ADataSet.FieldByName('id').AsInteger;
  FNumeroDDT     := ADataSet.FieldByName('numero_ddt').AsString;
  FDataEmissione := ADataSet.FieldByName('data_emissione').AsDateTime;
  FDataRicezione := ADataSet.FieldByName('data_ricezione').AsDateTime;
  FFornitoreID   := ADataSet.FieldByName('fornitore_id').AsInteger;
  FNote          := ADataSet.FieldByName('note').AsString;
  FCreatoIl      := ADataSet.FieldByName('creato_il').AsDateTime;
  FAggiornatoIl  := ADataSet.FieldByName('aggiornato_il').AsDateTime;
end;

class function TDDTEntrata.GetByID(AID: Integer): TDDTEntrata;
var
  LAutoQuery: TAutoQuery;
begin
  Result := nil;

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE id = :id', [AID]);
  try
    if not LAutoQuery.Query.IsEmpty then
    begin
      Result := TDDTEntrata.Create;
      Result.LoadFromDataSet(LAutoQuery.Query);
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TDDTEntrata.GetByNumero(const ANumeroDDT: string; AFornitoreID: Integer): TDDTEntrata;
var
  LAutoQuery: TAutoQuery;
begin
  // numero_ddt e' univoco solo insieme a fornitore_id (uq_ddt_entrata_numero_fornitore):
  // ogni fornitore numera per conto suo.
  Result := nil;

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE numero_ddt = :numero_ddt ' +
    'AND fornitore_id = :fornitore_id',
    [ANumeroDDT, AFornitoreID]);
  try
    if not LAutoQuery.Query.IsEmpty then
    begin
      Result := TDDTEntrata.Create;
      Result.LoadFromDataSet(LAutoQuery.Query);
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TDDTEntrata.GetAll: TObjectList<TDDTEntrata>;
var
  LAutoQuery: TAutoQuery;
  LDDT: TDDTEntrata;
begin
  Result := TObjectList<TDDTEntrata>.Create(True); // possiede gli oggetti

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'ORDER BY data_ricezione DESC');
  try
    while not LAutoQuery.Query.Eof do
    begin
      LDDT := TDDTEntrata.Create;
      LDDT.LoadFromDataSet(LAutoQuery.Query);
      Result.Add(LDDT);
      LAutoQuery.Query.Next;
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TDDTEntrata.GetByFornitore(AFornitoreID: Integer): TObjectList<TDDTEntrata>;
var
  LAutoQuery: TAutoQuery;
  LDDT: TDDTEntrata;
begin
  // Storico DDT di un fornitore, dal piu' recente. Serve nel richiamo per trovare il
  // fornitore di una materia prima non conforme.
  Result := TObjectList<TDDTEntrata>.Create(True);

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE fornitore_id = :fornitore_id ' +
    'ORDER BY data_ricezione DESC',
    [AFornitoreID]);
  try
    while not LAutoQuery.Query.Eof do
    begin
      LDDT := TDDTEntrata.Create;
      LDDT.LoadFromDataSet(LAutoQuery.Query);
      Result.Add(LDDT);
      LAutoQuery.Query.Next;
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TDDTEntrata.Delete(AID: Integer): Boolean;
begin
  // Fallisce se il DDT ha righe (e lotti generati): nessun ON DELETE CASCADE. Voluto, e' un
  // dato fiscale e di tracciabilita'.
  Result := TDB.GetInstance.executeQuery(
    'DELETE FROM ddt_entrata WHERE id = :id', [AID]);
end;

function TDDTEntrata.Insert: Integer;
var
  LAutoQuery: TAutoQuery;
begin
  // creato_il/aggiornato_il: DEFAULT del database. Un duplicato sul vincolo UNIQUE solleva
  // un'eccezione da gestire nel controller.
  LAutoQuery := TDB.GetInstance.getQueryResult(
    'INSERT INTO ddt_entrata ' +
    '(numero_ddt, data_emissione, data_ricezione, fornitore_id, note) ' +
    'VALUES (:numero_ddt, :data_emissione, :data_ricezione, :fornitore_id, :note) ' +
    'RETURNING id, creato_il, aggiornato_il',
    [FNumeroDDT, FDataEmissione, FDataRicezione, FFornitoreID, FNote]);
  try
    FID           := LAutoQuery.Query.FieldByName('id').AsInteger;
    FCreatoIl     := LAutoQuery.Query.FieldByName('creato_il').AsDateTime;
    FAggiornatoIl := LAutoQuery.Query.FieldByName('aggiornato_il').AsDateTime;
    Result := FID;
  finally
    LAutoQuery.Free;
  end;
end;

function TDDTEntrata.Update: Boolean;
var
  LAutoQuery: TAutoQuery;
begin
  // aggiornato_il lo imposta il trigger.
  LAutoQuery := TDB.GetInstance.getQueryResult(
    'UPDATE ddt_entrata SET numero_ddt = :numero_ddt, ' +
    'data_emissione = :data_emissione, data_ricezione = :data_ricezione, ' +
    'fornitore_id = :fornitore_id, note = :note ' +
    'WHERE id = :id ' +
    'RETURNING aggiornato_il',
    [FNumeroDDT, FDataEmissione, FDataRicezione, FFornitoreID, FNote, FID]);
  try
    Result := not LAutoQuery.Query.IsEmpty;
    if Result then
      FAggiornatoIl := LAutoQuery.Query.FieldByName('aggiornato_il').AsDateTime;
  finally
    LAutoQuery.Free;
  end;
end;

function TDDTEntrata.Save: Boolean;
begin
  if FID = 0 then
  begin
    Insert;
    Result := FID > 0;
  end
  else
    Result := Update;
end;

function TDDTEntrata.ToJSONObject: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('id', TJSONNumber.Create(FID));
  Result.AddPair('numero_ddt', FNumeroDDT);
  Result.AddPair('data_emissione', DateToISO8601(FDataEmissione));
  Result.AddPair('data_ricezione', DateToISO8601(FDataRicezione));
  Result.AddPair('fornitore_id', TJSONNumber.Create(FFornitoreID));
  Result.AddPair('note', FNote);
  Result.AddPair('creato_il', DateToISO8601(FCreatoIl));
  Result.AddPair('aggiornato_il', DateToISO8601(FAggiornatoIl));
end;

procedure TDDTEntrata.FromJSONObject(AJSON: TJSONObject);
var
  LValInt: Integer;
  LValStr: string;
begin
  // Id e audit non si leggono dal payload: li gestisce il database.
  if AJSON.TryGetValue<string>('numero_ddt', LValStr) then
    FNumeroDDT := LValStr;
  if AJSON.TryGetValue<string>('data_emissione', LValStr) then
    FDataEmissione := ISO8601ToDate(LValStr);
  if AJSON.TryGetValue<string>('data_ricezione', LValStr) then
    FDataRicezione := ISO8601ToDate(LValStr);
  if AJSON.TryGetValue<Integer>('fornitore_id', LValInt) then
    FFornitoreID := LValInt;
  if AJSON.TryGetValue<string>('note', LValStr) then
    FNote := LValStr;
end;

end.
