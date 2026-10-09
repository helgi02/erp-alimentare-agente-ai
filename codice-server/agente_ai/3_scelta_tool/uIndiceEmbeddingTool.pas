unit uIndiceEmbeddingTool;

// Fase 1: mantiene la tabella mcp_tool_indice allineata ai tool davvero registrati e la
// interroga per trovare i tool pertinenti a una domanda, cosi' nel prompt vanno solo i loro
// schemi.
// Fonti: TCatalogoTool (nome e descrizione dei tool reali, mai ricopiati a mano) e
// TFrasiEsempioTool (frasi scritte a mano). TRegistroProviderMCP fa da cerniera: una riga
// il cui tool non e' riconosciuto da nessun provider viene scartata con un log.
// Sincronizza non fa DROP/INSERT: ricalcolare a ogni avvio tutti gli embedding sprecherebbe
// una chiamata per frase. Quindi: (1) costruisce le righe desiderate con l'hash SHA-256 del
// testo; (2) legge dalla tabella la cache hash -> embedding; (3) riusa l'embedding se
// l'hash coincide, altrimenti lo segna da calcolare; (4) una sola chiamata batch per tutto
// cio' che manca; (5) TRUNCATE + reinsert in un'unica transazione: l'indice riflette
// l'elenco desiderato oppure resta com'era.
// Va chiamata in FormCreate dopo TCatalogoTool.Costruisci e prima di doStartServer; e'
// sicura da richiamare piu' volte.

interface

uses
  System.Generics.Collections;

type
  // Un tool trovato con la sua similarita' rispetto alla domanda. E' il risultato di Cerca.
  TToolPertinente = record
    NomeTool: string;
    Provider: string;
    Similarita: Double;
  end;

  TIndiceEmbeddingTool = class
  public
    class procedure Sincronizza;

    // Tutti i tool dei migliori AMaxProvider PROVIDER per similarita' con ATesto, in ordine
    // decrescente. Una chiamata per l'embedding della domanda e una a Postgres (scansione
    // esatta di mcp_tool_indice: con poche centinaia di righe e' piu' veloce di un indice
    // approssimato).
    // Si selezionano PROVIDER e non tool singoli perche' i tool di una famiglia (es.
    // ricette) sono passi di un flusso a catena: se uno e' il migliore, vengono inclusi
    // tutti con il loro punteggio reale, e la famiglia arriva intera o non arriva.
    // La selezione e' per rango dei provider e non per soglia: il modello di embedding
    // comprime le similarita' in una fascia altissima (0.92-1.00 anche per frasi senza
    // relazione), quindi nessuna soglia assoluta separa pertinente da non pertinente.
    // ASoglia resta solo come rete di sicurezza (scarta righe anomale).
    // AMargineProvider: il rango da solo ammette sempre un secondo provider, anche se e'
    // rumore. Sui dati osservati (logs/selezione_tool.log) la distanza fra primo e secondo
    // provider e' sotto 0,03 quando il secondo e' pertinente e sopra 0,04 quando e' rumore:
    // un margine di 0,035 li separa. Il primo provider e' sempre ammesso (altrimenti il
    // turno ripiegherebbe sull'intero catalogo); dal secondo in poi serve anche restare
    // entro il margine dal primo.
    // Il margine e' relativo al miglior provider di questo turno, ASoglia e' assoluta. Non
    // risolve i casi in cui e' gia' sbagliato il primo provider (domande di continuazione
    // come "Ho scelto l'id 3"): se ne occupa TServizioAgente.ProviderUsatiDiRecente.
    class function Cerca(const ATesto: string; AMaxProvider: Integer = 2;
      ASoglia: Double = 0.5; AMargineProvider: Double = 0.035): TArray<TToolPertinente>;

    // Come Cerca, ma restituisce in ATuttiIPunteggi anche il punteggio di tutti i tool
    // letti dall'indice, non solo di quelli scelti: serve alla diagnostica per turno. Non
    // fa query in piu'.
    class function CercaConPunteggi(const ATesto: string;
      out ATuttiIPunteggi: TArray<TToolPertinente>; AMaxProvider: Integer = 2;
      ASoglia: Double = 0.5; AMargineProvider: Double = 0.035): TArray<TToolPertinente>;

    // Retrieval per azione: per ogni testo di ATesti, il punteggio di tutti i tool
    // dell'indice in ordine decrescente (a parita', per nome). Il punteggio di un tool e'
    // quello della sua frase migliore.
    // Una sola richiesta di embedding per tutti i testi (OttieniBatch) e poi una query per
    // testo. Nessuna selezione qui: i candidati li sceglie TRetrieverPiano.
    class function PunteggiPerTesti(const ATesti: TArray<string>): TArray<TArray<TToolPertinente>>;
  end;

