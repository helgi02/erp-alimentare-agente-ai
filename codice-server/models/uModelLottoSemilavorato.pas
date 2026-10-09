unit uModelLottoSemilavorato;

interface

uses
  System.SysUtils,
  System.Generics.Collections,
  Data.DB, System.JSON, System.DateUtils,
  FireDAC.Comp.Client,
  DbU;

type
  // Rappresenta un lotto fisico di semilavorato prodotto internamente
  // (tabella lotti_semilavorati). A differenza di TLottoMateriaPrima,
  // qui UnitaMisura e' un campo proprio (il DDL non lo eredita da
  // nessuna riga esterna), e non c'e' DataScadenza: il DDL non la
  // prevede per i semilavorati, presumibilmente perche' sono prodotti
  // intermedi con vita utile breve e non etichettati singolarmente per
  // il consumatore finale (a differenza dei prodotti finiti, che invece
  // hanno sia data_produzione sia data_scadenza).
  //
  // RicettaID punta alla versione di ricetta (ricette_semilavorati)
  // effettivamente usata per produrre QUESTO lotto: e' un dato di
  // tracciabilita' importante perche' le ricette sono versionate (vedi
  // ricette_semilavorati.versione) — sapere quale versione e' stata
  // usata e' essenziale per lo scenario di ritiro/richiamo, dove va
  // ricostruita esattamente la composizione del lotto coinvolto.
  //
  // Quantita/QuantitaDisponibile usano Currency per lo stesso motivo di
  // TLottoMateriaPrima: precisione esatta a 4 decimali, come le colonne
  // NUMERIC(10,4) del DB.
  TLottoSemilavorato = class
  private
    FID: Integer;
    FSemilavoratoID: Integer;
    FCodiceLotto: string;
    FDataProduzione: TDateTime;
    FQuantita: Currency;
    FQuantitaDisponibile: Currency;
    FUnitaMisura: string;
    FRicettaID: Integer;
    FStabilimentoID: Integer;
    FCreatoIl: TDateTime;
    FAggiornatoIl: TDateTime;

    procedure LoadFromDataSet(ADataSet: TDataSet);
  public
    constructor Create;

    property ID: Integer read FID write FID;
    property SemilavoratoID: Integer read FSemilavoratoID write FSemilavoratoID;
    property CodiceLotto: string read FCodiceLotto write FCodiceLotto;
    property DataProduzione: TDateTime read FDataProduzione write FDataProduzione;
    property Quantita: Currency read FQuantita write FQuantita;
    property QuantitaDisponibile: Currency read FQuantitaDisponibile write FQuantitaDisponibile;
    property UnitaMisura: string read FUnitaMisura write FUnitaMisura;
    property RicettaID: Integer read FRicettaID write FRicettaID;
    property StabilimentoID: Integer read FStabilimentoID write FStabilimentoID;

    // Campi di audit: sola lettura, gestiti dal database (default/trigger
    // trg_lotti_semilavorati_aggiornato_il)
    property CreatoIl: TDateTime read FCreatoIl;
    property AggiornatoIl: TDateTime read FAggiornatoIl;

    // Operazioni CRUD
    class function GetByID(AID: Integer): TLottoSemilavorato;
    class function GetByCodiceLotto(ASemilavoratoID: Integer;
      const ACodiceLotto: string): TLottoSemilavorato;
    class function GetAll: TObjectList<TLottoSemilavorato>;
    class function GetBySemilavorato(ASemilavoratoID: Integer): TObjectList<TLottoSemilavorato>;
    class function Delete(AID: Integer): Boolean;

    // Decremento atomico e condizionato della giacenza disponibile.
    // Stesso ruolo e stessa logica di TLottoMateriaPrima.DecrementaQuantitaDisponibile
    // (vedi commento li'): usato da TServizioGiacenza quando un lotto di
    // semilavorato e' il COMPONENTE consumato per produrre un altro
    // lotto (di semilavorato "genitore" o di prodotto finito).
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
    'SELECT id, semilavorato_id, codice_lotto, data_produzione, quantita, ' +
    'quantita_disponibile, unita_misura, ricetta_id, stabilimento_id, ' +
    'creato_il, aggiornato_il ' +
    'FROM lotti_semilavorati ';

