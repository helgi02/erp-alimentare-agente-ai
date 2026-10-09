unit uModelDDTUscitaRiga;

interface

uses
  System.SysUtils,
  System.Generics.Collections,
  Data.DB, System.JSON, System.DateUtils,
  DbU;

type
  // Rappresenta una riga di un DDT di uscita: la spedizione effettiva di
  // una riga d'ordine vendita (tabella ddt_uscita_righe). Non
  // referenzia direttamente un prodotto o un lotto: referenzia
  // OrdineVenditaRigaID, cioe' QUALE riga ordine viene evasa da questa
  // spedizione. Prodotto e lotto si ottengono a cascata risalendo alla
  // riga ordine (che a sua volta punta a prodotto_finito_id e
  // lotto_prodotto_finito_id).
  //
  // QuantitaSpedita puo' differire dalla quantita' ordinata sulla riga
  // (spedizioni parziali, rotture di stock): per questo un solo ordine
  // puo' generare piu' righe DDT su DDT diversi, tutte con lo stesso
  // OrdineVenditaRigaID mano a mano che l'ordine viene evaso.
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

    // Campi di audit: sola lettura, gestiti dal database (default/trigger
    // trg_ddt_uscita_righe_aggiornato_il)
    property CreatoIl: TDateTime read FCreatoIl;
    property AggiornatoIl: TDateTime read FAggiornatoIl;

    // Operazioni CRUD
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

{ TDDTUscitaRiga }

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
  // Tutte le righe di un DDT di uscita.
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
  // Tutte le spedizioni (eventualmente parziali) che hanno evaso una
  // specifica riga ordine. Sommando QuantitaSpedita su questo insieme si
  // ottiene quanto di quella riga e' stato effettivamente consegnato.
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
  // Nessun'altra tabella referenzia ddt_uscita_righe come FK (e' un
  // "nodo foglia" nello schema): la cancellazione non incontra vincoli
  // di integrita' referenziale da parte di altre tabelle.
  Result := TDB.GetInstance.executeQuery(
    'DELETE FROM ddt_uscita_righe WHERE id = :id', [AID]);
end;

function TDDTUscitaRiga.Insert: Integer;
var
  LAutoQuery: TAutoQuery;
begin
  // creato_il e aggiornato_il NON compaiono tra i campi inseriti: sono
  // valorizzati dal DEFAULT del database (now()).
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
  // aggiornato_il NON viene impostato esplicitamente: il trigger
  // trg_ddt_uscita_righe_aggiornato_il lo valorizza automaticamente.
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
  // id, creato_il, aggiornato_il NON vengono letti dal payload in
  // ingresso: sono gestiti dal database, mai dal client
  if AJSON.TryGetValue<Integer>('ddt_uscita_id', LValInt) then
    FDDTUscitaID := LValInt;
  if AJSON.TryGetValue<Integer>('ordine_vendita_riga_id', LValInt) then
    FOrdineVenditaRigaID := LValInt;
  if AJSON.TryGetValue<string>('unita_misura', LValStr) then
    FUnitaMisura := LValStr;

  // Campo numerico decimale: letto come TJSONNumber per preservarne la
  // precisione (evitando conversioni intermedie a Double)
  if AJSON.TryGetValue<TJSONValue>('quantita_spedita', LValNum) and (LValNum is TJSONNumber) then
    FQuantitaSpedita := TJSONNumber(LValNum).AsDouble;
end;

end.
