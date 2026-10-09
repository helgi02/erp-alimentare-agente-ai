unit uModelOrdineVenditaRiga;

interface

uses
  System.SysUtils,
  System.Generics.Collections,
  Data.DB, System.JSON, System.DateUtils,
  DbU;

type
  // Riga di ordine di vendita: un prodotto finito assegnato a un lotto specifico
  // (ordini_vendita_righe). LottoProdottoFinitoID e' obbligatorio fin dall'ordine: per
  // sapere se un cliente ha ricevuto un lotto serve il lotto, non il prodotto. E' il dato
  // chiave del richiamo.
  TOrdineVenditaRiga = class
  private
    FID: Integer;
    FOrdineVenditaID: Integer;
    FProdottoFinitoID: Integer;
    FLottoProdottoFinitoID: Integer;
    FQuantita: Currency;
    FUnitaMisura: string;
    FPrezzoUnitario: Currency;
    FCreatoIl: TDateTime;
    FAggiornatoIl: TDateTime;

    procedure LoadFromDataSet(ADataSet: TDataSet);
  public
    constructor Create;

    property ID: Integer read FID write FID;
    property OrdineVenditaID: Integer read FOrdineVenditaID write FOrdineVenditaID;
    property ProdottoFinitoID: Integer read FProdottoFinitoID write FProdottoFinitoID;
    property LottoProdottoFinitoID: Integer read FLottoProdottoFinitoID write FLottoProdottoFinitoID;
    property Quantita: Currency read FQuantita write FQuantita;
    property UnitaMisura: string read FUnitaMisura write FUnitaMisura;
    property PrezzoUnitario: Currency read FPrezzoUnitario write FPrezzoUnitario;

    property CreatoIl: TDateTime read FCreatoIl;
    property AggiornatoIl: TDateTime read FAggiornatoIl;

    class function GetByID(AID: Integer): TOrdineVenditaRiga;
    class function GetAll: TObjectList<TOrdineVenditaRiga>;
    class function GetByOrdineVendita(AOrdineVenditaID: Integer): TObjectList<TOrdineVenditaRiga>;
    class function GetByLottoProdottoFinito(ALottoProdottoFinitoID: Integer): TObjectList<TOrdineVenditaRiga>;
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
    'SELECT id, ordine_vendita_id, prodotto_finito_id, lotto_prodotto_finito_id, ' +
    'quantita, unita_misura, prezzo_unitario, creato_il, aggiornato_il ' +
    'FROM ordini_vendita_righe ';

constructor TOrdineVenditaRiga.Create;
begin
  inherited Create;
  FID := 0;
end;

procedure TOrdineVenditaRiga.LoadFromDataSet(ADataSet: TDataSet);
begin
  FID                    := ADataSet.FieldByName('id').AsInteger;
  FOrdineVenditaID       := ADataSet.FieldByName('ordine_vendita_id').AsInteger;
  FProdottoFinitoID      := ADataSet.FieldByName('prodotto_finito_id').AsInteger;
  FLottoProdottoFinitoID := ADataSet.FieldByName('lotto_prodotto_finito_id').AsInteger;
  FQuantita              := ADataSet.FieldByName('quantita').AsCurrency;
  FUnitaMisura           := ADataSet.FieldByName('unita_misura').AsString;
  FPrezzoUnitario        := ADataSet.FieldByName('prezzo_unitario').AsCurrency;
  FCreatoIl              := ADataSet.FieldByName('creato_il').AsDateTime;
  FAggiornatoIl          := ADataSet.FieldByName('aggiornato_il').AsDateTime;
end;

class function TOrdineVenditaRiga.GetByID(AID: Integer): TOrdineVenditaRiga;
var
  LAutoQuery: TAutoQuery;
begin
  Result := nil;

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE id = :id', [AID]);
  try
    if not LAutoQuery.Query.IsEmpty then
    begin
      Result := TOrdineVenditaRiga.Create;
      Result.LoadFromDataSet(LAutoQuery.Query);
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TOrdineVenditaRiga.GetAll: TObjectList<TOrdineVenditaRiga>;
var
  LAutoQuery: TAutoQuery;
  LRiga: TOrdineVenditaRiga;
begin
  Result := TObjectList<TOrdineVenditaRiga>.Create(True); // possiede gli oggetti

  LAutoQuery := TDB.GetInstance.getQueryResult(SQL_SELECT_BASE + 'ORDER BY id');
  try
    while not LAutoQuery.Query.Eof do
    begin
      LRiga := TOrdineVenditaRiga.Create;
      LRiga.LoadFromDataSet(LAutoQuery.Query);
      Result.Add(LRiga);
      LAutoQuery.Query.Next;
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TOrdineVenditaRiga.GetByOrdineVendita(AOrdineVenditaID: Integer): TObjectList<TOrdineVenditaRiga>;
var
  LAutoQuery: TAutoQuery;
  LRiga: TOrdineVenditaRiga;
begin
  Result := TObjectList<TOrdineVenditaRiga>.Create(True);

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE ordine_vendita_id = :ordine_vendita_id ORDER BY id',
    [AOrdineVenditaID]);
  try
    while not LAutoQuery.Query.Eof do
    begin
      LRiga := TOrdineVenditaRiga.Create;
      LRiga.LoadFromDataSet(LAutoQuery.Query);
      Result.Add(LRiga);
      LAutoQuery.Query.Next;
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TOrdineVenditaRiga.GetByLottoProdottoFinito(ALottoProdottoFinitoID: Integer): TObjectList<TOrdineVenditaRiga>;
var
  LAutoQuery: TAutoQuery;
  LRiga: TOrdineVenditaRiga;
