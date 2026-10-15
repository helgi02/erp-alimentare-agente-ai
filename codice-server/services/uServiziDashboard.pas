unit uServiziDashboard;

interface

uses
  System.SysUtils,
  System.JSON,
  DbU;

type
  // Servizio di sola lettura che produce il riepilogo mostrato nella
  // home del frontend web.
  //
  // PERCHE' UN UNICO ENDPOINT AGGREGATO E NON CINQUE CHIAMATE
  // La dashboard e' la prima schermata che si apre: farle fare cinque
  // richieste HTTP separate significherebbe cinque round trip di rete e
  // cinque prelievi dal pool di connessioni per disegnare una sola
  // pagina. Le singole risorse restano comunque interrogabili dai
  // rispettivi controller CRUD per le altre viste: qui si aggrega solo
  // cio' che serve alla home.
  //
  // PERCHE' JSON COSTRUITO A MANO E NON I MODEL
  // I dati della dashboard sono aggregazioni (COUNT, SUM, GROUP BY) e
  // proiezioni con JOIN, non entita' del dominio: non esiste un
  // "TDashboard" da mappare, e passare per i model significherebbe
  // caricare in memoria oggetti interi per poi contarli in Delphi
  // invece che nel database. Le query restituiscono gia' la forma
  // finale, il servizio si limita a tradurla in JSON.
  //
  // NOTA SUI TOTALI DEGLI ORDINI
  // Il totale di un ordine non e' una colonna di ordini_vendita: si
  // calcola come SUM(quantita * prezzo_unitario) sulle righe. E' una
  // scelta del DDL (nessun dato derivato memorizzato, quindi nessun
  // rischio di disallineamento fra testata e righe), e si riflette qui
  // in una subquery invece che in una lettura diretta.
  TServizioDashboard = class
  private
    class function LeggiKPI: TJSONObject;
    class function LeggiVenditeMensili: TJSONArray;
    class function LeggiNonConformitaRecenti: TJSONArray;
    class function LeggiLottiInScadenza: TJSONArray;
    class function LeggiOrdiniRecenti: TJSONArray;
  public
    // Chiamante responsabile della Free dell'oggetto restituito.
    class function Riepilogo: TJSONObject;
  end;

implementation

const
  // Finestre temporali e limiti di riga, raccolti qui invece che
  // sparsi nelle query: sono i parametri che con ogni probabilita'
  // verranno ritoccati dopo le prime prove con dati reali.
  GIORNI_SCADENZA_IMMINENTE = 30;   // soglia "lotto in scadenza"
  GIORNI_FATTURATO          = 30;   // finestra del KPI fatturato
  MESI_STORICO_VENDITE      = 11;   // 11 mesi indietro + corrente = 12
  MAX_RIGHE_ELENCO          = 5;    // righe per ciascuna tabella della home

{ TServizioDashboard }

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
    // Se una delle letture fallisce l'oggetto parziale non deve
    // restare orfano: si libera qui e l'eccezione risale al controller,
    // che la trasformera' in una risposta HTTP 500.
    Result.Free;
    raise;
  end;
end;

// I quattro indicatori in testa alla pagina, in UNA sola query: sono
// quattro scalari indipendenti, e calcolarli come subquery della stessa
// SELECT evita quattro giri separati verso PostgreSQL.
//
// Le soglie temporali sono interpolate nel testo SQL invece che passate
// come parametri perche' sono costanti di compilazione (Integer), non
// input esterni: nessuna superficie di SQL injection.
class function TServizioDashboard.LeggiKPI: TJSONObject;
var
  LAutoQuery: TAutoQuery;
  LSQL: string;
begin
  LSQL :=
    'SELECT ' +
    // Non conformita' ancora da chiudere: 'aperta' e 'in_gestione'
    // valgono entrambe come "aperte" per chi guarda la home.
    '  (SELECT COUNT(*) FROM non_conformita ' +
    '     WHERE stato_nc <> ''chiusa'') AS nc_aperte, ' +
    // Lotti prossimi alla scadenza: contano solo quelli con giacenza
    // residua, un lotto gia' consumato non e' un problema.
    '  (SELECT COUNT(*) FROM lotti_materie_prime ' +
    '     WHERE quantita_disponibile > 0 ' +
    '       AND data_scadenza BETWEEN CURRENT_DATE ' +
    '           AND CURRENT_DATE + ' + GIORNI_SCADENZA_IMMINENTE.ToString + ') AS lotti_in_scadenza, ' +
    // Ordini confermati ma non ancora spediti
    '  (SELECT COUNT(*) FROM ordini_vendita ' +
    '     WHERE stato = ''confermato'') AS ordini_da_spedire, ' +
    // Fatturato dell'ultimo periodo, esclusi gli ordini annullati
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

    // Le finestre temporali viaggiano insieme ai numeri: e' il frontend
    // a scrivere l'etichetta ("entro 30 giorni", "ultimi 30 giorni"), e
    // deve poterlo fare senza avere le soglie cablate anche lui.
    Result.AddPair('giorniScadenza', TJSONNumber.Create(GIORNI_SCADENZA_IMMINENTE));
    Result.AddPair('giorniFatturato', TJSONNumber.Create(GIORNI_FATTURATO));
  finally
    LAutoQuery.Free;
  end;
end;

// Serie del fatturato per mese, ultimi 12 mesi.
// Il mese viaggia in formato 'YYYY-MM': e' ordinabile, non ambiguo e
// indipendente dal locale del server. L'etichetta leggibile ("ago 26")
// la compone il frontend, che conosce la lingua dell'utente.
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

// Ultime non conformita' aperte.
//
// I tre LEFT JOIN riflettono il vincolo chk_lotto_non_conformita del
// DDL: una NC punta ad almeno uno fra lotto materia prima, semilavorato
// e prodotto finito (e' un OR, non uno XOR - vedi commento in
// uModelNonConformita). Il COALESCE prende il primo lotto valorizzato,
// che per la home basta: il dettaglio completo, con eventuali lotti
// multipli, appartiene alla vista della singola NC.
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

// Lotti di materia prima prossimi alla scadenza con giacenza residua.
//
// L'unita' di misura si prende dalla riga DDT di origine e non dal
// lotto: LOTTI_MATERIE_PRIME non ha una colonna propria, la eredita da
// ddt_entrata_righe.unita_misura (scelta del DDL per non duplicare - e
// quindi non disallineare - lo stesso dato in due tabelle). Il JOIN e'
// LEFT perche' la UM non deve poter far sparire una riga dall'elenco:
// meglio un lotto senza unita' che un lotto in scadenza non mostrato.
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

// Ultimi ordini di vendita registrati.
// Il totale e' una subquery correlata sulle righe: vedi la nota in
// testa alla unit sul perche' non e' una colonna di ordini_vendita.
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
