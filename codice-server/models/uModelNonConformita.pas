unit uModelNonConformita;

interface

uses
  System.SysUtils,
  System.Variants,
  System.Generics.Collections,
  Data.DB, System.JSON, System.DateUtils,
  DbU;

type
  // Non conformita' su un lotto (non_conformita): l'evento che innesca il richiamo (2.1).
  // Dai lotti coinvolti si risale ai prodotti finiti (consumi_produzione_*), si verifica
  // quali sono in giacenza e quali dai clienti (ordini_vendita_righe, ddt_uscita) e si
  // decide se generare solo la Scheda di Notifica OSA o anche il Modello di Richiamo al
  // Consumatore.
  // Il CHECK chk_lotto_non_conformita e' un OR, non uno XOR: almeno uno dei tre lotti,
  // anche piu' di uno (una NC puo' riguardare la materia prima contaminata e i prodotti
  // finiti che l'hanno incorporata, sotto lo stesso codice_nc).
  // StatoNC e' un ENUM PostgreSQL (stato_nc_enum) ma si tratta come string (FireDAC lo
  // restituisce via AsString); i valori ammessi sono validati in EnsureStatoValido.
  TNonConformita = class
  private
    FID: Integer;
    FCodiceNC: string;
    FMotivo: string;
    FStatoNC: string;
    FDataApertura: TDateTime;
    FAzioniCorrettive: string;
    FLottoMateriaPrimaID: Integer;    // 0 = NULL
    FLottoSemilavoratoID: Integer;    // 0 = NULL
    FLottoProdottoFinitoID: Integer;  // 0 = NULL
    FCreatoIl: TDateTime;
    FAggiornatoIl: TDateTime;

    procedure LoadFromDataSet(ADataSet: TDataSet);
    procedure EnsureStatoValido;
    procedure EnsureAlmenoUnLottoValido;
  public
    constructor Create;

    property ID: Integer read FID write FID;
    property CodiceNC: string read FCodiceNC write FCodiceNC;
    property Motivo: string read FMotivo write FMotivo;
    property StatoNC: string read FStatoNC write FStatoNC;
    property DataApertura: TDateTime read FDataApertura write FDataApertura;
    property AzioniCorrettive: string read FAzioniCorrettive write FAzioniCorrettive;
    property LottoMateriaPrimaID: Integer read FLottoMateriaPrimaID write FLottoMateriaPrimaID;
    property LottoSemilavoratoID: Integer read FLottoSemilavoratoID write FLottoSemilavoratoID;
    property LottoProdottoFinitoID: Integer read FLottoProdottoFinitoID write FLottoProdottoFinitoID;

    property CreatoIl: TDateTime read FCreatoIl;
    property AggiornatoIl: TDateTime read FAggiornatoIl;

    class function GetByID(AID: Integer): TNonConformita;
    class function GetByCodice(const ACodiceNC: string): TNonConformita;
    class function GetAll: TObjectList<TNonConformita>;
    class function GetByStato(const AStato: string): TObjectList<TNonConformita>;
    class function GetByLottoMateriaPrima(ALottoMateriaPrimaID: Integer): TObjectList<TNonConformita>;
    class function GetByLottoSemilavorato(ALottoSemilavoratoID: Integer): TObjectList<TNonConformita>;
    class function GetByLottoProdottoFinito(ALottoProdottoFinitoID: Integer): TObjectList<TNonConformita>;
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
    'SELECT id, codice_nc, motivo, stato_nc, data_apertura, azioni_correttive, ' +
    'lotto_materia_prima_id, lotto_semilavorato_id, lotto_prodotto_finito_id, ' +
    'creato_il, aggiornato_il ' +
    'FROM non_conformita ';

  // Valori dell'ENUM stato_nc_enum, validati qui prima di arrivare al DB.
  STATI_VALIDI: array[0..2] of string = ('aperta', 'in_gestione', 'chiusa');

constructor TNonConformita.Create;
begin
  inherited Create;
  FID := 0;
  FStatoNC := 'aperta';           // replica il DEFAULT lato database
  FDataApertura := Date; // replica il DEFAULT CURRENT_DATE lato database
  FLottoMateriaPrimaID := 0;
  FLottoSemilavoratoID := 0;
  FLottoProdottoFinitoID := 0;
end;

procedure TNonConformita.EnsureStatoValido;
var
  LStato: string;
  LValido: Boolean;
begin
  LValido := False;
  for LStato in STATI_VALIDI do
    if SameText(LStato, FStatoNC) then
    begin
      LValido := True;
      Break;
    end;

  if not LValido then
    raise Exception.Create(
      'TNonConformita: stato_nc "' + FStatoNC + '" non valido. Valori ammessi: ' +
      'aperta, in_gestione, chiusa.');
