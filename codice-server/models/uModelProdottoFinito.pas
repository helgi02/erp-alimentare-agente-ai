unit uModelProdottoFinito;

interface

uses
  System.SysUtils,
  System.Variants,
  System.Generics.Collections,
  Data.DB, System.JSON, System.DateUtils,
  DbU, uModelAllergene;

type
  // Rappresenta l'anagrafica di un prodotto finito destinato alla vendita
  // (tabella anagrafiche_prodotti_finiti). Stessa forma di TMateriaPrima/
  // TSemilavorato (codice univoco + denominazione + audit), con l'aggiunta
  // di GiorniScadenzaStandard: la shelf life standard in giorni, usata dal
  // gestionale per calcolare la data_scadenza dei singoli lotti prodotti
  // (LOTTI_PRODOTTI_FINITI.data_scadenza = data_produzione +
  // GiorniScadenzaStandard). E' un dato rilevante anche per lo scenario
  // di ritiro/richiamo, dove la scadenza del lotto determina l'urgenza
  // della procedura.
  TProdottoFinito = class
  private
    FID: Integer;
    FCodice: string;
    FDenominazione: string;
    FGiorniScadenzaStandard: Integer;
    FProdottoFinitoPadreID: Integer;  // 0 = NULL = prodotto "radice", non una variante

    // Dato anagrafico per il modulo ministeriale di ritiro/richiamo (vedi
    // richiamo.pdf), campo "Descrizione peso/volume unita' di vendita"
    // (es. "confezione da 250 g"). Aggiunto con ALTER TABLE separato,
    // vedi commento in ddl_completo.sql. Stessa sentinella 0/'' = NULL
    // gia' in uso per ProdottoFinitoPadreID/resa_quantita: molti prodotti
    // esistenti non avranno ancora questo dato censito.
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

    // Se valorizzato, questo prodotto e' una VARIANTE dietetica (es. senza
    // glutine/lattosio) generata dallo scenario 3 (adattamento ricette) a
    // partire dal prodotto finito con questo id, che resta invariato e in
    // vendita. 0 = NULL = prodotto "radice" (il caso normale, per tutti i
    // prodotti che non sono nati da un adattamento). Non e' una catena
    // arbitraria: per costruzione (vedi TServizioRicette.
    // ApplicaAdattamentoRicetta) una variante punta sempre a un prodotto
    // radice, mai a un'altra variante — cosi' "trova le varianti di X" resta
    // una query piatta (WHERE prodotto_finito_padre_id = X), senza dover
    // risalire ricorsivamente una catena.
    property ProdottoFinitoPadreID: Integer read FProdottoFinitoPadreID write FProdottoFinitoPadreID;

    // Peso o volume della singola unita' di vendita (es. 250 per una
    // confezione da 250 g) e relativa unita' di misura (es. "g", "ml").
    // 0 / '' = non ancora censito — il tool di generazione documenti
    // deve lasciare il campo vuoto nel documento in quel caso, non
    // inventare un valore.
    property PesoVolumeUnitaVendita: Double read FPesoVolumeUnitaVendita write FPesoVolumeUnitaVendita;
    property UnitaMisuraVendita: string read FUnitaMisuraVendita write FUnitaMisuraVendita;

    // Campi di audit: sola lettura, gestiti dal database (default/trigger
    // trg_anagrafiche_prodotti_finiti_aggiornato_il)
    property CreatoIl: TDateTime read FCreatoIl;
    property AggiornatoIl: TDateTime read FAggiornatoIl;

    // Operazioni CRUD
    class function GetByID(AID: Integer): TProdottoFinito;
    class function GetByCodice(const ACodice: string): TProdottoFinito;
    class function GetAll: TObjectList<TProdottoFinito>;
    class function Delete(AID: Integer): Boolean;

    // Tutte le varianti dietetiche gia' generate a partire dal prodotto
    // APadreID (vedi commento su ProdottoFinitoPadreID sopra). Usato da
    // TServizioRicette.ApplicaAdattamentoRicetta per verificare se esiste
    // gia' una variante compatibile PRIMA di crearne una nuova — non e' un
    // semplice elenco a video, e' il controllo di deduplicazione.
    class function GetVarianti(APadreID: Integer): TObjectList<TProdottoFinito>;

    function Insert: Integer;   // restituisce l'ID generato
    function Update: Boolean;
    function Save: Boolean;     // Insert o Update a seconda che FID sia valorizzato
    function ToJSONObject: TJSONObject;
    procedure FromJSONObject(AJSON: TJSONObject);

    // Allergeni dichiarati per questo prodotto finito (tabella ponte
    // anagrafiche_prodotti_finiti_allergeni) - il dato che finisce in
    // etichetta ai sensi del Reg. UE 1169/2011. Wrapper sottile sulla
    // logica condivisa in TAllergene: nessuna query duplicata qui.
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

{ TProdottoFinito }

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
  // codice ha un vincolo UNIQUE (anagrafiche_prodotti_finiti_codice_key).
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

  // L'ordinamento per denominazione sfrutta l'indice
  // idx_anagrafiche_prodotti_finiti_denominazione gia' presente sul DB.
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
  // Prodotto finito e' referenziato da ricette_prodotti_finiti,
  // lotti_prodotti_finiti e ordini_vendita_righe: in assenza di
  // ON DELETE CASCADE lato DB, la query fallisce se esistono record
  // collegati. Comportamento voluto.
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
  // creato_il e aggiornato_il NON compaiono tra i campi inseriti:
  // sono valorizzati dal DEFAULT del database (now()).
  if FProdottoFinitoPadreID = 0 then
    LPadreParam := Null
  else
    LPadreParam := FProdottoFinitoPadreID;

  // Stessa sentinella 0/'' = NULL di FProdottoFinitoPadreID (vedi sopra).
  // Cast espliciti ::numeric/::varchar sui parametri Null: senza, FireDAC
  // li lega come testo generico e Postgres rifiuta l'INSERT — stesso bug
  // gia' incontrato e corretto sugli id di lotto in uModelNonConformita.pas.
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
  // aggiornato_il NON viene impostato esplicitamente: il trigger
  // trg_anagrafiche_prodotti_finiti_aggiornato_il lo valorizza
  // automaticamente.
  if FProdottoFinitoPadreID = 0 then
    LPadreParam := Null
  else
    LPadreParam := FProdottoFinitoPadreID;

  // Stessi cast espliciti e stessa sentinella di Insert (vedi commento li').
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
  // id, creato_il, aggiornato_il NON vengono letti dal payload in ingresso:
  // sono gestiti dal database, mai dal client. prodotto_finito_padre_id
  // invece si': e' cosi' che TServizioRicette.ApplicaAdattamentoRicetta
  // marca una variante appena creata (vedi quel metodo) - qui basta saperlo
  // leggere se presente, 0 (assente) resta il default "prodotto radice".
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
