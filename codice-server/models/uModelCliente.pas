unit uModelCliente;

interface

uses
  System.SysUtils,
  System.Generics.Collections,
  Data.DB, System.JSON, System.DateUtils,
  DbU;

type
  // Cliente B2B (tabella clienti). Speculare a TFornitore ma con due indirizzi,
  // fatturazione e consegna (la sede legale puo' non coincidere con il punto di
  // spedizione), quindi i campi indirizzo hanno suffisso _fatturazione / _consegna.
  TCliente = class
  private
    FID: Integer;
    FRagioneSociale: string;
    FPartitaIva: string;
    FEmail: string;
    FTelefono: string;
    FViaFatturazione: string;
    FCittaFatturazione: string;
    FProvinciaFatturazione: string;
    FCapFatturazione: string;
    FPaeseFatturazione: string;
    FViaConsegna: string;
    FCittaConsegna: string;
    FProvinciaConsegna: string;
    FCapConsegna: string;
    FPaeseConsegna: string;
    FCreatoIl: TDateTime;
    FAggiornatoIl: TDateTime;

    procedure LoadFromDataSet(ADataSet: TDataSet);
  public
    constructor Create;

    property ID: Integer read FID write FID;
    property RagioneSociale: string read FRagioneSociale write FRagioneSociale;
    property PartitaIva: string read FPartitaIva write FPartitaIva;
    property Email: string read FEmail write FEmail;
    property Telefono: string read FTelefono write FTelefono;

    // Sede legale.
    property ViaFatturazione: string read FViaFatturazione write FViaFatturazione;
    property CittaFatturazione: string read FCittaFatturazione write FCittaFatturazione;
    property ProvinciaFatturazione: string read FProvinciaFatturazione write FProvinciaFatturazione;
    property CapFatturazione: string read FCapFatturazione write FCapFatturazione;
    property PaeseFatturazione: string read FPaeseFatturazione write FPaeseFatturazione;

    // Destinazione fisica della merce.
    property ViaConsegna: string read FViaConsegna write FViaConsegna;
    property CittaConsegna: string read FCittaConsegna write FCittaConsegna;
    property ProvinciaConsegna: string read FProvinciaConsegna write FProvinciaConsegna;
    property CapConsegna: string read FCapConsegna write FCapConsegna;
    property PaeseConsegna: string read FPaeseConsegna write FPaeseConsegna;

    property CreatoIl: TDateTime read FCreatoIl;
    property AggiornatoIl: TDateTime read FAggiornatoIl;

    class function GetByID(AID: Integer): TCliente;
    class function GetByPartitaIva(const APartitaIva: string): TCliente;
    class function GetAll: TObjectList<TCliente>;
    class function Delete(AID: Integer): Boolean;

    function Insert: Integer;   // restituisce l'ID generato
    function Update: Boolean;
    function Save: Boolean;     // Insert o Update a seconda che FID sia valorizzato
    function ToJSONObject: TJSONObject;
    procedure FromJSONObject(AJSON: TJSONObject);

  end;

implementation

const
  SQL_SELECT_BASE =
    'SELECT id, ragione_sociale, partita_iva, email, telefono, ' +
    'via_fatturazione, citta_fatturazione, provincia_fatturazione, ' +
    'cap_fatturazione, paese_fatturazione, ' +
    'via_consegna, citta_consegna, provincia_consegna, ' +
    'cap_consegna, paese_consegna, ' +
    'creato_il, aggiornato_il ' +
    'FROM clienti ';

constructor TCliente.Create;
begin
  inherited Create;
  FID := 0;
  // Replicano i DEFAULT del database per i nuovi record.
  FPaeseFatturazione := 'Italia';
  FPaeseConsegna      := 'Italia';
end;