implementation

uses
  System.SysUtils,
  System.JSON,
  System.Hash,
  Data.DB,
  DbU,
  uLog,
  uConfig,
  uCatalogoTool,
  uRegistroProviderMCP,
  uFrasiEsempioTool,
  uServizioEmbedding;

type
  // Riga pronta da scrivere in mcp_tool_indice: a differenza di TFraseEsempio porta
  // provider risolto, hash ed embedding (calcolato o preso dalla cache). Tipo privato di
  // questa unit.
  TRigaIndice = record
    NomeTool: string;
    Provider: string;
    TipoTesto: string; // 'descrizione' oppure 'esempio', vedi CHECK a DB
    Testo: string;
    HashTesto: string;
    Embedding: TArray<Single>; // nil finche' non calcolato o riusato
  end;

// Provider a cui appartiene ANomeTool; stringa vuota se nessuno lo rivendica (refuso in
// TFrasiEsempioTool o tool non registrato in TRegistroProviderMCP). Non solleva eccezioni:
// un buco nel retrieval degrada la fase 1 ma non deve fermare l'avvio. Delega a
// TRegistroProviderMCP.ProviderDiTool, usata anche da
// TServizioAgente.ProviderUsatiDiRecente.
function TrovaProvider(const ANomeTool: string): string;
begin
  Result := TRegistroProviderMCP.ProviderDiTool(ANomeTool);
end;

// Converte un vettore nel letterale testuale di pgvector '[v1,v2,...]'. FireDAC non conosce
// il tipo vector: il parametro viaggia come stringa e il cast ::vector nella SQL fa il
// resto.
function VettoreASQL(const AEmbedding: TArray<Single>): string;
var
  LBuilder: TStringBuilder;
  i: Integer;
begin
  LBuilder := TStringBuilder.Create;
  try
    LBuilder.Append('[');
    for i := 0 to High(AEmbedding) do
    begin
      if i > 0 then
        LBuilder.Append(',');
      // FloatToStr usa il separatore decimale del sistema (virgola in Italia): senza
      // TFormatSettings.Invariant il letterale sarebbe illegale per pgvector.
      LBuilder.Append(FloatToStr(AEmbedding[i], TFormatSettings.Invariant));
    end;
    LBuilder.Append(']');
    Result := LBuilder.ToString;
  finally
    LBuilder.Free;
  end;
end;

// Operazione inversa: legge il testo di una colonna vector (SELECT embedding::text) e lo
// riporta a TArray<Single>. Serve a ripopolare la cache (Sincronizza, passo 2).
function SQLAVettore(const ATesto: string): TArray<Single>;
var
  LInterno: string;
  LParti: TArray<string>;
  i: Integer;
begin
  LInterno := ATesto.Trim(['[', ']']);
  if LInterno = '' then
    Exit(nil);

  LParti := LInterno.Split([',']);
  SetLength(Result, Length(LParti));
  for i := 0 to High(LParti) do
    Result[i] := StrToFloat(LParti[i], TFormatSettings.Invariant);
end;

