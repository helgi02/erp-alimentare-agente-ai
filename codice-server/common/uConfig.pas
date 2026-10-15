unit uConfig;

interface

uses

  System.SysUtils,
  System.Classes,
  System.IniFiles,
  System.IOUtils,
  System.SyncObjs,

  Vcl.Forms;

type

  TDatabaseConfig = record
    Server: string;
    Port: Integer;
    Database: string;
    UserName: string;
    Password: string;
    PoolSize: Integer;
  end;

  // Server di posta in uscita, sezione [SMTP] dell'ini. Usato da
  // TEmailServer (services/Service.EmailServer.pas). Host vuoto = invio
  // email non configurato: il server parte lo stesso, e' l'invio a
  // rispondere con un errore chiaro.
  TConfigSMTP = record
    Host: string;
    // 465 = TLS implicito; 587/25 = STARTTLS (vedi TEmailServer).
    Port: Integer;
    Username: string;
    Password: string;
    // Mittente mostrato al destinatario.
    FromName: string;
    FromAddress: string;
    // Protezioni per prove e dimostrazioni (i clienti dei dati di test hanno
    // indirizzi verosimili, che non devono ricevere nulla):
    //   Simula = True      nessuna connessione al server SMTP: l'email
    //                      viene solo scritta in logs\email_simulate.jsonl
    //                      e l'invio risulta riuscito;
    //   ReindirizzaA <> '' l'email parte DAVVERO, ma verso questo unico
    //                      indirizzo; il destinatario vero finisce
    //                      nell'oggetto ("[per: ...]").
    // Simula ha la precedenza.
    Simula: Boolean;
    ReindirizzaA: string;
  end;

  // Configurazione del modello di CHAT (l'agente), sezione [LLM] dell'ini.
  // Record e non campi sparsi: si legge e si scrive tutta insieme sotto lock
  // (vedi TConfig.Chat / TConfig.SalvaChat), cosi' un passo del turno non
  // puo' mai vedere mezzo aggiornamento (es. endpoint nuovo con il nome del
  // modello vecchio).
  TConfigChat = record
    // URL di base di un'API compatibile OpenAI (es. http://localhost:1234/v1).
    Endpoint: string;
    // Id del modello come compare in <Endpoint>/models; vuoto = modello
    // caricato (LM Studio accetta 'local-model').
    Modello: string;
    // Temperatura opzionale: HaTemperatura = False -> non la si invia e vale
    // il default del motore.
    HaTemperatura: Boolean;
    Temperatura: Double;
    // 0 = nessun tetto esplicito ai token generati. Un tetto e' il
    // paracadute contro i loop di ripetizione: un modello locale piccolo
    // puo' ripetere all'infinito lo stesso paragrafo e far scadere il
    // timeout (errore WinHTTP 12002) invece di fermarsi da solo.
    MaxToken: Integer;
    // Presence penalty opzionale (API OpenAI, -2..2): penalizza i token
    // gia' comparsi nel testo e rompe i loop di ripetizione.
    // HaPresencePenalty = False -> non la si invia e vale il default.
    HaPresencePenalty: Boolean;
    PresencePenalty: Double;
    // Modalita' "thinking" dei modelli che la prevedono (es. Qwen3.5). False
    // = disattivata: per un flusso guidato da tool il ragionamento lungo non
    // serve e sui modelli piccoli puo' finire nel testo della risposta in
    // un ciclo senza fine.
    Pensiero: Boolean;
    // Attesa massima di UNA risposta del modello.
    TimeoutMs: Integer;
  end;

  TConfig = Class

  Private

    // Unica istanza: creata una volta in TFrmMain.FormCreate (che resta
    // proprietario del ciclo di vita, la libera in FormDestroy), ma
    // esposta qui perche' uWebModule e i tool provider (porta HTTP per
    // costruire l'URL /mcp, endpoint/modello LLM per il futuro agente)
    // ne hanno bisogno e non hanno altrimenti modo di raggiungere il
    // campo privato oConfig di TFrmMain.
    class var FInstance: TConfig;

    // "var" esplicito: senza questo, tutti i campi che seguono
    // resterebbero dentro il blocco "class var" appena aperto sopra
    // (diventando anch'essi campi di classe, condivisi, invece che
    // d'istanza) - causa dell'errore E2356 sulle property piu' sotto,
    // che leggono questi campi aspettandosi campi d'istanza normali.
    var
      FIniFileConfig: TIniFile;
    FDatabaseConfig: TDatabaseConfig;
    FHttpPort: Integer;
    // Servizio di EMBEDDING (sezione [Embedding] dell'ini: Endpoint, Model).
    // Serve a TServizioEmbedding per /v1/embeddings (retrieval semantico
    // dei tool, vedi uIndiceEmbeddingTool.pas). E' SEPARATO dal modello di
    // chat: gira sempre dove gira il server (localhost o rete interna),
    // perche' l'indice in pgvector e' legato a questo modello e ogni
    // ricerca lo interroga; il modello di chat ([LLM]) invece puo' stare
    // altrove. I vettori delle domande devono venire dallo STESSO modello
    // che ha costruito l'indice.
    FEmbeddingEndpoint: string;
    FEmbeddingModel: string;
    // Modello di CHAT (l'agente): UNA sola configurazione, letta da
    // [LLM] ChatEndpoint/ChatModel/Temperatura/MaxToken/TimeoutMs.
    //
    // E' il server a chiamare il modello: il frontend non sa quale sia ne'
    // dove giri. Puo' pero' MODIFICARE questa configurazione dal pannello
    // impostazioni della chat (GET/PUT /api/ai/configurazione-llm): il
    // server la valida, la scrive nell'ini (cosi' sopravvive al riavvio) e
    // la applica subito, dal passo successivo.
    //
    // Letta e scritta da piu' thread (una richiesta HTTP per thread), quindi
    // protetta da FLockChat: in Delphi assegnare una stringa mentre un altro
    // thread la legge puo' corrompere il conteggio dei riferimenti.
    FChat: TConfigChat;
    FLockChat: TCriticalSection;
    // --- API cloud per i test di confronto (vedi EndpointAmmesso) ---
    // Lette UNA volta all'avvio e poi solo consultate: si cambiano
    // nell'ini e riavviando il server, MAI dal pannello della chat (che non
    // richiede autenticazione). "class var" perche' le usano funzioni di
    // classe (EndpointAmmesso, ChiaveApiCloud) chiamate anche senza istanza.
    //   [LLM] ConsentiCloud=1          interruttore generale (default 0)
    //   [LLM] HostCloud=api.openai.com l'UNICO host pubblico ammesso
    //   [LLM] ChiaveApi=sk-...         chiave; ha la precedenza la variabile
    //                                  d'ambiente OPENAI_API_KEY
    class var FConsentiCloud: Boolean;
    class var FHostCloud: string;
    class var FChiaveApiIni: string;
    // Chiave per un motore LOCALE o di rete interna che richiede
    // l'autenticazione (es. Unsloth Studio): [LLM] ChiaveApiLocale. Tenuta
    // separata da ChiaveApi, cosi' la chiave OpenAI non finisce mai a un
    // motore locale e quella locale non finisce mai al cloud. Vuota =
    // nessuna intestazione Authorization (LM Studio, Ollama, llama.cpp).
    class var FChiaveApiLocaleIni: string;
    var
    // --- Orchestratore (fase 1: selezione dei tool) e modalita' di test ---
    // Strategia di selezione di default (vedi TModalitaSelezione in
    // uServiziAgente.pas): 'tutti', 'topk_tool', 'provider_rango',
    // 'provider_margine', 'provider_completo' (la versione in produzione).
    FSelezioneModalita: string;
    // Quanti tool singoli tiene la modalita' 'topk_tool' (baseline di
    // confronto per la relazione: la selezione per provider e' nata proprio
    // perche' il top-K di tool singoli spezzava le catene di tool).
    FSelezioneTopKTool: Integer;
    // Motore dell'orchestratore: 'ciclo' (quello di sempre: il modello chiama
    // i tool uno dopo l'altro) oppure 'pianificatore' (piano + esecuzione dal
    // codice, vedi agente_ai/1_turno/uTurnoPianificato.pas). Default 'ciclo'.
    FMotoreOrchestratore: string;
    // Se True, il corpo di POST /api/ai/turni puo' sovrascrivere
    // modalita' di selezione e nome del modello LM Studio (campi opzionali
    // "modalita_selezione" e "modello"). Serve SOLO alla batteria di test:
    // la pagina HTML non manda mai questi campi. Di default e' spento, cosi'
    // in uso normale nessun client puo' cambiare il comportamento
    // dell'orchestratore.
    FAbilitaOverrideTest: Boolean;
    // Cartella dove TFilesToolsProvider (generate_csv/generate_pdf) scrive i
    // file generati su richiesta del modello, servita staticamente da
    // TMVCStaticFilesMiddleware su /export (vedi uWebModule.pas). Sempre un
    // percorso ASSOLUTO dopo Load: se in ini e' relativo, viene risolto
    // rispetto alla cartella dell'eseguibile - stesso criterio gia' usato
    // per GetFullPathFileIni/getFullPathFileLog.
    FExportFolder: string;
    // Base URL con cui comporre il link di download restituito nel
    // tool_result (es. http://localhost:8080/export/xxx.csv). Di default
    // dedotta da HttpPort assumendo client MCP e server sulla stessa
    // macchina (vero per LM Studio locale, coerente con "nessun dato esce
    // dall'infrastruttura locale") - sovrascrivibile in ini con
    // [Server] PublicBaseUrl se in futuro client e server girassero su
    // macchine diverse della stessa rete locale.
    FPublicBaseUrlOverride: string;
    // Letta una volta in Load e poi mai modificata: si puo' leggere da piu'
    // thread senza lock (a differenza di FChat, che il pannello impostazioni
    // puo' riscrivere).
    FSMTP: TConfigSMTP;

    function GetFullPathFileIni: String;
    function GetBaseUrl: string;
    procedure Load;

  public

    Constructor Create;
    Destructor Destroy; override;

    // Solleva un'eccezione se richiamata prima che TFrmMain.FormCreate
    // abbia creato la configurazione - stesso principio di guardia di
    // TDB.GetInstance, qui pero' senza creazione lazy: TConfig legge un
    // file e valida la sua presenza nel costruttore, quindi la creazione
    // implicita "silenziosa" nasconderebbe un errore di avvio.
    class function GetInstance: TConfig;

    property DatabaseConfig: TDatabaseConfig read FDatabaseConfig;
    property SMTP: TConfigSMTP read FSMTP;
    property HttpPort: Integer read FHttpPort;
    property EmbeddingEndpoint: string read FEmbeddingEndpoint;
    property EmbeddingModel: string read FEmbeddingModel;

    // Copia della configurazione del modello di chat (sotto lock). Chi la
    // usa per una chiamata deve leggerla UNA volta e lavorare sulla copia.
    function Chat: TConfigChat;
    // Controlla una configurazione proposta dal client. False + motivo
    // leggibile se non e' accettabile. Non modifica nulla.
    class function ValidaChat(const AChat: TConfigChat; out AMotivo: string): Boolean;
    // L'endpoint e' ammesso solo se punta a questa macchina o alla rete
    // interna (vedi l'implementazione per il perche').
    class function EndpointAmmesso(const AEndpoint: string; out AMotivo: string): Boolean;
    // True se l'endpoint punta a questa macchina o alla rete interna
    // (localhost, 127.x, 10.x, 172.16-31.x, 192.168.x). Chi lo usa per
    // distinguere "locale" da "cloud" puo' ignorare AMotivo.
    class function EndpointLocale(const AEndpoint: string; out AMotivo: string): Boolean;
    // Chiave da mandare come "Authorization: Bearer" all'API cloud: variabile
    // d'ambiente OPENAI_API_KEY, altrimenti [LLM] ChiaveApi. Vuota = nessuna.
    // Non va MAI scritta nei log ne' restituita al browser.
    class function ChiaveApiCloud: string;
    // Chiave da mandare come "Authorization: Bearer" a un endpoint LOCALE
    // (vedi EndpointLocale): [LLM] ChiaveApiLocale. Vuota = nessuna. Come
    // l'altra, non va MAI scritta nei log ne' restituita al browser.
    class function ChiaveApiLocale: string;
    // Scrive la configurazione nell'ini e la rende attiva. Va chiamata solo
    // dopo ValidaChat.
    procedure SalvaChat(const AChat: TConfigChat);
    property SelezioneModalita: string read FSelezioneModalita;
    property SelezioneTopKTool: Integer read FSelezioneTopKTool;
    property MotoreOrchestratore: string read FMotoreOrchestratore;
    property AbilitaOverrideTest: Boolean read FAbilitaOverrideTest;
    property ExportFolder: string read FExportFolder;
    property BaseUrl: string read GetBaseUrl;

  End;

