unit uModelConsumoProduzioneProdottoFinito;

interface

uses
  System.SysUtils,
  System.Variants,
  System.Generics.Collections,
  Data.DB, System.JSON, System.DateUtils,
  FireDAC.Comp.Client,
  DbU;

type
  // Un componente consumato per produrre un lotto di prodotto finito
  // (consumi_produzione_prodotti_finiti). Speculare a TConsumoProduzioneSemilavorato:
  // registra lotto e quantita' reali di una riga di ricetta, con la stessa regola XOR
  // (chk_componente_consumo_prodotto_finito) fra LottoMateriaPrimaID e LottoSemilavoratoID;
  // 0 = NULL.
  // E' il punto d'arrivo della risalita di filiera nel richiamo: da LottoProdottoFinitoID
  // si passa a ordini_vendita_righe per sapere quali clienti hanno ricevuto il lotto.
  TConsumoProduzioneProdottoFinito = class
  private
    FID: Integer;
    FLottoProdottoFinitoID: Integer;
    FLottoMateriaPrimaID: Integer;  // 0 = NULL
    FLottoSemilavoratoID: Integer;  // 0 = NULL
    FQuantitaConsumata: Currency;
    FCreatoIl: TDateTime;
    FAggiornatoIl: TDateTime;

    procedure LoadFromDataSet(ADataSet: TDataSet);
    procedure EnsureComponenteValido;
    function GetIsComponenteMateriaPrima: Boolean;
  public
    constructor Create;

    property ID: Integer read FID write FID;
    property LottoProdottoFinitoID: Integer read FLottoProdottoFinitoID write FLottoProdottoFinitoID;
    property LottoMateriaPrimaID: Integer read FLottoMateriaPrimaID write FLottoMateriaPrimaID;
    property LottoSemilavoratoID: Integer read FLottoSemilavoratoID write FLottoSemilavoratoID;
    property QuantitaConsumata: Currency read FQuantitaConsumata write FQuantitaConsumata;
    property IsComponenteMateriaPrima: Boolean read GetIsComponenteMateriaPrima;

    property CreatoIl: TDateTime read FCreatoIl;
    property AggiornatoIl: TDateTime read FAggiornatoIl;

    class function GetByID(AID: Integer): TConsumoProduzioneProdottoFinito;
    class function GetByLottoProdottoFinito(ALottoProdottoFinitoID: Integer): TObjectList<TConsumoProduzioneProdottoFinito>;
    class function GetByLottoMateriaPrima(ALottoMateriaPrimaID: Integer): TObjectList<TConsumoProduzioneProdottoFinito>;
    class function GetByLottoSemilavorato(ALottoSemilavoratoID: Integer): TObjectList<TConsumoProduzioneProdottoFinito>;
    class function Delete(AID: Integer): Boolean;

    function Insert: Integer; overload;   // restituisce l'ID generato (connessione pooled propria)

    // Overload per TServizioGiacenza: vedi
    // TConsumoProduzioneSemilavorato.Insert(AConnection).
    function Insert(AConnection: TFDConnection): Integer; overload;

    function Update: Boolean;
    function Save: Boolean;     // Insert o Update a seconda che FID sia valorizzato
    function ToJSONObject: TJSONObject;
    procedure FromJSONObject(AJSON: TJSONObject);

  end;

implementation

const
  SQL_SELECT_BASE =
    'SELECT id, lotto_prodotto_finito_id, lotto_materia_prima_id, ' +
    'lotto_semilavorato_id, quantita_consumata, creato_il, aggiornato_il ' +
    'FROM consumi_produzione_prodotti_finiti ';

constructor TConsumoProduzioneProdottoFinito.Create;
begin
  inherited Create;
  FID := 0;
  FLottoMateriaPrimaID := 0;
  FLottoSemilavoratoID := 0;
end;

function TConsumoProduzioneProdottoFinito.GetIsComponenteMateriaPrima: Boolean;
begin
  Result := FLottoMateriaPrimaID <> 0;
end;

