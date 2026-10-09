unit uServiziVendite;

interface

uses
  System.SysUtils,
  System.DateUtils,
  System.Variants,
  System.Generics.Collections,
  Data.DB,
  DbU;

type
  // Esito della risoluzione di UN valore testuale (un elemento
  // dell'array ragione_sociale_cliente o nome_prodotto passato dal
  // modello) sulla rispettiva anagrafica. Il modello non conosce gli ID
  // interni (cliente_id, prodotto_finito_id): puo' solo esprimere un
  // filtro come testo, quindi questo e' il passo che traduce testo -> ID,
  // PRIMA di costruire qualunque query di vendite.
  TEsitoRisoluzione = (erRisolto, erAmbiguo, erNonTrovato);

  // Un candidato restituito quando la risoluzione e' ambigua (o, per
  // comodita' del chiamante, anche quando e' risolta con successo):
  // abbastanza informazione perche' un utente possa distinguere due
  // clienti/prodotti con nome simile.
  TCandidatoCliente = record
    ID: Integer;
    RagioneSociale: string;
    PartitaIva: string;
  end;

  TCandidatoProdotto = record
    ID: Integer;
    Codice: string;
    Denominazione: string;
  end;

  // Risultato di TServizioVendite.RisolviCliente per un singolo valore
  // cercato. ClienteID e' valido solo se Esito = erRisolto; Candidati e'
  // valorizzato se Esito = erAmbiguo (tutti i match trovati, perche' il
  // tool provider deve poterli proporre all'utente) o erRisolto (il
  // singolo match, per comodita' - non e' obbligatorio usarlo in quel
  // caso).
  TRisoluzioneCliente = class
  public
    ValoreCercato: string;
    Esito: TEsitoRisoluzione;
    ClienteID: Integer;
    Candidati: TArray<TCandidatoCliente>;
  end;

  TRisoluzioneProdotto = class
  public
    ValoreCercato: string;
    Esito: TEsitoRisoluzione;
    ProdottoID: Integer;
    Candidati: TArray<TCandidatoProdotto>;
  end;

  // Una riga di dettaglio nel risultato di un'interrogazione vendite: un
  // prodotto venduto in un ordine che soddisfa i filtri (equivale a una
  // riga del JOIN ordini_vendita + ordini_vendita_righe + clienti +
  // anagrafiche_prodotti_finiti). Non e' un model persistito ne' un
  // oggetto con Insert/Update: e' un DTO di sola lettura, pensato per
  // essere serializzato dal tool provider nel tool_result. Per lo stesso
  // motivo porta gia' i NOMI (ragione sociale, denominazione), non solo
  // gli ID: il modello non saprebbe interpretare un ID nudo.
  TRigaVenditaDettaglio = class
  public
    OrdineID: Integer;
    NumeroOrdine: string;
    DataOrdine: TDateTime;
    Stato: string;
    ClienteID: Integer;
    ClienteRagioneSociale: string;
    ProdottoID: Integer;
    ProdottoDenominazione: string;
    Quantita: Currency;
    UnitaMisura: string;
    PrezzoUnitario: Currency;
    Importo: Currency; // Quantita * PrezzoUnitario, calcolato qui una volta per tutte
  end;

  // Esito "positivo" di InterrogaVendite: il periodo EFFETTIVAMENTE
  // applicato (puo' essere il default "ultimo mese", non esplicitato dal
  // chiamante - per questo va restituito, non solo usato internamente,
  // cosi' il modello puo' dichiararlo in risposta invece di lasciare
  // l'utente a chiedersi "ma di che periodo sta parlando?"), l'aggregato
  // complessivo e il dettaglio riga per riga.
  //
  // Non aggregato PER cliente/prodotto quando gli array hanno piu' di un
  // elemento (utile per un vero confronto multi-entita'): e' il
  // prossimo incremento, non ancora implementato in questa prima
  // versione - vedi nota nella conversazione di progetto.
  TRisultatoVendite = class
  public
    DataInizio: TDateTime;
    DataFine: TDateTime;
    TotaleOrdini: Integer;      // ordini DISTINTI coinvolti, non righe
    TotaleQuantita: Currency;
    TotaleFatturato: Currency;
    Dettaglio: TObjectList<TRigaVenditaDettaglio>;

    constructor Create;
    destructor Destroy; override;
  end;

  // Layer Services per lo scenario 2.2 del tirocinio (interrogazione
  // vendite ad hoc). Incapsula le due responsabilita' che il tool MCP
  // get_list_vendite delega qui:
  //   1) risolvere i filtri testuali (nome cliente/prodotto) sulle
  //      rispettive anagrafiche, gestendo i casi di ambiguita';
  //   2) costruire ed eseguire la query aggregata con WHERE dinamica a
  //      partire da qualunque combinazione di filtri opzionali.
  //
  // Principio "tool generico e parametrico" (documento di progetto,
  // sezione 4): tutti i filtri sono opzionali e liberamente componibili;
  // questa classe e' l'UNICA che sa costruire la query per qualsiasi
  // combinazione, cosi' il tool MCP resta uno solo (get_list_vendite),
  // invece di un tool per ogni combinazione di filtri.
  TServizioVendite = class
  private
    // Costruisce un elenco di placeholder posizionali ":pN" per una
    // clausola IN (...) con un numero variabile di elementi.
    // AStartIndex e' il numero di parametri GIA' aggiunti all'array
    // Params prima di questa clausola: TDB.getQueryResult lega i valori
    // per POSIZIONE (Params[i] nell'ordine in cui i nomi compaiono nella
    // query), quindi il nome del placeholder conta solo per essere
    // univoco all'interno della query - non deve avere un significato,
    // deve solo evitare collisioni con altri placeholder gia' usati.
    class function BuildPlaceholders(ACount, AStartIndex: Integer): string;

    // Esegue la query aggregata vera e propria, con WHERE dinamica in
    // base a quali ID sono stati risolti. A questo punto (chiamato solo
    // da InterrogaVendite dopo la risoluzione) tutti i filtri testuali
    // sono gia' diventati ID univoci: qui non c'e' piu' nessuna
    // ambiguita' da gestire, solo un JOIN con filtro.
    //
    // ANessunFiltro (vedi InterrogaVendite): quando True, cliente/prodotto
    // e periodo sono TUTTI assenti nella richiesta originale - in quel
    // caso non ha senso costruire una WHERE dinamica (sarebbe solo
    // "stato <> annullato"): eseguiamo direttamente la query "ultime
    // vendite", senza vincolo di periodo, limitata a MAX_RIGHE_QUERY
    // righe. Quando False, resta il comportamento attuale: WHERE dinamica
    // su tutti i filtri disponibili (incluso il periodo, gia' risolto da
    // InterrogaVendite col default "ultimo mese"), con lo stesso LIMIT in
    // coda per coerenza.
    class function EseguiQueryVendite(
      const AClienteIDs, AProdottoIDs: TArray<Integer>;
      ADataInizio, ADataFine: TDateTime;
      ANessunFiltro: Boolean): TRisultatoVendite;
  public
    // Risolve un singolo valore testuale sull'anagrafica clienti: prova
    // prima un match ESATTO (case-insensitive, tramite ILIKE senza
    // caratteri jolly) sulla ragione sociale; se non trova nulla, ripiega
    // su un match PARZIALE (ILIKE '%valore%'). Il match esatto ha
    // precedenza assoluta: se l'utente ha gia' scritto il nome preciso
    // (es. perche' e' il valore restituito da una precedente
    // disambiguazione), non ha senso riproporre altri candidati solo
    // perche' un match piu' lasco ne troverebbe altri.
    class function RisolviCliente(const ANome: string): TRisoluzioneCliente;

    // Come sopra, per l'anagrafica prodotti: il match esatto e' provato
    // sia sul codice sia sulla denominazione (un operatore puo' riferirsi
    // al prodotto con l'uno o con l'altra); il match parziale, invece,
    // solo sulla denominazione - un codice prodotto e' un identificativo
    // breve, non ha senso cercarlo "contenuto in" un altro codice.
    class function RisolviProdotto(const ANome: string): TRisoluzioneProdotto;

    // Orchestratore principale, pensato per essere chiamato direttamente
    // dal tool provider. Risolve TUTTI i nomi cliente/prodotto passati
    // (ogni elemento dei due array); se anche uno solo risulta ambiguo o
    // non trovato, l'INTERA richiesta si ferma - Result e' nil, e i
    // problemi (tutti, non solo il primo) sono restituiti in
    // AProblemiCliente/AProblemiProdotto. Questo evita di eseguire una
    // query parziale sui filtri validi mentre uno e' irrisolto: in un
    // dominio di tracciabilita' alimentare un dato parziale presentato
    // come completo e' peggio di un rifiuto esplicito.
    //
    // AClienteIdEsatto/AProdottoIdEsatto: 0 = "non specificato" (stessa
    // sentinella di ADataInizio/ADataFine sotto). Quando > 0, ha la
    // PRECEDENZA sul corrispondente array di nomi, che viene ignorato del
    // tutto: nessuna query ILIKE, nessuna nuova risoluzione, quindi
    // nessuna nuova ambiguita' possibile per quel filtro. Pensato per il
    // secondo giro dopo una disambiguazione: il tool provider lo popola
    // quando l'utente ha scelto un id preciso da un elenco di candidati
    // gia' proposto (vedi commento su TVenditeToolProvider).
    //
    // ADataInizio/ADataFine possono essere 0 (sentinella "non
    // specificata" dal chiamante): in tal caso viene applicato il
    // default "ultimo mese" (oggi meno un mese, fino a oggi). Il periodo
    // EFFETTIVAMENTE applicato torna sempre valorizzato dentro
    // TRisultatoVendite.
    //
    // Ownership: se la risoluzione fallisce, gli oggetti in
    // AProblemiCliente/AProblemiProdotto passano in proprieta' al
    // chiamante, che deve liberarli. Se ha successo, il chiamante deve
    // liberare il TRisultatoVendite restituito (e il suo Dettaglio, gia'
    // gestito dal distruttore di TRisultatoVendite).
    class function InterrogaVendite(
      const ANomiCliente: TArray<string>;
      AClienteIdEsatto: Integer;
      const ANomiProdotto: TArray<string>;
      AProdottoIdEsatto: Integer;
      ADataInizio, ADataFine: TDateTime;
      out AProblemiCliente: TArray<TRisoluzioneCliente>;
      out AProblemiProdotto: TArray<TRisoluzioneProdotto>): TRisultatoVendite;
  end;

