unit uModelConsumoProduzioneSemilavorato;

interface

uses
  System.SysUtils,
  System.Variants,
  System.Generics.Collections,
  Data.DB, System.JSON, System.DateUtils,
  FireDAC.Comp.Client,
  DbU;

type
  // Un componente consumato per produrre un lotto di semilavorato
  // (consumi_produzione_semilavorati). La ricetta dice la dose standard; qui si registrano
  // il lotto usato e la quantita' reale (QuantitaConsumata).
  // E' la tabella chiave della tracciabilita' a ritroso del richiamo: da un lotto di
  // materia prima non conforme (LottoMateriaPrimaID) si trovano i lotti di semilavorato che
  // l'hanno consumato e, via LottoSemilavoratoFiglioID, tutta la catena multi-livello.
  // Il componente e' esattamente uno fra lotto di materia prima e lotto di semilavorato
  // (chk_componente_consumo_semilavorato); 0 = NULL.
  TConsumoProduzioneSemilavorato = class
  private
    FID: Integer;
    FLottoSemilavoratoID: Integer;
    FLottoMateriaPrimaID: Integer;         // 0 = NULL
    FLottoSemilavoratoFiglioID: Integer;   // 0 = NULL
    FQuantitaConsumata: Currency;
    FCreatoIl: TDateTime;
    FAggiornatoIl: TDateTime;

    procedure LoadFromDataSet(ADataSet: TDataSet);
    procedure EnsureComponenteValido;
    function GetIsComponenteMateriaPrima: Boolean;
  public
    constructor Create;

    property ID: Integer read FID write FID;
    property LottoSemilavoratoID: Integer read FLottoSemilavoratoID write FLottoSemilavoratoID;
    property LottoMateriaPrimaID: Integer read FLottoMateriaPrimaID write FLottoMateriaPrimaID;
    property LottoSemilavoratoFiglioID: Integer read FLottoSemilavoratoFiglioID write FLottoSemilavoratoFiglioID;
    property QuantitaConsumata: Currency read FQuantitaConsumata write FQuantitaConsumata;
    property IsComponenteMateriaPrima: Boolean read GetIsComponenteMateriaPrima;

    property CreatoIl: TDateTime read FCreatoIl;
    property AggiornatoIl: TDateTime read FAggiornatoIl;

    class function GetByID(AID: Integer): TConsumoProduzioneSemilavorato;
    class function GetByLottoSemilavorato(ALottoSemilavoratoID: Integer): TObjectList<TConsumoProduzioneSemilavorato>;
    class function GetByLottoMateriaPrima(ALottoMateriaPrimaID: Integer): TObjectList<TConsumoProduzioneSemilavorato>;
    class function GetByLottoSemilavoratoFiglio(ALottoSemilavoratoFiglioID: Integer): TObjectList<TConsumoProduzioneSemilavorato>;
    class function Delete(AID: Integer): Boolean;

    function Insert: Integer; overload;   // restituisce l'ID generato (connessione pooled propria)

    // Overload per TServizioGiacenza: scrive sulla connessione ricevuta (transazione del
    // chiamante), cosi' insert e decremento della giacenza del lotto componente
    // (DecrementaQuantitaDisponibile) condividono commit/rollback.
    function Insert(AConnection: TFDConnection): Integer; overload;

    function Update: Boolean;
    function Save: Boolean;     // Insert o Update a seconda che FID sia valorizzato
    function ToJSONObject: TJSONObject;
    procedure FromJSONObject(AJSON: TJSONObject);

  end;

implementation

const
  SQL_SELECT_BASE =
    'SELECT id, lotto_semilavorato_id, lotto_materia_prima_id, ' +
    'lotto_semilavorato_figlio_id, quantita_consumata, creato_il, aggiornato_il ' +
    'FROM consumi_produzione_semilavorati ';

constructor TConsumoProduzioneSemilavorato.Create;
begin
  inherited Create;
  FID := 0;
  FLottoMateriaPrimaID := 0;
  FLottoSemilavoratoFiglioID := 0;
end;

function TConsumoProduzioneSemilavorato.GetIsComponenteMateriaPrima: Boolean;
begin
  Result := FLottoMateriaPrimaID <> 0;
end;