implementation

function TConfig.GetFullPathFileIni: String;
var
  LPathApplication: string;
  LFileNameWithoutExtension: string;
begin

  LPathApplication := ExtractFilePath(Application.ExeName);
  LFileNameWithoutExtension := TPath.GetFileNameWithoutExtension(Application.ExeName);

  Result := LPathApplication + LFileNameWithoutExtension + '.ini';

end;

constructor TConfig.Create;
var
  LIniPath: string;
begin

  inherited;

  LIniPath := GetFullPathFileIni;

  if not TFile.Exists(LIniPath) then
    raise Exception.CreateFmt(
      'File di configurazione non trovato: %s. ' +
      'Copiare config.ini.example, rinominarlo e valorizzare i parametri richiesti.',
      [LIniPath]);

  FIniFileConfig := TIniFile.Create(LIniPath);
  FLockChat := TCriticalSection.Create;

  Load;

  FInstance := Self;

end;

destructor TConfig.Destroy;
begin

  if FInstance = Self then
    FInstance := nil;

  FIniFileConfig.Free;
  FLockChat.Free;

  inherited;

end;

class function TConfig.GetInstance: TConfig;
begin
  if FInstance = nil then
    raise Exception.Create(
      'TConfig.GetInstance chiamato prima che la configurazione fosse ' +
      'caricata (TFrmMain.FormCreate deve eseguire TConfig.Create per primo).');
  Result := FInstance;
