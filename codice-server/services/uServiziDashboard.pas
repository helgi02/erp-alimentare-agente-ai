unit uServiziDashboard;

interface

uses
  System.SysUtils,
  System.JSON,
  DbU;

type
  // Riepilogo di sola lettura per la home del frontend.
  // Un unico endpoint aggregato e non cinque chiamate: la home e' la prima schermata, e
  // cinque richieste sarebbero cinque round trip e cinque connessioni dal pool. Le singole
  // risorse restano nei rispettivi controller.
  // JSON costruito a mano e non dai model: sono aggregazioni (COUNT, SUM, GROUP BY) e JOIN,
  // non entita'; passare dai model vorrebbe dire caricare oggetti interi per contarli in
  // Delphi invece che nel database.
  // Il totale di un ordine non e' una colonna di ordini_vendita: e' SUM(quantita *
  // prezzo_unitario) sulle righe (scelta del DDL: nessun dato derivato, nessun
  // disallineamento testata-righe), quindi qui e' una subquery.
  TServizioDashboard = class
  private
    class function LeggiKPI: TJSONObject;
    class function LeggiVenditeMensili: TJSONArray;
    class function LeggiNonConformitaRecenti: TJSONArray;
    class function LeggiLottiInScadenza: TJSONArray;
    class function LeggiOrdiniRecenti: TJSONArray;
  public
    // Il chiamante libera l'oggetto restituito.
    class function Riepilogo: TJSONObject;
  end;

implementation

const
  // Finestre temporali e limiti di riga, raccolti qui perche' verranno ritoccati dopo le
  // prove con dati reali.
  GIORNI_SCADENZA_IMMINENTE = 30;   // soglia "lotto in scadenza"
  GIORNI_FATTURATO          = 30;   // finestra del KPI fatturato
  MESI_STORICO_VENDITE      = 11;   // 11 mesi indietro + corrente = 12
  MAX_RIGHE_ELENCO          = 5;    // righe per ciascuna tabella della home

class function TServizioDashboard.Riepilogo: TJSONObject;
begin
  Result := TJSONObject.Create;
  try
    Result.AddPair('kpi',             LeggiKPI);
    Result.AddPair('venditeMensili',  LeggiVenditeMensili);
    Result.AddPair('nonConformita',   LeggiNonConformitaRecenti);
    Result.AddPair('lottiInScadenza', LeggiLottiInScadenza);
    Result.AddPair('ordiniRecenti',   LeggiOrdiniRecenti);
  except
    // Se una lettura fallisce l'oggetto parziale non resta orfano: si libera qui e
    // l'eccezione arriva al controller (HTTP 500).
    Result.Free;
    raise;
  end;
end;

// I quattro indicatori in una sola query (subquery scalari nella stessa SELECT), per
// evitare quattro giri verso PostgreSQL. Le soglie sono interpolate nel testo SQL perche'
// sono costanti di compilazione (Integer), non input esterno: nessun rischio di SQL
// injection.
class function TServizioDashboard.LeggiKPI: TJSONObject;
var
  LAutoQuery: TAutoQuery;
  LSQL: string;
begin
  LSQL :=
    'SELECT ' +
    // 'aperta' e 'in_gestione' valgono entrambe come aperte.
    '  (SELECT COUNT(*) FROM non_conformita ' +
    '     WHERE stato_nc <> ''chiusa'') AS nc_aperte, ' +
    // Solo lotti con giacenza residua: uno consumato non e' un problema.
    '  (SELECT COUNT(*) FROM lotti_materie_prime ' +
    '     WHERE quantita_disponibile > 0 ' +
    '       AND data_scadenza BETWEEN CURRENT_DATE ' +
    '           AND CURRENT_DATE + ' + GIORNI_SCADENZA_IMMINENTE.ToString + ') AS lotti_in_scadenza, ' +
    '  (SELECT COUNT(*) FROM ordini_vendita ' +
    '     WHERE stato = ''confermato'') AS ordini_da_spedire, ' +
    // Fatturato dell'ultimo periodo, esclusi gli annullati.
    '  (SELECT COALESCE(SUM(ovr.quantita * ovr.prezzo_unitario), 0) ' +
    '     FROM ordini_vendita ov ' +
    '     JOIN ordini_vendita_righe ovr ON ovr.ordine_vendita_id = ov.id ' +
    '     WHERE ov.stato <> ''annullato'' ' +
    '       AND ov.data_ordine >= CURRENT_DATE - ' + GIORNI_FATTURATO.ToString + ') AS fatturato_periodo';

  LAutoQuery := TDB.GetInstance.getQueryResult(LSQL);
  try
    Result := TJSONObject.Create;
    Result.AddPair('ncAperte',
      TJSONNumber.Create(LAutoQuery.Query.FieldByName('nc_aperte').AsInteger));
    Result.AddPair('lottiInScadenza',
      TJSONNumber.Create(LAutoQuery.Query.FieldByName('lotti_in_scadenza').AsInteger));
    Result.AddPair('ordiniDaSpedire',
      TJSONNumber.Create(LAutoQuery.Query.FieldByName('ordini_da_spedire').AsInteger));
    Result.AddPair('fatturatoPeriodo',
      TJSONNumber.Create(LAutoQuery.Query.FieldByName('fatturato_periodo').AsCurrency));

    // Le finestre viaggiano coi numeri: l'etichetta ("entro 30 giorni") la scrive il
    // frontend senza soglie cablate.
    Result.AddPair('giorniScadenza', TJSONNumber.Create(GIORNI_SCADENZA_IMMINENTE));
    Result.AddPair('giorniFatturato', TJSONNumber.Create(GIORNI_FATTURATO));
  finally
    LAutoQuery.Free;
  end;
