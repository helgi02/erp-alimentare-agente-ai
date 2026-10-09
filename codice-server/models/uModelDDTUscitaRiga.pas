unit uModelDDTUscitaRiga;

interface

uses
  System.SysUtils,
  System.Generics.Collections,
  Data.DB, System.JSON, System.DateUtils,
  DbU;

type
  // Riga di DDT di uscita: la spedizione di una riga d'ordine (ddt_uscita_righe).
  // Referenzia OrdineVenditaRigaID, non prodotto o lotto, che si ottengono risalendo alla
  // riga ordine (prodotto_finito_id, lotto_prodotto_finito_id).
  // QuantitaSpedita puo' differire da quella ordinata (spedizioni parziali, rotture di
  // stock): un ordine puo' avere piu' righe DDT sullo stesso OrdineVenditaRigaID.
  TDDTUscitaRiga = class
  private
    FID: Integer;
    FDDTUscitaID: Integer;
    FOrdineVenditaRigaID: Integer;
    FQuantitaSpedita: Currency;
    FUnitaMisura: string;
    FCreatoIl: TDateTime;
    FAggiornatoIl: TDateTime;

    procedure LoadFromDataSet(ADataSet: TDataSet);
  public
    constructor Create;

    property ID: Integer read FID write FID;
    property DDTUscitaID: Integer read FDDTUscitaID write FDDTUscitaID;
    property OrdineVenditaRigaID: Integer read FOrdineVenditaRigaID write FOrdineVenditaRigaID;
    property QuantitaSpedita: Currency read FQuantitaSpedita write FQuantitaSpedita;
    property UnitaMisura: string read FUnitaMisura write FUnitaMisura;

    property CreatoIl: TDateTime read FCreatoIl;
    property AggiornatoIl: TDateTime read FAggiornatoIl;

    class function GetByID(AID: Integer): TDDTUscitaRiga;
    class function GetAll: TObjectList<TDDTUscitaRiga>;
    class function GetByDDTUscita(ADDTUscitaID: Integer): TObjectList<TDDTUscitaRiga>;
    class function GetByOrdineVenditaRiga(AOrdineVenditaRigaID: Integer): TObjectList<TDDTUscitaRiga>;
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
    'SELECT id, ddt_uscita_id, ordine_vendita_riga_id, quantita_spedita, ' +
    'unita_misura, creato_il, aggiornato_il ' +
    'FROM ddt_uscita_righe ';

constructor TDDTUscitaRiga.Create;
begin
  inherited Create;
  FID := 0;
end;

procedure TDDTUscitaRiga.LoadFromDataSet(ADataSet: TDataSet);
begin
  FID                  := ADataSet.FieldByName('id').AsInteger;
  FDDTUscitaID         := ADataSet.FieldByName('ddt_uscita_id').AsInteger;
  FOrdineVenditaRigaID := ADataSet.FieldByName('ordine_vendita_riga_id').AsInteger;
  FQuantitaSpedita     := ADataSet.FieldByName('quantita_spedita').AsCurrency;
  FUnitaMisura         := ADataSet.FieldByName('unita_misura').AsString;
  FCreatoIl            := ADataSet.FieldByName('creato_il').AsDateTime;
  FAggiornatoIl        := ADataSet.FieldByName('aggiornato_il').AsDateTime;
end;

class function TDDTUscitaRiga.GetByID(AID: Integer): TDDTUscitaRiga;
var
  LAutoQuery: TAutoQuery;
begin
  Result := nil;

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE id = :id', [AID]);
  try
    if not LAutoQuery.Query.IsEmpty then
    begin
      Result := TDDTUscitaRiga.Create;
      Result.LoadFromDataSet(LAutoQuery.Query);
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TDDTUscitaRiga.GetAll: TObjectList<TDDTUscitaRiga>;
var
  LAutoQuery: TAutoQuery;
  LRiga: TDDTUscitaRiga;
begin
  Result := TObjectList<TDDTUscitaRiga>.Create(True); // possiede gli oggetti

  LAutoQuery := TDB.GetInstance.getQueryResult(SQL_SELECT_BASE + 'ORDER BY id');
  try
    while not LAutoQuery.Query.Eof do
    begin
      LRiga := TDDTUscitaRiga.Create;
      LRiga.LoadFromDataSet(LAutoQuery.Query);
      Result.Add(LRiga);
      LAutoQuery.Query.Next;
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TDDTUscitaRiga.GetByDDTUscita(ADDTUscitaID: Integer): TObjectList<TDDTUscitaRiga>;
var
  LAutoQuery: TAutoQuery;
  LRiga: TDDTUscitaRiga;
begin
  // Righe di un DDT di uscita.
  Result := TObjectList<TDDTUscitaRiga>.Create(True);

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE ddt_uscita_id = :ddt_uscita_id ORDER BY id',
    [ADDTUscitaID]);
  try
    while not LAutoQuery.Query.Eof do
    begin
      LRiga := TDDTUscitaRiga.Create;
      LRiga.LoadFromDataSet(LAutoQuery.Query);
      Result.Add(LRiga);
      LAutoQuery.Query.Next;
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TDDTUscitaRiga.GetByOrdineVenditaRiga(AOrdineVenditaRigaID: Integer): TObjectList<TDDTUscitaRiga>;
var
  LAutoQuery: TAutoQuery;
  LRiga: TDDTUscitaRiga;
