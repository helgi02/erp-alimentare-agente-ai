unit uServiziOrdiniVendita;

interface

uses
  System.SysUtils,
  System.JSON,
  System.Generics.Collections,
  System.DateUtils,
  System.Variants,
  DbU;

type
  // Filtri dell'elenco ordini di vendita. Tutti opzionali e liberamente
  // combinabili: e' lo stesso principio di design dei tool MCP (un solo
  // punto di accesso parametrico invece di un endpoint per ogni
  // combinazione), applicato qui al livello REST.
  //
  // Le sentinelle di "filtro assente" sono 0 per gli ID e 0 (data nulla)
  // per le date, coerentemente con il resto del progetto, dove 0 indica
  // gia' NULL nei model (es. TNonConformita.LottoMateriaPrimaID).
  TFiltriOrdiniVendita = record
    ClienteID: Integer;
    ProdottoID: Integer;
    DataInizio: TDateTime;
    DataFine: TDateTime;
    Stato: string;
    Pagina: Integer;
    PerPagina: Integer;
  end;

  // Servizio di sola lettura a supporto della schermata Vendite del
  // frontend web.
  //
  // PERCHE' NON SI RIUSA TServizioVendite (quello dei tool MCP)
  // Quel servizio e' tarato su un interlocutore diverso, il modello
  // linguistico, e ha comportamenti che in una schermata sarebbero
  // sbagliati: risolve i nomi in ID gestendo l'ambiguita', taglia il
  // dettaglio a 100 righe, applica un periodo di default implicito
  // ("ultimo mese") e esclude sempre gli ordini annullati. La vista
  // riceve invece ID gia' scelti da un elenco, deve paginare davvero,
  // deve mostrare il periodo nei campi e deve poter filtrare anche gli
  // annullati. Stessi dati e stesso dominio, interfacce diverse: sono
  // due servizi distinti proprio perche' i vincoli sono diversi.
  //
  // NOTA SUI TOTALI (importante)
  // I totali sono calcolati da una query PROPRIA, senza LIMIT, non
  // accumulati mentre si leggono le righe della pagina. E' la
  // differenza fra "fatturato del periodo richiesto" e "fatturato dei
  // record che sto mostrando": la seconda e' un numero plausibile e
  // sbagliato, cioe' il tipo di errore peggiore. Lo stesso difetto e'
  // presente oggi in TServizioVendite.EseguiQuery, dove i totali
  // vengono sommati dentro il ciclo su una query gia' limitata a 100
  // righe, e va corretto li' allo stesso modo.
  TServizioOrdiniVendita = class
  private
    // Costruisce la clausola WHERE dinamica in base ai filtri
    // valorizzati, e riempie AParams con i valori nello stesso ordine in
    // cui i placeholder compaiono nel testo: TDB.getQueryResult li lega
    // per POSIZIONE, quindi l'ordine di inserimento e' vincolante.
    // La stessa WHERE viene usata sia dalla query dei dati sia da quella
    // dei totali: una sola definizione del filtro, nessun rischio che le
    // due divergano.
    class function CostruisciWhere(const AFiltri: TFiltriOrdiniVendita;
      AParams: TList<Variant>): string;

    class function RigheOrdineToJSON(AOrdineID: Integer;
      out ATotale: Currency): TJSONArray;
  public
    // Elenco paginato. Il chiamante e' responsabile della Free.
    class function Elenco(const AFiltri: TFiltriOrdiniVendita): TJSONObject;

    // Testata + righe di un singolo ordine. Restituisce nil se l'ordine
    // non esiste, cosi' il controller puo' rispondere 404.
    class function Dettaglio(AID: Integer): TJSONObject;

    // Valori ammessi da chk_stato_ordine_vendita. Esposta perche' il
    // controller possa rifiutare uno stato non valido con un 400 invece
    // di lasciar arrivare al database un filtro senza senso.
    class function StatoValido(const AStato: string): Boolean;
  end;

implementation

