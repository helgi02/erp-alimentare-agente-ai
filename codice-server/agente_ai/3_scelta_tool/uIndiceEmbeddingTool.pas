unit uIndiceEmbeddingTool;

(* ============================================================================
  TIndiceEmbeddingTool -- fase 1 dell'orchestratore: mantiene la tabella
  mcp_tool_indice (scripts/001_pgvector_indice_tool.sql) allineata ai tool
  DAVVERO registrati, e la interroga per trovare quali tool sono pertinenti
  a una domanda utente, cosi' da poter iniettare nel prompt di LM Studio
  solo i loro schemi invece dell'elenco completo.

  -- Le due fonti di verita', e come questa unit le mette insieme ------------
  TCatalogoTool e' la fonte di verita' sui tool REALMENTE esposti (viene da
  TMCPBridge.CostruisciElencoToolPerLLM, lo stesso ToolsList che vedrebbe un
  client MCP esterno): da qui arrivano nome e descrizione di ogni tool,
  senza che vengano mai ricopiati a mano. TFrasiEsempioTool e' dato scritto
  a mano (il registro linguistico che nessuna fonte automatica puo'
  produrre): da qui arrivano le formulazioni utente. TRegistroProviderMCP
  fa da cerniera fra le due: dice a quale provider appartiene ciascun nome
  tool, quindi ogni riga costruita qui - sia che venga dalla prima fonte
  sia che venga dalla seconda - passa da quella cerniera, e una riga il cui
  nome tool non e' riconosciuto da NESSUN provider viene scartata con un
  log invece di essere scritta in tabella. E' cosi' che l'indice resta
  garantito allineato al server MCP: non per disciplina di chi scrive
  uFrasiEsempioTool.pas, ma perche' un disallineamento non passa qui senza
  lasciare traccia in log.

  -- L'algoritmo di Sincronizza (perche' non e' un semplice DROP/INSERT) -----
  Ricalcolare tutti gli embedding ad ogni avvio del server sprecherebbe una
  chiamata a LM Studio per ogni frase ad OGNI riavvio, anche quando nessun
  testo e' cambiato dall'ultima volta - un costo che durante lo sviluppo,
  con riavvii frequenti, si sente. Sincronizza invece:
    1. costruisce l'elenco DESIDERATO di righe (descrizioni dei tool reali +
       frasi di esempio), con il relativo hash SHA-256 del testo;
    2. legge dalla tabella, PRIMA di modificarla, la mappa hash -> embedding
       gia' presente: e' la cache;
    3. per ogni riga desiderata, riusa l'embedding dalla cache se l'hash
       coincide, altrimenti la segna "da calcolare";
    4. chiama TServizioEmbedding.OttieniBatch UNA VOLTA per tutto cio' che
       manca (non una chiamata per frase);
    5. TRUNCATE + reinsert dell'intero elenco desiderato in un'unica
       transazione (TDB.ExecuteQueriesInTransaction): o l'indice riflette
       per intero l'elenco desiderato, o resta esattamente come prima.
  Il TRUNCATE finale non e' in tensione col punto 2: gestisce da solo anche
  "ho tolto una frase o un tool" (quella riga semplicemente non viene
  reinserita), senza bisogno di una DELETE...WHERE NOT IN separata.

  -- Ciclo di vita ------------------------------------------------------------
  Sincronizza va chiamata in FormCreate, DOPO TCatalogoTool.Costruisci (le
  serve l'elenco tool reale per convalidare/generare le righe descrizione)
  e prima di doStartServer. A differenza di TCatalogoTool.Costruisci, e'
  sicura da richiamare piu' volte nello stesso processo: non lascia stato
  residuo, ogni chiamata riparte dalla lettura della tabella e da un
  TRUNCATE, quindi una Ricostruisci esplicita non serve.
  ============================================================================ *)

interface

uses
  System.Generics.Collections;

