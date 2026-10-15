unit uModelOrdineVendita;

interface

uses
  System.SysUtils,
  System.Generics.Collections,
  Data.DB, System.JSON, System.DateUtils,
  DbU;

type
  // Rappresenta la testata di un ordine di vendita verso un cliente
  // (tabella ordini_vendita). Speculare a TOrdineFornitore, con stati
  // diversi: 'confermato' -> 'spedito' -> 'consegnato', oppure
  // 'annullato'. E' l'entita' centrale dello scenario di interrogazione
  // vendite (2.2): report ad hoc per cliente, prodotto/categoria,
  // periodo o area geografica partono tutti da qui e dalle sue righe
  // (ordini_vendita_righe, vedi TOrdineVenditaRiga).
  TOrdineVendita = class
  private
    FID: Integer;
    FNumeroOrdine: string;
    FDataOrdine: TDateTime;
    FClienteID: Integer;
    FStato: string;
    FNote: string;
    FCreatoIl: TDateTime;
    FAggiornatoIl: TDateTime;

    procedure LoadFromDataSet(ADataSet: TDataSet);
    procedure EnsureStatoValido;
  public
    constructor Create;

    property ID: Integer read FID write FID;
    property NumeroOrdine: string read FNumeroOrdine write FNumeroOrdine;
    property DataOrdine: TDateTime read FDataOrdine write FDataOrdine;
    property ClienteID: Integer read FClienteID write FClienteID;
    property Stato: string read FStato write FStato;
    property Note: string read FNote write FNote;

    // Campi di audit: sola lettura, gestiti dal database (default/trigger
    // trg_ordini_vendita_aggiornato_il)
    property CreatoIl: TDateTime read FCreatoIl;
    property AggiornatoIl: TDateTime read FAggiornatoIl;

    // Operazioni CRUD
    class function GetByID(AID: Integer): TOrdineVendita;
    class function GetByNumero(const ANumeroOrdine: string): TOrdineVendita;
    class function GetAll: TObjectList<TOrdineVendita>;
    class function GetByCliente(AClienteID: Integer): TObjectList<TOrdineVendita>;
    class function GetByStato(const AStato: string): TObjectList<TOrdineVendita>;
    class function GetByPeriodo(ADataDa, ADataA: TDateTime): TObjectList<TOrdineVendita>;
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
    'SELECT id, numero_ordine, data_ordine, cliente_id, stato, note, ' +
    'creato_il, aggiornato_il ' +
    'FROM ordini_vendita ';

  // Valori ammessi da chk_stato_ordine_vendita: replicati qui per
  // validare lato Delphi prima di arrivare al DB.
  STATI_VALIDI: array[0..3] of string = ('confermato', 'spedito', 'consegnato', 'annullato');

{ TOrdineVendita }

constructor TOrdineVendita.Create;
begin
  inherited Create;
  FID := 0;
  FStato := 'confermato'; // replica il DEFAULT lato database per i nuovi record
end;

procedure TOrdineVendita.EnsureStatoValido;
var
  LStato: string;
  LValido: Boolean;
begin
  LValido := False;
  for LStato in STATI_VALIDI do
    if SameText(LStato, FStato) then
    begin
      LValido := True;
      Break;
    end;

  if not LValido then
    raise Exception.Create(
      'TOrdineVendita: stato "' + FStato + '" non valido. Valori ammessi: ' +
      'confermato, spedito, consegnato, annullato.');
end;

procedure TOrdineVendita.LoadFromDataSet(ADataSet: TDataSet);
begin
  FID           := ADataSet.FieldByName('id').AsInteger;
  FNumeroOrdine := ADataSet.FieldByName('numero_ordine').AsString;
  FDataOrdine   := ADataSet.FieldByName('data_ordine').AsDateTime;
  FClienteID    := ADataSet.FieldByName('cliente_id').AsInteger;
  FStato        := ADataSet.FieldByName('stato').AsString;
  FNote         := ADataSet.FieldByName('note').AsString;
  FCreatoIl     := ADataSet.FieldByName('creato_il').AsDateTime;
  FAggiornatoIl := ADataSet.FieldByName('aggiornato_il').AsDateTime;
