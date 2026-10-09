unit uModelLottoMateriaPrima;

interface

uses
  System.SysUtils,
  System.Generics.Collections,
  Data.DB, System.JSON, System.DateUtils,
  FireDAC.Comp.Client,
  DbU;

type
  // Lotto fisico di materia prima ricevuto da un fornitore (lotti_materie_prime): l'unita'
  // minima di tracciabilita' del richiamo (2.1). Da un lotto non conforme si risale ai
  // prodotti finiti che lo contengono tramite le catene di consumo.
  // Quantita e QuantitaDisponibile sono NUMERIC(10,4): si usa Currency (intero scalato a 4
  // decimali) per avere la stessa precisione senza gli arrotondamenti binari del floating
  // point, che sommati su molti movimenti farebbero divergere la giacenza.
  // Non ha UnitaMisura: la eredita dalla riga DDT di origine
  // (ddt_entrata_righe.unita_misura), per non duplicarla.
  TLottoMateriaPrima = class
  private
    FID: Integer;
    FMateriaPrimaID: Integer;
    FCodiceLotto: string;
    FDataScadenza: TDateTime;
    FQuantita: Currency;
    FQuantitaDisponibile: Currency;
    FDdtEntrataRigaID: Integer;
    FCreatoIl: TDateTime;
    FAggiornatoIl: TDateTime;

    procedure LoadFromDataSet(ADataSet: TDataSet);
  public
    constructor Create;

    property ID: Integer read FID write FID;
    property MateriaPrimaID: Integer read FMateriaPrimaID write FMateriaPrimaID;
    property CodiceLotto: string read FCodiceLotto write FCodiceLotto;
    property DataScadenza: TDateTime read FDataScadenza write FDataScadenza;
    property Quantita: Currency read FQuantita write FQuantita;
    property QuantitaDisponibile: Currency read FQuantitaDisponibile write FQuantitaDisponibile;
    property DdtEntrataRigaID: Integer read FDdtEntrataRigaID write FDdtEntrataRigaID;

    property CreatoIl: TDateTime read FCreatoIl;
    property AggiornatoIl: TDateTime read FAggiornatoIl;

    class function GetByID(AID: Integer): TLottoMateriaPrima;
    class function GetByCodiceLotto(AMateriaPrimaID: Integer;
      const ACodiceLotto: string): TLottoMateriaPrima;
    // Cerca solo per codice_lotto, senza materia_prima_id (a differenza di
    // GetByCodiceLotto, univoca per uq_lotto_materia_prima). Serve al tool di
    // ritiro/richiamo, dove l'utente dice solo il codice. Puo' dare piu' risultati:
    // l'unicita' vale per coppia (materia_prima_id, codice_lotto), non globalmente. Lista
    // vuota = esito legittimo, lo segnala il chiamante.
    class function GetByCodiceLottoGlobale(const ACodiceLotto: string): TObjectList<TLottoMateriaPrima>;
    class function GetAll: TObjectList<TLottoMateriaPrima>;
    class function GetByMateriaPrima(AMateriaPrimaID: Integer): TObjectList<TLottoMateriaPrima>;
    class function Delete(AID: Integer): Boolean;

    // Decremento atomico e condizionato della giacenza. Va chiamato dentro una transazione
    // di un Service (TServizioGiacenza): riceve la connessione, cosi' UPDATE e INSERT del
    // consumo condividono commit/rollback. La WHERE "AND quantita_disponibile >= :quantita"
    // lo rende sicuro in concorrenza: o decrementa senza andare sotto zero, o non tocca
    // nulla (Result = False), senza una SELECT preventiva che aprirebbe una race condition.
    class function DecrementaQuantitaDisponibile(AID: Integer; AQuantita: Currency;
      AConnection: TFDConnection): Boolean;

    function Insert: Integer;   // restituisce l'ID generato
    function Update: Boolean;
    function Save: Boolean;     // Insert o Update a seconda che FID sia valorizzato
    function ToJSONObject: TJSONObject;
    procedure FromJSONObject(AJSON: TJSONObject);

  end;

implementation

const
  SQL_SELECT_BASE =
    'SELECT id, materia_prima_id, codice_lotto, data_scadenza, quantita, ' +
    'quantita_disponibile, ddt_entrata_riga_id, creato_il, aggiornato_il ' +
    'FROM lotti_materie_prime ';

constructor TLottoMateriaPrima.Create;
begin
  inherited Create;
  FID := 0;
end;

procedure TLottoMateriaPrima.LoadFromDataSet(ADataSet: TDataSet);
begin
  FID                  := ADataSet.FieldByName('id').AsInteger;
  FMateriaPrimaID      := ADataSet.FieldByName('materia_prima_id').AsInteger;
  FCodiceLotto         := ADataSet.FieldByName('codice_lotto').AsString;
  FDataScadenza        := ADataSet.FieldByName('data_scadenza').AsDateTime;
  FQuantita            := ADataSet.FieldByName('quantita').AsCurrency;
  FQuantitaDisponibile := ADataSet.FieldByName('quantita_disponibile').AsCurrency;
  FDdtEntrataRigaID    := ADataSet.FieldByName('ddt_entrata_riga_id').AsInteger;
  FCreatoIl            := ADataSet.FieldByName('creato_il').AsDateTime;
  FAggiornatoIl        := ADataSet.FieldByName('aggiornato_il').AsDateTime;
