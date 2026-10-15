unit AIAgentControllerU;

interface

uses
  System.SysUtils,
  System.JSON,
  MVCFramework,
  MVCFramework.Commons,
  uConfig,
  uServiziAgente;

type
  // Endpoint di dialogo con l'agente - protocollo "a passi".
  //
  // CHI FA COSA (decisione del 29/09/2026)
  // Il server fa TUTTO: prompt di sistema, selezione dei tool (fase 1, con
  // gli embedding), chiamata al modello, esecuzione dei tool MCP sul DB,
  // storico, guardie (link inventati, fallback testuale, paracadute) e
  // diagnostica. Il modello e' uno solo, configurato nell'ini ([LLM]
  // ChatEndpoint/ChatModel...) e gira sulla stessa macchina del server.
  // Il frontend e' "ignorante": non vede richieste o risposte del modello,
  // non conosce endpoint, formati o nomi dei modelli. Chiede soltanto di
  // far avanzare il turno e mostra la fase e le tracce dei tool.
  //
  // PERCHE' A PASSI E NON IN UNA SOLA RICHIESTA
  // Un turno puo' richiedere piu' chiamate al modello (tool -> risultato ->
  // altro tool -> risposta). Facendone UNA per richiesta HTTP:
  //   - la chat mostra l'avanzamento reale ("Il modello sta leggendo i
  //     dati", le tracce dei tool man mano che vengono eseguiti);
  //   - nessuna richiesta HTTP resta aperta per minuti;
  //   - un doppio invio non fa eseguire due volte gli stessi tool (vedi
  //     "passo" piu' sotto).
  //
  // FLUSSO DI UN TURNO
  //   1) POST /api/ai/turni   { "message": "...", "conversation_id": "..." (opz.) }
  //      Crea il turno e seleziona i tool. <- "in_corso" con passo = 1.
  //   2) POST /api/ai/turni/passo
  //        { "conversation_id", "turno_id", "numero_turno", "passo" }
  //      Il server chiama il modello ed elabora la risposta (eseguendo i
  //      tool richiesti). <- di nuovo "in_corso" con passo + 1, oppure
  //      "concluso".
  //   Si ripete 2) finche' lo stato non e' "concluso".
  //
  //   POST /api/ai/turni/annulla  { "conversation_id", "turno_id" }
  //      L'utente rinuncia: il turno viene scartato subito invece di
  //      aspettarne la scadenza.
  //
  // RISPOSTE
  //   { "stato": "in_corso", "conversation_id", "turno_id",
  //     "numero_turno", "passo",
  //     "fase": "Il modello sta leggendo i dati (passo 2)",
  //     "tool_calls_passo": [ tracce dei tool eseguiti in QUESTO passo ] }
  //
  //   { "stato": "concluso", "conversation_id", "turno_id", "numero_turno",
  //     "passo", "agent_response", "tool_calls": [...tutte...],
  //     "tool_calls_passo": [...], "diagnostica",
  //     ["limite_iterazioni": true] }
  //
  //   "fase" e' una frase gia' pronta per l'utente, decisa dal server (vedi
  //   TServizioAgente.DescriviFase): il client la mostra senza interpretarla.
  //
  //   400 corpo non valido
  //   404 turno sconosciuto o scaduto
  //   409 turno superato da uno piu' recente, passo non atteso (doppio
  //       invio) o passo gia' in elaborazione
  //   502 il motore di inferenza non risponde o risponde male: il turno
  //       viene scartato (nessun tool di quel passo e' stato eseguito)
  //   500 errore durante l'elaborazione: il turno viene scartato
  //   Il campo "message" dell'errore e' gia' il testo da mostrare.
  //
  // I TRE IDENTIFICATIVI
  //   conversation_id  la conversazione (storico dei messaggi).
  //   turno_id         GUID del turno: e' quello che il server controlla.
  //   numero_turno     progressivo leggibile, per log e interfaccia.
  //   passo            chiamata al modello dentro il turno: impedisce che
  //                    un retry faccia eseguire due volte gli stessi tool
  //                    (importante per quelli che scrivono sul DB, es. il
  //                    ritiro/richiamo dello scenario 1).
  //
  // CONFIGURAZIONE DEL MODELLO (pannello impostazioni della chat)
  // Il client puo' vedere e cambiare QUALE modello usa il server, ma non
  // lo chiama mai: la configurazione vive nell'ini del server, e' il server
  // a validarla e a scriverla.
  //   GET  /api/ai/configurazione-llm
  //     <- { "endpoint", "modello", "temperatura" (null = default del motore),
  //          "max_token", "timeout_ms" }
  //   PUT  /api/ai/configurazione-llm   stesso formato; i campi assenti
  //        restano come sono. Valida (400 + motivo), scrive l'ini e
  //        applica dal passo successivo. <- la configurazione salvata.
  //   POST /api/ai/configurazione-llm/modelli   { "endpoint" }
  //     <- { "endpoint", "modelli": [...] }  il SERVER interroga
  //        <endpoint>/models: serve a verificare un indirizzo prima di
  //        salvarlo e a scegliere il modello da un elenco. 502 se il motore
  //        non risponde.
  //   L'endpoint deve essere di questa macchina o della rete interna (vedi
  //   TConfig.EndpointAmmesso): i dati aziendali non escono.
  //   NB: oggi senza autenticazione chiunque apra il sito puo' cambiare il
  //   modello. Con il JWT (sviluppi futuri) va riservato a un amministratore.
  [MVCPath('/api/ai')]
  TAIAgentController = class(TMVCController)
  private
    // Stringa di un campo opzionale del corpo: '' se assente o null.
    function Campo(ARichiesta: TJSONObject; const ANome: string): string;
    // Risposta "in_corso" oppure "concluso" per lo stato dato. Se il turno
    // e' concluso consegna l'esito (lo stato non va piu' rimesso).
    // Restituisce True se lo stato va rimesso nell'archivio.
    function RispostaPerStato(AStato: TStatoTurno; out ARisposta: TJSONObject): Boolean;
    function ParseCorpo: TJSONObject;
    // Configurazione del modello nel formato JSON del pannello impostazioni.
    function ConfigChatToJSON(const AChat: TConfigChat): TJSONObject;
    // Applica ad AChat i campi presenti nel corpo. False + motivo se un
    // campo ha un tipo o un formato non valido.
    function LeggiConfigChat(ACorpo: TJSONObject; var AChat: TConfigChat;
      out AMotivo: string): Boolean;
  public
    [MVCPath('/turni')]
    [MVCHTTPMethod([httpPOST])]
    procedure AvviaTurno(ctx: TWebContext);

    [MVCPath('/turni/passo')]
    [MVCHTTPMethod([httpPOST])]
    procedure EseguiPasso(ctx: TWebContext);

    [MVCPath('/turni/annulla')]
    [MVCHTTPMethod([httpPOST])]
    procedure AnnullaTurno(ctx: TWebContext);

    [MVCPath('/configurazione-llm')]
    [MVCHTTPMethod([httpGET])]
    procedure LeggiConfigurazioneLLM(ctx: TWebContext);

    [MVCPath('/configurazione-llm')]
    [MVCHTTPMethod([httpPUT])]
    procedure SalvaConfigurazioneLLM(ctx: TWebContext);

    [MVCPath('/configurazione-llm/modelli')]
    [MVCHTTPMethod([httpPOST])]
    procedure ElencaModelliLLM(ctx: TWebContext);

    // GET /api/ai/contratti-tool - sola lettura, per la verifica dei
    // contratti (tappa 2 del porting del pianificatore). Per ogni tool del
    // catalogo: effetto, conferma, output_schema e schema di input
    // effettivo (quello del server + i vincoli del contratto). Il test
    // scripts/prototipo_pianificatore/tests/test_contratti_delphi.py lo
    // confronta con i contratti del prototipo Python.
    [MVCPath('/contratti-tool')]
    [MVCHTTPMethod([httpGET])]
    procedure ElencaContrattiTool(ctx: TWebContext);
  end;

