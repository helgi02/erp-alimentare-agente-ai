unit uModelMateriaPrima;

interface

uses
  System.SysUtils,
  System.Generics.Collections,
  Data.DB, System.JSON, System.DateUtils,
  DbU, uModelAllergene;

type
  // Rappresenta l'anagrafica di una materia prima acquistata da fornitori
  // esterni (tabella anagrafiche_materie_prime). E' l'entita' referenziata
  // da ordini fornitore, DDT di entrata, lotti e righe ricetta.
  // Nota di naming: la classe si chiama TMateriaPrima e non
  // TAnagraficaMateriaPrima per coerenza con TFornitore/TAllergene/
  // TStabilimento; il nome della tabella resta comunque
  // "anagrafiche_materie_prime".
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

    // Campi di audit: sola lettura, gestiti dal database (default/trigger
    // trg_anagrafiche_materie_prime_aggiornato_il)
    property CreatoIl: TDateTime read FCreatoIl;
    property AggiornatoIl: TDateTime read FAggiornatoIl;

    // Operazioni CRUD
    class function GetByID(AID: Integer): TMateriaPrima;
    class function GetByCodice(const ACodice: string): TMateriaPrima;
    class function GetAll: TObjectList<TMateriaPrima>;
    class function Delete(AID: Integer): Boolean;

    function Insert: Integer;   // restituisce l'ID generato
    function Update: Boolean;
    function Save: Boolean;     // Insert o Update a seconda che FID sia valorizzato
    function ToJSONObject: TJSONObject;
    procedure FromJSONObject(AJSON: TJSONObject);

    // Allergeni dichiarati per questa materia prima (tabella ponte
    // anagrafiche_materie_prime_allergeni). Wrapper sottile sulla logica
    // condivisa in TAllergene: nessuna query duplicata qui.
    class function GetAllergeni(AMateriaPrimaID: Integer): TObjectList<TAllergene>;
    class procedure SetAllergeni(AMateriaPrimaID: Integer; const AAllergeneIDs: TArray<Integer>);

  end;

implementation

const
  SQL_SELECT_BASE =
    'SELECT id, codice, denominazione, creato_il, aggiornato_il ' +
    'FROM anagrafiche_materie_prime ';

{ TMateriaPrima }

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
  // codice ha un vincolo UNIQUE (anagrafiche_materie_prime_codice_key):
  // e' il codice interno con cui operatori e tool MCP identificano la
  // materia prima senza dover conoscere l'id numerico interno.
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

  // L'ordinamento per denominazione sfrutta l'indice
  // idx_anagrafiche_materie_prime_denominazione gia' presente sul DB.
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
  // Materia prima e' referenziata da ordini fornitore, DDT entrata, lotti
  // materie prime e righe ricetta: in assenza di ON DELETE CASCADE lato
  // DB, la query fallisce se esistono record collegati. Comportamento
  // voluto: una materia prima gia' movimentata non va cancellata.
  Result := TDB.GetInstance.executeQuery(
    'DELETE FROM anagrafiche_materie_prime WHERE id = :id', [AID]);
end;

function TMateriaPrima.Insert: Integer;
var
  LAutoQuery: TAutoQuery;
begin
  // creato_il e aggiornato_il NON compaiono tra i campi inseriti:
  // sono valorizzati dal DEFAULT del database (now()).
  // codice ha un vincolo UNIQUE: un eventuale duplicato solleva
  // un'eccezione da gestire a livello di controller.
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
  // aggiornato_il NON viene impostato esplicitamente: il trigger
  // trg_anagrafiche_materie_prime_aggiornato_il lo valorizza
  // automaticamente.
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
  // id, creato_il, aggiornato_il NON vengono letti dal payload in ingresso:
  // sono gestiti dal database, mai dal client
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
