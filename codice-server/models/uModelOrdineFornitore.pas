unit uModelOrdineFornitore;

interface

uses
  System.SysUtils,
  System.Generics.Collections,
  Data.DB, System.JSON, System.DateUtils,
  DbU;

type
  // Testata di un ordine di acquisto (ordini_fornitori). Stato gestito dall'applicazione
  // (il DB ha solo un CHECK sui valori): 'inviato' -> 'confermato' -> 'ricevuto', oppure
  // 'annullato' da uno stato precedente. Il collegamento ai DDT di entrata non ha una FK,
  // e' tracciato a livello di processo.
  TOrdineFornitore = class
  private
    FID: Integer;
    FNumeroOrdine: string;
    FDataOrdine: TDateTime;
    FFornitoreID: Integer;
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
    property FornitoreID: Integer read FFornitoreID write FFornitoreID;
    property Stato: string read FStato write FStato;
    property Note: string read FNote write FNote;

    property CreatoIl: TDateTime read FCreatoIl;
    property AggiornatoIl: TDateTime read FAggiornatoIl;

    class function GetByID(AID: Integer): TOrdineFornitore;
    class function GetByNumero(const ANumeroOrdine: string): TOrdineFornitore;
    class function GetAll: TObjectList<TOrdineFornitore>;
    class function GetByFornitore(AFornitoreID: Integer): TObjectList<TOrdineFornitore>;
    class function GetByStato(const AStato: string): TObjectList<TOrdineFornitore>;
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
    'SELECT id, numero_ordine, data_ordine, fornitore_id, stato, note, ' +
    'creato_il, aggiornato_il ' +
    'FROM ordini_fornitori ';

  // Valori di chk_stato_ordine_fornitore, validati qui prima del DB.
  STATI_VALIDI: array[0..3] of string = ('inviato', 'confermato', 'ricevuto', 'annullato');

constructor TOrdineFornitore.Create;
begin
  inherited Create;
  FID := 0;
  FStato := 'inviato'; // replica il DEFAULT lato database per i nuovi record
end;

procedure TOrdineFornitore.EnsureStatoValido;
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
      'TOrdineFornitore: stato "' + FStato + '" non valido. Valori ammessi: ' +
      'inviato, confermato, ricevuto, annullato.');
end;

procedure TOrdineFornitore.LoadFromDataSet(ADataSet: TDataSet);
begin
  FID           := ADataSet.FieldByName('id').AsInteger;
  FNumeroOrdine := ADataSet.FieldByName('numero_ordine').AsString;
  FDataOrdine   := ADataSet.FieldByName('data_ordine').AsDateTime;
  FFornitoreID  := ADataSet.FieldByName('fornitore_id').AsInteger;
  FStato        := ADataSet.FieldByName('stato').AsString;
  FNote         := ADataSet.FieldByName('note').AsString;
  FCreatoIl     := ADataSet.FieldByName('creato_il').AsDateTime;
  FAggiornatoIl := ADataSet.FieldByName('aggiornato_il').AsDateTime;
end;

class function TOrdineFornitore.GetByID(AID: Integer): TOrdineFornitore;
var
  LAutoQuery: TAutoQuery;
begin
  Result := nil;

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE id = :id', [AID]);
  try
    if not LAutoQuery.Query.IsEmpty then
    begin
      Result := TOrdineFornitore.Create;
      Result.LoadFromDataSet(LAutoQuery.Query);
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TOrdineFornitore.GetByNumero(const ANumeroOrdine: string): TOrdineFornitore;
var
  LAutoQuery: TAutoQuery;
begin
  // numero_ordine e' UNIQUE globale (i DDT lo sono solo per fornitore).
  Result := nil;

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE numero_ordine = :numero_ordine', [ANumeroOrdine]);
  try
    if not LAutoQuery.Query.IsEmpty then
    begin
      Result := TOrdineFornitore.Create;
      Result.LoadFromDataSet(LAutoQuery.Query);
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TOrdineFornitore.GetAll: TObjectList<TOrdineFornitore>;
var
  LAutoQuery: TAutoQuery;
  LOrdine: TOrdineFornitore;
begin
  Result := TObjectList<TOrdineFornitore>.Create(True); // possiede gli oggetti

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'ORDER BY data_ordine DESC');
  try
    while not LAutoQuery.Query.Eof do
    begin
      LOrdine := TOrdineFornitore.Create;
      LOrdine.LoadFromDataSet(LAutoQuery.Query);
      Result.Add(LOrdine);
      LAutoQuery.Query.Next;
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TOrdineFornitore.GetByFornitore(AFornitoreID: Integer): TObjectList<TOrdineFornitore>;
var
  LAutoQuery: TAutoQuery;
  LOrdine: TOrdineFornitore;