procedure TConsumoProduzioneSemilavorato.EnsureComponenteValido;
begin
  // Replica il CHECK chk_componente_consumo_semilavorato.
  if (FLottoMateriaPrimaID <> 0) = (FLottoSemilavoratoFiglioID <> 0) then
    raise Exception.Create(
      'TConsumoProduzioneSemilavorato: la riga deve avere ESATTAMENTE uno tra ' +
      'LottoMateriaPrimaID e LottoSemilavoratoFiglioID valorizzato (mai entrambi, mai nessuno).');
end;

procedure TConsumoProduzioneSemilavorato.LoadFromDataSet(ADataSet: TDataSet);
begin
  FID                  := ADataSet.FieldByName('id').AsInteger;
  FLottoSemilavoratoID := ADataSet.FieldByName('lotto_semilavorato_id').AsInteger;

  if ADataSet.FieldByName('lotto_materia_prima_id').IsNull then
    FLottoMateriaPrimaID := 0
  else
    FLottoMateriaPrimaID := ADataSet.FieldByName('lotto_materia_prima_id').AsInteger;

  if ADataSet.FieldByName('lotto_semilavorato_figlio_id').IsNull then
    FLottoSemilavoratoFiglioID := 0
  else
    FLottoSemilavoratoFiglioID := ADataSet.FieldByName('lotto_semilavorato_figlio_id').AsInteger;

  FQuantitaConsumata := ADataSet.FieldByName('quantita_consumata').AsCurrency;
  FCreatoIl           := ADataSet.FieldByName('creato_il').AsDateTime;
  FAggiornatoIl        := ADataSet.FieldByName('aggiornato_il').AsDateTime;
end;

class function TConsumoProduzioneSemilavorato.GetByID(AID: Integer): TConsumoProduzioneSemilavorato;
var
  LAutoQuery: TAutoQuery;
begin
  Result := nil;

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE id = :id', [AID]);
  try
    if not LAutoQuery.Query.IsEmpty then
    begin
      Result := TConsumoProduzioneSemilavorato.Create;
      Result.LoadFromDataSet(LAutoQuery.Query);
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TConsumoProduzioneSemilavorato.GetByLottoSemilavorato(
  ALottoSemilavoratoID: Integer): TObjectList<TConsumoProduzioneSemilavorato>;
var
  LAutoQuery: TAutoQuery;
  LConsumo: TConsumoProduzioneSemilavorato;
begin
  // Componenti consumati per un lotto: la distinta base effettiva.
  Result := TObjectList<TConsumoProduzioneSemilavorato>.Create(True);

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE lotto_semilavorato_id = :lotto_semilavorato_id ORDER BY id',
    [ALottoSemilavoratoID]);
  try
    while not LAutoQuery.Query.Eof do
    begin
      LConsumo := TConsumoProduzioneSemilavorato.Create;
      LConsumo.LoadFromDataSet(LAutoQuery.Query);
      Result.Add(LConsumo);
      LAutoQuery.Query.Next;
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TConsumoProduzioneSemilavorato.GetByLottoMateriaPrima(
  ALottoMateriaPrimaID: Integer): TObjectList<TConsumoProduzioneSemilavorato>;
var
  LAutoQuery: TAutoQuery;
  LConsumo: TConsumoProduzioneSemilavorato;
begin
  // A ritroso: i lotti di semilavorato che hanno consumato un lotto di materia prima. Primo
  // passo della risalita nel richiamo.
  Result := TObjectList<TConsumoProduzioneSemilavorato>.Create(True);

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE lotto_materia_prima_id = :lotto_materia_prima_id ORDER BY id',
    [ALottoMateriaPrimaID]);
  try
    while not LAutoQuery.Query.Eof do
    begin
      LConsumo := TConsumoProduzioneSemilavorato.Create;
      LConsumo.LoadFromDataSet(LAutoQuery.Query);
      Result.Add(LConsumo);
      LAutoQuery.Query.Next;
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TConsumoProduzioneSemilavorato.GetByLottoSemilavoratoFiglio(
  ALottoSemilavoratoFiglioID: Integer): TObjectList<TConsumoProduzioneSemilavorato>;
var
  LAutoQuery: TAutoQuery;
  LConsumo: TConsumoProduzioneSemilavorato;