implementation

{ TRisultatoVendite }

constructor TRisultatoVendite.Create;
begin
  inherited Create;
  Dettaglio := TObjectList<TRigaVenditaDettaglio>.Create(True); // possiede le righe
end;

destructor TRisultatoVendite.Destroy;
begin
  Dettaglio.Free;
  inherited;
end;

{ TServizioVendite }

class function TServizioVendite.BuildPlaceholders(ACount, AStartIndex: Integer): string;
var
  i: Integer;
  LNomi: TArray<string>;
begin
  SetLength(LNomi, ACount);
  for i := 0 to ACount - 1 do
    LNomi[i] := ':p' + IntToStr(AStartIndex + i);
  Result := string.Join(', ', LNomi);
end;

class function TServizioVendite.RisolviCliente(const ANome: string): TRisoluzioneCliente;
var
  LNome: string;
  LCandidati: TList<TCandidatoCliente>;

  procedure EseguiRicerca(const APattern: string);
  var
    LAutoQuery: TAutoQuery;
    LCandidato: TCandidatoCliente;
  begin
    LAutoQuery := TDB.GetInstance.getQueryResult(
      'SELECT id, ragione_sociale, partita_iva FROM clienti ' +
      'WHERE ragione_sociale ILIKE :pattern ORDER BY ragione_sociale',
      [APattern]);
    try
      while not LAutoQuery.Query.Eof do
      begin
        LCandidato.ID             := LAutoQuery.Query.FieldByName('id').AsInteger;
        LCandidato.RagioneSociale := LAutoQuery.Query.FieldByName('ragione_sociale').AsString;
        LCandidato.PartitaIva     := LAutoQuery.Query.FieldByName('partita_iva').AsString;
        LCandidati.Add(LCandidato);
        LAutoQuery.Query.Next;
      end;
    finally
      LAutoQuery.Free;
    end;
  end;

