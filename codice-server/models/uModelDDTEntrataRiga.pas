unit uModelDDTEntrataRiga;

interface

uses
  System.SysUtils,
  System.Generics.Collections,
  Data.DB, System.JSON, System.DateUtils,
  DbU;

type
  // Rappresenta una riga di un DDT di entrata: una materia prima
  // ricevuta, con quantita', unita' di misura e prezzo di acquisto
  // effettivo (tabella ddt_entrata_righe). E' la sorgente da cui viene
  // generato un lotto (lotti_materie_prime.ddt_entrata_riga_id): come
  // segnalato nel commento della colonna nel DDL, UnitaMisura viene
  // "ereditata" dal lotto generato, cioe' il lotto NON ripete il proprio
  // valore ma lo legge da qui tramite la FK — per questo va tenuta
  // aggiornata con attenzione, un errore qui si propaga al lotto.
  //
  // PrezzoUnitario e' il prezzo di acquisto REALE concordato per quella
  // consegna specifica: puo' differire da riga a riga anche per la
  // stessa materia prima (offerte, variazioni di mercato), a differenza
  // di un prezzo di listino fisso sull'anagrafica.
  TDDTEntrataRiga = class
  private
    FID: Integer;
    FDDTEntrataID: Integer;
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
    property DDTEntrataID: Integer read FDDTEntrataID write FDDTEntrataID;
    property MateriaPrimaID: Integer read FMateriaPrimaID write FMateriaPrimaID;
    property Quantita: Currency read FQuantita write FQuantita;
    property UnitaMisura: string read FUnitaMisura write FUnitaMisura;
    property PrezzoUnitario: Currency read FPrezzoUnitario write FPrezzoUnitario;

    // Campi di audit: sola lettura, gestiti dal database (default/trigger
    // trg_ddt_entrata_righe_aggiornato_il)
    property CreatoIl: TDateTime read FCreatoIl;
    property AggiornatoIl: TDateTime read FAggiornatoIl;

    // Operazioni CRUD
    class function GetByID(AID: Integer): TDDTEntrataRiga;
    class function GetAll: TObjectList<TDDTEntrataRiga>;
    class function GetByDDTEntrata(ADDTEntrataID: Integer): TObjectList<TDDTEntrataRiga>;
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
    'SELECT id, ddt_entrata_id, materia_prima_id, quantita, unita_misura, ' +
    'prezzo_unitario, creato_il, aggiornato_il ' +
    'FROM ddt_entrata_righe ';

{ TDDTEntrataRiga }

constructor TDDTEntrataRiga.Create;
begin
  inherited Create;
  FID := 0;
end;

procedure TDDTEntrataRiga.LoadFromDataSet(ADataSet: TDataSet);
begin
  FID             := ADataSet.FieldByName('id').AsInteger;
  FDDTEntrataID   := ADataSet.FieldByName('ddt_entrata_id').AsInteger;
  FMateriaPrimaID := ADataSet.FieldByName('materia_prima_id').AsInteger;
  FQuantita       := ADataSet.FieldByName('quantita').AsCurrency;
  FUnitaMisura    := ADataSet.FieldByName('unita_misura').AsString;
  FPrezzoUnitario := ADataSet.FieldByName('prezzo_unitario').AsCurrency;
  FCreatoIl       := ADataSet.FieldByName('creato_il').AsDateTime;
  FAggiornatoIl   := ADataSet.FieldByName('aggiornato_il').AsDateTime;
end;

class function TDDTEntrataRiga.GetByID(AID: Integer): TDDTEntrataRiga;
var
  LAutoQuery: TAutoQuery;
begin
  Result := nil;

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE id = :id', [AID]);
  try
    if not LAutoQuery.Query.IsEmpty then
    begin
      Result := TDDTEntrataRiga.Create;
      Result.LoadFromDataSet(LAutoQuery.Query);
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TDDTEntrataRiga.GetAll: TObjectList<TDDTEntrataRiga>;
var
  LAutoQuery: TAutoQuery;
  LRiga: TDDTEntrataRiga;
begin
  Result := TObjectList<TDDTEntrataRiga>.Create(True); // possiede gli oggetti

  LAutoQuery := TDB.GetInstance.getQueryResult(SQL_SELECT_BASE + 'ORDER BY id');
  try
    while not LAutoQuery.Query.Eof do
    begin
      LRiga := TDDTEntrataRiga.Create;
      LRiga.LoadFromDataSet(LAutoQuery.Query);
      Result.Add(LRiga);
      LAutoQuery.Query.Next;
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TDDTEntrataRiga.GetByDDTEntrata(ADDTEntrataID: Integer): TObjectList<TDDTEntrataRiga>;
var
  LAutoQuery: TAutoQuery;
  LRiga: TDDTEntrataRiga;