begin
  // A valle: dato un lotto di prodotto finito, le righe ordine (quindi i clienti) che
  // l'hanno acquistato.
  Result := TObjectList<TOrdineVenditaRiga>.Create(True);

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE lotto_prodotto_finito_id = :lotto_prodotto_finito_id ORDER BY id',
    [ALottoProdottoFinitoID]);
  try
    while not LAutoQuery.Query.Eof do
    begin
      LRiga := TOrdineVenditaRiga.Create;
      LRiga.LoadFromDataSet(LAutoQuery.Query);
      Result.Add(LRiga);
      LAutoQuery.Query.Next;
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TOrdineVenditaRiga.Delete(AID: Integer): Boolean;
begin
  // Fallisce se il record e' referenziato (nessun ON DELETE CASCADE): voluto, per non
  // perdere dati di tracciabilita'.
  Result := TDB.GetInstance.executeQuery(
    'DELETE FROM ordini_vendita_righe WHERE id = :id', [AID]);
end;

function TOrdineVenditaRiga.Insert: Integer;
var
  LAutoQuery: TAutoQuery;
begin
  // creato_il/aggiornato_il: DEFAULT del database.
  LAutoQuery := TDB.GetInstance.getQueryResult(
    'INSERT INTO ordini_vendita_righe ' +
    '(ordine_vendita_id, prodotto_finito_id, lotto_prodotto_finito_id, ' +
    'quantita, unita_misura, prezzo_unitario) ' +
    'VALUES (:ordine_vendita_id, :prodotto_finito_id, :lotto_prodotto_finito_id, ' +
    ':quantita, :unita_misura, :prezzo_unitario) ' +
    'RETURNING id, creato_il, aggiornato_il',
    [FOrdineVenditaID, FProdottoFinitoID, FLottoProdottoFinitoID,
     FQuantita, FUnitaMisura, FPrezzoUnitario]);
  try
    FID           := LAutoQuery.Query.FieldByName('id').AsInteger;
    FCreatoIl     := LAutoQuery.Query.FieldByName('creato_il').AsDateTime;
    FAggiornatoIl := LAutoQuery.Query.FieldByName('aggiornato_il').AsDateTime;
    Result := FID;
  finally
    LAutoQuery.Free;
  end;
end;

function TOrdineVenditaRiga.Update: Boolean;
var
  LAutoQuery: TAutoQuery;
begin
  // aggiornato_il lo imposta il trigger.
  LAutoQuery := TDB.GetInstance.getQueryResult(
    'UPDATE ordini_vendita_righe SET ordine_vendita_id = :ordine_vendita_id, ' +
    'prodotto_finito_id = :prodotto_finito_id, ' +
    'lotto_prodotto_finito_id = :lotto_prodotto_finito_id, ' +
    'quantita = :quantita, unita_misura = :unita_misura, ' +
    'prezzo_unitario = :prezzo_unitario ' +
    'WHERE id = :id ' +
    'RETURNING aggiornato_il',
    [FOrdineVenditaID, FProdottoFinitoID, FLottoProdottoFinitoID,
     FQuantita, FUnitaMisura, FPrezzoUnitario, FID]);
  try
    Result := not LAutoQuery.Query.IsEmpty;
    if Result then
      FAggiornatoIl := LAutoQuery.Query.FieldByName('aggiornato_il').AsDateTime;
  finally
    LAutoQuery.Free;
  end;
end;

function TOrdineVenditaRiga.Save: Boolean;
begin
  if FID = 0 then
  begin
    Insert;
    Result := FID > 0;
  end
  else
    Result := Update;
end;

function TOrdineVenditaRiga.ToJSONObject: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('id', TJSONNumber.Create(FID));
  Result.AddPair('ordine_vendita_id', TJSONNumber.Create(FOrdineVenditaID));
  Result.AddPair('prodotto_finito_id', TJSONNumber.Create(FProdottoFinitoID));
  Result.AddPair('lotto_prodotto_finito_id', TJSONNumber.Create(FLottoProdottoFinitoID));
  Result.AddPair('quantita', TJSONNumber.Create(FQuantita));
  Result.AddPair('unita_misura', FUnitaMisura);
  Result.AddPair('prezzo_unitario', TJSONNumber.Create(FPrezzoUnitario));
  Result.AddPair('creato_il', DateToISO8601(FCreatoIl));
  Result.AddPair('aggiornato_il', DateToISO8601(FAggiornatoIl));
end;

procedure TOrdineVenditaRiga.FromJSONObject(AJSON: TJSONObject);
var
  LValInt: Integer;
  LValStr: string;
  LValNum: TJSONValue;
begin
  // Id e audit non si leggono dal payload: li gestisce il database.
  if AJSON.TryGetValue<Integer>('ordine_vendita_id', LValInt) then
    FOrdineVenditaID := LValInt;
  if AJSON.TryGetValue<Integer>('prodotto_finito_id', LValInt) then
    FProdottoFinitoID := LValInt;
  if AJSON.TryGetValue<Integer>('lotto_prodotto_finito_id', LValInt) then
    FLottoProdottoFinitoID := LValInt;
  if AJSON.TryGetValue<string>('unita_misura', LValStr) then
    FUnitaMisura := LValStr;

  // Decimali letti come TJSONNumber, per non perdere precisione.
  if AJSON.TryGetValue<TJSONValue>('quantita', LValNum) and (LValNum is TJSONNumber) then
    FQuantita := TJSONNumber(LValNum).AsDouble;
  if AJSON.TryGetValue<TJSONValue>('prezzo_unitario', LValNum) and (LValNum is TJSONNumber) then
    FPrezzoUnitario := TJSONNumber(LValNum).AsDouble;
end;

end.
