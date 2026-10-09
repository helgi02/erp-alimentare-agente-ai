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

  // Server di posta in uscita, sezione [SMTP] dell'ini, usato da TEmailServer. Host vuoto =
  // invio non configurato: il server parte lo stesso e l'invio risponde con un errore
  // chiaro.
  TConfigSMTP = record
    Host: string;
    // 465 = TLS implicito; 587/25 = STARTTLS.
    Port: Integer;
    Username: string;
    Password: string;
    // Mittente mostrato al destinatario.
    FromName: string;
    FromAddress: string;
    // Protezioni per prove e dimostrazioni (gli indirizzi dei dati di test sono verosimili
    // e non devono ricevere nulla). Simula = True: nessuna connessione SMTP, l'email e'
    // scritta in logs\email_simulate.jsonl e l'invio risulta riuscito. ReindirizzaA <> '':
    // l'email parte davvero ma verso quell'unico indirizzo, con il destinatario vero
    // nell'oggetto ("[per: ...]"). Simula ha la precedenza.
    Simula: Boolean;
    ReindirizzaA: string;
  end;

  // Configurazione del modello di chat, sezione [LLM]. E' un record letto e scritto tutto
  // insieme sotto lock, cosi' un passo del turno non vede mezzo aggiornamento (endpoint
  // nuovo con modello vecchio).
  TConfigChat = record
    // URL di base di un'API compatibile OpenAI (es. http://localhost:1234/v1).
    Endpoint: string;
    // Id del modello come in <Endpoint>/models; vuoto = modello caricato (LM Studio accetta
    // 'local-model').
    Modello: string;
    // Temperatura opzionale: se HaTemperatura = False non si invia e vale il default del
    // motore.
    HaTemperatura: Boolean;
    Temperatura: Double;
    // 0 = nessun tetto ai token generati. Un tetto protegge dai loop di ripetizione, che
    // con un modello piccolo fanno scadere il timeout (WinHTTP 12002).
    MaxToken: Integer;
    // Presence penalty opzionale (-2..2): penalizza i token gia' comparsi e rompe i loop di
    // ripetizione. Se HaPresencePenalty = False vale il default.
    HaPresencePenalty: Boolean;
    PresencePenalty: Double;
    // Modalita' "thinking" (es. Qwen3.5). False = disattivata: per un flusso a tool non
    // serve e sui modelli piccoli puo' finire nel testo della risposta in un ciclo senza
    // fine.
    Pensiero: Boolean;
    // Attesa massima di una risposta del modello.
    TimeoutMs: Integer;
  end;

  TConfig = Class

  Private

    // Unica istanza, creata in TFrmMain.FormCreate (che la libera in FormDestroy) ed
    // esposta qui perche' uWebModule e i tool provider non possono raggiungere il campo
    // privato oConfig.
    class var FInstance: TConfig;

    // "var" esplicito: senza, i campi seguenti resterebbero nel blocco "class var"
    // (condivisi invece che d'istanza), causa dell'errore E2356 sulle property sotto.
    var
      FIniFileConfig: TIniFile;
    FDatabaseConfig: TDatabaseConfig;
    FHttpPort: Integer;
    // Servizio di embedding, sezione [Embedding] (Endpoint, Model), per /v1/embeddings
    // (retrieval dei tool, uIndiceEmbeddingTool). E' separato dal modello di chat, che puo'
    // stare altrove: l'indice pgvector e' legato a questo modello, quindi i vettori delle
    // domande devono venire dallo stesso.
    FEmbeddingEndpoint: string;
    FEmbeddingModel: string;
    // Modello di chat: una sola configurazione, da [LLM]
    // ChatEndpoint/ChatModel/Temperatura/MaxToken/TimeoutMs. Il frontend non sa quale sia:
    // puo' pero' modificarla dal pannello impostazioni (GET/PUT
    // /api/ai/configurazione-llm); il server la valida, la scrive nell'ini e la applica dal
    // passo successivo. E' letta e scritta da piu' thread, quindi protetta da FLockChat
    // (assegnare una stringa mentre un altro thread la legge puo' corrompere il conteggio
    // dei riferimenti).
    FChat: TConfigChat;
    FLockChat: TCriticalSection;
    // API cloud per i test di confronto (vedi EndpointAmmesso). Lette una volta all'avvio:
    // si cambiano nell'ini e riavviando, mai dal pannello della chat (senza
    // autenticazione). "class var" perche' le usano funzioni di classe. [LLM]
    // ConsentiCloud=1 interruttore (default 0); HostCloud=api.openai.com unico host
    // pubblico ammesso; ChiaveApi=sk-... (ha la precedenza OPENAI_API_KEY).
    class var FConsentiCloud: Boolean;
    class var FHostCloud: string;
    class var FChiaveApiIni: string;
    // Chiave per un motore locale o di rete interna che richiede autenticazione (es.
    // Unsloth Studio): [LLM] ChiaveApiLocale. Separata da ChiaveApi, cosi' la chiave OpenAI
    // non va a un motore locale e viceversa. Vuota = nessuna intestazione Authorization.
    class var FChiaveApiLocaleIni: string;
    var
    // Orchestratore (selezione dei tool) e modalita' di test. Strategia di default
    // (TModalitaSelezione): 'tutti', 'topk_tool', 'provider_rango', 'provider_margine',
    // 'provider_completo' (produzione).
    FSelezioneModalita: string;
    // Tool tenuti da 'topk_tool' (baseline di confronto per la relazione: la selezione per
    // provider nasce perche' il top-K spezzava le catene di tool).
    FSelezioneTopKTool: Integer;
    // Motore dell'orchestratore: 'ciclo' (il modello chiama i tool uno dopo l'altro) o
    // 'pianificatore' (piano ed esecuzione dal codice, uTurnoPianificato). Default 'ciclo'.
    FMotoreOrchestratore: string;
    // Se True, il corpo di POST /api/ai/turni puo' sovrascrivere "modalita_selezione" e
    // "modello". Serve solo alla batteria di test; di default spento.
    FAbilitaOverrideTest: Boolean;
    // Cartella dove TFilesToolsProvider scrive i file generati, servita su /export da
    // TMVCStaticFilesMiddleware. Dopo Load e' sempre assoluta: se in ini e' relativa, si
    // risolve rispetto all'eseguibile.
    FExportFolder: string;
    // Base URL del link di download restituito nel tool_result. Di default dedotta da
    // HttpPort (client e server sulla stessa macchina); sovrascrivibile con [Server]
    // PublicBaseUrl.
    FPublicBaseUrlOverride: string;
    // Letta una volta in Load e mai modificata: leggibile da piu' thread senza lock (a
    // differenza di FChat).
    FSMTP: TConfigSMTP;

    function GetFullPathFileIni: String;
    function GetBaseUrl: string;
    procedure Load;

  public

    Constructor Create;
    Destructor Destroy; override;

    // Solleva un'eccezione se chiamata prima che FormCreate abbia creato la configurazione.
    // Niente creazione lazy: nasconderebbe un errore di avvio.
    class function GetInstance: TConfig;

    property DatabaseConfig: TDatabaseConfig read FDatabaseConfig;
    property SMTP: TConfigSMTP read FSMTP;
    property HttpPort: Integer read FHttpPort;
    property EmbeddingEndpoint: string read FEmbeddingEndpoint;
    property EmbeddingModel: string read FEmbeddingModel;

    // Copia della configurazione di chat (sotto lock): chi la usa la legge una volta e
    // lavora sulla copia.
    function Chat: TConfigChat;
    // Controlla una configurazione proposta dal client: False + motivo leggibile se non
    // accettabile. Non modifica nulla.
    class function ValidaChat(const AChat: TConfigChat; out AMotivo: string): Boolean;
    // Endpoint ammesso solo se punta a questa macchina o alla rete interna.
    class function EndpointAmmesso(const AEndpoint: string; out AMotivo: string): Boolean;
    // True se l'endpoint e' locale o di rete interna (localhost, 127.x, 10.x, 172.16-31.x,
    // 192.168.x). Chi distingue "locale" da "cloud" puo' ignorare AMotivo.
    class function EndpointLocale(const AEndpoint: string; out AMotivo: string): Boolean;
    // Chiave "Authorization: Bearer" per l'API cloud: OPENAI_API_KEY, altrimenti [LLM]
    // ChiaveApi. Vuota = nessuna. Mai nei log ne' al browser.
    class function ChiaveApiCloud: string;
    // Chiave "Authorization: Bearer" per un endpoint locale: [LLM] ChiaveApiLocale. Vuota =
    // nessuna. Mai nei log ne' al browser.
    class function ChiaveApiLocale: string;
    // Scrive la configurazione nell'ini e la attiva. Solo dopo ValidaChat.
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

  // Bootstrap: serve per connettersi al DB.
  FDatabaseConfig.Server   := FIniFileConfig.ReadString('Database', 'Server', 'localhost');
  FDatabaseConfig.Port     := FIniFileConfig.ReadInteger('Database', 'Port', 5432);
  FDatabaseConfig.Database := FIniFileConfig.ReadString('Database', 'Database', '');
  FDatabaseConfig.UserName := FIniFileConfig.ReadString('Database', 'UserName', '');
  FDatabaseConfig.Password := FIniFileConfig.ReadString('Database', 'Password', '');
  FDatabaseConfig.PoolSize := FIniFileConfig.ReadInteger('Database', 'PoolSize', 10);

  // Server HTTP.
  FHttpPort := FIniFileConfig.ReadInteger('Server', 'HttpPort', 8080);

  // Cartella di export: default 'export' accanto all'eseguibile; un percorso assoluto e'
  // comunque configurabile.
  LExportFolderIni := FIniFileConfig.ReadString('Server', 'ExportFolder', 'export');
  if TPath.IsRelativePath(LExportFolderIni) then
    FExportFolder := TPath.Combine(ExtractFilePath(Application.ExeName), LExportFolderIni)
  else
    FExportFolder := LExportFolderIni;

  // TMVCStaticFilesMiddleware solleva un'eccezione se DocumentRoot non esiste: al primo
  // avvio la cartella puo' mancare, quindi la si crea prima del WebModule.
  if not TDirectory.Exists(FExportFolder) then
    TDirectory.CreateDirectory(FExportFolder);

  FPublicBaseUrlOverride := FIniFileConfig.ReadString('Server', 'PublicBaseUrl', '');

  // Servizio di embedding. Se manca la sezione [Embedding] si leggono le chiavi dei vecchi
  // ini ([LLM] Endpoint / EmbeddingModel).
  FEmbeddingEndpoint := FIniFileConfig.ReadString('Embedding', 'Endpoint',
    FIniFileConfig.ReadString('LLM', 'Endpoint', 'http://localhost:1234/v1'));
  // Nessun default per il modello di embedding: stringa vuota, e TServizioEmbedding solleva
  // un errore chiaro al primo uso. Non si fallisce all'avvio per una funzione non ancora
  // sul percorso critico.
  FEmbeddingModel := FIniFileConfig.ReadString('Embedding', 'Model',
    FIniFileConfig.ReadString('LLM', 'EmbeddingModel', ''));

  // Modello di chat, sezione [LLM], indipendente dagli embedding: se ChatEndpoint manca
  // vale il default di LM Studio locale, non l'endpoint degli embedding (possono stare su
  // macchine diverse). Load gira nel costruttore, prima delle richieste: il lock non serve.
  FChat.Endpoint := FIniFileConfig.ReadString('LLM', 'ChatEndpoint', 'http://localhost:1234/v1');
  FChat.Modello := FIniFileConfig.ReadString('LLM', 'ChatModel', '');
  // Letta come stringa e convertita col formato invariante: ReadFloat userebbe le
  // impostazioni di Windows e su un PC italiano "0.2" non verrebbe riconosciuto.
  LTemperaturaIni := Trim(FIniFileConfig.ReadString('LLM', 'Temperatura', ''));
  FChat.HaTemperatura := (LTemperaturaIni <> '') and
    TryStrToFloat(LTemperaturaIni, FChat.Temperatura, TFormatSettings.Invariant);
  FChat.MaxToken := FIniFileConfig.ReadInteger('LLM', 'MaxToken', 0);
  // Come la temperatura: stringa + formato invariante.
  LPresenceIni := Trim(FIniFileConfig.ReadString('LLM', 'PresencePenalty', ''));
  FChat.HaPresencePenalty := (LPresenceIni <> '') and
    TryStrToFloat(LPresenceIni, FChat.PresencePenalty, TFormatSettings.Invariant);
  // Default False: il thinking si attiva solo con Pensiero=1.
  FChat.Pensiero := FIniFileConfig.ReadBool('LLM', 'Pensiero', False);
  FChat.TimeoutMs := FIniFileConfig.ReadInteger('LLM', 'TimeoutMs', 180000);

  // API cloud: spenta se le chiavi mancano.
  FConsentiCloud := FIniFileConfig.ReadBool('LLM', 'ConsentiCloud', False);
  FHostCloud := LowerCase(Trim(FIniFileConfig.ReadString('LLM', 'HostCloud', 'api.openai.com')));
  FChiaveApiIni := Trim(FIniFileConfig.ReadString('LLM', 'ChiaveApi', ''));
  // Chiave del motore locale (opzionale).
  FChiaveApiLocaleIni := Trim(FIniFileConfig.ReadString('LLM', 'ChiaveApiLocale', ''));

  // Default = comportamento attuale (provider_completo): un ini senza queste chiavi
  // funziona come prima.
  FSelezioneModalita := FIniFileConfig.ReadString('Orchestratore', 'Modalita', 'provider_completo');
  FSelezioneTopKTool := FIniFileConfig.ReadInteger('Orchestratore', 'TopKTool', 3);
  // Senza questa chiave si usa il motore di sempre.
  FMotoreOrchestratore := FIniFileConfig.ReadString('Orchestratore', 'Motore', 'ciclo');
  FAbilitaOverrideTest := FIniFileConfig.ReadBool('Test', 'AbilitaOverride', False);

  // Posta in uscita (TConfigSMTP). Nessun default per Host: senza [SMTP] l'invio risulta
  // "non configurato".
  FSMTP.Host        := Trim(FIniFileConfig.ReadString('SMTP', 'Host', ''));
  FSMTP.Port        := FIniFileConfig.ReadInteger('SMTP', 'Port', 465);
  FSMTP.Username    := Trim(FIniFileConfig.ReadString('SMTP', 'Username', ''));
  FSMTP.Password    := FIniFileConfig.ReadString('SMTP', 'Password', '');
  FSMTP.FromName    := Trim(FIniFileConfig.ReadString('SMTP', 'FromName', ''));
  // Mittente non indicato = l'utente di autenticazione.
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