const
  // Limite di sicurezza sulla dimensione di pagina: senza, un
  // per_pagina=100000 nella query string diventerebbe una lettura
  // dell'intera tabella richiesta da chiunque.
  MAX_PER_PAGINA     = 200;
  PER_PAGINA_DEFAULT = 10;

  STATI_VALIDI: array[0..3] of string =
    ('confermato', 'spedito', 'consegnato', 'annullato');

  // Testata dell'ordine piu' i due valori derivati dalle righe.
  // numero_righe e totale sono subquery correlate e non colonne di
  // ordini_vendita: il DDL non memorizza dati derivati, cosi' testata e
  // righe non possono disallinearsi.
  SQL_ELENCO_BASE =
    'SELECT ov.id, ov.numero_ordine, ov.data_ordine, ov.stato, ' +
    '       ov.cliente_id, c.ragione_sociale AS cliente, ' +
    '       (SELECT COUNT(*) FROM ordini_vendita_righe r ' +
    '          WHERE r.ordine_vendita_id = ov.id) AS numero_righe, ' +
    '       (SELECT COALESCE(SUM(r.quantita * r.prezzo_unitario), 0) ' +
    '          FROM ordini_vendita_righe r ' +
    '         WHERE r.ordine_vendita_id = ov.id) AS totale ' +
    'FROM ordini_vendita ov ' +
    'JOIN clienti c ON c.id = ov.cliente_id ';

  // Totali sull'intero insieme filtrato.
  // Il LEFT JOIN sulle righe serve a sommare gli importi; COUNT(DISTINCT
  // ov.id) e' obbligatorio perche' il join moltiplica la testata per il
  // numero di righe e un COUNT(*) conterebbe le righe, non gli ordini.
  SQL_TOTALI_BASE =
    'SELECT COUNT(DISTINCT ov.id) AS totale_ordini, ' +
    '       COALESCE(SUM(ovr.quantita * ovr.prezzo_unitario), 0) AS totale_fatturato ' +
    'FROM ordini_vendita ov ' +
    'JOIN clienti c ON c.id = ov.cliente_id ' +
    'LEFT JOIN ordini_vendita_righe ovr ON ovr.ordine_vendita_id = ov.id ';

{ TServizioOrdiniVendita }

class function TServizioOrdiniVendita.StatoValido(const AStato: string): Boolean;
var
  LStato: string;
begin
  for LStato in STATI_VALIDI do
    if SameText(LStato, AStato) then
      Exit(True);
  Result := False;
end;

class function TServizioOrdiniVendita.CostruisciWhere(
  const AFiltri: TFiltriOrdiniVendita; AParams: TList<Variant>): string;
var
  LCondizioni: TList<string>;
begin
  LCondizioni := TList<string>.Create;
  try
    if AFiltri.ClienteID > 0 then
    begin
      LCondizioni.Add('ov.cliente_id = :cliente_id');
      AParams.Add(AFiltri.ClienteID);
    end;

    // Filtro sul prodotto con EXISTS e non con un JOIN sulle righe.
    // La differenza non e' stilistica: con il JOIN, la query dei totali
    // sommerebbe solo le righe del prodotto filtrato, restituendo un
    // "fatturato" che non corrisponde al valore degli ordini elencati
    // (dove invece compare il totale INTERO dell'ordine). Con EXISTS il
    // filtro seleziona gli ordini che contengono quel prodotto, e i
    // totali restano coerenti con quello che si vede in tabella.
    if AFiltri.ProdottoID > 0 then
    begin
      LCondizioni.Add(
        'EXISTS (SELECT 1 FROM ordini_vendita_righe r2 ' +
        '         WHERE r2.ordine_vendita_id = ov.id ' +
        '           AND r2.prodotto_finito_id = :prodotto_id)');
      AParams.Add(AFiltri.ProdottoID);
    end;

    if AFiltri.DataInizio > 0 then
    begin
      LCondizioni.Add('ov.data_ordine >= :data_inizio');
      AParams.Add(AFiltri.DataInizio);
    end;

    if AFiltri.DataFine > 0 then
    begin
      LCondizioni.Add('ov.data_ordine <= :data_fine');
      AParams.Add(AFiltri.DataFine);
    end;

    // A differenza del tool MCP, qui gli annullati NON sono esclusi
    // d'ufficio: nella schermata sono un filtro come gli altri, perche'
    // un operatore ha motivi legittimi per cercarli.
    if AFiltri.Stato <> '' then
    begin
      LCondizioni.Add('ov.stato = :stato');
      AParams.Add(AFiltri.Stato);
    end;

    if LCondizioni.Count = 0 then
      Result := ''
    else
      Result := 'WHERE ' + string.Join(' AND ', LCondizioni.ToArray) + ' ';
  finally
    LCondizioni.Free;
  end;
end;

class function TServizioOrdiniVendita.Elenco(
  const AFiltri: TFiltriOrdiniVendita): TJSONObject;