// Formato del testo per il modello di embedding (multilingual-e5-large-instruct, vedi la
// scheda del modello):
// - lato query: template "Instruct: {compito}" a capo "Query: {testo}", dove {compito}
// descrive il tipo di ricerca (COMPITO_RETRIEVAL);
// - lato documento: il testo cosi' com'e', senza prefisso.
// Non e' uguale per tutte le varianti E5 (le "base" usano "query: " e "passage: "):
// cambiando modello vanno riscritte queste due funzioni, altrimenti la qualita' del
// retrieval peggiora senza errori.
// Sono usate anche per HashTesto: l'hash copre il testo davvero inviato, quindi se cambia
// la convenzione Sincronizza ricalcola le righe invece di riusare embedding calcolati con
// un'altra.
const
  // Frase fissa che descrive il tipo di operazione (trovare il tool giusto per una
  // richiesta), non la domanda specifica. In inglese, come negli esempi ufficiali del
  // modello.
  COMPITO_RETRIEVAL_TOOL =
    'Given a user request in Italian, retrieve the tool description or ' +
    'example phrase that best matches the action the user wants to perform';

function TestoPerIndicizzazione(const ATesto: string): string;
begin
  Result := ATesto;
end;

function TestoPerQuery(const ATesto: string): string;
begin
  // #10 esplicito (LF) e non sLineBreak: su Windows sarebbe CRLF, mentre l'esempio
  // ufficiale del modello usa il solo LF.
  Result := 'Instruct: ' + COMPITO_RETRIEVAL_TOOL + #10 + 'Query: ' + ATesto;
end;

// L'hash che decide il riuso dalla cache dipende anche dal modello che ha calcolato
// l'embedding: due modelli danno vettori diversi per lo stesso testo. Senza il nome del
// modello, cambiando EmbeddingModel si riuserebbero in silenzio embedding del modello
// vecchio mescolati a quelli nuovi. Il nome entra nell'hash e non nel testo inviato al
// modello.
function HashDiIndicizzazione(const ATestoPrefissato: string): string;
begin
  Result := THashSHA2.GetHashString(
    TConfig.GetInstance.EmbeddingModel + '|' + ATestoPrefissato,
    THashSHA2.TSHA2Version.SHA256);
end;

class procedure TIndiceEmbeddingTool.Sincronizza;
var
  LDesiderate: TList<TRigaIndice>;
  LRiga: TRigaIndice;
  LFrase: TFraseEsempio;
  LDefinizioni: TJSONArray;
  LVoceTool, LFunzione: TJSONObject;
  LNomeTool, LDescrizione, LProvider: string;
  i: Integer;
  LCache: TDictionary<string, TArray<Single>>;
  LEmbeddingCache: TArray<Single>;
  LAutoQuery: TAutoQuery;
  LDaCalcolare: TList<Integer>; // indici in LDesiderate che non erano in cache
  LTestiDaCalcolare: TArray<string>;
  LEmbeddingCalcolati: TArray<TArray<Single>>;
  LQueries: TArray<string>;
  LParamsList: TArray<TArray<Variant>>;
  LScartate, LRiusate, LCalcolate: Integer;