begin
  // A ritroso: i lotti di semilavorato "genitore" che hanno consumato un lotto di
  // semilavorato (distinta multi-livello).
  Result := TObjectList<TConsumoProduzioneSemilavorato>.Create(True);

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE lotto_semilavorato_figlio_id = :lotto_semilavorato_figlio_id ORDER BY id',
    [ALottoSemilavoratoFiglioID]);
  try
    while not LAutoQuery.Query.Eof do
    begin
      LConsumo := TConsumoProduzioneSemilavorato.Create;
      LConsumo.LoadFromDataSet(LAutoQuery.Query);
      Result.Add(LConsumo);
      LAutoQuery.Query.Next;
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TConsumoProduzioneSemilavorato.Delete(AID: Integer): Boolean;
begin
  // Nodo foglia: nessuna FK lo referenzia.
  Result := TDB.GetInstance.executeQuery(
    'DELETE FROM consumi_produzione_semilavorati WHERE id = :id', [AID]);
end;

function TConsumoProduzioneSemilavorato.Insert: Integer;
var
  LAutoQuery: TAutoQuery;
  LMateriaPrimaParam, LSemilavoratoFiglioParam: Variant;
begin
  EnsureComponenteValido;

  if FLottoMateriaPrimaID = 0 then LMateriaPrimaParam := Null else LMateriaPrimaParam := FLottoMateriaPrimaID;
  if FLottoSemilavoratoFiglioID = 0 then LSemilavoratoFiglioParam := Null else LSemilavoratoFiglioParam := FLottoSemilavoratoFiglioID;

  // creato_il/aggiornato_il: DEFAULT del database.
  LAutoQuery := TDB.GetInstance.getQueryResult(
    'INSERT INTO consumi_produzione_semilavorati ' +
    '(lotto_semilavorato_id, lotto_materia_prima_id, lotto_semilavorato_figlio_id, quantita_consumata) ' +
    'VALUES (:lotto_semilavorato_id, :lotto_materia_prima_id, :lotto_semilavorato_figlio_id, :quantita_consumata) ' +
    'RETURNING id, creato_il, aggiornato_il',
    [FLottoSemilavoratoID, LMateriaPrimaParam, LSemilavoratoFiglioParam, FQuantitaConsumata]);
  try
    FID           := LAutoQuery.Query.FieldByName('id').AsInteger;
    FCreatoIl     := LAutoQuery.Query.FieldByName('creato_il').AsDateTime;
    FAggiornatoIl := LAutoQuery.Query.FieldByName('aggiornato_il').AsDateTime;
    Result := FID;
  finally
    LAutoQuery.Free;
  end;
end;

function TConsumoProduzioneSemilavorato.Insert(AConnection: TFDConnection): Integer;
var
  LQuery: TFDQuery;
  LMateriaPrimaParam, LSemilavoratoFiglioParam: Variant;
begin
  EnsureComponenteValido;

  if FLottoMateriaPrimaID = 0 then LMateriaPrimaParam := Null else LMateriaPrimaParam := FLottoMateriaPrimaID;
  if FLottoSemilavoratoFiglioID = 0 then LSemilavoratoFiglioParam := Null else LSemilavoratoFiglioParam := FLottoSemilavoratoFiglioID;

  // Come l'overload senza parametri, ma su AConnection (transazione del chiamante).
  // LQuery.Open e non ExecSQL perche' si legge la riga del RETURNING.
  LQuery := TFDQuery.Create(nil);
  try
    LQuery.Connection := AConnection;
    LQuery.SQL.Text :=
      'INSERT INTO consumi_produzione_semilavorati ' +
      '(lotto_semilavorato_id, lotto_materia_prima_id, lotto_semilavorato_figlio_id, quantita_consumata) ' +
      'VALUES (:lotto_semilavorato_id, :lotto_materia_prima_id, :lotto_semilavorato_figlio_id, :quantita_consumata) ' +
      'RETURNING id, creato_il, aggiornato_il';
    LQuery.ParamByName('lotto_semilavorato_id').AsInteger := FLottoSemilavoratoID;
    LQuery.ParamByName('lotto_materia_prima_id').Value := LMateriaPrimaParam;
    LQuery.ParamByName('lotto_semilavorato_figlio_id').Value := LSemilavoratoFiglioParam;
    LQuery.ParamByName('quantita_consumata').Value := FQuantitaConsumata;
    LQuery.Open;

    FID           := LQuery.FieldByName('id').AsInteger;
    FCreatoIl     := LQuery.FieldByName('creato_il').AsDateTime;
    FAggiornatoIl := LQuery.FieldByName('aggiornato_il').AsDateTime;
    Result := FID;
  finally
    LQuery.Free;
  end;
