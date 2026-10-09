unit uModelRicettaSemilavorato;

interface

uses
  System.SysUtils,
  System.Variants,
  System.Generics.Collections,
  Data.DB, System.JSON, System.DateUtils,
  DbU;

type
  // Testata di una versione di ricetta di semilavorato (ricette_semilavorati). Le ricette
  // sono versionate: una modifica non aggiorna la riga ma ne crea una con Versione
  // incrementata. ValidaAl = NULL e' la versione corrente (al massimo una per semilavorato,
  // indice unico parziale idx_ricetta_semilavorato_corrente, WHERE valida_al IS NULL).
  // ValidaAl usa 0 (30/12/1899, data che non comparira' mai) come sentinella per NULL, come
  // gli ID (0 = non salvato).
  // Il versionamento serve al richiamo, che deve ricostruire quale ricetta era in vigore
  // alla produzione di un lotto (lotti_semilavorati.ricetta_id punta a una versione).
  // Aggiornare in place romperebbe lo storico.
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

    property CreatoIl: TDateTime read FCreatoIl;
    property AggiornatoIl: TDateTime read FAggiornatoIl;

    class function GetByID(AID: Integer): TRicettaSemilavorato;
    class function GetCorrente(ASemilavoratoID: Integer): TRicettaSemilavorato;
    class function GetByVersione(ASemilavoratoID, AVersione: Integer): TRicettaSemilavorato;
    class function GetStorico(ASemilavoratoID: Integer): TObjectList<TRicettaSemilavorato>;
    class function Delete(AID: Integer): Boolean;

    function Insert: Integer;   // restituisce l'ID generato — SOLO per la primissima versione
    function Update: Boolean;
    function ToJSONObject: TJSONObject;
    procedure FromJSONObject(AJSON: TJSONObject);

    // Crea atomicamente una nuova versione corrente: chiude (ValidaAl = CURRENT_DATE) la
    // corrente e inserisce la nuova con Versione incrementata e ValidaAl = NULL, in una
    // transazione (TDB.ExecuteQueriesInTransaction): altrimenti un errore a meta'
    // lascerebbe il semilavorato senza versione corrente. E' il modo per modificare una
    // ricetta, non Insert.
    class function CreaNuovaVersione(ASemilavoratoID: Integer;
      const ACreatoDa, ANote: string): TRicettaSemilavorato;

  end;

implementation

const
  SQL_SELECT_BASE =
    'SELECT id, semilavorato_id, versione, valida_dal, valida_al, ' +
    'creato_da, note, creato_il, aggiornato_il ' +
    'FROM ricette_semilavorati ';

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
  // valida_al IS NULL e' un letterale SQL: ":x IS NULL" con parametro NULL non e' portabile
  // in FireDAC/PostgreSQL.
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
  // Tutte le versioni, dalla piu' vecchia: l'evoluzione della ricetta.
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
  // Fallisce se il record e' referenziato (nessun ON DELETE CASCADE): voluto, per non
  // perdere dati di tracciabilita'.
  Result := TDB.GetInstance.executeQuery(
    'DELETE FROM ricette_semilavorati WHERE id = :id', [AID]);
end;

function TRicettaSemilavorato.Insert: Integer;
var
  LAutoQuery: TAutoQuery;
  LValidaAlParam: Variant;
begin
  // Solo per la primissima versione, quando non c'e' una corrente da chiudere. Per
  // modificare usare CreaNuovaVersione. creato_il/aggiornato_il: DEFAULT del database.
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
  // Aggiorna i campi non di versionamento (creato_da, note) o corregge le date a mano. Per
  // una nuova versione usare CreaNuovaVersione. aggiornato_il lo imposta il trigger.
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
  // id, versione, valida_al e audit non si leggono dal payload: il versionamento e' di
  // CreaNuovaVersione.
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
      // Chiude la corrente e apre la nuova in una transazione. CURRENT_DATE e' un letterale
      // SQL, deterministico.
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
      // Nessuna versione corrente da chiudere: basta un Insert.
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

  // Ricarica lo stato scritto (a transazione gia' committata), incluso il valida_dal di
  // default.
  Result := GetCorrente(ASemilavoratoID);
end;

end.