begin
  LNome := Trim(ANome);

  Result := TRisoluzioneCliente.Create;
  Result.ValoreCercato := LNome;

  if LNome = '' then
  begin
    // Guardia: un pattern vuoto dentro ILIKE '%' + '' + '%' = '%%'
    // corrisponderebbe a TUTTI i clienti - l'opposto di quello che
    // vogliamo. Un elemento vuoto nell'array filtri e' un errore di chi
    // costruisce la chiamata (il tool provider dovrebbe gia' scartare le
    // stringhe vuote prima di arrivare qui): lo trattiamo come "non
    // trovato" invece di restituire un falso match universale.
    Result.Esito := erNonTrovato;
    Exit;
  end;

  LCandidati := TList<TCandidatoCliente>.Create;
  try
    // Passo 1: match esatto (case-insensitive - ILIKE senza '%' e' un
    // confronto di uguaglianza case-insensitive in PostgreSQL).
    EseguiRicerca(LNome);

    // Passo 2: solo se il match esatto non ha trovato nulla, ripiega sul
    // match parziale (tollerante a "Rossi" invece di "Rossi Srl").
    if LCandidati.Count = 0 then
      EseguiRicerca('%' + LNome + '%');

    case LCandidati.Count of
      0: Result.Esito := erNonTrovato;
      1:
        begin
          Result.Esito := erRisolto;
          Result.ClienteID := LCandidati[0].ID;
          Result.Candidati := LCandidati.ToArray;
        end;
    else
      Result.Esito := erAmbiguo;
      Result.Candidati := LCandidati.ToArray;
    end;
  finally
    LCandidati.Free;
  end;
