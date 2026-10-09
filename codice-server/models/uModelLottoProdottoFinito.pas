unit uModelLottoProdottoFinito;

interface

uses
  System.SysUtils,
  System.Generics.Collections,
  Data.DB, System.JSON, System.DateUtils,
  DbU;

type
  // Rappresenta un lotto fisico di prodotto finito pronto per la vendita
  // (tabella lotti_prodotti_finiti). Struttura identica a
  // TLottoSemilavorato con l'aggiunta di DataScadenza: a differenza dei
  // semilavorati, il prodotto finito raggiunge lo scaffale/il
  // consumatore e la sua scadenza effettiva e' un dato di legge
  // (etichetta) — puo' differire dal calcolo standard dell'anagrafica
  // (ProdottoFinito.GiorniScadenzaStandard), come segnalato nel commento
  // della colonna nel DDL, per questo va salvata esplicitamente per
  // ciascun lotto anziche' ricalcolata al volo.
  //
  // E' l'entita' piu' direttamente coinvolta nello scenario di
  // ritiro/richiamo quando il lotto compromesso ha gia' raggiunto il
  // magazzino prodotti finiti: da qui si arriva a ordini_vendita_righe
  // (tramite lotto_prodotto_finito_id) per sapere quali clienti hanno
  // gia' ricevuto il lotto.
  TLottoProdottoFinito = class
  private
    FID: Integer;
    FProdottoFinitoID: Integer;
    FCodiceLotto: string;
    FDataProduzione: TDateTime;
    FDataScadenza: TDateTime;
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
    property ProdottoFinitoID: Integer read FProdottoFinitoID write FProdottoFinitoID;
    property CodiceLotto: string read FCodiceLotto write FCodiceLotto;
    property DataProduzione: TDateTime read FDataProduzione write FDataProduzione;
    property DataScadenza: TDateTime read FDataScadenza write FDataScadenza;
    property Quantita: Currency read FQuantita write FQuantita;
    property QuantitaDisponibile: Currency read FQuantitaDisponibile write FQuantitaDisponibile;
    property UnitaMisura: string read FUnitaMisura write FUnitaMisura;
    property RicettaID: Integer read FRicettaID write FRicettaID;
    property StabilimentoID: Integer read FStabilimentoID write FStabilimentoID;

    // Campi di audit: sola lettura, gestiti dal database (default/trigger
    // trg_lotti_prodotti_finiti_aggiornato_il)
    property CreatoIl: TDateTime read FCreatoIl;
    property AggiornatoIl: TDateTime read FAggiornatoIl;

    // Operazioni CRUD
    class function GetByID(AID: Integer): TLottoProdottoFinito;
    class function GetByCodiceLotto(AProdottoFinitoID: Integer;
      const ACodiceLotto: string): TLottoProdottoFinito;
    class function GetAll: TObjectList<TLottoProdottoFinito>;
    class function GetByProdottoFinito(AProdottoFinitoID: Integer): TObjectList<TLottoProdottoFinito>;
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
    'SELECT id, prodotto_finito_id, codice_lotto, data_produzione, ' +
    'data_scadenza, quantita, quantita_disponibile, unita_misura, ' +
    'ricetta_id, stabilimento_id, creato_il, aggiornato_il ' +
    'FROM lotti_prodotti_finiti ';

{ TLottoProdottoFinito }

constructor TLottoProdottoFinito.Create;
begin
  inherited Create;
  FID := 0;
end;

procedure TLottoProdottoFinito.LoadFromDataSet(ADataSet: TDataSet);
begin
  FID                  := ADataSet.FieldByName('id').AsInteger;
  FProdottoFinitoID    := ADataSet.FieldByName('prodotto_finito_id').AsInteger;
  FCodiceLotto         := ADataSet.FieldByName('codice_lotto').AsString;
  FDataProduzione      := ADataSet.FieldByName('data_produzione').AsDateTime;
  FDataScadenza        := ADataSet.FieldByName('data_scadenza').AsDateTime;
  FQuantita            := ADataSet.FieldByName('quantita').AsCurrency;
  FQuantitaDisponibile := ADataSet.FieldByName('quantita_disponibile').AsCurrency;
  FUnitaMisura         := ADataSet.FieldByName('unita_misura').AsString;
  FRicettaID           := ADataSet.FieldByName('ricetta_id').AsInteger;
  FStabilimentoID      := ADataSet.FieldByName('stabilimento_id').AsInteger;
  FCreatoIl            := ADataSet.FieldByName('creato_il').AsDateTime;
  FAggiornatoIl        := ADataSet.FieldByName('aggiornato_il').AsDateTime;
