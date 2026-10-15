unit uModelRicettaSemilavoratoRiga;

interface

uses
  System.SysUtils,
  System.Variants,
  System.Generics.Collections,
  Data.DB, System.JSON, System.DateUtils,
  DbU;

type
  // Rappresenta una riga/componente di una versione di ricetta di
  // semilavorato (tabella ricette_semilavorati_righe). Modella un nodo
  // di un albero di distinta base: il componente e' ESATTAMENTE UNO tra
  // - una materia prima (MateriaPrimaID valorizzato): componente foglia
  // - un altro semilavorato (SemilavoratoFiglioID valorizzato): nodo
  //   ricorsivo, che ha a sua volta una propria ricetta con le proprie
  //   righe
  // Il DDL impone questo XOR con un CHECK constraint
  // (chk_componente_semilavorato); lo ripetiamo qui lato Delphi in
  // EnsureComponenteValido per fallire con un errore leggibile PRIMA di
  // arrivare al DB, invece di lasciare che sia PostgreSQL a rifiutare
  // l'INSERT con un errore meno chiaro per chi chiama (incluso un tool
  // MCP che compone questi dati da una richiesta in linguaggio naturale).
  //
  // MateriaPrimaID e SemilavoratoFiglioID usano 0 come sentinella per
  // NULL, stesso criterio di ValidaAl in TRicettaSemilavorato.
  //
  // UnitaMisuraDose puo' differire dall'unita' di misura di magazzino
  // del componente (es. dose in grammi per una materia prima che si
  // acquista e stocca in kg): e' un dato voluto, non un errore.
  TRicettaSemilavoratoRiga = class
  private
    FID: Integer;
    FRicettaID: Integer;
    FMateriaPrimaID: Integer;        // 0 = NULL
    FSemilavoratoFiglioID: Integer;  // 0 = NULL
    FQuantitaStandard: Currency;
    FUnitaMisuraDose: string;
    FCreatoIl: TDateTime;
    FAggiornatoIl: TDateTime;

    procedure LoadFromDataSet(ADataSet: TDataSet);
    procedure EnsureComponenteValido;
    function GetIsComponenteMateriaPrima: Boolean;
  public
    constructor Create;

    property ID: Integer read FID write FID;
    property RicettaID: Integer read FRicettaID write FRicettaID;
    property MateriaPrimaID: Integer read FMateriaPrimaID write FMateriaPrimaID;
    property SemilavoratoFiglioID: Integer read FSemilavoratoFiglioID write FSemilavoratoFiglioID;
    property QuantitaStandard: Currency read FQuantitaStandard write FQuantitaStandard;
    property UnitaMisuraDose: string read FUnitaMisuraDose write FUnitaMisuraDose;
    property IsComponenteMateriaPrima: Boolean read GetIsComponenteMateriaPrima;

    // Campi di audit: sola lettura, gestiti dal database (default/trigger
    // trg_ricette_semilavorati_righe_aggiornato_il)
    property CreatoIl: TDateTime read FCreatoIl;
    property AggiornatoIl: TDateTime read FAggiornatoIl;

    // Operazioni CRUD
    class function GetByID(AID: Integer): TRicettaSemilavoratoRiga;
    class function GetByRicetta(ARicettaID: Integer): TObjectList<TRicettaSemilavoratoRiga>;
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
    'SELECT id, ricetta_id, materia_prima_id, semilavorato_figlio_id, ' +
    'quantita_standard, unita_misura_dose, creato_il, aggiornato_il ' +
    'FROM ricette_semilavorati_righe ';

{ TRicettaSemilavoratoRiga }

constructor TRicettaSemilavoratoRiga.Create;
begin
  inherited Create;
  FID := 0;
  FMateriaPrimaID := 0;
  FSemilavoratoFiglioID := 0;
end;

function TRicettaSemilavoratoRiga.GetIsComponenteMateriaPrima: Boolean;
begin
  Result := FMateriaPrimaID <> 0;
end;

procedure TRicettaSemilavoratoRiga.EnsureComponenteValido;
begin
  // Replica lato Delphi il CHECK chk_componente_semilavorato: esattamente
  // uno tra MateriaPrimaID e SemilavoratoFiglioID deve essere valorizzato.
  if (FMateriaPrimaID <> 0) = (FSemilavoratoFiglioID <> 0) then
    raise Exception.Create(
      'TRicettaSemilavoratoRiga: la riga deve avere ESATTAMENTE uno tra ' +
      'MateriaPrimaID e SemilavoratoFiglioID valorizzato (mai entrambi, mai nessuno).');