implementation

uses
  uLog,
  uClientLLM,
  uCatalogoTool,
  uContrattiTool;

{ TAIAgentController }

function TAIAgentController.Campo(ARichiesta: TJSONObject; const ANome: string): string;
var
  LValore: TJSONValue;
begin
  Result := '';
  LValore := ARichiesta.GetValue(ANome);
  if (LValore <> nil) and not (LValore is TJSONNull) then
    Result := Trim(LValore.Value);
end;

function TAIAgentController.ParseCorpo: TJSONObject;
var
  LValore: TJSONValue;
begin
  LValore := TJSONObject.ParseJSONValue(Context.Request.Body);
  if LValore is TJSONObject then
    Exit(TJSONObject(LValore));
  LValore.Free;
  Result := nil;
end;

function TAIAgentController.RispostaPerStato(AStato: TStatoTurno;
  out ARisposta: TJSONObject): Boolean;
var
  LEsito: TEsitoConversazione;
  LTracce: TJSONArray;
  LTraccia: TTracciaTool;
  i: Integer;
begin
  ARisposta := TJSONObject.Create;
  try
    ARisposta.AddPair('conversation_id', AStato.Esito.ConversationID);
    ARisposta.AddPair('turno_id', AStato.TurnoID);
    ARisposta.AddPair('numero_turno', TJSONNumber.Create(AStato.NumeroTurno));
    ARisposta.AddPair('passo', TJSONNumber.Create(AStato.Passo));

    // Tracce dei tool eseguiti dall'ultima risposta consegnata. Si
    // costruiscono PRIMA di ConsegnaEsitoTurno, che toglie l'esito allo
    // stato. Il contatore avanza solo qui: se la risposta HTTP non
    // arrivasse al client quelle tracce andrebbero perse per l'ispettore
    // "live", ma restano comunque nel tool_calls completo di fine turno.
    LTracce := TJSONArray.Create;
    for i := AStato.TracceConsegnate to AStato.Esito.Tracce.Count - 1 do
      LTracce.AddElement(AStato.Esito.Tracce[i].ToJSONObject);
    AStato.TracceConsegnate := AStato.Esito.Tracce.Count;
    ARisposta.AddPair('tool_calls_passo', LTracce);

    if AStato.Fase <> ftConcluso then
    begin
      // Turno ancora aperto: al client basta sapere COSA dire all'utente
      // mentre aspetta il passo successivo.
      ARisposta.AddPair('stato', 'in_corso');
      ARisposta.AddPair('fase', TServizioAgente.DescriviFase(AStato));
      Exit(True);
    end;

    // Turno concluso: stesso contenuto che restituiva agent-chat, cosi' la
    // parte dell'interfaccia che mostra risposta, ispettore e tabelle non
    // cambia.
    LEsito := TServizioAgente.ConsegnaEsitoTurno(AStato);
    try
      ARisposta.AddPair('stato', 'concluso');
      ARisposta.AddPair('agent_response', LEsito.RispostaFinale);

      LTracce := TJSONArray.Create;
      for LTraccia in LEsito.Tracce do
        LTracce.AddElement(LTraccia.ToJSONObject);
      ARisposta.AddPair('tool_calls', LTracce);
      ARisposta.AddPair('diagnostica', LEsito.Diagnostica.ToJSONObject);
      // Solo motore "pianificatore": stato in cui resta il turno e dettaglio
      // (piano, candidati, errori di validazione, esiti dei passi).
      if LEsito.StatoTurno <> '' then
        ARisposta.AddPair('stato_turno', LEsito.StatoTurno);
      if LEsito.DatiPianificatore <> nil then
        ARisposta.AddPair('pianificatore', LEsito.DatiPianificatore.Clone as TJSONObject);
      if LEsito.LimiteRaggiunto then
        ARisposta.AddPair('limite_iterazioni', TJSONBool.Create(True));
    finally
      LEsito.Free;
    end;
    Result := False;
  except
    FreeAndNil(ARisposta);
    raise;
  end;