end;

procedure TNonConformita.EnsureAlmenoUnLottoValido;
begin
  // Replica il CHECK chk_lotto_non_conformita: OR, non XOR; basta almeno un lotto
  // valorizzato.
  if (FLottoMateriaPrimaID = 0) and (FLottoSemilavoratoID = 0) and (FLottoProdottoFinitoID = 0) then
    raise Exception.Create(
      'TNonConformita: deve essere valorizzato almeno uno tra LottoMateriaPrimaID, ' +
      'LottoSemilavoratoID e LottoProdottoFinitoID.');
end;

procedure TNonConformita.LoadFromDataSet(ADataSet: TDataSet);
begin
  FID           := ADataSet.FieldByName('id').AsInteger;
  FCodiceNC     := ADataSet.FieldByName('codice_nc').AsString;
  FMotivo       := ADataSet.FieldByName('motivo').AsString;
  FStatoNC      := ADataSet.FieldByName('stato_nc').AsString;
  FDataApertura := ADataSet.FieldByName('data_apertura').AsDateTime;
  FAzioniCorrettive := ADataSet.FieldByName('azioni_correttive').AsString;

  if ADataSet.FieldByName('lotto_materia_prima_id').IsNull then
    FLottoMateriaPrimaID := 0
  else
    FLottoMateriaPrimaID := ADataSet.FieldByName('lotto_materia_prima_id').AsInteger;

  if ADataSet.FieldByName('lotto_semilavorato_id').IsNull then
    FLottoSemilavoratoID := 0
  else
    FLottoSemilavoratoID := ADataSet.FieldByName('lotto_semilavorato_id').AsInteger;

  if ADataSet.FieldByName('lotto_prodotto_finito_id').IsNull then
    FLottoProdottoFinitoID := 0
  else
    FLottoProdottoFinitoID := ADataSet.FieldByName('lotto_prodotto_finito_id').AsInteger;

  FCreatoIl     := ADataSet.FieldByName('creato_il').AsDateTime;
  FAggiornatoIl := ADataSet.FieldByName('aggiornato_il').AsDateTime;
end;

class function TNonConformita.GetByID(AID: Integer): TNonConformita;
var
  LAutoQuery: TAutoQuery;
begin
  Result := nil;

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE id = :id', [AID]);
  try
    if not LAutoQuery.Query.IsEmpty then
    begin
      Result := TNonConformita.Create;
      Result.LoadFromDataSet(LAutoQuery.Query);
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TNonConformita.GetByCodice(const ACodiceNC: string): TNonConformita;
var
  LAutoQuery: TAutoQuery;
begin
  // codice_nc e' UNIQUE.
  Result := nil;

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE codice_nc = :codice_nc', [ACodiceNC]);
  try
    if not LAutoQuery.Query.IsEmpty then
    begin
      Result := TNonConformita.Create;
      Result.LoadFromDataSet(LAutoQuery.Query);
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TNonConformita.GetAll: TObjectList<TNonConformita>;
var
  LAutoQuery: TAutoQuery;
  LNC: TNonConformita;
begin
  Result := TObjectList<TNonConformita>.Create(True); // possiede gli oggetti

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'ORDER BY data_apertura DESC');
  try
    while not LAutoQuery.Query.Eof do
    begin
      LNC := TNonConformita.Create;
      LNC.LoadFromDataSet(LAutoQuery.Query);
      Result.Add(LNC);
      LAutoQuery.Query.Next;
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TNonConformita.GetByStato(const AStato: string): TObjectList<TNonConformita>;
var
  LAutoQuery: TAutoQuery;
  LNC: TNonConformita;
begin
  // Es. GetByStato('aperta') per le non conformita' da gestire.
  Result := TObjectList<TNonConformita>.Create(True);

  // Stesso cast esplicito di Insert: anche in una WHERE, :stato_nc legato come character
  // varying darebbe lo stesso errore di tipo.
  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE stato_nc = :stato_nc::stato_nc_enum ORDER BY data_apertura',
    [AStato]);
  try
    while not LAutoQuery.Query.Eof do
    begin
      LNC := TNonConformita.Create;
      LNC.LoadFromDataSet(LAutoQuery.Query);
      Result.Add(LNC);
      LAutoQuery.Query.Next;
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TNonConformita.GetByLottoMateriaPrima(ALottoMateriaPrimaID: Integer): TObjectList<TNonConformita>;
var
  LAutoQuery: TAutoQuery;
  LNC: TNonConformita;
