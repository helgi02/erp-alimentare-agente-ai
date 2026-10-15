unit uServiziAgente;

interface

uses
  System.SysUtils,
  System.Classes,
  System.JSON,
  System.SyncObjs,
  System.Generics.Collections,
  System.Diagnostics,
  TextFileWriterU,
  uConfig;

type
  TTracciaTool = class
  public
    Nome: string;
    ArgomentiJSON: string;
    RisultatoJSON: string;
    DurataMs: Int64;
    Riuscita: Boolean;
    function ToJSONObject: TJSONObject;
  end;

  TModalitaSelezione = (msTutti, msTopKTool, msProviderRango, msProviderMargine,
    msProviderCompleto);

  TOpzioniTurno = record
    ModalitaOverride: string;
    ModelloOverride: string;
    // Solo batteria di test: 'ciclo' o 'pianificatore' per questo turno,
    // al posto di [Orchestratore] Motore dell'ini.
    MotoreOverride: string;
    // Solo batteria di test: da quale run, caso e ripetizione arriva il
    // turno. Il server non li usa: li riporta nei file di diagnostica, cosi'
    // ogni riga del registro si aggancia alla riga dei risultati dello script.
    TestRun: string;
    TestCaso: string;
    TestRipetizione: string;
    ProfiloLLM: string;
    // Solo motore "pianificatore": risposta alla richiesta di conferma data
    // con i pulsanti della chat ('conferma' o 'annulla'; '' = l'utente ha
    // scritto del testo). Con il pulsante la scelta e' gia' certa, quindi
    // TTurnoPianificato.PassoConferma non chiama il modello per leggerla.
    SceltaConferma: string;
  end;

  TVoceSelezione = record
    Provider: string;
    NomeTool: string;
    Similarita: Double;
    Stato: string;
  end;

  TChiamataLLM = record
    Iterazione: Integer;
    DurataMs: Int64;
    PromptTokens: Integer;
    CompletionTokens: Integer;
    TotaleTokens: Integer;
  end;

  TDiagnosticaTurno = class
  public
    ConversationID: string;
    NumeroTurno: Integer;
    Domanda: string;
    Modalita: string;
    ModelloLLM: string;
    ProfiloLLM: string;
    FallbackCatalogo: Boolean;
    DurataFase1Ms: Int64;
    DurataTotaleMs: Int64;
    ToolCatalogo: Integer;
    ToolInviati: Integer;
    CaratteriDefinizioniTool: Integer;
    ProviderSelezionati: TArray<string>;
    ProviderRecenti: TArray<string>;
    ToolChiamati: TArray<string>;
    Voci: TList<TVoceSelezione>;
    Chiamate: TList<TChiamataLLM>;
    constructor Create;
    destructor Destroy; override;
    function PromptTokensTotali: Integer;
    function CompletionTokensTotali: Integer;
    function PromptTokensPrimaChiamata: Integer;
    function DurataLLMTotaleMs: Int64;
    function ToJSONObject: TJSONObject;
  end;

  TEsitoConversazione = class
  public
    ConversationID: string;
    RispostaFinale: string;
    Tracce: TObjectList<TTracciaTool>;
    Iterazioni: Integer;
    LimiteRaggiunto: Boolean;
    Diagnostica: TDiagnosticaTurno;
    // Solo motore "pianificatore": stato in cui resta il turno (concluso,
    // in_attesa_conferma, in_attesa_scelta) e dettaglio di cio' che e'
    // successo (piano, candidati, errori, esiti). Di proprieta' dell'esito.
    StatoTurno: string;
    DatiPianificatore: TJSONObject;
    constructor Create;
    destructor Destroy; override;
  end;

  TFaseTurno = (ftCiclo, ftParacadute, ftConcluso);

  TStatoTurno = class
  public
    Messaggi: TJSONArray;
    Tools: TJSONArray;
    ToolsProprietario: Boolean;
    Opzioni: TOpzioniTurno;
    // Identita' del turno nel protocollo con il client (vedi
    // TArchivioTurniAttivi e docs/protocollo_turni_client_llm.md):
    //   TurnoID      GUID generato alla creazione: e' la chiave con cui il
    //                server riconosce il turno. Serve perche' NumeroTurno
    //                da solo non e' univoco: un turno abbandonato non viene
    //                salvato nello storico, quindi il turno successivo
    //                riceverebbe lo stesso numero e una risposta in ritardo
    //                del vecchio turno verrebbe scambiata per quella nuova.
    //   NumeroTurno  progressivo leggibile (1, 2, 3...) delle domande
    //                dell'utente nella conversazione: per log, CSV e
    //                interfaccia, non per la validazione.
    //   Passo        numero della richiesta al modello DENTRO il turno
    //                (1 = prima richiesta, poi +1 dopo ogni risposta
    //                elaborata). Il client deve rimandare lo stesso numero
    //                che ha ricevuto: cosi' un doppio invio o un retry di
    //                rete non fa eseguire due volte gli stessi tool.
    TurnoID: string;
    NumeroTurno: Integer;
    Passo: Integer;
    // Ultima volta che il turno e' stato toccato: per scartare i turni che
    // il client ha abbandonato (pagina chiusa, LLM locale spento...).
    UltimoAccesso: TDateTime;
    // Quante tracce di Esito.Tracce sono gia' state consegnate al client.
    // Ogni risposta del protocollo porta solo quelle nuove
    // ("tool_calls_passo"), cosi' la chat puo' mostrare i tool man mano
    // che vengono eseguiti invece che tutti insieme a fine turno.
    TracceConsegnate: Integer;
    Fase: TFaseTurno;
    Iterazione: Integer;
    CronometroTotale: TStopwatch;
    Esito: TEsitoConversazione;
    // nil con il motore "ciclo". Con il motore "pianificatore" e' il
    // TTurnoPianificato (uTurnoPianificato.pas) che guida il turno; il
    // tipo e' TObject per non far dipendere questa unit da quella. Di
    // proprieta' dello stato.
    Pianificatore: TObject;
    destructor Destroy; override;
  end;

  TServizioAgente = class
  private
    class var FLogSelezione: TTextFileWriter;
    class var FCsvSelezione: TTextFileWriter;
    class function ChiudiCicloTool(AStato: TStatoTurno): Boolean;
    class function ScegliModalitaSelezioneToolTraOverrideEIni(const AOpzioni: TOpzioniTurno): TModalitaSelezione;
    class function ContaTurniUtente(AMessaggi: TJSONArray): Integer;
    class procedure ScriviCsvSelezioneTool(ADiagnostica: TDiagnosticaTurno);
    class function EstraiMessaggioAssistente(ARisposta: TJSONObject): TJSONObject;
    class function CreaMessaggioRisultatoTool(const AToolCallID, ANome,
      ARisultato: string): TJSONObject;
    class function EstraiToolCallDalTesto(const AContenuto: string;
      out ANomeTool: string; out AArgomenti: TJSONObject): Boolean;
    class function CreaPromptDiSistema: string;
    class function ContieneLinkNonValido(const AContenuto: string): Boolean;
    class function UltimiMessaggi(AMessaggi: TJSONArray): TJSONArray;
    class function ProviderUsatiDiRecente(AMessaggi: TJSONArray): TArray<string>;
    class function SelezionaToolPerDomanda(const ATesto: string; AStoricoMessaggi: TJSONArray;
      AModalita: TModalitaSelezione; ADiagnostica: TDiagnosticaTurno;
      out AProprietario: Boolean): TJSONArray;
    class procedure ScriviLogSelezione(const AMessaggio: string);
    class constructor Create;
    class destructor Destroy;
  public
    // Il turno avanza a passi, e a ogni passo e' il SERVER a chiamare il
    // modello (TClientLLM, configurazione unica in [LLM] dell'ini). Il
    // client si limita a chiedere "fai il passo successivo" e a mostrare la
    // fase: non vede mai richieste o risposte del modello.
    //   CreaStatoTurno -> [EseguiPassoLLM]* -> ConsegnaEsitoTurno
    // dove EseguiPassoLLM = PreparaRichiestaLLM -> TClientLLM.Completa ->
    // ValidaRispostaLLM -> ElaboraRispostaLLM.
    // Fra un passo e l'altro lo stato vive in TArchivioTurniAttivi.
    class function CreaStatoTurno(const AConversationID, AMessaggioUtente: string;
      const AOpzioni: TOpzioniTurno): TStatoTurno;
    // Richiesta per il modello (formato interno chat/completions), da liberare.
    class function PreparaRichiestaLLM(AStato: TStatoTurno): TJSONObject;
    // Controllo di forma della risposta del modello PRIMA di toccare lo
    // stato: un modello piccolo puo' produrre tool_calls incomplete.
    class function ValidaRispostaLLM(ARisposta: TJSONObject; out AMotivo: string): Boolean;
    class function ElaboraRispostaLLM(AStato: TStatoTurno; ARisposta: TJSONObject;
      ADurataMs: Int64): Boolean;
    // Un passo completo: chiama il modello ed elabora la sua risposta
    // (eseguendo i tool richiesti). True = turno concluso. Solleva
    // ELLMErrore (uClientLLM) se il motore di inferenza non risponde.
    class function EseguiPassoLLM(AStato: TStatoTurno): Boolean;
    // Frase che descrive all'utente cosa fara' il PROSSIMO passo (es. "Il
    // modello sta leggendo i dati"): la decide il server, cosi' il client
    // la mostra senza dover interpretare nulla.
    class function DescriviFase(AStato: TStatoTurno): string;
    class function ConsegnaEsitoTurno(AStato: TStatoTurno): TEsitoConversazione;
    // Token e durata di una chiamata al modello nella diagnostica del turno.
    // Pubblica perche' la usa anche il motore "pianificatore".
    class procedure RegistraTokenChiamataLLM(ADiagnostica: TDiagnosticaTurno;
      AIterazione: Integer; ARisposta: TJSONObject; ADurataMs: Int64);
    // True se questo turno va gestito dal motore "pianificatore": override
    // della batteria di test se presente, altrimenti [Orchestratore] Motore.
    class function MotorePianificatore(const AOpzioni: TOpzioniTurno): Boolean;
  end;

  // Esito di TArchivioTurniAttivi.Preleva, tradotto dal controller in uno
  // status HTTP (404 turno sconosciuto/scaduto, 409 turno superato o passo
  // non atteso o gia' in elaborazione).
  TEsitoPrelievo = (epOk, epSconosciuto, epSuperato, epPassoErrato, epInElaborazione);

  // Turni in corso, uno per conversazione, fra una risposta del client e la
  // successiva. Prima tutto il turno viveva nello stack di una sola richiesta
  // HTTP; ora dura piu' richieste, quindi lo stato va parcheggiato qui.
  //
  // Schema "preleva / rimetti": chi elabora un passo PRELEVA lo stato (che
  // resta segnato come in elaborazione) e lo RIMETTE a fine passo. Il lock
  // globale e' tenuto solo per le operazioni sul dizionario, mai durante
  // l'esecuzione dei tool: due conversazioni diverse avanzano in parallelo,
  // mentre due richieste sullo stesso turno si escludono a vicenda (la
  // seconda riceve epInElaborazione).
  TArchivioTurniAttivi = class
  private
    class var FLock: TCriticalSection;
    // conversation_id -> stato del turno (nil = prelevato, in elaborazione)
    class var FTurni: TObjectDictionary<string, TStatoTurno>;
    // conversation_id -> turno_id del turno CORRENTE. Separato da FTurni
    // perche' deve esistere anche mentre lo stato e' prelevato: e' cio' che
    // permette di accorgersi che nel frattempo e' partito un turno nuovo.
    class var FTurnoCorrente: TDictionary<string, string>;
    class procedure RimuoviScaduti;
  public
    class constructor Create;
    class destructor Destroy;
    // Registra un turno appena creato come turno corrente della sua
    // conversazione. Un turno precedente ancora aperto viene abbandonato:
    // se il client riparte con una nuova domanda, quella vecchia non
    // interessa piu' a nessuno.
    class procedure Registra(AStato: TStatoTurno);
    class function Preleva(const AConversationID, ATurnoID: string; APasso: Integer;
      out AStato: TStatoTurno): TEsitoPrelievo;
    // Rimette lo stato dopo un passo. Se nel frattempo e' partito un turno
    // nuovo, questo e' superato: viene liberato e il risultato e' False.
    class function Rimetti(AStato: TStatoTurno): Boolean;
    // Chiude il turno (concluso o annullato) togliendolo dall'archivio. Se
    // era parcheggiato lo stato viene liberato qui; se era prelevato resta
    // a carico di chi lo ha prelevato. True = era ancora il turno corrente.
    class function Chiudi(const AConversationID, ATurnoID: string): Boolean;
  end;

  TArchivioConversazioni = class
  private
    class var FLock: TCriticalSection;
    class var FConversazioni: TObjectDictionary<string, TJSONArray>;
    class var FUltimoAccesso: TDictionary<string, TDateTime>;
    class procedure RimuoviScadute;
  public
    class constructor Create;
    class destructor Destroy;

    class function Leggi(const AID: string): TJSONArray;
    class procedure Scrivi(const AID: string; AMessaggi: TJSONArray);
    class function NuovoID: string;
  end;