end;

procedure TAIAgentController.AvviaTurno(ctx: TWebContext);
var
  LRichiesta, LRisposta: TJSONObject;
  LMessaggio, LConversationID: string;
  LOpzioni: TOpzioniTurno;
  LStato: TStatoTurno;
  LChat: TConfigChat;
begin
  LRichiesta := ParseCorpo;
  if LRichiesta = nil then
  begin
    Render(HTTP_STATUS.BadRequest, 'Corpo della richiesta non valido.');
    Exit;
  end;

  try
    LMessaggio := Campo(LRichiesta, 'message');
    LConversationID := Campo(LRichiesta, 'conversation_id');
    if LMessaggio = '' then
    begin
      Render(HTTP_STATUS.BadRequest, 'Messaggio per l''agente mancante.');
      Exit;
    end;

    // Solo per diagnostica e CSV: il modello configurato in ini. Il client
    // non puo' sceglierlo.
    LChat := TConfig.GetInstance.Chat;
    LOpzioni.ProfiloLLM := LChat.Modello;
    if LOpzioni.ProfiloLLM = '' then
      LOpzioni.ProfiloLLM := '(modello caricato su ' + LChat.Endpoint + ')';
    // Override della batteria di test, letti solo con [Test] AbilitaOverride=1.
    LOpzioni.ModalitaOverride := '';
    LOpzioni.ModelloOverride := '';
    LOpzioni.MotoreOverride := '';
    LOpzioni.TestRun := '';
    LOpzioni.TestCaso := '';
    LOpzioni.TestRipetizione := '';
    // Pulsanti "Conferma" / "Annulla" della chat: campo facoltativo
    // "conferma" nel corpo, accanto a "message" (che resta obbligatorio: e'
    // il testo mostrato in chat e salvato nello storico). Vale solo se c'e'
    // davvero una scrittura in attesa di conferma, altrimenti e' ignorato
    // (vedi TTurnoPianificato.Avvia). Qualunque altro valore e' scartato.
    LOpzioni.SceltaConferma := LowerCase(Campo(LRichiesta, 'conferma'));
    if (LOpzioni.SceltaConferma <> 'conferma') and (LOpzioni.SceltaConferma <> 'annulla') then
      LOpzioni.SceltaConferma := '';
    if TConfig.GetInstance.AbilitaOverrideTest then
    begin
      LOpzioni.ModalitaOverride := Campo(LRichiesta, 'modalita_selezione');
      LOpzioni.ModelloOverride := Campo(LRichiesta, 'modello');
      // 'ciclo' o 'pianificatore': la batteria confronta i due motori sullo
      // stesso server senza riavviarlo.
      LOpzioni.MotoreOverride := Campo(LRichiesta, 'motore');
      // Etichetta del test (run, caso, ripetizione): finisce solo nei file di
      // diagnostica, per incrociarli con i risultati della batteria.
      LOpzioni.TestRun := Campo(LRichiesta, 'test_run');
      LOpzioni.TestCaso := Campo(LRichiesta, 'test_caso');
      LOpzioni.TestRipetizione := Campo(LRichiesta, 'test_ripetizione');
    end;

    TLog.Write('AGENTE - richiesta [' + LConversationID + ']: ' + LMessaggio);

    try
      LStato := TServizioAgente.CreaStatoTurno(LConversationID, LMessaggio, LOpzioni);
      try
        // La prima risposta e' sempre "in_corso" con passo 1: il modello
        // non e' ancora stato chiamato, cosi' la chat mostra subito "Il
        // modello sta pensando" invece di restare muta per tutta la prima
        // chiamata. Si costruisce PRIMA di registrare il turno, cosi' se
        // fallisce lo stato si libera qui e non resta orfano.
        RispostaPerStato(LStato, LRisposta);
      except
        LStato.Free;
        raise;
      end;
      TArchivioTurniAttivi.Registra(LStato);
      Render(LRisposta);
    except
      on E: Exception do
      begin
        TLog.Write('AGENTE - errore avvio turno: ' + E.Message);
        Render(HTTP_STATUS.InternalServerError, E.Message);
      end;
    end;
  finally
    LRichiesta.Free;
  end;
