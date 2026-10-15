unit uServiziLotti;

interface

uses
  System.SysUtils,
  System.JSON,
  System.DateUtils,
  DbU;

type
  // Query di lettura "arricchite" sui tre lotti (materie prime,
  // semilavorati, prodotti finiti), pensate per la vista Lotti del
  // frontend web.
  //
  // PERCHE' UN SERVICE E NON I MODEL TLottoMateriaPrima/TLottoSemilavorato/
  // TLottoProdottoFinito (vedi models/uModelLotto*.pas)
  // I model restano fedeli alla riga della loro tabella: TLottoMateriaPrima.
  // ToJSONObject espone materia_prima_id, non la denominazione, perche' e'
  // la rappresentazione corretta per chi scrive (TServizioGiacenza, che
  // lavora per id) e per un futuro CRUD. La vista Lotti, pero', deve
  // disegnare una tabella leggibile: un id nudo non basta, serve gia'
  // risolto codice+denominazione della materia prima/semilavorato/prodotto
  // finito collegato. Stessa scelta gia' fatta per gli ordini di vendita
  // (vedi TServizioOrdiniVendita.Elenco, SQL_ELENCO_BASE: la riga d'ordine
  // porta gia' "prodotto" via JOIN, non solo prodotto_id) — qui si applica
  // lo stesso principio ai tre tipi di lotto.
  //
  // TRE METODI ELENCO SEPARATI, NON UNO SOLO
  // Scelta presa con Helena: un /api/lotti unico che unisce i tre tipi
  // avrebbe richiesto una UNION su tabelle con colonne diverse (i lotti di
  // semilavorato non hanno data_scadenza, quelli di materia prima non hanno
  // ricetta_id/stabilimento_id...) e un'unica forma JSON annacquata per
  // forza. Tre endpoint distinti (vedi i tre controller
  // uControllerLottiMateriePrime/Semilavorati/ProdottiFiniti) restano
  // speculari al pattern gia' in uso per le anagrafiche (TControllerMateriePrime/
  // Semilavorati/ProdottiFiniti) ed espongono ciascuno la forma reale della
  // propria tabella: la vista frontend, se vuole una tabella unica, unisce i
  // tre risultati lato client (vedi assets/js/views/view-lotti.js).
  //
  // SOLA LETTURA
  // Nessuno dei tre scenari del tirocinio crea o modifica un lotto da un
  // endpoint REST diretto: un lotto nasce da un DDT di entrata o da una
  // produzione (entrambi fuori dal perimetro, vedi le voci disabilitate in
  // view-da-costruire.js) oppure viene decrementato in giacenza da un
  // consumo di produzione (TServizioGiacenza, chiamato dai tool MCP dello
  // scenario ricette). La scrittura vera resta li': questo service e i
  // controller che lo usano sono solo una vetrina di lettura.
  TServizioLotti = class
  public
    // AMateriaPrimaID = 0 (default): nessun filtro, tutti i lotti.
    // Altrimenti solo i lotti di QUELLA materia prima (stesso ruolo di
    // TLottoMateriaPrima.GetByMateriaPrima, qui con denominazione gia'
    // risolta).
    class function ElencoMateriePrime(AMateriaPrimaID: Integer = 0): TJSONArray;
    class function DettaglioMateriaPrima(AID: Integer): TJSONObject;

    class function ElencoSemilavorati(ASemilavoratoID: Integer = 0): TJSONArray;
    class function DettaglioSemilavorato(AID: Integer): TJSONObject;

    class function ElencoProdottiFiniti(AProdottoFinitoID: Integer = 0): TJSONArray;
    class function DettaglioProdottoFinito(AID: Integer): TJSONObject;
  end;

implementation

const
  // JOIN su anagrafiche_materie_prime: mp.codice/mp.denominazione danno
  // alla riga un nome leggibile, esattamente come materia_prima_id da
  // solo non potrebbe. ORDER BY data_scadenza = ordinamento FEFO (First
  // Expired, First Out), lo stesso gia' scelto in TLottoMateriaPrima.GetAll.
  // LEFT JOIN (non JOIN) su ddt_entrata_righe: TLottoMateriaPrima non ha
  // una colonna unita_misura propria, la eredita dalla riga DDT di
  // origine (vedi il commento in uModelLottoMateriaPrima.pas) - senza
  // questo secondo join la vista non avrebbe modo di sapere se una
  // quantita' e' in kg, litri o pezzi. LEFT e non JOIN semplice per
  // sicurezza: un domani un lotto senza riga DDT collegata (dato
  // storico, importazione) non deve sparire dall'elenco, deve solo
  // comparire con unita_misura vuota.
  SQL_LOTTI_MATERIE_PRIME =
    'SELECT l.id, l.materia_prima_id, mp.codice AS entita_codice, ' +
    'mp.denominazione AS entita_denominazione, l.codice_lotto, ' +
    'l.data_scadenza, l.quantita, l.quantita_disponibile, ' +
    'der.unita_misura, l.ddt_entrata_riga_id, l.creato_il, l.aggiornato_il ' +
    'FROM lotti_materie_prime l ' +
    'JOIN anagrafiche_materie_prime mp ON mp.id = l.materia_prima_id ' +
    'LEFT JOIN ddt_entrata_righe der ON der.id = l.ddt_entrata_riga_id ';

  // I lotti di semilavorato non hanno data_scadenza (il DDL non la
  // prevede, vedi il commento in uModelLottoSemilavorato.pas): si ordina
  // per data_produzione, piu' recente per ultima, come nel model.
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

{ TServizioLotti }

// ---------------------------------------------------------------------
// Mapping riga -> TJSONObject, un metodo per tipo: usato sia da Elenco
// (una volta per riga) sia da Dettaglio (una volta sola), cosi' le due
// risposte non possono divergere nella forma. "entita_codice"/
// "entita_denominazione" (non "materia_prima_codice" ecc.): stesso nome
// di campo nei tre JSON, cosi' la vista frontend che unisce i tre elenchi
// in un'unica tabella (view-lotti.js) legge sempre la stessa chiave a
// prescindere dal tipo di lotto, invece di doverla scegliere caso per
// caso.
// ---------------------------------------------------------------------

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
    // AsString su un campo NULL (nessuna riga DDT collegata, vedi il
    // commento sul LEFT JOIN qui sopra) restituisce '', mai un'eccezione.
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