type
  // Un tool trovato con la sua similarita' rispetto alla domanda
  // dell'utente. E' quello che restituisce Cerca.
  TToolPertinente = record
    NomeTool: string;
    Provider: string;
    Similarita: Double;
  end;

  TIndiceEmbeddingTool = class
  public
    class procedure Sincronizza;

    // Tutti i tool dei migliori AMaxProvider PROVIDER per similarita' con
    // ATesto, in ordine di similarita' decrescente. Una chiamata a LM
    // Studio (embedding della domanda) e una a Postgres (scansione di
    // mcp_tool_indice - con poche centinaia di righe una scansione
    // sequenziale esatta e' piu' veloce di un indice approssimato, vedi lo
    // script SQL che crea la tabella).
    //
    // -- Perche' si selezionano PROVIDER e non TOOL singoli --------------
    // Prima versione: i migliori AMax tool per punteggio individuale.
    // Funzionava per tool "isolati" (es. apri_vista), ma non per famiglie
    // come ricette (uRicetteToolProvider.pas): get_ricetta_prodotto_finito
    // -> cerca_componenti_ricetta -> simula_adattamento_ricetta ->
    // applica_adattamento_ricetta sono passi di UN flusso a catena (il
    // codice allergene del primo alimenta il secondo, i candidati del
    // secondo alimentano il terzo, ...). Scegliere solo il tool con il
    // punteggio migliore di quella famiglia e scartare gli altri tre
    // spezzerebbe il flusso a meta'; e siccome ogni tool ha frasi di
    // esempio proprie, non c'e' garanzia che tutti e quattro superino una
    // selezione a livello di singolo tool nella stessa domanda. Selezionare
    // per PROVIDER risolve la cosa alla radice: se un tool ricette e' il
    // migliore, TUTTI i tool ricette vengono inclusi con il loro punteggio
    // reale (gia' letto da mcp_tool_indice, non un segnaposto) - la
    // famiglia arriva sempre intera o non arriva affatto.
    //
    // -- Perche' AMaxProvider e non ASoglia come meccanismo di selezione -
    // Il test isolato in scripts/test_isolamento_embedding.py ha mostrato
    // che multilingual-e5-small comprime QUALSIASI coppia di frasi
    // italiane in una fascia di similarita' altissima (0.92-1.00 anche per
    // frasi senza alcuna relazione semantica) - una caratteristica nota
    // dei modelli di embedding "small", non un bug della pipeline (vedi
    // anche il commento su TestoPerQuery/TestoPerIndicizzazione). Con
    // quella compressione una domanda fuori dominio puo' ottenere un
    // punteggio PIU' alto di un match legittimo: non esiste nessun valore
    // di soglia assoluta che separi correttamente "pertinente" da "non
    // pertinente" su questa scala. ASoglia resta come rete di sicurezza
    // puramente difensiva (scarta solo righe patologiche, es. un embedding
    // quasi ortogonale) - la vera selezione e' il rango dei provider.
    //
    // -- AMargineProvider: perche' il rango da solo non basta -----------
    // Il rango fisso (i primi AMaxProvider provider, punto e basta) ha un
    // difetto osservato in produzione (vedi logs/selezione_tool.log,
    // analizzato per intero prima di questa modifica): su una domanda che
    // riguarda un solo dominio ("ok, ora genera il csv", dopo aver gia'
    // ottenuto le vendite), il secondo provider per punteggio non e' quasi
    // mai vuoto - c'e' sempre un secondo classificato, anche quando e'
    // chiaramente rumore (es. "ricette" agganciato da "ok, ora genera il
    // csv" con punteggio 0,851 contro lo 0,913 di "file", il provider
    // davvero pertinente). Il rango lo ammette comunque, perche' guarda
    // solo la posizione in classifica, mai la distanza dal primo.
    //
    // Sulle 39 righe reali di selezione_tool.log raccolte fino ad ora, la
    // distanza fra il punteggio del provider migliore e quello del
    // secondo si divide in due fasce nettamente separate:
    //   - quando il secondo provider e' davvero pertinente alla domanda
    //     (es. "esporta in csv le vendite di marzo": servono sia "vendite"
    //     che "file"), la distanza resta sotto 0,03 (osservato: 0,001-0,026);
    //   - quando e' rumore (es. "ok, ora genera il csv/pdf", "voglio
    //     modificare la ricetta della colomba"), la distanza supera 0,04
    //     (osservato: 0,045-0,088).
    // Un margine a 0,035 - a meta' fra le due fasce, con un margine di
    // sicurezza da entrambi i lati - separa i due casi senza aver mai
    // scartato, sul campione osservato, un provider davvero pertinente.
    //
    // Il PRIMO provider (il migliore in assoluto) e' sempre ammesso,
    // margine o no: deve sempre restare disponibile almeno un provider,
    // altrimenti un turno andrebbe erroneamente in fallback sull'intero
    // catalogo (vedi TServizioAgente.SelezionaToolPerDomanda) anche quando la
    // domanda un dominio pertinente ce l'ha eccome, solo che e' il primo.
    // Dal secondo provider in poi, invece, l'ammissione richiede ANCHE di
    // restare entro AMargineProvider dal punteggio del primo - non basta
    // piu' arrivare in classifica.
    //
    // Questo margine e' un meccanismo DIVERSO da ASoglia (sopra): ASoglia
    // taglia sui punteggi ASSOLUTI (una rete di sicurezza contro righe
    // patologiche), il margine taglia sulla distanza RELATIVA dal miglior
    // provider di QUESTO turno - motivo per cui funziona anche se il
    // livello generale dei punteggi cambiasse (es. cambiando ancora il
    // modello di embedding, vedi il commento su TestoPerQuery). Non risolve
    // (e non deve risolvere) i casi in cui e' il PRIMO provider ad essere
    // gia' sbagliato: quello e' il problema delle domande di continuazione
    // senza contenuto di dominio ("Ho scelto l'id 3", "150g"), gia' coperto
    // altrove da TServizioAgente.ProviderUsatiDiRecente, non da qui.
    class function Cerca(const ATesto: string; AMaxProvider: Integer = 2;
      ASoglia: Double = 0.5; AMargineProvider: Double = 0.035): TArray<TToolPertinente>;

    // Stessa selezione di Cerca, ma restituisce in ATuttiIPunteggi anche il
    // punteggio di TUTTI i tool letti dall'indice (ordinati per similarita'
    // decrescente), non solo di quelli dei provider scelti. Serve alla
    // diagnostica per turno (vedi TDiagnosticaTurno in uServiziAgente.pas):
    // per dimostrare che la selezione e' ragionevole bisogna vedere anche i
    // punteggi dei tool SCARTATI, che Cerca da sola non espone. Non fa
    // nessuna query in piu': i punteggi c'erano gia' (passo 1 di Cerca).
    class function CercaConPunteggi(const ATesto: string;
      out ATuttiIPunteggi: TArray<TToolPertinente>; AMaxProvider: Integer = 2;
      ASoglia: Double = 0.5; AMargineProvider: Double = 0.035): TArray<TToolPertinente>;

    // Tappa 5 del porting del pianificatore (retrieval per AZIONE).
    // Per ogni testo di ATesti, il punteggio di TUTTI i tool dell'indice,
    // in ordine decrescente (a parita' di punteggio, per nome). Il punteggio
    // di un tool e' quello della sua frase migliore, come in CercaConPunteggi.
    // UNA sola richiesta di embedding per tutti i testi (OttieniBatch): con
    // N azioni e' una chiamata a LM Studio, non N. Poi una query per testo.
    // Nessuna selezione qui (ne' provider, ne' soglia): i candidati di ogni
    // passo li sceglie TRetrieverPiano (agente_ai/3_scelta_tool/uRetrieverPiano.pas).
    // Stessa funzione di IndiceDB.punteggi nel prototipo (indice_db.py).
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
  // Una riga "risolta e pronta" da scrivere in mcp_tool_indice: a
  // differenza di TFraseEsempio (dato grezzo, solo nome tool + testo),
  // questa porta gia' il provider risolto, l'hash e - una volta calcolato
  // o riusato dalla cache - l'embedding. Tipo privato di questa unit: chi
  // sta fuori ha bisogno solo di TToolPertinente (il risultato di Cerca).
  TRigaIndice = record
    NomeTool: string;
    Provider: string;
    TipoTesto: string; // 'descrizione' oppure 'esempio', vedi CHECK a DB
    Testo: string;
    HashTesto: string;
    Embedding: TArray<Single>; // nil finche' non calcolato o riusato
  end;