end;

procedure TAIAgentController.EseguiPasso(ctx: TWebContext);
var
  LRichiesta, LRisposta: TJSONObject;
  LConversationID, LTurnoID: string;
  LPasso: Integer;
  LStato: TStatoTurno;
  LEsitoPrelievo: TEsitoPrelievo;
begin
  LRichiesta := ParseCorpo;
  if LRichiesta = nil then
  begin
    Render(HTTP_STATUS.BadRequest, 'Corpo della richiesta non valido.');
    Exit;
  end;

  try
    LConversationID := Campo(LRichiesta, 'conversation_id');
    LTurnoID := Campo(LRichiesta, 'turno_id');
    LPasso := StrToIntDef(Campo(LRichiesta, 'passo'), 0);

    if (LConversationID = '') or (LTurnoID = '') or (LPasso < 1) then
    begin
      Render(HTTP_STATUS.BadRequest, 'conversation_id, turno_id e passo sono obbligatori.');
      Exit;
    end;

    LEsitoPrelievo := TArchivioTurniAttivi.Preleva(LConversationID, LTurnoID, LPasso, LStato);
    case LEsitoPrelievo of
      epSconosciuto:
        begin
          Render(HTTP_STATUS.NotFound, 'Il turno e'' scaduto o il server e'' stato riavviato. Ripeti la domanda.');
          Exit;
        end;
      epSuperato:
        begin
          Render(HTTP_STATUS.Conflict, 'Il turno e'' stato superato da una domanda piu'' recente.');
          Exit;
        end;
      epPassoErrato:
        begin
          Render(HTTP_STATUS.Conflict, 'Passo non atteso (richiesta duplicata o fuori ordine). Ripeti la domanda.');
          Exit;
        end;
      epInElaborazione:
        begin
          Render(HTTP_STATUS.Conflict, 'Il passo precedente di questo turno e'' ancora in elaborazione.');
          Exit;
        end;
    end;

    // Da qui lo stato e' nostro (nessun'altra richiesta puo' toccarlo
    // finche' non lo si rimette). Ogni errore scarta il turno: un errore
    // del modello arriva prima dei tool, ma un errore a meta' elaborazione
    // potrebbe averne gia' eseguiti alcuni, e ripetere il passo
    // rischierebbe di rieseguirli.
    try
      // Il passo vero e proprio: chiamata al modello + tool richiesti.
      TServizioAgente.EseguiPassoLLM(LStato);
      if LStato.Fase <> ftConcluso then
        LStato.Passo := LStato.Passo + 1;

      if LStato.Fase = ftConcluso then
      begin
        // Chiude PRIMA di consegnare: se nel frattempo e' partito un turno
        // nuovo questo non deve finire nello storico.
        if not TArchivioTurniAttivi.Chiudi(LConversationID, LTurnoID) then
        begin
          FreeAndNil(LStato);
          Render(HTTP_STATUS.Conflict, 'Il turno e'' stato superato da una domanda piu'' recente.');
          Exit;
        end;
        RispostaPerStato(LStato, LRisposta);
        FreeAndNil(LStato);
      end
      else
      begin
        RispostaPerStato(LStato, LRisposta);
        // Rimetti libera lo stato se nel frattempo il turno e' stato superato.
        if not TArchivioTurniAttivi.Rimetti(LStato) then
        begin
          LStato := nil;
          LRisposta.Free;
          Render(HTTP_STATUS.Conflict, 'Il turno e'' stato superato da una domanda piu'' recente.');
          Exit;
        end;
        LStato := nil;
      end;
      Render(LRisposta);
    except
      on E: Exception do
      begin
        TLog.Write('AGENTE - errore nel passo ' + LPasso.ToString + ' [' +
          LConversationID + ']: ' + E.Message);
        if LStato <> nil then
        begin
          TArchivioTurniAttivi.Chiudi(LConversationID, LTurnoID);
          LStato.Free;
        end;
        // 502 = il problema e' nel motore di inferenza (spento, timeout,
        // risposta malformata), non nel gestionale: il client mostra il
        // messaggio cosi' com'e'.
        if E is ELLMErrore then
          Render(502, E.Message)   // 502 Bad Gateway
        else
          Render(HTTP_STATUS.InternalServerError, E.Message);
      end;
    end;
  finally
    LRichiesta.Free;
  end;