// Perche' solo indirizzi locali: nessun dato aziendale deve uscire dall'infrastruttura, e
// il modello riceve domande e risultati dei tool. Il pannello impostazioni non ha
// autenticazione: senza questo controllo chiunque aprisse il sito potrebbe far contattare
// al server un indirizzo qualsiasi di Internet. Si ammettono localhost, 127.x.x.x, ::1 e
// gli IPv4 privati (10.x, 172.16-31.x, 192.168.x), es. un PC con GPU nello stesso ufficio o
// via VPN. Aprire ad altro e' uno sviluppo futuro, legato a un utente autenticato.
class function TConfig.EndpointLocale(const AEndpoint: string; out AMotivo: string): Boolean;
var
  LResto, LHost: string;
  LParti: TArray<string>;
  LOttetti: array[0..3] of Integer;
  i, p: Integer;
begin
  Result := False;
  AMotivo := '';

  // Solo http/https.
  if AEndpoint.StartsWith('http://', True) then
    LResto := Copy(AEndpoint, 8, MaxInt)
  else if AEndpoint.StartsWith('https://', True) then
    LResto := Copy(AEndpoint, 9, MaxInt)
  else
  begin
    AMotivo := 'l''indirizzo deve iniziare con http:// o https://';
    Exit;
  end;

  // Host = prima del primo '/', senza porta. Credenziali nell'URL (utente@host) non
  // ammesse: renderebbero ambiguo l'host.
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
    // IPv6 tra parentesi quadre: solo il loopback [::1].
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