begin
  // Le non conformita' gia' associate a un lotto di materia prima: primo controllo del
  // richiamo.
  Result := TObjectList<TNonConformita>.Create(True);

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE lotto_materia_prima_id = :lotto_materia_prima_id ' +
    'ORDER BY data_apertura DESC',
    [ALottoMateriaPrimaID]);
  try
    while not LAutoQuery.Query.Eof do
    begin
      LNC := TNonConformita.Create;
      LNC.LoadFromDataSet(LAutoQuery.Query);
      Result.Add(LNC);
      LAutoQuery.Query.Next;
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TNonConformita.GetByLottoSemilavorato(ALottoSemilavoratoID: Integer): TObjectList<TNonConformita>;
var
  LAutoQuery: TAutoQuery;
  LNC: TNonConformita;
begin
  Result := TObjectList<TNonConformita>.Create(True);

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE lotto_semilavorato_id = :lotto_semilavorato_id ' +
    'ORDER BY data_apertura DESC',
    [ALottoSemilavoratoID]);
  try
    while not LAutoQuery.Query.Eof do
    begin
      LNC := TNonConformita.Create;
      LNC.LoadFromDataSet(LAutoQuery.Query);
      Result.Add(LNC);
      LAutoQuery.Query.Next;
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TNonConformita.GetByLottoProdottoFinito(ALottoProdottoFinitoID: Integer): TObjectList<TNonConformita>;
var
  LAutoQuery: TAutoQuery;
  LNC: TNonConformita;
begin
  Result := TObjectList<TNonConformita>.Create(True);

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE lotto_prodotto_finito_id = :lotto_prodotto_finito_id ' +
    'ORDER BY data_apertura DESC',
    [ALottoProdottoFinitoID]);
  try
    while not LAutoQuery.Query.Eof do
    begin
      LNC := TNonConformita.Create;
      LNC.LoadFromDataSet(LAutoQuery.Query);
      Result.Add(LNC);
      LAutoQuery.Query.Next;
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TNonConformita.Delete(AID: Integer): Boolean;
begin
  // Nodo foglia: nessuna FK lo referenzia.
  Result := TDB.GetInstance.executeQuery(
    'DELETE FROM non_conformita WHERE id = :id', [AID]);
end;

function TNonConformita.Insert: Integer;
var
  LAutoQuery: TAutoQuery;
  LMateriaPrimaParam, LSemilavoratoParam, LProdottoFinitoParam: Variant;
begin
  EnsureStatoValido;
  EnsureAlmenoUnLottoValido;

  if FLottoMateriaPrimaID = 0 then LMateriaPrimaParam := Null else LMateriaPrimaParam := FLottoMateriaPrimaID;
  if FLottoSemilavoratoID = 0 then LSemilavoratoParam := Null else LSemilavoratoParam := FLottoSemilavoratoID;
  if FLottoProdottoFinitoID = 0 then LProdottoFinitoParam := Null else LProdottoFinitoParam := FLottoProdottoFinitoID;

  // creato_il/aggiornato_il: DEFAULT del database. Un duplicato sul vincolo UNIQUE solleva
  // un'eccezione da gestire nel controller.
  LAutoQuery := TDB.GetInstance.getQueryResult(
    'INSERT INTO non_conformita ' +
    '(codice_nc, motivo, stato_nc, data_apertura, azioni_correttive, ' +
    'lotto_materia_prima_id, lotto_semilavorato_id, lotto_prodotto_finito_id) ' +
    // Cast esplicito :stato_nc::stato_nc_enum: stato_nc e' un ENUM nativo ma FireDAC lega
    // il parametro come character varying e Postgres non fa il cast implicito. Cast
    // esplicito anche sui tre id di lotto: se il chiamante passa NULL, FireDAC non puo'
    // dedurre il tipo e lo lega come testo (errore "colonna di tipo integer ma espressione
    // character varying"); con un intero valorizzato funziona.
    'VALUES (:codice_nc, :motivo, :stato_nc::stato_nc_enum, :data_apertura, :azioni_correttive, ' +
    ':lotto_materia_prima_id::integer, :lotto_semilavorato_id::integer, ' +
    ':lotto_prodotto_finito_id::integer) ' +
    'RETURNING id, creato_il, aggiornato_il',
    [FCodiceNC, FMotivo, FStatoNC, FDataApertura, FAzioniCorrettive,
     LMateriaPrimaParam, LSemilavoratoParam, LProdottoFinitoParam]);
  try
    FID           := LAutoQuery.Query.FieldByName('id').AsInteger;
    FCreatoIl     := LAutoQuery.Query.FieldByName('creato_il').AsDateTime;
    FAggiornatoIl := LAutoQuery.Query.FieldByName('aggiornato_il').AsDateTime;
    Result := FID;
  finally
    LAutoQuery.Free;
  end;
end;

function TNonConformita.Update: Boolean;
var
  LAutoQuery: TAutoQuery;
  LMateriaPrimaParam, LSemilavoratoParam, LProdottoFinitoParam: Variant;