begin
  // Tutte le righe di un DDT: il caso d'uso principale, dato che una
  // testata DDT si consulta sempre insieme alle proprie righe.
  Result := TObjectList<TDDTEntrataRiga>.Create(True);

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE ddt_entrata_id = :ddt_entrata_id ORDER BY id',
    [ADDTEntrataID]);
  try
    while not LAutoQuery.Query.Eof do
    begin
      LRiga := TDDTEntrataRiga.Create;
      LRiga.LoadFromDataSet(LAutoQuery.Query);
      Result.Add(LRiga);
      LAutoQuery.Query.Next;
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TDDTEntrataRiga.Delete(AID: Integer): Boolean;
begin
  // Una riga DDT e' referenziata da lotti_materie_prime
  // (ddt_entrata_riga_id): in assenza di ON DELETE CASCADE lato DB, la
  // query fallisce se la riga ha gia' generato un lotto. Comportamento
  // voluto: la riga DDT e' l'origine documentale del lotto, non va
  // cancellata una volta che il lotto esiste.
  Result := TDB.GetInstance.executeQuery(
    'DELETE FROM ddt_entrata_righe WHERE id = :id', [AID]);
end;

function TDDTEntrataRiga.Insert: Integer;
var
  LAutoQuery: TAutoQuery;
begin
  // creato_il e aggiornato_il NON compaiono tra i campi inseriti: sono
  // valorizzati dal DEFAULT del database (now()).
  LAutoQuery := TDB.GetInstance.getQueryResult(
    'INSERT INTO ddt_entrata_righe ' +
    '(ddt_entrata_id, materia_prima_id, quantita, unita_misura, prezzo_unitario) ' +
    'VALUES (:ddt_entrata_id, :materia_prima_id, :quantita, :unita_misura, :prezzo_unitario) ' +
    'RETURNING id, creato_il, aggiornato_il',
    [FDDTEntrataID, FMateriaPrimaID, FQuantita, FUnitaMisura, FPrezzoUnitario]);
  try
    FID           := LAutoQuery.Query.FieldByName('id').AsInteger;
    FCreatoIl     := LAutoQuery.Query.FieldByName('creato_il').AsDateTime;
    FAggiornatoIl := LAutoQuery.Query.FieldByName('aggiornato_il').AsDateTime;
    Result := FID;
  finally
    LAutoQuery.Free;
  end;
end;

function TDDTEntrataRiga.Update: Boolean;
var
  LAutoQuery: TAutoQuery;
begin
  // aggiornato_il NON viene impostato esplicitamente: il trigger
  // trg_ddt_entrata_righe_aggiornato_il lo valorizza automaticamente.
  LAutoQuery := TDB.GetInstance.getQueryResult(
    'UPDATE ddt_entrata_righe SET ddt_entrata_id = :ddt_entrata_id, ' +
    'materia_prima_id = :materia_prima_id, quantita = :quantita, ' +
    'unita_misura = :unita_misura, prezzo_unitario = :prezzo_unitario ' +
    'WHERE id = :id ' +
    'RETURNING aggiornato_il',
    [FDDTEntrataID, FMateriaPrimaID, FQuantita, FUnitaMisura, FPrezzoUnitario, FID]);
  try
    Result := not LAutoQuery.Query.IsEmpty;
    if Result then
      FAggiornatoIl := LAutoQuery.Query.FieldByName('aggiornato_il').AsDateTime;
  finally
    LAutoQuery.Free;
  end;
end;

function TDDTEntrataRiga.Save: Boolean;
begin
  if FID = 0 then
  begin
    Insert;
    Result := FID > 0;
  end
  else
    Result := Update;
end;

function TDDTEntrataRiga.ToJSONObject: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('id', TJSONNumber.Create(FID));
  Result.AddPair('ddt_entrata_id', TJSONNumber.Create(FDDTEntrataID));
  Result.AddPair('materia_prima_id', TJSONNumber.Create(FMateriaPrimaID));
  Result.AddPair('quantita', TJSONNumber.Create(FQuantita));
  Result.AddPair('unita_misura', FUnitaMisura);
  Result.AddPair('prezzo_unitario', TJSONNumber.Create(FPrezzoUnitario));
  Result.AddPair('creato_il', DateToISO8601(FCreatoIl));
  Result.AddPair('aggiornato_il', DateToISO8601(FAggiornatoIl));
end;

procedure TDDTEntrataRiga.FromJSONObject(AJSON: TJSONObject);
var
  LValInt: Integer;
  LValStr: string;
  LValNum: TJSONValue;
begin
  // id, creato_il, aggiornato_il NON vengono letti dal payload in
  // ingresso: sono gestiti dal database, mai dal client
  if AJSON.TryGetValue<Integer>('ddt_entrata_id', LValInt) then
    FDDTEntrataID := LValInt;
  if AJSON.TryGetValue<Integer>('materia_prima_id', LValInt) then
    FMateriaPrimaID := LValInt;
  if AJSON.TryGetValue<string>('unita_misura', LValStr) then
    FUnitaMisura := LValStr;

  // Campi numerici decimali: letti come TJSONNumber per preservarne la
  // precisione (evitando conversioni intermedie a Double)
  if AJSON.TryGetValue<TJSONValue>('quantita', LValNum) and (LValNum is TJSONNumber) then
    FQuantita := TJSONNumber(LValNum).AsDouble;
  if AJSON.TryGetValue<TJSONValue>('prezzo_unitario', LValNum) and (LValNum is TJSONNumber) then
    FPrezzoUnitario := TJSONNumber(LValNum).AsDouble;
end;

end.
