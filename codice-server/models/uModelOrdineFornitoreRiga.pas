unit uModelOrdineFornitoreRiga;

interface

uses
  System.SysUtils,
  System.Generics.Collections,
  Data.DB, System.JSON, System.DateUtils,
  DbU;

type
  // Riga di ordine di acquisto: una materia prima ordinata, con quantita', unita' e prezzo
  // negoziato (ordini_fornitori_righe). Il prezzo puo' differire dal PrezzoUnitario della
  // riga DDT di entrata; non c'e' una FK ordine-riga -> DDT-riga, la corrispondenza e' di
  // processo.
  TOrdineFornitoreRiga = class
  private
    FID: Integer;
    FOrdineFornitoreID: Integer;
    FMateriaPrimaID: Integer;
    FQuantita: Currency;
    FUnitaMisura: string;
    FPrezzoUnitario: Currency;
    FCreatoIl: TDateTime;
    FAggiornatoIl: TDateTime;

    procedure LoadFromDataSet(ADataSet: TDataSet);
  public
    constructor Create;

    property ID: Integer read FID write FID;
    property OrdineFornitoreID: Integer read FOrdineFornitoreID write FOrdineFornitoreID;
    property MateriaPrimaID: Integer read FMateriaPrimaID write FMateriaPrimaID;
    property Quantita: Currency read FQuantita write FQuantita;
    property UnitaMisura: string read FUnitaMisura write FUnitaMisura;
    property PrezzoUnitario: Currency read FPrezzoUnitario write FPrezzoUnitario;

    property CreatoIl: TDateTime read FCreatoIl;
    property AggiornatoIl: TDateTime read FAggiornatoIl;

    class function GetByID(AID: Integer): TOrdineFornitoreRiga;
    class function GetAll: TObjectList<TOrdineFornitoreRiga>;
    class function GetByOrdineFornitore(AOrdineFornitoreID: Integer): TObjectList<TOrdineFornitoreRiga>;
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
    'SELECT id, ordine_fornitore_id, materia_prima_id, quantita, ' +
    'unita_misura, prezzo_unitario, creato_il, aggiornato_il ' +
    'FROM ordini_fornitori_righe ';

constructor TOrdineFornitoreRiga.Create;
begin
  inherited Create;
  FID := 0;
end;

procedure TOrdineFornitoreRiga.LoadFromDataSet(ADataSet: TDataSet);
begin
  FID                := ADataSet.FieldByName('id').AsInteger;
  FOrdineFornitoreID := ADataSet.FieldByName('ordine_fornitore_id').AsInteger;
  FMateriaPrimaID    := ADataSet.FieldByName('materia_prima_id').AsInteger;
  FQuantita          := ADataSet.FieldByName('quantita').AsCurrency;
  FUnitaMisura       := ADataSet.FieldByName('unita_misura').AsString;
  FPrezzoUnitario    := ADataSet.FieldByName('prezzo_unitario').AsCurrency;
  FCreatoIl          := ADataSet.FieldByName('creato_il').AsDateTime;
  FAggiornatoIl      := ADataSet.FieldByName('aggiornato_il').AsDateTime;
end;

class function TOrdineFornitoreRiga.GetByID(AID: Integer): TOrdineFornitoreRiga;
var
  LAutoQuery: TAutoQuery;
begin
  Result := nil;

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE id = :id', [AID]);
  try
    if not LAutoQuery.Query.IsEmpty then
    begin
      Result := TOrdineFornitoreRiga.Create;
      Result.LoadFromDataSet(LAutoQuery.Query);
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TOrdineFornitoreRiga.GetAll: TObjectList<TOrdineFornitoreRiga>;
var
  LAutoQuery: TAutoQuery;
  LRiga: TOrdineFornitoreRiga;
begin
  Result := TObjectList<TOrdineFornitoreRiga>.Create(True); // possiede gli oggetti

  LAutoQuery := TDB.GetInstance.getQueryResult(SQL_SELECT_BASE + 'ORDER BY id');
  try
    while not LAutoQuery.Query.Eof do
    begin
      LRiga := TOrdineFornitoreRiga.Create;
      LRiga.LoadFromDataSet(LAutoQuery.Query);
      Result.Add(LRiga);
      LAutoQuery.Query.Next;
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TOrdineFornitoreRiga.GetByOrdineFornitore(AOrdineFornitoreID: Integer): TObjectList<TOrdineFornitoreRiga>;
var
  LAutoQuery: TAutoQuery;
  LRiga: TOrdineFornitoreRiga;