end;

procedure TRicettaSemilavoratoRiga.LoadFromDataSet(ADataSet: TDataSet);
begin
  FID        := ADataSet.FieldByName('id').AsInteger;
  FRicettaID := ADataSet.FieldByName('ricetta_id').AsInteger;

  if ADataSet.FieldByName('materia_prima_id').IsNull then
    FMateriaPrimaID := 0
  else
    FMateriaPrimaID := ADataSet.FieldByName('materia_prima_id').AsInteger;

  if ADataSet.FieldByName('semilavorato_figlio_id').IsNull then
    FSemilavoratoFiglioID := 0
  else
    FSemilavoratoFiglioID := ADataSet.FieldByName('semilavorato_figlio_id').AsInteger;

  FQuantitaStandard := ADataSet.FieldByName('quantita_standard').AsCurrency;
  FUnitaMisuraDose   := ADataSet.FieldByName('unita_misura_dose').AsString;
  FCreatoIl          := ADataSet.FieldByName('creato_il').AsDateTime;
  FAggiornatoIl      := ADataSet.FieldByName('aggiornato_il').AsDateTime;
end;

class function TRicettaSemilavoratoRiga.GetByID(AID: Integer): TRicettaSemilavoratoRiga;
var
  LAutoQuery: TAutoQuery;
begin
  Result := nil;

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE id = :id', [AID]);
  try
    if not LAutoQuery.Query.IsEmpty then
    begin
      Result := TRicettaSemilavoratoRiga.Create;
      Result.LoadFromDataSet(LAutoQuery.Query);
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TRicettaSemilavoratoRiga.GetByRicetta(ARicettaID: Integer): TObjectList<TRicettaSemilavoratoRiga>;
var
  LAutoQuery: TAutoQuery;
  LRiga: TRicettaSemilavoratoRiga;
begin
  // Modalita' d'accesso principale: le righe si consultano sempre
  // insieme alla testata ricetta a cui appartengono.
  Result := TObjectList<TRicettaSemilavoratoRiga>.Create(True);

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE ricetta_id = :ricetta_id ORDER BY id',
    [ARicettaID]);
  try
    while not LAutoQuery.Query.Eof do
    begin
      LRiga := TRicettaSemilavoratoRiga.Create;
      LRiga.LoadFromDataSet(LAutoQuery.Query);
      Result.Add(LRiga);
      LAutoQuery.Query.Next;
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TRicettaSemilavoratoRiga.Delete(AID: Integer): Boolean;
begin
  // Nessun'altra tabella referenzia ricette_semilavorati_righe come FK:
  // e' un nodo foglia nello schema, la cancellazione non incontra
  // vincoli di integrita' referenziale da parte di altre tabelle.
  Result := TDB.GetInstance.executeQuery(
    'DELETE FROM ricette_semilavorati_righe WHERE id = :id', [AID]);
end;

function TRicettaSemilavoratoRiga.Insert: Integer;
var
  LAutoQuery: TAutoQuery;
  LMateriaPrimaParam, LSemilavoratoFiglioParam: Variant;
begin
  EnsureComponenteValido;

  if FMateriaPrimaID = 0 then LMateriaPrimaParam := Null else LMateriaPrimaParam := FMateriaPrimaID;
  if FSemilavoratoFiglioID = 0 then LSemilavoratoFiglioParam := Null else LSemilavoratoFiglioParam := FSemilavoratoFiglioID;

  // creato_il e aggiornato_il NON compaiono tra i campi inseriti: sono
  // valorizzati dal DEFAULT del database (now()).
  LAutoQuery := TDB.GetInstance.getQueryResult(
    'INSERT INTO ricette_semilavorati_righe ' +
    '(ricetta_id, materia_prima_id, semilavorato_figlio_id, quantita_standard, unita_misura_dose) ' +
    'VALUES (:ricetta_id, :materia_prima_id, :semilavorato_figlio_id, :quantita_standard, :unita_misura_dose) ' +
    'RETURNING id, creato_il, aggiornato_il',
    [FRicettaID, LMateriaPrimaParam, LSemilavoratoFiglioParam, FQuantitaStandard, FUnitaMisuraDose]);
  try
    FID           := LAutoQuery.Query.FieldByName('id').AsInteger;
    FCreatoIl     := LAutoQuery.Query.FieldByName('creato_il').AsDateTime;
    FAggiornatoIl := LAutoQuery.Query.FieldByName('aggiornato_il').AsDateTime;
    Result := FID;
  finally
    LAutoQuery.Free;
  end;