end;

procedure TConfig.Load;
var
  LExportFolderIni: string;
  LTemperaturaIni: string;
  LPresenceIni: string;
begin

  // Configurazione di bootstrap: necessaria per stabilire la connessione al DB
  FDatabaseConfig.Server   := FIniFileConfig.ReadString('Database', 'Server', 'localhost');
  FDatabaseConfig.Port     := FIniFileConfig.ReadInteger('Database', 'Port', 5432);
  FDatabaseConfig.Database := FIniFileConfig.ReadString('Database', 'Database', '');
  FDatabaseConfig.UserName := FIniFileConfig.ReadString('Database', 'UserName', '');
  FDatabaseConfig.Password := FIniFileConfig.ReadString('Database', 'Password', '');
  FDatabaseConfig.PoolSize := FIniFileConfig.ReadInteger('Database', 'PoolSize', 10);

  // Configurazione del server HTTP
  FHttpPort := FIniFileConfig.ReadInteger('Server', 'HttpPort', 8080);

  // Cartella di export (generate_csv/generate_pdf): default 'export' accanto
  // all'eseguibile se la chiave non e' presente in ini. TPath.IsRelativePath
  // permette comunque di configurare un percorso assoluto (es. un disco
  // dedicato) senza cambiare codice.
  LExportFolderIni := FIniFileConfig.ReadString('Server', 'ExportFolder', 'export');
  if TPath.IsRelativePath(LExportFolderIni) then
    FExportFolder := TPath.Combine(ExtractFilePath(Application.ExeName), LExportFolderIni)
  else
    FExportFolder := LExportFolderIni;

  // TMVCStaticFilesMiddleware (uWebModule.pas) solleva un'eccezione in fase
  // di creazione se il DocumentRoot non esiste: al primo avvio la cartella
  // potrebbe mancare, quindi la creiamo qui, prima che il WebModule venga
  // istanziato.
  if not TDirectory.Exists(FExportFolder) then
    TDirectory.CreateDirectory(FExportFolder);

  FPublicBaseUrlOverride := FIniFileConfig.ReadString('Server', 'PublicBaseUrl', '');

  // Servizio di embedding (vedi il commento su FEmbeddingEndpoint). Sezione
  // [Embedding]; per compatibilita' con i vecchi ini, se manca si leggono
  // ancora le chiavi [LLM] Endpoint / EmbeddingModel.
  FEmbeddingEndpoint := FIniFileConfig.ReadString('Embedding', 'Endpoint',
    FIniFileConfig.ReadString('LLM', 'Endpoint', 'http://localhost:1234/v1'));
  // Nessun default sensato per un modello di embedding (a differenza
  // dell'endpoint, che e' quasi sempre localhost:1234): stringa vuota se la
  // chiave manca, e TServizioEmbedding solleva un'eccezione chiara al
  // primo utilizzo - non qui, per non far fallire l'avvio del server per
  // una funzionalita' (il retrieval) che non e' ancora sul percorso
  // critico della conversazione.
  FEmbeddingModel := FIniFileConfig.ReadString('Embedding', 'Model',
    FIniFileConfig.ReadString('LLM', 'EmbeddingModel', ''));

  // Modello di chat (vedi il commento su FChat), sezione [LLM]. Indipendente
  // dagli embedding: se ChatEndpoint manca vale il default di LM Studio
  // locale, NON l'endpoint degli embedding (i due servizi possono stare su
  // macchine diverse). Load gira nel costruttore, prima che partano le
  // richieste HTTP: qui il lock non serve.
  FChat.Endpoint := FIniFileConfig.ReadString('LLM', 'ChatEndpoint', 'http://localhost:1234/v1');
  FChat.Modello := FIniFileConfig.ReadString('LLM', 'ChatModel', '');
  // Letta come STRINGA e convertita con il formato invariante (punto
  // decimale): TIniFile.ReadFloat userebbe le impostazioni internazionali
  // di Windows, e su un PC italiano "0.2" non verrebbe riconosciuto.
  LTemperaturaIni := Trim(FIniFileConfig.ReadString('LLM', 'Temperatura', ''));
  FChat.HaTemperatura := (LTemperaturaIni <> '') and
    TryStrToFloat(LTemperaturaIni, FChat.Temperatura, TFormatSettings.Invariant);
  FChat.MaxToken := FIniFileConfig.ReadInteger('LLM', 'MaxToken', 0);
  // Stesso criterio della temperatura: stringa + formato invariante.
  LPresenceIni := Trim(FIniFileConfig.ReadString('LLM', 'PresencePenalty', ''));
  FChat.HaPresencePenalty := (LPresenceIni <> '') and
    TryStrToFloat(LPresenceIni, FChat.PresencePenalty, TFormatSettings.Invariant);
  // Default False: il thinking si attiva solo esplicitamente (Pensiero=1).
  FChat.Pensiero := FIniFileConfig.ReadBool('LLM', 'Pensiero', False);
  FChat.TimeoutMs := FIniFileConfig.ReadInteger('LLM', 'TimeoutMs', 180000);

  // API cloud (vedi EndpointAmmesso): spenta se le chiavi mancano.
  FConsentiCloud := FIniFileConfig.ReadBool('LLM', 'ConsentiCloud', False);
  FHostCloud := LowerCase(Trim(FIniFileConfig.ReadString('LLM', 'HostCloud', 'api.openai.com')));
  FChiaveApiIni := Trim(FIniFileConfig.ReadString('LLM', 'ChiaveApi', ''));
  // Chiave del motore locale (opzionale): letta all'avvio come le altre.
  FChiaveApiLocaleIni := Trim(FIniFileConfig.ReadString('LLM', 'ChiaveApiLocale', ''));

  // Orchestratore: default = comportamento attuale (provider_completo), quindi
  // un ini senza queste chiavi funziona esattamente come prima.
  FSelezioneModalita := FIniFileConfig.ReadString('Orchestratore', 'Modalita', 'provider_completo');
  FSelezioneTopKTool := FIniFileConfig.ReadInteger('Orchestratore', 'TopKTool', 3);
  // Senza questa chiave il server usa il motore di sempre.
  FMotoreOrchestratore := FIniFileConfig.ReadString('Orchestratore', 'Motore', 'ciclo');
  FAbilitaOverrideTest := FIniFileConfig.ReadBool('Test', 'AbilitaOverride', False);

  // Posta in uscita (vedi TConfigSMTP). Nessun default per Host: senza la
  // sezione [SMTP] l'invio email risulta "non configurato".
  FSMTP.Host        := Trim(FIniFileConfig.ReadString('SMTP', 'Host', ''));
  FSMTP.Port        := FIniFileConfig.ReadInteger('SMTP', 'Port', 465);
  FSMTP.Username    := Trim(FIniFileConfig.ReadString('SMTP', 'Username', ''));
  FSMTP.Password    := FIniFileConfig.ReadString('SMTP', 'Password', '');
  FSMTP.FromName    := Trim(FIniFileConfig.ReadString('SMTP', 'FromName', ''));
  // Mittente non indicato = l'utente con cui ci si autentica.
  FSMTP.FromAddress := Trim(FIniFileConfig.ReadString('SMTP', 'FromAddress', FSMTP.Username));
  FSMTP.Simula       := FIniFileConfig.ReadBool('SMTP', 'Simula', False);
  FSMTP.ReindirizzaA := Trim(FIniFileConfig.ReadString('SMTP', 'ReindirizzaA', ''));


