unit uModelRicettaProdottoFinito;

interface

uses
  System.SysUtils,
  System.Variants,
  System.Generics.Collections,
  Data.DB, System.JSON, System.DateUtils,
  DbU;

type
  // Testata di una versione di ricetta di prodotto finito (ricette_prodotti_finiti). Stesso
  // versionamento di TRicettaSemilavorato (ValidaAl = NULL = versione corrente, indice
  // unico parziale, 0 = NULL): vedi li' il ragionamento completo.
  // E' l'entita' centrale dello scenario 3: il turno 1 legge la ricetta corrente
  // (GetCorrente) per proporre sostituti; il turno 2 usa prezzi e dosi originali
  // (TRicettaProdottoFinitoRiga) per il delta di costo e il nuovo prezzo suggerito.
  TRicettaProdottoFinito = class
  private
    FID: Integer;
    FProdottoFinitoID: Integer;
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
    property ProdottoFinitoID: Integer read FProdottoFinitoID write FProdottoFinitoID;
    property Versione: Integer read FVersione write FVersione;
    property ValidaDal: TDateTime read FValidaDal write FValidaDal;
    property ValidaAl: TDateTime read FValidaAl write FValidaAl;
    property IsCorrente: Boolean read GetIsCorrente;
    property CreatoDa: string read FCreatoDa write FCreatoDa;
    property Note: string read FNote write FNote;

    property CreatoIl: TDateTime read FCreatoIl;
    property AggiornatoIl: TDateTime read FAggiornatoIl;

    class function GetByID(AID: Integer): TRicettaProdottoFinito;
    class function GetCorrente(AProdottoFinitoID: Integer): TRicettaProdottoFinito;
    class function GetByVersione(AProdottoFinitoID, AVersione: Integer): TRicettaProdottoFinito;
    class function GetStorico(AProdottoFinitoID: Integer): TObjectList<TRicettaProdottoFinito>;
    class function Delete(AID: Integer): Boolean;

    function Insert: Integer;   // restituisce l'ID generato — SOLO per la primissima versione
    function Update: Boolean;
    function ToJSONObject: TJSONObject;
    procedure FromJSONObject(AJSON: TJSONObject);

    // Come TRicettaSemilavorato.CreaNuovaVersione: chiusura + apertura atomica con
    // TDB.ExecuteQueriesInTransaction.
    class function CreaNuovaVersione(AProdottoFinitoID: Integer;
      const ACreatoDa, ANote: string): TRicettaProdottoFinito;

  end;

implementation

const
  SQL_SELECT_BASE =
    'SELECT id, prodotto_finito_id, versione, valida_dal, valida_al, ' +
    'creato_da, note, creato_il, aggiornato_il ' +
    'FROM ricette_prodotti_finiti ';

constructor TRicettaProdottoFinito.Create;
begin
  inherited Create;
  FID := 0;
  FVersione := 1;
  FValidaDal := Date; // replica il DEFAULT CURRENT_DATE lato database
  FValidaAl := 0; // NULL: per default un oggetto nuovo rappresenta una versione corrente
end;

function TRicettaProdottoFinito.GetIsCorrente: Boolean;
begin
  Result := FValidaAl = 0;
end;

procedure TRicettaProdottoFinito.LoadFromDataSet(ADataSet: TDataSet);
begin
  FID               := ADataSet.FieldByName('id').AsInteger;
  FProdottoFinitoID := ADataSet.FieldByName('prodotto_finito_id').AsInteger;
  FVersione         := ADataSet.FieldByName('versione').AsInteger;
  FValidaDal        := ADataSet.FieldByName('valida_dal').AsDateTime;

  if ADataSet.FieldByName('valida_al').IsNull then
    FValidaAl := 0
  else
    FValidaAl := ADataSet.FieldByName('valida_al').AsDateTime;

  FCreatoDa     := ADataSet.FieldByName('creato_da').AsString;
  FNote         := ADataSet.FieldByName('note').AsString;
  FCreatoIl     := ADataSet.FieldByName('creato_il').AsDateTime;
  FAggiornatoIl := ADataSet.FieldByName('aggiornato_il').AsDateTime;
end;

class function TRicettaProdottoFinito.GetByID(AID: Integer): TRicettaProdottoFinito;
var
  LAutoQuery: TAutoQuery;
begin
  Result := nil;

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE id = :id', [AID]);
  try
    if not LAutoQuery.Query.IsEmpty then
    begin
      Result := TRicettaProdottoFinito.Create;
      Result.LoadFromDataSet(LAutoQuery.Query);
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TRicettaProdottoFinito.GetCorrente(AProdottoFinitoID: Integer): TRicettaProdottoFinito;
var
  LAutoQuery: TAutoQuery;
begin
  Result := nil;

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE prodotto_finito_id = :prodotto_finito_id ' +
    'AND valida_al IS NULL',
    [AProdottoFinitoID]);
  try
    if not LAutoQuery.Query.IsEmpty then
    begin
      Result := TRicettaProdottoFinito.Create;
      Result.LoadFromDataSet(LAutoQuery.Query);
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TRicettaProdottoFinito.GetByVersione(AProdottoFinitoID, AVersione: Integer): TRicettaProdottoFinito;
var
  LAutoQuery: TAutoQuery;
begin
  Result := nil;

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE prodotto_finito_id = :prodotto_finito_id ' +
    'AND versione = :versione',
    [AProdottoFinitoID, AVersione]);
  try
    if not LAutoQuery.Query.IsEmpty then
    begin
      Result := TRicettaProdottoFinito.Create;
      Result.LoadFromDataSet(LAutoQuery.Query);
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TRicettaProdottoFinito.GetStorico(AProdottoFinitoID: Integer): TObjectList<TRicettaProdottoFinito>;
var
  LAutoQuery: TAutoQuery;
  LRicetta: TRicettaProdottoFinito;
