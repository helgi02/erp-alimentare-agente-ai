unit uTurnoPianificato;

// Turno con il pianificatore. Il turno resta quello di TServizioAgente (stesso stato,
// protocollo a passi e diagnostica); con [Orchestratore] Motore = 'pianificatore' le
// decisioni di ogni passo le prende questa unit.
// Fasi (ogni passo del protocollo = al massimo una chiamata al modello o un tool):
// CONFERMA: solo se il turno precedente aspetta la conferma di una scrittura. Una chiamata
// a risposta chiusa (conferma/annulla/altro) legge la risposta; il Planner non viene
// chiamato.
// PIANO: il Planner scrive il piano; poi, senza modello, il retrieval trova i tool
// candidati per ogni azione.
// COMPLETAMENTO: solo se restano passi astratti; il Completer sceglie tool e argomenti, poi
// il codice normalizza, deduplica e valida il piano.
// ESECUZIONE: un tool per passo, con i riferimenti risolti dal codice.
// SINTESI: il modello racconta i dati letti o spiega un arresto.
// Fine turno: piano non operativo (risposta del Planner), piano non valido (testo fisso),
// scrittura da confermare (in_attesa_conferma), disambiguazione (in_attesa_scelta),
// altrimenti sintesi del modello.
// Registro: gli eventi del turno (chiamate al modello, piano, retrieval, controlli, tool,
// risposta) vanno in logs/: pianificatore.log (leggibile), pianificatore_turni.csv
// (metriche) e pianificatore_dettaglio.jsonl (tutto, prompt compresi). Un riassunto senza
// prompt torna al client nel campo 'pianificatore'.
// Storico: TArchivioStorici tiene per conversazione lo storico dei turni
// (uStoricoTurni.pas) e l'eventuale scrittura in sospeso; a inizio turno se ne prende una
// copia, a fine turno si aggiunge il turno.

interface

uses
  System.SysUtils,
  System.Classes,
  System.JSON,
  System.SyncObjs,
  System.Generics.Collections,
  uServiziAgente,
  uPianificatore,
  uRetrieverPiano,
  uValidatorePiano,
  uEsecutorePiano,
  uStoricoTurni,
  TextFileWriterU;

type
  TFasePianificatore = (fpConferma, fpPiano, fpCompletamento, fpEsecuzione, fpSintesi, fpConcluso);

  TArchivioStorici = class
  private
    class var FLock: TCriticalSection;
    class var FStorici: TObjectDictionary<string, TStoricoTurni>;
    // Scrittura proposta e non ancora confermata, per conversazione:
    // {"tool","piano","indice_passo","output","domanda","argomenti"}.
    class var FSospesi: TObjectDictionary<string, TJSONObject>;
    class var FUltimoAccesso: TDictionary<string, TDateTime>;
    class procedure RimuoviScaduti;
  public
    class constructor Create;
    class destructor Destroy;
    // Copia di cio' che serve a un turno. ASospeso e' del chiamante (nil = nessuna
    // scrittura in attesa). Restituisce il numero di turni.
    class function Istantanea(const AID: string; out AStoricoTesto: string;
      out AToolNoti: TArray<string>; out ASospeso: TJSONObject): Integer;
    // Aggiunge il turno concluso. ATurno e ASospeso passano all'archivio
    // (ASospeso = nil cancella la scrittura in sospeso).
    class procedure Registra(const AID: string; ATurno: TTurnoStorico; ASospeso: TJSONObject);
    // Voci "esiti" per lo storico, con i parametri di riduzione dello storico.
    class function EsitiPerStorico(AEsecuzione: TEsitoEsecuzione): TJSONArray;
  end;

  // I tre file del registro (vedi l'intestazione).
  TRegistroPianificatore = class
  private
    class var FLog: TTextFileWriter;
    class var FCsv: TTextFileWriter;
    class var FDettaglio: TTextFileWriter;
  public
    class constructor Create;
    class destructor Destroy;
    // Non sollevano eccezioni: un problema di scrittura del registro non
    // deve far fallire il turno (finisce nel log generale).
    class procedure ScriviLog(const ATesto: string);
    class procedure ScriviCsv(const ARiga: string);
    class procedure ScriviDettaglio(const ARigaJSON: string);
  end;

  TTurnoPianificato = class
  private
    FDomanda: string;
    FOggi: string;
    FFase: TFasePianificatore;
    FChiamateLLM: Integer;
    // Copia dello storico presa all'inizio del turno.
    FStoricoTesto: string;
    FToolNoti: TArray<string>;
    FSospeso: TJSONObject;
    // Il piano e cio' che gli gira intorno.
    FPiano: TPiano;
    FMessaggiPiano: TJSONArray;       // messaggi del Planner, prefisso del Completer
    FRetrieval: TRisultatoRetrieval;
    FCompletati: TArray<Integer>;
    FErrori: TArray<TErroreValidazione>;
    FNote: TArray<string>;
    FEsecutore: TEsecutorePiano;
    FArrestoPreventivo: TJSONObject;
    // Esito del turno.
    FStatoTurno: string;
    FToolInAttesa: string;
    FEtichetta: string;
    FNuovoSospeso: TJSONObject;
    // Registro del turno: gli eventi (per il file di dettaglio e per il
    // client) e le righe leggibili (per pianificatore.log).
    FEventi: TJSONArray;
    FRighe: TStringList;

    // Aggiunge un evento al registro (ne diventa proprietario) e la sua
    // riga leggibile.
    procedure Evento(AEvento: TJSONObject; const ARiga: string);
    procedure EventoPiano(const ATipo: string);
    procedure EventoRetrieval(ADurataMs: Int64);
    procedure EventoControlli;
    procedure EventoTool(AEsito: TEsitoPasso);
    procedure ScriviRegistro(AStato: TStatoTurno);
    function ChiamaLLM(AStato: TStatoTurno; ARichiesta: TJSONObject; const AFase: string): string;
    procedure Chiudi(AStato: TStatoTurno; const ARisposta, AStatoTurno, AEtichetta: string);
    procedure ChiudiNonValido(AStato: TStatoTurno; const ACodice, AMessaggio: string);
    procedure ControllaPiano(AStato: TStatoTurno);
    procedure AggiungiTraccia(AStato: TStatoTurno; AEsito: TEsitoPasso);
    procedure PassoConferma(AStato: TStatoTurno);
    procedure PassoPiano(AStato: TStatoTurno);
    procedure PassoCompletamento(AStato: TStatoTurno);
    procedure PassoEsecuzione(AStato: TStatoTurno);
    procedure PassoSintesi(AStato: TStatoTurno);
    function DatiPerDiagnostica: TJSONObject;
  public
    destructor Destroy; override;

    // Prepara il turno: lo aggancia ad AStato (AStato.Pianificatore) e
    // decide la prima fase. Non chiama il modello.
    class procedure Avvia(AStato: TStatoTurno; const ADomanda: string);
    // Un passo del protocollo. True = turno concluso.
    class function EseguiPasso(AStato: TStatoTurno): Boolean;
    // Frase per l'utente su cio' che fara' il PROSSIMO passo.
    class function DescriviFase(AStato: TStatoTurno): string;
    // A turno concluso: scrive lo storico e completa l'esito per il client.
    class procedure Consegna(AStato: TStatoTurno);
  end;