begin
  // Spedizioni (anche parziali) di una riga ordine. La somma di QuantitaSpedita e' quanto
  // e' stato consegnato.
  Result := TObjectList<TDDTUscitaRiga>.Create(True);

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE ordine_vendita_riga_id = :ordine_vendita_riga_id ORDER BY id',
    [AOrdineVenditaRigaID]);
  try
    while not LAutoQuery.Query.Eof do
    begin
      LRiga := TDDTUscitaRiga.Create;
      LRiga.LoadFromDataSet(LAutoQuery.Query);
      Result.Add(LRiga);
      LAutoQuery.Query.Next;
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TDDTUscitaRiga.Delete(AID: Integer): Boolean;
begin
  // Nodo foglia: nessuna FK lo referenzia.
  Result := TDB.GetInstance.executeQuery(
    'DELETE FROM ddt_uscita_righe WHERE id = :id', [AID]);
end;

function TDDTUscitaRiga.Insert: Integer;
var
  LAutoQuery: TAutoQuery;
begin
  // creato_il/aggiornato_il: DEFAULT del database.
  LAutoQuery := TDB.GetInstance.getQueryResult(
    'INSERT INTO ddt_uscita_righe ' +
    '(ddt_uscita_id, ordine_vendita_riga_id, quantita_spedita, unita_misura) ' +
    'VALUES (:ddt_uscita_id, :ordine_vendita_riga_id, :quantita_spedita, :unita_misura) ' +
    'RETURNING id, creato_il, aggiornato_il',
    [FDDTUscitaID, FOrdineVenditaRigaID, FQuantitaSpedita, FUnitaMisura]);
  try
    FID           := LAutoQuery.Query.FieldByName('id').AsInteger;
    FCreatoIl     := LAutoQuery.Query.FieldByName('creato_il').AsDateTime;
    FAggiornatoIl := LAutoQuery.Query.FieldByName('aggiornato_il').AsDateTime;
    Result := FID;
  finally
    LAutoQuery.Free;
  end;
end;

function TDDTUscitaRiga.Update: Boolean;
var
  LAutoQuery: TAutoQuery;
begin
  // aggiornato_il lo imposta il trigger.
  LAutoQuery := TDB.GetInstance.getQueryResult(
    'UPDATE ddt_uscita_righe SET ddt_uscita_id = :ddt_uscita_id, ' +
    'ordine_vendita_riga_id = :ordine_vendita_riga_id, ' +
    'quantita_spedita = :quantita_spedita, unita_misura = :unita_misura ' +
    'WHERE id = :id ' +
    'RETURNING aggiornato_il',
    [FDDTUscitaID, FOrdineVenditaRigaID, FQuantitaSpedita, FUnitaMisura, FID]);
  try
    Result := not LAutoQuery.Query.IsEmpty;
    if Result then
      FAggiornatoIl := LAutoQuery.Query.FieldByName('aggiornato_il').AsDateTime;
  finally
    LAutoQuery.Free;
  end;
end;

function TDDTUscitaRiga.Save: Boolean;
begin
  if FID = 0 then
  begin
    Insert;
    Result := FID > 0;
  end
  else
    Result := Update;
end;

function TDDTUscitaRiga.ToJSONObject: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('id', TJSONNumber.Create(FID));
  Result.AddPair('ddt_uscita_id', TJSONNumber.Create(FDDTUscitaID));
  Result.AddPair('ordine_vendita_riga_id', TJSONNumber.Create(FOrdineVenditaRigaID));
  Result.AddPair('quantita_spedita', TJSONNumber.Create(FQuantitaSpedita));
  Result.AddPair('unita_misura', FUnitaMisura);
  Result.AddPair('creato_il', DateToISO8601(FCreatoIl));
  Result.AddPair('aggiornato_il', DateToISO8601(FAggiornatoIl));
end;

procedure TDDTUscitaRiga.FromJSONObject(AJSON: TJSONObject);
var
  LValInt: Integer;
  LValStr: string;
  LValNum: TJSONValue;
begin
  // Id e audit non si leggono dal payload: li gestisce il database.
  if AJSON.TryGetValue<Integer>('ddt_uscita_id', LValInt) then
    FDDTUscitaID := LValInt;
  if AJSON.TryGetValue<Integer>('ordine_vendita_riga_id', LValInt) then
    FOrdineVenditaRigaID := LValInt;
  if AJSON.TryGetValue<string>('unita_misura', LValStr) then
    FUnitaMisura := LValStr;

  // Decimali letti come TJSONNumber, per non perdere precisione.
  if AJSON.TryGetValue<TJSONValue>('quantita_spedita', LValNum) and (LValNum is TJSONNumber) then
    FQuantitaSpedita := TJSONNumber(LValNum).AsDouble;
end;

end.