procedure TConsumoProduzioneProdottoFinito.EnsureComponenteValido;
begin
  // Replica il CHECK chk_componente_consumo_prodotto_finito.
  if (FLottoMateriaPrimaID <> 0) = (FLottoSemilavoratoID <> 0) then
    raise Exception.Create(
      'TConsumoProduzioneProdottoFinito: la riga deve avere ESATTAMENTE uno tra ' +
      'LottoMateriaPrimaID e LottoSemilavoratoID valorizzato (mai entrambi, mai nessuno).');
end;

procedure TConsumoProduzioneProdottoFinito.LoadFromDataSet(ADataSet: TDataSet);
begin
  FID                    := ADataSet.FieldByName('id').AsInteger;
  FLottoProdottoFinitoID := ADataSet.FieldByName('lotto_prodotto_finito_id').AsInteger;

  if ADataSet.FieldByName('lotto_materia_prima_id').IsNull then
    FLottoMateriaPrimaID := 0
  else
    FLottoMateriaPrimaID := ADataSet.FieldByName('lotto_materia_prima_id').AsInteger;

  if ADataSet.FieldByName('lotto_semilavorato_id').IsNull then
    FLottoSemilavoratoID := 0
  else
    FLottoSemilavoratoID := ADataSet.FieldByName('lotto_semilavorato_id').AsInteger;

  FQuantitaConsumata := ADataSet.FieldByName('quantita_consumata').AsCurrency;
  FCreatoIl          := ADataSet.FieldByName('creato_il').AsDateTime;
  FAggiornatoIl       := ADataSet.FieldByName('aggiornato_il').AsDateTime;
end;

class function TConsumoProduzioneProdottoFinito.GetByID(AID: Integer): TConsumoProduzioneProdottoFinito;
var
  LAutoQuery: TAutoQuery;
begin
  Result := nil;

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE id = :id', [AID]);
  try
    if not LAutoQuery.Query.IsEmpty then
    begin
      Result := TConsumoProduzioneProdottoFinito.Create;
      Result.LoadFromDataSet(LAutoQuery.Query);
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TConsumoProduzioneProdottoFinito.GetByLottoProdottoFinito(
  ALottoProdottoFinitoID: Integer): TObjectList<TConsumoProduzioneProdottoFinito>;
var
  LAutoQuery: TAutoQuery;
  LConsumo: TConsumoProduzioneProdottoFinito;
begin
  // Componenti consumati per un lotto: la distinta base effettiva.
  Result := TObjectList<TConsumoProduzioneProdottoFinito>.Create(True);

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE lotto_prodotto_finito_id = :lotto_prodotto_finito_id ORDER BY id',
    [ALottoProdottoFinitoID]);
  try
    while not LAutoQuery.Query.Eof do
    begin
      LConsumo := TConsumoProduzioneProdottoFinito.Create;
      LConsumo.LoadFromDataSet(LAutoQuery.Query);
      Result.Add(LConsumo);
      LAutoQuery.Query.Next;
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TConsumoProduzioneProdottoFinito.GetByLottoMateriaPrima(
  ALottoMateriaPrimaID: Integer): TObjectList<TConsumoProduzioneProdottoFinito>;
var
  LAutoQuery: TAutoQuery;
  LConsumo: TConsumoProduzioneProdottoFinito;
begin
  // A ritroso: i lotti di prodotto finito che hanno consumato direttamente un lotto di
  // materia prima.
  Result := TObjectList<TConsumoProduzioneProdottoFinito>.Create(True);

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE lotto_materia_prima_id = :lotto_materia_prima_id ORDER BY id',
    [ALottoMateriaPrimaID]);
  try
    while not LAutoQuery.Query.Eof do
    begin
      LConsumo := TConsumoProduzioneProdottoFinito.Create;
      LConsumo.LoadFromDataSet(LAutoQuery.Query);
      Result.Add(LConsumo);
      LAutoQuery.Query.Next;
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TConsumoProduzioneProdottoFinito.GetByLottoSemilavorato(
  ALottoSemilavoratoID: Integer): TObjectList<TConsumoProduzioneProdottoFinito>;
