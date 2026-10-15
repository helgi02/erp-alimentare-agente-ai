unit uModelDDTUscita;

interface

uses
  System.SysUtils,
  System.Generics.Collections,
  Data.DB, System.JSON, System.DateUtils,
  DbU;

type
  // Rappresenta la testata di un documento di trasporto in uscita verso
  // un cliente (tabella ddt_uscita). Speculare a TDDTEntrata, con una
  // differenza strutturale: qui c'e' anche OrdineVenditaID, perche' un
  // DDT di uscita nasce sempre per evadere un ordine di vendita gia'
  // esistente (a differenza del DDT di entrata, che accompagna un
  // acquisto senza bisogno di un "ordine" formale modellato a parte in
  // questo schema). Le righe (ddt_uscita_righe, vedi TDDTUscitaRiga)
  // referenziano infatti ordini_vendita_righe, non un prodotto/lotto
  // generico: e' cosi' che si traccia quale riga ordine e' stata evasa
  // da quale spedizione — dato chiave per lo scenario di ritiro/richiamo
  // quando serve sapere quali clienti hanno gia' ricevuto un lotto.
  TDDTUscita = class
  private
    FID: Integer;
    FNumeroDDT: string;
    FDataEmissione: TDateTime;
    FDataSpedizione: TDateTime;
    FClienteID: Integer;
    FOrdineVenditaID: Integer;
    FNote: string;
    FCreatoIl: TDateTime;
    FAggiornatoIl: TDateTime;

    procedure LoadFromDataSet(ADataSet: TDataSet);
  public
    constructor Create;

    property ID: Integer read FID write FID;
    property NumeroDDT: string read FNumeroDDT write FNumeroDDT;
    property DataEmissione: TDateTime read FDataEmissione write FDataEmissione;
    property DataSpedizione: TDateTime read FDataSpedizione write FDataSpedizione;
    property ClienteID: Integer read FClienteID write FClienteID;
    property OrdineVenditaID: Integer read FOrdineVenditaID write FOrdineVenditaID;
    property Note: string read FNote write FNote;

    // Campi di audit: sola lettura, gestiti dal database (default/trigger
    // trg_ddt_uscita_aggiornato_il)
    property CreatoIl: TDateTime read FCreatoIl;
    property AggiornatoIl: TDateTime read FAggiornatoIl;

    // Operazioni CRUD
    class function GetByID(AID: Integer): TDDTUscita;
    class function GetByNumero(const ANumeroDDT: string; AClienteID: Integer): TDDTUscita;
    class function GetAll: TObjectList<TDDTUscita>;
    class function GetByCliente(AClienteID: Integer): TObjectList<TDDTUscita>;
    class function GetByOrdineVendita(AOrdineVenditaID: Integer): TObjectList<TDDTUscita>;
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
    'SELECT id, numero_ddt, data_emissione, data_spedizione, cliente_id, ' +
    'ordine_vendita_id, note, creato_il, aggiornato_il ' +
    'FROM ddt_uscita ';

{ TDDTUscita }

constructor TDDTUscita.Create;
begin
  inherited Create;
  FID := 0;
end;

procedure TDDTUscita.LoadFromDataSet(ADataSet: TDataSet);
begin
  FID              := ADataSet.FieldByName('id').AsInteger;
  FNumeroDDT       := ADataSet.FieldByName('numero_ddt').AsString;
  FDataEmissione   := ADataSet.FieldByName('data_emissione').AsDateTime;
  FDataSpedizione  := ADataSet.FieldByName('data_spedizione').AsDateTime;
  FClienteID       := ADataSet.FieldByName('cliente_id').AsInteger;
  FOrdineVenditaID := ADataSet.FieldByName('ordine_vendita_id').AsInteger;
  FNote            := ADataSet.FieldByName('note').AsString;
  FCreatoIl        := ADataSet.FieldByName('creato_il').AsDateTime;
  FAggiornatoIl    := ADataSet.FieldByName('aggiornato_il').AsDateTime;
end;

