unit uModelRicettaSemilavorato;

interface

uses
  System.SysUtils,
  System.Variants,
  System.Generics.Collections,
  Data.DB, System.JSON, System.DateUtils,
  DbU;

type
  // Rappresenta la testata di una versione di ricetta di un semilavorato
  // (tabella ricette_semilavorati). Le ricette sono VERSIONATE: ogni
  // modifica non aggiorna la riga esistente, ne crea una nuova con
  // Versione incrementata. ValidaAl = NULL identifica la versione
  // CORRENTE; il DB garantisce con un indice unico parziale
  // (idx_ricetta_semilavorato_corrente, WHERE valida_al IS NULL) che ce
  // ne sia al massimo una per semilavorato.
  //
  // ValidaAl usa 0 (TDateTime "vuoto") come sentinella per NULL: non e'
  // un valore di data ambiguo perche' 0 corrisponde al 30/12/1899, una
  // data che non si presentera' mai in questo dominio. E' lo stesso
  // criterio gia' usato per gli ID (0 = non ancora salvato).
  //
  // Perche' il versionamento conta per il progetto: lo scenario di
  // ritiro/richiamo deve poter ricostruire ESATTAMENTE quale ricetta era
  // in vigore quando un dato lotto e' stato prodotto (vedi
  // lotti_semilavorati.ricetta_id, che punta a una versione specifica,
  // non genericamente al semilavorato). Aggiornare la ricetta esistente
  // in place romperebbe questa tracciabilita' storica.
  TRicettaSemilavorato = class
  private
    FID: Integer;
    FSemilavoratoID: Integer;
    FVersione: Integer;
    FValidaDal: TDateTime;
    FValidaAl: TDateTime;       // 0 = NULL = versione corrente
    FCreatoDa: string;
    FNote: string;
    FCreatoIl: TDateTime;
    FAggiornatoIl: TDateTime;

    procedure LoadFromDataSet(ADataSet: TDataSet);
    function GetIsCorrente: Boolean;
  public
    constructor Create;

    property ID: Integer read FID write FID;
    property SemilavoratoID: Integer read FSemilavoratoID write FSemilavoratoID;
    property Versione: Integer read FVersione write FVersione;
    property ValidaDal: TDateTime read FValidaDal write FValidaDal;
    property ValidaAl: TDateTime read FValidaAl write FValidaAl;
    property IsCorrente: Boolean read GetIsCorrente;
    property CreatoDa: string read FCreatoDa write FCreatoDa;
    property Note: string read FNote write FNote;

    // Campi di audit: sola lettura, gestiti dal database (default/trigger
    // trg_ricette_semilavorati_aggiornato_il)
    property CreatoIl: TDateTime read FCreatoIl;
    property AggiornatoIl: TDateTime read FAggiornatoIl;

    // Operazioni CRUD
    class function GetByID(AID: Integer): TRicettaSemilavorato;
    class function GetCorrente(ASemilavoratoID: Integer): TRicettaSemilavorato;
    class function GetByVersione(ASemilavoratoID, AVersione: Integer): TRicettaSemilavorato;
    class function GetStorico(ASemilavoratoID: Integer): TObjectList<TRicettaSemilavorato>;
    class function Delete(AID: Integer): Boolean;

    function Insert: Integer;   // restituisce l'ID generato — SOLO per la primissima versione
    function Update: Boolean;
    function ToJSONObject: TJSONObject;
    procedure FromJSONObject(AJSON: TJSONObject);

    // Crea atomicamente una nuova versione corrente: chiude (ValidaAl =
    // CURRENT_DATE) l'eventuale versione corrente esistente e ne inserisce
    // una nuova con Versione incrementata e ValidaAl = NULL. Le due
    // operazioni vanno in un'unica transazione (TDB.ExecuteQueriesInTransaction):
    // senza atomicita', un fallimento a meta' potrebbe lasciare il
    // semilavorato SENZA alcuna versione corrente. E' il modo corretto —
    // non Insert — per introdurre una modifica alla ricetta.
    class function CreaNuovaVersione(ASemilavoratoID: Integer;
      const ACreatoDa, ANote: string): TRicettaSemilavorato;

  end;