end;

procedure TAIAgentController.AnnullaTurno(ctx: TWebContext);
var
  LRichiesta: TJSONObject;
  LConversationID, LTurnoID: string;
begin
  LRichiesta := ParseCorpo;
  if LRichiesta = nil then
  begin
    Render(HTTP_STATUS.BadRequest, 'Corpo della richiesta non valido.');
    Exit;
  end;
  try
    LConversationID := Campo(LRichiesta, 'conversation_id');
    LTurnoID := Campo(LRichiesta, 'turno_id');
    // Idempotente: annullare un turno gia' chiuso o scaduto non e' un errore.
    if TArchivioTurniAttivi.Chiudi(LConversationID, LTurnoID) then
      TLog.Write('AGENTE - turno annullato dal client [' + LConversationID + ']');
    Render(TJSONObject.Create.AddPair('stato', 'annullato'));
  finally
    LRichiesta.Free;
  end;
end;

{ Configurazione del modello }

function TAIAgentController.ConfigChatToJSON(const AChat: TConfigChat): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('endpoint', AChat.Endpoint);
  Result.AddPair('modello', AChat.Modello);
  if AChat.HaTemperatura then
    Result.AddPair('temperatura', TJSONNumber.Create(AChat.Temperatura))
  else
    Result.AddPair('temperatura', TJSONNull.Create);
  Result.AddPair('max_token', TJSONNumber.Create(AChat.MaxToken));
  Result.AddPair('timeout_ms', TJSONNumber.Create(AChat.TimeoutMs));
