unit uFrmMain;

interface

uses
  Winapi.Windows, Winapi.Messages,
  System.SysUtils, System.Classes, System.SyncObjs,
  Vcl.Controls, Vcl.Forms, Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.ComCtrls,
  Web.WebReq, Web.WebBroker,
  IdHTTPWebBrokerBridge, uConfig,
  MVCFramework, MVCFramework.Logger, MVCFramework.Commons,
   uLog;

type
  TFrmMain = class(TForm)
    MemoLog: TMemo;
    PanelComandi: TPanel;
    ButtonStartServer: TButton;
    ButtonStopServer: TButton;
    StatusBar: TStatusBar;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure ButtonStartServerClick(Sender: TObject);
    procedure ButtonStopServerClick(Sender: TObject);
  private
    oConfig: TConfig;
    FServer: TIdHTTPWebBrokerBridge;
    procedure doStartServer;
    procedure doStopServer;
  end;

var
  FrmMain: TFrmMain;

implementation
uses
  uType,
  uFunzioni,
  DbU,
  uWebModule,
  MVCFramework.MCP.Server,
  uVenditeToolProvider,
  uClientiToolProvider,
  uEmailToolProvider,
  uFilesToolsProvider,
  uNavigazioneToolProvider,
  uRicetteToolProvider,
  uRitiroRichiamoToolProvider,
  uRegistroViste,
  uRegistroProviderMCP,
  uContrattiTool,
  uCatalogoTool,
  uIndiceEmbeddingTool;

{$R *.dfm}