{ TLottoSemilavorato }

constructor TLottoSemilavorato.Create;
begin
  inherited Create;
  FID := 0;
end;

procedure TLottoSemilavorato.LoadFromDataSet(ADataSet: TDataSet);
begin
  FID                  := ADataSet.FieldByName('id').AsInteger;
  FSemilavoratoID      := ADataSet.FieldByName('semilavorato_id').AsInteger;
  FCodiceLotto         := ADataSet.FieldByName('codice_lotto').AsString;
  FDataProduzione      := ADataSet.FieldByName('data_produzione').AsDateTime;
  FQuantita            := ADataSet.FieldByName('quantita').AsCurrency;
  FQuantitaDisponibile := ADataSet.FieldByName('quantita_disponibile').AsCurrency;
  FUnitaMisura         := ADataSet.FieldByName('unita_misura').AsString;
  FRicettaID           := ADataSet.FieldByName('ricetta_id').AsInteger;
  FStabilimentoID      := ADataSet.FieldByName('stabilimento_id').AsInteger;
  FCreatoIl            := ADataSet.FieldByName('creato_il').AsDateTime;
  FAggiornatoIl        := ADataSet.FieldByName('aggiornato_il').AsDateTime;
end;

class function TLottoSemilavorato.GetByID(AID: Integer): TLottoSemilavorato;
var
  LAutoQuery: TAutoQuery;
begin
  Result := nil;

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE id = :id', [AID]);
  try
    if not LAutoQuery.Query.IsEmpty then
    begin
      Result := TLottoSemilavorato.Create;
      Result.LoadFromDataSet(LAutoQuery.Query);
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TLottoSemilavorato.GetByCodiceLotto(ASemilavoratoID: Integer;
  const ACodiceLotto: string): TLottoSemilavorato;
var
  LAutoQuery: TAutoQuery;
begin
  // Il codice lotto e' univoco solo all'interno dello stesso semilavorato
  // (vincolo uq_lotto_semilavorato), non globalmente.
  Result := nil;

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE semilavorato_id = :semilavorato_id ' +
    'AND codice_lotto = :codice_lotto',
    [ASemilavoratoID, ACodiceLotto]);
  try
    if not LAutoQuery.Query.IsEmpty then
    begin
      Result := TLottoSemilavorato.Create;
      Result.LoadFromDataSet(LAutoQuery.Query);
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TLottoSemilavorato.GetAll: TObjectList<TLottoSemilavorato>;
var
  LAutoQuery: TAutoQuery;
  LLotto: TLottoSemilavorato;
begin
  Result := TObjectList<TLottoSemilavorato>.Create(True); // possiede gli oggetti

  // Ordinamento per data_produzione: qui non c'e' data_scadenza su cui
  // ordinare (assente nel DDL per i semilavorati), quindi si usa la data
  // di produzione, piu' recente per ultima.
  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'ORDER BY data_produzione');
  try
    while not LAutoQuery.Query.Eof do
    begin
      LLotto := TLottoSemilavorato.Create;
      LLotto.LoadFromDataSet(LAutoQuery.Query);
      Result.Add(LLotto);
      LAutoQuery.Query.Next;
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TLottoSemilavorato.GetBySemilavorato(ASemilavoratoID: Integer): TObjectList<TLottoSemilavorato>;
var
  LAutoQuery: TAutoQuery;
  LLotto: TLottoSemilavorato;
