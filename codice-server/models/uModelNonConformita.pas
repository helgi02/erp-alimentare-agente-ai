unit uModelNonConformita;

interface

uses
  System.SysUtils,
  System.Variants,
  System.Generics.Collections,
  Data.DB, System.JSON, System.DateUtils,
  DbU;

type
  // Rappresenta una non conformita' rilevata su un lotto (tabella
  // non_conformita) — l'evento che innesca lo scenario di
  // ritiro/richiamo (2.1). Da qui l'agente MCP identifica, tramite i
  // lotti coinvolti, tutti i prodotti finiti che li impiegano
  // (risalendo consumi_produzione_*), verifica quali sono ancora in
  // giacenza e quali gia' presso i clienti (tramite ordini_vendita_righe
  // e ddt_uscita), e determina se generare solo la Scheda di Notifica
  // OSA o anche il Modello di Richiamo al Consumatore.
  //
  // A differenza dei pattern XOR gia' visti (ricette, consumi), qui il
  // CHECK del DDL (chk_lotto_non_conformita) e' un OR, non uno XOR:
  // almeno UNO tra i tre lotti deve essere valorizzato, ma non e' vietato
  // che lo siano piu' di uno. Questo riflette un caso reale: una singola
  // non conformita' puo' riguardare contemporaneamente, ad esempio, sia
  // il lotto di materia prima contaminato sia i lotti di prodotto finito
  // che lo hanno gia' incorporato, se si vuole tracciarli sotto lo stesso
  // codice_nc invece di aprire NC separate collegate manualmente.
  //
  // StatoNC e' un ENUM PostgreSQL nativo (stato_nc_enum), non un
  // VARCHAR con CHECK come lo Stato di TOrdineFornitore/TOrdineVendita:
  // FireDAC lo restituisce comunque come stringa via AsString, quindi
  // qui lo trattiamo come string per semplicita' — la validazione dei
  // valori ammessi resta comunque replicata lato Delphi in
  // EnsureStatoValido, per lo stesso motivo delle altre EnsureXxxValido.
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

    // Campi di audit: sola lettura, gestiti dal database (default/trigger
    // trg_non_conformita_aggiornato_il)
    property CreatoIl: TDateTime read FCreatoIl;
    property AggiornatoIl: TDateTime read FAggiornatoIl;

    // Operazioni CRUD
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

  // Valori ammessi dall'ENUM stato_nc_enum: replicati qui per validare
  // lato Delphi prima di arrivare al DB.
  STATI_VALIDI: array[0..2] of string = ('aperta', 'in_gestione', 'chiusa');

{ TNonConformita }

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
  // Replica lato Delphi il CHECK chk_lotto_non_conformita: e' un OR, non
  // uno XOR come negli altri EnsureXxxValido di questo progetto — basta
  // che ALMENO UNO dei tre lotti sia valorizzato, possono esserlo anche
  // due o tutti e tre.
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
  // codice_nc ha un vincolo UNIQUE.
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
  // Uso tipico: GetByStato('aperta') per elencare le non conformita'
  // ancora da gestire.
  Result := TObjectList<TNonConformita>.Create(True);

  // Stesso cast esplicito di Insert/Update (vedi commento in Insert): un
  // confronto stato_nc = :stato_nc con :stato_nc legato come character
  // varying fallisce con lo stesso errore di tipo, anche in una WHERE.
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
  // Verifica se un dato lotto di materia prima ha gia' una o piu' non
  // conformita' associate: primo controllo dell'agente MCP quando avvia
  // lo scenario di ritiro/richiamo.
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
  // Nessun'altra tabella referenzia non_conformita come FK: nodo foglia
  // nello schema. Va comunque usata con cautela: e' un dato di
  // compliance (Reg. CE 178/2002), non un semplice record operativo. Per
  // chiudere una NC si usa stato_nc = 'chiusa', non Delete.
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

  // creato_il e aggiornato_il NON compaiono tra i campi inseriti: sono
  // valorizzati dal DEFAULT del database (now()). codice_nc ha un
  // vincolo UNIQUE: un duplicato solleva un'eccezione da gestire a
  // livello di controller.
  LAutoQuery := TDB.GetInstance.getQueryResult(
    'INSERT INTO non_conformita ' +
    '(codice_nc, motivo, stato_nc, data_apertura, azioni_correttive, ' +
    'lotto_materia_prima_id, lotto_semilavorato_id, lotto_prodotto_finito_id) ' +
    // :stato_nc::stato_nc_enum - cast esplicito necessario: stato_nc e' un
    // ENUM nativo Postgres (vedi commento di classe su StatoNC), ma FireDAC
    // lega il parametro come character varying. Senza il cast, Postgres
    // solleva 'la colonna "stato_nc" e'' di tipo stato_nc_enum ma
    // l''espressione e'' di tipo character varying' - non e' un problema
    // di valore (EnsureStatoValido lo ha gia'' validato sopra), e' proprio
    // il driver che non fa il cast implicito verso un tipo enum custom.
    // Cast esplicito anche sui tre id di lotto (oltre a stato_nc sopra):
    // quando il chiamante passa NULL (nessun lotto di quel tipo coinvolto,
    // vedi LMateriaPrimaParam/LSemilavoratoParam/LProdottoFinitoParam sotto),
    // FireDAC non ha un valore concreto da cui dedurre il tipo del
    // parametro e lo lega come testo generico - stesso errore "colonna di
    // tipo integer ma l''espressione e'' di tipo character varying" gia''
    // visto per stato_nc, qui pero'' innescato solo quando il valore e''
    // Null (con un intero valorizzato FireDAC lo lega correttamente).
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

  // aggiornato_il NON viene impostato esplicitamente: il trigger
  // trg_non_conformita_aggiornato_il lo valorizza automaticamente.
  // E' questo il metodo con cui, in pratica, si fa avanzare lo stato
  // (aperta -> in_gestione -> chiusa) e si compilano le azioni
  // correttive man mano che la procedura di gestione avanza.
  LAutoQuery := TDB.GetInstance.getQueryResult(
    'UPDATE non_conformita SET codice_nc = :codice_nc, motivo = :motivo, ' +
    // Stesso cast esplicito di Insert, stesso motivo (vedi commento li').
    'stato_nc = :stato_nc::stato_nc_enum, data_apertura = :data_apertura, ' +
    'azioni_correttive = :azioni_correttive, ' +
    // Cast espliciti sui tre id di lotto, stesso motivo di Insert (vedi
    // commento li'').
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
  // id, creato_il, aggiornato_il NON vengono letti dal payload in
  // ingresso: sono gestiti dal database, mai dal client
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
