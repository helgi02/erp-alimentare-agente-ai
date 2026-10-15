unit uModelAllergene;

interface

uses
  System.SysUtils,
  System.Generics.Collections,
  Data.DB, System.JSON, System.DateUtils,
  DbU;

type
  // Rappresenta un allergene di riferimento (Reg. UE 1169/2011, Allegato II).
  // Tabella anagrafica di riferimento normativo (es. GLUT, LAT, UOV),
  // popolata perlopiu' una tantum ma dotata comunque dei consueti campi
  // di audit gestiti dal database (default + trigger aggiorna_timestamp).
  TAllergene = class
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
    // trg_allergeni_aggiornato_il)
    property CreatoIl: TDateTime read FCreatoIl;
    property AggiornatoIl: TDateTime read FAggiornatoIl;

    // Operazioni CRUD
    class function GetByID(AID: Integer): TAllergene;
    class function GetByCodice(const ACodice: string): TAllergene;
    class function GetAll: TObjectList<TAllergene>;
    class function Delete(AID: Integer): Boolean;

    function Insert: Integer;   // restituisce l'ID generato
    function Update: Boolean;
    function Save: Boolean;     // Insert o Update a seconda che FID sia valorizzato
    function ToJSONObject: TJSONObject;
    procedure FromJSONObject(AJSON: TJSONObject);

    // Logica condivisa per le tabelle ponte many-to-many con le
    // anagrafiche (anagrafiche_materie_prime_allergeni,
    // anagrafiche_semilavorati_allergeni,
    // anagrafiche_prodotti_finiti_allergeni). Sono strutturalmente
    // identiche: due sole FK, PK composta, nessun campo proprio, nessun
    // audit. Anziche' triplicare la stessa logica su tre classi, ogni
    // anagrafica (TMateriaPrima, TSemilavorato, TProdottoFinito) espone
    // un wrapper sottile che delega qui, passando il nome della tabella
    // ponte e della colonna FK che la identifica.
    class function GetPerEntita(const ATabellaPonte, AColonnaFK: string;
      AEntitaID: Integer): TObjectList<TAllergene>;
    class procedure SetPerEntita(const ATabellaPonte, AColonnaFK: string;
      AEntitaID: Integer; const AAllergeneIDs: TArray<Integer>);

  end;

implementation

const
  SQL_SELECT_BASE =
    'SELECT id, codice, denominazione, creato_il, aggiornato_il ' +
    'FROM allergeni ';

{ TAllergene }

constructor TAllergene.Create;
begin
  inherited Create;
  FID := 0;
end;

procedure TAllergene.LoadFromDataSet(ADataSet: TDataSet);
begin
  FID            := ADataSet.FieldByName('id').AsInteger;
  FCodice        := ADataSet.FieldByName('codice').AsString;
  FDenominazione := ADataSet.FieldByName('denominazione').AsString;
  FCreatoIl      := ADataSet.FieldByName('creato_il').AsDateTime;
  FAggiornatoIl  := ADataSet.FieldByName('aggiornato_il').AsDateTime;
end;

class function TAllergene.GetByID(AID: Integer): TAllergene;
var
  LAutoQuery: TAutoQuery;
begin
  Result := nil;

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE id = :id', [AID]);
  try
    if not LAutoQuery.Query.IsEmpty then
    begin
      Result := TAllergene.Create;
      Result.LoadFromDataSet(LAutoQuery.Query);
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TAllergene.GetByCodice(const ACodice: string): TAllergene;
var
  LAutoQuery: TAutoQuery;
begin
  // Utile perche' i tool MCP che verificano la conformita' delle etichette
  // (scenario "adattamento ricette") ragionano piu' naturalmente per codice
  // allergene (es. GLUT) che per id numerico interno. codice ha un vincolo
  // UNIQUE (allergeni_codice_key), quindi la ricerca e' univoca.
  Result := nil;

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE codice = :codice', [ACodice]);
  try
    if not LAutoQuery.Query.IsEmpty then
    begin
      Result := TAllergene.Create;
      Result.LoadFromDataSet(LAutoQuery.Query);
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TAllergene.GetAll: TObjectList<TAllergene>;
var
  LAutoQuery: TAutoQuery;
  LAllergene: TAllergene;
begin
  Result := TObjectList<TAllergene>.Create(True); // possiede gli oggetti

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'ORDER BY denominazione');
  try
    while not LAutoQuery.Query.Eof do
    begin
      LAllergene := TAllergene.Create;
      LAllergene.LoadFromDataSet(LAutoQuery.Query);
      Result.Add(LAllergene);
      LAutoQuery.Query.Next;
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TAllergene.Delete(AID: Integer): Boolean;
begin
  // Nota: allergeni e' referenziato dalle tabelle ponte
  // *_allergeni (materie prime, semilavorati, prodotti finiti).
  // Se il DB ha vincoli FK senza ON DELETE CASCADE, questa query
  // sollevera' un'eccezione in presenza di associazioni esistenti:
  // comportamento voluto, per evitare cancellazioni accidentali di
  // un allergene ancora in uso.
  Result := TDB.GetInstance.executeQuery(
    'DELETE FROM allergeni WHERE id = :id', [AID]);