implementation

uses
  System.DateUtils,
  System.Net.HttpClient,
  System.Net.HttpClientComponent,
  System.RegularExpressions,
  System.IOUtils,
  uMCPBridge,
  uCatalogoTool,
  uIndiceEmbeddingTool,
  uRegistroProviderMCP,
  uClientLLM,
  uTurnoPianificato,
  uLog;

function ConvertiModalitaSelezioneToolInStringa(AModalita: TModalitaSelezione): string;
begin
  case AModalita of
    msTutti:           Result := 'tutti';
    msTopKTool:        Result := 'topk_tool';
    msProviderRango:   Result := 'provider_rango';
    msProviderMargine: Result := 'provider_margine';
  else
    Result := 'provider_completo';
  end;
end;

function ConvertiStringaInModalitaSelezioneTool(const ANome: string; out AModalita: TModalitaSelezione): Boolean;
begin
  Result := True;
  if SameText(ANome, 'tutti') then
    AModalita := msTutti
  else if SameText(ANome, 'topk_tool') then
    AModalita := msTopKTool
  else if SameText(ANome, 'provider_rango') then
    AModalita := msProviderRango
  else if SameText(ANome, 'provider_margine') then
    AModalita := msProviderMargine
  else if SameText(ANome, 'provider_completo') then
    AModalita := msProviderCompleto
  else
  begin
    AModalita := msProviderCompleto;
    Result := False;
  end;
end;

const

  MAX_ITERAZIONI = 8;

  TTL_CONVERSAZIONE_MINUTI = 60;

  // Tempo massimo di attesa fra due passi dello stesso turno (pagina chiusa
  // a meta' turno). Largo perche' un passo comprende la risposta del
  // modello: un 9B su CPU puo' metterci minuti per una sola richiesta.
  TTL_TURNO_ATTIVO_MINUTI = 15;

  MAX_TURNI_FINESTRA = 6;

{ TTracciaTool }

function TTracciaTool.ToJSONObject: TJSONObject;
var
  LArgomenti, LRisultato: TJSONValue;
begin
  Result := TJSONObject.Create;
  Result.AddPair('tool', Nome);

  LArgomenti := TJSONObject.ParseJSONValue(ArgomentiJSON);
  if LArgomenti <> nil then
    Result.AddPair('arguments', LArgomenti)
  else
    Result.AddPair('arguments', TJSONObject.Create);

  LRisultato := TJSONObject.ParseJSONValue(RisultatoJSON);
  if LRisultato <> nil then
    Result.AddPair('result', LRisultato)
  else
    Result.AddPair('result', RisultatoJSON);

  Result.AddPair('duration_ms', TJSONNumber.Create(DurataMs));
  Result.AddPair('ok', TJSONBool.Create(Riuscita));
end;

{ TDiagnosticaTurno }

constructor TDiagnosticaTurno.Create;
begin
  inherited;
  Voci := TList<TVoceSelezione>.Create;
  Chiamate := TList<TChiamataLLM>.Create;
end;

destructor TDiagnosticaTurno.Destroy;
begin
  Voci.Free;
  Chiamate.Free;
  inherited;
end;

function TDiagnosticaTurno.PromptTokensTotali: Integer;
var
  LChiamata: TChiamataLLM;
begin
  Result := -1;
  for LChiamata in Chiamate do
    if LChiamata.PromptTokens >= 0 then
    begin
      if Result < 0 then
        Result := 0;
      Inc(Result, LChiamata.PromptTokens);
    end;
end;

function TDiagnosticaTurno.CompletionTokensTotali: Integer;
var
  LChiamata: TChiamataLLM;
begin
  Result := -1;
  for LChiamata in Chiamate do
    if LChiamata.CompletionTokens >= 0 then
    begin
      if Result < 0 then
        Result := 0;
      Inc(Result, LChiamata.CompletionTokens);
    end;
end;

function TDiagnosticaTurno.PromptTokensPrimaChiamata: Integer;
begin
  if Chiamate.Count > 0 then
    Result := Chiamate[0].PromptTokens
  else
    Result := -1;
end;

function TDiagnosticaTurno.DurataLLMTotaleMs: Int64;
var
  LChiamata: TChiamataLLM;
begin
  Result := 0;
  for LChiamata in Chiamate do
    Inc(Result, LChiamata.DurataMs);
end;

function TDiagnosticaTurno.ToJSONObject: TJSONObject;
var
  LVoce: TVoceSelezione;
  LChiamata: TChiamataLLM;
  LArrayVoci, LArrayChiamate, LArrayProvider, LArrayRecenti, LArrayChiamati: TJSONArray;
  LOggetto: TJSONObject;
  LNome: string;

  procedure AggiungiIntero(AOggetto: TJSONObject; const ANome: string; AValore: Integer);
  begin
    if AValore >= 0 then
      AOggetto.AddPair(ANome, TJSONNumber.Create(AValore))
    else
      AOggetto.AddPair(ANome, TJSONNull.Create);
  end;