var
  LParams: TList<Variant>;
  LWhere, LSQL: string;
  LAutoQuery: TAutoQuery;
  LOrdini: TJSONArray;
  LRiga: TJSONObject;
  LPagina, LPerPagina, LOffset: Integer;
begin
  LPerPagina := AFiltri.PerPagina;
  if LPerPagina <= 0 then
    LPerPagina := PER_PAGINA_DEFAULT;
  if LPerPagina > MAX_PER_PAGINA then
    LPerPagina := MAX_PER_PAGINA;

  LPagina := AFiltri.Pagina;
  if LPagina < 1 then
    LPagina := 1;

  LOffset := (LPagina - 1) * LPerPagina;

  Result := TJSONObject.Create;
  LParams := TList<Variant>.Create;
  try
    LWhere := CostruisciWhere(AFiltri, LParams);

    // --- Totali: PRIMA e senza LIMIT, sull'insieme filtrato completo.
    LAutoQuery := TDB.GetInstance.getQueryResult(
      SQL_TOTALI_BASE + LWhere, LParams.ToArray);
    try
      Result.AddPair('totale_ordini',
        TJSONNumber.Create(LAutoQuery.Query.FieldByName('totale_ordini').AsInteger));
      Result.AddPair('totale_fatturato',
        TJSONNumber.Create(LAutoQuery.Query.FieldByName('totale_fatturato').AsCurrency));
    finally
      LAutoQuery.Free;
    end;

    // --- Pagina di dati.
    // LIMIT e OFFSET sono interpolati come interi gia' validati e non
    // passati come parametri: restando in coda alla query, legarli
    // costringerebbe a tenere conto della loro posizione nell'array
    // Params, che TDB lega posizionalmente. Sono Integer, quindi non
    // c'e' superficie di injection.
    LSQL := SQL_ELENCO_BASE + LWhere +
      'ORDER BY ov.data_ordine DESC, ov.id DESC ' +
      'LIMIT ' + LPerPagina.ToString + ' OFFSET ' + LOffset.ToString;

    LAutoQuery := TDB.GetInstance.getQueryResult(LSQL, LParams.ToArray);
    try
      LOrdini := TJSONArray.Create;
      while not LAutoQuery.Query.Eof do
      begin
        LRiga := TJSONObject.Create;
        LRiga.AddPair('id',
          TJSONNumber.Create(LAutoQuery.Query.FieldByName('id').AsInteger));
        LRiga.AddPair('numero_ordine',
          LAutoQuery.Query.FieldByName('numero_ordine').AsString);
        LRiga.AddPair('data_ordine',
          FormatDateTime('yyyy-mm-dd', LAutoQuery.Query.FieldByName('data_ordine').AsDateTime));
        LRiga.AddPair('cliente_id',
          TJSONNumber.Create(LAutoQuery.Query.FieldByName('cliente_id').AsInteger));
        LRiga.AddPair('cliente',
          LAutoQuery.Query.FieldByName('cliente').AsString);
        LRiga.AddPair('stato',
          LAutoQuery.Query.FieldByName('stato').AsString);
        LRiga.AddPair('numero_righe',
          TJSONNumber.Create(LAutoQuery.Query.FieldByName('numero_righe').AsInteger));
        LRiga.AddPair('totale',
          TJSONNumber.Create(LAutoQuery.Query.FieldByName('totale').AsCurrency));

        LOrdini.AddElement(LRiga);
        LAutoQuery.Query.Next;
      end;

      Result.AddPair('pagina', TJSONNumber.Create(LPagina));
      Result.AddPair('per_pagina', TJSONNumber.Create(LPerPagina));
      Result.AddPair('ordini', LOrdini);
    finally
      LAutoQuery.Free;
    end;
  except
    Result.Free;
    LParams.Free;
    raise;
  end;
  LParams.Free;
end;

// Righe di un ordine. Restituisce anche il totale calcolato sulle righe
// lette, cosi' il chiamante non deve rifare la somma con una seconda
// query: qui il ciclo copre TUTTE le righe dell'ordine, non un campione,
// quindi accumulare durante la lettura e' corretto.
class function TServizioOrdiniVendita.RigheOrdineToJSON(AOrdineID: Integer;
  out ATotale: Currency): TJSONArray;
var
  LAutoQuery: TAutoQuery;
  LRiga: TJSONObject;
  LImporto: Currency;