end;

function TConfig.GetBaseUrl: string;
begin
  if FPublicBaseUrlOverride <> '' then
    Result := FPublicBaseUrlOverride
  else
    Result := 'http://localhost:' + FHttpPort.ToString;
end;

function TConfig.Chat: TConfigChat;
begin
  FLockChat.Enter;
  try
    Result := FChat;
  finally
    FLockChat.Leave;
  end;
end;

// PERCHE' SOLO INDIRIZZI LOCALI
// Principio del progetto: nessun dato aziendale esce dall'infrastruttura.
// Il modello riceve le domande E i risultati dei tool (vendite, clienti,
// ricette...), quindi un endpoint pubblico li manderebbe fuori. In piu', il
// pannello impostazioni oggi non richiede autenticazione: senza questo
// controllo chiunque apra il sito potrebbe far contattare al server un
// indirizzo qualsiasi di Internet. Si ammettono quindi:
//   - questa macchina: localhost, 127.x.x.x, ::1;
//   - la rete interna (IPv4 privati): 10.x, 172.16-31.x, 192.168.x
//     (es. un PC con GPU nello stesso ufficio o raggiunto via VPN).
// Aprire ad altro (API cloud) e' uno sviluppo futuro, da legare a un utente
// autenticato con il ruolo giusto.
class function TConfig.EndpointLocale(const AEndpoint: string; out AMotivo: string): Boolean;
var
  LResto, LHost: string;
  LParti: TArray<string>;
  LOttetti: array[0..3] of Integer;
  i, p: Integer;