implementation

uses
  System.DateUtils,
  System.Diagnostics,
  uSchemaJSON,
  uContrattiTool,
  uSintesiRisposta,
  System.IOUtils,
  uClientLLM,
  uLog;

const
  TTL_STORICO_MINUTI = 60;

  SISTEMA_CONFERMA =
    'Il gestionale ha proposto all''utente un''operazione e gli ha chiesto conferma. ' +
    'Classifica la sua risposta:'#10 +
    '- conferma: accetta l''operazione cosi'' com''e'' ("si", "confermo", "procedi", "ok");'#10 +
    '- annulla: la rifiuta ("no", "annulla", "lascia stare");'#10 +
    '- altro: chiede di cambiare qualcosa, fa una domanda o parla d''altro.'#10;

  SCHEMA_CONFERMA =
    '{"type":"object","properties":{"scelta":{"type":"string",' +
    '"enum":["conferma","annulla","altro"]}},"required":["scelta"]}';

class constructor TArchivioStorici.Create;
begin
  FLock := TCriticalSection.Create;
  FStorici := TObjectDictionary<string, TStoricoTurni>.Create([doOwnsValues]);
  FSospesi := TObjectDictionary<string, TJSONObject>.Create([doOwnsValues]);
  FUltimoAccesso := TDictionary<string, TDateTime>.Create;
end;

class destructor TArchivioStorici.Destroy;
begin
  FUltimoAccesso.Free;
  FSospesi.Free;
  FStorici.Free;
  FLock.Free;
end;

// Chiamata con il lock gia' preso.
class procedure TArchivioStorici.RimuoviScaduti;
var
  LScaduti: TArray<string>;
  LCoppia: TPair<string, TDateTime>;
  LID: string;
begin
  LScaduti := nil;
  for LCoppia in FUltimoAccesso do
    if MinutesBetween(Now, LCoppia.Value) > TTL_STORICO_MINUTI then
      LScaduti := LScaduti + [LCoppia.Key];
  for LID in LScaduti do
  begin
    FStorici.Remove(LID);
    FSospesi.Remove(LID);
    FUltimoAccesso.Remove(LID);
  end;
end;

class function TArchivioStorici.Istantanea(const AID: string; out AStoricoTesto: string;
  out AToolNoti: TArray<string>; out ASospeso: TJSONObject): Integer;
var
  LStorico: TStoricoTurni;
  LSospeso: TJSONObject;
begin
  Result := 0;
  AToolNoti := nil;
  ASospeso := nil;
  AStoricoTesto := '(nessun turno precedente)';
  FLock.Acquire;
  try
    RimuoviScaduti;
    if not FStorici.TryGetValue(AID, LStorico) then
      Exit;
    FUltimoAccesso.AddOrSetValue(AID, Now);
    Result := LStorico.Turni.Count;
    AStoricoTesto := LStorico.PerLLM;
    AToolNoti := LStorico.ToolNoti;
    // La scrittura in sospeso vale solo se l'ULTIMO turno la sta aspettando.
    if (LStorico.Ultimo <> nil) and (LStorico.Ultimo.Stato = STATO_IN_ATTESA_CONFERMA) and
       FSospesi.TryGetValue(AID, LSospeso) then
      ASospeso := LSospeso.Clone as TJSONObject;
  finally
    FLock.Release;
  end;
end;

class procedure TArchivioStorici.Registra(const AID: string; ATurno: TTurnoStorico;
  ASospeso: TJSONObject);
var
  LStorico: TStoricoTurni;
begin
  FLock.Acquire;
  try
    if not FStorici.TryGetValue(AID, LStorico) then
    begin
      LStorico := TStoricoTurni.Create;
      FStorici.Add(AID, LStorico);
    end;
    LStorico.Aggiungi(ATurno);
    if ASospeso <> nil then
      FSospesi.AddOrSetValue(AID, ASospeso)
    else
      FSospesi.Remove(AID);
    FUltimoAccesso.AddOrSetValue(AID, Now);
  finally
    FLock.Release;
  end;
end;

class function TArchivioStorici.EsitiPerStorico(AEsecuzione: TEsitoEsecuzione): TJSONArray;
var
  LStorico: TStoricoTurni;
begin
  // Uno storico vuoto, solo per usare i suoi parametri di riduzione.
  LStorico := TStoricoTurni.Create;
  try
    Result := LStorico.EsitiDaEsecuzione(AEsecuzione);
  finally
    LStorico.Free;
  end;
end;

const
  INTESTAZIONE_CSV =
    'timestamp;conversation_id;turno;domanda;esito_piano;passi;stato_turno;esecuzione;' +
    'tool_eseguiti;errori_validazione;chiamate_llm;prompt_tokens;completion_tokens;' +
    'durata_llm_ms;durata_retrieval_ms;durata_tool_ms;durata_totale_ms;modello;' +
    // Vuote nell'uso normale; riempite dalla batteria di test.
    'test_run;test_caso;test_ripetizione';

class constructor TRegistroPianificatore.Create;
var
  LCartella: string;
begin
  LCartella := TPath.Combine(ExtractFilePath(ParamStr(0)), 'logs');
  FLog := TTextFileWriter.Create(LCartella, 'pianificatore.log');
  FDettaglio := TTextFileWriter.Create(LCartella, 'pianificatore_dettaglio.jsonl');
  FCsv := TTextFileWriter.Create(LCartella, 'pianificatore_turni.csv');
  try
    if not TFile.Exists(TPath.Combine(LCartella, 'pianificatore_turni.csv')) then
      FCsv.WriteRawLine(INTESTAZIONE_CSV);
  except
  end;
end;

class destructor TRegistroPianificatore.Destroy;
begin
  FCsv.Free;
  FDettaglio.Free;
  FLog.Free;
end;

class procedure TRegistroPianificatore.ScriviLog(const ATesto: string);
begin
  try
    FLog.WriteRawLine(ATesto);
  except
    on E: Exception do
      TLog.Write('AGENTE - registro del pianificatore non scrivibile (log): ' + E.Message);
  end;
end;

class procedure TRegistroPianificatore.ScriviCsv(const ARiga: string);
begin
  try
    FCsv.WriteRawLine(ARiga);
  except
    on E: Exception do
      TLog.Write('AGENTE - registro del pianificatore non scrivibile (csv): ' + E.Message);
  end;
end;

class procedure TRegistroPianificatore.ScriviDettaglio(const ARigaJSON: string);
begin
  try
    FDettaglio.WriteRawLine(ARigaJSON);
  except
    on E: Exception do
      TLog.Write('AGENTE - registro del pianificatore non scrivibile (dettaglio): ' + E.Message);
  end;
end;

destructor TTurnoPianificato.Destroy;
begin
  FRighe.Free;
  FEventi.Free;
  FNuovoSospeso.Free;
  FArrestoPreventivo.Free;
  FEsecutore.Free;      // prima del piano: l'esecutore lo usa
  FRetrieval.Free;
  FMessaggiPiano.Free;
  FPiano.Free;
  FSospeso.Free;
  inherited;
end;

