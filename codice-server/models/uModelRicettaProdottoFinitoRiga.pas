unit uModelRicettaProdottoFinitoRiga;

interface

uses
  System.SysUtils,
  System.Variants,
  System.Generics.Collections,
  Data.DB, System.JSON, System.DateUtils,
  FireDAC.Comp.Client,
  DbU;

type
  // Componente di una versione di ricetta di prodotto finito
  // (ricette_prodotti_finiti_righe). Il componente e' esattamente uno fra materia prima
  // (MateriaPrimaID) e semilavorato (SemilavoratoID) (chk_componente_prodotto_finito). Qui
  // il campo si chiama semilavorato_id, non semilavorato_figlio_id come in
  // ricette_semilavorati_righe: non c'e' ricorsione, il prodotto finito e' sempre la radice
  // della distinta.
  TRicettaProdottoFinitoRiga = class
  private
    FID: Integer;
    FRicettaID: Integer;
    FMateriaPrimaID: Integer;  // 0 = NULL
    FSemilavoratoID: Integer;  // 0 = NULL
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
    property SemilavoratoID: Integer read FSemilavoratoID write FSemilavoratoID;
    property QuantitaStandard: Currency read FQuantitaStandard write FQuantitaStandard;
    property UnitaMisuraDose: string read FUnitaMisuraDose write FUnitaMisuraDose;
    property IsComponenteMateriaPrima: Boolean read GetIsComponenteMateriaPrima;

    property CreatoIl: TDateTime read FCreatoIl;
    property AggiornatoIl: TDateTime read FAggiornatoIl;

    class function GetByID(AID: Integer): TRicettaProdottoFinitoRiga;
    class function GetByRicetta(ARicettaID: Integer): TObjectList<TRicettaProdottoFinitoRiga>;
    class function Delete(AID: Integer): Boolean;

    function Insert: Integer; overload;   // restituisce l'ID generato (connessione pooled propria)

    // Overload per TServizioRicette.ApplicaSostituzioneIngrediente: copiando le righe in
    // una nuova versione le insert vanno tutte o nessuna, perche' una ricetta con meta'
    // righe sarebbe un dato silenziosamente sbagliato. Vedi
    // TConsumoProduzioneSemilavorato.Insert(AConnection).
    function Insert(AConnection: TFDConnection): Integer; overload;

    function Update: Boolean;
    function Save: Boolean;     // Insert o Update a seconda che FID sia valorizzato
    function ToJSONObject: TJSONObject;
    procedure FromJSONObject(AJSON: TJSONObject);

  end;

implementation

const
  SQL_SELECT_BASE =
    'SELECT id, ricetta_id, materia_prima_id, semilavorato_id, ' +
    'quantita_standard, unita_misura_dose, creato_il, aggiornato_il ' +
    'FROM ricette_prodotti_finiti_righe ';

constructor TRicettaProdottoFinitoRiga.Create;
begin
  inherited Create;
  FID := 0;
  FMateriaPrimaID := 0;
  FSemilavoratoID := 0;
end;

function TRicettaProdottoFinitoRiga.GetIsComponenteMateriaPrima: Boolean;
begin
  Result := FMateriaPrimaID <> 0;
end;

procedure TRicettaProdottoFinitoRiga.EnsureComponenteValido;
begin
  // Replica il CHECK chk_componente_prodotto_finito: esattamente uno fra MateriaPrimaID e
  // SemilavoratoID.
  if (FMateriaPrimaID <> 0) = (FSemilavoratoID <> 0) then
    raise Exception.Create(
      'TRicettaProdottoFinitoRiga: la riga deve avere ESATTAMENTE uno tra ' +
      'MateriaPrimaID e SemilavoratoID valorizzato (mai entrambi, mai nessuno).');
end;

procedure TRicettaProdottoFinitoRiga.LoadFromDataSet(ADataSet: TDataSet);
begin
  FID        := ADataSet.FieldByName('id').AsInteger;
  FRicettaID := ADataSet.FieldByName('ricetta_id').AsInteger;

  if ADataSet.FieldByName('materia_prima_id').IsNull then
    FMateriaPrimaID := 0
  else
    FMateriaPrimaID := ADataSet.FieldByName('materia_prima_id').AsInteger;

  if ADataSet.FieldByName('semilavorato_id').IsNull then
    FSemilavoratoID := 0
  else
    FSemilavoratoID := ADataSet.FieldByName('semilavorato_id').AsInteger;

  FQuantitaStandard := ADataSet.FieldByName('quantita_standard').AsCurrency;
  FUnitaMisuraDose   := ADataSet.FieldByName('unita_misura_dose').AsString;
  FCreatoIl          := ADataSet.FieldByName('creato_il').AsDateTime;
  FAggiornatoIl      := ADataSet.FieldByName('aggiornato_il').AsDateTime;
end;