end;

class function TLottoMateriaPrima.GetByID(AID: Integer): TLottoMateriaPrima;
var
  LAutoQuery: TAutoQuery;
begin
  Result := nil;

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE id = :id', [AID]);
  try
    if not LAutoQuery.Query.IsEmpty then
    begin
      Result := TLottoMateriaPrima.Create;
      Result.LoadFromDataSet(LAutoQuery.Query);
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TLottoMateriaPrima.GetByCodiceLotto(AMateriaPrimaID: Integer;
  const ACodiceLotto: string): TLottoMateriaPrima;
var
  LAutoQuery: TAutoQuery;
begin
  // Il codice lotto e' univoco solo per materia prima (uq_lotto_materia_prima), non
  // globalmente.
  Result := nil;

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE materia_prima_id = :materia_prima_id ' +
    'AND codice_lotto = :codice_lotto',
    [AMateriaPrimaID, ACodiceLotto]);
  try
    if not LAutoQuery.Query.IsEmpty then
    begin
      Result := TLottoMateriaPrima.Create;
      Result.LoadFromDataSet(LAutoQuery.Query);
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TLottoMateriaPrima.GetByCodiceLottoGlobale(
  const ACodiceLotto: string): TObjectList<TLottoMateriaPrima>;
var
  LAutoQuery: TAutoQuery;
  LLotto: TLottoMateriaPrima;
begin
  // Come dichiarato: nessun filtro su materia_prima_id, 0, 1 o piu' righe. Ordinato per id
  // e non FEFO: i risultati possono essere di materie prime diverse.
  Result := TObjectList<TLottoMateriaPrima>.Create(True);

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE codice_lotto = :codice_lotto ORDER BY id',
    [ACodiceLotto]);
  try
    while not LAutoQuery.Query.Eof do
    begin
      LLotto := TLottoMateriaPrima.Create;
      LLotto.LoadFromDataSet(LAutoQuery.Query);
      Result.Add(LLotto);
      LAutoQuery.Query.Next;
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TLottoMateriaPrima.GetAll: TObjectList<TLottoMateriaPrima>;
var
  LAutoQuery: TAutoQuery;
  LLotto: TLottoMateriaPrima;
begin
  Result := TObjectList<TLottoMateriaPrima>.Create(True); // possiede gli oggetti

  // Ordine per data_scadenza (FEFO, First Expired First Out).
  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'ORDER BY data_scadenza');
  try
    while not LAutoQuery.Query.Eof do
    begin
      LLotto := TLottoMateriaPrima.Create;
      LLotto.LoadFromDataSet(LAutoQuery.Query);
      Result.Add(LLotto);
      LAutoQuery.Query.Next;
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TLottoMateriaPrima.GetByMateriaPrima(AMateriaPrimaID: Integer): TObjectList<TLottoMateriaPrima>;
var
  LAutoQuery: TAutoQuery;
  LLotto: TLottoMateriaPrima;
begin
  // Lotti di una materia prima, in ordine FEFO. Primo passo del richiamo: dai lotti non
  // conformi si risale a semilavorati e prodotti finiti.
  Result := TObjectList<TLottoMateriaPrima>.Create(True);

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE materia_prima_id = :materia_prima_id ' +
    'ORDER BY data_scadenza',
    [AMateriaPrimaID]);
  try
    while not LAutoQuery.Query.Eof do
    begin
      LLotto := TLottoMateriaPrima.Create;
      LLotto.LoadFromDataSet(LAutoQuery.Query);
      Result.Add(LLotto);
      LAutoQuery.Query.Next;
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TLottoMateriaPrima.Delete(AID: Integer): Boolean;
begin
  // Fallisce se il record e' referenziato (nessun ON DELETE CASCADE): voluto, per non
  // perdere dati di tracciabilita'.
  Result := TDB.GetInstance.executeQuery(
    'DELETE FROM lotti_materie_prime WHERE id = :id', [AID]);
end;

class function TLottoMateriaPrima.DecrementaQuantitaDisponibile(AID: Integer;
  AQuantita: Currency; AConnection: TFDConnection): Boolean;
var
  LQuery: TFDQuery;
begin
  // Query a mano su AConnection e non su una connessione pooled: la UPDATE deve stare nella
  // transazione del chiamante.
  LQuery := TFDQuery.Create(nil);
  try
    LQuery.Connection := AConnection;
    LQuery.SQL.Text :=
      'UPDATE lotti_materie_prime ' +
      'SET quantita_disponibile = quantita_disponibile - :quantita ' +
      'WHERE id = :id AND quantita_disponibile >= :quantita';
    LQuery.ParamByName('quantita').Value := AQuantita;
    LQuery.ParamByName('id').AsInteger := AID;
    LQuery.ExecSQL;

    // RowsAffected = 0: lotto inesistente o AQuantita oltre la giacenza. Result = False
    // dice al chiamante di annullare l'intera operazione.
    Result := LQuery.RowsAffected > 0;
  finally
    LQuery.Free;
  end;