class procedure TTurnoPianificato.Avvia(AStato: TStatoTurno; const ADomanda: string);
var
  LTurno: TTurnoPianificato;
  LQuanti: Integer;
begin
  LTurno := TTurnoPianificato.Create;
  AStato.Pianificatore := LTurno;      // da qui lo libera TStatoTurno
  LTurno.FDomanda := ADomanda;
  LTurno.FOggi := FormatDateTime('yyyy-mm-dd', Date);
  LTurno.FStatoTurno := STATO_CONCLUSO;
  LTurno.FEtichetta := ESECUZIONE_NON_ESEGUITA;
  LTurno.FEventi := TJSONArray.Create;
  LTurno.FRighe := TStringList.Create;

  LQuanti := TArchivioStorici.Istantanea(AStato.Esito.ConversationID, LTurno.FStoricoTesto,
    LTurno.FToolNoti, LTurno.FSospeso);
  AStato.NumeroTurno := LQuanti + 1;
  AStato.Esito.Diagnostica.NumeroTurno := AStato.NumeroTurno;

  // Scrittura in attesa di conferma: il turno parte dalla lettura della
  // risposta dell'utente, non dal Planner.
  if LTurno.FSospeso <> nil then
    LTurno.FFase := fpConferma
  else
    LTurno.FFase := fpPiano;

  TLog.Write(Format('AGENTE - turno %d avviato [%s] turno_id=%s, motore: pianificatore',
    [AStato.NumeroTurno, AStato.Esito.ConversationID, AStato.TurnoID]));
end;

class function TTurnoPianificato.DescriviFase(AStato: TStatoTurno): string;
begin
  case TTurnoPianificato(AStato.Pianificatore).FFase of
    fpConferma:      Result := 'Leggo la tua risposta';
    fpPiano:         Result := 'Sto preparando il piano';
    fpCompletamento: Result := 'Scelgo gli strumenti da usare';
    fpEsecuzione:    Result := 'Sto eseguendo le operazioni';
    fpSintesi:       Result := 'Preparo la risposta';
  else
    Result := '';
  end;
end;

class function TTurnoPianificato.EseguiPasso(AStato: TStatoTurno): Boolean;
var
  LTurno: TTurnoPianificato;
begin
  LTurno := TTurnoPianificato(AStato.Pianificatore);
  case LTurno.FFase of
    fpConferma:      LTurno.PassoConferma(AStato);
    fpPiano:         LTurno.PassoPiano(AStato);
    fpCompletamento: LTurno.PassoCompletamento(AStato);
    fpEsecuzione:    LTurno.PassoEsecuzione(AStato);
    fpSintesi:       LTurno.PassoSintesi(AStato);
  end;
  if LTurno.FFase = fpConcluso then
    AStato.Fase := ftConcluso;
  Result := AStato.Fase = ftConcluso;
end;

procedure TTurnoPianificato.Evento(AEvento: TJSONObject; const ARiga: string);
begin
  FEventi.AddElement(AEvento);
  if ARiga <> '' then
    FRighe.Add(ARiga);
end;

// Il piano com'e' in questo momento (dopo il Planner, dopo il Completer).
procedure TTurnoPianificato.EventoPiano(const ATipo: string);
var
  LPasso: TPasso;
  LRiga, LTool: string;
begin
  LRiga := '  ' + UpperCase(ATipo) + ': ' + FPiano.Esito;
  if FPiano.Risposta <> '' then
    LRiga := LRiga + ' - "' + FPiano.Risposta + '"';
  for LPasso in FPiano.Passi do
  begin
    if LPasso.Concreto then
      LTool := ' -> ' + LPasso.Tool + ' ' + JSONComePython(LPasso.Argomenti)
    else
      LTool := ' -> (tool da scegliere)';
    LRiga := LRiga + sLineBreak + Format('    %d. %s%s', [LPasso.Id, LPasso.Azione, LTool]);
  end;
  Evento(TJSONObject.Create.AddPair('tipo', ATipo).AddPair('piano', FPiano.ToJSON), LRiga);
end;

// Esito di normalizzazione, deduplica e validazione.
procedure TTurnoPianificato.EventoControlli;
var
  LNote, LErrori: TJSONArray;
  LErrore: TErroreValidazione;
  LNota, LRiga: string;
begin
  LNote := TJSONArray.Create;
  LErrori := TJSONArray.Create;
  if Length(FErrori) = 0 then
    LRiga := '  CONTROLLI: piano valido'
  else
    LRiga := Format('  CONTROLLI: piano NON valido (%d errori), niente viene eseguito', [Length(FErrori)]);
  for LNota in FNote do
  begin
    LNote.Add(LNota);
    LRiga := LRiga + sLineBreak + '    corretto: ' + LNota;
  end;
  for LErrore in FErrori do
  begin
    LErrori.AddElement(TJSONObject.Create
      .AddPair('codice', LErrore.Codice)
      .AddPair('passo', TJSONNumber.Create(LErrore.Passo))
      .AddPair('messaggio', LErrore.Messaggio));
    LRiga := LRiga + sLineBreak + Format('    errore %s (passo %d): %s',
      [LErrore.Codice, LErrore.Passo, LErrore.Messaggio]);
  end;
  Evento(TJSONObject.Create
    .AddPair('tipo', 'controlli')
    .AddPair('normalizzazioni', LNote)
    .AddPair('errori', LErrori), LRiga);
end;

// Un passo dell'esecuzione: argomenti risolti, esito, durata, risultato.
procedure TTurnoPianificato.EventoTool(AEsito: TEsitoPasso);
var
  LEvento: TJSONObject;
  LRiga: string;
begin
  LEvento := TJSONObject.Create;
  LEvento.AddPair('tipo', 'tool');
  LEvento.AddPair('id', TJSONNumber.Create(AEsito.Id));
  LEvento.AddPair('tool', AEsito.Tool);
  if AEsito.ArgomentiRisolti <> nil then
    LEvento.AddPair('argomenti', AEsito.ArgomentiRisolti.Clone as TJSONValue)
  else
    LEvento.AddPair('argomenti', TJSONNull.Create);
  LEvento.AddPair('esito', AEsito.Esito);
  LEvento.AddPair('dettaglio', AEsito.Dettaglio);
  LEvento.AddPair('durata_ms', TJSONNumber.Create(AEsito.DurataMs));
  // Il risultato intero puo' essere molto lungo: nel registro va ridotto
  // (array troncati a 50 elementi, come quello passato al modello).
  if AEsito.Output <> nil then
    LEvento.AddPair('output', RiduciOutput(AEsito.Output, 50, True))
  else
    LEvento.AddPair('output', TJSONNull.Create);

  LRiga := Format('  PASSO %d: %s %s -> %s (%d ms)',
    [AEsito.Id, AEsito.Tool, JSONComePython(AEsito.ArgomentiRisolti), AEsito.Esito, AEsito.DurataMs]);
  if AEsito.Dettaglio <> '' then
    LRiga := LRiga + ' - ' + AEsito.Dettaglio;
  Evento(LEvento, LRiga);
end;

// Candidati e primi punteggi di ogni passo.
procedure TTurnoPianificato.EventoRetrieval(ADurataMs: Int64);
const
  PUNTEGGI_NEL_REGISTRO = 5;
