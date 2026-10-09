unit uRegistroProviderMCP;

(* ============================================================================
  TRegistroProviderMCP -- catalogo delle DESCRIZIONI dei tool provider MCP
  (uno per scenario/dominio: vendite, ricette, navigazione, generazione file,
  ...), pensato per l'orchestratore (TServizioAgente, vedi services/
  uServiziAgente.pas), non per il protocollo MCP in se'.

  -- Il problema che risolve -------------------------------------------------
  Oggi TServizioAgente.EseguiTurnoCompleto legge da TCatalogoTool (common/
  uCatalogoTool.pas) l'elenco COMPLETO dei tool registrati e lo manda a LM
  Studio ad ogni turno, senza distinzione. Il catalogo ha gia' eliminato il
  COSTO DI COSTRUZIONE ripetuto (l'elenco si costruisce una volta sola
  all'avvio), ma non il problema di cui parla questo file: quante
  definizioni finiscono nel contesto del modello. Sono due cose diverse -
  la prima e' lavoro sprecato lato server, la seconda incide sulla qualita'
  delle risposte. Con pochi tool (i quattro provider attuali) va bene; quando il catalogo crescera' (scenario 1 - ritiro/richiamo - non ha
  ancora un tool provider proprio, e altri arriveranno), mandare sempre
  tutto significa piu' token per richiesta e, soprattutto, piu' probabilita'
  che il modello scelga il tool sbagliato fra troppe opzioni simili - un
  problema di ACCURATEZZA, non solo di velocita' (vedi le note di progetto:
  Qwen e' un modello piccolo, 9B, gira in locale).

  L'idea (discussa prima di scrivere questo file): raggruppare i tool per
  provider e dare a ciascun provider una descrizione breve, cosi' che una
  prima chiamata leggera all'LLM possa scegliere QUALI provider sono
  pertinenti alla richiesta dell'utente, PRIMA di costruire l'elenco tool
  "vero" (quello con gli schemi completi) da mandare nella chiamata che fa
  davvero la tool_call. Questo file e' SOLO il catalogo delle descrizioni:
  non contiene ancora la logica di selezione ne' il filtro applicato
  all'elenco tool - quella arriva in un passo successivo, in
  TCatalogoTool/TServizioAgente.

  NOTA: la selezione va decisa UNA VOLTA per turno utente e tenuta fissa
  per tutte le iterazioni del ciclo tool_use, non ricalcolata ad ogni
  iterazione: cambiare l'insieme dei tool a meta' di una sequenza
  significherebbe far sparire dal contesto uno strumento che il modello ha
  appena usato.

  -- Perche' un registro separato e non un campo su IMCPToolProvider -------
  I tool provider di questo progetto non implementano l'interfaccia
  IMCPToolProvider dichiarata in common/uMCPToolProvider.pas (che era
  un'ipotesi di progetto precedente alla libreria MCP di DMVCFramework):
  estendono invece TMCPToolProvider della libreria (MVCFramework.MCP.
  ToolProvider), che non prevede alcun concetto di "descrizione del
  provider" - la libreria conosce solo singoli tool con nome e descrizione
  propri (RegisterToolProvider legge [MCPTool]/[MCPParam] via RTTI,
  RegisterDynamicProvider legge GetDynamicToolDefs). Aggiungere un campo
  del genere alla libreria significherebbe modificare codice di terze
  parti; un registro applicativo separato, sullo stesso modello gia'
  seguito da TRegistroViste per le viste apribili, ottiene lo stesso
  risultato senza toccarla.

  -- Perche' un registro "piatto" e non un dizionario nome->descrizione ----
  Stessa scelta di TRegistroViste: il numero di provider attesi e' piccolo
  (una manciata), quindi una lista lineare con ricerca O(n) resta la
  struttura piu' semplice da leggere - non serve altro.

  -- Ciclo di vita e sicurezza per i thread ----------------------------------
  Registra va chiamato SOLO durante l'avvio, in uFrmMain.FormCreate, subito
  dopo la RegisterToolProvider/RegisterDynamicProvider del provider a cui la
  descrizione si riferisce - stesso principio "wiring esplicito accanto alla
  registrazione reale" gia' seguito per le viste: un provider registrato
  senza la sua voce qui verrebbe escluso da ogni turno, il giorno in cui il
  filtro entrera' in uso, senza che nessun errore lo segnali esplicitamente
  (comportamento silenzioso da evitare). Da quel momento il registro e'
  soltanto letto, in concorrenza da thread diversi: sola lettura di una
  lista gia' popolata e stabile, intrinsecamente sicura senza lock.
  ============================================================================ *)

interface

uses
  System.Generics.Collections;

