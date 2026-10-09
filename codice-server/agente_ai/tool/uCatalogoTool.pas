unit uCatalogoTool;

(* ============================================================================
  TCatalogoTool -- elenco dei tool MCP gia' tradotto nel formato "tools"
  dell'API chat/completions compatibile OpenAI, costruito UNA VOLTA SOLA
  all'avvio del server e da li' in poi soltanto letto.

  -- Il problema che risolve -------------------------------------------------
  Prima di questa unit, TServizioAgente.EseguiTurnoCompleto chiamava
  TMCPBridge.ElencoToolPerLLM ad OGNI turno di conversazione. Quella
  funzione non e' gratis: crea un TMCPEndpoint, invoca ToolsList, serializza
  la risposta MCP in testo, la rilegge con System.JSON e ricostruisce da
  capo un TJSONArray con un oggetto "function" per ciascun tool. Tutto
  questo per ottenere, ogni volta, un risultato IDENTICO al precedente: i
  tool provider sono registrati una sola volta in uFrmMain.FormCreate e non
  cambiano piu' per tutta la vita del processo.

  -- Perche' NON e' un allontanamento dal protocollo MCP ---------------------
  E' il contrario, ed e' un punto da riportare in relazione. Nel protocollo
  MCP "tools/list" e' un'operazione pensata per essere chiamata dal client
  UNA VOLTA per sessione e messa in cache: la specifica prevede a questo
  scopo la notifica "notifications/tools/list_changed", che esiste proprio
  per dire al client quando invalidare quella cache. Un client che
  ri-chiedesse l'elenco ad ogni interazione non sarebbe "piu' aderente" al
  protocollo, sarebbe semplicemente un client scritto male.

  Chiamare ToolsList una volta all'avvio e' quindi il comportamento
  idiomatico di un client MCP, non una scorciatoia: la fonte degli schemi
  resta il server MCP (generati via RTTI dagli attributi [MCPTool]/
  [MCPParam] o dichiarati in GetDynamicToolDefs), non una copia scritta a
  mano qui dentro. Cambia solo QUANDO la traduzione avviene, non DA DOVE
  arriva il dato.

  -- Invalidazione -----------------------------------------------------------
  In questo progetto i tool sono fissi a compile-time: sono registrati in
  FormCreate e nessun percorso di codice ne aggiunge o rimuove a runtime,
  quindi la cache non ha bisogno di essere invalidata e non esiste alcun
  emittente di list_changed. Ricostruisci e' esposto lo stesso, per due
  motivi: rende esplicito che la scelta di non invalidare e' consapevole e
  non una dimenticanza, e lascia il gancio pronto se un giorno i tool
  diventassero dinamici (per esempio provider abilitati da configurazione).
  ATTENZIONE: vedi la nota sui thread qui sotto prima di chiamarlo.

  -- Ciclo di vita e sicurezza per i thread ----------------------------------
  Costruisci va chiamato UNA VOLTA, in uFrmMain.FormCreate, DOPO tutte le
  RegisterToolProvider/RegisterDynamicProvider e PRIMA di doStartServer:
  un tool registrato dopo la costruzione del catalogo non comparirebbe mai
  nell'elenco mandato al modello, senza che alcun errore lo segnali.

  Da quel momento il catalogo e' in sola lettura da parte dei worker thread
  Indy, che vi accedono in concorrenza: la lettura di una struttura gia'
  popolata e MAI PIU' MODIFICATA e' intrinsecamente sicura senza lock -
  stesso ragionamento gia' seguito da TRegistroViste e TRegistroProviderMCP.
  E' esattamente questa immutabilita' a rendere Ricostruisci pericoloso a
  server avviato: andrebbe chiamato solo con il server fermo.

  -- Perche' Definizioni NON restituisce un clone ----------------------------
  L'array restituito e' l'array interno, condiviso: il chiamante lo legge e
  NON lo libera (vedi il commento sul metodo). Restituire un clone
  reintrodurrebbe, a ogni turno, buona parte del lavoro che questa unit
  esiste per togliere. Il clone serve comunque piu' a valle, in
  TServizioAgente.PreparaRichiestaLLM, dove la richiesta consegnata al client deve
  possedere i propri oggetti per liberarli con se': quello resta e va bene,
  perche' e' una copia per richiesta HTTP, non una ricostruzione da MCP.
  ============================================================================ *)