end;

class function TServizioVendite.RisolviProdotto(const ANome: string): TRisoluzioneProdotto;
var
  LNome: string;
  LCandidati: TList<TCandidatoProdotto>;

  procedure EseguiRicerca(const ASQL: string; const AParam: string);
  var
    LAutoQuery: TAutoQuery;
    LCandidato: TCandidatoProdotto;
  begin
    LAutoQuery := TDB.GetInstance.getQueryResult(ASQL, [AParam]);
    try
      while not LAutoQuery.Query.Eof do
      begin
        LCandidato.ID            := LAutoQuery.Query.FieldByName('id').AsInteger;
        LCandidato.Codice        := LAutoQuery.Query.FieldByName('codice').AsString;
        LCandidato.Denominazione := LAutoQuery.Query.FieldByName('denominazione').AsString;
        LCandidati.Add(LCandidato);
        LAutoQuery.Query.Next;
      end;
    finally
      LAutoQuery.Free;
    end;
  end;

begin
  LNome := Trim(ANome);

  Result := TRisoluzioneProdotto.Create;
  Result.ValoreCercato := LNome;

  if LNome = '' then
  begin
    // Stessa guardia di RisolviCliente: vedi commento li'.
    Result.Esito := erNonTrovato;
    Exit;
  end;

  LCandidati := TList<TCandidatoProdotto>.Create;
  try
    // Passo 1: match esatto su CODICE o DENOMINAZIONE (un operatore puo'
    // riferirsi al prodotto con l'uno o con l'altra).
    EseguiRicerca(
      'SELECT id, codice, denominazione FROM anagrafiche_prodotti_finiti ' +
      'WHERE codice ILIKE :val OR denominazione ILIKE :val ORDER BY denominazione',
      LNome);

    // Passo 2: match parziale, solo sulla denominazione - un codice
    // prodotto e' un identificativo breve, cercarlo "contenuto in"
    // un altro codice non avrebbe senso.
    if LCandidati.Count = 0 then
      EseguiRicerca(
        'SELECT id, codice, denominazione FROM anagrafiche_prodotti_finiti ' +
        'WHERE denominazione ILIKE :val ORDER BY denominazione',
        '%' + LNome + '%');

    case LCandidati.Count of
      0: Result.Esito := erNonTrovato;
      1:
        begin
          Result.Esito := erRisolto;
          Result.ProdottoID := LCandidati[0].ID;
          Result.Candidati := LCandidati.ToArray;
        end;
    else
      Result.Esito := erAmbiguo;
      Result.Candidati := LCandidati.ToArray;
    end;
  finally
    LCandidati.Free;
  end;
end;

class function TServizioVendite.EseguiQueryVendite(
  const AClienteIDs, AProdottoIDs: TArray<Integer>;
  ADataInizio, ADataFine: TDateTime;
  ANessunFiltro: Boolean): TRisultatoVendite;