var
  LPassi, LCandidati, LPunteggi: TJSONArray;
  LVoce: TJSONObject;
  LDecisione: TDecisionePasso;
  LRiga, LNome, LTestoPunteggi, LNota: string;
  i: Integer;
begin
  LRiga := Format('  RETRIEVAL: %d ms', [ADurataMs]);
  LPassi := TJSONArray.Create;
  for LDecisione in FRetrieval.Decisioni do
  begin
    LVoce := TJSONObject.Create;
    LPassi.AddElement(LVoce);
    LVoce.AddPair('id', TJSONNumber.Create(LDecisione.Id));
    LVoce.AddPair('azione', LDecisione.Azione);
    LCandidati := TJSONArray.Create;
    for LNome in LDecisione.Candidati do
      LCandidati.Add(LNome);
    LVoce.AddPair('candidati', LCandidati);

    LPunteggi := TJSONArray.Create;
    LTestoPunteggi := '';
    for i := 0 to High(LDecisione.Punteggi) do
    begin
      if i >= PUNTEGGI_NEL_REGISTRO then
        Break;
      LPunteggi.AddElement(TJSONObject.Create
        .AddPair('tool', LDecisione.Punteggi[i].NomeTool)
        .AddPair('punteggio', TJSONNumber.Create(LDecisione.Punteggi[i].Similarita)));
      if LTestoPunteggi <> '' then
        LTestoPunteggi := LTestoPunteggi + ', ';
      LTestoPunteggi := LTestoPunteggi + Format('%s %.3f',
        [LDecisione.Punteggi[i].NomeTool, LDecisione.Punteggi[i].Similarita]);
    end;
    LVoce.AddPair('punteggi', LPunteggi);

    LNota := '';
    if LDecisione.ToolDichiarato <> '' then
    begin
      LVoce.AddPair('tool_dichiarato', LDecisione.ToolDichiarato);
      LVoce.AddPair('rango_dichiarato', TJSONNumber.Create(LDecisione.RangoDichiarato));
      LNota := Format(' | tool scritto dal Planner: %s (rango %d)',
        [LDecisione.ToolDichiarato, LDecisione.RangoDichiarato]);
    end;
    LVoce.AddPair('declassato', TJSONBool.Create(LDecisione.Declassato));
    LVoce.AddPair('non_coperto', TJSONBool.Create(LDecisione.NonCoperto));
    if LDecisione.Declassato then
      LNota := LNota + ' -> DECLASSATO';
    if LDecisione.NonCoperto then
      LNota := LNota + ' -> NON COPERTO';

    LRiga := LRiga + sLineBreak + Format('    passo %d: candidati [%s] | punteggi: %s%s',
      [LDecisione.Id, string.Join(', ', LDecisione.Candidati), LTestoPunteggi, LNota]);
  end;
  Evento(TJSONObject.Create
    .AddPair('tipo', 'retrieval')
    .AddPair('durata_ms', TJSONNumber.Create(ADurataMs))
    .AddPair('passi', LPassi), LRiga);
end;

// Chiama il modello con ARichiesta (liberata qui) e ne restituisce il testo. Registra
// token, durata e chiamata completa nel registro. Un ELLMErrore sale al controller.
function TTurnoPianificato.ChiamaLLM(AStato: TStatoTurno; ARichiesta: TJSONObject;
  const AFase: string): string;
var
  LRisposta, LEvento: TJSONObject;
  LMessaggi: TJSONValue;
  LDurataMs: Int64;
  LChiamata: TChiamataLLM;
begin
  LMessaggi := nil;
  try
    try
      if AStato.Opzioni.ModelloOverride <> '' then
        ARichiesta.AddPair('modello', AStato.Opzioni.ModelloOverride);
      if ARichiesta.GetValue('messages') <> nil then
        LMessaggi := ARichiesta.GetValue('messages').Clone as TJSONValue;
      LRisposta := TClientLLM.Completa(ARichiesta, LDurataMs);
    finally
      ARichiesta.Free;
    end;
    try
      Inc(FChiamateLLM);
      TServizioAgente.RegistraTokenChiamataLLM(AStato.Esito.Diagnostica, FChiamateLLM,
        LRisposta, LDurataMs);
      Result := TPianificatore.TestoRisposta(LRisposta);
    finally
      LRisposta.Free;
    end;

    LChiamata := AStato.Esito.Diagnostica.Chiamate.Last;
    LEvento := TJSONObject.Create;
    LEvento.AddPair('tipo', 'llm');
    LEvento.AddPair('fase', AFase);
    LEvento.AddPair('durata_ms', TJSONNumber.Create(LDurataMs));
    LEvento.AddPair('prompt_tokens', TJSONNumber.Create(LChiamata.PromptTokens));
    LEvento.AddPair('completion_tokens', TJSONNumber.Create(LChiamata.CompletionTokens));
    if LMessaggi <> nil then
    begin
      LEvento.AddPair('richiesta', LMessaggi);
      LMessaggi := nil;                  // ora appartiene all'evento
    end;
    LEvento.AddPair('risposta', Result);
    Evento(LEvento, Format('  MODELLO (%s): %d token di prompt, %d di risposta, %d ms',
      [AFase, LChiamata.PromptTokens, LChiamata.CompletionTokens, LDurataMs]));
  finally
    LMessaggi.Free;
  end;
end;

procedure TTurnoPianificato.Chiudi(AStato: TStatoTurno; const ARisposta, AStatoTurno,
  AEtichetta: string);
begin
  AStato.Esito.RispostaFinale := ARisposta;
  FStatoTurno := AStatoTurno;
  FEtichetta := AEtichetta;
  FFase := fpConcluso;
  Evento(TJSONObject.Create
    .AddPair('tipo', 'fine')
    .AddPair('stato_turno', AStatoTurno)
    .AddPair('esecuzione', AEtichetta)
    .AddPair('risposta', ARisposta),
    '  RISPOSTA: ' + ARisposta);
end;

procedure TTurnoPianificato.ChiudiNonValido(AStato: TStatoTurno; const ACodice, AMessaggio: string);
var
  LErrore: TErroreValidazione;
begin
  if ACodice <> '' then
  begin
    LErrore.Codice := ACodice;
    LErrore.Passo := 0;
    LErrore.Messaggio := AMessaggio;
    FErrori := FErrori + [LErrore];
  end;
  TLog.Write('AGENTE - piano non valido: ' + ACodice + ' ' + AMessaggio);
  Chiudi(AStato, TSintesiRisposta.TestoPianoNonValido, STATO_CONCLUSO, ESECUZIONE_NON_ESEGUITA);
end;

// Traccia per il client e la batteria di test: un tool chiamato davvero, con il risultato
// nella forma che il frontend conosce.
procedure TTurnoPianificato.AggiungiTraccia(AStato: TStatoTurno; AEsito: TEsitoPasso);
var
  LTraccia: TTracciaTool;
  LRisultato: TJSONObject;
  LErrore: TJSONValue;