end;

function TRicettaSemilavoratoRiga.Update: Boolean;
var
  LAutoQuery: TAutoQuery;
  LMateriaPrimaParam, LSemilavoratoFiglioParam: Variant;
begin
  EnsureComponenteValido;

  if FMateriaPrimaID = 0 then LMateriaPrimaParam := Null else LMateriaPrimaParam := FMateriaPrimaID;
  if FSemilavoratoFiglioID = 0 then LSemilavoratoFiglioParam := Null else LSemilavoratoFiglioParam := FSemilavoratoFiglioID;

  // aggiornato_il NON viene impostato esplicitamente: il trigger
  // trg_ricette_semilavorati_righe_aggiornato_il lo valorizza
  // automaticamente.
  LAutoQuery := TDB.GetInstance.getQueryResult(
    'UPDATE ricette_semilavorati_righe SET ricetta_id = :ricetta_id, ' +
    'materia_prima_id = :materia_prima_id, ' +
    'semilavorato_figlio_id = :semilavorato_figlio_id, ' +
    'quantita_standard = :quantita_standard, unita_misura_dose = :unita_misura_dose ' +
    'WHERE id = :id ' +
    'RETURNING aggiornato_il',
    [FRicettaID, LMateriaPrimaParam, LSemilavoratoFiglioParam, FQuantitaStandard, FUnitaMisuraDose, FID]);
  try
    Result := not LAutoQuery.Query.IsEmpty;
    if Result then
      FAggiornatoIl := LAutoQuery.Query.FieldByName('aggiornato_il').AsDateTime;
  finally
    LAutoQuery.Free;
  end;
end;

function TRicettaSemilavoratoRiga.Save: Boolean;
begin
  if FID = 0 then
  begin
    Insert;
    Result := FID > 0;
  end
  else
    Result := Update;
end;

function TRicettaSemilavoratoRiga.ToJSONObject: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('id', TJSONNumber.Create(FID));
  Result.AddPair('ricetta_id', TJSONNumber.Create(FRicettaID));
  if FMateriaPrimaID = 0 then
    Result.AddPair('materia_prima_id', TJSONNull.Create)
  else
    Result.AddPair('materia_prima_id', TJSONNumber.Create(FMateriaPrimaID));
  if FSemilavoratoFiglioID = 0 then
    Result.AddPair('semilavorato_figlio_id', TJSONNull.Create)
  else
    Result.AddPair('semilavorato_figlio_id', TJSONNumber.Create(FSemilavoratoFiglioID));
  Result.AddPair('quantita_standard', TJSONNumber.Create(FQuantitaStandard));
  Result.AddPair('unita_misura_dose', FUnitaMisuraDose);
  Result.AddPair('creato_il', DateToISO8601(FCreatoIl));
  Result.AddPair('aggiornato_il', DateToISO8601(FAggiornatoIl));
end;

procedure TRicettaSemilavoratoRiga.FromJSONObject(AJSON: TJSONObject);
var
  LValInt: Integer;
  LValStr: string;
  LValNum: TJSONValue;
begin
  // id, creato_il, aggiornato_il NON vengono letti dal payload in
  // ingresso: sono gestiti dal database, mai dal client
  if AJSON.TryGetValue<Integer>('ricetta_id', LValInt) then
    FRicettaID := LValInt;
  if AJSON.TryGetValue<Integer>('materia_prima_id', LValInt) then
    FMateriaPrimaID := LValInt;
  if AJSON.TryGetValue<Integer>('semilavorato_figlio_id', LValInt) then
    FSemilavoratoFiglioID := LValInt;
  if AJSON.TryGetValue<string>('unita_misura_dose', LValStr) then
    FUnitaMisuraDose := LValStr;

  // Campo numerico decimale: letto come TJSONNumber per preservarne la
  // precisione (evitando conversioni intermedie a Double)
  if AJSON.TryGetValue<TJSONValue>('quantita_standard', LValNum) and (LValNum is TJSONNumber) then
    FQuantitaStandard := TJSONNumber(LValNum).AsDouble;
end;

end.
