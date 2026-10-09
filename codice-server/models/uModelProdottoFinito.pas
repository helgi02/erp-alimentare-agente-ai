unit uModelProdottoFinito;

interface

uses
  System.SysUtils,
  System.Variants,
  System.Generics.Collections,
  Data.DB, System.JSON, System.DateUtils,
  DbU, uModelAllergene;

type
  // Anagrafica di un prodotto finito (anagrafiche_prodotti_finiti). Come TMateriaPrima,
  // piu' GiorniScadenzaStandard: la shelf life con cui si calcola la data_scadenza dei
  // lotti (data_produzione + GiorniScadenzaStandard), che nel richiamo determina l'urgenza.
  TProdottoFinito = class
  private
    FID: Integer;
    FCodice: string;
    FDenominazione: string;
    FGiorniScadenzaStandard: Integer;
    FProdottoFinitoPadreID: Integer;  // 0 = NULL = prodotto "radice", non una variante

    // Peso o volume dell'unita' di vendita (es. "confezione da 250 g"), per il modulo
    // ministeriale di richiamo (richiamo.pdf). Aggiunto con un ALTER TABLE separato
    // (ddl_completo.sql). 0/'' = NULL: molti prodotti non lo hanno ancora censito.
    FPesoVolumeUnitaVendita: Double;   // 0 = NULL = non ancora censito
    FUnitaMisuraVendita: string;       // '' = NULL = non ancora censito

    FCreatoIl: TDateTime;
    FAggiornatoIl: TDateTime;

    procedure LoadFromDataSet(ADataSet: TDataSet);
  public
    constructor Create;

    property ID: Integer read FID write FID;
    property Codice: string read FCodice write FCodice;
    property Denominazione: string read FDenominazione write FDenominazione;
    property GiorniScadenzaStandard: Integer read FGiorniScadenzaStandard write FGiorniScadenzaStandard;

    // Se valorizzato, e' una variante dietetica (es. senza glutine/lattosio) generata dallo
    // scenario 3 dal prodotto con questo id, che resta invariato e in vendita. 0 = NULL =
    // prodotto "radice". Una variante punta sempre a una radice, mai a un'altra variante
    // (TServizioRicette.ApplicaAdattamentoRicetta), cosi' "le varianti di X" e' una query
    // piatta (WHERE prodotto_finito_padre_id = X).
    property ProdottoFinitoPadreID: Integer read FProdottoFinitoPadreID write FProdottoFinitoPadreID;

    // Peso o volume della singola unita' di vendita e relativa unita' (es. "g", "ml"). 0/''
    // = non censito: i documenti devono lasciare il campo vuoto, non inventare un valore.
    property PesoVolumeUnitaVendita: Double read FPesoVolumeUnitaVendita write FPesoVolumeUnitaVendita;
    property UnitaMisuraVendita: string read FUnitaMisuraVendita write FUnitaMisuraVendita;

    property CreatoIl: TDateTime read FCreatoIl;
    property AggiornatoIl: TDateTime read FAggiornatoIl;

    class function GetByID(AID: Integer): TProdottoFinito;
    class function GetByCodice(const ACodice: string): TProdottoFinito;
    class function GetAll: TObjectList<TProdottoFinito>;
    class function Delete(AID: Integer): Boolean;

    // Le varianti dietetiche di APadreID. TServizioRicette.ApplicaAdattamentoRicetta la usa
    // per verificare se esiste gia' una variante compatibile prima di crearne una
    // (deduplicazione).
    class function GetVarianti(APadreID: Integer): TObjectList<TProdottoFinito>;

    function Insert: Integer;   // restituisce l'ID generato
    function Update: Boolean;
    function Save: Boolean;     // Insert o Update a seconda che FID sia valorizzato
    function ToJSONObject: TJSONObject;
    procedure FromJSONObject(AJSON: TJSONObject);

    // Allergeni dichiarati (tabella ponte anagrafiche_prodotti_finiti_allergeni): finiscono
    // in etichetta (Reg. UE 1169/2011). Wrapper sottile su TAllergene.
    class function GetAllergeni(AProdottoFinitoID: Integer): TObjectList<TAllergene>;
    class procedure SetAllergeni(AProdottoFinitoID: Integer; const AAllergeneIDs: TArray<Integer>);

  end;