begin
  if AEsito.Output = nil then
    Exit;                              // fermato prima di chiamare il tool

  LTraccia := TTracciaTool.Create;
  AStato.Esito.Tracce.Add(LTraccia);
  LTraccia.Nome := AEsito.Tool;
  if AEsito.ArgomentiRisolti <> nil then
    LTraccia.ArgomentiJSON := AEsito.ArgomentiRisolti.ToJSON
  else
    LTraccia.ArgomentiJSON := '{}';
  LTraccia.DurataMs := AEsito.DurataMs;
  LTraccia.Riuscita := AEsito.Esito <> 'ERRORE_TOOL';

  if AEsito.Esito = 'ERRORE_TOOL' then
  begin
    LErrore := AEsito.Output.GetValue('errore');
    LRisultato := TJSONObject.Create;
    try
      if LErrore is TJSONObject then
        LRisultato.AddPair('errore', TestoCampo(TJSONObject(LErrore), 'messaggio'))
      else
        LRisultato.AddPair('errore', '');
      LRisultato.AddPair('tool', AEsito.Tool);
      LTraccia.RisultatoJSON := LRisultato.ToJSON;
    finally
      LRisultato.Free;
    end;
  end
  else if AEsito.Output.GetValue('richiede_disambiguazione') <> nil then
  begin
    // Forma originale del tool: e' quella che la chat usa per i pulsanti di scelta.
    LRisultato := TJSONObject.Create;
    try
      LRisultato.AddPair('esito', 'richiede_disambiguazione');
      LRisultato.AddPair('problemi',
        AEsito.Output.GetValue('richiede_disambiguazione').Clone as TJSONValue);
      LTraccia.RisultatoJSON := LRisultato.ToJSON;
    finally
      LRisultato.Free;
    end;
  end
  else if (AEsito.Output.Count = 1) and (AEsito.Output.GetValue('messaggio') <> nil) then
    // Risposta testuale del tool (es. il link di generate_csv): il testo.
    LTraccia.RisultatoJSON := AEsito.Output.GetValue('messaggio').Value
  else
    LTraccia.RisultatoJSON := AEsito.Output.ToJSON;
end;

procedure TTurnoPianificato.PassoConferma(AStato: TStatoTurno);
var
  LRichiesta: TJSONObject;
  LMessaggi: TJSONArray;
  LRisposta, LScelta: TJSONValue;
  LTesto, LTool, LSceltaTesto: string;
  LOutput: TJSONValue;
begin
  LTool := TestoCampo(FSospeso, 'tool');

  // Risposta data con i pulsanti della chat: la scelta e' certa, nessuna chiamata al
  // modello. Con testo libero resta la chiamata a risposta chiusa.
  if AStato.Opzioni.SceltaConferma <> '' then
  begin
    LSceltaTesto := AStato.Opzioni.SceltaConferma;
    TLog.Write('AGENTE - conferma data con il pulsante della chat: nessuna chiamata al modello.');
  end
  else
  begin
    LMessaggi := TJSONArray.Create;
    LMessaggi.AddElement(TJSONObject.Create
      .AddPair('role', 'system').AddPair('content', SISTEMA_CONFERMA));
    LMessaggi.AddElement(TJSONObject.Create
      .AddPair('role', 'user')
      .AddPair('content',
        'OPERAZIONE PROPOSTA: ' + LTool + ' ' + JSONComePython(FSospeso.GetValue('argomenti')) + #10 +
        'RISPOSTA DELL''UTENTE: ' + FDomanda));
    LRichiesta := TJSONObject.Create;
    LRichiesta.AddPair('messages', LMessaggi);
    LRichiesta.AddPair('schema_risposta', TJSONObject.Create
      .AddPair('nome', 'conferma')
      .AddPair('schema', TJSONObject.ParseJSONValue(SCHEMA_CONFERMA)));

    LTesto := ChiamaLLM(AStato, LRichiesta, 'conferma');
    // Risposta illeggibile = "altro": il turno procede come un turno normale.
    LSceltaTesto := 'altro';
    LRisposta := TJSONObject.ParseJSONValue(LTesto);
    try
      if LRisposta is TJSONObject then
      begin
        LScelta := TJSONObject(LRisposta).GetValue('scelta');
        if (LScelta <> nil) and ((LScelta.Value = 'conferma') or (LScelta.Value = 'annulla')) then
          LSceltaTesto := LScelta.Value;
      end;
    finally
      LRisposta.Free;
    end;
  end;
  TLog.Write('AGENTE - risposta alla richiesta di conferma: ' + LSceltaTesto);
  Evento(TJSONObject.Create
    .AddPair('tipo', 'conferma')
    .AddPair('tool', LTool)
    .AddPair('scelta', LSceltaTesto),
    Format('  CONFERMA di %s: l''utente ha risposto "%s"', [LTool, LSceltaTesto]));

  if LSceltaTesto = 'altro' then
  begin
    FFase := fpPiano;
    Exit;
  end;

  // Il piano del turno e' quello che aveva portato alla proposta.
  FPiano := TPianificatore.LeggiPiano(FSospeso.GetValue('piano').ToJSON);

  if LSceltaTesto = 'annulla' then
  begin
    Chiudi(AStato, TSintesiRisposta.TestoAnnullata, STATO_CONCLUSO, 'annullata');
    Exit;
  end;

  // Conferma: si riprende dal passo fermo, con i risultati dei passi gia' eseguiti. Gli
  // argomenti sono ricalcolati dagli stessi risultati, quindi uguali a quelli mostrati.
  FEsecutore := TEsecutorePiano.Create(FPiano);
  LOutput := FSospeso.GetValue('output');
  if LOutput is TJSONObject then
    FEsecutore.RiprendiDa(StrToIntDef(TestoCampo(FSospeso, 'indice_passo'), 0), TJSONObject(LOutput))
  else
    FEsecutore.RiprendiDa(StrToIntDef(TestoCampo(FSospeso, 'indice_passo'), 0), nil);
  FEsecutore.ToolConfermato := LTool;
  FFase := fpEsecuzione;
end;

procedure TTurnoPianificato.PassoPiano(AStato: TStatoTurno);
var
  LRichiesta, LVoce: TJSONObject;
  LTesto: string;
  LCronometro: TStopwatch;
  LPasso: TPasso;
  LNonCoperti: TArray<Integer>;
  LId: Integer;
  LPassi, LAzioni: TJSONArray;
  LAstratti: Boolean;
  LCandidati: TList<string>;
  LDecisione: TDecisionePasso;
  LNome: string;