const
  // I JOIN a clienti e anagrafiche_prodotti_finiti sono SEMPRE presenti,
  // a prescindere da quali filtri sono stati passati: servono comunque a
  // restituire i NOMI in output (un tool_result con soli ID interni
  // sarebbe inutile al modello, che non li sa interpretare). E' il
  // WHERE, costruito dinamicamente qui sotto, a variare in base ai
  // filtri - non la struttura dei JOIN.
  SQL_BASE =
    'SELECT ov.id AS ordine_id, ov.numero_ordine, ov.data_ordine, ov.stato, ' +
    'c.id AS cliente_id, c.ragione_sociale, ' +
    'apf.id AS prodotto_id, apf.denominazione, ' +
    'ovr.quantita, ovr.unita_misura, ovr.prezzo_unitario ' +
    'FROM ordini_vendita ov ' +
    'JOIN clienti c ON c.id = ov.cliente_id ' +
    'JOIN ordini_vendita_righe ovr ON ovr.ordine_vendita_id = ov.id ' +
    'JOIN anagrafiche_prodotti_finiti apf ON apf.id = ovr.prodotto_finito_id ';
  // Limite righe applicato SEMPRE in coda alla query, sia nel ramo
  // "nessun filtro" (dove e' l'unico vincolo, insieme a stato <>
  // annullato) sia nel ramo con filtri (dove si aggiunge alla WHERE
  // dinamica): evita di restituire al modello un numero di righe
  // arbitrariamente grande in entrambi i casi.
  MAX_RIGHE_QUERY = 100;
var
  LWhere: TList<string>;
  LParams: TList<Variant>;
  LSQL: string;
  i: Integer;
  LAutoQuery: TAutoQuery;
  LRiga: TRigaVenditaDettaglio;
  LOrdiniDistinti: TList<Integer>;
begin
  Result := TRisultatoVendite.Create;
  Result.DataInizio := ADataInizio;
  Result.DataFine := ADataFine;

  LWhere := TList<string>.Create;
  LParams := TList<Variant>.Create;
  LOrdiniDistinti := TList<Integer>.Create;
  try
    if ANessunFiltro then
    begin
      // Richiesta priva di qualunque filtro: niente WHERE dinamica, solo
      // l'esclusione sempre valida degli annullati (vedi commento sotto)
      // e il LIMIT. Nessun parametro posizionale da legare.
      LSQL := SQL_BASE +
        'WHERE ov.stato <> ''annullato'' ' +
        'ORDER BY ov.data_ordine DESC ' +
        'LIMIT ' + IntToStr(MAX_RIGHE_QUERY);

      LAutoQuery := TDB.GetInstance.getQueryResult(LSQL);
    end
    else
    begin
      // Un ordine annullato non e' una vendita: escluso SEMPRE (non e' un
      // filtro opzionale - vedi discussione di progetto). Se in futuro
      // servisse interrogare esplicitamente gli annullati (es. "quali
      // ordini sono stati annullati questo mese"), sara' un tool/parametro
      // a parte, non una variante di get_list_vendite.
      LWhere.Add('ov.stato <> ''annullato''');

      // Il periodo e' sempre applicato in questo ramo: a differenza di
      // cliente/prodotto, non e' mai "assente" a questo punto
      // (InterrogaVendite ha gia' risolto il default "ultimo mese" prima
      // di chiamare questo metodo, dato che ANessunFiltro = False implica
      // che almeno un filtro - non necessariamente il periodo - e'
      // presente).
      LWhere.Add('ov.data_ordine BETWEEN :data_inizio AND :data_fine');
      LParams.Add(ADataInizio);
      LParams.Add(ADataFine);

      if Length(AClienteIDs) > 0 then
      begin
        LWhere.Add('c.id IN (' + BuildPlaceholders(Length(AClienteIDs), LParams.Count) + ')');
        for i := 0 to High(AClienteIDs) do
          LParams.Add(AClienteIDs[i]);
      end;

      if Length(AProdottoIDs) > 0 then
      begin
        LWhere.Add('apf.id IN (' + BuildPlaceholders(Length(AProdottoIDs), LParams.Count) + ')');
        for i := 0 to High(AProdottoIDs) do
          LParams.Add(AProdottoIDs[i]);
      end;

      LSQL := SQL_BASE + 'WHERE ' + string.Join(' AND ', LWhere.ToArray) +
        ' ORDER BY ov.data_ordine DESC LIMIT ' + IntToStr(MAX_RIGHE_QUERY);

      LAutoQuery := TDB.GetInstance.getQueryResult(LSQL, LParams.ToArray);
    end;

    try
      while not LAutoQuery.Query.Eof do
      begin
        LRiga := TRigaVenditaDettaglio.Create;
        LRiga.OrdineID              := LAutoQuery.Query.FieldByName('ordine_id').AsInteger;
        LRiga.NumeroOrdine          := LAutoQuery.Query.FieldByName('numero_ordine').AsString;
        LRiga.DataOrdine            := LAutoQuery.Query.FieldByName('data_ordine').AsDateTime;
        LRiga.Stato                 := LAutoQuery.Query.FieldByName('stato').AsString;
        LRiga.ClienteID             := LAutoQuery.Query.FieldByName('cliente_id').AsInteger;
        LRiga.ClienteRagioneSociale := LAutoQuery.Query.FieldByName('ragione_sociale').AsString;
        LRiga.ProdottoID            := LAutoQuery.Query.FieldByName('prodotto_id').AsInteger;
        LRiga.ProdottoDenominazione := LAutoQuery.Query.FieldByName('denominazione').AsString;
        LRiga.Quantita              := LAutoQuery.Query.FieldByName('quantita').AsCurrency;
        LRiga.UnitaMisura           := LAutoQuery.Query.FieldByName('unita_misura').AsString;
        LRiga.PrezzoUnitario        := LAutoQuery.Query.FieldByName('prezzo_unitario').AsCurrency;
        LRiga.Importo               := LRiga.Quantita * LRiga.PrezzoUnitario;

        Result.Dettaglio.Add(LRiga);
        Result.TotaleQuantita  := Result.TotaleQuantita + LRiga.Quantita;
        Result.TotaleFatturato := Result.TotaleFatturato + LRiga.Importo;
        if not LOrdiniDistinti.Contains(LRiga.OrdineID) then
          LOrdiniDistinti.Add(LRiga.OrdineID);

        LAutoQuery.Query.Next;
      end;
    finally
      LAutoQuery.Free;
    end;

    Result.TotaleOrdini := LOrdiniDistinti.Count;
  finally
    LWhere.Free;
    LParams.Free;
    LOrdiniDistinti.Free;
  end;