implementation

const
  SQL_SELECT_BASE =
    'SELECT id, codice, denominazione, giorni_scadenza_standard, ' +
    'prodotto_finito_padre_id, peso_volume_unita_vendita, ' +
    'unita_misura_vendita, creato_il, aggiornato_il ' +
    'FROM anagrafiche_prodotti_finiti ';

constructor TProdottoFinito.Create;
begin
  inherited Create;
  FID := 0;
end;

procedure TProdottoFinito.LoadFromDataSet(ADataSet: TDataSet);
begin
  FID                     := ADataSet.FieldByName('id').AsInteger;
  FCodice                 := ADataSet.FieldByName('codice').AsString;
  FDenominazione          := ADataSet.FieldByName('denominazione').AsString;
  FGiorniScadenzaStandard := ADataSet.FieldByName('giorni_scadenza_standard').AsInteger;

  if ADataSet.FieldByName('prodotto_finito_padre_id').IsNull then
    FProdottoFinitoPadreID := 0
  else
    FProdottoFinitoPadreID := ADataSet.FieldByName('prodotto_finito_padre_id').AsInteger;

  if ADataSet.FieldByName('peso_volume_unita_vendita').IsNull then
    FPesoVolumeUnitaVendita := 0
  else
    FPesoVolumeUnitaVendita := ADataSet.FieldByName('peso_volume_unita_vendita').AsFloat;

  if ADataSet.FieldByName('unita_misura_vendita').IsNull then
    FUnitaMisuraVendita := ''
  else
    FUnitaMisuraVendita := ADataSet.FieldByName('unita_misura_vendita').AsString;

  FCreatoIl               := ADataSet.FieldByName('creato_il').AsDateTime;
  FAggiornatoIl           := ADataSet.FieldByName('aggiornato_il').AsDateTime;
end;

class function TProdottoFinito.GetByID(AID: Integer): TProdottoFinito;
var
  LAutoQuery: TAutoQuery;
begin
  Result := nil;

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE id = :id', [AID]);
  try
    if not LAutoQuery.Query.IsEmpty then
    begin
      Result := TProdottoFinito.Create;
      Result.LoadFromDataSet(LAutoQuery.Query);
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TProdottoFinito.GetByCodice(const ACodice: string): TProdottoFinito;
var
  LAutoQuery: TAutoQuery;
begin
  // codice e' UNIQUE (anagrafiche_prodotti_finiti_codice_key).
  Result := nil;

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE codice = :codice', [ACodice]);
  try
    if not LAutoQuery.Query.IsEmpty then
    begin
      Result := TProdottoFinito.Create;
      Result.LoadFromDataSet(LAutoQuery.Query);
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TProdottoFinito.GetAll: TObjectList<TProdottoFinito>;
var
  LAutoQuery: TAutoQuery;
  LProdottoFinito: TProdottoFinito;
begin
  Result := TObjectList<TProdottoFinito>.Create(True); // possiede gli oggetti

  // L'ordine per denominazione usa l'indice idx_anagrafiche_prodotti_finiti_denominazione.
  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'ORDER BY denominazione');
  try
    while not LAutoQuery.Query.Eof do
    begin
      LProdottoFinito := TProdottoFinito.Create;
      LProdottoFinito.LoadFromDataSet(LAutoQuery.Query);
      Result.Add(LProdottoFinito);
      LAutoQuery.Query.Next;
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TProdottoFinito.GetVarianti(APadreID: Integer): TObjectList<TProdottoFinito>;
var
  LAutoQuery: TAutoQuery;
  LProdottoFinito: TProdottoFinito;