end;

function TConsumoProduzioneSemilavorato.Update: Boolean;
var
  LAutoQuery: TAutoQuery;
  LMateriaPrimaParam, LSemilavoratoFiglioParam: Variant;
begin
  EnsureComponenteValido;

  if FLottoMateriaPrimaID = 0 then LMateriaPrimaParam := Null else LMateriaPrimaParam := FLottoMateriaPrimaID;
  if FLottoSemilavoratoFiglioID = 0 then LSemilavoratoFiglioParam := Null else LSemilavoratoFiglioParam := FLottoSemilavoratoFiglioID;

  // aggiornato_il lo imposta il trigger.
  LAutoQuery := TDB.GetInstance.getQueryResult(
    'UPDATE consumi_produzione_semilavorati SET lotto_semilavorato_id = :lotto_semilavorato_id, ' +
    'lotto_materia_prima_id = :lotto_materia_prima_id, ' +
    'lotto_semilavorato_figlio_id = :lotto_semilavorato_figlio_id, ' +
    'quantita_consumata = :quantita_consumata ' +
    'WHERE id = :id ' +
    'RETURNING aggiornato_il',
    [FLottoSemilavoratoID, LMateriaPrimaParam, LSemilavoratoFiglioParam, FQuantitaConsumata, FID]);
  try
    Result := not LAutoQuery.Query.IsEmpty;
    if Result then
      FAggiornatoIl := LAutoQuery.Query.FieldByName('aggiornato_il').AsDateTime;
  finally
    LAutoQuery.Free;
  end;
end;

function TConsumoProduzioneSemilavorato.Save: Boolean;
begin
  if FID = 0 then
  begin
    Insert;
    Result := FID > 0;
  end
  else
    Result := Update;
end;

function TConsumoProduzioneSemilavorato.ToJSONObject: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('id', TJSONNumber.Create(FID));
  Result.AddPair('lotto_semilavorato_id', TJSONNumber.Create(FLottoSemilavoratoID));
  if FLottoMateriaPrimaID = 0 then
    Result.AddPair('lotto_materia_prima_id', TJSONNull.Create)
  else
    Result.AddPair('lotto_materia_prima_id', TJSONNumber.Create(FLottoMateriaPrimaID));
  if FLottoSemilavoratoFiglioID = 0 then
    Result.AddPair('lotto_semilavorato_figlio_id', TJSONNull.Create)
  else
    Result.AddPair('lotto_semilavorato_figlio_id', TJSONNumber.Create(FLottoSemilavoratoFiglioID));
  Result.AddPair('quantita_consumata', TJSONNumber.Create(FQuantitaConsumata));
  Result.AddPair('creato_il', DateToISO8601(FCreatoIl));
  Result.AddPair('aggiornato_il', DateToISO8601(FAggiornatoIl));
end;

procedure TConsumoProduzioneSemilavorato.FromJSONObject(AJSON: TJSONObject);
var
  LValInt: Integer;
  LValNum: TJSONValue;
begin
  // Id e audit non si leggono dal payload: li gestisce il database.
  if AJSON.TryGetValue<Integer>('lotto_semilavorato_id', LValInt) then
    FLottoSemilavoratoID := LValInt;
  if AJSON.TryGetValue<Integer>('lotto_materia_prima_id', LValInt) then
    FLottoMateriaPrimaID := LValInt;
  if AJSON.TryGetValue<Integer>('lotto_semilavorato_figlio_id', LValInt) then
    FLottoSemilavoratoFiglioID := LValInt;

  // Decimali letti come TJSONNumber, per non perdere precisione.
  if AJSON.TryGetValue<TJSONValue>('quantita_consumata', LValNum) and (LValNum is TJSONNumber) then
    FQuantitaConsumata := TJSONNumber(LValNum).AsDouble;
end;

end.
