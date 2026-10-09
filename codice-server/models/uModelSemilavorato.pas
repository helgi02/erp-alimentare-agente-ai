unit uModelSemilavorato;

interface

uses
  System.SysUtils,
  System.Generics.Collections,
  Data.DB, System.JSON, System.DateUtils,
  DbU, uModelAllergene;

type
  // Anagrafica di un semilavorato prodotto internamente (anagrafiche_semilavorati). Stessa
  // forma di TMateriaPrima, ma entita' distinta, referenziata dalle ricette (come
  // componente di semilavorati e prodotti finiti) e da lotti_semilavorati.
  TSemilavorato = class
  private
    FID: Integer;
    FCodice: string;
    FDenominazione: string;
    FCreatoIl: TDateTime;
    FAggiornatoIl: TDateTime;

    procedure LoadFromDataSet(ADataSet: TDataSet);
  public
    constructor Create;

    property ID: Integer read FID write FID;
    property Codice: string read FCodice write FCodice;
    property Denominazione: string read FDenominazione write FDenominazione;

    property CreatoIl: TDateTime read FCreatoIl;
    property AggiornatoIl: TDateTime read FAggiornatoIl;

    class function GetByID(AID: Integer): TSemilavorato;
    class function GetByCodice(const ACodice: string): TSemilavorato;
    class function GetAll: TObjectList<TSemilavorato>;
    class function Delete(AID: Integer): Boolean;

    function Insert: Integer;   // restituisce l'ID generato
    function Update: Boolean;
    function Save: Boolean;     // Insert o Update a seconda che FID sia valorizzato
    function ToJSONObject: TJSONObject;
    procedure FromJSONObject(AJSON: TJSONObject);

    // Allergeni dichiarati (tabella ponte anagrafiche_semilavorati_allergeni): wrapper
    // sottile su TAllergene.
    class function GetAllergeni(ASemilavoratoID: Integer): TObjectList<TAllergene>;
    class procedure SetAllergeni(ASemilavoratoID: Integer; const AAllergeneIDs: TArray<Integer>);

  end;

implementation

const
  SQL_SELECT_BASE =
    'SELECT id, codice, denominazione, creato_il, aggiornato_il ' +
    'FROM anagrafiche_semilavorati ';

constructor TSemilavorato.Create;
begin
  inherited Create;
  FID := 0;
end;

procedure TSemilavorato.LoadFromDataSet(ADataSet: TDataSet);
begin
  FID            := ADataSet.FieldByName('id').AsInteger;
  FCodice        := ADataSet.FieldByName('codice').AsString;
  FDenominazione := ADataSet.FieldByName('denominazione').AsString;
  FCreatoIl      := ADataSet.FieldByName('creato_il').AsDateTime;
  FAggiornatoIl  := ADataSet.FieldByName('aggiornato_il').AsDateTime;
end;

class function TSemilavorato.GetByID(AID: Integer): TSemilavorato;
var
  LAutoQuery: TAutoQuery;
begin
  Result := nil;

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE id = :id', [AID]);
  try
    if not LAutoQuery.Query.IsEmpty then
    begin
      Result := TSemilavorato.Create;
      Result.LoadFromDataSet(LAutoQuery.Query);
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TSemilavorato.GetByCodice(const ACodice: string): TSemilavorato;
var
  LAutoQuery: TAutoQuery;
begin
  // codice e' UNIQUE (anagrafiche_semilavorati_codice_key).
  Result := nil;

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE codice = :codice', [ACodice]);
  try
    if not LAutoQuery.Query.IsEmpty then
    begin
      Result := TSemilavorato.Create;
      Result.LoadFromDataSet(LAutoQuery.Query);
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TSemilavorato.GetAll: TObjectList<TSemilavorato>;
var
  LAutoQuery: TAutoQuery;
  LSemilavorato: TSemilavorato;