interface

uses
  System.JSON;

type
  TCatalogoTool = class
  private
    class var FDefinizioni: System.JSON.TJSONArray;
    class destructor Destroy;
  public
    // Costruisce il catalogo interrogando il server MCP. Da chiamare una
    // volta sola in FormCreate (vedi nota sul ciclo di vita in testa).
    // Solleva un'eccezione se il catalogo risulta vuoto: un server che non
    // espone alcun tool e' quasi certamente una registrazione dimenticata,
    // e fallire all'avvio e' molto meglio che scoprirlo al primo messaggio
    // in chat, dove il sintomo sarebbe un modello che "non usa mai i tool"
    // - un guasto difficile da attribuire alla causa giusta.
    class procedure Costruisci;

    // Ricostruisce il catalogo da MCP. NON chiamare a server avviato: vedi
    // la nota sui thread in testa alla unit.
    class procedure Ricostruisci;

    // Le definizioni dei tool nel formato atteso da LM Studio.
    //
    // L'array restituito e' quello INTERNO, condiviso fra tutti i thread:
    // il chiamante lo passa al client LLM e NON deve liberarlo ne'
    // modificarlo. Se serve una versione modificabile (per esempio per
    // filtrare i tool di un singolo turno, prossimo passo) va clonata
    // esplicitamente dal chiamante.
    class function Definizioni: System.JSON.TJSONArray;

    // Quanti tool contiene il catalogo. Usato nel log di avvio: e' la
    // conferma piu' rapida che la registrazione dei provider e' andata a
    // buon fine.
    class function Conteggio: Integer;

    // True se il catalogo e' gia' stato costruito.
    class function Costruito: Boolean;
  end;

implementation

uses
  System.SysUtils,
  uMCPBridge;

{ TCatalogoTool }

class destructor TCatalogoTool.Destroy;
begin
  FDefinizioni.Free;
end;

class procedure TCatalogoTool.Costruisci;
begin
  // Costruire due volte non e' un errore fatale (basta liberare il vecchio
  // array), ma e' quasi sempre il sintomo di una doppia chiamata in
  // FormCreate: si preferisce fallire rumorosamente, come gia' fa
  // TRegistroProviderMCP.Registra sui nomi duplicati.
  if FDefinizioni <> nil then
    raise Exception.Create(
      'TCatalogoTool.Costruisci: il catalogo e'' gia'' stato costruito. ' +
      'Va chiamato una sola volta, in FormCreate dopo la registrazione dei ' +
      'tool provider. Per una ricostruzione volontaria usa Ricostruisci.');

  FDefinizioni := TMCPBridge.CostruisciElencoToolPerLLM;

  if FDefinizioni.Count = 0 then
  begin
    // Si libera prima di sollevare: altrimenti il catalogo resterebbe in
    // uno stato "costruito ma vuoto" che farebbe fallire anche un
    // eventuale tentativo di ricostruzione con il messaggio sbagliato.
    FreeAndNil(FDefinizioni);
    raise Exception.Create(
      'TCatalogoTool.Costruisci: il server MCP non espone alcun tool. ' +
      'Verifica che le RegisterToolProvider/RegisterDynamicProvider in ' +
      'FormCreate siano eseguite PRIMA di questa chiamata.');
  end;
end;

class procedure TCatalogoTool.Ricostruisci;
begin
  FreeAndNil(FDefinizioni);
  Costruisci;
end;

class function TCatalogoTool.Definizioni: System.JSON.TJSONArray;
begin
  if FDefinizioni = nil then
    raise Exception.Create(
      'TCatalogoTool.Definizioni: catalogo non costruito. Manca la chiamata ' +
      'a TCatalogoTool.Costruisci in uFrmMain.FormCreate, dopo la ' +
      'registrazione dei tool provider.');

  Result := FDefinizioni;
end;

class function TCatalogoTool.Conteggio: Integer;
begin
  if FDefinizioni = nil then
    Result := 0
  else
    Result := FDefinizioni.Count;
end;

class function TCatalogoTool.Costruito: Boolean;
begin
  Result := FDefinizioni <> nil;
end;

end.