type
  // Una voce del catalogo. Nome e' una chiave stabile scelta da chi
  // registra (es. 'vendite'), NON il nome della classe Delphi del
  // provider: cosi' si puo' rinominare/riorganizzare la classe senza
  // rompere riferimenti salvati altrove (es. la selezione dei provider
  // pertinenti restituita dall'LLM in un turno). Descrizione e' il testo
  // che l'LLM legge nella fase di selezione - poche righe, dominio di
  // competenza e quando sceglierlo, non l'elenco dei parametri (quello
  // resta nello schema di ciascun tool). NomiTool sono i nomi dei tool
  // che appartengono a questo provider, cosi' come compaiono in
  // ToolDefinition/GetDynamicToolDefs: e' la chiave che permettera' di
  // filtrare l'elenco tool "vero" a partire dai soli provider scelti.
  TDescrizioneProviderMCP = record
    Nome: string;
    Descrizione: string;
    NomiTool: TArray<string>;
  end;

  TRegistroProviderMCP = class
  private
    class var FProvider: TList<TDescrizioneProviderMCP>;
    class constructor Create;
    class destructor Destroy;
  public
    // Registra un provider. Solleva un'eccezione se il nome e' gia'
    // presente: una doppia registrazione e' quasi certamente un
    // copia-incolla sbagliato in FormCreate - meglio far fallire
    // rumorosamente l'avvio del server che avere due descrizioni in
    // conflitto silenzioso per lo stesso provider. Stessa filosofia del
    // "Duplicate tool name" gia' sollevato da TMCPServer.RegisterToolProvider
    // e di TRegistroViste.Registra per le viste.
    class procedure Registra(const ADescrizione: TDescrizioneProviderMCP); overload;
    class procedure Registra(const ANome, ADescrizione: string;
      const ANomiTool: TArray<string>); overload;

    // Cerca un provider per nome (case-insensitive). False se il nome non
    // e' stato registrato da nessuno.
    class function Find(const ANome: string; out ADescrizione: TDescrizioneProviderMCP): Boolean;

    // Tutti i provider registrati, nell'ordine di registrazione: e' il
    // "menu" che finira' nella fase di selezione (prossimo passo).
    class function Tutte: TArray<TDescrizioneProviderMCP>;

    // Nomi di tutti i tool appartenenti ai provider indicati (per nome),
    // senza duplicati. Pensato per il filtro che TMCPBridge applichera'
    // all'elenco completo dei tool dopo la selezione: il chiamante passa
    // qui i nomi dei provider scelti dall'LLM e ottiene l'insieme dei nomi
    // tool da mantenere. Se ANomiProvider e' vuoto, restituisce un array
    // vuoto (non "tutti i tool"): la decisione su cosa fare quando la
    // selezione e' vuota/non valida spetta al chiamante (fallback
    // esplicito), non a questa funzione.
    class function NomiToolPer(const ANomiProvider: TArray<string>): TArray<string>;

    // Percorso inverso di NomiToolPer: il nome del provider a cui
    // appartiene ANomeTool, cercando fra tutti i provider registrati.
    // Stringa vuota se nessun provider lo rivendica (tool registrato nel
    // server MCP ma dimenticato qui, o refuso di battitura altrove - stesso
    // rischio gia' descritto sopra per NomiToolPer). Nasce come metodo
    // pubblico unico per una logica che prima era duplicata: la usava gia'
    // TrovaProvider in uIndiceEmbeddingTool.pas (per capire a quale
    // provider indicizzare una riga) e ora la usa anche
    // TServizioAgente.ProviderUsatiDiRecente (per capire quali
    // provider sono stati usati di recente in una conversazione).
    class function ProviderDiTool(const ANomeTool: string): string;
  end;

implementation

uses
  System.SysUtils;

{ TRegistroProviderMCP }

class constructor TRegistroProviderMCP.Create;
begin
  FProvider := TList<TDescrizioneProviderMCP>.Create;
end;

class destructor TRegistroProviderMCP.Destroy;
begin
  FProvider.Free;
end;

class procedure TRegistroProviderMCP.Registra(const ADescrizione: TDescrizioneProviderMCP);
var
  LEsistente: TDescrizioneProviderMCP;
begin
  if Find(ADescrizione.Nome, LEsistente) then
    raise Exception.CreateFmt(
      'TRegistroProviderMCP.Registra: il provider "%s" e'' gia'' registrato. Controlla se ' +
      'due chiamate in FormCreate usano lo stesso nome, o se e'' un copia-incolla.',
      [ADescrizione.Nome]);

  FProvider.Add(ADescrizione);
end;

class procedure TRegistroProviderMCP.Registra(const ANome, ADescrizione: string;
  const ANomiTool: TArray<string>);
var
  LDescrizione: TDescrizioneProviderMCP;
begin
  LDescrizione.Nome := ANome;
  LDescrizione.Descrizione := ADescrizione;
  LDescrizione.NomiTool := ANomiTool;
  Registra(LDescrizione);
end;

class function TRegistroProviderMCP.Find(const ANome: string;
  out ADescrizione: TDescrizioneProviderMCP): Boolean;
var
  LProvider: TDescrizioneProviderMCP;
begin
  for LProvider in FProvider do
    if SameText(LProvider.Nome, ANome) then
    begin
      ADescrizione := LProvider;
      Exit(True);
    end;

  Result := False;
end;

class function TRegistroProviderMCP.Tutte: TArray<TDescrizioneProviderMCP>;
begin
  Result := FProvider.ToArray;
end;

class function TRegistroProviderMCP.NomiToolPer(const ANomiProvider: TArray<string>): TArray<string>;
var
  LRisultato: TList<string>;
  LNomeProvider, LNomeTool: string;
  LDescrizione: TDescrizioneProviderMCP;
begin
  LRisultato := TList<string>.Create;
  try
    for LNomeProvider in ANomiProvider do
      if Find(LNomeProvider, LDescrizione) then
        for LNomeTool in LDescrizione.NomiTool do
          if not LRisultato.Contains(LNomeTool) then
            LRisultato.Add(LNomeTool);

    Result := LRisultato.ToArray;
  finally
    LRisultato.Free;
  end;
end;

class function TRegistroProviderMCP.ProviderDiTool(const ANomeTool: string): string;
var
  LProvider: TDescrizioneProviderMCP;
  LNomeTool: string;
begin
  for LProvider in FProvider do
    for LNomeTool in LProvider.NomiTool do
      if SameText(LNomeTool, ANomeTool) then
        Exit(LProvider.Nome);

  Result := '';
end;

end.