begin
  Result := TObjectList<TSemilavorato>.Create(True); // possiede gli oggetti

  // L'ordine per denominazione usa l'indice idx_anagrafiche_semilavorati_denominazione.
  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'ORDER BY denominazione');
  try
    while not LAutoQuery.Query.Eof do
    begin
      LSemilavorato := TSemilavorato.Create;
      LSemilavorato.LoadFromDataSet(LAutoQuery.Query);
      Result.Add(LSemilavorato);
      LAutoQuery.Query.Next;
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TSemilavorato.Delete(AID: Integer): Boolean;
begin
  // Fallisce se il record e' referenziato (nessun ON DELETE CASCADE): voluto, per non
  // perdere dati di tracciabilita'.
  Result := TDB.GetInstance.executeQuery(
    'DELETE FROM anagrafiche_semilavorati WHERE id = :id', [AID]);
end;

function TSemilavorato.Insert: Integer;
var
  LAutoQuery: TAutoQuery;
begin
  // creato_il/aggiornato_il: DEFAULT del database.
  LAutoQuery := TDB.GetInstance.getQueryResult(
    'INSERT INTO anagrafiche_semilavorati (codice, denominazione) ' +
    'VALUES (:codice, :denominazione) ' +
    'RETURNING id, creato_il, aggiornato_il',
    [FCodice, FDenominazione]);
  try
    FID           := LAutoQuery.Query.FieldByName('id').AsInteger;
    FCreatoIl     := LAutoQuery.Query.FieldByName('creato_il').AsDateTime;
    FAggiornatoIl := LAutoQuery.Query.FieldByName('aggiornato_il').AsDateTime;
    Result := FID;
  finally
    LAutoQuery.Free;
  end;
end;

function TSemilavorato.Update: Boolean;
var
  LAutoQuery: TAutoQuery;
begin
  // aggiornato_il lo imposta il trigger.
  LAutoQuery := TDB.GetInstance.getQueryResult(
    'UPDATE anagrafiche_semilavorati SET codice = :codice, ' +
    'denominazione = :denominazione ' +
    'WHERE id = :id ' +
    'RETURNING aggiornato_il',
    [FCodice, FDenominazione, FID]);
  try
    Result := not LAutoQuery.Query.IsEmpty;
    if Result then
      FAggiornatoIl := LAutoQuery.Query.FieldByName('aggiornato_il').AsDateTime;
  finally
    LAutoQuery.Free;
  end;
end;

function TSemilavorato.Save: Boolean;
begin
  if FID = 0 then
  begin
    Insert;
    Result := FID > 0;
  end
  else
    Result := Update;
end;

function TSemilavorato.ToJSONObject: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('id', TJSONNumber.Create(FID));
  Result.AddPair('codice', FCodice);
  Result.AddPair('denominazione', FDenominazione);
  Result.AddPair('creato_il', DateToISO8601(FCreatoIl));
  Result.AddPair('aggiornato_il', DateToISO8601(FAggiornatoIl));
end;

procedure TSemilavorato.FromJSONObject(AJSON: TJSONObject);
begin
  // Id e audit non si leggono dal payload: li gestisce il database.
  if AJSON.TryGetValue<string>('codice', FCodice) then ;
  if AJSON.TryGetValue<string>('denominazione', FDenominazione) then ;
end;

class function TSemilavorato.GetAllergeni(ASemilavoratoID: Integer): TObjectList<TAllergene>;
begin
  Result := TAllergene.GetPerEntita(
    'anagrafiche_semilavorati_allergeni', 'semilavorato_id', ASemilavoratoID);
end;

class procedure TSemilavorato.SetAllergeni(ASemilavoratoID: Integer; const AAllergeneIDs: TArray<Integer>);
begin
  TAllergene.SetPerEntita(
    'anagrafiche_semilavorati_allergeni', 'semilavorato_id', ASemilavoratoID, AAllergeneIDs);
end;

end.