class function TDDTUscita.GetByID(AID: Integer): TDDTUscita;
var
  LAutoQuery: TAutoQuery;
begin
  Result := nil;

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE id = :id', [AID]);
  try
    if not LAutoQuery.Query.IsEmpty then
    begin
      Result := TDDTUscita.Create;
      Result.LoadFromDataSet(LAutoQuery.Query);
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TDDTUscita.GetByNumero(const ANumeroDDT: string; AClienteID: Integer): TDDTUscita;
var
  LAutoQuery: TAutoQuery;
begin
  // numero_ddt e' univoco solo insieme a cliente_id (vincolo
  // uq_ddt_uscita_numero_cliente).
  Result := nil;

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE numero_ddt = :numero_ddt ' +
    'AND cliente_id = :cliente_id',
    [ANumeroDDT, AClienteID]);
  try
    if not LAutoQuery.Query.IsEmpty then
    begin
      Result := TDDTUscita.Create;
      Result.LoadFromDataSet(LAutoQuery.Query);
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TDDTUscita.GetAll: TObjectList<TDDTUscita>;
var
  LAutoQuery: TAutoQuery;
  LDDT: TDDTUscita;
begin
  Result := TObjectList<TDDTUscita>.Create(True); // possiede gli oggetti

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'ORDER BY data_spedizione DESC');
  try
    while not LAutoQuery.Query.Eof do
    begin
      LDDT := TDDTUscita.Create;
      LDDT.LoadFromDataSet(LAutoQuery.Query);
      Result.Add(LDDT);
      LAutoQuery.Query.Next;
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TDDTUscita.GetByCliente(AClienteID: Integer): TObjectList<TDDTUscita>;
var
  LAutoQuery: TAutoQuery;
  LDDT: TDDTUscita;
begin
  // Storico spedizioni verso un cliente, dal piu' recente. Base per lo
  // scenario di interrogazione vendite (2.2) quando la richiesta
  // riguarda le consegne piuttosto che gli ordini.
  Result := TObjectList<TDDTUscita>.Create(True);

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE cliente_id = :cliente_id ' +
    'ORDER BY data_spedizione DESC',
    [AClienteID]);
  try
    while not LAutoQuery.Query.Eof do
    begin
      LDDT := TDDTUscita.Create;
      LDDT.LoadFromDataSet(LAutoQuery.Query);
      Result.Add(LDDT);
      LAutoQuery.Query.Next;
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TDDTUscita.GetByOrdineVendita(AOrdineVenditaID: Integer): TObjectList<TDDTUscita>;
var
  LAutoQuery: TAutoQuery;
  LDDT: TDDTUscita;
begin
  // Un ordine di vendita puo' essere evaso con piu' spedizioni parziali:
  // questo metodo restituisce tutti i DDT generati per un dato ordine.
  Result := TObjectList<TDDTUscita>.Create(True);

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE ordine_vendita_id = :ordine_vendita_id ' +
    'ORDER BY data_spedizione',
    [AOrdineVenditaID]);
  try
    while not LAutoQuery.Query.Eof do
    begin
      LDDT := TDDTUscita.Create;
      LDDT.LoadFromDataSet(LAutoQuery.Query);
      Result.Add(LDDT);
      LAutoQuery.Query.Next;
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TDDTUscita.Delete(AID: Integer): Boolean;
begin
  // Un DDT uscita e' referenziato da ddt_uscita_righe: in assenza di ON
  // DELETE CASCADE lato DB, la query fallisce se il DDT ha gia' righe.
  // Comportamento voluto: un documento di trasporto emesso e' un dato
  // fiscale/di tracciabilita', non va cancellato una volta registrato.
  Result := TDB.GetInstance.executeQuery(
    'DELETE FROM ddt_uscita WHERE id = :id', [AID]);
end;

function TDDTUscita.Insert: Integer;
var
  LAutoQuery: TAutoQuery;