begin
  Result := False;
  AMotivo := '';

  // Schema: solo http/https.
  if AEndpoint.StartsWith('http://', True) then
    LResto := Copy(AEndpoint, 8, MaxInt)
  else if AEndpoint.StartsWith('https://', True) then
    LResto := Copy(AEndpoint, 9, MaxInt)
  else
  begin
    AMotivo := 'l''indirizzo deve iniziare con http:// o https://';
    Exit;
  end;

  // Host = cio' che precede il primo '/', senza la porta. Le credenziali
  // nell'URL (utente@host) non sono ammesse: renderebbero ambiguo l'host.
  p := Pos('/', LResto);
  if p > 0 then
    LResto := Copy(LResto, 1, p - 1);
  if Pos('@', LResto) > 0 then
  begin
    AMotivo := 'l''indirizzo non puo'' contenere credenziali (utente@host)';
    Exit;
  end;
  if LResto.StartsWith('[') then
  begin
    // IPv6 tra parentesi quadre: si ammette solo il loopback [::1].
    p := Pos(']', LResto);
    LHost := Copy(LResto, 2, p - 2);
  end
  else
  begin
    p := Pos(':', LResto);
    if p > 0 then
      LHost := Copy(LResto, 1, p - 1)
    else
      LHost := LResto;
  end;
  LHost := LowerCase(Trim(LHost));

  if (LHost = 'localhost') or (LHost = '::1') then
    Exit(True);

  // IPv4: quattro numeri 0-255.
  LParti := LHost.Split(['.']);
  if Length(LParti) = 4 then
  begin
    for i := 0 to 3 do
      if not TryStrToInt(LParti[i], LOttetti[i]) or (LOttetti[i] < 0) or (LOttetti[i] > 255) then
        Break
      else if i = 3 then
      begin
        if (LOttetti[0] = 127) or (LOttetti[0] = 10) or
           ((LOttetti[0] = 172) and (LOttetti[1] >= 16) and (LOttetti[1] <= 31)) or
           ((LOttetti[0] = 192) and (LOttetti[1] = 168)) then
          Exit(True);
      end;
  end;

  AMotivo := Format('l''indirizzo "%s" non e'' di questa macchina ne'' della rete interna. ' +
    'Sono ammessi localhost, 127.x.x.x e gli indirizzi privati (10.x, 172.16-31.x, 192.168.x): ' +
    'i dati aziendali non devono uscire dall''infrastruttura.', [LHost]);