var
  LAutoQuery: TAutoQuery;
  LConsumo: TConsumoProduzioneProdottoFinito;
begin
  // A ritroso: i lotti di prodotto finito che hanno consumato un lotto di semilavorato.
  Result := TObjectList<TConsumoProduzioneProdottoFinito>.Create(True);

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE lotto_semilavorato_id = :lotto_semilavorato_id ORDER BY id',
    [ALottoSemilavoratoID]);
  try
    while not LAutoQuery.Query.Eof do
    begin
      LConsumo := TConsumoProduzioneProdottoFinito.Create;
      LConsumo.LoadFromDataSet(LAutoQuery.Query);
      Result.Add(LConsumo);
      LAutoQuery.Query.Next;
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TConsumoProduzioneProdottoFinito.Delete(AID: Integer): Boolean;
begin
  // Nodo foglia: nessuna FK lo referenzia.
  Result := TDB.GetInstance.executeQuery(
    'DELETE FROM consumi_produzione_prodotti_finiti WHERE id = :id', [AID]);
end;

function TConsumoProduzioneProdottoFinito.Insert: Integer;
var
  LAutoQuery: TAutoQuery;
  LMateriaPrimaParam, LSemilavoratoParam: Variant;
begin
  EnsureComponenteValido;

  if FLottoMateriaPrimaID = 0 then LMateriaPrimaParam := Null else LMateriaPrimaParam := FLottoMateriaPrimaID;
  if FLottoSemilavoratoID = 0 then LSemilavoratoParam := Null else LSemilavoratoParam := FLottoSemilavoratoID;

  // creato_il/aggiornato_il: DEFAULT del database.
  LAutoQuery := TDB.GetInstance.getQueryResult(
    'INSERT INTO consumi_produzione_prodotti_finiti ' +
    '(lotto_prodotto_finito_id, lotto_materia_prima_id, lotto_semilavorato_id, quantita_consumata) ' +
    'VALUES (:lotto_prodotto_finito_id, :lotto_materia_prima_id, :lotto_semilavorato_id, :quantita_consumata) ' +
    'RETURNING id, creato_il, aggiornato_il',
    [FLottoProdottoFinitoID, LMateriaPrimaParam, LSemilavoratoParam, FQuantitaConsumata]);
  try
    FID           := LAutoQuery.Query.FieldByName('id').AsInteger;
    FCreatoIl     := LAutoQuery.Query.FieldByName('creato_il').AsDateTime;
    FAggiornatoIl := LAutoQuery.Query.FieldByName('aggiornato_il').AsDateTime;
    Result := FID;
  finally
    LAutoQuery.Free;
  end;
end;

function TConsumoProduzioneProdottoFinito.Insert(AConnection: TFDConnection): Integer;
var
  LQuery: TFDQuery;
  LMateriaPrimaParam, LSemilavoratoParam: Variant;
begin
  EnsureComponenteValido;

  if FLottoMateriaPrimaID = 0 then LMateriaPrimaParam := Null else LMateriaPrimaParam := FLottoMateriaPrimaID;
  if FLottoSemilavoratoID = 0 then LSemilavoratoParam := Null else LSemilavoratoParam := FLottoSemilavoratoID;

  // Come l'overload senza parametri, ma su AConnection (transazione del chiamante): vedi
  // TConsumoProduzioneSemilavorato.Insert(AConnection).
  LQuery := TFDQuery.Create(nil);
  try
    LQuery.Connection := AConnection;
    LQuery.SQL.Text :=
      'INSERT INTO consumi_produzione_prodotti_finiti ' +
      '(lotto_prodotto_finito_id, lotto_materia_prima_id, lotto_semilavorato_id, quantita_consumata) ' +
      'VALUES (:lotto_prodotto_finito_id, :lotto_materia_prima_id, :lotto_semilavorato_id, :quantita_consumata) ' +
      'RETURNING id, creato_il, aggiornato_il';
    LQuery.ParamByName('lotto_prodotto_finito_id').AsInteger := FLottoProdottoFinitoID;
    LQuery.ParamByName('lotto_materia_prima_id').Value := LMateriaPrimaParam;
    LQuery.ParamByName('lotto_semilavorato_id').Value := LSemilavoratoParam;
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