begin
  Result := TObjectList<TOrdineFornitoreRiga>.Create(True);

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE ordine_fornitore_id = :ordine_fornitore_id ORDER BY id',
    [AOrdineFornitoreID]);
  try
    while not LAutoQuery.Query.Eof do
    begin
      LRiga := TOrdineFornitoreRiga.Create;
      LRiga.LoadFromDataSet(LAutoQuery.Query);
      Result.Add(LRiga);
      LAutoQuery.Query.Next;
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TOrdineFornitoreRiga.Delete(AID: Integer): Boolean;
begin
  Result := TDB.GetInstance.executeQuery(
    'DELETE FROM ordini_fornitori_righe WHERE id = :id', [AID]);
end;

function TOrdineFornitoreRiga.Insert: Integer;
var
  LAutoQuery: TAutoQuery;
begin
  // creato_il/aggiornato_il: DEFAULT del database.
  LAutoQuery := TDB.GetInstance.getQueryResult(
    'INSERT INTO ordini_fornitori_righe ' +
    '(ordine_fornitore_id, materia_prima_id, quantita, unita_misura, prezzo_unitario) ' +
    'VALUES (:ordine_fornitore_id, :materia_prima_id, :quantita, :unita_misura, :prezzo_unitario) ' +
    'RETURNING id, creato_il, aggiornato_il',
    [FOrdineFornitoreID, FMateriaPrimaID, FQuantita, FUnitaMisura, FPrezzoUnitario]);
  try
    FID           := LAutoQuery.Query.FieldByName('id').AsInteger;
    FCreatoIl     := LAutoQuery.Query.FieldByName('creato_il').AsDateTime;
    FAggiornatoIl := LAutoQuery.Query.FieldByName('aggiornato_il').AsDateTime;
    Result := FID;
  finally
    LAutoQuery.Free;
  end;
end;

function TOrdineFornitoreRiga.Update: Boolean;
var
  LAutoQuery: TAutoQuery;
begin
  // aggiornato_il lo imposta il trigger.
  LAutoQuery := TDB.GetInstance.getQueryResult(
    'UPDATE ordini_fornitori_righe SET ordine_fornitore_id = :ordine_fornitore_id, ' +
    'materia_prima_id = :materia_prima_id, quantita = :quantita, ' +
    'unita_misura = :unita_misura, prezzo_unitario = :prezzo_unitario ' +
    'WHERE id = :id ' +
    'RETURNING aggiornato_il',
    [FOrdineFornitoreID, FMateriaPrimaID, FQuantita, FUnitaMisura, FPrezzoUnitario, FID]);
  try
    Result := not LAutoQuery.Query.IsEmpty;
    if Result then
      FAggiornatoIl := LAutoQuery.Query.FieldByName('aggiornato_il').AsDateTime;
  finally
    LAutoQuery.Free;
  end;
end;

function TOrdineFornitoreRiga.Save: Boolean;
begin
  if FID = 0 then
  begin
    Insert;
    Result := FID > 0;
  end
  else
    Result := Update;
end;

function TOrdineFornitoreRiga.ToJSONObject: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('id', TJSONNumber.Create(FID));
  Result.AddPair('ordine_fornitore_id', TJSONNumber.Create(FOrdineFornitoreID));
  Result.AddPair('materia_prima_id', TJSONNumber.Create(FMateriaPrimaID));
  Result.AddPair('quantita', TJSONNumber.Create(FQuantita));
  Result.AddPair('unita_misura', FUnitaMisura);
  Result.AddPair('prezzo_unitario', TJSONNumber.Create(FPrezzoUnitario));
  Result.AddPair('creato_il', DateToISO8601(FCreatoIl));
  Result.AddPair('aggiornato_il', DateToISO8601(FAggiornatoIl));
end;

procedure TOrdineFornitoreRiga.FromJSONObject(AJSON: TJSONObject);
var
  LValInt: Integer;
  LValStr: string;
  LValNum: TJSONValue;
begin
  // Id e audit non si leggono dal payload: li gestisce il database.
  if AJSON.TryGetValue<Integer>('ordine_fornitore_id', LValInt) then
    FOrdineFornitoreID := LValInt;
  if AJSON.TryGetValue<Integer>('materia_prima_id', LValInt) then
    FMateriaPrimaID := LValInt;
  if AJSON.TryGetValue<string>('unita_misura', LValStr) then
    FUnitaMisura := LValStr;

  // Decimali letti come TJSONNumber, per non perdere precisione.
  if AJSON.TryGetValue<TJSONValue>('quantita', LValNum) and (LValNum is TJSONNumber) then
    FQuantita := TJSONNumber(LValNum).AsDouble;
  if AJSON.TryGetValue<TJSONValue>('prezzo_unitario', LValNum) and (LValNum is TJSONNumber) then
    FPrezzoUnitario := TJSONNumber(LValNum).AsDouble;
end;

end.