// Nome del provider a cui appartiene ANomeTool. Stringa vuota se nessun
// provider lo rivendica: succede per un refuso in TFrasiEsempioTool (nome
// tool sbagliato/rinominato) o per un tool registrato nel server MCP ma
// dimenticato in TRegistroProviderMCP (stesso rischio gia' descritto nei
// commenti di quella unit). Il chiamante decide cosa fare di una stringa
// vuota - qui non si solleva eccezione: un buco nel retrieval degrada la
// fase 1, non deve fermare l'avvio del server (stesso principio gia'
// applicato a TToolProviderApp.Istruzioni).
//
// Delega a TRegistroProviderMCP.ProviderDiTool invece di scandire
// direttamente TRegistroProviderMCP.Tutte: stessa logica che serve anche a
// TServizioAgente.ProviderUsatiDiRecente (vedi uServiziAgente.pas)
// per i provider usati di recente in una conversazione - un'unica
// implementazione invece di due copie che potrebbero disallinearsi.
function TrovaProvider(const ANomeTool: string): string;
begin
  Result := TRegistroProviderMCP.ProviderDiTool(ANomeTool);
end;

// Converte un vettore Delphi nella sintassi testuale che pgvector si
// aspetta per un letterale di tipo vector: '[v1,v2,...]'. FireDAC non
// conosce il tipo "vector" (non e' uno dei tipi che il driver PG mappa
// nativamente), quindi il parametro viaggia come stringa e il cast
// "::vector" nella SQL fa il resto lato server.
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
      // FloatToStr dipende dal FormatSettings di sistema (virgola vs
      // punto come separatore decimale): senza TFormatSettings.Invariant
      // qui il letterale sarebbe illegale per pgvector su qualunque
      // macchina con locale italiano - stesso genere di bug gia' evitato
      // altrove nel progetto passando per un parsing esplicito invece che
      // per le funzioni legate al locale (vedi ParseDataISO in
      // uVenditeToolProvider.pas).
      LBuilder.Append(FloatToStr(AEmbedding[i], TFormatSettings.Invariant));
    end;
    LBuilder.Append(']');
    Result := LBuilder.ToString;
  finally
    LBuilder.Free;
  end;