procedure TCliente.LoadFromDataSet(ADataSet: TDataSet);
begin
  FID                     := ADataSet.FieldByName('id').AsInteger;
  FRagioneSociale         := ADataSet.FieldByName('ragione_sociale').AsString;
  FPartitaIva             := ADataSet.FieldByName('partita_iva').AsString;
  FEmail                  := ADataSet.FieldByName('email').AsString;
  FTelefono               := ADataSet.FieldByName('telefono').AsString;
  FViaFatturazione        := ADataSet.FieldByName('via_fatturazione').AsString;
  FCittaFatturazione      := ADataSet.FieldByName('citta_fatturazione').AsString;
  FProvinciaFatturazione  := ADataSet.FieldByName('provincia_fatturazione').AsString;
  FCapFatturazione        := ADataSet.FieldByName('cap_fatturazione').AsString;
  FPaeseFatturazione      := ADataSet.FieldByName('paese_fatturazione').AsString;
  FViaConsegna            := ADataSet.FieldByName('via_consegna').AsString;
  FCittaConsegna          := ADataSet.FieldByName('citta_consegna').AsString;
  FProvinciaConsegna      := ADataSet.FieldByName('provincia_consegna').AsString;
  FCapConsegna            := ADataSet.FieldByName('cap_consegna').AsString;
  FPaeseConsegna          := ADataSet.FieldByName('paese_consegna').AsString;
  FCreatoIl               := ADataSet.FieldByName('creato_il').AsDateTime;
  FAggiornatoIl           := ADataSet.FieldByName('aggiornato_il').AsDateTime;
end;

class function TCliente.GetByID(AID: Integer): TCliente;
var
  LAutoQuery: TAutoQuery;
begin
  Result := nil;

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE id = :id', [AID]);
  try
    if not LAutoQuery.Query.IsEmpty then
    begin
      Result := TCliente.Create;
      Result.LoadFromDataSet(LAutoQuery.Query);
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TCliente.GetByPartitaIva(const APartitaIva: string): TCliente;
var
  LAutoQuery: TAutoQuery;
begin
  // partita_iva e' UNIQUE (clienti_partita_iva_key), come in TFornitore.
  Result := nil;

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'WHERE partita_iva = :partita_iva', [APartitaIva]);
  try
    if not LAutoQuery.Query.IsEmpty then
    begin
      Result := TCliente.Create;
      Result.LoadFromDataSet(LAutoQuery.Query);
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TCliente.GetAll: TObjectList<TCliente>;
var
  LAutoQuery: TAutoQuery;
  LCliente: TCliente;
begin
  Result := TObjectList<TCliente>.Create(True); // possiede gli oggetti

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_SELECT_BASE + 'ORDER BY ragione_sociale');
  try
    while not LAutoQuery.Query.Eof do
    begin
      LCliente := TCliente.Create;
      LCliente.LoadFromDataSet(LAutoQuery.Query);
      Result.Add(LCliente);
      LAutoQuery.Query.Next;
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TCliente.Delete(AID: Integer): Boolean;
begin
  // Fallisce se il record e' referenziato (nessun ON DELETE CASCADE): voluto, per non
  // perdere dati di tracciabilita'.
  Result := TDB.GetInstance.executeQuery(
    'DELETE FROM clienti WHERE id = :id', [AID]);
end;

function TCliente.Insert: Integer;
var
  LAutoQuery: TAutoQuery;
begin
  // creato_il/aggiornato_il: DEFAULT del database. Un duplicato sul vincolo UNIQUE solleva
  // un'eccezione da gestire nel controller.
  LAutoQuery := TDB.GetInstance.getQueryResult(
    'INSERT INTO clienti ' +
    '(ragione_sociale, partita_iva, email, telefono, ' +
    'via_fatturazione, citta_fatturazione, provincia_fatturazione, ' +
    'cap_fatturazione, paese_fatturazione, ' +
    'via_consegna, citta_consegna, provincia_consegna, ' +
    'cap_consegna, paese_consegna) ' +
    'VALUES (:ragione_sociale, :partita_iva, :email, :telefono, ' +
    ':via_fatturazione, :citta_fatturazione, :provincia_fatturazione, ' +
    ':cap_fatturazione, :paese_fatturazione, ' +
    ':via_consegna, :citta_consegna, :provincia_consegna, ' +
    ':cap_consegna, :paese_consegna) ' +
    'RETURNING id, creato_il, aggiornato_il',
    [FRagioneSociale, FPartitaIva, FEmail, FTelefono,
     FViaFatturazione, FCittaFatturazione, FProvinciaFatturazione,
     FCapFatturazione, FPaeseFatturazione,
     FViaConsegna, FCittaConsegna, FProvinciaConsegna,
     FCapConsegna, FPaeseConsegna]);
  try
    FID           := LAutoQuery.Query.FieldByName('id').AsInteger;
    FCreatoIl     := LAutoQuery.Query.FieldByName('creato_il').AsDateTime;
    FAggiornatoIl := LAutoQuery.Query.FieldByName('aggiornato_il').AsDateTime;
    Result := FID;
  finally
    LAutoQuery.Free;
  end;
end;