begin
  LDesiderate := TList<TRigaIndice>.Create;
  LCache := TDictionary<string, TArray<Single>>.Create;
  LDaCalcolare := TList<Integer>.Create;
  try
    // 1. Riga "descrizione" per ogni tool registrato oggi (da TCatalogoTool, mai ricopiata
    // a mano).
    LScartate := 0;
    LDefinizioni := TCatalogoTool.Definizioni;
    for i := 0 to LDefinizioni.Count - 1 do
    begin
      LVoceTool := LDefinizioni.Items[i] as TJSONObject;
      LFunzione := LVoceTool.GetValue('function') as TJSONObject;
      LNomeTool := LFunzione.GetValue<string>('name');
      LDescrizione := LFunzione.GetValue<string>('description');

      LProvider := TrovaProvider(LNomeTool);
      if LProvider = '' then
      begin
        TLog.Write('TIndiceEmbeddingTool.Sincronizza: il tool "' + LNomeTool +
          '" e'' registrato nel server MCP ma nessun provider in ' +
          'TRegistroProviderMCP lo rivendica. Riga descrizione SCARTATA - ' +
          'aggiungilo all''array NomiTool della Registra corrispondente in ' +
          'uFrmMain.FormCreate.');
        Inc(LScartate);
        Continue;
      end;

      LRiga.NomeTool := LNomeTool;
      LRiga.Provider := LProvider;
      LRiga.TipoTesto := 'descrizione';
      LRiga.Testo := LDescrizione;
      LRiga.HashTesto := HashDiIndicizzazione(TestoPerIndicizzazione(LDescrizione));
      LRiga.Embedding := nil;
      LDesiderate.Add(LRiga);
    end;

    // 2. Riga "esempio" per ogni frase scritta a mano; un refuso produce log e scarto, mai
    // un'eccezione.
    for LFrase in TFrasiEsempioTool.Elenco do
    begin
      LProvider := TrovaProvider(LFrase.NomeTool);
      if LProvider = '' then
      begin
        TLog.Write('TIndiceEmbeddingTool.Sincronizza: la frase di esempio "' +
          LFrase.Testo + '" fa riferimento al tool "' + LFrase.NomeTool +
          '", che non risulta registrato. Riga SCARTATA - controlla il nome ' +
          'in uFrasiEsempioTool.pas (rinominato? rimosso? refuso di battitura?).');
        Inc(LScartate);
        Continue;
      end;

      LRiga.NomeTool := LFrase.NomeTool;
      LRiga.Provider := LProvider;
      LRiga.TipoTesto := 'esempio';
      LRiga.Testo := LFrase.Testo;
      LRiga.HashTesto := HashDiIndicizzazione(TestoPerIndicizzazione(LFrase.Testo));
      LRiga.Embedding := nil;
      LDesiderate.Add(LRiga);
    end;

    if LScartate > 0 then
      TLog.Write('TIndiceEmbeddingTool.Sincronizza: ' + LScartate.ToString +
        ' riga/e scartata/e per provider non risolto (vedi log sopra).');

    // 3. Cache: legge cio' che e' gia' in tabella (hash -> embedding) prima di modificarla.
    LAutoQuery := TDB.GetInstance.getQueryResult(
      'SELECT hash_testo, embedding::text AS embedding_testo FROM mcp_tool_indice');
    try
      while not LAutoQuery.Query.Eof do
      begin
        LCache.AddOrSetValue(
          LAutoQuery.Query.FieldByName('hash_testo').AsString,
          SQLAVettore(LAutoQuery.Query.FieldByName('embedding_testo').AsString));
        LAutoQuery.Query.Next;
      end;
    finally
      LAutoQuery.Free;
    end;

    // 4. Per ogni riga desiderata: riusa l'embedding se l'hash coincide, altrimenti va
    // calcolato.
    for i := 0 to LDesiderate.Count - 1 do
    begin
      LRiga := LDesiderate[i];
      if LCache.TryGetValue(LRiga.HashTesto, LEmbeddingCache) then
      begin
        LRiga.Embedding := LEmbeddingCache;
        LDesiderate[i] := LRiga;
      end
      else
        LDaCalcolare.Add(i);
    end;

    LRiusate := LDesiderate.Count - LDaCalcolare.Count;
    LCalcolate := LDaCalcolare.Count;

    // 5. Una sola chiamata batch per tutto cio' che manca.
    if LDaCalcolare.Count > 0 then
    begin
      SetLength(LTestiDaCalcolare, LDaCalcolare.Count);
      for i := 0 to LDaCalcolare.Count - 1 do
        LTestiDaCalcolare[i] := TestoPerIndicizzazione(LDesiderate[LDaCalcolare[i]].Testo);

      LEmbeddingCalcolati := TServizioEmbedding.OttieniBatch(LTestiDaCalcolare);

      for i := 0 to LDaCalcolare.Count - 1 do
      begin
        LRiga := LDesiderate[LDaCalcolare[i]];
        LRiga.Embedding := LEmbeddingCalcolati[i];
        LDesiderate[LDaCalcolare[i]] := LRiga;
      end;
    end;

    // 6. TRUNCATE + reinsert in un'unica transazione (TDB.ExecuteQueriesInTransaction):
    // l'indice riflette l'elenco desiderato oppure resta com'era.
    SetLength(LQueries, LDesiderate.Count + 1);
    SetLength(LParamsList, LDesiderate.Count + 1);

    LQueries[0] := 'TRUNCATE TABLE mcp_tool_indice';
    LParamsList[0] := nil;

    for i := 0 to LDesiderate.Count - 1 do
    begin
      LRiga := LDesiderate[i];
      LQueries[i + 1] :=
        'INSERT INTO mcp_tool_indice (nome_tool, provider, tipo_testo, testo, embedding, hash_testo) ' +
        'VALUES (:nome_tool, :provider, :tipo_testo, :testo, :embedding::vector, :hash_testo)';
      LParamsList[i + 1] := TArray<Variant>.Create(
        LRiga.NomeTool, LRiga.Provider, LRiga.TipoTesto, LRiga.Testo,
        VettoreASQL(LRiga.Embedding), LRiga.HashTesto);
    end;

    TDB.GetInstance.ExecuteQueriesInTransaction(LQueries, LParamsList);

    TLog.Write(Format(
      'TIndiceEmbeddingTool.Sincronizza completata: %d righe (%d riusate dalla cache, ' +
      '%d ricalcolate con LM Studio, %d scartate).',
      [LDesiderate.Count, LRiusate, LCalcolate, LScartate]));
  finally
    LDaCalcolare.Free;
    LCache.Free;
    LDesiderate.Free;
  end;