end;

// Fatturato per mese, ultimi 12. Il mese e' 'YYYY-MM' (ordinabile, non ambiguo,
// indipendente dal locale); l'etichetta ("ago 26") la compone il frontend.
class function TServizioDashboard.LeggiVenditeMensili: TJSONArray;
var
  LAutoQuery: TAutoQuery;
  LSQL: string;
  LRiga: TJSONObject;
begin
  LSQL :=
    'SELECT to_char(date_trunc(''month'', ov.data_ordine), ''YYYY-MM'') AS mese, ' +
    '       COALESCE(SUM(ovr.quantita * ovr.prezzo_unitario), 0) AS importo ' +
    'FROM ordini_vendita ov ' +
    'JOIN ordini_vendita_righe ovr ON ovr.ordine_vendita_id = ov.id ' +
    'WHERE ov.stato <> ''annullato'' ' +
    '  AND ov.data_ordine >= date_trunc(''month'', CURRENT_DATE) ' +
    '      - INTERVAL ''' + MESI_STORICO_VENDITE.ToString + ' months'' ' +
    'GROUP BY 1 ' +
    'ORDER BY 1';

  LAutoQuery := TDB.GetInstance.getQueryResult(LSQL);
  try
    Result := TJSONArray.Create;
    while not LAutoQuery.Query.Eof do
    begin
      LRiga := TJSONObject.Create;
      LRiga.AddPair('mese', LAutoQuery.Query.FieldByName('mese').AsString);
      LRiga.AddPair('importo',
        TJSONNumber.Create(LAutoQuery.Query.FieldByName('importo').AsCurrency));
      Result.AddElement(LRiga);
      LAutoQuery.Query.Next;
    end;
  finally
    LAutoQuery.Free;
  end;
end;

// Ultime non conformita' aperte. I tre LEFT JOIN riflettono chk_lotto_non_conformita (OR,
// non XOR, vedi uModelNonConformita); COALESCE prende il primo lotto valorizzato, basta per
// la home: il dettaglio spetta alla vista della singola NC.
class function TServizioDashboard.LeggiNonConformitaRecenti: TJSONArray;
var
  LAutoQuery: TAutoQuery;
  LSQL: string;
  LRiga: TJSONObject;
begin
  LSQL :=
    'SELECT nc.id, nc.codice_nc, nc.motivo, nc.stato_nc, nc.data_apertura, ' +
    '       COALESCE(lmp.codice_lotto, lsl.codice_lotto, lpf.codice_lotto) AS lotto, ' +
    '       CASE ' +
    '         WHEN nc.lotto_materia_prima_id   IS NOT NULL THEN ''materia prima'' ' +
    '         WHEN nc.lotto_semilavorato_id    IS NOT NULL THEN ''semilavorato'' ' +
    '         WHEN nc.lotto_prodotto_finito_id IS NOT NULL THEN ''prodotto finito'' ' +
    '       END AS lotto_tipo ' +
    'FROM non_conformita nc ' +
    'LEFT JOIN lotti_materie_prime   lmp ON lmp.id = nc.lotto_materia_prima_id ' +
    'LEFT JOIN lotti_semilavorati    lsl ON lsl.id = nc.lotto_semilavorato_id ' +
    'LEFT JOIN lotti_prodotti_finiti lpf ON lpf.id = nc.lotto_prodotto_finito_id ' +
    'ORDER BY nc.data_apertura DESC, nc.id DESC ' +
    'LIMIT ' + MAX_RIGHE_ELENCO.ToString;

  LAutoQuery := TDB.GetInstance.getQueryResult(LSQL);
  try
    Result := TJSONArray.Create;
    while not LAutoQuery.Query.Eof do
    begin
      LRiga := TJSONObject.Create;
      LRiga.AddPair('id', TJSONNumber.Create(LAutoQuery.Query.FieldByName('id').AsInteger));
      LRiga.AddPair('codice_nc',     LAutoQuery.Query.FieldByName('codice_nc').AsString);
      LRiga.AddPair('motivo',        LAutoQuery.Query.FieldByName('motivo').AsString);
      LRiga.AddPair('stato_nc',      LAutoQuery.Query.FieldByName('stato_nc').AsString);
      LRiga.AddPair('data_apertura',
        FormatDateTime('yyyy-mm-dd', LAutoQuery.Query.FieldByName('data_apertura').AsDateTime));
      LRiga.AddPair('lotto',         LAutoQuery.Query.FieldByName('lotto').AsString);
      LRiga.AddPair('lotto_tipo',    LAutoQuery.Query.FieldByName('lotto_tipo').AsString);
      Result.AddElement(LRiga);
      LAutoQuery.Query.Next;
    end;
  finally
    LAutoQuery.Free;
  end;