end;

function TAIAgentController.LeggiConfigChat(ACorpo: TJSONObject;
  var AChat: TConfigChat; out AMotivo: string): Boolean;

  // Numero da un campo JSON: accetta sia un numero sia una stringa (un
  // <input> HTML restituisce testo), con punto o virgola decimale.
  function Numero(const ANome: string; out AValore: Double): Boolean;
  var
    LValore: TJSONValue;
  begin
    LValore := ACorpo.GetValue(ANome);
    if LValore is TJSONNumber then
    begin
      AValore := TJSONNumber(LValore).AsDouble;
      Exit(True);
    end;
    Result := (LValore is TJSONString) and
      TryStrToFloat(StringReplace(Trim(LValore.Value), ',', '.', []), AValore,
        TFormatSettings.Invariant);
  end;

  function Intero(const ANome: string; var AValore: Integer): Boolean;
  var
    LNumero: Double;
  begin
    if ACorpo.GetValue(ANome) = nil then
      Exit(True);                    // assente: resta com'e'
    Result := Numero(ANome, LNumero) and (Frac(LNumero) = 0) and
      (Abs(LNumero) <= MaxInt);
    if Result then
      AValore := Trunc(LNumero)
    else
      AMotivo := ANome + ' deve essere un numero intero';
  end;

var
  LValore: TJSONValue;
  LTemperatura: Double;