// Eccezione controllata: API cloud per i test di confronto (04/10/2026). Si ammette un solo
// host pubblico, a tre condizioni: 1) [LLM] ConsentiCloud=1, scelta esplicita di chi
// amministra perche' domande e risultati dei tool (dati aziendali) vanno al fornitore; 2)
// https e host identico a [LLM] HostCloud (default api.openai.com), non un indirizzo
// pubblico qualsiasi: il pannello non ha autenticazione e altrimenti chiave e dati
// potrebbero andare a un server altrui; 3) una chiave API (ChiaveApiCloud). Con
// ConsentiCloud=0 solo locale.
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

  // Host fra "https://" e il primo "/", senza porta. La "@" e' rifiutata: in
  // "https://api.openai.com:443@altro.host/" l'host vero e' altro.host.
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
  // La variabile d'ambiente ha la precedenza, cosi' la chiave puo' restare fuori dai file
  // del progetto e dai loro backup.
  Result := Trim(GetEnvironmentVariable('OPENAI_API_KEY'));
  if Result = '' then
    Result := FChiaveApiIni;
end;

class function TConfig.ChiaveApiLocale: string;
begin
  // Solo da ini, senza variabile d'ambiente, per non confonderla con OPENAI_API_KEY
  // (riservata al cloud).
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

  // Il nome del modello finisce nell'ini: niente a capo o caratteri di controllo,
  // romperebbero il file.
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
    // Prima l'ini, poi la memoria: se la scrittura fallisce si solleva l'eccezione e la
    // configurazione attiva resta coerente col file. TIniFile aggiorna le chiavi in
    // posizione e lascia intatti i commenti.
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