function TCliente.Update: Boolean;
var
  LAutoQuery: TAutoQuery;
begin
  // aggiornato_il lo imposta il trigger.
  LAutoQuery := TDB.GetInstance.getQueryResult(
    'UPDATE clienti SET ragione_sociale = :ragione_sociale, ' +
    'partita_iva = :partita_iva, email = :email, telefono = :telefono, ' +
    'via_fatturazione = :via_fatturazione, ' +
    'citta_fatturazione = :citta_fatturazione, ' +
    'provincia_fatturazione = :provincia_fatturazione, ' +
    'cap_fatturazione = :cap_fatturazione, ' +
    'paese_fatturazione = :paese_fatturazione, ' +
    'via_consegna = :via_consegna, ' +
    'citta_consegna = :citta_consegna, ' +
    'provincia_consegna = :provincia_consegna, ' +
    'cap_consegna = :cap_consegna, ' +
    'paese_consegna = :paese_consegna ' +
    'WHERE id = :id ' +
    'RETURNING aggiornato_il',
    [FRagioneSociale, FPartitaIva, FEmail, FTelefono,
     FViaFatturazione, FCittaFatturazione, FProvinciaFatturazione,
     FCapFatturazione, FPaeseFatturazione,
     FViaConsegna, FCittaConsegna, FProvinciaConsegna,
     FCapConsegna, FPaeseConsegna, FID]);
  try
    Result := not LAutoQuery.Query.IsEmpty;
    if Result then
      FAggiornatoIl := LAutoQuery.Query.FieldByName('aggiornato_il').AsDateTime;
  finally
    LAutoQuery.Free;
  end;
end;

function TCliente.Save: Boolean;
begin
  if FID = 0 then
  begin
    Insert;
    Result := FID > 0;
  end
  else
    Result := Update;
end;

function TCliente.ToJSONObject: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('id', TJSONNumber.Create(FID));
  Result.AddPair('ragione_sociale', FRagioneSociale);
  Result.AddPair('partita_iva', FPartitaIva);
  Result.AddPair('email', FEmail);
  Result.AddPair('telefono', FTelefono);
  Result.AddPair('via_fatturazione', FViaFatturazione);
  Result.AddPair('citta_fatturazione', FCittaFatturazione);
  Result.AddPair('provincia_fatturazione', FProvinciaFatturazione);
  Result.AddPair('cap_fatturazione', FCapFatturazione);
  Result.AddPair('paese_fatturazione', FPaeseFatturazione);
  Result.AddPair('via_consegna', FViaConsegna);
  Result.AddPair('citta_consegna', FCittaConsegna);
  Result.AddPair('provincia_consegna', FProvinciaConsegna);
  Result.AddPair('cap_consegna', FCapConsegna);
  Result.AddPair('paese_consegna', FPaeseConsegna);
  Result.AddPair('creato_il', DateToISO8601(FCreatoIl));
  Result.AddPair('aggiornato_il', DateToISO8601(FAggiornatoIl));
end;

procedure TCliente.FromJSONObject(AJSON: TJSONObject);
begin
  // Id e audit non si leggono dal payload: li gestisce il database.
  if AJSON.TryGetValue<string>('ragione_sociale', FRagioneSociale) then ;
  if AJSON.TryGetValue<string>('partita_iva', FPartitaIva) then ;
  if AJSON.TryGetValue<string>('email', FEmail) then ;
  if AJSON.TryGetValue<string>('telefono', FTelefono) then ;
  if AJSON.TryGetValue<string>('via_fatturazione', FViaFatturazione) then ;
  if AJSON.TryGetValue<string>('citta_fatturazione', FCittaFatturazione) then ;
  if AJSON.TryGetValue<string>('provincia_fatturazione', FProvinciaFatturazione) then ;
  if AJSON.TryGetValue<string>('cap_fatturazione', FCapFatturazione) then ;
  if AJSON.TryGetValue<string>('paese_fatturazione', FPaeseFatturazione) then ;
  if AJSON.TryGetValue<string>('via_consegna', FViaConsegna) then ;
  if AJSON.TryGetValue<string>('citta_consegna', FCittaConsegna) then ;
  if AJSON.TryGetValue<string>('provincia_consegna', FProvinciaConsegna) then ;
  if AJSON.TryGetValue<string>('cap_consegna', FCapConsegna) then ;
  if AJSON.TryGetValue<string>('paese_consegna', FPaeseConsegna) then ;
end;

end.