end;

// Percorso inverso: legge il testo restituito da Postgres per una colonna
// vector (SELECT ... embedding::text, per non dipendere da come FireDAC
// mapperebbe un tipo che non riconosce) e lo riporta a un TArray<Single>.
// Usata solo per ripopolare la cache delle righe gia' presenti in tabella
// (vedi Sincronizza, passo 2).
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

// La famiglia di modelli E5 e' stata addestrata aspettandosi un formato
// diverso a seconda che il testo sia CIO' CHE SI CERCA o CIO' IN CUI SI
// CERCA: senza rispettarlo il modello funziona comunque (non da' errore),
// ma la qualita' del retrieval peggiora sensibilmente, perche' il vettore
// prodotto non e' quello per cui il modello e' stato ottimizzato. Le due
// funzioni sono il SOLO punto da cambiare se in futuro cambiasse ancora il
// modello configurato in EmbeddingModel (config.ini) - vedi pero' la nota
// sotto: la convenzione NON e' la stessa per tutte le varianti E5.
//
// -- Perche' qui NON c'e' piu' "passage: "/"query: " ------------------------
// Quel prefisso e' la convenzione delle varianti E5 "base" (usata da
// multilingual-e5-small, il modello con cui questo file e' stato scritto
// all'inizio). Il modello ora configurato,
// text-embedding-multilingual-e5-large-instruct, e' la variante
// "instruct" della stessa famiglia e usa una convenzione DIVERSA (scheda
// del modello, huggingface.co/intfloat/multilingual-e5-large-instruct):
// - lato query: un template "Instruct: {compito}
//Query: {testo}", dove
//   {compito} e' una frase che descrive IL TIPO di ricerca (non cambia
//   fra una domanda e l'altra - vedi COMPITO_RETRIEVAL sotto);
// - lato passage/documento: il testo COSI' COM'E', senza alcun prefisso
//   ("No need to add instruction for retrieval documents", testuale
//   nella scheda del modello).
// Se in futuro EmbeddingModel tornasse a una variante E5 "base" (o
// cambiasse famiglia, es. bge), queste due funzioni vanno riscritte di
// nuovo secondo LA CONVENZIONE DI QUEL modello specifico - non e' un
// dettaglio universale della famiglia E5, e sbagliarlo non da' errore,
// degrada solo silenziosamente la qualita' del retrieval (esattamente il
// problema che l'introduzione di questi prefissi doveva risolvere).
//
// Deliberatamente usate anche per calcolare HashTesto (non solo per la
// chiamata a LM Studio, vedi Sincronizza e HashDiIndicizzazione): l'hash
// cattura cosi' il testo EFFETTIVAMENTE mandato al modello, non la frase
// grezza. Se un domani cambiasse la convenzione qui sotto, l'hash
// cambierebbe con lei (e con il nome del modello, vedi
// HashDiIndicizzazione) e Sincronizza ricalcolerebbe da sola tutte le
// righe invece di riusare dalla cache embedding calcolati sotto una
// convenzione ormai diversa.
const
  // Frase unica che descrive IL TIPO di operazione (recupero del tool
  // giusto data una richiesta utente), non la domanda specifica - quella
  // arriva come {testo} nel template. In inglese perche' gli esempi
  // ufficiali della scheda del modello sono in inglese anche per query in
  // lingue diverse (il modello e' multilingue sui testi, non e' detto lo
  // sia altrettanto sulle istruzioni - nessuna indicazione contraria
  // nella documentazione, quindi si segue l'esempio ufficiale).
  COMPITO_RETRIEVAL_TOOL =
    'Given a user request in Italian, retrieve the tool description or ' +
    'example phrase that best matches the action the user wants to perform';