end;

class function TServizioVendite.InterrogaVendite(
  const ANomiCliente: TArray<string>;
  AClienteIdEsatto: Integer;
  const ANomiProdotto: TArray<string>;
  AProdottoIdEsatto: Integer;
  ADataInizio, ADataFine: TDateTime;
  out AProblemiCliente: TArray<TRisoluzioneCliente>;
  out AProblemiProdotto: TArray<TRisoluzioneProdotto>): TRisultatoVendite;
var
  LClienteIDs, LProdottoIDs: TList<Integer>;
  LProblemiCliente: TList<TRisoluzioneCliente>;
  LProblemiProdotto: TList<TRisoluzioneProdotto>;
  LRisoluzioneC: TRisoluzioneCliente;
  LRisoluzioneP: TRisoluzioneProdotto;
  LNome: string;
  LNessunFiltro: Boolean;
begin
  Result := nil;
  AProblemiCliente := [];
  AProblemiProdotto := [];

  // Richiesta priva di QUALUNQUE filtro (ne' cliente, ne' prodotto, ne'
  // periodo): calcolato PRIMA di applicare il default "ultimo mese" al
  // periodo, perche' e' proprio la presenza/assenza del periodo esplicito
  // a determinare il flag (se lo calcolassimo dopo il passo 2, ADataFine/
  // ADataInizio non sarebbero piu' 0 e il flag risulterebbe sempre
  // False). Guida due scelte in EseguiQueryVendite: se True, niente WHERE
  // dinamica e niente vincolo di periodo, solo "ultime N vendite"; se
  // False, resta il comportamento attuale (vedi passo 2 e 3 sotto).
  //
  // AClienteIdEsatto/AProdottoIdEsatto contano come filtro presente
  // esattamente come i rispettivi array di nomi: sono due modi diversi
  // di esprimere lo stesso vincolo (per testo o per id gia' risolto), non
  // un filtro ulteriore rispetto a loro.
  LNessunFiltro :=
    (Length(ANomiCliente) = 0) and (AClienteIdEsatto = 0) and
    (Length(ANomiProdotto) = 0) and (AProdottoIdEsatto = 0) and
    (ADataInizio = 0) and
    (ADataFine = 0);

  LClienteIDs := TList<Integer>.Create;
  LProdottoIDs := TList<Integer>.Create;
  // Questi due NON possiedono gli oggetti che contengono (non sono
  // TObjectList): i risolti con successo vengono liberati subito sotto
  // (l'ID e' gia' stato estratto, non servono oltre); i problematici
  // restano vivi e la loro proprieta' passa al chiamante tramite
  // AProblemiCliente/AProblemiProdotto - per questo qui liberiamo solo il
  // CONTENITORE, mai gli oggetti al suo interno (vedi finally in fondo).
  LProblemiCliente := TList<TRisoluzioneCliente>.Create;
  LProblemiProdotto := TList<TRisoluzioneProdotto>.Create;
  try
    // --- 1) Risoluzione di ogni filtro testuale (o dell'id esatto) ----
    //
    // Se l'id esatto e' stato fornito, ha la precedenza: si usa
    // direttamente, senza passare da RisolviCliente/RisolviProdotto. E'
    // la via che elimina l'ambiguita' per costruzione invece di
    // limitarsi a ridurla - vedi il commento sull'id esatto sopra la
    // dichiarazione di questo metodo per il caso (raro ma reale) in cui
    // anche un match testuale ESATTO trova piu' di un candidato
    // (omonimia perfetta fra due anagrafiche).
    if AClienteIdEsatto > 0 then
      LClienteIDs.Add(AClienteIdEsatto)
    else
      for LNome in ANomiCliente do
      begin
        LRisoluzioneC := RisolviCliente(LNome);
        if LRisoluzioneC.Esito = erRisolto then
        begin
          LClienteIDs.Add(LRisoluzioneC.ClienteID);
          LRisoluzioneC.Free;
        end
        else
          LProblemiCliente.Add(LRisoluzioneC);
      end;

    if AProdottoIdEsatto > 0 then
      LProdottoIDs.Add(AProdottoIdEsatto)
    else
      for LNome in ANomiProdotto do
      begin
        LRisoluzioneP := RisolviProdotto(LNome);
        if LRisoluzioneP.Esito = erRisolto then
        begin
          LProdottoIDs.Add(LRisoluzioneP.ProdottoID);
          LRisoluzioneP.Free;
        end
        else
          LProblemiProdotto.Add(LRisoluzioneP);
      end;

    // Se anche un solo filtro e' ambiguo/non trovato, l'INTERA richiesta
    // si ferma: nessuna query di vendite viene eseguita. Riportiamo TUTTI
    // i problemi insieme (non solo il primo), cosi' chi chiama puo'
    // chiederli all'utente in un colpo solo invece che uno alla volta a
    // ogni turno di conversazione.
    if (LProblemiCliente.Count > 0) or (LProblemiProdotto.Count > 0) then
    begin
      AProblemiCliente := LProblemiCliente.ToArray;
      AProblemiProdotto := LProblemiProdotto.ToArray;
      Exit; // Result resta nil
    end;

    // --- 2) Periodo: default "ultimo mese" se non specificato ---------
    // Sentinella 0 = non valorizzato dal chiamante (stesso principio
    // "parametro opzionale con sentinella" gia' usato altrove nel
    // progetto, es. TServizioRitiroRichiamo.EseguiRitiro).
    //
    // Applicato SOLO quando esiste almeno un filtro (LNessunFiltro =
    // False): con una richiesta completamente priva di filtri non ha
    // senso restringere implicitamente all'ultimo mese un risultato che
    // l'utente non ha vincolato a nessun periodo - vedi EseguiQueryVendite,
    // che in quel caso ignora comunque data_inizio/data_fine.
    if not LNessunFiltro then
    begin
      if ADataFine = 0 then
        ADataFine := Now;
      if ADataInizio = 0 then
        ADataInizio := IncMonth(ADataFine, -1);
    end;

    // --- 3) Query -------------------------------------------------------
    // Nessun filtro -> ultime MAX_RIGHE_QUERY vendite, senza WHERE
    // dinamica ne' vincolo di periodo. Almeno un filtro -> tutti i filtri
    // risolti (cliente/prodotto/periodo) diventano una WHERE dinamica,
    // con lo stesso LIMIT in coda (vedi EseguiQueryVendite).
    Result := EseguiQueryVendite(LClienteIDs.ToArray, LProdottoIDs.ToArray,
      ADataInizio, ADataFine, LNessunFiltro);
  finally
    LClienteIDs.Free;
    LProdottoIDs.Free;
    LProblemiCliente.Free;
    LProblemiProdotto.Free;
  end;
end;

end.
