unit uModelMateriaPrima;

interface

uses
  System.SysUtils,
  System.Generics.Collections,
  Data.DB, System.JSON, System.DateUtils,
  DbU, uModelAllergene;

type
  // Anagrafica di una materia prima acquistata (anagrafiche_materie_prime), referenziata da
  // ordini fornitore, DDT di entrata, lotti e righe ricetta. La classe si chiama
  // TMateriaPrima per coerenza con TFornitore/TAllergene/TStabilimento.
  TMateriaPrima = class
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

    class function GetByID(AID: Integer): TMateriaPrima;
    class function GetByCodice(const ACodice: string): TMateriaPrima;
    class function GetAll: TObjectList<TMateriaPrima>;
    class function Delete(AID: Integer): Boolean;

    function Insert: Integer;   // restituisce l'ID generato
    function Update: Boolean;
    function Save: Boolean;     // Insert o Update a seconda che FID sia valorizzato
    function ToJSONObject: TJSONObject;
    procedure FromJSONObject(AJSON: TJSONObject);

    // Allergeni dichiarati (tabella ponte anagrafiche_materie_prime_allergeni): wrapper
    // sottile sulla logica condivisa in TAllergene.
    class function GetAllergeni(AMateriaPrimaID: Integer): TObjectList<TAllergene>;
    class procedure SetAllergeni(AMateriaPrimaID: Integer; const AAllergeneIDs: TArray<Integer>);

  end;

implementation

const
  SQL_SELECT_BASE =
    'SELECT id, codice, denominazione, creato_il, aggiornato_il ' +
    'FROM anagrafiche_materie_prime ';

constructor TMateriaPrima.Create;
begin
  inherited Create;
  FID := 0;
end;

procedure TMateriaPrima.LoadFromDataSet(ADataSet: TDataSet);
begin
  FID            := ADataSet.FieldByName('id').AsInteger;
  FCodice        := ADataSet.FieldByName('codice').AsString;
  FDenominazione := ADataSet.FieldByName('denominazione').AsString;
  FCreatoIl      := ADataSet.FieldByName('creato_il').AsDateTime;
  FAggiornatoIl  := ADataSet.FieldByName('aggiornato_il').AsDateTime;
end;

class function TMateriaPrima.GetByID(AID: Integer): TMateriaPrima;
var
  LAutoQuery: TAutoQuery;
begin
  Result := nil;

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE id = :id', [AID]);
  try
    if not LAutoQuery.Query.IsEmpty then
    begin
      Result := TMateriaPrima.Create;
      Result.LoadFromDataSet(LAutoQuery.Query);
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TMateriaPrima.GetByCodice(const ACodice: string): TMateriaPrima;
var
  LAutoQuery: TAutoQuery;
begin
  // codice e' UNIQUE (anagrafiche_materie_prime_codice_key): e' il codice interno con cui
  // operatori e tool MCP la identificano.
  Result := nil;

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE codice = :codice', [ACodice]);
  try
    if not LAutoQuery.Query.IsEmpty then
    begin
      Result := TMateriaPrima.Create;
      Result.LoadFromDataSet(LAutoQuery.Query);
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TMateriaPrima.GetAll: TObjectList<TMateriaPrima>;
var
  LAutoQuery: TAutoQuery;
  LMateriaPrima: TMateriaPrima;
begin
  Result := TObjectList<TMateriaPrima>.Create(True); // possiede gli oggetti

  // L'ordine per denominazione usa l'indice idx_anagrafiche_materie_prime_denominazione.
  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'ORDER BY denominazione');
  try
    while not LAutoQuery.Query.Eof do
    begin
      LMateriaPrima := TMateriaPrima.Create;
      LMateriaPrima.LoadFromDataSet(LAutoQuery.Query);
      Result.Add(LMateriaPrima);
      LAutoQuery.Query.Next;
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TMateriaPrima.Delete(AID: Integer): Boolean;
begin
  // Fallisce se il record e' referenziato (nessun ON DELETE CASCADE): voluto, per non
  // perdere dati di tracciabilita'.
  Result := TDB.GetInstance.executeQuery(
    'DELETE FROM anagrafiche_materie_prime WHERE id = :id', [AID]);
end;

function TMateriaPrima.Insert: Integer;
var
  LAutoQuery: TAutoQuery;
begin
  // creato_il/aggiornato_il: DEFAULT del database. Un duplicato sul vincolo UNIQUE solleva
  // un'eccezione da gestire nel controller.
  LAutoQuery := TDB.GetInstance.getQueryResult(
    'INSERT INTO anagrafiche_materie_prime (codice, denominazione) ' +
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

function TMateriaPrima.Update: Boolean;
var
  LAutoQuery: TAutoQuery;
begin
  // aggiornato_il lo imposta il trigger.
  LAutoQuery := TDB.GetInstance.getQueryResult(
    'UPDATE anagrafiche_materie_prime SET codice = :codice, ' +
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

function TMateriaPrima.Save: Boolean;
begin
  if FID = 0 then
  begin
    Insert;
    Result := FID > 0;
  end
  else
    Result := Update;
end;

function TMateriaPrima.ToJSONObject: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('id', TJSONNumber.Create(FID));
  Result.AddPair('codice', FCodice);
  Result.AddPair('denominazione', FDenominazione);
  Result.AddPair('creato_il', DateToISO8601(FCreatoIl));
  Result.AddPair('aggiornato_il', DateToISO8601(FAggiornatoIl));
end;

procedure TMateriaPrima.FromJSONObject(AJSON: TJSONObject);
begin
  // Id e audit non si leggono dal payload: li gestisce il database.
  if AJSON.TryGetValue<string>('codice', FCodice) then ;
  if AJSON.TryGetValue<string>('denominazione', FDenominazione) then ;
end;

class function TMateriaPrima.GetAllergeni(AMateriaPrimaID: Integer): TObjectList<TAllergene>;
begin
  Result := TAllergene.GetPerEntita(
    'anagrafiche_materie_prime_allergeni', 'materia_prima_id', AMateriaPrimaID);
end;

class procedure TMateriaPrima.SetAllergeni(AMateriaPrimaID: Integer; const AAllergeneIDs: TArray<Integer>);
begin
  TAllergene.SetPerEntita(
    'anagrafiche_materie_prime_allergeni', 'materia_prima_id', AMateriaPrimaID, AAllergeneIDs);
end;

end.