begin
  EnsureStatoValido;
  EnsureAlmenoUnLottoValido;

  if FLottoMateriaPrimaID = 0 then LMateriaPrimaParam := Null else LMateriaPrimaParam := FLottoMateriaPrimaID;
  if FLottoSemilavoratoID = 0 then LSemilavoratoParam := Null else LSemilavoratoParam := FLottoSemilavoratoID;
  if FLottoProdottoFinitoID = 0 then LProdottoFinitoParam := Null else LProdottoFinitoParam := FLottoProdottoFinitoID;

  // aggiornato_il lo imposta il trigger.
  LAutoQuery := TDB.GetInstance.getQueryResult(
    'UPDATE non_conformita SET codice_nc = :codice_nc, motivo = :motivo, ' +
    // Stesso cast esplicito di Insert.
    'stato_nc = :stato_nc::stato_nc_enum, data_apertura = :data_apertura, ' +
    'azioni_correttive = :azioni_correttive, ' +
    // Cast espliciti sui tre id di lotto, come in Insert.
    'lotto_materia_prima_id = :lotto_materia_prima_id::integer, ' +
    'lotto_semilavorato_id = :lotto_semilavorato_id::integer, ' +
    'lotto_prodotto_finito_id = :lotto_prodotto_finito_id::integer ' +
    'WHERE id = :id ' +
    'RETURNING aggiornato_il',
    [FCodiceNC, FMotivo, FStatoNC, FDataApertura, FAzioniCorrettive,
     LMateriaPrimaParam, LSemilavoratoParam, LProdottoFinitoParam, FID]);
  try
    Result := not LAutoQuery.Query.IsEmpty;
    if Result then
      FAggiornatoIl := LAutoQuery.Query.FieldByName('aggiornato_il').AsDateTime;
  finally
    LAutoQuery.Free;
  end;
end;

function TNonConformita.Save: Boolean;
begin
  if FID = 0 then
  begin
    Insert;
    Result := FID > 0;
  end
  else
    Result := Update;
end;

function TNonConformita.ToJSONObject: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('id', TJSONNumber.Create(FID));
  Result.AddPair('codice_nc', FCodiceNC);
  Result.AddPair('motivo', FMotivo);
  Result.AddPair('stato_nc', FStatoNC);
  Result.AddPair('data_apertura', DateToISO8601(FDataApertura));
  Result.AddPair('azioni_correttive', FAzioniCorrettive);
  if FLottoMateriaPrimaID = 0 then
    Result.AddPair('lotto_materia_prima_id', TJSONNull.Create)
  else
    Result.AddPair('lotto_materia_prima_id', TJSONNumber.Create(FLottoMateriaPrimaID));
  if FLottoSemilavoratoID = 0 then
    Result.AddPair('lotto_semilavorato_id', TJSONNull.Create)
  else
    Result.AddPair('lotto_semilavorato_id', TJSONNumber.Create(FLottoSemilavoratoID));
  if FLottoProdottoFinitoID = 0 then
    Result.AddPair('lotto_prodotto_finito_id', TJSONNull.Create)
  else
    Result.AddPair('lotto_prodotto_finito_id', TJSONNumber.Create(FLottoProdottoFinitoID));
  Result.AddPair('creato_il', DateToISO8601(FCreatoIl));
  Result.AddPair('aggiornato_il', DateToISO8601(FAggiornatoIl));
end;

procedure TNonConformita.FromJSONObject(AJSON: TJSONObject);
var
  LValInt: Integer;
  LValStr: string;
begin
  // Id e audit non si leggono dal payload: li gestisce il database.
  if AJSON.TryGetValue<string>('codice_nc', LValStr) then
    FCodiceNC := LValStr;
  if AJSON.TryGetValue<string>('motivo', LValStr) then
    FMotivo := LValStr;
  if AJSON.TryGetValue<string>('stato_nc', LValStr) then
    FStatoNC := LValStr;
  if AJSON.TryGetValue<string>('data_apertura', LValStr) then
    FDataApertura := ISO8601ToDate(LValStr);
  if AJSON.TryGetValue<string>('azioni_correttive', LValStr) then
    FAzioniCorrettive := LValStr;
  if AJSON.TryGetValue<Integer>('lotto_materia_prima_id', LValInt) then
    FLottoMateriaPrimaID := LValInt;
  if AJSON.TryGetValue<Integer>('lotto_semilavorato_id', LValInt) then
    FLottoSemilavoratoID := LValInt;
  if AJSON.TryGetValue<Integer>('lotto_prodotto_finito_id', LValInt) then
    FLottoProdottoFinitoID := LValInt;
end;

end.