begin
  Result := TJSONObject.Create;
  Result.AddPair('conversation_id', ConversationID);
  Result.AddPair('numero_turno', TJSONNumber.Create(NumeroTurno));
  Result.AddPair('modalita_selezione', Modalita);
  Result.AddPair('modello', ModelloLLM);
  Result.AddPair('profilo_llm', ProfiloLLM);
  Result.AddPair('fallback_catalogo', TJSONBool.Create(FallbackCatalogo));
  Result.AddPair('durata_fase1_ms', TJSONNumber.Create(DurataFase1Ms));
  Result.AddPair('durata_llm_ms', TJSONNumber.Create(DurataLLMTotaleMs));
  Result.AddPair('durata_totale_ms', TJSONNumber.Create(DurataTotaleMs));
  Result.AddPair('tool_catalogo', TJSONNumber.Create(ToolCatalogo));
  Result.AddPair('tool_inviati', TJSONNumber.Create(ToolInviati));
  Result.AddPair('caratteri_definizioni_tool', TJSONNumber.Create(CaratteriDefinizioniTool));
  AggiungiIntero(Result, 'prompt_tokens_prima_chiamata', PromptTokensPrimaChiamata);
  AggiungiIntero(Result, 'prompt_tokens_totali', PromptTokensTotali);
  AggiungiIntero(Result, 'completion_tokens_totali', CompletionTokensTotali);

  LArrayProvider := TJSONArray.Create;
  for LNome in ProviderSelezionati do
    LArrayProvider.Add(LNome);
  Result.AddPair('provider_selezionati', LArrayProvider);

  LArrayRecenti := TJSONArray.Create;
  for LNome in ProviderRecenti do
    LArrayRecenti.Add(LNome);
  Result.AddPair('provider_recenti', LArrayRecenti);

  LArrayChiamati := TJSONArray.Create;
  for LNome in ToolChiamati do
    LArrayChiamati.Add(LNome);
  Result.AddPair('tool_chiamati', LArrayChiamati);

  LArrayVoci := TJSONArray.Create;
  for LVoce in Voci do
  begin
    LOggetto := TJSONObject.Create;
    LOggetto.AddPair('provider', LVoce.Provider);
    LOggetto.AddPair('tool', LVoce.NomeTool);
    if LVoce.Similarita >= 0 then
      LOggetto.AddPair('similarita', TJSONNumber.Create(LVoce.Similarita))
    else
      LOggetto.AddPair('similarita', TJSONNull.Create);
    LOggetto.AddPair('stato', LVoce.Stato);
    LArrayVoci.AddElement(LOggetto);
  end;
  Result.AddPair('selezione', LArrayVoci);

  LArrayChiamate := TJSONArray.Create;
  for LChiamata in Chiamate do
  begin
    LOggetto := TJSONObject.Create;
    LOggetto.AddPair('iterazione', TJSONNumber.Create(LChiamata.Iterazione));
    LOggetto.AddPair('durata_ms', TJSONNumber.Create(LChiamata.DurataMs));
    AggiungiIntero(LOggetto, 'prompt_tokens', LChiamata.PromptTokens);
    AggiungiIntero(LOggetto, 'completion_tokens', LChiamata.CompletionTokens);
    AggiungiIntero(LOggetto, 'total_tokens', LChiamata.TotaleTokens);
    LArrayChiamate.AddElement(LOggetto);
  end;
  Result.AddPair('chiamate_llm', LArrayChiamate);
end;

{ TEsitoConversazione }

constructor TEsitoConversazione.Create;
begin
  inherited;
  Tracce := TObjectList<TTracciaTool>.Create(True);
  Diagnostica := TDiagnosticaTurno.Create;
end;

destructor TEsitoConversazione.Destroy;
begin
  Tracce.Free;
  Diagnostica.Free;
  DatiPianificatore.Free;
  inherited;
end;

{ TStatoTurno }

destructor TStatoTurno.Destroy;
begin
  // Prima dell'esito: il turno pianificato non possiede nulla dell'esito,
  // ma va liberato per primo perche' puo' riferirsi allo stato.
  Pianificatore.Free;
  Messaggi.Free;
  if ToolsProprietario then
    Tools.Free;
  Esito.Free;
  inherited;
end;

{ TArchivioTurniAttivi }

class constructor TArchivioTurniAttivi.Create;
begin
  FLock := TCriticalSection.Create;
  FTurni := TObjectDictionary<string, TStatoTurno>.Create([doOwnsValues]);
  FTurnoCorrente := TDictionary<string, string>.Create;
end;

class destructor TArchivioTurniAttivi.Destroy;
begin
  FTurni.Free;
  FTurnoCorrente.Free;
  FLock.Free;
end;

// Chiamata con il lock gia' preso. Scarta solo i turni PARCHEGGIATI da
// troppo tempo: uno prelevato (valore nil) e' in elaborazione e non scade.
class procedure TArchivioTurniAttivi.RimuoviScaduti;
var
  LScaduti: TArray<string>;
  LCoppia: TPair<string, TStatoTurno>;
  LID: string;
begin
  LScaduti := [];
  for LCoppia in FTurni do
    if (LCoppia.Value <> nil) and
       (MinutesBetween(Now, LCoppia.Value.UltimoAccesso) > TTL_TURNO_ATTIVO_MINUTI) then
      LScaduti := LScaduti + [LCoppia.Key];

  for LID in LScaduti do
  begin
    TLog.Write('AGENTE - turno scaduto senza risposta dal client [' + LID + ']');
    FTurni.Remove(LID);
    FTurnoCorrente.Remove(LID);
  end;
end;

class procedure TArchivioTurniAttivi.Registra(AStato: TStatoTurno);
var
  LID: string;
begin
  LID := AStato.Esito.ConversationID;
  FLock.Acquire;
  try
    RimuoviScaduti;
    if FTurnoCorrente.ContainsKey(LID) then
      TLog.Write('AGENTE - nuovo turno su [' + LID + ']: il turno ' +
        FTurnoCorrente[LID] + ' viene abbandonato');
    AStato.UltimoAccesso := Now;
    // AddOrSetValue libera l'eventuale stato vecchio (doOwnsValues). Se il
    // vecchio era prelevato (nil) lo liberera' Rimetti, accorgendosi di
    // essere stato superato.
    FTurni.AddOrSetValue(LID, AStato);
    FTurnoCorrente.AddOrSetValue(LID, AStato.TurnoID);
  finally
    FLock.Release;
  end;
end;

class function TArchivioTurniAttivi.Preleva(const AConversationID, ATurnoID: string;
  APasso: Integer; out AStato: TStatoTurno): TEsitoPrelievo;
var
  LCorrente: string;
  LStato: TStatoTurno;
begin
  AStato := nil;
  FLock.Acquire;
  try
    RimuoviScaduti;

    if not FTurnoCorrente.TryGetValue(AConversationID, LCorrente) then
      Exit(epSconosciuto);
    if LCorrente <> ATurnoID then
      Exit(epSuperato);

    LStato := FTurni[AConversationID];
    if LStato = nil then
      Exit(epInElaborazione);
    if LStato.Passo <> APasso then
      Exit(epPassoErrato);

    // Estrae l'oggetto senza liberarlo e lascia la chiave con valore nil:
    // la conversazione risulta "in elaborazione" finche' non si rimette.
    AStato := FTurni.ExtractPair(AConversationID).Value;
    FTurni.Add(AConversationID, nil);
    Result := epOk;
  finally
    FLock.Release;
  end;
end;

class function TArchivioTurniAttivi.Rimetti(AStato: TStatoTurno): Boolean;
var
  LID, LCorrente: string;
begin
  LID := AStato.Esito.ConversationID;
  FLock.Acquire;
  try
    Result := FTurnoCorrente.TryGetValue(LID, LCorrente) and (LCorrente = AStato.TurnoID);
    if Result then
    begin
      AStato.UltimoAccesso := Now;
      FTurni.AddOrSetValue(LID, AStato);
    end;
  finally
    FLock.Release;
  end;

  if not Result then
    AStato.Free;
end;

class function TArchivioTurniAttivi.Chiudi(const AConversationID, ATurnoID: string): Boolean;
var
  LCorrente: string;
begin
  FLock.Acquire;
  try
    Result := FTurnoCorrente.TryGetValue(AConversationID, LCorrente) and
      (LCorrente = ATurnoID);
    if Result then
    begin
      // Remove libera lo stato se era parcheggiato; se era prelevato il
      // valore e' nil e lo stato resta al chiamante.
      FTurni.Remove(AConversationID);
      FTurnoCorrente.Remove(AConversationID);
    end;
  finally
    FLock.Release;
  end;
end;

{ TArchivioConversazioni }

class constructor TArchivioConversazioni.Create;
begin
  FLock := TCriticalSection.Create;
  FConversazioni := TObjectDictionary<string, TJSONArray>.Create([doOwnsValues]);
  FUltimoAccesso := TDictionary<string, TDateTime>.Create;
end;

class destructor TArchivioConversazioni.Destroy;
begin
  FConversazioni.Free;
  FUltimoAccesso.Free;
  FLock.Free;
end;

class function TArchivioConversazioni.NuovoID: string;
begin
  Result := TGUID.NewGuid.ToString.Replace('{', '').Replace('}', '');
end;

class procedure TArchivioConversazioni.RimuoviScadute;
var
  LScadute: TArray<string>;
  LCoppia: TPair<string, TDateTime>;
  LID: string;
begin
  LScadute := [];
  for LCoppia in FUltimoAccesso do
    if MinutesBetween(Now, LCoppia.Value) > TTL_CONVERSAZIONE_MINUTI then
      LScadute := LScadute + [LCoppia.Key];

  for LID in LScadute do
  begin
    FConversazioni.Remove(LID);
    FUltimoAccesso.Remove(LID);
  end;
end;

class function TArchivioConversazioni.Leggi(const AID: string): TJSONArray;
var
  LMessaggi: TJSONArray;
begin
  Result := nil;
  if AID = '' then
    Exit;

  FLock.Acquire;
  try
    RimuoviScadute;
    if FConversazioni.TryGetValue(AID, LMessaggi) then
    begin
      Result := LMessaggi.Clone as TJSONArray;
      FUltimoAccesso.AddOrSetValue(AID, Now);
    end;
  finally
    FLock.Release;
  end;
end;

class procedure TArchivioConversazioni.Scrivi(const AID: string;
  AMessaggi: TJSONArray);
begin
  if AID = '' then
    Exit;

  FLock.Acquire;
  try
    FConversazioni.AddOrSetValue(AID, AMessaggi.Clone as TJSONArray);
    FUltimoAccesso.AddOrSetValue(AID, Now);
  finally
    FLock.Release;
  end;
end;

{ TServizioAgente }

// Prompt di sistema: regole generali dell'agente + elenco dei provider disponibili.
class function TServizioAgente.CreaPromptDiSistema: string;
var
  LProvider: TDescrizioneProviderMCP;
  LElencoProvider: string;