begin
  Result := TObjectList<TOrdineFornitore>.Create(True);

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE fornitore_id = :fornitore_id ' +
    'ORDER BY data_ordine DESC',
    [AFornitoreID]);
  try
    while not LAutoQuery.Query.Eof do
    begin
      LOrdine := TOrdineFornitore.Create;
      LOrdine.LoadFromDataSet(LAutoQuery.Query);
      Result.Add(LOrdine);
      LAutoQuery.Query.Next;
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TOrdineFornitore.GetByStato(const AStato: string): TObjectList<TOrdineFornitore>;
var
  LAutoQuery: TAutoQuery;
  LOrdine: TOrdineFornitore;
begin
  // Es. gli ordini 'inviato' o 'confermato' in attesa di consegna.
  Result := TObjectList<TOrdineFornitore>.Create(True);

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE stato = :stato ORDER BY data_ordine',
    [AStato]);
  try
    while not LAutoQuery.Query.Eof do
    begin
      LOrdine := TOrdineFornitore.Create;
      LOrdine.LoadFromDataSet(LAutoQuery.Query);
      Result.Add(LOrdine);
      LAutoQuery.Query.Next;
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TOrdineFornitore.Delete(AID: Integer): Boolean;
begin
  // Fallisce se il record e' referenziato (nessun ON DELETE CASCADE): voluto, per non
  // perdere dati di tracciabilita'.
  Result := TDB.GetInstance.executeQuery(
    'DELETE FROM ordini_fornitori WHERE id = :id', [AID]);
end;

function TOrdineFornitore.Insert: Integer;
var
  LAutoQuery: TAutoQuery;
begin
  EnsureStatoValido;

  // creato_il/aggiornato_il: DEFAULT del database. Un duplicato sul vincolo UNIQUE solleva
  // un'eccezione da gestire nel controller.
  LAutoQuery := TDB.GetInstance.getQueryResult(
    'INSERT INTO ordini_fornitori (numero_ordine, data_ordine, fornitore_id, stato, note) ' +
    'VALUES (:numero_ordine, :data_ordine, :fornitore_id, :stato, :note) ' +
    'RETURNING id, creato_il, aggiornato_il',
    [FNumeroOrdine, FDataOrdine, FFornitoreID, FStato, FNote]);
  try
    FID           := LAutoQuery.Query.FieldByName('id').AsInteger;
    FCreatoIl     := LAutoQuery.Query.FieldByName('creato_il').AsDateTime;
    FAggiornatoIl := LAutoQuery.Query.FieldByName('aggiornato_il').AsDateTime;
    Result := FID;
  finally
    LAutoQuery.Free;
  end;
end;

function TOrdineFornitore.Update: Boolean;
var
  LAutoQuery: TAutoQuery;
begin
  EnsureStatoValido;

  // aggiornato_il lo imposta il trigger.
  LAutoQuery := TDB.GetInstance.getQueryResult(
    'UPDATE ordini_fornitori SET numero_ordine = :numero_ordine, ' +
    'data_ordine = :data_ordine, fornitore_id = :fornitore_id, ' +
    'stato = :stato, note = :note ' +
    'WHERE id = :id ' +
    'RETURNING aggiornato_il',
    [FNumeroOrdine, FDataOrdine, FFornitoreID, FStato, FNote, FID]);
  try
    Result := not LAutoQuery.Query.IsEmpty;
    if Result then
      FAggiornatoIl := LAutoQuery.Query.FieldByName('aggiornato_il').AsDateTime;
  finally
    LAutoQuery.Free;
  end;
end;

function TOrdineFornitore.Save: Boolean;
begin
  if FID = 0 then
  begin
    Insert;
    Result := FID > 0;
  end
  else
    Result := Update;
end;

function TOrdineFornitore.ToJSONObject: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('id', TJSONNumber.Create(FID));
  Result.AddPair('numero_ordine', FNumeroOrdine);
  Result.AddPair('data_ordine', DateToISO8601(FDataOrdine));
  Result.AddPair('fornitore_id', TJSONNumber.Create(FFornitoreID));
  Result.AddPair('stato', FStato);
  Result.AddPair('note', FNote);
  Result.AddPair('creato_il', DateToISO8601(FCreatoIl));
  Result.AddPair('aggiornato_il', DateToISO8601(FAggiornatoIl));
end;

procedure TOrdineFornitore.FromJSONObject(AJSON: TJSONObject);
var
  LValInt: Integer;
  LValStr: string;
begin
  // Id e audit non si leggono dal payload: li gestisce il database.
  if AJSON.TryGetValue<string>('numero_ordine', LValStr) then
    FNumeroOrdine := LValStr;
  if AJSON.TryGetValue<string>('data_ordine', LValStr) then
    FDataOrdine := ISO8601ToDate(LValStr);
  if AJSON.TryGetValue<Integer>('fornitore_id', LValInt) then
    FFornitoreID := LValInt;
  if AJSON.TryGetValue<string>('stato', LValStr) then
    FStato := LValStr;
  if AJSON.TryGetValue<string>('note', LValStr) then
    FNote := LValStr;
end;

end.