begin
  Result := False;
  AMotivo := '';

  if ACorpo.GetValue('endpoint') <> nil then
    AChat.Endpoint := Campo(ACorpo, 'endpoint');
  if ACorpo.GetValue('modello') <> nil then
    AChat.Modello := Campo(ACorpo, 'modello');

  // temperatura: null o "" = nessuna (default del motore).
  LValore := ACorpo.GetValue('temperatura');
  if LValore <> nil then
  begin
    if (LValore is TJSONNull) or ((LValore is TJSONString) and (Trim(LValore.Value) = '')) then
      AChat.HaTemperatura := False
    else if Numero('temperatura', LTemperatura) then
    begin
      AChat.HaTemperatura := True;
      AChat.Temperatura := LTemperatura;
    end
    else
    begin
      AMotivo := 'temperatura deve essere un numero (es. 0.2) oppure vuota';
      Exit;
    end;
  end;

  if not Intero('max_token', AChat.MaxToken) then
    Exit;
  if not Intero('timeout_ms', AChat.TimeoutMs) then
    Exit;

  Result := True;
end;

procedure TAIAgentController.LeggiConfigurazioneLLM(ctx: TWebContext);
begin
  Render(ConfigChatToJSON(TConfig.GetInstance.Chat));
end;

procedure TAIAgentController.SalvaConfigurazioneLLM(ctx: TWebContext);
var
  LCorpo: TJSONObject;
  LChat: TConfigChat;
  LMotivo: string;
begin
  LCorpo := ParseCorpo;
  if LCorpo = nil then
  begin
    Render(HTTP_STATUS.BadRequest, 'Corpo della richiesta non valido.');
    Exit;
  end;
  try
    // Si parte dalla configurazione attuale: i campi assenti restano uguali.
    LChat := TConfig.GetInstance.Chat;
    if not LeggiConfigChat(LCorpo, LChat, LMotivo) or
       not TConfig.ValidaChat(LChat, LMotivo) then
    begin
      Render(HTTP_STATUS.BadRequest, 'Configurazione non valida: ' + LMotivo + '.');
      Exit;
    end;

    try
      TConfig.GetInstance.SalvaChat(LChat);
    except
      on E: Exception do
      begin
        TLog.Write('AGENTE - impossibile salvare la configurazione del modello: ' + E.Message);
        Render(HTTP_STATUS.InternalServerError,
          'Impossibile scrivere il file di configurazione del server: ' + E.Message);
        Exit;
      end;
    end;

    LChat := TConfig.GetInstance.Chat;
    TLog.Write(Format('AGENTE - configurazione del modello aggiornata dal client: %s, modello "%s"',
      [LChat.Endpoint, LChat.Modello]));
    Render(ConfigChatToJSON(LChat));
  finally
    LCorpo.Free;
  end;
end;

procedure TAIAgentController.ElencaModelliLLM(ctx: TWebContext);
var
  LCorpo, LRisposta: TJSONObject;
  LEndpoint, LMotivo, LModello: string;
  LModelli: TJSONArray;
begin
  LCorpo := ParseCorpo;
  if LCorpo = nil then
  begin
    Render(HTTP_STATUS.BadRequest, 'Corpo della richiesta non valido.');
    Exit;
  end;
  try
    // Endpoint da verificare (anche non ancora salvato); assente = quello attivo.
    LEndpoint := Campo(LCorpo, 'endpoint');
    if LEndpoint = '' then
      LEndpoint := TConfig.GetInstance.Chat.Endpoint;

    // Stesso controllo del salvataggio: il server non contatta indirizzi
    // esterni nemmeno per una semplice verifica.
    if not TConfig.EndpointAmmesso(LEndpoint, LMotivo) then
    begin
      Render(HTTP_STATUS.BadRequest, 'Indirizzo non ammesso: ' + LMotivo);
      Exit;
    end;

    try
      LModelli := TJSONArray.Create;
      try
        for LModello in TClientLLM.ElencaModelli(LEndpoint) do
          LModelli.Add(LModello);
        LRisposta := TJSONObject.Create;
        LRisposta.AddPair('endpoint', LEndpoint);
        LRisposta.AddPair('modelli', LModelli);
        LModelli := nil;                 // ora appartiene a LRisposta
      finally
        LModelli.Free;
      end;
      Render(LRisposta);
    except
      on E: ELLMErrore do
        Render(502, E.Message);          // 502 Bad Gateway: il motore non risponde
    end;
  finally
    LCorpo.Free;
  end;