end;

// ECCEZIONE CONTROLLATA: API CLOUD PER I TEST DI CONFRONTO (04/10/2026)
// Per confrontare il modello locale con uno in cloud (ChatGPT) si ammette
// anche UN host pubblico, a tre condizioni tutte necessarie:
//   1. [LLM] ConsentiCloud=1 nell'ini: scelta esplicita di chi amministra
//      il server, perche' da quel momento domande e risultati dei tool
//      (dati aziendali) vengono inviati al fornitore del modello;
//   2. https e host identico a [LLM] HostCloud (default api.openai.com).
//      Non "qualsiasi indirizzo pubblico": il pannello della chat non ha
//      autenticazione, e chi lo apre potrebbe altrimenti far spedire la
//      chiave API e i dati a un server suo;
//   3. una chiave API disponibile (vedi ChiaveApiCloud).
// Con ConsentiCloud=0 il comportamento e' quello di prima: solo locale.
class function TConfig.EndpointAmmesso(const AEndpoint: string; out AMotivo: string): Boolean;
var
  LHost: string;
  p: Integer;
begin
  if EndpointLocale(AEndpoint, AMotivo) then
    Exit(True);
  Result := False;

  if not FConsentiCloud then
  begin
    // Si tiene il motivo di EndpointLocale e si aggiunge come sbloccare.
    AMotivo := AMotivo + ' Per provare un''API cloud impostare [LLM] ConsentiCloud=1 ' +
      'nell''ini del server e riavviarlo';
    Exit;
  end;
  if not AEndpoint.StartsWith('https://', True) then
  begin
    AMotivo := 'un''API cloud va chiamata in https://';
    Exit;
  end;

  // Host = fra "https://" e il primo "/", senza porta. La "@" e' rifiutata:
  // in "https://api.openai.com:443@altro.host/" l'host vero e' altro.host.
  LHost := Copy(AEndpoint, 9, MaxInt);
  p := Pos('/', LHost);
  if p > 0 then
    LHost := Copy(LHost, 1, p - 1);
  if Pos('@', LHost) > 0 then
  begin
    AMotivo := 'l''indirizzo non puo'' contenere credenziali (utente@host)';
    Exit;
  end;
  p := Pos(':', LHost);
  if p > 0 then
    LHost := Copy(LHost, 1, p - 1);
  LHost := LowerCase(Trim(LHost));

  if (FHostCloud = '') or (LHost <> FHostCloud) then
  begin
    AMotivo := Format('l''unico host cloud ammesso e'' "%s" ([LLM] HostCloud nell''ini), ' +
      'non "%s"', [FHostCloud, LHost]);
    Exit;
  end;
  if ChiaveApiCloud = '' then
  begin
    AMotivo := 'manca la chiave API: variabile d''ambiente OPENAI_API_KEY oppure ' +
      '[LLM] ChiaveApi nell''ini del server';
    Exit;
  end;

  AMotivo := '';
  Result := True;