begin
  Result := TObjectList<TProdottoFinito>.Create(True); // possiede gli oggetti

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE prodotto_finito_padre_id = :prodotto_finito_padre_id ' +
    'ORDER BY id',
    [APadreID]);
  try
    while not LAutoQuery.Query.Eof do
    begin
      LProdottoFinito := TProdottoFinito.Create;
      LProdottoFinito.LoadFromDataSet(LAutoQuery.Query);
      Result.Add(LProdottoFinito);
      LAutoQuery.Query.Next;
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TProdottoFinito.Delete(AID: Integer): Boolean;
begin
  // Fallisce se il record e' referenziato (nessun ON DELETE CASCADE): voluto, per non
  // perdere dati di tracciabilita'.
  Result := TDB.GetInstance.executeQuery(
    'DELETE FROM anagrafiche_prodotti_finiti WHERE id = :id', [AID]);
end;

function TProdottoFinito.Insert: Integer;
var
  LAutoQuery: TAutoQuery;
  LPadreParam: Variant;
  LPesoVolumeParam: Variant;
  LUnitaMisuraVenditaParam: Variant;
begin
  // creato_il/aggiornato_il: DEFAULT del database.
  if FProdottoFinitoPadreID = 0 then
    LPadreParam := Null
  else
    LPadreParam := FProdottoFinitoPadreID;

  // Sentinella 0/'' = NULL come FProdottoFinitoPadreID. Cast espliciti ::numeric/::varchar
  // sui parametri Null: senza, FireDAC li lega come testo e Postgres rifiuta l'INSERT
  // (stesso problema degli id di lotto in uModelNonConformita).
  if FPesoVolumeUnitaVendita = 0 then
    LPesoVolumeParam := Null
  else
    LPesoVolumeParam := FPesoVolumeUnitaVendita;

  if FUnitaMisuraVendita = '' then
    LUnitaMisuraVenditaParam := Null
  else
    LUnitaMisuraVenditaParam := FUnitaMisuraVendita;

  LAutoQuery := TDB.GetInstance.getQueryResult(
    'INSERT INTO anagrafiche_prodotti_finiti ' +
    '(codice, denominazione, giorni_scadenza_standard, prodotto_finito_padre_id, ' +
    'peso_volume_unita_vendita, unita_misura_vendita) ' +
    'VALUES (:codice, :denominazione, :giorni_scadenza_standard, :prodotto_finito_padre_id, ' +
    ':peso_volume_unita_vendita::numeric, :unita_misura_vendita::varchar) ' +
    'RETURNING id, creato_il, aggiornato_il',
    [FCodice, FDenominazione, FGiorniScadenzaStandard, LPadreParam,
     LPesoVolumeParam, LUnitaMisuraVenditaParam]);
  try
    FID           := LAutoQuery.Query.FieldByName('id').AsInteger;
    FCreatoIl     := LAutoQuery.Query.FieldByName('creato_il').AsDateTime;
    FAggiornatoIl := LAutoQuery.Query.FieldByName('aggiornato_il').AsDateTime;
    Result := FID;
  finally
    LAutoQuery.Free;
  end;
end;

function TProdottoFinito.Update: Boolean;
var
  LAutoQuery: TAutoQuery;
  LPadreParam: Variant;
  LPesoVolumeParam: Variant;
  LUnitaMisuraVenditaParam: Variant;