begin
  LElencoProvider := '';
  for LProvider in TRegistroProviderMCP.Tutte do
    LElencoProvider := LElencoProvider + '- ' + LProvider.Nome + ': ' +
      LProvider.Descrizione + sLineBreak;

  Result :=
    'Sei l''assistente del gestionale di un''azienda del settore alimentare. ' +
    'Oggi è il ' + FormatDateTime('dd/mm/yyyy', Now) + '.' + sLineBreak +
    'Rispondi in italiano, in modo conciso e professionale.' + sLineBreak +

    'REGOLE GENERALI' + sLineBreak +
    '- Per domande su dati aziendali (vendite, clienti, prodotti, lotti, non conformità, ricette) usa almeno un tool prima di rispondere. ' +
    'Non inventare dati, numeri, codici o nomi.' + sLineBreak +
    '- Basa le risposte sui dati restituiti dai tool.' + sLineBreak +
    '- Se il risultato indica un periodo, dichiaralo nella risposta.' + sLineBreak +
    '- Se un tool restituisce un errore, spiegalo senza aggirarlo.' + sLineBreak +
    '- Nell''ambito della STESSA richiesta, dopo aver ottenuto il dato non richiamare lo stesso tool con gli stessi argomenti o equivalenti. ' +
    'Richiamalo di nuovo solo per ottenere dati realmente diversi. Una NUOVA richiesta dell''utente (anche simile a una precedente, ' +
    'o con un filtro diverso) richiede sempre una nuova chiamata al tool.' + sLineBreak +
    '- Per CSV, PDF o export: ottieni prima i dati dal tool pertinente, poi genera il file con il tool apposito. ' +
    'Non inventare MAI un URL o un nome di file: riporta il link esattamente come te lo restituisce il tool.' + sLineBreak +

    'ESECUZIONE DELLE RICHIESTE' + sLineBreak +
    '- Esegui esattamente ciò che l''utente chiede, con i tool disponibili. Non sostituire la richiesta con un''altra e non prendere ' +
    'iniziative non richieste (per esempio proporre o decidere modifiche, sostituzioni o azioni che l''utente non ha chiesto).' + sLineBreak +
    '- Non dichiarare di aver già eseguito una ricerca, un calcolo o un''operazione se non hai chiamato il tool per farlo ' +
    'in questa conversazione: se l''utente ti chiede di cercare, calcolare o generare qualcosa, chiama il tool pertinente.' + sLineBreak +
    '- Se per procedere manca un dato indispensabile, chiedilo; altrimenti non chiedere conferme superflue.' + sLineBreak +

    'TOOL DISPONIBILI IN QUESTO TURNO' + sLineBreak +
    '- I tool che vedi in questo turno sono un sottoinsieme scelto automaticamente in base alla tua domanda, ' +
    'appartenenti a uno o più dei provider elencati in fondo a questo messaggio: non è l''intero catalogo del gestionale.' + sLineBreak +
    '- Se nessuno dei tool disponibili è adatto alla richiesta, dillo chiaramente invece di usarne uno non pertinente ' +
    'o di rispondere senza dati.' + sLineBreak +
    '- Se non vedi un tool adatto, non concludere che il gestionale non supporta quella funzionalità: potrebbe non ' +
    'essere disponibile solo in questo turno. Chiedi all''utente di riformulare la domanda in modo più specifico ' +
    '(es. nominando esplicitamente prodotto, cliente o documento coinvolto).' + sLineBreak +

    'DISAMBIGUAZIONE' + sLineBreak +
    '- Se un nome identifica più anagrafiche o nessuna e il tool restituisce candidati, non scegliere autonomamente: ' +
    'mostra i candidati e chiedi all''utente quale intende.' + sLineBreak +
    '- Se l''utente indica esplicitamente l''id di un candidato (es. "id 42"), usa il parametro ID dedicato ' +
    '(es. AClienteId, AProdottoId o prodotto_finito_id, secondo il tool), non il parametro testuale. Mantieni gli altri filtri già specificati.' + sLineBreak +

    'PROVIDER DISPONIBILI NEL GESTIONALE' + sLineBreak +
    '- Il gestionale è organizzato in famiglie di funzionalità (provider); i tool di ciascuna arrivano in questo ' +
    'messaggio solo quando pertinenti alla domanda dell''utente:' + sLineBreak +
    LElencoProvider;
end;

class function TServizioAgente.EstraiMessaggioAssistente(ARisposta: TJSONObject): TJSONObject;
var
  LChoices: TJSONArray;
begin
  Result := nil;
  LChoices := ARisposta.GetValue('choices') as TJSONArray;
  if (LChoices = nil) or (LChoices.Count = 0) then
    Exit;

  Result := (LChoices.Items[0] as TJSONObject).GetValue('message') as TJSONObject;
end;

class function TServizioAgente.CreaMessaggioRisultatoTool(const AToolCallID, ANome,
  ARisultato: string): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('role', 'tool');
  Result.AddPair('tool_call_id', AToolCallID);
  Result.AddPair('name', ANome);
  Result.AddPair('content', ARisultato);
end;

// Riconosce una chiamata a tool scritta come testo (<function=...>) da modelli che non usano tool_calls.
class function TServizioAgente.EstraiToolCallDalTesto(const AContenuto: string;
  out ANomeTool: string; out AArgomenti: TJSONObject): Boolean;
var
  LMatchFunzione, LMatchParam: TMatch;
  LRegexParam: TRegEx;
  LNomeParam, LValoreParam: string;
begin
  Result := False;
  ANomeTool := '';
  AArgomenti := nil;

  if (Pos('<tool_call>', AContenuto) = 0) and (Pos('<function=', AContenuto) = 0) then
    Exit;

  LMatchFunzione := TRegEx.Match(AContenuto, '<function\s*=\s*([^>\s]+)\s*>');
  if not LMatchFunzione.Success then
    Exit;

  ANomeTool := Trim(LMatchFunzione.Groups[1].Value);
  AArgomenti := TJSONObject.Create;

  LRegexParam := TRegEx.Create('<parameter\s*=\s*([^>\s]+)\s*>([\s\S]*?)</parameter>');
  LMatchParam := LRegexParam.Match(AContenuto);
  while LMatchParam.Success do
  begin
    LNomeParam := Trim(LMatchParam.Groups[1].Value);
    LValoreParam := Trim(LMatchParam.Groups[2].Value).DeQuotedString('"');
    if LNomeParam <> '' then
      AArgomenti.AddPair(LNomeParam, LValoreParam);
    LMatchParam := LMatchParam.NextMatch;
  end;

  Result := True;
end;

// True se il testo contiene un URL diverso da quelli generati da generate_csv/generate_pdf.
class function TServizioAgente.ContieneLinkNonValido(const AContenuto: string): Boolean;
var
  LPrefissoValido: string;
  LMatch: TMatch;
begin
  Result := False;
  LPrefissoValido := TConfig.GetInstance.BaseUrl + '/export/';

  LMatch := TRegEx.Match(AContenuto, 'https?://[^\s\)\]"''<>]+');
  while LMatch.Success do
  begin
    if not LMatch.Value.StartsWith(LPrefissoValido, True) then
      Exit(True);
    LMatch := LMatch.NextMatch;
  end;
end;

// Messaggio di sistema + ultimi MAX_TURNI_FINESTRA turni utente, senza spezzare un turno.
class function TServizioAgente.UltimiMessaggi(AMessaggi: TJSONArray): TJSONArray;
var
  LIndiciUser: TArray<Integer>;
  I, LPrimoIndice: Integer;
  LRuolo: string;
begin
  Result := TJSONArray.Create;

  if AMessaggi.Count = 0 then
    Exit;

  Result.AddElement((AMessaggi.Items[0] as TJSONObject).Clone as TJSONObject);

  LIndiciUser := [];
  for I := 1 to AMessaggi.Count - 1 do
  begin
    LRuolo := '';
    if (AMessaggi.Items[I] as TJSONObject).GetValue('role') <> nil then
      LRuolo := (AMessaggi.Items[I] as TJSONObject).GetValue('role').Value;
    if LRuolo = 'user' then
      LIndiciUser := LIndiciUser + [I];
  end;

  if Length(LIndiciUser) = 0 then
  begin
    for I := 1 to AMessaggi.Count - 1 do
      Result.AddElement((AMessaggi.Items[I] as TJSONObject).Clone as TJSONObject);
    Exit;
  end;

  if Length(LIndiciUser) > MAX_TURNI_FINESTRA then
    LPrimoIndice := LIndiciUser[Length(LIndiciUser) - MAX_TURNI_FINESTRA]
  else
    LPrimoIndice := LIndiciUser[0];

  for I := LPrimoIndice to AMessaggi.Count - 1 do
    Result.AddElement((AMessaggi.Items[I] as TJSONObject).Clone as TJSONObject);
end;

class constructor TServizioAgente.Create;
begin
  FLogSelezione := TTextFileWriter.Create(
    TPath.Combine(ExtractFilePath(ParamStr(0)), 'logs'), 'selezione_tool.log');

  FCsvSelezione := TTextFileWriter.Create(
    TPath.Combine(ExtractFilePath(ParamStr(0)), 'logs'), 'selezione_tool.csv');
  try
    if not TFile.Exists(TPath.Combine(
      TPath.Combine(ExtractFilePath(ParamStr(0)), 'logs'), 'selezione_tool.csv')) then
      FCsvSelezione.WriteRawLine(
        'timestamp;conversation_id;turno;modalita;modello;domanda;provider;tool;' +
        'similarita;stato;tool_inviati;tool_catalogo;fallback_catalogo;' +
        'durata_fase1_ms;durata_llm_ms;durata_totale_ms;chiamate_llm;' +
        'prompt_tokens_prima_chiamata;prompt_tokens_totali;completion_tokens_totali;' +
        'tool_chiamati');
  except
  end;
end;

class destructor TServizioAgente.Destroy;
begin
  FCsvSelezione.Free;
  FLogSelezione.Free;