implementation

const
  SQL_SELECT_BASE =
    'SELECT id, semilavorato_id, versione, valida_dal, valida_al, ' +
    'creato_da, note, creato_il, aggiornato_il ' +
    'FROM ricette_semilavorati ';

{ TRicettaSemilavorato }

constructor TRicettaSemilavorato.Create;
begin
  inherited Create;
  FID := 0;
  FVersione := 1;
  FValidaDal := Date; // replica il DEFAULT CURRENT_DATE lato database
  FValidaAl := 0; // NULL: per default un oggetto nuovo rappresenta una versione corrente
end;

function TRicettaSemilavorato.GetIsCorrente: Boolean;
begin
  Result := FValidaAl = 0;
end;

procedure TRicettaSemilavorato.LoadFromDataSet(ADataSet: TDataSet);
begin
  FID             := ADataSet.FieldByName('id').AsInteger;
  FSemilavoratoID := ADataSet.FieldByName('semilavorato_id').AsInteger;
  FVersione       := ADataSet.FieldByName('versione').AsInteger;
  FValidaDal      := ADataSet.FieldByName('valida_dal').AsDateTime;

  if ADataSet.FieldByName('valida_al').IsNull then
    FValidaAl := 0
  else
    FValidaAl := ADataSet.FieldByName('valida_al').AsDateTime;

  FCreatoDa     := ADataSet.FieldByName('creato_da').AsString;
  FNote         := ADataSet.FieldByName('note').AsString;

  FCreatoIl     := ADataSet.FieldByName('creato_il').AsDateTime;
  FAggiornatoIl := ADataSet.FieldByName('aggiornato_il').AsDateTime;
end;

class function TRicettaSemilavorato.GetByID(AID: Integer): TRicettaSemilavorato;
var
  LAutoQuery: TAutoQuery;
begin
  Result := nil;

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE id = :id', [AID]);
  try
    if not LAutoQuery.Query.IsEmpty then
    begin
      Result := TRicettaSemilavorato.Create;
      Result.LoadFromDataSet(LAutoQuery.Query);
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TRicettaSemilavorato.GetCorrente(ASemilavoratoID: Integer): TRicettaSemilavorato;
var
  LAutoQuery: TAutoQuery;
begin
  // valida_al IS NULL e' un letterale in SQL, non un parametro: non si
  // puo' fare ":x IS NULL" con parametro NULL in modo portabile via
  // FireDAC/PostgreSQL, quindi lo scriviamo direttamente nel testo.
  Result := nil;

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE semilavorato_id = :semilavorato_id ' +
    'AND valida_al IS NULL',
    [ASemilavoratoID]);
  try
    if not LAutoQuery.Query.IsEmpty then
    begin
      Result := TRicettaSemilavorato.Create;
      Result.LoadFromDataSet(LAutoQuery.Query);
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TRicettaSemilavorato.GetByVersione(ASemilavoratoID, AVersione: Integer): TRicettaSemilavorato;
var
  LAutoQuery: TAutoQuery;
begin
  Result := nil;

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE semilavorato_id = :semilavorato_id ' +
    'AND versione = :versione',
    [ASemilavoratoID, AVersione]);
  try
    if not LAutoQuery.Query.IsEmpty then
    begin
      Result := TRicettaSemilavorato.Create;
      Result.LoadFromDataSet(LAutoQuery.Query);
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TRicettaSemilavorato.GetStorico(ASemilavoratoID: Integer): TObjectList<TRicettaSemilavorato>;
var
  LAutoQuery: TAutoQuery;
  LRicetta: TRicettaSemilavorato;
