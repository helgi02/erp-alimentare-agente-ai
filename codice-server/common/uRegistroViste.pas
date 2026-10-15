unit uRegistroViste;

(* ============================================================================
  TRegistroViste — catalogo condiviso delle "viste apribili" del gestionale
  su richiesta del modello, tramite il tool MCP generico apri_vista (vedi
  agente_ai/tool/uNavigazioneToolProvider.pas).

  ── Il problema che risolve ─────────────────────────────────────────────────
  Il modello deve poter chiedere "apri la schermata X per l'entita' Y" senza
  che il tool che esegue quella richiesta (apri_vista) debba conoscere ogni
  scenario del gestionale (ricette, vendite, ritiro/richiamo, ...). Ma
  qualcuno deve pur sapere che la vista "ricetta_prodotto_finito" esiste e
  che le serve un "prodotto_finito_id" per essere aperta: quel qualcuno e' il
  tool provider dello SCENARIO a cui la vista appartiene (es. il futuro
  TRicetteToolProvider), non il tool di navigazione stesso.

  Questa unit e' il punto di incontro fra le due cose: ogni tool provider che
  possiede una vista sensata da aprire (non tutti ce l'hanno: TVenditeToolProvider,
  i cui dati stanno gia' bene in una tabella di chat, non ne registra nessuna)
  dichiara un TDefinizioneVista e la registra qui con TRegistroViste.Registra,
  UNA VOLTA SOLA, in uFrmMain.FormCreate, accanto alla riga che registra i
  suoi tool MCP (RegisterToolProvider/RegisterDynamicProvider) — stesso
  principio "wiring esplicito, niente scoperta automatica via RTTI o unit
  initialization" gia' seguito li' per i tool.

  TNavigazioneToolProvider (il tool apri_vista) legge poi SOLO questo
  registro: non importa mai nessuna unit di uno scenario specifico, quindi
  resta riutilizzabile senza modifiche quando si aggiungeranno le viste di
  ritiro/richiamo (scenario 1) e vendite (scenario 2, se mai servisse).

  ── Perche' un registro "piatto" e non un dizionario per-scenario ──────────
  Il numero di viste totali atteso e' piccolo (una manciata, una per
  scenario che ne ha davvero bisogno): una lista lineare con ricerca O(n) e'
  piu' che sufficiente e piu' semplice da leggere di una struttura ad-hoc.

  ── Ciclo di vita e sicurezza per i thread ──────────────────────────────────
  Registra va chiamato SOLO durante l'avvio (stessa finestra temporale della
  registrazione dei tool provider in FormCreate), prima che il server inizi
  ad accettare richieste. Da quel momento il registro e' soltanto letto, in
  concorrenza da thread diversi (un TFilesToolsProvider/TNavigazioneToolProvider
  e' un'istanza condivisa fra i worker Indy) — la sola lettura di una lista
  gia' popolata e stabile e' intrinsecamente sicura, senza bisogno di lock.
  ============================================================================ *)

interface

uses
  System.Generics.Collections;

type
  // Una voce del catalogo: Nome e' l'identificatore stabile che il modello
  // passa al tool apri_vista e che il frontend usa per instradare la
  // navigazione (es. 'ricetta_prodotto_finito'); Descrizione e' una riga
  // di testo pensata per il MODELLO (finisce nella descrizione del tool
  // apri_vista, per aiutarlo a capire quando questa vista e' pertinente);
  // ChiaviRichieste sono le chiavi obbligatorie che il modello deve fornire
  // nell'oggetto "parametri" quando chiede di aprire questa vista (es.
  // ['prodotto_finito_id']).
  TDefinizioneVista = record
    Nome: string;
    Descrizione: string;
    ChiaviRichieste: TArray<string>;
  end;

  TRegistroViste = class
  private
    // class var (non un'istanza con GetInstance come TConfig): questo
    // registro non ha un "proprietario" che lo crea e lo libera in un
    // punto preciso del ciclo di vita dell'applicazione, e' solo stato
    // condiviso per la durata del processo — un class constructor/
    // destructor lo inizializza/libera automaticamente, senza bisogno che
    // nessuno lo crei esplicitamente prima del primo uso.
    class var FViste: TList<TDefinizioneVista>;
    class constructor Create;
    class destructor Destroy;
  public
    // Registra una vista. Solleva un'eccezione se il nome e' gia' presente:
    // una doppia registrazione sullo stesso nome e' quasi certamente un
    // copia-incolla sbagliato fra due tool provider (o una riga duplicata
    // in FormCreate) — meglio far fallire rumorosamente l'avvio del server
    // che avere due definizioni in conflitto silenzioso per la stessa
    // vista. Stessa filosofia del "Duplicate tool name" gia' sollevato da
    // TMCPServer.RegisterToolProvider per i tool.
    class procedure Registra(const ADefinizione: TDefinizioneVista); overload;
    class procedure Registra(const ANome, ADescrizione: string;
      const AChiaviRichieste: TArray<string>); overload;

    // Cerca una vista per nome (case-insensitive). False se il nome non e'
    // stato registrato da nessun tool provider — il chiamante
    // (TNavigazioneToolProvider.InvokeDynamic) lo trasforma in un
    // tool_result di errore "di dominio" che il modello vede e puo'
    // correggere, non in un'eccezione.
    class function Find(const ANome: string; out ADefinizione: TDefinizioneVista): Boolean;

    // Tutte le viste registrate, nell'ordine di registrazione. Usato da
    // TNavigazioneToolProvider per costruire SIA la validazione (Execute)
    // SIA il testo della descrizione del tool (GetDynamicToolDefs) a
    // partire dalla stessa fonte: cosi' l'elenco che il modello legge nel
    // prompt e quello che il codice valida davvero non possono
    // disallinearsi.
    class function GetAll: TArray<TDefinizioneVista>;
  end;

implementation

uses
  System.SysUtils;

{ TRegistroViste }

class constructor TRegistroViste.Create;
begin
  FViste := TList<TDefinizioneVista>.Create;
end;

class destructor TRegistroViste.Destroy;
begin
  FViste.Free;
end;

class procedure TRegistroViste.Registra(const ADefinizione: TDefinizioneVista);
var
  LEsistente: TDefinizioneVista;
begin
  if Find(ADefinizione.Nome, LEsistente) then
    raise Exception.CreateFmt(
      'TRegistroViste.Registra: la vista "%s" e'' gia'' registrata. Controlla se ' +
      'due tool provider dichiarano lo stesso nome, o se FormCreate la registra ' +
      'due volte per errore.',
      [ADefinizione.Nome]);

  FViste.Add(ADefinizione);
end;

class procedure TRegistroViste.Registra(const ANome, ADescrizione: string;
  const AChiaviRichieste: TArray<string>);
var
  LDefinizione: TDefinizioneVista;
begin
  LDefinizione.Nome := ANome;
  LDefinizione.Descrizione := ADescrizione;
  LDefinizione.ChiaviRichieste := AChiaviRichieste;
  Registra(LDefinizione);
end;

class function TRegistroViste.Find(const ANome: string;
  out ADefinizione: TDefinizioneVista): Boolean;
var
  LVista: TDefinizioneVista;
begin
  for LVista in FViste do
    if SameText(LVista.Nome, ANome) then
    begin
      ADefinizione := LVista;
      Exit(True);
    end;

  Result := False;
end;

class function TRegistroViste.GetAll: TArray<TDefinizioneVista>;
begin
  Result := FViste.ToArray;
end;

end.