begin
  // creato_il e aggiornato_il NON compaiono tra i campi inseriti: sono
  // valorizzati dal DEFAULT del database (now()).
  // (numero_ddt, cliente_id) ha un vincolo UNIQUE: un duplicato solleva
  // un'eccezione da gestire a livello di controller.
  LAutoQuery := TDB.GetInstance.getQueryResult(
    'INSERT INTO ddt_uscita ' +
    '(numero_ddt, data_emissione, data_spedizione, cliente_id, ordine_vendita_id, note) ' +
    'VALUES (:numero_ddt, :data_emissione, :data_spedizione, :cliente_id, :ordine_vendita_id, :note) ' +
    'RETURNING id, creato_il, aggiornato_il',
    [FNumeroDDT, FDataEmissione, FDataSpedizione, FClienteID, FOrdineVenditaID, FNote]);
  try
    FID           := LAutoQuery.Query.FieldByName('id').AsInteger;
    FCreatoIl     := LAutoQuery.Query.FieldByName('creato_il').AsDateTime;
    FAggiornatoIl := LAutoQuery.Query.FieldByName('aggiornato_il').AsDateTime;
    Result := FID;
  finally
    LAutoQuery.Free;
  end;
end;

function TDDTUscita.Update: Boolean;
var
  LAutoQuery: TAutoQuery;
begin
  // aggiornato_il NON viene impostato esplicitamente: il trigger
  // trg_ddt_uscita_aggiornato_il lo valorizza automaticamente.
  LAutoQuery := TDB.GetInstance.getQueryResult(
    'UPDATE ddt_uscita SET numero_ddt = :numero_ddt, ' +
    'data_emissione = :data_emissione, data_spedizione = :data_spedizione, ' +
    'cliente_id = :cliente_id, ordine_vendita_id = :ordine_vendita_id, ' +
    'note = :note ' +
    'WHERE id = :id ' +
    'RETURNING aggiornato_il',
    [FNumeroDDT, FDataEmissione, FDataSpedizione, FClienteID, FOrdineVenditaID, FNote, FID]);
  try
    Result := not LAutoQuery.Query.IsEmpty;
    if Result then
      FAggiornatoIl := LAutoQuery.Query.FieldByName('aggiornato_il').AsDateTime;
  finally
    LAutoQuery.Free;
  end;
end;

function TDDTUscita.Save: Boolean;
begin
  if FID = 0 then
  begin
    Insert;
    Result := FID > 0;
  end
  else
    Result := Update;
end;

function TDDTUscita.ToJSONObject: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('id', TJSONNumber.Create(FID));
  Result.AddPair('numero_ddt', FNumeroDDT);
  Result.AddPair('data_emissione', DateToISO8601(FDataEmissione));
  Result.AddPair('data_spedizione', DateToISO8601(FDataSpedizione));
  Result.AddPair('cliente_id', TJSONNumber.Create(FClienteID));
  Result.AddPair('ordine_vendita_id', TJSONNumber.Create(FOrdineVenditaID));
  Result.AddPair('note', FNote);
  Result.AddPair('creato_il', DateToISO8601(FCreatoIl));
  Result.AddPair('aggiornato_il', DateToISO8601(FAggiornatoIl));
end;

procedure TDDTUscita.FromJSONObject(AJSON: TJSONObject);
var
  LValInt: Integer;
  LValStr: string;
begin
  // id, creato_il, aggiornato_il NON vengono letti dal payload in
  // ingresso: sono gestiti dal database, mai dal client
  if AJSON.TryGetValue<string>('numero_ddt', LValStr) then
    FNumeroDDT := LValStr;
  if AJSON.TryGetValue<string>('data_emissione', LValStr) then
    FDataEmissione := ISO8601ToDate(LValStr);
  if AJSON.TryGetValue<string>('data_spedizione', LValStr) then
    FDataSpedizione := ISO8601ToDate(LValStr);
  if AJSON.TryGetValue<Integer>('cliente_id', LValInt) then
    FClienteID := LValInt;
  if AJSON.TryGetValue<Integer>('ordine_vendita_id', LValInt) then
    FOrdineVenditaID := LValInt;
  if AJSON.TryGetValue<string>('note', LValStr) then
    FNote := LValStr;
end;

end.