begin
  LRichiesta := TPianificatore.RichiestaPiano(FStoricoTesto, FDomanda, FOggi, FToolNoti);
  // I messaggi del Planner servono poi come prefisso al Completer.
  FMessaggiPiano := LRichiesta.GetValue('messages').Clone as TJSONArray;
  LTesto := ChiamaLLM(AStato, LRichiesta, 'piano');

  try
    FPiano := TPianificatore.LeggiPiano(LTesto);
  except
    on E: EContrattoPiano do
    begin
      ChiudiNonValido(AStato, E.Codice, E.Messaggio);
      Exit;
    end;
  end;
  LVoce := TJSONObject.Create.AddPair('role', 'assistant').AddPair('content', LTesto);
  FMessaggiPiano.AddElement(LVoce);
  EventoPiano('piano');

  if FPiano.Esito <> ESITO_OPERATIVA then
  begin
    Chiudi(AStato, FPiano.Risposta, STATO_CONCLUSO, ESECUZIONE_NON_ESEGUITA);
    Exit;
  end;

  // Retrieval: nessun modello di chat, una richiesta di embedding.
  LCronometro := TStopwatch.StartNew;
  FRetrieval := TRetrieverPiano.SelezionaToolPerAzioni(FPiano, TConfigRetrieval.Predefinita);
  LCronometro.Stop;
  AStato.Esito.Diagnostica.DurataFase1Ms := LCronometro.ElapsedMilliseconds;

  LCandidati := TList<string>.Create;
  try
    for LDecisione in FRetrieval.Decisioni do
      for LNome in LDecisione.Candidati do
        if not LCandidati.Contains(LNome) then
          LCandidati.Add(LNome);
    AStato.Esito.Diagnostica.ToolInviati := LCandidati.Count;
  finally
    LCandidati.Free;
  end;
  EventoRetrieval(LCronometro.ElapsedMilliseconds);

  LNonCoperti := FRetrieval.NonCoperti;
  if Length(LNonCoperti) > 0 then
  begin
    // Per almeno un'azione manca un tool: non si esegue niente e il modello spiega cosa non
    // si puo' fare.
    LPassi := TJSONArray.Create;
    LAzioni := TJSONArray.Create;
    for LId in LNonCoperti do
    begin
      LPassi.Add(LId);
      for LPasso in FPiano.Passi do
        if LPasso.Id = LId then
          LAzioni.Add(LPasso.Azione);
    end;
    FArrestoPreventivo := TJSONObject.Create
      .AddPair('codice', 'PASSO_NON_COPERTO')
      .AddPair('passi', LPassi)
      .AddPair('azioni', LAzioni);
    FEtichetta := 'fermata:PASSO_NON_COPERTO';
    FFase := fpSintesi;
    Exit;
  end;

  LAstratti := False;
  for LPasso in FPiano.Passi do
    if not LPasso.Concreto then
      LAstratti := True;
  if LAstratti then
    FFase := fpCompletamento
  else
    ControllaPiano(AStato);
end;

procedure TTurnoPianificato.PassoCompletamento(AStato: TStatoTurno);
var
  LCandidati: TArray<TCandidatiPasso>;
  LVoce: TCandidatiPasso;
  LTesto, LProblema: string;
  LRichiesta, LCopia, LCorrezione, LEvento: TJSONObject;
begin
  LCandidati := FRetrieval.CandidatiPerCompletamento(FPiano);
  FCompletati := nil;
  for LVoce in LCandidati do
    FCompletati := FCompletati + [LVoce.Id];

  // ChiamaLLM libera la richiesta: se ne tiene una copia, utile se serve chiedere una
  // correzione.
  LRichiesta := TPianificatore.RichiestaCompletamento(FMessaggiPiano, LCandidati);
  LCopia := LRichiesta.Clone as TJSONObject;
  try
    LTesto := ChiamaLLM(AStato, LRichiesta, 'completamento');
    LProblema := '';
    try
      TPianificatore.ApplicaCompletamento(FPiano, LTesto, LCandidati);
    except
      on E: EContrattoPiano do
      begin
        if E.Codice <> 'PASSO_DOPPIO' then
        begin
          ChiudiNonValido(AStato, E.Codice, E.Messaggio);
          Exit;
        end;
        LProblema := E.Messaggio;
      end;
    end;

    // Due voci per lo stesso passo: il codice non sceglie. Si chiede UNA sola correzione al
    // modello; se anche la seconda risposta non e' valida il turno si chiude con "piano non
    // valido" senza eseguire tool.
    if LProblema <> '' then
    begin
      LEvento := TJSONObject.Create;
      LEvento.AddPair('tipo', 'correzione_completamento');
      LEvento.AddPair('motivo', 'PASSO_DOPPIO');
      LEvento.AddPair('dettaglio', LProblema);
      Evento(LEvento, '  CORREZIONE: completamento ambiguo (' + LProblema +
        '), chiesta una nuova risposta al modello');

      LCorrezione := TPianificatore.RichiestaCorrezioneCompletamento(LCopia, LTesto, LProblema);
      LTesto := ChiamaLLM(AStato, LCorrezione, 'completamento_correzione');
      try
        TPianificatore.ApplicaCompletamento(FPiano, LTesto, LCandidati);
      except
        on E: EContrattoPiano do
        begin
          ChiudiNonValido(AStato, E.Codice, E.Messaggio);
          Exit;
        end;
      end;
    end;
  finally
    LCopia.Free;
  end;
  EventoPiano('completamento');
  ControllaPiano(AStato);
end;

// Normalizzazione, deduplica e validazione: nessun modello, nessun tool.
procedure TTurnoPianificato.ControllaPiano(AStato: TStatoTurno);
var
  LMappa: TDictionary<Integer, Integer>;
  LTolti, LNuovi: TArray<Integer>;
  LNoteDuplicati: TArray<string>;
  LDecisione: TDecisionePasso;
  LId, LNuovo, i: Integer;
  LPresente: Boolean;
begin
  FNote := TValidatorePiano.NormalizzaPiano(FPiano);

  LMappa := TDictionary<Integer, Integer>.Create;
  try
    LNoteDuplicati := TValidatorePiano.DeduplicaPassi(FPiano, LMappa, LTolti);
    if Length(LTolti) > 0 then
    begin
      FNote := FNote + LNoteDuplicati;
      // Stessa rinumerazione per le decisioni del retrieval e per i passi completati.
      if FRetrieval <> nil then
      begin
        for i := FRetrieval.Decisioni.Count - 1 downto 0 do
        begin
          LPresente := False;
          for LId in LTolti do
            if FRetrieval.Decisioni[i].Id = LId then
              LPresente := True;
          if LPresente then
            FRetrieval.Decisioni.Delete(i);
        end;
        for LDecisione in FRetrieval.Decisioni do
          if LMappa.TryGetValue(LDecisione.Id, LNuovo) then
            LDecisione.Id := LNuovo;
      end;
      LNuovi := nil;
      for LId in FCompletati do
        if LMappa.TryGetValue(LId, LNuovo) then
        begin
          LPresente := False;
          for i := 0 to High(LNuovi) do
            if LNuovi[i] = LNuovo then
              LPresente := True;
          if not LPresente then
            LNuovi := LNuovi + [LNuovo];
        end;
      FCompletati := LNuovi;
    end;
  finally
    LMappa.Free;
  end;

  // Ultimo argomento: testo noto per il controllo dei valori ancorati (domanda + storico
  // visto dal Planner).
  FErrori := TValidatorePiano.ValidaPiano(FPiano, FRetrieval, FCompletati,
    FDomanda + sLineBreak + FStoricoTesto);
  EventoControlli;
  if Length(FErrori) > 0 then
  begin
    ChiudiNonValido(AStato, '', Format('%d errori di validazione', [Length(FErrori)]));
    Exit;
  end;

  FEsecutore := TEsecutorePiano.Create(FPiano);
  FFase := fpEsecuzione;
end;