end;

class function TConfig.ChiaveApiCloud: string;
begin
  // La variabile d'ambiente ha la precedenza: cosi' la chiave puo' restare
  // fuori dai file del progetto (e dai loro backup).
  Result := Trim(GetEnvironmentVariable('OPENAI_API_KEY'));
  if Result = '' then
    Result := FChiaveApiIni;
end;

class function TConfig.ChiaveApiLocale: string;
begin
  // Solo dall'ini: niente variabile d'ambiente, per non confonderla con
  // OPENAI_API_KEY (che e' riservata al cloud).
  Result := FChiaveApiLocaleIni;
end;

class function TConfig.ValidaChat(const AChat: TConfigChat; out AMotivo: string): Boolean;
var
  i: Integer;
begin
  Result := False;

  if Trim(AChat.Endpoint) = '' then
  begin
    AMotivo := 'indirizzo del motore di inferenza mancante';
    Exit;
  end;
  if not EndpointAmmesso(Trim(AChat.Endpoint), AMotivo) then
    Exit;

  // Il nome del modello finisce nell'ini: niente a capo o caratteri di
  // controllo, che romperebbero il file.
  if Length(AChat.Modello) > 200 then
  begin
    AMotivo := 'nome del modello troppo lungo';
    Exit;
  end;
  for i := 1 to Length(AChat.Modello) do
    if AChat.Modello[i] < ' ' then
    begin
      AMotivo := 'il nome del modello contiene caratteri non validi';
      Exit;
    end;

  if AChat.HaTemperatura and ((AChat.Temperatura < 0) or (AChat.Temperatura > 2)) then
  begin
    AMotivo := 'la temperatura deve essere compresa fra 0 e 2';
    Exit;
  end;
  if AChat.HaPresencePenalty and ((AChat.PresencePenalty < -2) or (AChat.PresencePenalty > 2)) then
  begin
    AMotivo := 'la presence penalty deve essere compresa fra -2 e 2';
    Exit;
  end;
  if (AChat.MaxToken < 0) or (AChat.MaxToken > 131072) then
  begin
    AMotivo := 'MaxToken deve essere fra 0 (nessun limite) e 131072';
    Exit;
  end;
  if (AChat.TimeoutMs < 5000) or (AChat.TimeoutMs > 1800000) then
  begin
    AMotivo := 'il timeout deve essere fra 5 secondi e 30 minuti';
    Exit;
  end;

  AMotivo := '';
  Result := True;