function TestoPerIndicizzazione(const ATesto: string): string;
begin
  Result := ATesto;
end;

function TestoPerQuery(const ATesto: string): string;
begin
  // #10 esplicito (LF), non sLineBreak: su Windows sLineBreak e' CRLF,
  // mentre l'esempio ufficiale della scheda del modello costruisce la
  // stringa in Python con un singolo '\n' - restare fedeli byte per byte
  // alla convenzione di training, invece che all'a-capo di piattaforma.
  Result := 'Instruct: ' + COMPITO_RETRIEVAL_TOOL + #10 + 'Query: ' + ATesto;
end;

// L'hash che decide se Sincronizza puo' riusare un embedding dalla cache
// (vedi il passo 2/3 di Sincronizza) deve dipendere anche da QUALE modello
// lo ha calcolato, non solo dal testo: due modelli diversi producono
// vettori diversi per lo stesso identico testo (dimensioni diverse,
// spazio semantico diverso), quindi un embedding calcolato con un modello
// non e' valido - non solo "impreciso" - se il modello configurato e'
// cambiato. Senza questo, cambiare EmbeddingModel in config.ini e
// riavviare il server farebbe TROVARE hash identici in cache (il testo
// non e' cambiato) e RIUSARE in silenzio embedding del modello vecchio
// mescolati a quelli del nuovo: un disallineamento che pgvector non ha
// modo di segnalare (i vettori restano comunque validi numericamente,
// solo semanticamente incoerenti fra loro). Includere il nome del modello
// QUI (non dentro TestoPerIndicizzazione/TestoPerQuery) e' deliberato: il
// nome del modello non deve mai finire nel testo davvero mandato a LM
// Studio, solo nell'hash che decide la cache.
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
    // --- 1. Una riga 'descrizione' per ogni tool DAVVERO registrato oggi.
    // Fonte: TCatalogoTool, cioe' lo stesso ToolsList che vedrebbe un
    // client MCP esterno - nessuna descrizione viene ricopiata a mano. ---
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

    // --- 2. Una riga 'esempio' per ogni frase scritta a mano, con la
    // stessa convalida e lo stesso trattamento in caso di refuso: log e
    // scarto, mai un'eccezione che fermi l'avvio del server. -------------
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

    // --- 3. Cache: leggi cio' che e' GIA' in tabella (hash -> embedding),
    // PRIMA di modificarla, cosi' da non richiamare LM Studio per testo
    // che non e' cambiato dal sync precedente. ---------------------------
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

    // --- 4. Per ogni riga desiderata: riusa l'embedding dalla cache se
    // l'hash coincide, altrimenti segnala che va calcolato. ---------------
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

    // --- 5. Un'UNICA chiamata batch a LM Studio per tutto cio' che manca -
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

    // --- 6. TRUNCATE + reinsert in un'unica transazione: o l'indice
    // riflette per intero l'elenco desiderato, o (in caso di errore) resta
    // esattamente come prima - mai a meta' strada. Riusa
    // TDB.ExecuteQueriesInTransaction, pensato apposta per questo genere
    // di operazione (vedi il commento in testa a quel metodo in DbU.pas). -
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
  // Comportamento invariato: chi non ha bisogno dei punteggi completi
  // continua a chiamare Cerca come prima.
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
    // Placeholder ripetuto (":query_vettore_1" e ":query_vettore_2"),
    // NON lo stesso nome due volte: FireDAC lega i valori per posizione
    // (Params[i] nell'ordine in cui i nomi compaiono nella query), quindi
    // due occorrenze con lo stesso nome collasserebbero su un solo
    // parametro e sfaserebbero il binding di tutti quelli successivi -
    // stessa convenzione gia' seguita altrove nel progetto (vedi il
    // commento su BuildPlaceholders in uServiziVendite.pas).
    //
    // MAX() raggruppato per tool: il punteggio di un tool e' quello della
    // sua frase migliore (descrizione o uno qualsiasi degli esempi) - vedi
    // il commento in testa allo script SQL sul perche' una riga per frase
    // e non una riga per tool. HAVING ripete l'espressione invece di usare
    // l'alias "similarita": Postgres non ammette un alias del SELECT
    // dentro HAVING (a differenza di ORDER BY, dove invece e' ammesso ed
    // e' usato qui sotto). ASoglia qui e' solo la rete di sicurezza
    // difensiva descritta sopra alla dichiarazione del metodo.
    //
    // NIENTE LIMIT: serve il punteggio REALE di ogni tool (non solo dei
    // migliori) per poter poi espandere per provider al passo 2 - con
    // poche centinaia di righe su una manciata di tool leggerle tutte
    // costa trascurabilmente di piu' che leggerne solo le prime.
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

    // Passo 2: LTutti e' gia' ordinato per similarita' decrescente (ORDER
    // BY sopra). Percorrendolo si scelgono fino ad AMaxProvider PROVIDER
    // DISTINTI - non i primi AMaxProvider TOOL: e' la parte che tiene
    // insieme famiglie come ricette (vedi il commento alla dichiarazione
    // del metodo). Il PRIMO provider incontrato e' sempre ammesso (e' il
    // migliore in assoluto, LMiglioreGlobale = suo punteggio); dal secondo
    // in poi, l'ammissione richiede ANCHE di restare entro AMargineProvider
    // da LMiglioreGlobale - non basta piu' il solo rango. Vedi il commento
    // "AMargineProvider: perche' il rango da solo non basta" alla
    // dichiarazione del metodo per i punteggi reali (da
    // logs/selezione_tool.log) che motivano questa soglia.
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

      // Nota: niente Break se il margine scarta un provider - un provider
      // successivo in classifica (punteggio ancora piu' basso) non potra'
      // MAI rientrare nel margine se questo non c'e' rientrato (LTutti e'
      // ordinato decrescente), ma continuare il ciclo invece di fermarsi
      // qui costerebbe comunque pochissimo (poche decine di righe) ed
      // evita di dover dimostrare separatamente che nessun caso limite
      // rompe questa monotonia.
    end;

    // Passo 3: tutti i tool (con il loro punteggio reale) i cui provider
    // sono fra quelli scelti - l'ordine per similarita' decrescente resta
    // valido perche' si scorre LTutti, gia' ordinato, una sola volta.
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
