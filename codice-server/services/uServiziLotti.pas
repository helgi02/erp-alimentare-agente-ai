unit uServiziLotti;

interface

uses
  System.SysUtils,
  System.JSON,
  System.DateUtils,
  DbU;

type
  // Letture "arricchite" sui tre lotti (materie prime, semilavorati, prodotti finiti) per
  // la vista Lotti.
  // Un service e non i model: i model restano fedeli alla riga della tabella
  // (TLottoMateriaPrima.ToJSONObject espone materia_prima_id, giusto per TServizioGiacenza
  // e un futuro CRUD), ma la vista deve mostrare codice e denominazione gia' risolti.
  // Stessa scelta degli ordini di vendita (TServizioOrdiniVendita.Elenco, SQL_ELENCO_BASE).
  // Tre elenchi separati e non un /api/lotti unico: servirebbe una UNION su tabelle con
  // colonne diverse (i lotti di semilavorato non hanno data_scadenza, quelli di materia
  // prima non hanno ricetta_id/stabilimento_id) e un JSON annacquato. Tre endpoint
  // (uControllerLottiMateriePrime/Semilavorati/ProdottiFiniti) come le anagrafiche,
  // ciascuno con la forma della propria tabella; la vista che vuole una tabella unica
  // unisce i risultati lato client (assets/js/views/view-lotti.js).
  // Sola lettura: nessuno scenario crea o modifica un lotto da REST. Un lotto nasce da un
  // DDT di entrata o da una produzione (fuori perimetro) o si decrementa con un consumo
  // (TServizioGiacenza, dai tool dello scenario ricette).
  TServizioLotti = class
  public
    // AMateriaPrimaID = 0: tutti i lotti; altrimenti solo quelli di quella materia prima
    // (come GetByMateriaPrima, con la denominazione risolta).
    class function ElencoMateriePrime(AMateriaPrimaID: Integer = 0): TJSONArray;
    class function DettaglioMateriaPrima(AID: Integer): TJSONObject;

    class function ElencoSemilavorati(ASemilavoratoID: Integer = 0): TJSONArray;
    class function DettaglioSemilavorato(AID: Integer): TJSONObject;

    class function ElencoProdottiFiniti(AProdottoFinitoID: Integer = 0): TJSONArray;
    class function DettaglioProdottoFinito(AID: Integer): TJSONObject;
  end;

implementation

const
  // JOIN su anagrafiche_materie_prime per codice e denominazione. ORDER BY data_scadenza =
  // FEFO, come TLottoMateriaPrima.GetAll. LEFT JOIN su ddt_entrata_righe: il lotto non ha
  // unita_misura propria (uModelLottoMateriaPrima), senza il join la vista non saprebbe se
  // la quantita' e' in kg, litri o pezzi; LEFT perche' un lotto senza riga DDT (dato
  // storico) non deve sparire.
  SQL_LOTTI_MATERIE_PRIME =
    'SELECT l.id, l.materia_prima_id, mp.codice AS entita_codice, ' +
    'mp.denominazione AS entita_denominazione, l.codice_lotto, ' +
    'l.data_scadenza, l.quantita, l.quantita_disponibile, ' +
    'der.unita_misura, l.ddt_entrata_riga_id, l.creato_il, l.aggiornato_il ' +
    'FROM lotti_materie_prime l ' +
    'JOIN anagrafiche_materie_prime mp ON mp.id = l.materia_prima_id ' +
    'LEFT JOIN ddt_entrata_righe der ON der.id = l.ddt_entrata_riga_id ';

  // Niente data_scadenza (non prevista per i semilavorati): ordine per data_produzione,
  // piu' recente per ultima.
  SQL_LOTTI_SEMILAVORATI =
    'SELECT l.id, l.semilavorato_id, s.codice AS entita_codice, ' +
    's.denominazione AS entita_denominazione, l.codice_lotto, ' +
    'l.data_produzione, l.quantita, l.quantita_disponibile, ' +
    'l.unita_misura, l.ricetta_id, l.stabilimento_id, l.creato_il, ' +
    'l.aggiornato_il ' +
    'FROM lotti_semilavorati l ' +
    'JOIN anagrafiche_semilavorati s ON s.id = l.semilavorato_id ';

  SQL_LOTTI_PRODOTTI_FINITI =
    'SELECT l.id, l.prodotto_finito_id, pf.codice AS entita_codice, ' +
    'pf.denominazione AS entita_denominazione, l.codice_lotto, ' +
    'l.data_produzione, l.data_scadenza, l.quantita, ' +
    'l.quantita_disponibile, l.unita_misura, l.ricetta_id, ' +
    'l.stabilimento_id, l.creato_il, l.aggiornato_il ' +
    'FROM lotti_prodotti_finiti l ' +
    'JOIN anagrafiche_prodotti_finiti pf ON pf.id = l.prodotto_finito_id ';