begin
  // Tutti i lotti di uno specifico semilavorato. Come per
  // TLottoMateriaPrima.GetByMateriaPrima, e' il punto di partenza per
  // risalire la catena di tracciabilita' nello scenario di
  // ritiro/richiamo, quando il componente non conforme e' un
  // semilavorato anziche' una materia prima.
  Result := TObjectList<TLottoSemilavorato>.Create(True);

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE semilavorato_id = :semilavorato_id ' +
    'ORDER BY data_produzione',
    [ASemilavoratoID]);
  try
    while not LAutoQuery.Query.Eof do
    begin
      LLotto := TLottoSemilavorato.Create;
      LLotto.LoadFromDataSet(LAutoQuery.Query);
      Result.Add(LLotto);
      LAutoQuery.Query.Next;
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TLottoSemilavorato.Delete(AID: Integer): Boolean;
begin
  // Un lotto di semilavorato e' referenziato da
  // consumi_produzione_semilavorati (sia come lotto prodotto sia come
  // componente consumato di un altro lotto), consumi_produzione_prodotti_finiti
  // e non_conformita: in assenza di ON DELETE CASCADE lato DB, la query
  // fallisce se il lotto e' gia' stato usato. Comportamento voluto.
  Result := TDB.GetInstance.executeQuery(
    'DELETE FROM lotti_semilavorati WHERE id = :id', [AID]);
end;

class function TLottoSemilavorato.DecrementaQuantitaDisponibile(AID: Integer;
  AQuantita: Currency; AConnection: TFDConnection): Boolean;
var
  LQuery: TFDQuery;
begin
  // Vedi il commento gemello in TLottoMateriaPrima.DecrementaQuantitaDisponibile:
  // stessa tecnica (UPDATE condizionata sulla connessione esterna
  // ricevuta), stesso motivo (atomicita' con l'insert della riga di
  // consumo nella stessa transazione).
  LQuery := TFDQuery.Create(nil);
  try
    LQuery.Connection := AConnection;
    LQuery.SQL.Text :=
      'UPDATE lotti_semilavorati ' +
      'SET quantita_disponibile = quantita_disponibile - :quantita ' +
      'WHERE id = :id AND quantita_disponibile >= :quantita';
    LQuery.ParamByName('quantita').Value := AQuantita;
    LQuery.ParamByName('id').AsInteger := AID;
    LQuery.ExecSQL;

    Result := LQuery.RowsAffected > 0;
  finally
    LQuery.Free;
  end;
end;

function TLottoSemilavorato.Insert: Integer;
var
  LAutoQuery: TAutoQuery;
begin
  // creato_il e aggiornato_il NON compaiono tra i campi inseriti: sono
  // valorizzati dal DEFAULT del database (now()).
  // Come per TLottoMateriaPrima: il DB ha DEFAULT 0 su
  // quantita_disponibile solo come garanzia di NOT NULL. Per un lotto
  // appena prodotto la regola di business e' QuantitaDisponibile =
  // Quantita: e' responsabilita' del chiamante impostarla prima di
  // chiamare Insert.
  LAutoQuery := TDB.GetInstance.getQueryResult(
    'INSERT INTO lotti_semilavorati ' +
    '(semilavorato_id, codice_lotto, data_produzione, quantita, ' +
    'quantita_disponibile, unita_misura, ricetta_id, stabilimento_id) ' +
    'VALUES (:semilavorato_id, :codice_lotto, :data_produzione, :quantita, ' +
    ':quantita_disponibile, :unita_misura, :ricetta_id, :stabilimento_id) ' +
    'RETURNING id, creato_il, aggiornato_il',
    [FSemilavoratoID, FCodiceLotto, FDataProduzione, FQuantita,
     FQuantitaDisponibile, FUnitaMisura, FRicettaID, FStabilimentoID]);
  try
    FID           := LAutoQuery.Query.FieldByName('id').AsInteger;
    FCreatoIl     := LAutoQuery.Query.FieldByName('creato_il').AsDateTime;
    FAggiornatoIl := LAutoQuery.Query.FieldByName('aggiornato_il').AsDateTime;
    Result := FID;
  finally
    LAutoQuery.Free;
  end;
end;

function TLottoSemilavorato.Update: Boolean;
var
  LAutoQuery: TAutoQuery;
