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
  // Filtri dell'elenco ordini di vendita, tutti opzionali e combinabili (lo stesso
  // principio dei tool MCP, a livello REST). Sentinella "filtro assente": 0 per gli ID e
  // per le date, come nei model (0 = NULL).
  TFiltriOrdiniVendita = record
    ClienteID: Integer;
    ProdottoID: Integer;
    DataInizio: TDateTime;
    DataFine: TDateTime;
    Stato: string;
    Pagina: Integer;
    PerPagina: Integer;
  end;

  // Lettura per la schermata Vendite.
  // Non riusa TServizioVendite (quello dei tool MCP) perche' ha comportamenti sbagliati per
  // una schermata: risolve i nomi in ID gestendo l'ambiguita', taglia il dettaglio a 100
  // righe, applica il periodo di default "ultimo mese" ed esclude sempre gli annullati. La
  // vista riceve ID gia' scelti, pagina davvero, mostra il periodo e puo' filtrare anche
  // gli annullati.
  // I totali sono calcolati da una query propria, senza LIMIT, non sommati sulle righe
  // della pagina: "fatturato del periodo" e non "dei record mostrati", che sarebbe un
  // numero plausibile e sbagliato. Lo stesso difetto c'e' oggi in
  // TServizioVendite.EseguiQuery (totali sommati su una query limitata a 100 righe) e va
  // corretto li' allo stesso modo.
  TServizioOrdiniVendita = class
  private
    // Costruisce la WHERE dinamica e riempie AParams nello stesso ordine dei placeholder:
    // TDB.getQueryResult li lega per posizione. La stessa WHERE serve la query dei dati e
    // quella dei totali, che non possono divergere.
    class function CostruisciWhere(const AFiltri: TFiltriOrdiniVendita;
      AParams: TList<Variant>): string;

    class function RigheOrdineToJSON(AOrdineID: Integer;
      out ATotale: Currency): TJSONArray;
  public
    // Elenco paginato. Il chiamante libera l'oggetto.
    class function Elenco(const AFiltri: TFiltriOrdiniVendita): TJSONObject;

    // Testata + righe di un ordine. nil se non esiste (il controller risponde 404).
    class function Dettaglio(AID: Integer): TJSONObject;

    // Valori di chk_stato_ordine_vendita, perche' il controller risponda 400 a uno stato
    // non valido invece di mandare al DB un filtro senza senso.
    class function StatoValido(const AStato: string): Boolean;
  end;

implementation

const
  // Limite alla dimensione di pagina: senza, per_pagina=100000 leggerebbe l'intera tabella.
  MAX_PER_PAGINA     = 200;
  PER_PAGINA_DEFAULT = 10;

  STATI_VALIDI: array[0..3] of string =
    ('confermato', 'spedito', 'consegnato', 'annullato');

  // Testata + due valori derivati dalle righe (numero_righe, totale), subquery correlate
  // perche' il DDL non memorizza dati derivati.
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

  // Totali sull'intero insieme filtrato. Il LEFT JOIN sulle righe somma gli importi;
  // COUNT(DISTINCT ov.id) e' necessario perche' il join moltiplica la testata per le righe
  // e COUNT(*) conterebbe le righe.
  SQL_TOTALI_BASE =
    'SELECT COUNT(DISTINCT ov.id) AS totale_ordini, ' +
    '       COALESCE(SUM(ovr.quantita * ovr.prezzo_unitario), 0) AS totale_fatturato ' +
    'FROM ordini_vendita ov ' +
    'JOIN clienti c ON c.id = ov.cliente_id ' +
    'LEFT JOIN ordini_vendita_righe ovr ON ovr.ordine_vendita_id = ov.id ';

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

    // Filtro sul prodotto con EXISTS e non con JOIN: con il JOIN i totali sommerebbero solo
    // le righe del prodotto, un fatturato diverso dal valore degli ordini elencati (che
    // mostrano il totale intero). Con EXISTS i totali restano coerenti con la tabella.
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

    // A differenza del tool MCP gli annullati non sono esclusi: in schermata sono un filtro
    // come gli altri.
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

    // Totali: prima, senza LIMIT, sull'insieme filtrato completo.
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

    // Pagina di dati. LIMIT e OFFSET sono interpolati come interi gia' validati: legarli
    // costringerebbe a tenere conto della posizione nei Params (legati per posizione). Sono
    // Integer: nessun rischio di injection.
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

// Righe di un ordine, con il totale calcolato su tutte (non su un campione), quindi
// accumulare durante la lettura e' corretto.
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
    // LEFT JOIN: il lotto puo' non essere assegnato (ordine confermato non spedito); con un
    // JOIN interno le righe sparirebbero in silenzio.
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