end;

class procedure TServizioAgente.ScriviLogSelezione(const AMessaggio: string);
begin
  try
    FLogSelezione.WriteLine(AMessaggio);
  except
    on E: Exception do
      TLog.Write('AGENTE - impossibile scrivere sul log dedicato alla selezione ' +
        'semantica (' + E.Message + '). Messaggio perso: ' + AMessaggio);
  end;
end;

// Provider dei tool gia' chiamati nella finestra corrente della conversazione.
class function TServizioAgente.ProviderUsatiDiRecente(
  AMessaggi: TJSONArray): TArray<string>;
var
  LFinestra: TJSONArray;
  LRisultato: TList<string>;
  i, j: Integer;
  LMessaggio, LToolCall, LFunzione: TJSONObject;
  LRuolo, LNomeTool, LNomeProvider: string;
  LToolCalls: TJSONArray;
begin
  LFinestra := UltimiMessaggi(AMessaggi);
  try
    LRisultato := TList<string>.Create;
    try
      for i := 0 to LFinestra.Count - 1 do
      begin
        LMessaggio := LFinestra.Items[i] as TJSONObject;

        LRuolo := '';
        if LMessaggio.GetValue('role') <> nil then
          LRuolo := LMessaggio.GetValue('role').Value;
        if LRuolo <> 'assistant' then
          Continue;

        if LMessaggio.GetValue('tool_calls') = nil then
          Continue;
        LToolCalls := LMessaggio.GetValue('tool_calls') as TJSONArray;

        for j := 0 to LToolCalls.Count - 1 do
        begin
          LToolCall := LToolCalls.Items[j] as TJSONObject;
          LFunzione := LToolCall.GetValue('function') as TJSONObject;
          if LFunzione = nil then
            Continue;

          LNomeTool := LFunzione.GetValue<string>('name');
          LNomeProvider := TRegistroProviderMCP.ProviderDiTool(LNomeTool);
          if (LNomeProvider <> '') and not LRisultato.Contains(LNomeProvider) then
            LRisultato.Add(LNomeProvider);
        end;
      end;

      Result := LRisultato.ToArray;
    finally
      LRisultato.Free;
    end;
  finally
    LFinestra.Free;
  end;
end;

class function TServizioAgente.ScegliModalitaSelezioneToolTraOverrideEIni(
  const AOpzioni: TOpzioniTurno): TModalitaSelezione;
begin
  if (AOpzioni.ModalitaOverride <> '') and
     ConvertiStringaInModalitaSelezioneTool(AOpzioni.ModalitaOverride, Result) then
    Exit;

  if not ConvertiStringaInModalitaSelezioneTool(TConfig.GetInstance.SelezioneModalita, Result) then
    Result := msProviderCompleto;
end;

class function TServizioAgente.MotorePianificatore(const AOpzioni: TOpzioniTurno): Boolean;
var
  LMotore: string;
begin
  LMotore := AOpzioni.MotoreOverride;
  if LMotore = '' then
    LMotore := TConfig.GetInstance.MotoreOrchestratore;
  Result := SameText(LMotore, 'pianificatore');
end;

class function TServizioAgente.ContaTurniUtente(AMessaggi: TJSONArray): Integer;
var
  i: Integer;
  LMessaggio: TJSONObject;
  LRuolo, LContenuto: TJSONValue;
begin
  Result := 0;
  for i := 0 to AMessaggi.Count - 1 do
  begin
    LMessaggio := AMessaggi.Items[i] as TJSONObject;
    LRuolo := LMessaggio.GetValue('role');
    LContenuto := LMessaggio.GetValue('content');
    if (LRuolo <> nil) and (LRuolo.Value = 'user') then
      if not ((LContenuto <> nil) and not (LContenuto is TJSONNull) and
              LContenuto.Value.StartsWith('[verifica automatica]')) then
        Inc(Result);
  end;
end;

class procedure TServizioAgente.RegistraTokenChiamataLLM(ADiagnostica: TDiagnosticaTurno;
  AIterazione: Integer; ARisposta: TJSONObject; ADurataMs: Int64);
var
  LChiamata: TChiamataLLM;
  LUsage, LModello: TJSONValue;

  function LeggiIntero(AOggetto: TJSONObject; const ANome: string): Integer;
  var
    LValore: TJSONValue;
  begin
    Result := -1;
    LValore := AOggetto.GetValue(ANome);
    if (LValore <> nil) and not (LValore is TJSONNull) then
      Result := StrToIntDef(LValore.Value, -1);
  end;
begin
  LChiamata.Iterazione := AIterazione;
  LChiamata.DurataMs := ADurataMs;
  LChiamata.PromptTokens := -1;
  LChiamata.CompletionTokens := -1;
  LChiamata.TotaleTokens := -1;

  LUsage := ARisposta.GetValue('usage');
  if (LUsage <> nil) and (LUsage is TJSONObject) then
  begin
    LChiamata.PromptTokens := LeggiIntero(TJSONObject(LUsage), 'prompt_tokens');
    LChiamata.CompletionTokens := LeggiIntero(TJSONObject(LUsage), 'completion_tokens');
    LChiamata.TotaleTokens := LeggiIntero(TJSONObject(LUsage), 'total_tokens');
  end;
  ADiagnostica.Chiamate.Add(LChiamata);

  LModello := ARisposta.GetValue('model');
  if (LModello <> nil) and not (LModello is TJSONNull) then
    ADiagnostica.ModelloLLM := LModello.Value;
end;