begin
  Result := TObjectList<TRicettaProdottoFinito>.Create(True);

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE prodotto_finito_id = :prodotto_finito_id ' +
    'ORDER BY versione',
    [AProdottoFinitoID]);
  try
    while not LAutoQuery.Query.Eof do
    begin
      LRicetta := TRicettaProdottoFinito.Create;
      LRicetta.LoadFromDataSet(LAutoQuery.Query);
      Result.Add(LRicetta);
      LAutoQuery.Query.Next;
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TRicettaProdottoFinito.Delete(AID: Integer): Boolean;
begin
  // Fallisce se il record e' referenziato (nessun ON DELETE CASCADE): voluto, per non
  // perdere dati di tracciabilita'.
  Result := TDB.GetInstance.executeQuery(
    'DELETE FROM ricette_prodotti_finiti WHERE id = :id', [AID]);
end;

function TRicettaProdottoFinito.Insert: Integer;
var
  LAutoQuery: TAutoQuery;
  LValidaAlParam: Variant;
begin
  // Solo per la primissima versione. Per modificare usare CreaNuovaVersione.
  if FValidaAl = 0 then
    LValidaAlParam := Null
  else
    LValidaAlParam := FValidaAl;

  LAutoQuery := TDB.GetInstance.getQueryResult(
    'INSERT INTO ricette_prodotti_finiti ' +
    '(prodotto_finito_id, versione, valida_dal, valida_al, creato_da, note) ' +
    'VALUES (:prodotto_finito_id, :versione, :valida_dal, :valida_al::date, :creato_da, :note) ' +
    'RETURNING id, valida_dal, creato_il, aggiornato_il',
    [FProdottoFinitoID, FVersione, FValidaDal, LValidaAlParam, FCreatoDa, FNote]);
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

function TRicettaProdottoFinito.Update: Boolean;
var
  LAutoQuery: TAutoQuery;
  LValidaAlParam: Variant;
begin
  // aggiornato_il lo imposta il trigger.
  if FValidaAl = 0 then
    LValidaAlParam := Null
  else
    LValidaAlParam := FValidaAl;

  LAutoQuery := TDB.GetInstance.getQueryResult(
    'UPDATE ricette_prodotti_finiti SET prodotto_finito_id = :prodotto_finito_id, ' +
    'versione = :versione, valida_dal = :valida_dal, valida_al = :valida_al::date, ' +
    'creato_da = :creato_da, note = :note ' +
    'WHERE id = :id ' +
    'RETURNING aggiornato_il',
    [FProdottoFinitoID, FVersione, FValidaDal, LValidaAlParam, FCreatoDa, FNote, FID]);
  try
    Result := not LAutoQuery.Query.IsEmpty;
    if Result then
      FAggiornatoIl := LAutoQuery.Query.FieldByName('aggiornato_il').AsDateTime;
  finally
    LAutoQuery.Free;
  end;
end;

function TRicettaProdottoFinito.ToJSONObject: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('id', TJSONNumber.Create(FID));
  Result.AddPair('prodotto_finito_id', TJSONNumber.Create(FProdottoFinitoID));
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

procedure TRicettaProdottoFinito.FromJSONObject(AJSON: TJSONObject);
var
  LValInt: Integer;
  LValStr: string;
begin
  // id, versione, valida_al e audit non si leggono dal payload: il versionamento e' di
  // CreaNuovaVersione.
  if AJSON.TryGetValue<Integer>('prodotto_finito_id', LValInt) then
    FProdottoFinitoID := LValInt;
  if AJSON.TryGetValue<string>('valida_dal', LValStr) then
    FValidaDal := ISO8601ToDate(LValStr);
  if AJSON.TryGetValue<string>('creato_da', LValStr) then
    FCreatoDa := LValStr;
  if AJSON.TryGetValue<string>('note', LValStr) then
    FNote := LValStr;
end;

class function TRicettaProdottoFinito.CreaNuovaVersione(AProdottoFinitoID: Integer;
  const ACreatoDa, ANote: string): TRicettaProdottoFinito;
var
  LCorrente: TRicettaProdottoFinito;
  LNuovaVersione: Integer;
  LQueries: TArray<string>;
  LParamsList: TArray<TArray<Variant>>;
begin
  LCorrente := GetCorrente(AProdottoFinitoID);
  try
    if Assigned(LCorrente) then
      LNuovaVersione := LCorrente.Versione + 1
    else
      LNuovaVersione := 1;

    if Assigned(LCorrente) then
    begin
      SetLength(LQueries, 2);
      SetLength(LParamsList, 2);

      LQueries[0] := 'UPDATE ricette_prodotti_finiti SET valida_al = CURRENT_DATE WHERE id = :id';
      LParamsList[0] := [LCorrente.ID];

      LQueries[1] :=
        'INSERT INTO ricette_prodotti_finiti (prodotto_finito_id, versione, creato_da, note) ' +
        'VALUES (:prodotto_finito_id, :versione, :creato_da, :note)';
      LParamsList[1] := [AProdottoFinitoID, LNuovaVersione, ACreatoDa, ANote];

      TDB.GetInstance.ExecuteQueriesInTransaction(LQueries, LParamsList);
    end
    else
    begin
      // Nessuna versione corrente da chiudere: basta un Insert.
      Result := TRicettaProdottoFinito.Create;
      Result.ProdottoFinitoID := AProdottoFinitoID;
      Result.Versione := LNuovaVersione;
      Result.CreatoDa := ACreatoDa;
      Result.Note := ANote;
      Result.Insert;
      Exit;
    end;
  finally
    LCorrente.Free;
  end;

  Result := GetCorrente(AProdottoFinitoID);
end;

end.