begin
  // aggiornato_il lo imposta il trigger.
  if FProdottoFinitoPadreID = 0 then
    LPadreParam := Null
  else
    LPadreParam := FProdottoFinitoPadreID;

  // Stessi cast e stessa sentinella di Insert.
  if FPesoVolumeUnitaVendita = 0 then
    LPesoVolumeParam := Null
  else
    LPesoVolumeParam := FPesoVolumeUnitaVendita;

  if FUnitaMisuraVendita = '' then
    LUnitaMisuraVenditaParam := Null
  else
    LUnitaMisuraVenditaParam := FUnitaMisuraVendita;

  LAutoQuery := TDB.GetInstance.getQueryResult(
    'UPDATE anagrafiche_prodotti_finiti SET codice = :codice, ' +
    'denominazione = :denominazione, ' +
    'giorni_scadenza_standard = :giorni_scadenza_standard, ' +
    'prodotto_finito_padre_id = :prodotto_finito_padre_id, ' +
    'peso_volume_unita_vendita = :peso_volume_unita_vendita::numeric, ' +
    'unita_misura_vendita = :unita_misura_vendita::varchar ' +
    'WHERE id = :id ' +
    'RETURNING aggiornato_il',
    [FCodice, FDenominazione, FGiorniScadenzaStandard, LPadreParam,
     LPesoVolumeParam, LUnitaMisuraVenditaParam, FID]);
  try
    Result := not LAutoQuery.Query.IsEmpty;
    if Result then
      FAggiornatoIl := LAutoQuery.Query.FieldByName('aggiornato_il').AsDateTime;
  finally
    LAutoQuery.Free;
  end;
end;

function TProdottoFinito.Save: Boolean;
begin
  if FID = 0 then
  begin
    Insert;
    Result := FID > 0;
  end
  else
    Result := Update;
end;

function TProdottoFinito.ToJSONObject: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('id', TJSONNumber.Create(FID));
  Result.AddPair('codice', FCodice);
  Result.AddPair('denominazione', FDenominazione);
  Result.AddPair('giorni_scadenza_standard', TJSONNumber.Create(FGiorniScadenzaStandard));
  if FProdottoFinitoPadreID = 0 then
    Result.AddPair('prodotto_finito_padre_id', TJSONNull.Create)
  else
    Result.AddPair('prodotto_finito_padre_id', TJSONNumber.Create(FProdottoFinitoPadreID));
  if FPesoVolumeUnitaVendita = 0 then
    Result.AddPair('peso_volume_unita_vendita', TJSONNull.Create)
  else
    Result.AddPair('peso_volume_unita_vendita', TJSONNumber.Create(FPesoVolumeUnitaVendita));
  if FUnitaMisuraVendita = '' then
    Result.AddPair('unita_misura_vendita', TJSONNull.Create)
  else
    Result.AddPair('unita_misura_vendita', FUnitaMisuraVendita);
  Result.AddPair('creato_il', DateToISO8601(FCreatoIl));
  Result.AddPair('aggiornato_il', DateToISO8601(FAggiornatoIl));
end;

procedure TProdottoFinito.FromJSONObject(AJSON: TJSONObject);
var
  LGiorni: Integer;
  LPadreID: Integer;
  LPesoVolume: Double;
  LUnitaMisuraVendita: string;
begin
  // Id e audit non si leggono dal payload: li gestisce il database.
  if AJSON.TryGetValue<string>('codice', FCodice) then ;
  if AJSON.TryGetValue<string>('denominazione', FDenominazione) then ;
  if AJSON.TryGetValue<Integer>('giorni_scadenza_standard', LGiorni) then
    FGiorniScadenzaStandard := LGiorni;
  if AJSON.TryGetValue<Integer>('prodotto_finito_padre_id', LPadreID) then
    FProdottoFinitoPadreID := LPadreID;
  if AJSON.TryGetValue<Double>('peso_volume_unita_vendita', LPesoVolume) then
    FPesoVolumeUnitaVendita := LPesoVolume;
  if AJSON.TryGetValue<string>('unita_misura_vendita', LUnitaMisuraVendita) then
    FUnitaMisuraVendita := LUnitaMisuraVendita;
end;

class function TProdottoFinito.GetAllergeni(AProdottoFinitoID: Integer): TObjectList<TAllergene>;
begin
  Result := TAllergene.GetPerEntita(
    'anagrafiche_prodotti_finiti_allergeni', 'prodotto_finito_id', AProdottoFinitoID);
end;

class procedure TProdottoFinito.SetAllergeni(AProdottoFinitoID: Integer; const AAllergeneIDs: TArray<Integer>);
begin
  TAllergene.SetPerEntita(
    'anagrafiche_prodotti_finiti_allergeni', 'prodotto_finito_id', AProdottoFinitoID, AAllergeneIDs);
end;

end.