// Una riga di selezione_tool.csv per ogni tool del catalogo, per il turno.
class procedure TServizioAgente.ScriviCsvSelezioneTool(ADiagnostica: TDiagnosticaTurno);
var
  LFS: TFormatSettings;
  LVoce: TVoceSelezione;
  LRighe, LPrefisso, LCodaTurno, LSimilarita, LChiamati, LNome: string;

  function Csv(const AValore: string): string;
  begin
    Result := '"' + AValore.Replace('"', '""').Replace(#13, ' ').Replace(#10, ' ') + '"';
  end;

  function Numero(AValore: Integer): string;
  begin
    if AValore >= 0 then
      Result := AValore.ToString
    else
      Result := '';
  end;
begin
  try
    LFS := TFormatSettings.Create('en-US');

    LChiamati := '';
    for LNome in ADiagnostica.ToolChiamati do
    begin
      if LChiamati <> '' then
        LChiamati := LChiamati + '|';
      LChiamati := LChiamati + LNome;
    end;

    LPrefisso := FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', Now) + ';' +
      ADiagnostica.ConversationID + ';' +
      ADiagnostica.NumeroTurno.ToString + ';' +
      ADiagnostica.Modalita + ';' +
      Csv(ADiagnostica.ModelloLLM) + ';' +
      Csv(ADiagnostica.Domanda) + ';';

    LCodaTurno := ';' +
      ADiagnostica.ToolInviati.ToString + ';' +
      ADiagnostica.ToolCatalogo.ToString + ';' +
      IntToStr(Ord(ADiagnostica.FallbackCatalogo)) + ';' +
      ADiagnostica.DurataFase1Ms.ToString + ';' +
      ADiagnostica.DurataLLMTotaleMs.ToString + ';' +
      ADiagnostica.DurataTotaleMs.ToString + ';' +
      ADiagnostica.Chiamate.Count.ToString + ';' +
      Numero(ADiagnostica.PromptTokensPrimaChiamata) + ';' +
      Numero(ADiagnostica.PromptTokensTotali) + ';' +
      Numero(ADiagnostica.CompletionTokensTotali) + ';' +
      Csv(LChiamati);

    LRighe := '';
    for LVoce in ADiagnostica.Voci do
    begin
      if LVoce.Similarita >= 0 then
        LSimilarita := FloatToStrF(LVoce.Similarita, ffFixed, 8, 4, LFS)
      else
        LSimilarita := '';

      if LRighe <> '' then
        LRighe := LRighe + sLineBreak;
      LRighe := LRighe + LPrefisso + LVoce.Provider + ';' + LVoce.NomeTool + ';' +
        LSimilarita + ';' + LVoce.Stato + LCodaTurno;
    end;

    if LRighe <> '' then
      FCsvSelezione.WriteRawLine(LRighe);
  except
    on E: Exception do
      TLog.Write('AGENTE - impossibile scrivere selezione_tool.csv (' + E.Message + ').');
  end;
end;

// Fase 1: sceglie i tool da inviare al modello secondo la modalita' (ripiego: catalogo intero).
class function TServizioAgente.SelezionaToolPerDomanda(const ATesto: string;
  AStoricoMessaggi: TJSONArray; AModalita: TModalitaSelezione;
  ADiagnostica: TDiagnosticaTurno; out AProprietario: Boolean): TJSONArray;
var
  LTutti, LPertinenti: TArray<TToolPertinente>;
  LProviderScelti, LProviderSemantici, LNomiTool: TList<string>;
  LProviderRecenti: TArray<string>;
  LNomeProviderRecente: string;
  LVoce: TToolPertinente;
  LVoceDiag: TVoceSelezione;
  LCatalogo: TJSONArray;
  LVoceCatalogo, LFunzione: TJSONObject;
  LNomeTool: string;
  LDettaglio, LRigaProviderRecenti: string;
  LSimilarita: Double;
  i, j: Integer;

  procedure RegistraCatalogoIntero(AFallback: Boolean);
  var
    LCat: TJSONArray;
    k: Integer;
    LNome: string;
    LV: TVoceSelezione;
  begin
    LCat := TCatalogoTool.Definizioni;
    for k := 0 to LCat.Count - 1 do
    begin
      LNome := ((LCat.Items[k] as TJSONObject).GetValue('function') as TJSONObject)
        .GetValue<string>('name');
      LV.NomeTool := LNome;
      LV.Provider := TRegistroProviderMCP.ProviderDiTool(LNome);
      LV.Similarita := -1;
      LV.Stato := 'selezionato';
      ADiagnostica.Voci.Add(LV);
    end;
    ADiagnostica.FallbackCatalogo := AFallback;
    ADiagnostica.ToolCatalogo := LCat.Count;
  end;
begin
  AProprietario := False;
  LProviderRecenti := nil;
  LTutti := nil;
  LPertinenti := nil;

  if AModalita = msTutti then
  begin
    RegistraCatalogoIntero(False);
    ScriviLogSelezione(Format('OK [%s] - domanda: "%s" - catalogo intero inviato (nessuna selezione).',
      [ConvertiModalitaSelezioneToolInStringa(AModalita), ATesto]));
    Exit(TCatalogoTool.Definizioni);
  end;

  try
    case AModalita of
      msProviderRango:
        LPertinenti := TIndiceEmbeddingTool.CercaConPunteggi(ATesto, LTutti, 2, 0.5, 1.0);
    else
      LPertinenti := TIndiceEmbeddingTool.CercaConPunteggi(ATesto, LTutti);
    end;
  except
    on E: Exception do
    begin
      TLog.Write('AGENTE - selezione semantica dei tool fallita (' + E.Message +
        '): ripiego sull''intero catalogo per questo turno.');
      ScriviLogSelezione('ERRORE [' + ConvertiModalitaSelezioneToolInStringa(AModalita) + '] - Cerca ha sollevato ' +
        'un''eccezione (' + E.Message + ') per la domanda: "' + ATesto +
        '" - ripiego sull''intero catalogo.');
      RegistraCatalogoIntero(True);
      Exit(TCatalogoTool.Definizioni);
    end;
  end;

  LProviderScelti := TList<string>.Create;
  LProviderSemantici := TList<string>.Create;
  LNomiTool := TList<string>.Create;
  try
    if AModalita = msTopKTool then
    begin
      for i := 0 to Length(LTutti) - 1 do
      begin
        if i >= TConfig.GetInstance.SelezioneTopKTool then
          Break;
        LNomiTool.Add(LTutti[i].NomeTool);
        if not LProviderScelti.Contains(LTutti[i].Provider) then
          LProviderScelti.Add(LTutti[i].Provider);
      end;
      LProviderSemantici.AddRange(LProviderScelti.ToArray);
    end
    else
    begin
      for LVoce in LPertinenti do
        if not LProviderScelti.Contains(LVoce.Provider) then
          LProviderScelti.Add(LVoce.Provider);
      LProviderSemantici.AddRange(LProviderScelti.ToArray);

      if AModalita = msProviderCompleto then
      begin
        LProviderRecenti := ProviderUsatiDiRecente(AStoricoMessaggi);
        for LNomeProviderRecente in LProviderRecenti do
          if not LProviderScelti.Contains(LNomeProviderRecente) then
            LProviderScelti.Add(LNomeProviderRecente);
      end;

      if LProviderScelti.Count > 0 then
        LNomiTool.AddRange(TRegistroProviderMCP.NomiToolPer(LProviderScelti.ToArray));
    end;

    if LNomiTool.Count = 0 then
    begin
      TLog.Write('AGENTE - selezione semantica: nessun tool pertinente (ne'' dal ' +
        'messaggio corrente ne'' dalla conversazione recente), ripiego sull''intero catalogo.');
      ScriviLogSelezione('VUOTO [' + ConvertiModalitaSelezioneToolInStringa(AModalita) + '] - nessun tool pertinente ' +
        'per la domanda: "' + ATesto + '" - ripiego sull''intero catalogo.');
      RegistraCatalogoIntero(True);
      Exit(TCatalogoTool.Definizioni);
    end;

    Result := TJSONArray.Create;
    AProprietario := True;
    LCatalogo := TCatalogoTool.Definizioni;

    ADiagnostica.ToolCatalogo := LCatalogo.Count;
    ADiagnostica.ProviderSelezionati := LProviderScelti.ToArray;
    ADiagnostica.ProviderRecenti := LProviderRecenti;

    for i := 0 to LCatalogo.Count - 1 do
    begin
      LVoceCatalogo := LCatalogo.Items[i] as TJSONObject;
      LFunzione := LVoceCatalogo.GetValue('function') as TJSONObject;
      LNomeTool := LFunzione.GetValue<string>('name');

      LSimilarita := -1;
      for j := 0 to Length(LTutti) - 1 do
        if SameText(LTutti[j].NomeTool, LNomeTool) then
        begin
          LSimilarita := LTutti[j].Similarita;
          Break;
        end;

      LVoceDiag.NomeTool := LNomeTool;
      LVoceDiag.Provider := TRegistroProviderMCP.ProviderDiTool(LNomeTool);
      LVoceDiag.Similarita := LSimilarita;
      if not LNomiTool.Contains(LNomeTool) then
        LVoceDiag.Stato := 'scartato'
      else if LProviderSemantici.Contains(LVoceDiag.Provider) then
        LVoceDiag.Stato := 'selezionato'
      else
        LVoceDiag.Stato := 'selezionato_finestra';
      ADiagnostica.Voci.Add(LVoceDiag);

      if LNomiTool.Contains(LNomeTool) then
        Result.AddElement(LVoceCatalogo.Clone as TJSONObject);
    end;

    TLog.Write(Format(
      'AGENTE - selezione semantica [%s]: %d tool inviati al modello (di %d nel catalogo completo).',
      [ConvertiModalitaSelezioneToolInStringa(AModalita), Result.Count, LCatalogo.Count]));

    LDettaglio := '';
    for LVoce in LTutti do
      if LNomiTool.Contains(LVoce.NomeTool) then
        LDettaglio := LDettaglio +
          Format('%s/%s=%.3f; ', [LVoce.Provider, LVoce.NomeTool, LVoce.Similarita]);

    if Length(LProviderRecenti) > 0 then
    begin
      LRigaProviderRecenti := '';
      for LNomeProviderRecente in LProviderRecenti do
      begin
        if LRigaProviderRecenti <> '' then
          LRigaProviderRecenti := LRigaProviderRecenti + ', ';
        LRigaProviderRecenti := LRigaProviderRecenti + LNomeProviderRecente;
      end;
      LDettaglio := LDettaglio + '| provider recenti dalla finestra: ' + LRigaProviderRecenti;
    end;

    ScriviLogSelezione(Format('OK [%s] - domanda: "%s" - %d/%d tool selezionati - %s',
      [ConvertiModalitaSelezioneToolInStringa(AModalita), ATesto, Result.Count, LCatalogo.Count, Trim(LDettaglio)]));
  finally
    LNomiTool.Free;
    LProviderSemantici.Free;
    LProviderScelti.Free;
  end;
end;

// Crea lo stato del turno: storico, messaggio utente, selezione dei tool, diagnostica iniziale.
class function TServizioAgente.CreaStatoTurno(const AConversationID,
  AMessaggioUtente: string; const AOpzioni: TOpzioniTurno): TStatoTurno;
var
  LModalita: TModalitaSelezione;
  LCronometroFase1: TStopwatch;
  LMessaggioUtente: TJSONObject;
begin
  Result := TStatoTurno.Create;
  try
    Result.Opzioni := AOpzioni;
    Result.Fase := ftCiclo;
    Result.Iterazione := 1;
    Result.TurnoID := TArchivioConversazioni.NuovoID;
    Result.Passo := 1;
    Result.UltimoAccesso := Now;

    Result.Esito := TEsitoConversazione.Create;
    Result.Esito.ConversationID := AConversationID;
    if Result.Esito.ConversationID = '' then
      Result.Esito.ConversationID := TArchivioConversazioni.NuovoID;

    Result.Messaggi := TArchivioConversazioni.Leggi(Result.Esito.ConversationID);
    if Result.Messaggi = nil then
    begin
      Result.Messaggi := TJSONArray.Create;
      Result.Messaggi.AddElement(TJSONObject.Create
        .AddPair('role', 'system')
        .AddPair('content', CreaPromptDiSistema));
    end;

    // Modello configurato in ini ([LLM] ChatModel), passato dal controller
    // solo per la diagnostica. Il nome effettivo arriva comunque nel campo
    // "model" di ogni risposta (vedi RegistraTokenChiamataLLM).
    Result.Esito.Diagnostica.ProfiloLLM := AOpzioni.ProfiloLLM;

    LMessaggioUtente := TJSONObject.Create;
    LMessaggioUtente.AddPair('role', 'user');
    LMessaggioUtente.AddPair('content', AMessaggioUtente);
    Result.Messaggi.AddElement(LMessaggioUtente);

    Result.CronometroTotale := TStopwatch.StartNew;
    LModalita := ScegliModalitaSelezioneToolTraOverrideEIni(AOpzioni);
    Result.Esito.Diagnostica.ConversationID := Result.Esito.ConversationID;
    Result.Esito.Diagnostica.Domanda := AMessaggioUtente;

    // MOTORE "PIANIFICATORE": il turno resta questo (stesso stato, stesso
    // protocollo a passi, stessa diagnostica) ma a guidarlo e'
    // TTurnoPianificato. Niente selezione dei tool sulla domanda: i tool
    // si cercano dopo, per ogni azione del piano.
    if MotorePianificatore(AOpzioni) then
    begin
      Result.Esito.Diagnostica.Modalita := 'pianificatore';
      Result.Tools := TJSONArray.Create;
      Result.ToolsProprietario := True;
      TTurnoPianificato.Avvia(Result, AMessaggioUtente);
      Exit;
    end;
    Result.Esito.Diagnostica.Modalita := ConvertiModalitaSelezioneToolInStringa(LModalita);
    Result.NumeroTurno := ContaTurniUtente(Result.Messaggi);
    Result.Esito.Diagnostica.NumeroTurno := Result.NumeroTurno;
    TLog.Write(Format('AGENTE - turno %d avviato [%s] turno_id=%s, llm: "%s"',
      [Result.NumeroTurno, Result.Esito.ConversationID, Result.TurnoID, AOpzioni.ProfiloLLM]));

    LCronometroFase1 := TStopwatch.StartNew;
    Result.Tools := SelezionaToolPerDomanda(AMessaggioUtente, Result.Messaggi, LModalita,
      Result.Esito.Diagnostica, Result.ToolsProprietario);
    LCronometroFase1.Stop;
    Result.Esito.Diagnostica.DurataFase1Ms := LCronometroFase1.ElapsedMilliseconds;
    Result.Esito.Diagnostica.ToolInviati := Result.Tools.Count;
    Result.Esito.Diagnostica.CaratteriDefinizioniTool := Length(Result.Tools.ToJSON);
  except
    Result.Free;
    raise;
  end;
end;

// Richiesta per il modello, nel formato interno chat/completions (vedi
// docs/protocollo_turni_client_llm.md). TClientLLM (uClientLLM.pas) la
// invia al motore quasi cosi' com'e'.
//   messages       finestra degli ultimi turni (UltimiMessaggi)
//   tools          definizioni dei tool selezionati nella fase 1
//   consenti_tool  false nel "paracadute" di fine ciclo: il modello deve
//                  rispondere a parole. Tenuto distinto dall'assenza di
//                  tools perche' Anthropic vuole i tool dichiarati se lo
//                  storico contiene tool_use (li manda con tool_choice none).
//   modello        solo batteria di test (override del nome del modello).
class function TServizioAgente.PreparaRichiestaLLM(AStato: TStatoTurno): TJSONObject;
begin
  if AStato.Fase = ftConcluso then
    raise Exception.Create('PreparaRichiestaLLM: il turno e'' gia'' concluso.');

  Result := TJSONObject.Create;
  try
    Result.AddPair('messages', UltimiMessaggi(AStato.Messaggi));
    // Clone: AStato.Tools puo' appartenere al catalogo condiviso
    // (ToolsProprietario = False) e non deve finire dentro la risposta HTTP,
    // che viene liberata dal framework dopo l'invio.
    Result.AddPair('tools', AStato.Tools.Clone as TJSONArray);
    Result.AddPair('consenti_tool', TJSONBool.Create(AStato.Fase = ftCiclo));
    if AStato.Opzioni.ModelloOverride <> '' then
      Result.AddPair('modello', AStato.Opzioni.ModelloOverride);
  except
    Result.Free;
    raise;
  end;
end;

// Se ne controlla la forma prima di eseguire qualunque tool: un modello
// piccolo puo' produrre tool_calls incomplete. Il minimo che
// ElaboraRispostaLLM da' per scontato: choices[0].message e, per ogni
// tool_call, id + function.name + function.arguments.
class function TServizioAgente.ValidaRispostaLLM(ARisposta: TJSONObject;
  out AMotivo: string): Boolean;
var
  LMessaggio, LToolCall, LFunzione: TJSONObject;
  LValore: TJSONValue;
  i: Integer;
begin
  Result := False;
  AMotivo := '';

  if not (ARisposta.GetValue('choices') is TJSONArray) or
     (TJSONArray(ARisposta.GetValue('choices')).Count = 0) or
     not (TJSONArray(ARisposta.GetValue('choices')).Items[0] is TJSONObject) then
  begin
    AMotivo := 'choices mancante o vuoto';
    Exit;
  end;

  LValore := TJSONObject(TJSONArray(ARisposta.GetValue('choices')).Items[0]).GetValue('message');
  if not (LValore is TJSONObject) then
  begin
    AMotivo := 'choices[0].message mancante';
    Exit;
  end;
  LMessaggio := TJSONObject(LValore);

  LValore := LMessaggio.GetValue('tool_calls');
  if (LValore <> nil) and not (LValore is TJSONNull) then
  begin
    if not (LValore is TJSONArray) then
    begin
      AMotivo := 'tool_calls non e'' un array';
      Exit;
    end;
    for i := 0 to TJSONArray(LValore).Count - 1 do
    begin
      if not (TJSONArray(LValore).Items[i] is TJSONObject) then
      begin
        AMotivo := Format('tool_calls[%d] non e'' un oggetto', [i]);
        Exit;
      end;
      LToolCall := TJSONObject(TJSONArray(LValore).Items[i]);
      if (LToolCall.GetValue('id') = nil) or
         not (LToolCall.GetValue('function') is TJSONObject) then
      begin
        AMotivo := Format('tool_calls[%d]: id o function mancante', [i]);
        Exit;
      end;
      LFunzione := TJSONObject(LToolCall.GetValue('function'));
      if (LFunzione.GetValue('name') = nil) or (LFunzione.GetValue('arguments') = nil) then
      begin
        AMotivo := Format('tool_calls[%d]: function.name o function.arguments mancante', [i]);
        Exit;
      end;
    end;
  end;

  Result := True;
end;

// Un passo del turno, tutto lato server:
//   1. prepara la richiesta (finestra dei messaggi + tool della fase 1);
//   2. la manda al motore di inferenza configurato in ini (TClientLLM);
//   3. controlla la forma della risposta;
//   4. la elabora: esegue i tool richiesti oppure registra la risposta finale.
// Se il motore non risponde (punto 2) o risponde male (punto 3) si solleva
// ELLMErrore PRIMA di aver eseguito qualunque tool di questo passo.
class function TServizioAgente.EseguiPassoLLM(AStato: TStatoTurno): Boolean;
var
  LRichiesta, LRisposta: TJSONObject;
  LDurataMs: Int64;
  LMotivo: string;
begin
  // Motore "pianificatore": il passo lo decide TTurnoPianificato.
  if AStato.Pianificatore <> nil then
    Exit(TTurnoPianificato.EseguiPasso(AStato));

  LRichiesta := PreparaRichiestaLLM(AStato);
  try
    LRisposta := TClientLLM.Completa(LRichiesta, LDurataMs);
  finally
    LRichiesta.Free;
  end;

  try
    if not ValidaRispostaLLM(LRisposta, LMotivo) then
      raise ELLMErrore.Create('Risposta del modello non valida: ' + LMotivo);
    // ElaboraRispostaLLM clona cio' che conserva nello storico: la risposta
    // resta nostra e si libera qui.
    Result := ElaboraRispostaLLM(AStato, LRisposta, LDurataMs);
  finally
    LRisposta.Free;
  end;
end;

class function TServizioAgente.DescriviFase(AStato: TStatoTurno): string;
begin
  if (AStato.Pianificatore <> nil) and (AStato.Fase <> ftConcluso) then
    Exit(TTurnoPianificato.DescriviFase(AStato));

  case AStato.Fase of
    ftParacadute:
      Result := 'Preparo la risposta';
    ftConcluso:
      Result := '';
  else
    if AStato.Passo <= 1 then
      Result := 'Il modello sta pensando'
    else
      Result := Format('Il modello sta leggendo i dati (passo %d)', [AStato.Passo]);
  end;
end;

// Fine del ciclo tool_use: concluso se c'e' una risposta finale, altrimenti paracadute.
class function TServizioAgente.ChiudiCicloTool(AStato: TStatoTurno): Boolean;
begin
  if AStato.Esito.RispostaFinale <> '' then
  begin
    AStato.Fase := ftConcluso;
    Exit(True);
  end;

  AStato.Esito.LimiteRaggiunto := True;
  TLog.Write('AGENTE - limite iterazioni raggiunto, forzo risposta finale senza tool');
  AStato.Fase := ftParacadute;
  Result := False;
end;

// True se il tool_result non e' un errore (chiave "errore" in cima, vedi TMCPBridge.EseguiTool).
function EsitoToolRiuscito(const ARisultato: string): Boolean;
var
  LValore: TJSONValue;
begin
  LValore := TJSONObject.ParseJSONValue(ARisultato);
  try
    Result := not ((LValore is TJSONObject) and (TJSONObject(LValore).GetValue('errore') <> nil));
  finally
    LValore.Free;
  end;
end;

// Legge function.arguments: stringa JSON (standard OpenAI) o oggetto gia' parsato.
// False se non e' un oggetto JSON valido; stringa vuota = nessun argomento.
function LeggiArgomentiToolCall(AFunzione: TJSONObject; out AArgomenti: TJSONObject): Boolean;
var
  LValore, LParsato: TJSONValue;
  LTesto: string;
begin
  AArgomenti := nil;
  LValore := AFunzione.GetValue('arguments');
  if LValore is TJSONObject then
    AArgomenti := TJSONObject(LValore).Clone as TJSONObject
  else if (LValore = nil) or (LValore is TJSONNull) then
    AArgomenti := TJSONObject.Create
  else if LValore is TJSONString then
  begin
    LTesto := Trim(LValore.Value);
    if LTesto = '' then
      AArgomenti := TJSONObject.Create
    else
    begin
      LParsato := TJSONObject.ParseJSONValue(LTesto);
      if LParsato is TJSONObject then
        AArgomenti := TJSONObject(LParsato)
      else
        LParsato.Free;
    end;
  end;
  Result := AArgomenti <> nil;
end;

// Elabora una risposta del modello: esegue i tool richiesti o valuta la risposta finale.
// True = turno concluso.
class function TServizioAgente.ElaboraRispostaLLM(AStato: TStatoTurno;
  ARisposta: TJSONObject; ADurataMs: Int64): Boolean;
var
  LToolCalls: TJSONArray;
  LMessaggio, LToolCall, LFunzione: TJSONObject;
  LArgomenti, LAssistenteSintetico: TJSONObject;
  LContenuto, LNomeTool, LToolCallID, LRisultato, LArgomentiTesto: string;
  LArgomentiValidi: Boolean;
  LTraccia: TTracciaTool;
  LCronometro: TStopwatch;
  i: Integer;
  LDaFallback: Boolean;
  LToolCallsSintetico: TJSONArray;
  LFunzioneSintetica: TJSONObject;
  LNomeToolScartato: string;
  LArgomentiScartati: TJSONObject;
begin
  Result := False;
  case AStato.Fase of
    ftConcluso:
      raise Exception.Create('ElaboraRispostaLLM: il turno e'' gia'' concluso.');

    ftParacadute:
      begin
        RegistraTokenChiamataLLM(AStato.Esito.Diagnostica, MAX_ITERAZIONI + 1,
          ARisposta, ADurataMs);
        LMessaggio := EstraiMessaggioAssistente(ARisposta);

        LArgomentiScartati := nil;
        try
          if (LMessaggio <> nil) and (LMessaggio.GetValue('content') <> nil) and
             not (LMessaggio.GetValue('content') is TJSONNull) and
             not ContieneLinkNonValido(LMessaggio.GetValue('content').Value) and
             not EstraiToolCallDalTesto(LMessaggio.GetValue('content').Value,
               LNomeToolScartato, LArgomentiScartati) then
          begin
            AStato.Esito.RispostaFinale := LMessaggio.GetValue('content').Value;
            AStato.Messaggi.AddElement(LMessaggio.Clone as TJSONObject);
          end
          else
            AStato.Esito.RispostaFinale :=
              'Ho raccolto i dati necessari ma non sono riuscito a formulare una risposta ' +
              'in questo turno. Prova a ripetere la domanda: i dati raccolti sono comunque ' +
              'visibili nel dettaglio tecnico qui sotto.';
        finally
          LArgomentiScartati.Free;
        end;

        AStato.Fase := ftConcluso;
        Exit(True);
      end;
  end;

  AStato.Esito.Iterazioni := AStato.Iterazione;
  RegistraTokenChiamataLLM(AStato.Esito.Diagnostica, AStato.Iterazione, ARisposta,
    ADurataMs);
  LMessaggio := EstraiMessaggioAssistente(ARisposta);
  if LMessaggio = nil then
    raise Exception.Create('Il motore di inferenza non ha restituito alcun messaggio.');

  LContenuto := '';
  if (LMessaggio.GetValue('content') <> nil) and
     not (LMessaggio.GetValue('content') is TJSONNull) then
    LContenuto := LMessaggio.GetValue('content').Value;

  LToolCalls := nil;
  LDaFallback := False;
  LArgomenti := nil;
  LNomeTool := '';

  // "is TJSONArray" e non "<> nil": alcuni motori mandano "tool_calls": null
  // quando il modello risponde a parole (ValidaRispostaLLM lo ammette).
  if LMessaggio.GetValue('tool_calls') is TJSONArray then
    LToolCalls := TJSONArray(LMessaggio.GetValue('tool_calls'))
  else if EstraiToolCallDalTesto(LContenuto, LNomeTool, LArgomenti) then
    LDaFallback := True;

  if ((LToolCalls = nil) or (LToolCalls.Count = 0)) and not LDaFallback then
  begin
    if ContieneLinkNonValido(LContenuto) then
    begin
      TLog.Write('AGENTE - link inventato nella risposta del modello, ' +
        'scartato: ' + LContenuto);

      if AStato.Iterazione < MAX_ITERAZIONI then
      begin
        AStato.Messaggi.AddElement(LMessaggio.Clone as TJSONObject);
        AStato.Messaggi.AddElement(TJSONObject.Create
          .AddPair('role', 'user')
          .AddPair('content',
            '[verifica automatica] Il link che hai scritto non esiste: nessun file e'' ' +
            'stato generato in questo turno. Non scrivere MAI un URL a memoria. Chiama ' +
            'ora il tool generate_csv (o generate_pdf) passando le righe gia'' ottenute, ' +
            'poi rispondi di nuovo riportando il link esattamente come te lo restituisce ' +
            'il tool.'));
        AStato.Iterazione := AStato.Iterazione + 1;
        Exit(False);
      end;

      Exit(ChiudiCicloTool(AStato));
    end;

    AStato.Esito.RispostaFinale := LContenuto;
    AStato.Messaggi.AddElement(LMessaggio.Clone as TJSONObject);
    Exit(ChiudiCicloTool(AStato));
  end;

  if LDaFallback then
  begin
    LToolCallID := 'call_fallback_' + AStato.Iterazione.ToString;

    LFunzioneSintetica := TJSONObject.Create;
    LFunzioneSintetica.AddPair('name', LNomeTool);
    LFunzioneSintetica.AddPair('arguments', LArgomenti.ToJSON);

    LToolCall := TJSONObject.Create;
    LToolCall.AddPair('id', LToolCallID);
    LToolCall.AddPair('type', 'function');
    LToolCall.AddPair('function', LFunzioneSintetica);

    LToolCallsSintetico := TJSONArray.Create;
    LToolCallsSintetico.AddElement(LToolCall);

    LAssistenteSintetico := TJSONObject.Create;
    LAssistenteSintetico.AddPair('role', 'assistant');
    LAssistenteSintetico.AddPair('content', TJSONNull.Create);
    LAssistenteSintetico.AddPair('tool_calls', LToolCallsSintetico);
    AStato.Messaggi.AddElement(LAssistenteSintetico);

    LCronometro := TStopwatch.StartNew;
    LRisultato := TMCPBridge.EseguiTool(LNomeTool, LArgomenti);
    LCronometro.Stop;

    LTraccia := TTracciaTool.Create;
    LTraccia.Nome := LNomeTool;
    LTraccia.ArgomentiJSON := LArgomenti.ToJSON;
    LTraccia.RisultatoJSON := LRisultato;
    LTraccia.DurataMs := LCronometro.ElapsedMilliseconds;
    LTraccia.Riuscita := EsitoToolRiuscito(LRisultato);
    AStato.Esito.Tracce.Add(LTraccia);

    TLog.Write(Format('AGENTE - tool "%s" (fallback testuale) in %d ms',
      [LNomeTool, LCronometro.ElapsedMilliseconds]));

    AStato.Messaggi.AddElement(
      CreaMessaggioRisultatoTool(LToolCallID, LNomeTool, LRisultato));

    LArgomenti.Free;
    LArgomenti := nil;
  end
  else
  begin
    AStato.Messaggi.AddElement(LMessaggio.Clone as TJSONObject);

    for i := 0 to LToolCalls.Count - 1 do
    begin
      LToolCall := LToolCalls.Items[i] as TJSONObject;
      LToolCallID := LToolCall.GetValue('id').Value;
      LFunzione := LToolCall.GetValue('function') as TJSONObject;
      LNomeTool := LFunzione.GetValue('name').Value;

      LArgomentiTesto := LFunzione.GetValue('arguments').ToString;
      LArgomentiValidi := LeggiArgomentiToolCall(LFunzione, LArgomenti);
      if not LArgomentiValidi then
        LArgomenti := TJSONObject.Create;

      try
        LCronometro := TStopwatch.StartNew;
        // Argomenti illeggibili: il tool non viene eseguito, l'errore torna al modello.
        if LArgomentiValidi then
          LRisultato := TMCPBridge.EseguiTool(LNomeTool, LArgomenti)
        else
          LRisultato := TMCPBridge.RisultatoErrore(
            'Argomenti non validi: atteso un oggetto JSON, ricevuto ' + LArgomentiTesto, LNomeTool);
        LCronometro.Stop;

        LTraccia := TTracciaTool.Create;
        LTraccia.Nome := LNomeTool;
        LTraccia.ArgomentiJSON := LArgomenti.ToJSON;
        LTraccia.RisultatoJSON := LRisultato;
        LTraccia.DurataMs := LCronometro.ElapsedMilliseconds;
        LTraccia.Riuscita := EsitoToolRiuscito(LRisultato);
        AStato.Esito.Tracce.Add(LTraccia);

        TLog.Write(Format('AGENTE - tool "%s" in %d ms',
          [LNomeTool, LCronometro.ElapsedMilliseconds]));

        AStato.Messaggi.AddElement(
          CreaMessaggioRisultatoTool(LToolCallID, LNomeTool, LRisultato));
      finally
        LArgomenti.Free;
        LArgomenti := nil;
      end;
    end;
  end;

  AStato.Iterazione := AStato.Iterazione + 1;
  if AStato.Iterazione > MAX_ITERAZIONI then
    Exit(ChiudiCicloTool(AStato));
end;

// Chiude la diagnostica, salva lo storico e consegna l'esito al chiamante.
class function TServizioAgente.ConsegnaEsitoTurno(AStato: TStatoTurno): TEsitoConversazione;
var
  LTraccia: TTracciaTool;
begin
  if AStato.Fase <> ftConcluso then
    raise Exception.Create('ConsegnaEsitoTurno: il turno non e'' ancora concluso.');

  for LTraccia in AStato.Esito.Tracce do
    AStato.Esito.Diagnostica.ToolChiamati :=
      AStato.Esito.Diagnostica.ToolChiamati + [LTraccia.Nome];
  AStato.Esito.Diagnostica.DurataTotaleMs := AStato.CronometroTotale.ElapsedMilliseconds;
  ScriviCsvSelezioneTool(AStato.Esito.Diagnostica);

  // Motore "pianificatore": lo storico e' quello dei turni (piano, esiti,
  // stato), non l'elenco dei messaggi chat.
  if AStato.Pianificatore <> nil then
    TTurnoPianificato.Consegna(AStato)
  else
    TArchivioConversazioni.Scrivi(AStato.Esito.ConversationID, AStato.Messaggi);

  Result := AStato.Esito;
  AStato.Esito := nil;
end;

end.