end;

// Lotti di materia prima in scadenza con giacenza. L'unita' di misura viene dalla riga DDT
// di origine (ddt_entrata_righe.unita_misura), perche' il lotto non ha una colonna propria.
// LEFT JOIN: meglio un lotto senza unita' che uno in scadenza non mostrato.
class function TServizioDashboard.LeggiLottiInScadenza: TJSONArray;
var
  LAutoQuery: TAutoQuery;
  LSQL: string;
  LRiga: TJSONObject;
begin
  LSQL :=
    'SELECT l.id, l.codice_lotto, amp.denominazione AS materia_prima, ' +
    '       l.data_scadenza, (l.data_scadenza - CURRENT_DATE) AS giorni, ' +
    '       l.quantita_disponibile, der.unita_misura AS um ' +
    'FROM lotti_materie_prime l ' +
    'JOIN anagrafiche_materie_prime amp ON amp.id = l.materia_prima_id ' +
    'LEFT JOIN ddt_entrata_righe der ON der.id = l.ddt_entrata_riga_id ' +
    'WHERE l.quantita_disponibile > 0 ' +
    '  AND l.data_scadenza BETWEEN CURRENT_DATE ' +
    '      AND CURRENT_DATE + ' + GIORNI_SCADENZA_IMMINENTE.ToString + ' ' +
    'ORDER BY l.data_scadenza ' +
    'LIMIT ' + MAX_RIGHE_ELENCO.ToString;

  LAutoQuery := TDB.GetInstance.getQueryResult(LSQL);
  try
    Result := TJSONArray.Create;
    while not LAutoQuery.Query.Eof do
    begin
      LRiga := TJSONObject.Create;
      LRiga.AddPair('id', TJSONNumber.Create(LAutoQuery.Query.FieldByName('id').AsInteger));
      LRiga.AddPair('codice_lotto',  LAutoQuery.Query.FieldByName('codice_lotto').AsString);
      LRiga.AddPair('materia_prima', LAutoQuery.Query.FieldByName('materia_prima').AsString);
      LRiga.AddPair('data_scadenza',
        FormatDateTime('yyyy-mm-dd', LAutoQuery.Query.FieldByName('data_scadenza').AsDateTime));
      LRiga.AddPair('giorni',
        TJSONNumber.Create(LAutoQuery.Query.FieldByName('giorni').AsInteger));
      LRiga.AddPair('quantita_disponibile',
        TJSONNumber.Create(LAutoQuery.Query.FieldByName('quantita_disponibile').AsCurrency));
      LRiga.AddPair('um', LAutoQuery.Query.FieldByName('um').AsString);
      Result.AddElement(LRiga);
      LAutoQuery.Query.Next;
    end;
  finally
    LAutoQuery.Free;
  end;
end;

// Ultimi ordini di vendita. Il totale e' una subquery correlata sulle righe (vedi nota in
// testa).
class function TServizioDashboard.LeggiOrdiniRecenti: TJSONArray;
var
  LAutoQuery: TAutoQuery;
  LSQL: string;
  LRiga: TJSONObject;
begin
  LSQL :=
    'SELECT ov.id, ov.numero_ordine, ov.data_ordine, ov.stato, ' +
    '       c.ragione_sociale AS cliente, ' +
    '       (SELECT COALESCE(SUM(r.quantita * r.prezzo_unitario), 0) ' +
    '          FROM ordini_vendita_righe r ' +
    '         WHERE r.ordine_vendita_id = ov.id) AS totale ' +
    'FROM ordini_vendita ov ' +
    'JOIN clienti c ON c.id = ov.cliente_id ' +
    'ORDER BY ov.data_ordine DESC, ov.id DESC ' +
    'LIMIT ' + MAX_RIGHE_ELENCO.ToString;

  LAutoQuery := TDB.GetInstance.getQueryResult(LSQL);
  try
    Result := TJSONArray.Create;
    while not LAutoQuery.Query.Eof do
    begin
      LRiga := TJSONObject.Create;
      LRiga.AddPair('id', TJSONNumber.Create(LAutoQuery.Query.FieldByName('id').AsInteger));
      LRiga.AddPair('numero_ordine', LAutoQuery.Query.FieldByName('numero_ordine').AsString);
      LRiga.AddPair('data_ordine',
        FormatDateTime('yyyy-mm-dd', LAutoQuery.Query.FieldByName('data_ordine').AsDateTime));
      LRiga.AddPair('cliente', LAutoQuery.Query.FieldByName('cliente').AsString);
      LRiga.AddPair('stato',   LAutoQuery.Query.FieldByName('stato').AsString);
      LRiga.AddPair('totale',
        TJSONNumber.Create(LAutoQuery.Query.FieldByName('totale').AsCurrency));
      Result.AddElement(LRiga);
      LAutoQuery.Query.Next;
    end;
  finally
    LAutoQuery.Free;
  end;
end;

end.