class function TRicettaProdottoFinitoRiga.GetByID(AID: Integer): TRicettaProdottoFinitoRiga;
var
  LAutoQuery: TAutoQuery;
begin
  Result := nil;

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE id = :id', [AID]);
  try
    if not LAutoQuery.Query.IsEmpty then
    begin
      Result := TRicettaProdottoFinitoRiga.Create;
      Result.LoadFromDataSet(LAutoQuery.Query);
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TRicettaProdottoFinitoRiga.GetByRicetta(ARicettaID: Integer): TObjectList<TRicettaProdottoFinitoRiga>;
var
  LAutoQuery: TAutoQuery;
  LRiga: TRicettaProdottoFinitoRiga;
begin
  Result := TObjectList<TRicettaProdottoFinitoRiga>.Create(True);

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE ricetta_id = :ricetta_id ORDER BY id',
    [ARicettaID]);
  try
    while not LAutoQuery.Query.Eof do
    begin
      LRiga := TRicettaProdottoFinitoRiga.Create;
      LRiga.LoadFromDataSet(LAutoQuery.Query);
      Result.Add(LRiga);
      LAutoQuery.Query.Next;
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TRicettaProdottoFinitoRiga.Delete(AID: Integer): Boolean;
begin
  // Nodo foglia: nessuna FK lo referenzia.
  Result := TDB.GetInstance.executeQuery(
    'DELETE FROM ricette_prodotti_finiti_righe WHERE id = :id', [AID]);
end;

function TRicettaProdottoFinitoRiga.Insert: Integer;
var
  LAutoQuery: TAutoQuery;
  LMateriaPrimaParam, LSemilavoratoParam: Variant;
begin
  EnsureComponenteValido;

  if FMateriaPrimaID = 0 then LMateriaPrimaParam := Null else LMateriaPrimaParam := FMateriaPrimaID;
  if FSemilavoratoID = 0 then LSemilavoratoParam := Null else LSemilavoratoParam := FSemilavoratoID;

  // creato_il/aggiornato_il: DEFAULT del database.
  LAutoQuery := TDB.GetInstance.getQueryResult(
    'INSERT INTO ricette_prodotti_finiti_righe ' +
    '(ricetta_id, materia_prima_id, semilavorato_id, quantita_standard, unita_misura_dose) ' +
    'VALUES (:ricetta_id, :materia_prima_id, :semilavorato_id, :quantita_standard, :unita_misura_dose) ' +
    'RETURNING id, creato_il, aggiornato_il',
    [FRicettaID, LMateriaPrimaParam, LSemilavoratoParam, FQuantitaStandard, FUnitaMisuraDose]);
  try
    FID           := LAutoQuery.Query.FieldByName('id').AsInteger;
    FCreatoIl     := LAutoQuery.Query.FieldByName('creato_il').AsDateTime;
    FAggiornatoIl := LAutoQuery.Query.FieldByName('aggiornato_il').AsDateTime;
    Result := FID;
  finally
    LAutoQuery.Free;
  end;
end;

function TRicettaProdottoFinitoRiga.Insert(AConnection: TFDConnection): Integer;
var
  LQuery: TFDQuery;
  LMateriaPrimaParam, LSemilavoratoParam: Variant;
begin
  EnsureComponenteValido;

  if FMateriaPrimaID = 0 then LMateriaPrimaParam := Null else LMateriaPrimaParam := FMateriaPrimaID;
  if FSemilavoratoID = 0 then LSemilavoratoParam := Null else LSemilavoratoParam := FSemilavoratoID;

  // Come l'overload senza parametri, ma su AConnection (transazione del chiamante).
  LQuery := TFDQuery.Create(nil);
  try
    LQuery.Connection := AConnection;
    LQuery.SQL.Text :=
      'INSERT INTO ricette_prodotti_finiti_righe ' +
      '(ricetta_id, materia_prima_id, semilavorato_id, quantita_standard, unita_misura_dose) ' +
      'VALUES (:ricetta_id, :materia_prima_id, :semilavorato_id, :quantita_standard, :unita_misura_dose) ' +
      'RETURNING id, creato_il, aggiornato_il';
    LQuery.ParamByName('ricetta_id').AsInteger := FRicettaID;

    // Uno fra materia_prima_id e semilavorato_id e' sempre Null, e un Variant Null puro non
    // porta il tipo: FireDAC manda un parametro sconosciuto e PostgreSQL rifiuta con "-335
    // ... data type is unknown". Questo overload crea la TFDQuery a mano perche' gira su
    // AConnection (transazione del chiamante) e non puo' riusare l'helper di
    // TDB.getQueryResult. Il parametro Null va dichiarato col tipo reale, ftInteger: con
    // ftWideString (prima versione, 01/10/2026) PostgreSQL rifiuta l'INSERT con "colonna di
    // tipo integer ma espressione character varying".
    if VarIsNull(LMateriaPrimaParam) then
    begin
      LQuery.ParamByName('materia_prima_id').DataType := ftInteger;
      LQuery.ParamByName('materia_prima_id').Clear;
    end
    else
      LQuery.ParamByName('materia_prima_id').AsInteger := LMateriaPrimaParam;

    if VarIsNull(LSemilavoratoParam) then
    begin
      LQuery.ParamByName('semilavorato_id').DataType := ftInteger;
      LQuery.ParamByName('semilavorato_id').Clear;
    end
    else
      LQuery.ParamByName('semilavorato_id').AsInteger := LSemilavoratoParam;

    LQuery.ParamByName('quantita_standard').Value := FQuantitaStandard;
    LQuery.ParamByName('unita_misura_dose').Value := FUnitaMisuraDose;
    LQuery.Open;

    FID           := LQuery.FieldByName('id').AsInteger;
    FCreatoIl     := LQuery.FieldByName('creato_il').AsDateTime;
    FAggiornatoIl := LQuery.FieldByName('aggiornato_il').AsDateTime;
    Result := FID;
  finally
    LQuery.Free;
  end;