procedure TTurnoPianificato.PassoEsecuzione(AStato: TStatoTurno);
var
  LUltimo: TEsitoPasso;
  LEsito: TEsitoEsecuzione;
  i, LIndice: Integer;
begin
  FEsecutore.EseguiProssimoPasso;
  LEsito := FEsecutore.Esito;
  if LEsito.Esiti.Count > 0 then
  begin
    LUltimo := LEsito.Esiti[LEsito.Esiti.Count - 1];
    AggiungiTraccia(AStato, LUltimo);
    EventoTool(LUltimo);
    TLog.Write(Format('AGENTE - passo %d "%s": %s (%d ms)',
      [LUltimo.Id, LUltimo.Tool, LUltimo.Esito, LUltimo.DurataMs]));
  end
  else
    LUltimo := nil;

  if not FEsecutore.Concluso then
    Exit;                              // il prossimo passo esegue il tool successivo

  FEtichetta := LEsito.Etichetta;

  if (LEsito.CodiceArresto = 'CONFERMA_RICHIESTA') and (LUltimo <> nil) then
  begin
    // Scrittura proposta: si salva cio' che serve per riprenderla da qui alla conferma.
    LIndice := 0;
    for i := 0 to FPiano.Passi.Count - 1 do
      if FPiano.Passi[i].Id = LUltimo.Id then
        LIndice := i;
    FToolInAttesa := LUltimo.Tool;
    FNuovoSospeso := TJSONObject.Create;
    FNuovoSospeso.AddPair('tool', LUltimo.Tool);
    FNuovoSospeso.AddPair('piano', FPiano.ToJSON);
    FNuovoSospeso.AddPair('indice_passo', TJSONNumber.Create(LIndice));
    FNuovoSospeso.AddPair('output', FEsecutore.OutputRiusciti);
    FNuovoSospeso.AddPair('domanda', FDomanda);
    if LUltimo.ArgomentiRisolti <> nil then
      FNuovoSospeso.AddPair('argomenti', LUltimo.ArgomentiRisolti.Clone as TJSONValue)
    else
      FNuovoSospeso.AddPair('argomenti', TJSONObject.Create);
    Chiudi(AStato, TSintesiRisposta.TestoConferma(LUltimo.Tool, LUltimo.ArgomentiRisolti),
      STATO_IN_ATTESA_CONFERMA, FEtichetta);
    Exit;
  end;

  if (LEsito.CodiceArresto = 'DISAMBIGUAZIONE') and (LUltimo <> nil) and (LUltimo.Output <> nil) then
  begin
    Chiudi(AStato,
      TSintesiRisposta.TestoDisambiguazione(LUltimo.Output.GetValue('richiede_disambiguazione')),
      STATO_IN_ATTESA_SCELTA, FEtichetta);
    Exit;
  end;

  // Completata, oppure fermata per un motivo da spiegare: lo racconta il modello.
  FFase := fpSintesi;
end;

procedure TTurnoPianificato.PassoSintesi(AStato: TStatoTurno);
var
  LEsecuzione: TEsitoEsecuzione;
  LTesto: string;
  LInizio, LFine: Integer;
begin
  if FEsecutore <> nil then
    LEsecuzione := FEsecutore.Esito
  else
    LEsecuzione := nil;
  LTesto := ChiamaLLM(AStato, TSintesiRisposta.RichiestaSintesi(FDomanda, FOggi, FPiano,
    LEsecuzione, FArrestoPreventivo), 'sintesi');

  // Un eventuale blocco di ragionamento rimasto nel testo non va all'utente.
  LInizio := Pos('<think>', LTesto);
  LFine := Pos('</think>', LTesto);
  if (LInizio > 0) and (LFine > LInizio) then
    Delete(LTesto, LInizio, LFine + Length('</think>') - LInizio);

  Chiudi(AStato, Trim(LTesto), STATO_CONCLUSO, FEtichetta);
end;

// Cio' che e' successo nel turno, per il client e per la batteria di test
// (campo "pianificatore" della risposta). Del chiamante.
function TTurnoPianificato.DatiPerDiagnostica: TJSONObject;
var
  LErrori, LNote, LDecisioni, LCandidati, LEsiti, LEventi: TJSONArray;
  LRimossa: TJSONPair;
  i: Integer;
  LErrore: TErroreValidazione;
  LDecisione: TDecisionePasso;
  LVoce: TJSONObject;
  LNome, LNota: string;
  LEsito: TEsitoPasso;
begin
  Result := TJSONObject.Create;
  Result.AddPair('esecuzione', FEtichetta);
  Result.AddPair('stato_turno', FStatoTurno);
  if FToolInAttesa <> '' then
    Result.AddPair('tool_in_attesa', FToolInAttesa);
  if FPiano <> nil then
    Result.AddPair('piano', FPiano.ToJSON)
  else
    Result.AddPair('piano', TJSONNull.Create);

  LDecisioni := TJSONArray.Create;
  Result.AddPair('retrieval', LDecisioni);
  if FRetrieval <> nil then
    for LDecisione in FRetrieval.Decisioni do
    begin
      LVoce := TJSONObject.Create;
      LDecisioni.AddElement(LVoce);
      LVoce.AddPair('id', TJSONNumber.Create(LDecisione.Id));
      LVoce.AddPair('azione', LDecisione.Azione);
      LCandidati := TJSONArray.Create;
      for LNome in LDecisione.Candidati do
        LCandidati.Add(LNome);
      LVoce.AddPair('candidati', LCandidati);
      if LDecisione.ToolDichiarato <> '' then
      begin
        LVoce.AddPair('tool_dichiarato', LDecisione.ToolDichiarato);
        LVoce.AddPair('rango_dichiarato', TJSONNumber.Create(LDecisione.RangoDichiarato));
      end;
      LVoce.AddPair('declassato', TJSONBool.Create(LDecisione.Declassato));
      LVoce.AddPair('non_coperto', TJSONBool.Create(LDecisione.NonCoperto));
    end;

  LErrori := TJSONArray.Create;
  Result.AddPair('errori_validazione', LErrori);
  for LErrore in FErrori do
    LErrori.AddElement(TJSONObject.Create
      .AddPair('codice', LErrore.Codice)
      .AddPair('passo', TJSONNumber.Create(LErrore.Passo))
      .AddPair('messaggio', LErrore.Messaggio));

  LNote := TJSONArray.Create;
  Result.AddPair('normalizzazioni', LNote);
  for LNota in FNote do
    LNote.Add(LNota);

  // Gli eventi del registro, senza i messaggi inviati al modello (che
  // restano solo nel file di dettaglio: sono lunghi).
  LEventi := FEventi.Clone as TJSONArray;
  for i := 0 to LEventi.Count - 1 do
    if LEventi.Items[i] is TJSONObject then
    begin
      LRimossa := TJSONObject(LEventi.Items[i]).RemovePair('richiesta');
      LRimossa.Free;
    end;
  Result.AddPair('eventi', LEventi);

  LEsiti := TJSONArray.Create;
  Result.AddPair('esiti', LEsiti);
  if FEsecutore <> nil then
    for LEsito in FEsecutore.Esito.Esiti do
      LEsiti.AddElement(TJSONObject.Create
        .AddPair('id', TJSONNumber.Create(LEsito.Id))
        .AddPair('tool', LEsito.Tool)
        .AddPair('esito', LEsito.Esito)
        .AddPair('dettaglio', LEsito.Dettaglio));