begin
  // aggiornato_il NON viene impostato esplicitamente: il trigger
  // trg_lotti_semilavorati_aggiornato_il lo valorizza automaticamente.
  LAutoQuery := TDB.GetInstance.getQueryResult(
    'UPDATE lotti_semilavorati SET semilavorato_id = :semilavorato_id, ' +
    'codice_lotto = :codice_lotto, data_produzione = :data_produzione, ' +
    'quantita = :quantita, quantita_disponibile = :quantita_disponibile, ' +
    'unita_misura = :unita_misura, ricetta_id = :ricetta_id, ' +
    'stabilimento_id = :stabilimento_id ' +
    'WHERE id = :id ' +
    'RETURNING aggiornato_il',
    [FSemilavoratoID, FCodiceLotto, FDataProduzione, FQuantita,
     FQuantitaDisponibile, FUnitaMisura, FRicettaID, FStabilimentoID, FID]);
  try
    Result := not LAutoQuery.Query.IsEmpty;
    if Result then
      FAggiornatoIl := LAutoQuery.Query.FieldByName('aggiornato_il').AsDateTime;
  finally
    LAutoQuery.Free;
  end;
end;

function TLottoSemilavorato.Save: Boolean;
begin
  if FID = 0 then
  begin
    Insert;
    Result := FID > 0;
  end
  else
    Result := Update;
end;

function TLottoSemilavorato.ToJSONObject: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('id', TJSONNumber.Create(FID));
  Result.AddPair('semilavorato_id', TJSONNumber.Create(FSemilavoratoID));
  Result.AddPair('codice_lotto', FCodiceLotto);
  Result.AddPair('data_produzione', DateToISO8601(FDataProduzione));
  Result.AddPair('quantita', TJSONNumber.Create(FQuantita));
  Result.AddPair('quantita_disponibile', TJSONNumber.Create(FQuantitaDisponibile));
  Result.AddPair('unita_misura', FUnitaMisura);
  Result.AddPair('ricetta_id', TJSONNumber.Create(FRicettaID));
  Result.AddPair('stabilimento_id', TJSONNumber.Create(FStabilimentoID));
  Result.AddPair('creato_il', DateToISO8601(FCreatoIl));
  Result.AddPair('aggiornato_il', DateToISO8601(FAggiornatoIl));
end;

procedure TLottoSemilavorato.FromJSONObject(AJSON: TJSONObject);
var
  LValInt: Integer;
  LValStr: string;
  LValNum: TJSONValue;
begin
  // id, creato_il, aggiornato_il NON vengono letti dal payload in
  // ingresso: sono gestiti dal database, mai dal client
  if AJSON.TryGetValue<Integer>('semilavorato_id', LValInt) then
    FSemilavoratoID := LValInt;
  if AJSON.TryGetValue<string>('codice_lotto', LValStr) then
    FCodiceLotto := LValStr;
  if AJSON.TryGetValue<string>('data_produzione', LValStr) then
    FDataProduzione := ISO8601ToDate(LValStr);
  if AJSON.TryGetValue<string>('unita_misura', LValStr) then
    FUnitaMisura := LValStr;
  if AJSON.TryGetValue<Integer>('ricetta_id', LValInt) then
    FRicettaID := LValInt;
  if AJSON.TryGetValue<Integer>('stabilimento_id', LValInt) then
    FStabilimentoID := LValInt;

  // Campi numerici decimali: letti come TJSONNumber per preservarne la
  // precisione (evitando conversioni intermedie a Double)
  if AJSON.TryGetValue<TJSONValue>('quantita', LValNum) and (LValNum is TJSONNumber) then
    FQuantita := TJSONNumber(LValNum).AsDouble;
  if AJSON.TryGetValue<TJSONValue>('quantita_disponibile', LValNum) and (LValNum is TJSONNumber) then
    FQuantitaDisponibile := TJSONNumber(LValNum).AsDouble;
end;

end.