end;

function TLottoMateriaPrima.Insert: Integer;
var
  LAutoQuery: TAutoQuery;
begin
  // creato_il/aggiornato_il: DEFAULT del database.
  LAutoQuery := TDB.GetInstance.getQueryResult(
    'INSERT INTO lotti_materie_prime ' +
    '(materia_prima_id, codice_lotto, data_scadenza, quantita, ' +
    'quantita_disponibile, ddt_entrata_riga_id) ' +
    'VALUES (:materia_prima_id, :codice_lotto, :data_scadenza, :quantita, ' +
    ':quantita_disponibile, :ddt_entrata_riga_id) ' +
    'RETURNING id, creato_il, aggiornato_il',
    [FMateriaPrimaID, FCodiceLotto, FDataScadenza, FQuantita,
     FQuantitaDisponibile, FDdtEntrataRigaID]);
  try
    FID           := LAutoQuery.Query.FieldByName('id').AsInteger;
    FCreatoIl     := LAutoQuery.Query.FieldByName('creato_il').AsDateTime;
    FAggiornatoIl := LAutoQuery.Query.FieldByName('aggiornato_il').AsDateTime;
    Result := FID;
  finally
    LAutoQuery.Free;
  end;
end;

function TLottoMateriaPrima.Update: Boolean;
var
  LAutoQuery: TAutoQuery;
begin
  // aggiornato_il lo imposta il trigger.
  LAutoQuery := TDB.GetInstance.getQueryResult(
    'UPDATE lotti_materie_prime SET materia_prima_id = :materia_prima_id, ' +
    'codice_lotto = :codice_lotto, data_scadenza = :data_scadenza, ' +
    'quantita = :quantita, quantita_disponibile = :quantita_disponibile, ' +
    'ddt_entrata_riga_id = :ddt_entrata_riga_id ' +
    'WHERE id = :id ' +
    'RETURNING aggiornato_il',
    [FMateriaPrimaID, FCodiceLotto, FDataScadenza, FQuantita,
     FQuantitaDisponibile, FDdtEntrataRigaID, FID]);
  try
    Result := not LAutoQuery.Query.IsEmpty;
    if Result then
      FAggiornatoIl := LAutoQuery.Query.FieldByName('aggiornato_il').AsDateTime;
  finally
    LAutoQuery.Free;
  end;
end;

function TLottoMateriaPrima.Save: Boolean;
begin
  if FID = 0 then
  begin
    Insert;
    Result := FID > 0;
  end
  else
    Result := Update;
end;

function TLottoMateriaPrima.ToJSONObject: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('id', TJSONNumber.Create(FID));
  Result.AddPair('materia_prima_id', TJSONNumber.Create(FMateriaPrimaID));
  Result.AddPair('codice_lotto', FCodiceLotto);
  Result.AddPair('data_scadenza', DateToISO8601(FDataScadenza));
  Result.AddPair('quantita', TJSONNumber.Create(FQuantita));
  Result.AddPair('quantita_disponibile', TJSONNumber.Create(FQuantitaDisponibile));
  Result.AddPair('ddt_entrata_riga_id', TJSONNumber.Create(FDdtEntrataRigaID));
  Result.AddPair('creato_il', DateToISO8601(FCreatoIl));
  Result.AddPair('aggiornato_il', DateToISO8601(FAggiornatoIl));
end;

procedure TLottoMateriaPrima.FromJSONObject(AJSON: TJSONObject);
var
  LValInt: Integer;
  LValStr: string;
  LValDate: TJSONValue;
begin
  // Id e audit non si leggono dal payload: li gestisce il database.
  if AJSON.TryGetValue<Integer>('materia_prima_id', LValInt) then
    FMateriaPrimaID := LValInt;
  if AJSON.TryGetValue<string>('codice_lotto', LValStr) then
    FCodiceLotto := LValStr;
  if AJSON.TryGetValue<string>('data_scadenza', LValStr) then
    FDataScadenza := ISO8601ToDate(LValStr);
  if AJSON.TryGetValue<Integer>('ddt_entrata_riga_id', LValInt) then
    FDdtEntrataRigaID := LValInt;

  // Decimali letti come TJSONNumber, per non perdere precisione.
  if AJSON.TryGetValue<TJSONValue>('quantita', LValDate) and (LValDate is TJSONNumber) then
    FQuantita := TJSONNumber(LValDate).AsDouble;
  if AJSON.TryGetValue<TJSONValue>('quantita_disponibile', LValDate) and (LValDate is TJSONNumber) then
    FQuantitaDisponibile := TJSONNumber(LValDate).AsDouble;
end;

end.