end;

class procedure TTurnoPianificato.Consegna(AStato: TStatoTurno);
var
  LTurno: TTurnoPianificato;
  LRecord: TTurnoStorico;
  LSospeso: TJSONObject;
begin
  LTurno := TTurnoPianificato(AStato.Pianificatore);

  LRecord := TTurnoStorico.Create;
  LRecord.Domanda := LTurno.FDomanda;
  if LTurno.FPiano <> nil then
    LRecord.Piano := LTurno.FPiano.ToJSON;
  if LTurno.FEsecutore <> nil then
  begin
    LRecord.Esiti.Free;
    LRecord.Esiti := TArchivioStorici.EsitiPerStorico(LTurno.FEsecutore.Esito);
  end;
  LRecord.Risposta := AStato.Esito.RispostaFinale;
  LRecord.Stato := LTurno.FStatoTurno;
  LRecord.ToolInAttesa := LTurno.FToolInAttesa;

  // La scrittura in sospeso passa all'archivio (nil = nessuna, e cancella
  // quella del turno precedente).
  LSospeso := LTurno.FNuovoSospeso;
  LTurno.FNuovoSospeso := nil;
  TArchivioStorici.Registra(AStato.Esito.ConversationID, LRecord, LSospeso);

  AStato.Esito.StatoTurno := LTurno.FStatoTurno;
  AStato.Esito.DatiPianificatore.Free;
  AStato.Esito.DatiPianificatore := LTurno.DatiPerDiagnostica;

  LTurno.ScriviRegistro(AStato);
end;

// Testo per una cella del CSV: senza separatori ne' a capo.
function PerCsv(const ATesto: string): string;
begin
  Result := ATesto.Replace(';', ',').Replace(#13, ' ').Replace(#10, ' ');
end;

// Il registro del turno nei tre file (vedi l'intestazione).
procedure TTurnoPianificato.ScriviRegistro(AStato: TStatoTurno);
var
  LDiagnostica: TDiagnosticaTurno;
  LDettaglio: TJSONObject;
  LEsito: TEsitoPasso;
  LErrore: TErroreValidazione;
  LAdesso, LToolEseguiti, LErrori, LEsitoPiano: string;
  LDurataTool: Int64;
  LPassi: Integer;
begin
  LDiagnostica := AStato.Esito.Diagnostica;
  LAdesso := FormatDateTime('yyyy-mm-dd hh:nn:ss', Now);

  LToolEseguiti := '';
  LDurataTool := 0;
  if FEsecutore <> nil then
    for LEsito in FEsecutore.Esito.Esiti do
    begin
      LDurataTool := LDurataTool + LEsito.DurataMs;
      if LEsito.Esito = 'ok' then
      begin
        if LToolEseguiti <> '' then
          LToolEseguiti := LToolEseguiti + ',';
        LToolEseguiti := LToolEseguiti + LEsito.Tool;
      end;
    end;
  LErrori := '';
  for LErrore in FErrori do
  begin
    if LErrori <> '' then
      LErrori := LErrori + ',';
    LErrori := LErrori + LErrore.Codice;
  end;
  LEsitoPiano := '';
  LPassi := 0;
  if FPiano <> nil then
  begin
    LEsitoPiano := FPiano.Esito;
    LPassi := FPiano.Passi.Count;
  end;

  // 1. Leggibile: un blocco per turno scritto in una volta, cosi' i turni di conversazioni
  // diverse non si mescolano.
  TRegistroPianificatore.ScriviLog(
    Format('%s  TURNO %d [%s]', [LAdesso, AStato.NumeroTurno, AStato.Esito.ConversationID]) + sLineBreak +
    '  UTENTE: ' + FDomanda + sLineBreak +
    FRighe.Text.TrimRight + sLineBreak +
    Format('  FINE: stato %s, esecuzione %s | %d chiamate al modello, %d token di prompt, %d ms in totale',
      [FStatoTurno, FEtichetta, FChiamateLLM, LDiagnostica.PromptTokensTotali, LDiagnostica.DurataTotaleMs]) +
    sLineBreak);

  // 2. Una riga di metriche per turno.
  TRegistroPianificatore.ScriviCsv(string.Join(';', [
    LAdesso, AStato.Esito.ConversationID, IntToStr(AStato.NumeroTurno), PerCsv(FDomanda),
    LEsitoPiano, IntToStr(LPassi), FStatoTurno, FEtichetta, LToolEseguiti, LErrori,
    IntToStr(FChiamateLLM), IntToStr(LDiagnostica.PromptTokensTotali),
    IntToStr(LDiagnostica.CompletionTokensTotali), IntToStr(LDiagnostica.DurataLLMTotaleMs),
    IntToStr(LDiagnostica.DurataFase1Ms), IntToStr(LDurataTool),
    IntToStr(LDiagnostica.DurataTotaleMs), PerCsv(LDiagnostica.ModelloLLM),
    PerCsv(AStato.Opzioni.TestRun), PerCsv(AStato.Opzioni.TestCaso),
    PerCsv(AStato.Opzioni.TestRipetizione)]));

  // 3. Tutto, in un oggetto JSON su una riga.
  LDettaglio := TJSONObject.Create;
  try
    LDettaglio.AddPair('timestamp', LAdesso);
    LDettaglio.AddPair('conversation_id', AStato.Esito.ConversationID);
    LDettaglio.AddPair('turno_id', AStato.TurnoID);
    LDettaglio.AddPair('numero_turno', TJSONNumber.Create(AStato.NumeroTurno));
    LDettaglio.AddPair('domanda', FDomanda);
    LDettaglio.AddPair('storico_visto_dal_planner', FStoricoTesto);
    LDettaglio.AddPair('eventi', FEventi.Clone as TJSONArray);
    LDettaglio.AddPair('stato_turno', FStatoTurno);
    LDettaglio.AddPair('esecuzione', FEtichetta);
    LDettaglio.AddPair('risposta', AStato.Esito.RispostaFinale);
    LDettaglio.AddPair('chiamate_llm', TJSONNumber.Create(FChiamateLLM));
    LDettaglio.AddPair('prompt_tokens', TJSONNumber.Create(LDiagnostica.PromptTokensTotali));
    LDettaglio.AddPair('completion_tokens', TJSONNumber.Create(LDiagnostica.CompletionTokensTotali));
    LDettaglio.AddPair('durata_totale_ms', TJSONNumber.Create(LDiagnostica.DurataTotaleMs));
    // Nome del modello come lo dichiara il motore nella risposta (non l'ini).
    LDettaglio.AddPair('modello', LDiagnostica.ModelloLLM);
    LDettaglio.AddPair('test_run', AStato.Opzioni.TestRun);
    LDettaglio.AddPair('test_caso', AStato.Opzioni.TestCaso);
    LDettaglio.AddPair('test_ripetizione', AStato.Opzioni.TestRipetizione);
    TRegistroPianificatore.ScriviDettaglio(LDettaglio.ToJSON);
  finally
    LDettaglio.Free;
  end;
end;

end.
