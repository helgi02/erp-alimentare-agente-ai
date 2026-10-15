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

  // Configurazione e registrazione tool del server MCP: va fatta una sola
  // volta per processo (TMCPServer.Instance e' un singleton, e
  // RegisterToolProvider solleva "Duplicate tool name" se richiamato due
  // volte sullo stesso provider). WebModuleCreate gira invece una volta
  // per ogni worker thread Indy, quindi NON e' il posto giusto: qui in
  // FormCreate viene eseguito esattamente una volta, prima che il server
  // inizi ad accettare richieste.
  TMCPServer.Instance.ServerName := 'AziendaAlimentareERP';
  TMCPServer.Instance.ServerVersion := '1.0.0';
  TMCPServer.Instance.ServerInstructions :=
    'Server per l''interrogazione sicura dei dati del gestionale alimentare ' +
    '(vendite, tracciabilita'', ricette). Nessun accesso diretto al database e'' concesso al modello: ' +
    'ogni operazione passa da un tool con parametri tipizzati.';
  TMCPServer.Instance.RegisterToolProvider(TVenditeToolProvider);
  // Contratti dei tool del provider (output, effetto, conferma, vincoli) per il
  // pianificatore: registrati accanto al provider, vedi agente_ai/tool/uContrattiTool.pas.
  TRegistroContrattiTool.Registra(TVenditeToolProvider.ContrattiTool);

  // Descrizione del provider per la selezione a monte da parte dell'LLM
  // (vedi agente_ai/tool/uRegistroProviderMCP.pas): registrata qui, accanto alla
  // riga che registra davvero il provider nel server MCP, cosi' le due
  // cose non possono disallinearsi.
  TRegistroProviderMCP.Registra('vendite',
    'Interrogazioni sui dati di vendita del gestionale: ordini di vendita e le relative ' +
    'righe prodotto, filtrabili per cliente, prodotto e periodo. Usa questo provider per ' +
    'qualsiasi domanda del tipo "quanto/cosa/a chi/quando abbiamo venduto" (scenario 2: ' +
    'interrogazione vendite ad hoc). Non genera file: per esportare un risultato in CSV/PDF ' +
    'serve anche il provider "file".',
    ['get_list_vendite']);

  // TClientiToolProvider (agente_ai/tool/uClientiToolProvider.pas): get_cliente,
  // anagrafica di un cliente cercato per id, partita IVA o ragione sociale.
  // Provider RTTI come TVenditeToolProvider (solo parametri stringa), quindi
  // RegisterToolProvider con la CLASSE, non RegisterDynamicProvider.
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

  // TEmailToolProvider (agente_ai/tool/uEmailToolProvider.pas): invia_email,
  // tool generico (destinatari, oggetto, testo scritti dal modello). Dinamico
  // perche' "destinatari" e' un array. Nel contratto e' una scrittura con
  // conferma: l'utente vede il messaggio prima che parta. Usa TEmailServer e
  // la sezione [SMTP] dell'ini.
  TMCPServer.Instance.RegisterDynamicProvider(TEmailToolProvider.Create);
  TRegistroContrattiTool.Registra(TEmailToolProvider.ContrattiTool);

  TRegistroProviderMCP.Registra('email',
    'Invio di una email a uno o piu'' destinatari, con oggetto e testo scritti dall''agente. ' +
    'Usa questo provider SOLO quando l''utente chiede esplicitamente di inviare/mandare/' +
    'scrivere una email a qualcuno. Non allega file e non cerca gli indirizzi: l''indirizzo ' +
    'di un cliente si legge prima con il provider "clienti". Comprende anche anteprima e ' +
    'invio di email a TESTO FISSO composte da un modello (es. le comunicazioni di ' +
    'ritiro/richiamo ai clienti): li'' il testo non lo scrive l''agente. ' +
    // 04/10/2026 (run 4, S1-F): il Planner vede la descrizione del PROVIDER
    // (quella del tool solo dopo che il tool e' stato usato), quindi la
    // dipendenza va ripetuta anche qui.
    'Anteprima o invio delle comunicazioni di ritiro/richiamo richiedono SEMPRE DUE passi ' +
    'nello stesso piano: prima la verifica delle spedizioni del provider "ritiro_richiamo" ' +
    'sui lotti di prodotto finito coinvolti, poi l''anteprima (o l''invio) con l''elenco ' +
    '"comunicazioni" restituito da quel passo. Vale anche se la verifica e'' gia'' stata ' +
    'fatta in un turno precedente: si ripete.',
    ['invia_email', 'anteprima_email_da_modello', 'invia_email_da_modello']);

  // TFilesToolsProvider espone tool "dinamici" (generate_csv/generate_pdf,
  // parametri array/object veri - vedi commento in testa a
  // uFilesToolsProvider.pas) e per questo si registra con
  // RegisterDynamicProvider, non RegisterToolProvider: a differenza dei
  // provider RTTI (una nuova istanza per ogni chiamata, vedi
  // TMCPRequestHandler.DoToolsCall), RegisterDynamicProvider prende
  // possesso di UN'ISTANZA che vive per tutta la durata del processo e
  // viene richiamata concorrentemente da thread diversi - per questo
  // InvokeDynamic non deve mai leggere/scrivere stato d'istanza (nessun
  // campo mutabile in TFilesToolsProvider, solo variabili locali).
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

  // apri_vista (agente_ai/tool/uNavigazioneToolProvider.pas): tool generico, uguale
  // per tutti gli scenari, che permette al modello di segnalare "apri
  // questa schermata per questa entita'" senza sapere nulla di ricette,
  // vendite o ritiro/richiamo - legge solo TRegistroViste (common/
  // uRegistroViste.pas). Registrato come dynamic provider per lo stesso
  // motivo di TFilesToolsProvider (parametro "parametri" e' un oggetto
  // vero, non esprimibile via RTTI).
  TMCPServer.Instance.RegisterDynamicProvider(TNavigazioneToolProvider.Create);
  TRegistroContrattiTool.Registra(TNavigazioneToolProvider.ContrattiTool);

  TRegistroProviderMCP.Registra('navigazione',
    'Tool generico che segnala al frontend di aprire una schermata del gestionale per una ' +
    'specifica entita'' (es. la scheda di un prodotto finito o semilavorato, o la sua ' +
    'ricetta corrente - vedi TRegistroViste per l''elenco viste disponibili). Usa questo ' +
    'provider quando l''esito di un''altra operazione e'' troppo ricco per essere ' +
    'riassunto in chat e conviene mostrarlo nell''interfaccia grafica.',
    ['apri_vista']);

  // TRicetteToolProvider (scenario 3, adattamento ricette): get_ricetta_
  // prodotto_finito, cerca_componenti_ricetta, simula_adattamento_ricetta,
  // applica_adattamento_ricetta. Tutti e quattro dichiarati "dinamici" nello
  // stesso provider (vedi il commento in testa a uRicetteToolProvider.pas
  // sul perche' - il parametro "sostituzioni" e' un array vero), quindi si
  // registra con RegisterDynamicProvider come TFilesToolsProvider/
  // TNavigazioneToolProvider, non con RegisterToolProvider.
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

  // Vista aperta da applica_adattamento_ricetta (tramite apri_vista) dopo
  // aver creato o individuato una variante: mostra l'anagrafica del
  // prodotto finito risultante con la sua ricetta corrente. Registrata qui
  // insieme al tool provider a cui appartiene, stesso principio delle
  // altre righe di questo blocco.
  TRegistroViste.Registra('ricetta_prodotto_finito',
    'Scheda anagrafica di un prodotto finito con la ricetta CORRENTE (versione, componenti, ' +
    'dosi). Apri questa vista dopo una scrittura di scenario 3 (nuova variante creata o ' +
    'riusata, nuova versione di ricetta) il cui esito e'' troppo ricco per essere riassunto a ' +
    'parole.',
    ['prodotto_finito_id']);

  // TRitiroRichiamoToolProvider (scenario 1, ritiro/richiamo prodotti non
  // conformi): apri_non_conformita_materia_prima,
  // trova_ordini_spedizioni_lotto_prodotto_finito. Entrambi "dinamici"
  // (parametro "codici_lotto_materia_prima"/"lotti_prodotto_finito_id" e'
  // un array vero - vedi il commento in testa a
  // uRitiroRichiamoToolProvider.pas), quindi RegisterDynamicProvider come
  // TFilesToolsProvider/TNavigazioneToolProvider/TRicetteToolProvider, non
  // RegisterToolProvider.
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

  // Le due viste seguenti (anagrafica prodotto finito/semilavorato, senza
  // ricetta) erano registrate qui come stopgap prima che esistesse un
  // provider "proprietario" di scenario 1 - vedi la nota storica in
  // uRitiroRichiamoToolProvider.pas. Spostate qui sotto la registrazione
  // vera del provider a cui appartengono, stesso principio gia' seguito da
  // uRicetteToolProvider per 'ricetta_prodotto_finito' sopra: restano
  // dichiarate in uFrmMain (nessun tool le usa direttamente, sono aperte
  // dal frontend via apri_vista indipendentemente da quale tool ha
  // prodotto il risultato), ma accanto al provider che le rende rilevanti.
  //
  // A differenza di 'ricetta_prodotto_finito' (ricetta CORRENTE), queste
  // aprono la scheda ANAGRAFICA pura (codice, allergeni, scadenza standard
  // per i prodotti finiti): utili quando l'esito di un'operazione riguarda
  // l'anagrafica stessa (es. individuazione del prodotto/semilavorato
  // coinvolto in una non conformita', prima ancora di toccarne la ricetta).
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

  // NOTA PER LA RELAZIONE DI TIROCINIO: 'vendite' e 'dashboard' esistono e
  // funzionano lato frontend ma NON vengono registrate qui, per scelta di
  // design gia' documentata in testa a uRegistroViste.pas: i dati di
  // TVenditeToolProvider (scenario 2) stanno gia' bene in una tabella
  // dentro la chat, quindi aprire una vista aggiuntiva per lo stesso
  // risultato sarebbe ridondante; 'dashboard' non e' legata a un'entita'
  // specifica restituita da un tool, quindi non ha un "parametro" sensato
  // da ricevere da apri_vista. Se in futuro servisse comunque un link alla
  // dashboard o all'elenco vendite filtrato, la registrazione andrebbe qui
  // accanto, con ChiaviRichieste vuoto o pari ai filtri di
  // TServizioVendite.

  // AGGIORNAMENTO 02/10/2026 - la nota qui sopra e' superata per 'vendite'.
  // Con il pianificatore la tabella in chat non c'e' piu' sempre (la sintesi
  // racconta i dati, e oltre le prime righe li riduce): aprire l'elenco gia'
  // filtrato e' un approfondimento utile, non un doppione. Le due viste
  // qui sotto vengono proposte in due modi:
  //  - dal modello, con apri_vista ("apri le vendite di febbraio");
  //  - dal codice, con "apertura_vista"/"aperture_vista" nel risultato di
  //    get_list_vendite e apri_non_conformita_materia_prima (pulsante in
  //    chat, vedi i due provider): non dipende dal modello.
  // I nomi devono combaciare con App.RegistroViste.registra nel frontend
  // (views/view-vendite.js, views/view-tracciabilita.js).
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

  // Catalogo dei tool per l'orchestratore: costruito QUI, dopo tutte le
  // registrazioni sopra e prima di doStartServer, perche' fotografa i tool
  // presenti nel server MCP in questo istante e non viene piu' ricostruito
  // (vedi agente_ai/tool/uCatalogoTool.pas). Un provider registrato dopo questa
  // riga non finirebbe mai nell'elenco mandato al modello.
  //
  // Nel protocollo MCP "tools/list" e' fatto per essere chiamato una volta
  // e messo in cache dal client - esiste apposta la notifica
  // "notifications/tools/list_changed" per invalidarla. Interrogarlo ad
  // ogni turno di conversazione, come faceva TServizioAgente prima, non era
  // "piu' MCP": era solo lavoro ripetuto per ottenere sempre lo stesso
  // risultato.
  TCatalogoTool.Costruisci;
  TLog.Write(Format('Catalogo tool MCP costruito: %d tool disponibili.',
    [TCatalogoTool.Conteggio]));

  // Fase 1 dell'orchestratore (retrieval semantico): allinea
  // mcp_tool_indice ai tool appena fotografati sopra da TCatalogoTool.
  // Va DOPO quella chiamata (le serve l'elenco reale per convalidare le
  // righe) - vedi il commento in testa a uIndiceEmbeddingTool.pas.
  //
  // AVVIO ROBUSTO: prima un errore qui (LM Studio spento o modello di
  // embedding non caricato) interrompeva FormCreate PRIMA di doStartServer:
  // la finestra restava aperta ma il server non apriva mai la porta HTTP.
  // Con l'inferenza spostata sul PC dell'utente (vedi il documento di
  // progetto "inferenza sul PC dell'utente") il server puo' girare su una
  // macchina senza alcun LM Studio, quindi la sincronizzazione NON deve
  // piu' essere bloccante:
  //   - l'errore viene scritto nel log, ben visibile;
  //   - la tabella mcp_tool_indice resta com'era (Sincronizza scrive in
  //     un'unica transazione: o tutto o niente);
  //   - in conversazione SelezionaToolPerDomanda, se la ricerca semantica fallisce,
  //     ripiega gia' da solo sull'intero catalogo dei tool per quel turno.
  // Il server resta quindi pienamente funzionante, solo senza la riduzione
  // dei tool della fase 1 finche' gli embedding non tornano disponibili.
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
    //TLog.Write('Server gi� attivo.');
    Exit;
  end;

  IsMultiThread := True;

  // Registra la classe WebModule presso il dispatcher di WebBroker: senza
  // questa riga, TIdHTTPWebBrokerBridge non sa quale WebModule istanziare
  // per ogni richiesta e solleva EWebBrokerException 'No data modules
  // registered' alla prima richiesta in arrivo. WebModuleClass e'
  // dichiarata in uWebModule.pas (= TWebModule1).
  if WebRequestHandler <> nil then
    WebRequestHandler.WebModuleClass := WebModuleClass;

  // Porta letta da config.ini (sezione [Server], HttpPort) invece di un
  // valore fisso: prima coincidevano per caso (entrambi 8080), ma con due
  // fonti separate cambiare l'ini non avrebbe mai spostato la porta
  // reale del server - vedi anche l'URL MCP che LM Studio deve chiamare.
  FServer.DefaultPort := oConfig.HttpPort;
  WebRequestHandlerProc.MaxConnections := 1024;
  FServer.Active := True;

  TLog.Write('Server MCP avviato su http://localhost:' + oConfig.HttpPort.ToString);
  // StatusBar e' in modalita' SimplePanel (vedi .dfm: SimplePanel = True,
  // Panels = <> vuoto): il testo va scritto in SimpleText, non in
  // Panels[0].Text, che qui solleverebbe un EListError (indice fuori
  // range su una collezione vuota) mascherando il vero stato del server.
  StatusBar.SimpleText := 'Server: attivo';
end;

procedure TFrmMain.doStopServer;
begin
  if FServer.Active then
  begin
    FServer.Active := False;
    //TLog.Write('Server fermato.');
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