end;

class function TIndiceEmbeddingTool.Cerca(const ATesto: string; AMaxProvider: Integer;
  ASoglia: Double; AMargineProvider: Double): TArray<TToolPertinente>;
var
  LTuttiScartati: TArray<TToolPertinente>;
begin
  Result := CercaConPunteggi(ATesto, LTuttiScartati, AMaxProvider, ASoglia,
    AMargineProvider);
end;

class function TIndiceEmbeddingTool.CercaConPunteggi(const ATesto: string;
  out ATuttiIPunteggi: TArray<TToolPertinente>; AMaxProvider: Integer;
  ASoglia: Double; AMargineProvider: Double): TArray<TToolPertinente>;
var
  LVettoreSQL: string;
  LAutoQuery: TAutoQuery;
  LTutti: TList<TToolPertinente>;
  LProviderScelti: TList<string>;
  LRisultati: TList<TToolPertinente>;
  LVoce: TToolPertinente;
  LMiglioreGlobale: Double;
begin
  LVettoreSQL := VettoreASQL(TServizioEmbedding.Ottieni(TestoPerQuery(ATesto)));

  LTutti := TList<TToolPertinente>.Create;
  LProviderScelti := TList<string>.Create;
  LRisultati := TList<TToolPertinente>.Create;
  try
    // Placeholder diversi (:query_vettore_1 e :query_vettore_2): FireDAC lega i parametri
    // per posizione, quindi due occorrenze con lo stesso nome sfaserebbero il binding.
    // MAX() per tool: il punteggio di un tool e' quello della sua frase migliore
    // (descrizione o esempi). HAVING ripete l'espressione perche' Postgres non ammette
    // l'alias del SELECT in HAVING. ASoglia e' la rete di sicurezza descritta sopra.
    // Niente LIMIT: serve il punteggio reale di ogni tool per espandere per provider al
    // passo 2.
    LAutoQuery := TDB.GetInstance.getQueryResult(
      'SELECT nome_tool, provider, ' +
      '       MAX(1 - (embedding <=> :query_vettore_1::vector)) AS similarita ' +
      'FROM   mcp_tool_indice ' +
      'GROUP BY nome_tool, provider ' +
      'HAVING MAX(1 - (embedding <=> :query_vettore_2::vector)) > :soglia ' +
      'ORDER BY similarita DESC',
      [LVettoreSQL, LVettoreSQL, ASoglia]);
    try
      while not LAutoQuery.Query.Eof do
      begin
        LVoce.NomeTool := LAutoQuery.Query.FieldByName('nome_tool').AsString;
        LVoce.Provider := LAutoQuery.Query.FieldByName('provider').AsString;
        LVoce.Similarita := LAutoQuery.Query.FieldByName('similarita').AsFloat;
        LTutti.Add(LVoce);
        LAutoQuery.Query.Next;
      end;
    finally
      LAutoQuery.Free;
    end;

    // Copia dei punteggi completi per il chiamante (vedi CercaConPunteggi).
    ATuttiIPunteggi := LTutti.ToArray;

    // Passo 2: LTutti e' ordinato per similarita' decrescente; si scelgono fino ad
    // AMaxProvider provider distinti (non tool, per tenere insieme famiglie come ricette).
    // Il primo e' sempre ammesso (LMiglioreGlobale = suo punteggio); dal secondo serve
    // anche restare entro AMargineProvider.
    LMiglioreGlobale := 0;
    for LVoce in LTutti do
    begin
      if LProviderScelti.Count >= AMaxProvider then
        Break;
      if LProviderScelti.Contains(LVoce.Provider) then
        Continue;

      if LProviderScelti.Count = 0 then
      begin
        LMiglioreGlobale := LVoce.Similarita;
        LProviderScelti.Add(LVoce.Provider);
      end
      else if LMiglioreGlobale - LVoce.Similarita <= AMargineProvider then
        LProviderScelti.Add(LVoce.Provider);

      // Niente Break se il margine scarta un provider: costa poco continuare ed evita di
      // dover dimostrare che nessun caso limite rompe l'ordinamento.
    end;

    // Passo 3: tutti i tool (con il punteggio reale) dei provider scelti, scorrendo una
    // sola volta LTutti gia' ordinato.
    for LVoce in LTutti do
      if LProviderScelti.Contains(LVoce.Provider) then
        LRisultati.Add(LVoce);

    Result := LRisultati.ToArray;
  finally
    LRisultati.Free;
    LProviderScelti.Free;
    LTutti.Free;
  end;