end;

class function TOrdineVendita.GetByID(AID: Integer): TOrdineVendita;
var
  LAutoQuery: TAutoQuery;
begin
  Result := nil;

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE id = :id', [AID]);
  try
    if not LAutoQuery.Query.IsEmpty then
    begin
      Result := TOrdineVendita.Create;
      Result.LoadFromDataSet(LAutoQuery.Query);
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TOrdineVendita.GetByNumero(const ANumeroOrdine: string): TOrdineVendita;
var
  LAutoQuery: TAutoQuery;
begin
  // numero_ordine ha un vincolo UNIQUE globale.
  Result := nil;

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE numero_ordine = :numero_ordine', [ANumeroOrdine]);
  try
    if not LAutoQuery.Query.IsEmpty then
    begin
      Result := TOrdineVendita.Create;
      Result.LoadFromDataSet(LAutoQuery.Query);
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TOrdineVendita.GetAll: TObjectList<TOrdineVendita>;
var
  LAutoQuery: TAutoQuery;
  LOrdine: TOrdineVendita;
begin
  Result := TObjectList<TOrdineVendita>.Create(True); // possiede gli oggetti

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'ORDER BY data_ordine DESC');
  try
    while not LAutoQuery.Query.Eof do
    begin
      LOrdine := TOrdineVendita.Create;
      LOrdine.LoadFromDataSet(LAutoQuery.Query);
      Result.Add(LOrdine);
      LAutoQuery.Query.Next;
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TOrdineVendita.GetByCliente(AClienteID: Integer): TObjectList<TOrdineVendita>;
var
  LAutoQuery: TAutoQuery;
  LOrdine: TOrdineVendita;
begin
  // Storico ordini di un cliente, dal piu' recente: e' esattamente il
  // caso d'uso base dello scenario 2.2 ("un agente commerciale in
  // trattativa vuole lo storico ordini di un cliente").
  Result := TObjectList<TOrdineVendita>.Create(True);

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE cliente_id = :cliente_id ' +
    'ORDER BY data_ordine DESC',
    [AClienteID]);
  try
    while not LAutoQuery.Query.Eof do
    begin
      LOrdine := TOrdineVendita.Create;
      LOrdine.LoadFromDataSet(LAutoQuery.Query);
      Result.Add(LOrdine);
      LAutoQuery.Query.Next;
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TOrdineVendita.GetByStato(const AStato: string): TObjectList<TOrdineVendita>;
var
  LAutoQuery: TAutoQuery;
  LOrdine: TOrdineVendita;
begin
  Result := TObjectList<TOrdineVendita>.Create(True);

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE stato = :stato ORDER BY data_ordine',
    [AStato]);
  try
    while not LAutoQuery.Query.Eof do
    begin
      LOrdine := TOrdineVendita.Create;
      LOrdine.LoadFromDataSet(LAutoQuery.Query);
      Result.Add(LOrdine);
      LAutoQuery.Query.Next;
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TOrdineVendita.GetByPeriodo(ADataDa, ADataA: TDateTime): TObjectList<TOrdineVendita>;
var
  LAutoQuery: TAutoQuery;
  LOrdine: TOrdineVendita;
begin
  // Filtro per intervallo di date: un altro dei parametri "ad hoc"
  // menzionati nello scenario 2.2 ("le vendite di una categoria prodotto
  // nell'ultimo trimestre", "confronto tra due periodi").
  Result := TObjectList<TOrdineVendita>.Create(True);

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE data_ordine BETWEEN :data_da AND :data_a ' +
    'ORDER BY data_ordine',
    [ADataDa, ADataA]);
  try
    while not LAutoQuery.Query.Eof do
    begin
      LOrdine := TOrdineVendita.Create;
      LOrdine.LoadFromDataSet(LAutoQuery.Query);
      Result.Add(LOrdine);
      LAutoQuery.Query.Next;
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TOrdineVendita.Delete(AID: Integer): Boolean;
begin
  // Un ordine vendita e' referenziato da ordini_vendita_righe e
  // ddt_uscita (ordine_vendita_id): in assenza di ON DELETE CASCADE lato
  // DB, la query fallisce se l'ordine ha righe o e' gia' stato evaso.
  // Comportamento voluto: usare stato = 'annullato' invece di cancellare.
  Result := TDB.GetInstance.executeQuery(
    'DELETE FROM ordini_vendita WHERE id = :id', [AID]);