begin
  // Tutte le versioni di un semilavorato, dalla piu' vecchia alla piu'
  // recente: utile per ricostruire l'evoluzione della ricetta nel tempo.
  Result := TObjectList<TRicettaSemilavorato>.Create(True);

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE semilavorato_id = :semilavorato_id ' +
    'ORDER BY versione',
    [ASemilavoratoID]);
  try
    while not LAutoQuery.Query.Eof do
    begin
      LRicetta := TRicettaSemilavorato.Create;
      LRicetta.LoadFromDataSet(LAutoQuery.Query);
      Result.Add(LRicetta);
      LAutoQuery.Query.Next;
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TRicettaSemilavorato.Delete(AID: Integer): Boolean;
begin
  // Una ricetta e' referenziata da ricette_semilavorati_righe e da
  // lotti_semilavorati.ricetta_id: in assenza di ON DELETE CASCADE lato
  // DB, la query fallisce se la ricetta ha righe o e' gia' stata usata
  // per produrre un lotto. Comportamento voluto: una versione di ricetta
  // e' un dato storico/di tracciabilita', non va cancellata una volta
  // utilizzata. Per "ritirarla" dall'uso corrente si usa
  // CreaNuovaVersione, non Delete.
  Result := TDB.GetInstance.executeQuery(
    'DELETE FROM ricette_semilavorati WHERE id = :id', [AID]);
end;

function TRicettaSemilavorato.Insert: Integer;
var
  LAutoQuery: TAutoQuery;
  LValidaAlParam: Variant;
begin
  // Da usare SOLO per la primissima versione di una ricetta (quando non
  // esiste ancora nessuna versione corrente da chiudere). Per introdurre
  // una modifica a una ricetta gia' esistente usare CreaNuovaVersione,
  // che gestisce l'atomicita' chiusura+apertura.
  // creato_il e aggiornato_il NON compaiono tra i campi inseriti: sono
  // valorizzati dal DEFAULT del database (now()).
  if FValidaAl = 0 then
    LValidaAlParam := Null
  else
    LValidaAlParam := FValidaAl;

  LAutoQuery := TDB.GetInstance.getQueryResult(
    'INSERT INTO ricette_semilavorati ' +
    '(semilavorato_id, versione, valida_dal, valida_al, creato_da, note) ' +
    'VALUES (:semilavorato_id, :versione, :valida_dal, :valida_al::date, :creato_da, :note) ' +
    'RETURNING id, valida_dal, creato_il, aggiornato_il',
    [FSemilavoratoID, FVersione, FValidaDal, LValidaAlParam, FCreatoDa, FNote]);
  try
    FID           := LAutoQuery.Query.FieldByName('id').AsInteger;
    FValidaDal    := LAutoQuery.Query.FieldByName('valida_dal').AsDateTime;
    FCreatoIl     := LAutoQuery.Query.FieldByName('creato_il').AsDateTime;
    FAggiornatoIl := LAutoQuery.Query.FieldByName('aggiornato_il').AsDateTime;
    Result := FID;
  finally
    LAutoQuery.Free;
  end;
end;

function TRicettaSemilavorato.Update: Boolean;
var
  LAutoQuery: TAutoQuery;
  LValidaAlParam: Variant;
begin
  // Aggiorna i campi non di versionamento (creato_da, note) o, se
  // necessario, corregge manualmente le date. Per il flusso normale di
  // "nuova versione" si usa CreaNuovaVersione, non Update.
  // aggiornato_il NON viene impostato esplicitamente: il trigger
  // trg_ricette_semilavorati_aggiornato_il lo valorizza automaticamente.
  if FValidaAl = 0 then
    LValidaAlParam := Null
  else
    LValidaAlParam := FValidaAl;

  LAutoQuery := TDB.GetInstance.getQueryResult(
    'UPDATE ricette_semilavorati SET semilavorato_id = :semilavorato_id, ' +
    'versione = :versione, valida_dal = :valida_dal, valida_al = :valida_al::date, ' +
    'creato_da = :creato_da, note = :note ' +
    'WHERE id = :id ' +
    'RETURNING aggiornato_il',
    [FSemilavoratoID, FVersione, FValidaDal, LValidaAlParam, FCreatoDa, FNote, FID]);
  try
    Result := not LAutoQuery.Query.IsEmpty;
    if Result then
      FAggiornatoIl := LAutoQuery.Query.FieldByName('aggiornato_il').AsDateTime;
  finally
    LAutoQuery.Free;
  end;