end;

class function TIndiceEmbeddingTool.PunteggiPerTesti(
  const ATesti: TArray<string>): TArray<TArray<TToolPertinente>>;
var
  LQuery: TArray<string>;
  LVettori: TArray<TEmbedding>;
  LAutoQuery: TAutoQuery;
  LElenco: TList<TToolPertinente>;
  LVoce: TToolPertinente;
  i: Integer;
begin
  SetLength(Result, Length(ATesti));
  if Length(ATesti) = 0 then
    Exit;

  // Stesso prefisso "Instruct: ... Query: ..." delle domande dell'utente.
  SetLength(LQuery, Length(ATesti));
  for i := 0 to High(ATesti) do
    LQuery[i] := TestoPerQuery(ATesti[i]);
  LVettori := TServizioEmbedding.OttieniBatch(LQuery);
  if Length(LVettori) <> Length(ATesti) then
    raise Exception.CreateFmt(
      'PunteggiPerTesti: chiesti %d embedding, ricevuti %d.', [Length(ATesti), Length(LVettori)]);

  LElenco := TList<TToolPertinente>.Create;
  try
    for i := 0 to High(ATesti) do
    begin
      LElenco.Clear;
      // Come in CercaConPunteggi, ma senza HAVING: servono tutti i tool.
      LAutoQuery := TDB.GetInstance.getQueryResult(
        'SELECT nome_tool, provider, ' +
        '       MAX(1 - (embedding <=> :query_vettore::vector)) AS similarita ' +
        'FROM   mcp_tool_indice ' +
        'GROUP BY nome_tool, provider ' +
        'ORDER BY similarita DESC, nome_tool',
        [VettoreASQL(LVettori[i])]);
      try
        while not LAutoQuery.Query.Eof do
        begin
          LVoce.NomeTool := LAutoQuery.Query.FieldByName('nome_tool').AsString;
          LVoce.Provider := LAutoQuery.Query.FieldByName('provider').AsString;
          LVoce.Similarita := LAutoQuery.Query.FieldByName('similarita').AsFloat;
          LElenco.Add(LVoce);
          LAutoQuery.Query.Next;
        end;
      finally
        LAutoQuery.Free;
      end;
      Result[i] := LElenco.ToArray;
    end;
  finally
    LElenco.Free;
  end;
end;

end.
