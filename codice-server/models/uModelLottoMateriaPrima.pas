unit uModelLottoMateriaPrima;

interface

uses
  System.SysUtils,
  System.Generics.Collections,
  Data.DB, System.JSON, System.DateUtils,
  FireDAC.Comp.Client,
  DbU;

type
  // Rappresenta un lotto fisico di materia prima ricevuto da un fornitore
  // (tabella lotti_materie_prime). E' l'unita' di tracciabilita' minima
  // usata dallo scenario di ritiro/richiamo (2.1): un lotto puo' essere
  // dichiarato non conforme, ed e' da un lotto che si risale a quali
  // prodotti finiti lo contengono (tramite le catene di consumo) e quanta
  // quantita' e' ancora disponibile in giacenza.
  //
  // Note sui tipi: Quantita e QuantitaDisponibile mappano colonne
  // NUMERIC(10,4) PostgreSQL. Si usa Currency (non Double) perche' e' un
  // intero scalato a 4 decimali esatti in Delphi: stessa precisione della
  // colonna DB, senza gli arrotondamenti binari del floating point che
  // altrimenti, sommati su molti movimenti di magazzino, potrebbero far
  // divergere QuantitaDisponibile dal valore reale.
  //
  // NON ha un campo UnitaMisura proprio: lo eredita dalla riga DDT di
  // origine (ddt_entrata_righe.unita_misura, tramite DdtEntrataRigaID) —
  // scelta del DDL per evitare di duplicare/disallineare l'unita' di
  // misura tra riga DDT e lotto generato da essa.
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

    // Campi di audit: sola lettura, gestiti dal database (default/trigger
    // trg_lotti_materie_prime_aggiornato_il)
    property CreatoIl: TDateTime read FCreatoIl;
    property AggiornatoIl: TDateTime read FAggiornatoIl;

    // Operazioni CRUD
    class function GetByID(AID: Integer): TLottoMateriaPrima;
    class function GetByCodiceLotto(AMateriaPrimaID: Integer;
      const ACodiceLotto: string): TLottoMateriaPrima;
    // A differenza di GetByCodiceLotto (che richiede materia_prima_id ed
    // e' quindi univoca per costruzione, vedi vincolo uq_lotto_materia_prima),
    // questa cerca SOLO per codice_lotto, senza sapere a quale materia
    // prima appartiene. Serve al tool MCP di ritiro/richiamo
    // (uRitiroRichiamoToolProvider.pas), dove il modello riceve dall'utente
    // un codice lotto testuale e non un id numerico ne' l'id della materia
    // prima. Puo' restituire piu' di un risultato: uq_lotto_materia_prima
    // garantisce l'unicita' solo per coppia (materia_prima_id, codice_lotto),
    // NON globalmente - due materie prime diverse possono avere entrambe un
    // lotto con lo stesso codice. La lista vuota (nessun match) e' un esito
    // legittimo, non un errore: il chiamante decide come segnalarlo.
    class function GetByCodiceLottoGlobale(const ACodiceLotto: string): TObjectList<TLottoMateriaPrima>;
    class function GetAll: TObjectList<TLottoMateriaPrima>;
    class function GetByMateriaPrima(AMateriaPrimaID: Integer): TObjectList<TLottoMateriaPrima>;
    class function Delete(AID: Integer): Boolean;

    // Decremento atomico e condizionato della giacenza disponibile.
    // Pensato per essere chiamato DENTRO una transazione gestita da un
    // Service (vedi TServizioGiacenza in services/uServiziGiacenza.pas):
    // riceve una connessione gia' aperta invece di aprirne una pooled
    // propria, cosi' questa UPDATE e l'INSERT della riga di consumo che
    // la accompagna possono essere committate o annullate insieme.
    // La condizione "AND quantita_disponibile >= :quantita" nella WHERE
    // rende l'operazione sicura anche in concorrenza: o decrementa senza
    // mai andare sotto zero, o non tocca nessuna riga (Result = False)
    // se la giacenza non basta — senza una SELECT preventiva che
    // lascerebbe una finestra di race condition tra lettura e scrittura.
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