end;

function TOrdineVendita.Insert: Integer;
var
  LAutoQuery: TAutoQuery;
begin
  EnsureStatoValido;

  // creato_il e aggiornato_il NON compaiono tra i campi inseriti: sono
  // valorizzati dal DEFAULT del database (now()). numero_ordine ha un
  // vincolo UNIQUE: un duplicato solleva un'eccezione da gestire a
  // livello di controller.
  LAutoQuery := TDB.GetInstance.getQueryResult(
    'INSERT INTO ordini_vendita (numero_ordine, data_ordine, cliente_id, stato, note) ' +
    'VALUES (:numero_ordine, :data_ordine, :cliente_id, :stato, :note) ' +
    'RETURNING id, creato_il, aggiornato_il',
    [FNumeroOrdine, FDataOrdine, FClienteID, FStato, FNote]);
  try
    FID           := LAutoQuery.Query.FieldByName('id').AsInteger;
    FCreatoIl     := LAutoQuery.Query.FieldByName('creato_il').AsDateTime;
    FAggiornatoIl := LAutoQuery.Query.FieldByName('aggiornato_il').AsDateTime;
    Result := FID;
  finally
    LAutoQuery.Free;
  end;
end;

function TOrdineVendita.Update: Boolean;
var
  LAutoQuery: TAutoQuery;
begin
  EnsureStatoValido;

  // aggiornato_il NON viene impostato esplicitamente: il trigger
  // trg_ordini_vendita_aggiornato_il lo valorizza automaticamente.
  LAutoQuery := TDB.GetInstance.getQueryResult(
    'UPDATE ordini_vendita SET numero_ordine = :numero_ordine, ' +
    'data_ordine = :data_ordine, cliente_id = :cliente_id, ' +
    'stato = :stato, note = :note ' +
    'WHERE id = :id ' +
    'RETURNING aggiornato_il',
    [FNumeroOrdine, FDataOrdine, FClienteID, FStato, FNote, FID]);
  try
    Result := not LAutoQuery.Query.IsEmpty;
    if Result then
      FAggiornatoIl := LAutoQuery.Query.FieldByName('aggiornato_il').AsDateTime;
  finally
    LAutoQuery.Free;
  end;
end;

function TOrdineVendita.Save: Boolean;
begin
  if FID = 0 then
  begin
    Insert;
    Result := FID > 0;
  end
  else
    Result := Update;
end;

function TOrdineVendita.ToJSONObject: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('id', TJSONNumber.Create(FID));
  Result.AddPair('numero_ordine', FNumeroOrdine);
  Result.AddPair('data_ordine', DateToISO8601(FDataOrdine));
  Result.AddPair('cliente_id', TJSONNumber.Create(FClienteID));
  Result.AddPair('stato', FStato);
  Result.AddPair('note', FNote);
  Result.AddPair('creato_il', DateToISO8601(FCreatoIl));
  Result.AddPair('aggiornato_il', DateToISO8601(FAggiornatoIl));
end;

procedure TOrdineVendita.FromJSONObject(AJSON: TJSONObject);
var
  LValInt: Integer;
  LValStr: string;
begin
  // id, creato_il, aggiornato_il NON vengono letti dal payload in
  // ingresso: sono gestiti dal database, mai dal client
  if AJSON.TryGetValue<string>('numero_ordine', LValStr) then
    FNumeroOrdine := LValStr;
  if AJSON.TryGetValue<string>('data_ordine', LValStr) then
    FDataOrdine := ISO8601ToDate(LValStr);
  if AJSON.TryGetValue<Integer>('cliente_id', LValInt) then
    FClienteID := LValInt;
  if AJSON.TryGetValue<string>('stato', LValStr) then
    FStato := LValStr;
  if AJSON.TryGetValue<string>('note', LValStr) then
    FNote := LValStr;
end;

end.