end;

// Schema dei parametri che il server dichiara per ANome (campo "parameters"
// del catalogo, cioe' l'inputSchema di tools/list). Riferimento interno al
// catalogo: NON va liberato. nil se il tool non e' nel catalogo.
function SchemaServerDelTool(const ANome: string): TJSONObject;
var
  LVoce: TJSONValue;
  LFunzione: TJSONValue;
begin
  Result := nil;
  for LVoce in TCatalogoTool.Definizioni do
  begin
    if not (LVoce is TJSONObject) then
      Continue;
    LFunzione := TJSONObject(LVoce).GetValue('function');
    if (LFunzione is TJSONObject) and (TJSONObject(LFunzione).GetValue('name') <> nil) and
       SameText(TJSONObject(LFunzione).GetValue('name').Value, ANome) then
    begin
      if TJSONObject(LFunzione).GetValue('parameters') is TJSONObject then
        Result := TJSONObject(TJSONObject(LFunzione).GetValue('parameters'));
      Exit;
    end;
  end;
end;

procedure TAIAgentController.ElencaContrattiTool(ctx: TWebContext);
var
  LRisposta: TJSONObject;
  LTools, LSenzaContratto: TJSONArray;
  LVoce: TJSONObject;
  LDefinizione, LFunzione: TJSONValue;
  LContratto: TContrattoTool;
  LNome: string;
begin
  LRisposta := TJSONObject.Create;
  try
    LTools := TJSONArray.Create;
    LRisposta.AddPair('tools', LTools);
    // Tool esposti dal server per cui nessun provider ha dichiarato un
    // contratto: il pianificatore non potrebbe usarli (deve restare vuoto).
    LSenzaContratto := TJSONArray.Create;
    LRisposta.AddPair('tool_senza_contratto', LSenzaContratto);

    // Si parte dal CATALOGO (i tool che il server espone davvero), non dal
    // registro dei contratti: cosi' un tool dimenticato si vede.
    for LDefinizione in TCatalogoTool.Definizioni do
    begin
      if not (LDefinizione is TJSONObject) then
        Continue;
      LFunzione := TJSONObject(LDefinizione).GetValue('function');
      if not (LFunzione is TJSONObject) or (TJSONObject(LFunzione).GetValue('name') = nil) then
        Continue;
      LNome := TJSONObject(LFunzione).GetValue('name').Value;

      if not TRegistroContrattiTool.Trova(LNome, LContratto) then
      begin
        LSenzaContratto.Add(LNome);
        Continue;
      end;

      LVoce := TJSONObject.Create;
      LTools.AddElement(LVoce);
      LVoce.AddPair('nome', LNome);
      LVoce.AddPair('effetto', EffettoInTesto(LContratto.Effetto));
      LVoce.AddPair('richiede_conferma', TJSONBool.Create(LContratto.RichiedeConferma));
      // Gia' verificato come oggetto JSON alla registrazione.
      LVoce.AddPair('output_schema', TJSONObject.ParseJSONValue(LContratto.OutputSchema));
      LVoce.AddPair('input_schema', SchemaInputEffettivo(LContratto, SchemaServerDelTool(LNome)));
    end;

    Render(LRisposta);
  except
    on E: Exception do
    begin
      LRisposta.Free;
      Render(HTTP_STATUS.InternalServerError, E.Message);
    end;
  end;
end;

end.