end;

function TRicettaProdottoFinitoRiga.Update: Boolean;
var
  LAutoQuery: TAutoQuery;
  LMateriaPrimaParam, LSemilavoratoParam: Variant;
begin
  EnsureComponenteValido;

  if FMateriaPrimaID = 0 then LMateriaPrimaParam := Null else LMateriaPrimaParam := FMateriaPrimaID;
  if FSemilavoratoID = 0 then LSemilavoratoParam := Null else LSemilavoratoParam := FSemilavoratoID;

  // aggiornato_il lo imposta il trigger.
  LAutoQuery := TDB.GetInstance.getQueryResult(
    'UPDATE ricette_prodotti_finiti_righe SET ricetta_id = :ricetta_id, ' +
    'materia_prima_id = :materia_prima_id, semilavorato_id = :semilavorato_id, ' +
    'quantita_standard = :quantita_standard, unita_misura_dose = :unita_misura_dose ' +
    'WHERE id = :id ' +
    'RETURNING aggiornato_il',
    [FRicettaID, LMateriaPrimaParam, LSemilavoratoParam, FQuantitaStandard, FUnitaMisuraDose, FID]);
  try
    Result := not LAutoQuery.Query.IsEmpty;
    if Result then
      FAggiornatoIl := LAutoQuery.Query.FieldByName('aggiornato_il').AsDateTime;
  finally
    LAutoQuery.Free;
  end;
end;

function TRicettaProdottoFinitoRiga.Save: Boolean;
begin
  if FID = 0 then
  begin
    Insert;
    Result := FID > 0;
  end
  else
    Result := Update;
end;

function TRicettaProdottoFinitoRiga.ToJSONObject: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('id', TJSONNumber.Create(FID));
  Result.AddPair('ricetta_id', TJSONNumber.Create(FRicettaID));
  if FMateriaPrimaID = 0 then
    Result.AddPair('materia_prima_id', TJSONNull.Create)
  else
    Result.AddPair('materia_prima_id', TJSONNumber.Create(FMateriaPrimaID));
  if FSemilavoratoID = 0 then
    Result.AddPair('semilavorato_id', TJSONNull.Create)
  else
    Result.AddPair('semilavorato_id', TJSONNumber.Create(FSemilavoratoID));
  Result.AddPair('quantita_standard', TJSONNumber.Create(FQuantitaStandard));
  Result.AddPair('unita_misura_dose', FUnitaMisuraDose);
  Result.AddPair('creato_il', DateToISO8601(FCreatoIl));
  Result.AddPair('aggiornato_il', DateToISO8601(FAggiornatoIl));
end;

procedure TRicettaProdottoFinitoRiga.FromJSONObject(AJSON: TJSONObject);
var
  LValInt: Integer;
  LValStr: string;
  LValNum: TJSONValue;
begin
  // Id e audit non si leggono dal payload: li gestisce il database.
  if AJSON.TryGetValue<Integer>('ricetta_id', LValInt) then
    FRicettaID := LValInt;
  if AJSON.TryGetValue<Integer>('materia_prima_id', LValInt) then
    FMateriaPrimaID := LValInt;
  if AJSON.TryGetValue<Integer>('semilavorato_id', LValInt) then
    FSemilavoratoID := LValInt;
  if AJSON.TryGetValue<string>('unita_misura_dose', LValStr) then
    FUnitaMisuraDose := LValStr;

  // Decimali letti come TJSONNumber, per non perdere precisione.
  if AJSON.TryGetValue<TJSONValue>('quantita_standard', LValNum) and (LValNum is TJSONNumber) then
    FQuantitaStandard := TJSONNumber(LValNum).AsDouble;
end;

end.