end;

class function TLottoProdottoFinito.GetByID(AID: Integer): TLottoProdottoFinito;
var
  LAutoQuery: TAutoQuery;
begin
  Result := nil;

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE id = :id', [AID]);
  try
    if not LAutoQuery.Query.IsEmpty then
    begin
      Result := TLottoProdottoFinito.Create;
      Result.LoadFromDataSet(LAutoQuery.Query);
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TLottoProdottoFinito.GetByCodiceLotto(AProdottoFinitoID: Integer;
  const ACodiceLotto: string): TLottoProdottoFinito;
var
  LAutoQuery: TAutoQuery;
begin
  // Il codice lotto e' univoco solo all'interno dello stesso prodotto
  // finito (vincolo uq_lotto_prodotto_finito), non globalmente.
  Result := nil;

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE prodotto_finito_id = :prodotto_finito_id ' +
    'AND codice_lotto = :codice_lotto',
    [AProdottoFinitoID, ACodiceLotto]);
  try
    if not LAutoQuery.Query.IsEmpty then
    begin
      Result := TLottoProdottoFinito.Create;
      Result.LoadFromDataSet(LAutoQuery.Query);
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TLottoProdottoFinito.GetAll: TObjectList<TLottoProdottoFinito>;
var
  LAutoQuery: TAutoQuery;
  LLotto: TLottoProdottoFinito;
begin
  Result := TObjectList<TLottoProdottoFinito>.Create(True); // possiede gli oggetti

  // Ordinamento FEFO per data_scadenza, come per TLottoMateriaPrima.
  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'ORDER BY data_scadenza');
  try
    while not LAutoQuery.Query.Eof do
    begin
      LLotto := TLottoProdottoFinito.Create;
      LLotto.LoadFromDataSet(LAutoQuery.Query);
      Result.Add(LLotto);
      LAutoQuery.Query.Next;
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TLottoProdottoFinito.GetByProdottoFinito(AProdottoFinitoID: Integer): TObjectList<TLottoProdottoFinito>;
var
  LAutoQuery: TAutoQuery;
  LLotto: TLottoProdottoFinito;
begin
  // Tutti i lotti di uno specifico prodotto finito, in ordine FEFO.
  // E' il punto d'arrivo tipico dello scenario di ritiro/richiamo: dato
  // un prodotto finito coinvolto, elenca i lotti da verificare uno per
  // uno (giacenza residua vs. gia' consegnati a clienti).
  Result := TObjectList<TLottoProdottoFinito>.Create(True);

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE prodotto_finito_id = :prodotto_finito_id ' +
    'ORDER BY data_scadenza',
    [AProdottoFinitoID]);
  try
    while not LAutoQuery.Query.Eof do
    begin
      LLotto := TLottoProdottoFinito.Create;
      LLotto.LoadFromDataSet(LAutoQuery.Query);
      Result.Add(LLotto);
      LAutoQuery.Query.Next;
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TLottoProdottoFinito.Delete(AID: Integer): Boolean;
begin
  // Un lotto di prodotto finito e' referenziato da
  // consumi_produzione_prodotti_finiti, ordini_vendita_righe e
  // non_conformita: in assenza di ON DELETE CASCADE lato DB, la query
  // fallisce se il lotto e' gia' stato venduto o coinvolto in una non
  // conformita'. Comportamento voluto.
  Result := TDB.GetInstance.executeQuery(
    'DELETE FROM lotti_prodotti_finiti WHERE id = :id', [AID]);
end;

function TLottoProdottoFinito.Insert: Integer;
var
  LAutoQuery: TAutoQuery;