end;

function TAllergene.Insert: Integer;
var
  LAutoQuery: TAutoQuery;
begin
  // creato_il e aggiornato_il NON compaiono tra i campi inseriti:
  // sono valorizzati dal DEFAULT del database (now()).
  // codice ha un vincolo UNIQUE (allergeni_codice_key): un eventuale
  // duplicato solleva un'eccezione da gestire a livello di controller,
  // come gia' fatto per partita_iva in TFornitore.
  LAutoQuery := TDB.GetInstance.getQueryResult(
    'INSERT INTO allergeni (codice, denominazione) ' +
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

function TAllergene.Update: Boolean;
var
  LAutoQuery: TAutoQuery;
begin
  // aggiornato_il NON viene impostato esplicitamente: il trigger
  // trg_allergeni_aggiornato_il lo valorizza automaticamente.
  LAutoQuery := TDB.GetInstance.getQueryResult(
    'UPDATE allergeni SET codice = :codice, denominazione = :denominazione ' +
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

function TAllergene.Save: Boolean;
begin
  if FID = 0 then
  begin
    Insert;
    Result := FID > 0;
  end
  else
    Result := Update;
end;

function TAllergene.ToJSONObject: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('id', TJSONNumber.Create(FID));
  Result.AddPair('codice', FCodice);
  Result.AddPair('denominazione', FDenominazione);
  Result.AddPair('creato_il', DateToISO8601(FCreatoIl));
  Result.AddPair('aggiornato_il', DateToISO8601(FAggiornatoIl));
end;

procedure TAllergene.FromJSONObject(AJSON: TJSONObject);
begin
  // id, creato_il, aggiornato_il NON vengono letti dal payload in ingresso:
  // sono gestiti dal database, mai dal client
  if AJSON.TryGetValue<string>('codice', FCodice) then ;
  if AJSON.TryGetValue<string>('denominazione', FDenominazione) then ;
end;

class function TAllergene.GetPerEntita(const ATabellaPonte, AColonnaFK: string;
  AEntitaID: Integer): TObjectList<TAllergene>;
var
  LAutoQuery: TAutoQuery;
  LAllergene: TAllergene;
  LSql: string;
begin
  Result := TObjectList<TAllergene>.Create(True); // possiede gli oggetti

  // JOIN parametrica sul nome tabella/colonna: ATabellaPonte e AColonnaFK
  // sono valori letterali decisi dal codice chiamante (mai dall'utente
  // finale o dal modello via JSON), quindi non c'e' rischio di SQL
  // injection nel comporli con Format/concatenazione.
  LSql := Format(
    'SELECT a.id, a.codice, a.denominazione, a.creato_il, a.aggiornato_il ' +
    'FROM allergeni a ' +
    'JOIN %s p ON p.allergene_id = a.id ' +
    'WHERE p.%s = :id ' +
    'ORDER BY a.denominazione',
    [ATabellaPonte, AColonnaFK]);

  LAutoQuery := TDB.GetInstance.getQueryResult(LSql, [AEntitaID]);
  try
    while not LAutoQuery.Query.Eof do
    begin
      LAllergene := TAllergene.Create;
      LAllergene.LoadFromDataSet(LAutoQuery.Query);
      Result.Add(LAllergene);
      LAutoQuery.Query.Next;
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class procedure TAllergene.SetPerEntita(const ATabellaPonte, AColonnaFK: string;
  AEntitaID: Integer; const AAllergeneIDs: TArray<Integer>);
var
  LQueries: TArray<string>;
  LParamsList: TArray<TArray<Variant>>;
  i: Integer;
begin
  // Sostituzione atomica dell'insieme di allergeni: un DELETE di tutte le
  // associazioni esistenti seguito da un INSERT per ciascun allergene
  // richiesto, il tutto in un'unica transazione (TDB.ExecuteQueriesInTransaction).
  // Senza transazione, un errore a meta' sequenza (es. un allergene_id
  // inesistente) lascerebbe l'entita' con un sottoinsieme parziale e
  // silenzioso di allergeni dichiarati: inaccettabile per un dato di
  // etichettatura (Reg. UE 1169/2011). Con la transazione, o l'intero
  // nuovo insieme viene scritto, o non cambia nulla e l'eccezione risale
  // al chiamante (es. il tool MCP che ha invocato questa procedure).
  SetLength(LQueries, Length(AAllergeneIDs) + 1);
  SetLength(LParamsList, Length(AAllergeneIDs) + 1);

  LQueries[0] := Format('DELETE FROM %s WHERE %s = :id', [ATabellaPonte, AColonnaFK]);
  LParamsList[0] := [AEntitaID];

  for i := 0 to High(AAllergeneIDs) do
  begin
    LQueries[i + 1] := Format(
      'INSERT INTO %s (%s, allergene_id) VALUES (:id, :allergene_id)',
      [ATabellaPonte, AColonnaFK]);
    LParamsList[i + 1] := [AEntitaID, AAllergeneIDs[i]];
  end;

  TDB.GetInstance.ExecuteQueriesInTransaction(LQueries, LParamsList);
end;

end.