function TConsumoProduzioneProdottoFinito.Update: Boolean;
var
  LAutoQuery: TAutoQuery;
  LMateriaPrimaParam, LSemilavoratoParam: Variant;
begin
  EnsureComponenteValido;

  if FLottoMateriaPrimaID = 0 then LMateriaPrimaParam := Null else LMateriaPrimaParam := FLottoMateriaPrimaID;
  if FLottoSemilavoratoID = 0 then LSemilavoratoParam := Null else LSemilavoratoParam := FLottoSemilavoratoID;

  // aggiornato_il lo imposta il trigger.
  LAutoQuery := TDB.GetInstance.getQueryResult(
    'UPDATE consumi_produzione_prodotti_finiti SET lotto_prodotto_finito_id = :lotto_prodotto_finito_id, ' +
    'lotto_materia_prima_id = :lotto_materia_prima_id, lotto_semilavorato_id = :lotto_semilavorato_id, ' +
    'quantita_consumata = :quantita_consumata ' +
    'WHERE id = :id ' +
    'RETURNING aggiornato_il',
    [FLottoProdottoFinitoID, LMateriaPrimaParam, LSemilavoratoParam, FQuantitaConsumata, FID]);
  try
    Result := not LAutoQuery.Query.IsEmpty;
    if Result then
      FAggiornatoIl := LAutoQuery.Query.FieldByName('aggiornato_il').AsDateTime;
  finally
    LAutoQuery.Free;
  end;
end;

function TConsumoProduzioneProdottoFinito.Save: Boolean;
begin
  if FID = 0 then
  begin
    Insert;
    Result := FID > 0;
  end
  else
    Result := Update;
end;

function TConsumoProduzioneProdottoFinito.ToJSONObject: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('id', TJSONNumber.Create(FID));
  Result.AddPair('lotto_prodotto_finito_id', TJSONNumber.Create(FLottoProdottoFinitoID));
  if FLottoMateriaPrimaID = 0 then
    Result.AddPair('lotto_materia_prima_id', TJSONNull.Create)
  else
    Result.AddPair('lotto_materia_prima_id', TJSONNumber.Create(FLottoMateriaPrimaID));
  if FLottoSemilavoratoID = 0 then
    Result.AddPair('lotto_semilavorato_id', TJSONNull.Create)
  else
    Result.AddPair('lotto_semilavorato_id', TJSONNumber.Create(FLottoSemilavoratoID));
  Result.AddPair('quantita_consumata', TJSONNumber.Create(FQuantitaConsumata));
  Result.AddPair('creato_il', DateToISO8601(FCreatoIl));
  Result.AddPair('aggiornato_il', DateToISO8601(FAggiornatoIl));
end;

procedure TConsumoProduzioneProdottoFinito.FromJSONObject(AJSON: TJSONObject);
var
  LValInt: Integer;
  LValNum: TJSONValue;
begin
  // Id e audit non si leggono dal payload: li gestisce il database.
  if AJSON.TryGetValue<Integer>('lotto_prodotto_finito_id', LValInt) then
    FLottoProdottoFinitoID := LValInt;
  if AJSON.TryGetValue<Integer>('lotto_materia_prima_id', LValInt) then
    FLottoMateriaPrimaID := LValInt;
  if AJSON.TryGetValue<Integer>('lotto_semilavorato_id', LValInt) then
    FLottoSemilavoratoID := LValInt;

  // Decimali letti come TJSONNumber, per non perdere precisione.
  if AJSON.TryGetValue<TJSONValue>('quantita_consumata', LValNum) and (LValNum is TJSONNumber) then
    FQuantitaConsumata := TJSONNumber(LValNum).AsDouble;
end;

end.