begin
  // creato_il e aggiornato_il NON compaiono tra i campi inseriti: sono
  // valorizzati dal DEFAULT del database (now()).
  // Come per TLottoMateriaPrima/TLottoSemilavorato: il DB ha DEFAULT 0 su
  // quantita_disponibile solo come garanzia di NOT NULL. Per un lotto
  // appena prodotto la regola di business e' QuantitaDisponibile =
  // Quantita: e' responsabilita' del chiamante impostarla prima di
  // chiamare Insert.
  LAutoQuery := TDB.GetInstance.getQueryResult(
    'INSERT INTO lotti_prodotti_finiti ' +
    '(prodotto_finito_id, codice_lotto, data_produzione, data_scadenza, ' +
    'quantita, quantita_disponibile, unita_misura, ricetta_id, stabilimento_id) ' +
    'VALUES (:prodotto_finito_id, :codice_lotto, :data_produzione, :data_scadenza, ' +
    ':quantita, :quantita_disponibile, :unita_misura, :ricetta_id, :stabilimento_id) ' +
    'RETURNING id, creato_il, aggiornato_il',
    [FProdottoFinitoID, FCodiceLotto, FDataProduzione, FDataScadenza, FQuantita,
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

function TLottoProdottoFinito.Update: Boolean;
var
  LAutoQuery: TAutoQuery;
begin
  // aggiornato_il NON viene impostato esplicitamente: il trigger
  // trg_lotti_prodotti_finiti_aggiornato_il lo valorizza automaticamente.
  LAutoQuery := TDB.GetInstance.getQueryResult(
    'UPDATE lotti_prodotti_finiti SET prodotto_finito_id = :prodotto_finito_id, ' +
    'codice_lotto = :codice_lotto, data_produzione = :data_produzione, ' +
    'data_scadenza = :data_scadenza, quantita = :quantita, ' +
    'quantita_disponibile = :quantita_disponibile, unita_misura = :unita_misura, ' +
    'ricetta_id = :ricetta_id, stabilimento_id = :stabilimento_id ' +
    'WHERE id = :id ' +
    'RETURNING aggiornato_il',
    [FProdottoFinitoID, FCodiceLotto, FDataProduzione, FDataScadenza, FQuantita,
     FQuantitaDisponibile, FUnitaMisura, FRicettaID, FStabilimentoID, FID]);
  try
    Result := not LAutoQuery.Query.IsEmpty;
    if Result then
      FAggiornatoIl := LAutoQuery.Query.FieldByName('aggiornato_il').AsDateTime;
  finally
    LAutoQuery.Free;
  end;
end;

function TLottoProdottoFinito.Save: Boolean;
begin
  if FID = 0 then
  begin
    Insert;
    Result := FID > 0;
  end
  else
    Result := Update;
end;

function TLottoProdottoFinito.ToJSONObject: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('id', TJSONNumber.Create(FID));
  Result.AddPair('prodotto_finito_id', TJSONNumber.Create(FProdottoFinitoID));
  Result.AddPair('codice_lotto', FCodiceLotto);
  Result.AddPair('data_produzione', DateToISO8601(FDataProduzione));
  Result.AddPair('data_scadenza', DateToISO8601(FDataScadenza));
  Result.AddPair('quantita', TJSONNumber.Create(FQuantita));
  Result.AddPair('quantita_disponibile', TJSONNumber.Create(FQuantitaDisponibile));
  Result.AddPair('unita_misura', FUnitaMisura);
  Result.AddPair('ricetta_id', TJSONNumber.Create(FRicettaID));
  Result.AddPair('stabilimento_id', TJSONNumber.Create(FStabilimentoID));
  Result.AddPair('creato_il', DateToISO8601(FCreatoIl));
  Result.AddPair('aggiornato_il', DateToISO8601(FAggiornatoIl));
end;

procedure TLottoProdottoFinito.FromJSONObject(AJSON: TJSONObject);
var
  LValInt: Integer;
  LValStr: string;
  LValNum: TJSONValue;
begin
  // id, creato_il, aggiornato_il NON vengono letti dal payload in
  // ingresso: sono gestiti dal database, mai dal client
  if AJSON.TryGetValue<Integer>('prodotto_finito_id', LValInt) then
    FProdottoFinitoID := LValInt;
  if AJSON.TryGetValue<string>('codice_lotto', LValStr) then
    FCodiceLotto := LValStr;
  if AJSON.TryGetValue<string>('data_produzione', LValStr) then
    FDataProduzione := ISO8601ToDate(LValStr);
  if AJSON.TryGetValue<string>('data_scadenza', LValStr) then
    FDataScadenza := ISO8601ToDate(LValStr);
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