{ TLottoMateriaPrima }

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
  // Il codice lotto e' univoco solo all'interno della stessa materia
  // prima (vincolo uq_lotto_materia_prima), non globalmente: due materie
  // prime diverse possono avere lotti con lo stesso codice.
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
  // Vedi il commento sulla dichiarazione: nessun filtro su materia_prima_id,
  // puo' restituire 0, 1 o piu' righe. Ordinamento per id (non per data
  // scadenza come GetByMateriaPrima): qui non ha senso un ordine FEFO, i
  // risultati possono appartenere a materie prime diverse.
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

  // Ordinamento per data_scadenza: riflette la logica FEFO (First Expired,
  // First Out) tipica del settore alimentare, ed e' utile di default per
  // individuare rapidamente i lotti piu' vicini alla scadenza.
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
  // Tutti i lotti di una specifica materia prima, in ordine FEFO. Utile
  // sia per la gestione di magazzino ordinaria sia come primo passo dello
  // scenario di ritiro/richiamo: individuati i lotti di una materia prima
  // non conforme, si risale da qui ai lotti di semilavorato/prodotto
  // finito che li hanno consumati.
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
  // Un lotto e' referenziato da consumi_produzione_semilavorati,
  // consumi_produzione_prodotti_finiti e non_conformita: in assenza di
  // ON DELETE CASCADE lato DB, la query fallisce se il lotto e' gia'
  // stato usato in produzione o coinvolto in una non conformita'.
  // Comportamento voluto: un lotto movimentato non va cancellato, e' un
  // dato di tracciabilita'.
  Result := TDB.GetInstance.executeQuery(
    'DELETE FROM lotti_materie_prime WHERE id = :id', [AID]);
end;

class function TLottoMateriaPrima.DecrementaQuantitaDisponibile(AID: Integer;
  AQuantita: Currency; AConnection: TFDConnection): Boolean;
var
  LQuery: TFDQuery;
begin
  // Query parametrica costruita a mano (non tramite TDB.GetInstance,
  // che aprirebbe una connessione pooled propria): usiamo direttamente
  // AConnection perche' questa UPDATE deve far parte della transazione
  // gia' avviata dal chiamante (tipicamente TServizioGiacenza), non di
  // una transazione a se stante.
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

    // RowsAffected = 0 significa che il lotto non esiste oppure che
    // AQuantita supera la giacenza disponibile: in entrambi i casi la
    // UPDATE non ha toccato nulla, quindi Result = False segnala al
    // chiamante di annullare l'intera operazione (consumo/spedizione).
    Result := LQuery.RowsAffected > 0;
  finally
    LQuery.Free;
  end;
end;

function TLottoMateriaPrima.Insert: Integer;
var
  LAutoQuery: TAutoQuery;
begin
  // creato_il e aggiornato_il NON compaiono tra i campi inseriti: sono
  // valorizzati dal DEFAULT del database (now()).
  // Il DB ha DEFAULT 0 su quantita_disponibile, ma e' solo una garanzia
  // di NOT NULL: per un lotto appena ricevuto la regola di business e'
  // che la quantita' disponibile parta uguale alla quantita' ricevuta.
  // E' responsabilita' del chiamante impostare QuantitaDisponibile
  // (tipicamente = Quantita) prima di chiamare Insert; qui la
  // valorizziamo comunque esplicitamente per non affidarci al default.
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
  // aggiornato_il NON viene impostato esplicitamente: il trigger
  // trg_lotti_materie_prime_aggiornato_il lo valorizza automaticamente.
  // Questo e' anche il metodo con cui, in pratica, si aggiorna
  // QuantitaDisponibile ad ogni consumo/scarico (vedi commento di classe).
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
  // id, creato_il, aggiornato_il NON vengono letti dal payload in
  // ingresso: sono gestiti dal database, mai dal client
  if AJSON.TryGetValue<Integer>('materia_prima_id', LValInt) then
    FMateriaPrimaID := LValInt;
  if AJSON.TryGetValue<string>('codice_lotto', LValStr) then
    FCodiceLotto := LValStr;
  if AJSON.TryGetValue<string>('data_scadenza', LValStr) then
    FDataScadenza := ISO8601ToDate(LValStr);
  if AJSON.TryGetValue<Integer>('ddt_entrata_riga_id', LValInt) then
    FDdtEntrataRigaID := LValInt;

  // I campi numerici decimali si leggono come TJSONNumber per
  // preservarne la precisione (evitando conversioni intermedie a Double)
  if AJSON.TryGetValue<TJSONValue>('quantita', LValDate) and (LValDate is TJSONNumber) then
    FQuantita := TJSONNumber(LValDate).AsDouble;
  if AJSON.TryGetValue<TJSONValue>('quantita_disponibile', LValDate) and (LValDate is TJSONNumber) then
    FQuantitaDisponibile := TJSONNumber(LValDate).AsDouble;
end;

end.