procedure TFrmMain.FormCreate(Sender: TObject);
begin
  TLog.Initialize(MemoLog, vbMinimale, getFullPathFileLog);
  TLog.Write('Application Started ...');

  oConfig := TConfig.Create;                    // 1. legge config.ini
  TDB.Initialize(oConfig.DatabaseConfig);        // 2. registra i parametri del pool
  TDB.GetInstance.getQueryResult('SELECT 1');    // 3. solo ora � sicuro usare il pool

  // Configurazione e registrazione dei tool MCP: una sola volta per processo.
  // TMCPServer.Instance e' un singleton e RegisterToolProvider solleva "Duplicate tool
  // name" se richiamato; WebModuleCreate gira per ogni worker Indy, quindi qui in
  // FormCreate.
  TMCPServer.Instance.ServerName := 'AziendaAlimentareERP';
  TMCPServer.Instance.ServerVersion := '1.0.0';
  TMCPServer.Instance.ServerInstructions :=
    'Server per l''interrogazione sicura dei dati del gestionale alimentare ' +
    '(vendite, tracciabilita'', ricette). Nessun accesso diretto al database e'' concesso al modello: ' +
    'ogni operazione passa da un tool con parametri tipizzati.';
  TMCPServer.Instance.RegisterToolProvider(TVenditeToolProvider);
  // Contratti dei tool (output, effetto, conferma, vincoli) per il pianificatore,
  // registrati accanto al provider (uContrattiTool.pas).
  TRegistroContrattiTool.Registra(TVenditeToolProvider.ContrattiTool);

  // Descrizione del provider per la selezione a monte (uRegistroProviderMCP.pas),
  // registrata accanto alla registrazione MCP perche' non si disallineino.
  TRegistroProviderMCP.Registra('vendite',
    'Interrogazioni sui dati di vendita del gestionale: ordini di vendita e le relative ' +
    'righe prodotto, filtrabili per cliente, prodotto e periodo. Usa questo provider per ' +
    'qualsiasi domanda del tipo "quanto/cosa/a chi/quando abbiamo venduto" (scenario 2: ' +
    'interrogazione vendite ad hoc). Non genera file: per esportare un risultato in CSV/PDF ' +
    'serve anche il provider "file".',
    ['get_list_vendite']);

  // Provider RTTI (solo parametri stringa): RegisterToolProvider con la classe.
  TMCPServer.Instance.RegisterToolProvider(TClientiToolProvider);
  TRegistroContrattiTool.Registra(TClientiToolProvider.ContrattiTool);

  TRegistroProviderMCP.Registra('clienti',
    'Anagrafica clienti del gestionale: dati di UN cliente (ragione sociale, partita IVA, ' +
    'email, telefono, indirizzo di fatturazione e di consegna), cercato per id, partita IVA ' +
    'o ragione sociale. Usa questo provider per domande sui dati anagrafici o di contatto di ' +
    'un cliente ("che partita IVA ha...", "dove consegniamo a...", "di chi e'' questa partita ' +
    'IVA"). NON usarlo per sapere cosa o quanto ha acquistato un cliente: quello e'' del ' +
    'provider "vendite".',
    ['get_cliente']);

  // Dinamico perche' "destinatari" e' un array. Nel contratto e' una scrittura con
  // conferma. Usa TEmailServer e [SMTP].
  TMCPServer.Instance.RegisterDynamicProvider(TEmailToolProvider.Create);
  TRegistroContrattiTool.Registra(TEmailToolProvider.ContrattiTool);

  TRegistroProviderMCP.Registra('email',
    'Invio di una email a uno o piu'' destinatari, con oggetto e testo scritti dall''agente. ' +
    'Usa questo provider SOLO quando l''utente chiede esplicitamente di inviare/mandare/' +
    'scrivere una email a qualcuno. Non allega file e non cerca gli indirizzi: l''indirizzo ' +
    'di un cliente si legge prima con il provider "clienti". Comprende anche anteprima e ' +
    'invio di email a TESTO FISSO composte da un modello (es. le comunicazioni di ' +
    'ritiro/richiamo ai clienti): li'' il testo non lo scrive l''agente. ' +
    // 04/10/2026 (run 4, S1-F): il Planner vede la descrizione del provider (quella del
    // tool solo dopo averlo usato), quindi la dipendenza va ripetuta anche qui.
    'Anteprima o invio delle comunicazioni di ritiro/richiamo richiedono SEMPRE DUE passi ' +
    'nello stesso piano: prima la verifica delle spedizioni del provider "ritiro_richiamo" ' +
    'sui lotti di prodotto finito coinvolti, poi l''anteprima (o l''invio) con l''elenco ' +
    '"comunicazioni" restituito da quel passo. Vale anche se la verifica e'' gia'' stata ' +
    'fatta in un turno precedente: si ripete.',
    ['invia_email', 'anteprima_email_da_modello', 'invia_email_da_modello']);

  // Provider dinamico (parametri array/object veri): RegisterDynamicProvider. A differenza
  // dei provider RTTI (istanza nuova per chiamata, TMCPRequestHandler.DoToolsCall) prende
  // un'istanza unica usata da piu' thread: InvokeDynamic non deve usare stato d'istanza.
  TMCPServer.Instance.RegisterDynamicProvider(TFilesToolsProvider.Create);
  TRegistroContrattiTool.Registra(TFilesToolsProvider.ContrattiTool);

  TRegistroProviderMCP.Registra('file',
    'Generazione di file scaricabili (CSV, PDF) a partire da dati che il modello ha gia'' ' +
    'ottenuto in questo stesso turno da un altro tool (es. un elenco di vendite o una ' +
    'ricetta). Usa questo provider SOLO quando l''utente chiede esplicitamente di ' +
    'esportare/scaricare/produrre un documento o un foglio a partire da dati appena ' +
    'consultati - non per recuperare i dati stessi. Un file richiede SEMPRE DUE passi nello ' +
    'stesso piano: prima il passo che legge i dati, poi il passo che genera il file dal ' +
    'risultato del primo. Vale anche per un seguito come "esportalo in csv" su dati mostrati ' +
    'in un turno precedente: il primo passo ripete quella lettura con gli stessi filtri.',
    ['generate_csv', 'generate_pdf']);

  // apri_vista: tool generico per tutti gli scenari, legge solo TRegistroViste. Dinamico
  // perche' "parametri" e' un oggetto vero.
  TMCPServer.Instance.RegisterDynamicProvider(TNavigazioneToolProvider.Create);
  TRegistroContrattiTool.Registra(TNavigazioneToolProvider.ContrattiTool);

  TRegistroProviderMCP.Registra('navigazione',
    'Tool generico che segnala al frontend di aprire una schermata del gestionale per una ' +
    'specifica entita'' (es. la scheda di un prodotto finito o semilavorato, o la sua ' +
    'ricetta corrente - vedi TRegistroViste per l''elenco viste disponibili). Usa questo ' +
    'provider quando l''esito di un''altra operazione e'' troppo ricco per essere ' +
    'riassunto in chat e conviene mostrarlo nell''interfaccia grafica.',
    ['apri_vista']);

  // Scenario 3. Tutti i tool dichiarati dinamici nello stesso provider ("sostituzioni" e'
  // un array): RegisterDynamicProvider.
  TMCPServer.Instance.RegisterDynamicProvider(TRicetteToolProvider.Create);
  TRegistroContrattiTool.Registra(TRicetteToolProvider.ContrattiTool);

  TRegistroProviderMCP.Registra('ricette',
    'Consultazione e adattamento delle ricette dei prodotti finiti: lettura della ricetta ' +
    'corrente, ricerca di componenti/ingredienti, simulazione di una modifica (es. ' +
    'sostituzione o rimozione di un ingrediente) con impatto economico, e applicazione ' +
    'definitiva della modifica come nuova variante o versione. Usa questo provider per ' +
    'richieste di adattamento ricetta su richiesta cliente, incluso il calcolo dei costi ' +
    '(scenario 3, tipicamente multi-turno).',
    ['get_ricetta_prodotto_finito', 'cerca_componenti_ricetta', 'simula_adattamento_ricetta',
     'applica_adattamento_ricetta']);

  // Vista aperta da applica_adattamento_ricetta (via apri_vista): anagrafica del prodotto
  // finito risultante con la ricetta corrente.
  TRegistroViste.Registra('ricetta_prodotto_finito',
    'Scheda anagrafica di un prodotto finito con la ricetta CORRENTE (versione, componenti, ' +
    'dosi). Apri questa vista dopo una scrittura di scenario 3 (nuova variante creata o ' +
    'riusata, nuova versione di ricetta) il cui esito e'' troppo ricco per essere riassunto a ' +
    'parole.',
    ['prodotto_finito_id']);

  // Scenario 1. Entrambi dinamici (parametri array): RegisterDynamicProvider.
  TMCPServer.Instance.RegisterDynamicProvider(TRitiroRichiamoToolProvider.Create);
  TRegistroContrattiTool.Registra(TRitiroRichiamoToolProvider.ContrattiTool);

  TRegistroProviderMCP.Registra('ritiro_richiamo',
    'Ritiro/richiamo di prodotti non conformi: apertura di una non conformita'' su uno o piu'' ' +
    'lotti di materia prima non conformi (identificati per codice lotto, es. dopo una ' +
    'segnalazione di corpo estraneo/contaminazione/difetto - anche se l''utente non usa mai le ' +
    'parole "ritiro" o "richiamo"), con risalita automatica ai lotti di prodotto finito ' +
    'coinvolti, e verifica se quei lotti di prodotto finito sono gia'' stati spediti/consegnati ' +
    'a qualche cliente (ordini e DDT di uscita). Usa questo provider per qualunque richiesta ' +
    'che parta da un problema su un LOTTO o una MATERIA PRIMA non conforme - anche solo per ' +
    'sapere se quel lotto e'' gia'' arrivato a un cliente. Non usarlo per interrogazioni di ' +
    'vendita generiche senza un lotto non conforme di mezzo (es. "quanto abbiamo venduto a ' +
    'marzo?", "cosa ha comprato il cliente Rossi?"): quelle sono del provider "vendite", anche ' +
    'se entrambi parlano di ordini e clienti. La verifica delle spedizioni da'' anche l''elenco dei clienti da avvisare, da passare al provider "email" per anteprima e invio. Non copre notifica ASL ne'' ' +
    'generazione documenti di compliance: quella parte del processo non e'' ancora ' +
    'implementata.',
    ['apri_non_conformita_materia_prima', 'trova_ordini_spedizioni_lotto_prodotto_finito']);

  // Viste anagrafica prodotto finito/semilavorato (senza ricetta): aperte dal frontend via
  // apri_vista, a prescindere dal tool che ha prodotto il risultato. A differenza di
  // 'ricetta_prodotto_finito' mostrano la scheda anagrafica pura (codice, allergeni,
  // scadenza standard).
  TRegistroViste.Registra('prodotto_finito',
    'Scheda anagrafica di un prodotto finito (codice, denominazione, scadenza standard, ' +
    'allergeni dichiarati, eventuale prodotto padre se e'' una variante). NON mostra la ' +
    'ricetta: per quella usa la vista "ricetta_prodotto_finito".',
    ['prodotto_finito_id']);

  TRegistroViste.Registra('semilavorato',
    'Scheda anagrafica di un semilavorato (codice, denominazione, allergeni dichiarati). ' +
    'Nessuna vista "ricetta_semilavorato" esiste ancora: la sua ricetta corrente si consulta ' +
    'solo dall''interfaccia umana (/ricette/semilavorati/(id)), non tramite apri_vista.',
    ['semilavorato_id']);

  // 'dashboard' non e' registrata: non e' legata a un'entita' restituita da un tool, quindi
  // non ha un parametro sensato per apri_vista.

  // 'vendite' e 'tracciabilita' sono registrate: con il pianificatore la tabella in chat
  // non c'e' sempre, e aprire l'elenco gia' filtrato e' un approfondimento. Le viste sono
  // proposte dal modello (apri_vista) e dal codice ("apertura_vista"/"aperture_vista" in
  // get_list_vendite e apri_non_conformita_materia_prima, come pulsante in chat). I nomi
  // devono combaciare con App.RegistroViste.registra nel frontend (views/view-vendite.js,
  // views/view-tracciabilita.js).
  TRegistroViste.Registra('vendite',
    'Elenco degli ordini di vendita, filtrabile. Nessun parametro obbligatorio; in ' +
    '"parametri" si possono indicare i filtri facoltativi cliente_id, prodotto_id, ' +
    'data_inizio e data_fine (date in formato AAAA-MM-GG).',
    nil);

  TRegistroViste.Registra('tracciabilita_lotto',
    'Albero di tracciabilita'' di un lotto: in quali semilavorati e prodotti finiti e'' ' +
    'entrato e a quali ordini/clienti e'' arrivato. tipo_lotto e'' uno fra ' +
    '"materia_prima", "semilavorato", "prodotto_finito"; lotto_id e'' l''id numerico del lotto.',
    ['tipo_lotto', 'lotto_id']);

  // Catalogo dei tool costruito qui, dopo tutte le registrazioni e prima di doStartServer:
  // fotografa i tool presenti e non viene ricostruito (uCatalogoTool.pas). Un provider
  // registrato dopo non arriverebbe mai al modello.
  TCatalogoTool.Costruisci;
  TLog.Write(Format('Catalogo tool MCP costruito: %d tool disponibili.',
    [TCatalogoTool.Conteggio]));

  // Fase 1 (retrieval semantico): allinea mcp_tool_indice ai tool del catalogo. Va dopo il
  // catalogo, che fornisce l'elenco reale per convalidare le righe. Non bloccante: se
  // l'embedding non risponde (LM Studio spento, modello non caricato) l'errore va nel log e
  // l'avvio continua. mcp_tool_indice resta com'era (Sincronizza e' una sola transazione) e
  // SelezionaToolPerDomanda ripiega sull'intero catalogo. Il server funziona, solo senza la
  // riduzione dei tool.
  try
    TIndiceEmbeddingTool.Sincronizza;
  except
    on E: Exception do
      TLog.Write('ATTENZIONE - sincronizzazione dell''indice degli embedding ' +
        'non riuscita (' + E.Message + '). Il server parte comunque: finche''' +
        ' gli embedding non sono disponibili, a ogni turno viene inviato al ' +
        'modello l''intero catalogo dei tool. Per ricostruire l''indice ' +
        'riavviare il server con il servizio di embedding attivo.');
  end;

  FServer := TIdHTTPWebBrokerBridge.Create(nil);

  doStartServer;                          // avvio automatico, non serve pi� FormAfterShow