// Mapping riga -> TJSONObject, uno per tipo, usato da Elenco e Dettaglio cosi' le due
// risposte non divergono. "entita_codice"/"entita_denominazione" hanno lo stesso nome nei
// tre JSON, cosi' view-lotti.js, che unisce i tre elenchi, legge sempre la stessa chiave.

function RigaMateriaPrima(AQuery: TAutoQuery): TJSONObject;
begin
  Result := TJSONObject.Create;
  with AQuery.Query do
  begin
    Result.AddPair('id', TJSONNumber.Create(FieldByName('id').AsInteger));
    Result.AddPair('materia_prima_id', TJSONNumber.Create(FieldByName('materia_prima_id').AsInteger));
    Result.AddPair('entita_codice', FieldByName('entita_codice').AsString);
    Result.AddPair('entita_denominazione', FieldByName('entita_denominazione').AsString);
    Result.AddPair('codice_lotto', FieldByName('codice_lotto').AsString);
    Result.AddPair('data_scadenza', DateToISO8601(FieldByName('data_scadenza').AsDateTime));
    Result.AddPair('quantita', TJSONNumber.Create(FieldByName('quantita').AsCurrency));
    Result.AddPair('quantita_disponibile', TJSONNumber.Create(FieldByName('quantita_disponibile').AsCurrency));
    // AsString su un NULL (nessuna riga DDT, vedi LEFT JOIN) da' '', mai un'eccezione.
    Result.AddPair('unita_misura', FieldByName('unita_misura').AsString);
    Result.AddPair('ddt_entrata_riga_id', TJSONNumber.Create(FieldByName('ddt_entrata_riga_id').AsInteger));
    Result.AddPair('creato_il', DateToISO8601(FieldByName('creato_il').AsDateTime));
    Result.AddPair('aggiornato_il', DateToISO8601(FieldByName('aggiornato_il').AsDateTime));
  end;
end;

function RigaSemilavorato(AQuery: TAutoQuery): TJSONObject;
begin
  Result := TJSONObject.Create;
  with AQuery.Query do
  begin
    Result.AddPair('id', TJSONNumber.Create(FieldByName('id').AsInteger));
    Result.AddPair('semilavorato_id', TJSONNumber.Create(FieldByName('semilavorato_id').AsInteger));
    Result.AddPair('entita_codice', FieldByName('entita_codice').AsString);
    Result.AddPair('entita_denominazione', FieldByName('entita_denominazione').AsString);
    Result.AddPair('codice_lotto', FieldByName('codice_lotto').AsString);
    Result.AddPair('data_produzione', DateToISO8601(FieldByName('data_produzione').AsDateTime));
    Result.AddPair('quantita', TJSONNumber.Create(FieldByName('quantita').AsCurrency));
    Result.AddPair('quantita_disponibile', TJSONNumber.Create(FieldByName('quantita_disponibile').AsCurrency));
    Result.AddPair('unita_misura', FieldByName('unita_misura').AsString);
    Result.AddPair('ricetta_id', TJSONNumber.Create(FieldByName('ricetta_id').AsInteger));
    Result.AddPair('stabilimento_id', TJSONNumber.Create(FieldByName('stabilimento_id').AsInteger));
    Result.AddPair('creato_il', DateToISO8601(FieldByName('creato_il').AsDateTime));
    Result.AddPair('aggiornato_il', DateToISO8601(FieldByName('aggiornato_il').AsDateTime));
  end;
end;

function RigaProdottoFinito(AQuery: TAutoQuery): TJSONObject;
begin
  Result := TJSONObject.Create;
  with AQuery.Query do
  begin
    Result.AddPair('id', TJSONNumber.Create(FieldByName('id').AsInteger));
    Result.AddPair('prodotto_finito_id', TJSONNumber.Create(FieldByName('prodotto_finito_id').AsInteger));
    Result.AddPair('entita_codice', FieldByName('entita_codice').AsString);
    Result.AddPair('entita_denominazione', FieldByName('entita_denominazione').AsString);
    Result.AddPair('codice_lotto', FieldByName('codice_lotto').AsString);
    Result.AddPair('data_produzione', DateToISO8601(FieldByName('data_produzione').AsDateTime));
    Result.AddPair('data_scadenza', DateToISO8601(FieldByName('data_scadenza').AsDateTime));
    Result.AddPair('quantita', TJSONNumber.Create(FieldByName('quantita').AsCurrency));
    Result.AddPair('quantita_disponibile', TJSONNumber.Create(FieldByName('quantita_disponibile').AsCurrency));
    Result.AddPair('unita_misura', FieldByName('unita_misura').AsString);
    Result.AddPair('ricetta_id', TJSONNumber.Create(FieldByName('ricetta_id').AsInteger));
    Result.AddPair('stabilimento_id', TJSONNumber.Create(FieldByName('stabilimento_id').AsInteger));
    Result.AddPair('creato_il', DateToISO8601(FieldByName('creato_il').AsDateTime));
    Result.AddPair('aggiornato_il', DateToISO8601(FieldByName('aggiornato_il').AsDateTime));
  end;