begin
  ATotale := 0;

  LAutoQuery := TDB.GetInstance.getQueryResult(
    'SELECT ovr.id, ovr.prodotto_finito_id AS prodotto_id, ' +
    '       apf.denominazione AS prodotto, ' +
    '       lpf.codice_lotto AS lotto, ' +
    '       ovr.quantita, ovr.unita_misura, ovr.prezzo_unitario ' +
    'FROM ordini_vendita_righe ovr ' +
    'JOIN anagrafiche_prodotti_finiti apf ON apf.id = ovr.prodotto_finito_id ' +
    // LEFT JOIN: il lotto puo' non essere ancora assegnato (ordine
    // confermato ma non spedito). Con un JOIN interno quelle righe
    // sparirebbero dal dettaglio, che sarebbe un errore silenzioso.
    'LEFT JOIN lotti_prodotti_finiti lpf ON lpf.id = ovr.lotto_prodotto_finito_id ' +
    'WHERE ovr.ordine_vendita_id = :ordine_vendita_id ' +
    'ORDER BY ovr.id', [AOrdineID]);
  try
    Result := TJSONArray.Create;
    while not LAutoQuery.Query.Eof do
    begin
      LImporto := LAutoQuery.Query.FieldByName('quantita').AsCurrency *
                  LAutoQuery.Query.FieldByName('prezzo_unitario').AsCurrency;
      ATotale := ATotale + LImporto;

      LRiga := TJSONObject.Create;
      LRiga.AddPair('id',
        TJSONNumber.Create(LAutoQuery.Query.FieldByName('id').AsInteger));
      LRiga.AddPair('prodotto_id',
        TJSONNumber.Create(LAutoQuery.Query.FieldByName('prodotto_id').AsInteger));
      LRiga.AddPair('prodotto',
        LAutoQuery.Query.FieldByName('prodotto').AsString);
      LRiga.AddPair('lotto',
        LAutoQuery.Query.FieldByName('lotto').AsString);
      LRiga.AddPair('quantita',
        TJSONNumber.Create(LAutoQuery.Query.FieldByName('quantita').AsCurrency));
      LRiga.AddPair('unita_misura',
        LAutoQuery.Query.FieldByName('unita_misura').AsString);
      LRiga.AddPair('prezzo_unitario',
        TJSONNumber.Create(LAutoQuery.Query.FieldByName('prezzo_unitario').AsCurrency));
      LRiga.AddPair('importo', TJSONNumber.Create(LImporto));

      Result.AddElement(LRiga);
      LAutoQuery.Query.Next;
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TServizioOrdiniVendita.Dettaglio(AID: Integer): TJSONObject;
var
  LAutoQuery: TAutoQuery;
  LTotale: Currency;
begin
  LAutoQuery := TDB.GetInstance.getQueryResult(
    'SELECT ov.id, ov.numero_ordine, ov.data_ordine, ov.stato, ov.note, ' +
    '       ov.cliente_id, c.ragione_sociale AS cliente ' +
    'FROM ordini_vendita ov ' +
    'JOIN clienti c ON c.id = ov.cliente_id ' +
    'WHERE ov.id = :id', [AID]);
  try
    if LAutoQuery.Query.IsEmpty then
      Exit(nil);

    Result := TJSONObject.Create;
    try
      Result.AddPair('id',
        TJSONNumber.Create(LAutoQuery.Query.FieldByName('id').AsInteger));
      Result.AddPair('numero_ordine',
        LAutoQuery.Query.FieldByName('numero_ordine').AsString);
      Result.AddPair('data_ordine',
        FormatDateTime('yyyy-mm-dd', LAutoQuery.Query.FieldByName('data_ordine').AsDateTime));
      Result.AddPair('cliente_id',
        TJSONNumber.Create(LAutoQuery.Query.FieldByName('cliente_id').AsInteger));
      Result.AddPair('cliente',
        LAutoQuery.Query.FieldByName('cliente').AsString);
      Result.AddPair('stato',
        LAutoQuery.Query.FieldByName('stato').AsString);
      Result.AddPair('note',
        LAutoQuery.Query.FieldByName('note').AsString);

      Result.AddPair('righe', RigheOrdineToJSON(AID, LTotale));
      Result.AddPair('totale', TJSONNumber.Create(LTotale));
    except
      Result.Free;
      raise;
    end;
  finally
    LAutoQuery.Free;
  end;
end;

end.