end;

procedure TFrmMain.FormDestroy(Sender: TObject);
begin
  doStopServer;
  FServer.Free;
  oConfig.Free;
end;

procedure TFrmMain.doStartServer;
begin
  if FServer.Active then
  begin
    Exit;
  end;

  IsMultiThread := True;

  // Registra la classe WebModule presso WebBroker: senza, TIdHTTPWebBridge non sa quale
  // WebModule istanziare e solleva 'No data modules registered' alla prima richiesta.
  if WebRequestHandler <> nil then
    WebRequestHandler.WebModuleClass := WebModuleClass;

  // Porta da config.ini ([Server] HttpPort), non fissa: con due fonti separate cambiare
  // l'ini non sposterebbe la porta reale.
  FServer.DefaultPort := oConfig.HttpPort;
  WebRequestHandlerProc.MaxConnections := 1024;
  FServer.Active := True;

  TLog.Write('Server MCP avviato su http://localhost:' + oConfig.HttpPort.ToString);
  // StatusBar e' SimplePanel (vedi .dfm): il testo va in SimpleText; Panels[0] solleverebbe
  // EListError mascherando lo stato del server.
  StatusBar.SimpleText := 'Server: attivo';
end;

procedure TFrmMain.doStopServer;
begin
  if FServer.Active then
  begin
    FServer.Active := False;
    StatusBar.SimpleText := 'Server: fermo';
  end;
end;

procedure TFrmMain.ButtonStartServerClick(Sender: TObject);
begin
  doStartServer;
end;

procedure TFrmMain.ButtonStopServerClick(Sender: TObject);
begin
  doStopServer;
end;

end.