end;

class function TServizioLotti.ElencoMateriePrime(AMateriaPrimaID: Integer): TJSONArray;
var
  LSQL: string;
  LAutoQuery: TAutoQuery;
begin
  Result := TJSONArray.Create;

  LSQL := SQL_LOTTI_MATERIE_PRIME;
  if AMateriaPrimaID > 0 then
    LSQL := LSQL + 'WHERE l.materia_prima_id = :materia_prima_id ';
  LSQL := LSQL + 'ORDER BY l.data_scadenza';

  if AMateriaPrimaID > 0 then
    LAutoQuery := TDB.GetInstance.getQueryResult(LSQL, [AMateriaPrimaID])
  else
    LAutoQuery := TDB.GetInstance.getQueryResult(LSQL);
  try
    while not LAutoQuery.Query.Eof do
    begin
      Result.AddElement(RigaMateriaPrima(LAutoQuery));
      LAutoQuery.Query.Next;
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TServizioLotti.DettaglioMateriaPrima(AID: Integer): TJSONObject;
var
  LAutoQuery: TAutoQuery;
begin
  Result := nil;

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_LOTTI_MATERIE_PRIME + 'WHERE l.id = :id', [AID]);
  try
    if not LAutoQuery.Query.IsEmpty then
      Result := RigaMateriaPrima(LAutoQuery);
  finally
    LAutoQuery.Free;
  end;
end;

class function TServizioLotti.ElencoSemilavorati(ASemilavoratoID: Integer): TJSONArray;
var
  LSQL: string;
  LAutoQuery: TAutoQuery;
begin
  Result := TJSONArray.Create;

  LSQL := SQL_LOTTI_SEMILAVORATI;
  if ASemilavoratoID > 0 then
    LSQL := LSQL + 'WHERE l.semilavorato_id = :semilavorato_id ';
  LSQL := LSQL + 'ORDER BY l.data_produzione';

  if ASemilavoratoID > 0 then
    LAutoQuery := TDB.GetInstance.getQueryResult(LSQL, [ASemilavoratoID])
  else
    LAutoQuery := TDB.GetInstance.getQueryResult(LSQL);
  try
    while not LAutoQuery.Query.Eof do
    begin
      Result.AddElement(RigaSemilavorato(LAutoQuery));
      LAutoQuery.Query.Next;
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TServizioLotti.DettaglioSemilavorato(AID: Integer): TJSONObject;
var
  LAutoQuery: TAutoQuery;
begin
  Result := nil;

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_LOTTI_SEMILAVORATI + 'WHERE l.id = :id', [AID]);
  try
    if not LAutoQuery.Query.IsEmpty then
      Result := RigaSemilavorato(LAutoQuery);
  finally
    LAutoQuery.Free;
  end;
end;

class function TServizioLotti.ElencoProdottiFiniti(AProdottoFinitoID: Integer): TJSONArray;
var
  LSQL: string;
  LAutoQuery: TAutoQuery;
begin
  Result := TJSONArray.Create;

  LSQL := SQL_LOTTI_PRODOTTI_FINITI;
  if AProdottoFinitoID > 0 then
    LSQL := LSQL + 'WHERE l.prodotto_finito_id = :prodotto_finito_id ';
  LSQL := LSQL + 'ORDER BY l.data_scadenza';

  if AProdottoFinitoID > 0 then
    LAutoQuery := TDB.GetInstance.getQueryResult(LSQL, [AProdottoFinitoID])
  else
    LAutoQuery := TDB.GetInstance.getQueryResult(LSQL);
  try
    while not LAutoQuery.Query.Eof do
    begin
      Result.AddElement(RigaProdottoFinito(LAutoQuery));
      LAutoQuery.Query.Next;
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TServizioLotti.DettaglioProdottoFinito(AID: Integer): TJSONObject;
var
  LAutoQuery: TAutoQuery;
begin
  Result := nil;

  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_LOTTI_PRODOTTI_FINITI + 'WHERE l.id = :id', [AID]);
  try
    if not LAutoQuery.Query.IsEmpty then
      Result := RigaProdottoFinito(LAutoQuery);
  finally
    LAutoQuery.Free;
  end;
end;

end.