end;

function TRicettaSemilavorato.ToJSONObject: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('id', TJSONNumber.Create(FID));
  Result.AddPair('semilavorato_id', TJSONNumber.Create(FSemilavoratoID));
  Result.AddPair('versione', TJSONNumber.Create(FVersione));
  Result.AddPair('valida_dal', DateToISO8601(FValidaDal));
  if FValidaAl = 0 then
    Result.AddPair('valida_al', TJSONNull.Create)
  else
    Result.AddPair('valida_al', DateToISO8601(FValidaAl));
  Result.AddPair('is_corrente', TJSONBool.Create(IsCorrente));
  Result.AddPair('creato_da', FCreatoDa);
  Result.AddPair('note', FNote);
  Result.AddPair('creato_il', DateToISO8601(FCreatoIl));
  Result.AddPair('aggiornato_il', DateToISO8601(FAggiornatoIl));
end;

procedure TRicettaSemilavorato.FromJSONObject(AJSON: TJSONObject);
var
  LValInt: Integer;
  LValStr: string;
begin
  // id, versione, valida_al, creato_il, aggiornato_il NON vengono letti
  // dal payload in ingresso: il versionamento e' gestito da
  // CreaNuovaVersione, non da un client che scrive direttamente questi
  // campi.
  if AJSON.TryGetValue<Integer>('semilavorato_id', LValInt) then
    FSemilavoratoID := LValInt;
  if AJSON.TryGetValue<string>('valida_dal', LValStr) then
    FValidaDal := ISO8601ToDate(LValStr);
  if AJSON.TryGetValue<string>('creato_da', LValStr) then
    FCreatoDa := LValStr;
  if AJSON.TryGetValue<string>('note', LValStr) then
    FNote := LValStr;
end;

class function TRicettaSemilavorato.CreaNuovaVersione(ASemilavoratoID: Integer;
  const ACreatoDa, ANote: string): TRicettaSemilavorato;
var
  LCorrente: TRicettaSemilavorato;
  LNuovaVersione: Integer;
  LQueries: TArray<string>;
  LParamsList: TArray<TArray<Variant>>;
begin
  LCorrente := GetCorrente(ASemilavoratoID);
  try
    if Assigned(LCorrente) then
      LNuovaVersione := LCorrente.Versione + 1
    else
      LNuovaVersione := 1;

    if Assigned(LCorrente) then
    begin
      // Chiude la versione corrente esistente e apre la nuova in
      // un'unica transazione. CURRENT_DATE e' un letterale SQL, non un
      // parametro: e' deterministico e non richiede binding.
      SetLength(LQueries, 2);
      SetLength(LParamsList, 2);

      LQueries[0] := 'UPDATE ricette_semilavorati SET valida_al = CURRENT_DATE WHERE id = :id';
      LParamsList[0] := [LCorrente.ID];

      LQueries[1] :=
        'INSERT INTO ricette_semilavorati ' +
        '(semilavorato_id, versione, creato_da, note) ' +
        'VALUES (:semilavorato_id, :versione, :creato_da, :note)';
      LParamsList[1] := [ASemilavoratoID, LNuovaVersione, ACreatoDa, ANote];

      TDB.GetInstance.ExecuteQueriesInTransaction(LQueries, LParamsList);
    end
    else
    begin
      // Nessuna versione corrente da chiudere: e' la primissima ricetta
      // di questo semilavorato, un semplice Insert basta.
      Result := TRicettaSemilavorato.Create;
      Result.SemilavoratoID := ASemilavoratoID;
      Result.Versione := LNuovaVersione;
      Result.CreatoDa := ACreatoDa;
      Result.Note := ANote;
      Result.Insert;
      Exit;
    end;
  finally
    LCorrente.Free;
  end;

  // Ricarica dal DB lo stato appena scritto (fuori dalla transazione,
  // che a questo punto e' gia' stata commitata): garantisce che
  // l'oggetto restituito rifletta esattamente cio' che e' stato
  // persistito, incluso il valida_dal di default del DB.
  Result := GetCorrente(ASemilavoratoID);
end;

end.