end;

procedure TConfig.SalvaChat(const AChat: TConfigChat);
var
  LTemperatura: string;
  LPresence: string;
begin
  if AChat.HaPresencePenalty then
    LPresence := FormatFloat('0.###', AChat.PresencePenalty, TFormatSettings.Invariant)
  else
    LPresence := '';

  if AChat.HaTemperatura then
    LTemperatura := FormatFloat('0.###', AChat.Temperatura, TFormatSettings.Invariant)
  else
    LTemperatura := '';

  FLockChat.Enter;
  try
    // PRIMA l'ini, POI la memoria: se la scrittura del file fallisce
    // (permessi, disco) si solleva l'eccezione e la configurazione attiva
    // resta quella di prima, coerente con il file. TIniFile scrive con le
    // API di Windows, che aggiornano le chiavi in posizione e lasciano
    // intatti i commenti del file.
    FIniFileConfig.WriteString('LLM', 'ChatEndpoint', Trim(AChat.Endpoint));
    FIniFileConfig.WriteString('LLM', 'ChatModel', Trim(AChat.Modello));
    FIniFileConfig.WriteString('LLM', 'Temperatura', LTemperatura);
    FIniFileConfig.WriteInteger('LLM', 'MaxToken', AChat.MaxToken);
    FIniFileConfig.WriteString('LLM', 'PresencePenalty', LPresence);
    FIniFileConfig.WriteBool('LLM', 'Pensiero', AChat.Pensiero);
    FIniFileConfig.WriteInteger('LLM', 'TimeoutMs', AChat.TimeoutMs);
    FIniFileConfig.UpdateFile;

    FChat := AChat;
    FChat.Endpoint := Trim(AChat.Endpoint);
    FChat.Modello := Trim(AChat.Modello);
  finally
    FLockChat.Leave;
  end;
end;

end.
