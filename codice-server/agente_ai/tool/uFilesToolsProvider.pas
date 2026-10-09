unit uFilesToolsProvider;

(* ============================================================================
  TFilesToolsProvider — tool MCP generico per generare file (CSV, PDF) a
  partire da dati che il MODELLO stesso fornisce, non il DB.

  ── Perche' questo provider e' diverso da TVenditeToolProvider ─────────────
  get_list_vendite (uVenditeToolProvider.pas) e' un tool "RTTI": i suoi
  parametri sono dichiarati come argomenti Pascal normali (const ANomeCliente:
  string, ecc.) e il framework li scopre via RTTI leggendo gli attributi
  [MCPTool]/[MCPParam]. Questa via supporta SOLO parametri scalari (string,
  integer, double, boolean) - vedi TMCPServer.DelphiTypeToJsonSchema nella
  libreria: non c'e' modo di dichiarare un parametro Pascal che diventi uno
  schema JSON "array" o "object" veri.

  I due tool esposti qui (generate_csv, generate_pdf) hanno invece bisogno di
  "colonne" (un array di definizioni colonna) e "righe" (un array di righe,
  cioe' di oggetti) come parametri REALI, non stringhe da interpretare a
  mano. Per questo il provider usa la via "dinamica" della libreria MCP:

    - GetDynamicToolDefs: dichiara a mano nome/descrizione/parametri di ogni
      tool (TMCPDynamicToolDef/TMCPDynamicParamDef), specificando
      esplicitamente JsonSchemaType := 'array' dove serve - non essendoci un
      parametro Pascal reale dietro, non c'e' RTTI da leggere.
    - InvokeDynamic: riceve il TJDOJsonObject "arguments" cosi' come arrivato
      dal client MCP (nessun marshalling automatico verso tipi Pascal, a
      differenza della via RTTI) e lo interpreta qui dentro con l'API di
      JsonDataObjects.

  ── Flusso d'uso previsto ───────────────────────────────────────────────────
  1. Il modello chiama un tool "dati" qualsiasi (es. get_list_vendite) e
     riceve una risposta JSON con un array di righe (es. "dettaglio").
  2. Il modello chiama generate_csv o generate_pdf passando:
       colonne: [{"campo": "cliente", "intestazione": "Cliente"}, ...
       righe:   [ {...}, {...}, ... ]   <- le righe ricevute al passo 1,
                                            COSI' COME SONO, non riscritte
     "campo" indica quale chiave leggere da ogni riga; "intestazione" e' il
     testo di colonna nel file generato.
  3. Il tool SCRIVE il file nella cartella di export del server (TConfig.
     ExportFolder, di default "export" accanto all'eseguibile) e risponde
     con un URL di download vero e proprio (es. http://localhost:8080/
     export/20260724_161005123_vendite.csv), servito come contenuto
     statico da TMVCStaticFilesMiddleware (vedi uWebModule.pas).

     *** Perche' non embedded nel tool_result (prima versione) ***
     La versione precedente restituiva il contenuto incorporato nella
     risposta JSON-RPC (Resource/ResourceBlob, vedi TMCPToolResult) per non
     scrivere nulla su disco. Provato con LM Studio (client MCP reale usato
     in questo progetto): il client mostra il tool_result solo come JSON
     grezzo nel pannello "Result" della chiamata, senza renderizzare i
     content-block "resource"/"resourceBlob" come allegato scaricabile - il
     modello vede il contenuto ma non c'e' modo per l'utente di scaricare
     il file. Un vero URL HTTP, invece, e' testo semplice: qualunque client
     (e qualunque modello, riportandolo in chat) lo puo' mostrare/copiare,
     a prescindere dal supporto o meno delle MCP resource.

     *** Limiti noti di questa scelta ***
     - I file scritti in ExportFolder non vengono mai ripuliti
       automaticamente: si accumulano nel tempo. Accettabile per una demo/
       tesi; in produzione servirebbe un job di pulizia (es. cancellazione
       dei file piu' vecchi di N ore) o una directory temporanea dedicata.
     - /export non richiede autenticazione: chiunque conosca (o indovini)
       il nome del file generato puo' scaricarlo. Coerente con l'assunzione
       di progetto "infrastruttura locale, nessun dato esce" - da rivedere
       se il server fosse mai esposto oltre localhost/rete fidata.

  ── Riuso dei motori di export ──────────────────────────────────────────────
  La costruzione vera e propria del CSV/PDF non e' qui: e' delegata a
  TEsportazioneCSV/TEsportazionePDF (services/uEsportazioneCSV.pas,
  services/uEsportazionePDF.pas), generici su un tipo di riga T. Qui T e'
  SEMPRE TJDOJsonObject (la riga e' letteralmente l'oggetto JSON che il
  modello ha passato) - questo file si occupa solo di leggere "colonne"/
  "righe" dall'input, di tradurre ogni definizione colonna in un
  TColonnaCSV<TJDOJsonObject>/TColonnaPDF<TJDOJsonObject> (nome + funzione
  che legge quel campo da una riga), e di scrivere il risultato su disco
  con un nome file univoco e sicuro (vedi CostruisciNomeFileUnico).
  ============================================================================ *)

interface

uses
  System.SysUtils,
  System.IOUtils,
  System.DateUtils,
  System.RegularExpressions,
  JsonDataObjects,
  MVCFramework.MCP.ToolProvider,
  uContrattiTool,
  uConfig,
  uEsportazioneCSV,
  uEsportazionePDF;

type
  TFilesToolsProvider = class(TMCPToolProvider)
  public
    function GetDynamicToolDefs: TArray<TMCPDynamicToolDef>; override;
    function InvokeDynamic(const AToolName: string;
      AArguments: TJDOJsonObject): TMCPToolResult; override;
    // Contratti dei tool di questo provider per il pianificatore: schema del
    // risultato, lettura/scrittura, conferma, vincoli sugli input (vedi
    // agente_ai/tool/uContrattiTool.pas e la sezione in fondo a questa unit).
    class function ContrattiTool: TArray<TContrattoTool>;
  end;

implementation

type
  // Una voce del parametro "colonne": Campo e' la chiave da leggere in ogni
  // riga, Intestazione e' il testo da stampare come intestazione di colonna
  // nel file generato (uguale a Campo se il chiamante non la specifica).
  TDefinizioneColonna = record
    Campo: string;
    Intestazione: string;
  end;

{ Funzioni di supporto, private all'unit }

// Legge il valore del campo ACampo dalla riga ARiga come stringa
// stampabile, per qualunque colonna venga chiesta (sia CSV sia PDF passano
// da qui - vedi CreaEstrattoreCampo). Non e' specifico di nessuno scenario:
// non sa nulla di vendite, ritiro/richiamo o altro, sa solo "come si legge
// un campo di un TJDOJsonObject come testo".
//
// TJsonObject.S[] fa gia' l'auto-cast per string/int/long/float/bool/data
// (vedi il commento sulla property in JsonDataObjects.pas: "returns '' if
// property doesn't exist, auto type-cast except for array/object") - qui
// serve gestire ESPLICITAMENTE solo il caso array/object, per cui l'auto-
// cast non esiste: si ripiega sulla rappresentazione JSON compatta del
// valore, invece di lasciare che .S[] restituisca una stringa vuota che
// nasconderebbe silenziosamente il dato.
// Se AValore e' una data o una data-ora in formato ISO 8601 (come tipicamente
// serializzata da DB/JSON, es. "2026-08-01T00:00:00.000Z" o "2026-08-01"),
// la riformatta in gg/mm/aaaa (con l'orario in coda solo se presente e
// diverso da mezzanotte - una data-ora a mezzanotte e' quasi sempre una
// colonna DATE serializzata con un orario fittizio, non un dato realmente
// time-sensitive, quindi l'orario si scarta). Se AValore non corrisponde al
// pattern, viene restituito invariato: questa funzione non sa nulla del
// significato del campo, riconosce solo la FORMA del valore - e' percio'
// generica quanto LeggiCellaComeStringa che la chiama, e si applica quindi
// automaticamente sia all'export CSV sia a quello PDF (entrambi passano da
// li'), senza dipendere da come il modello decide di formattare le date.
function FormattaSeData(const AValore: string): string;
const
  // BUG CORRETTO (ERegularExpressionError "Index out of bounds (4)", visto
  // ripetutamente come first-chance exception in debug durante l'export
  // CSV/PDF - il debugger la segnala comunque anche se poi viene intercettata,
  // vedi sotto). Il pattern originale era UNO SOLO, con la parte orario
  // interamente opzionale: '...(?:[T ](\d{2}):(\d{2}):(\d{2})...)?$' - i
  // gruppi 4/5/6 (ora/minuto/secondo) vivono dentro un gruppo non catturante
  // opzionale. Su un valore SENZA orario (il caso piu' comune: "2026-08-01",
  // che e' come arrivano quasi tutte le date da get_list_vendite) quel blocco
  // opzionale non partecipa affatto al match, e con questo motore regex la
  // riga "LMatch.Groups[4]" non restituisce un gruppo "non riuscito" ma
  // solleva ERegularExpressionError: l'eccezione veniva silenziosamente
  // inghiottita dal blocco "except Exit" qui sotto (pensato per un errore
  // diverso, vedi il suo commento), quindi la funzione uscendo in anticipo
  // ha sempre lasciato Result = AValore, cioe' la data non e' MAI stata
  // riformattata in gg/mm/aaaa per un valore senza orario - visibile nei CSV
  // gia' esportati (colonna "Data Ordine" ancora in aaaa-mm-gg).
  //
  // Rimedio: due pattern SEPARATI invece di uno con una parte opzionale.
  // Si prova prima quello con l'orario (tutti i suoi gruppi sono OBBLIGATORI
  // per costruzione, quindi se il match riesce i gruppi 1..6 esistono e sono
  // partecipanti per certo); solo se non trova orario si prova il pattern
  // "sola data" (3 gruppi, anch'essi tutti obbligatori). Cosi' non si indicizza
  // mai un gruppo la cui esistenza dipenda da una parte opzionale del pattern -
  // l'ambiguita' che ha causato il bug non puo' piu' presentarsi.
  PATTERN_DATA_ORA = '^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})(?:\.\d+)?Z?$';
  PATTERN_SOLO_DATA = '^(\d{4})-(\d{2})-(\d{2})$';
var
  LMatch: TMatch;
  LOra, LMinuto, LSecondo: Integer;
  LData: TDateTime;
  LConOrario: Boolean;
begin
  Result := AValore;

  LMatch := TRegEx.Match(AValore, PATTERN_DATA_ORA);
  LConOrario := LMatch.Success;
  if not LConOrario then
  begin
    LMatch := TRegEx.Match(AValore, PATTERN_SOLO_DATA);
    if not LMatch.Success then
      Exit; // non e' una data in questo formato: restituita invariata
  end;

  try
    if LConOrario then
    begin
      LOra := StrToInt(LMatch.Groups[4].Value);
      LMinuto := StrToInt(LMatch.Groups[5].Value);
      LSecondo := StrToInt(LMatch.Groups[6].Value);
    end
    else
    begin
      LOra := 0;
      LMinuto := 0;
      LSecondo := 0;
    end;
    LData := EncodeDate(
      StrToInt(LMatch.Groups[1].Value),
      StrToInt(LMatch.Groups[2].Value),
      StrToInt(LMatch.Groups[3].Value)) + EncodeTime(LOra, LMinuto, LSecondo, 0);
  except
    Exit; // pattern soddisfatto ma valori non validi (es. mese 13) -> lascia invariato
  end;
  if (LOra = 0) and (LMinuto = 0) and (LSecondo = 0) then
    Result := FormatDateTime('dd/mm/yyyy', LData)
  else
    Result := FormatDateTime('dd/mm/yyyy hh:nn', LData);
end;

function LeggiCellaComeStringa(ARiga: TJDOJsonObject; const ACampo: string): string;
begin
  if not ARiga.Contains(ACampo) then
    Exit('');

  case ARiga.Types[ACampo] of
    jdtArray:
      Result := ARiga.A[ACampo].ToJSON;
    jdtObject:
      Result := ARiga.O[ACampo].ToJSON;
  else
    Result := FormattaSeData(ARiga.S[ACampo]);
  end;
end;

// Costruisce la funzione di estrazione per UNA colonna. ACampo e' un
// PARAMETRO di questa funzione (non una variabile del ciclo chiamante) di
// proposito: se si costruisse la closure direttamente dentro un "for" che
// riusa la stessa variabile locale ad ogni iterazione, tutte le closure
// catturerebbero la STESSA variabile e finirebbero per leggere tutte
// l'ultimo campo del ciclo (bug classico di cattura in Delphi/molti altri
// linguaggi) - passare per un parametro di funzione da' a ciascuna closure
// la propria copia indipendente.
function CreaEstrattoreCampo(const ACampo: string): TFunc<TJDOJsonObject, string>;
begin
  Result :=
    function(ARiga: TJDOJsonObject): string
    begin
      Result := LeggiCellaComeStringa(ARiga, ACampo);
    end;
end;

// Legge e valida il parametro "colonne": deve essere un array non vuoto di
// oggetti {"campo": "...", "intestazione": "..." (opzionale)}. Solleva
// un'eccezione con un messaggio pensato per il modello (non per un log di
// sistema) su qualunque forma imprevista - InvokeDynamic la trasforma in
// TMCPToolResult.Error, cosi' il modello vede il problema e puo' correggere
// la chiamata al turno successivo invece di ricevere un errore di trasporto
// opaco.
function LeggiDefinizioniColonne(AArguments: TJDOJsonObject): TArray<TDefinizioneColonna>;
var
  LColonne: TJDOJsonArray;
  LColonnaObj: TJDOJsonObject;
  I: Integer;
begin
  if not (AArguments.Contains('colonne') and (AArguments.Types['colonne'] = jdtArray)) then
    raise Exception.Create(
      'Parametro "colonne" mancante o non e'' un array. Atteso un array di oggetti ' +
      '{"campo": "...", "intestazione": "..."}.');

  LColonne := AArguments.A['colonne'];
  if LColonne.Count = 0 then
    raise Exception.Create('Parametro "colonne" vuoto: specifica almeno una colonna.');

  SetLength(Result, LColonne.Count);
  for I := 0 to LColonne.Count - 1 do
  begin
    if LColonne.Types[I] <> jdtObject then
      raise Exception.CreateFmt(
        'Elemento %d di "colonne" non e'' un oggetto: atteso {"campo": "...", "intestazione": "..."}.',
        [I]);

    LColonnaObj := LColonne.O[I];
    if Trim(LColonnaObj.S['campo']) = '' then
      raise Exception.CreateFmt(
        'Elemento %d di "colonne" non ha un "campo" valorizzato.', [I]);

    Result[I].Campo := LColonnaObj.S['campo'];
    if Trim(LColonnaObj.S['intestazione']) <> '' then
      Result[I].Intestazione := LColonnaObj.S['intestazione']
    else
      // Nessuna intestazione esplicita: usa il nome del campo cosi' com'e'
      // (meglio un'intestazione un po' tecnica che un file senza intestazione).
      Result[I].Intestazione := Result[I].Campo;
  end;
end;

// Legge e valida il parametro "righe": un array non vuoto di oggetti. Le
// singole righe restituite sono RIFERIMENTI dentro AArguments (di proprieta'
// del chiamante di InvokeDynamic, cioe' del framework) - questa funzione
// non ne prende possesso e non li libera.
function LeggiRighe(AArguments: TJDOJsonObject): TArray<TJDOJsonObject>;
var
  LRighe: TJDOJsonArray;
  I: Integer;
begin
  if not (AArguments.Contains('righe') and (AArguments.Types['righe'] = jdtArray)) then
    raise Exception.Create('Parametro "righe" mancante o non e'' un array.');

  LRighe := AArguments.A['righe'];
  if LRighe.Count = 0 then
    raise Exception.Create('Parametro "righe" vuoto: non c''e'' nulla da esportare.');

  SetLength(Result, LRighe.Count);
  for I := 0 to LRighe.Count - 1 do
  begin
    if LRighe.Types[I] <> jdtObject then
      raise Exception.CreateFmt('Elemento %d di "righe" non e'' un oggetto.', [I]);
    Result[I] := LRighe.O[I];
  end;
end;

// Traduce le definizioni colonna (generiche, lette dal JSON) nel formato
// richiesto dal motore CSV condiviso (services/uEsportazioneCSV.pas).
function CostruisciColonneCSV(
  const ADefinizioni: TArray<TDefinizioneColonna>): TArray<TColonnaCSV<TJDOJsonObject>>;
var
  I: Integer;
begin
  SetLength(Result, Length(ADefinizioni));
  for I := 0 to High(ADefinizioni) do
    Result[I] := TColonnaCSV<TJDOJsonObject>.Create(
      ADefinizioni[I].Intestazione, CreaEstrattoreCampo(ADefinizioni[I].Campo));
end;

// Come sopra, per il motore PDF condiviso (services/uEsportazionePDF.pas).
function CostruisciColonnePDF(
  const ADefinizioni: TArray<TDefinizioneColonna>): TArray<TColonnaPDF<TJDOJsonObject>>;
var
  I: Integer;
begin
  SetLength(Result, Length(ADefinizioni));
  for I := 0 to High(ADefinizioni) do
    Result[I] := TColonnaPDF<TJDOJsonObject>.Create(
      ADefinizioni[I].Intestazione, CreaEstrattoreCampo(ADefinizioni[I].Campo));
end;

// Nome file "grezzo" richiesto dal chiamante (parametro opzionale "nome_file"):
// se assente o vuoto, ADefault. Nessuna validazione qui - il nome arriva
// cosi' com'e' dal modello e va sempre ripulito da CostruisciNomeFileUnico
// prima di essere usato come nome file reale su disco.
function NomeFileRichiesto(AArguments: TJDOJsonObject; const ADefault: string): string;
begin
  if AArguments.Contains('nome_file') and (Trim(AArguments.S['nome_file']) <> '') then
    Result := Trim(AArguments.S['nome_file'])
  else
    Result := ADefault;
end;

// Costruisce un nome file SICURO e UNIVOCO per il file da scrivere in
// TConfig.ExportFolder, a partire dal nome "grezzo" richiesto dal modello.
//
// Sicurezza: ANomeRichiesto arriva da un parametro di tool MCP, cioe' da
// testo che il modello ha generato - non fidarsi mai che sia un nome file
// valido. TPath.GetFileNameWithoutExtension scarta qualunque componente di
// percorso (cartelle, "..", ecc.); il filtro carattere-per-carattere che
// segue elimina anche cio' che restasse (separatori, due punti, ecc.),
// tenendo solo lettere/cifre/underscore/trattino. Il risultato non puo'
// quindi mai uscire da ExportFolder (niente path traversal).
//
// Univocita': un prefisso timestamp con i millisecondi rende la collisione
// fra due chiamate concorrenti estremamente improbabile - accettabile per
// questo scenario (non serve una garanzia crittografica, solo evitare che
// due export ravvicinati si sovrascrivano).
function CostruisciNomeFileUnico(const ANomeRichiesto, AEstensione: string): string;
var
  LBase: string;
  LPulito: string;
  I: Integer;
  LCarattere: Char;
begin
  LBase := TPath.GetFileNameWithoutExtension(ANomeRichiesto);

  LPulito := '';
  for I := 1 to Length(LBase) do
  begin
    LCarattere := LBase[I];
    if CharInSet(LCarattere, ['a'..'z', 'A'..'Z', '0'..'9', '_', '-']) then
      LPulito := LPulito + LCarattere
    else
      LPulito := LPulito + '_';
  end;

  if LPulito = '' then
    LPulito := 'export';

  Result := FormatDateTime('yyyymmdd_hhnnsszzz', Now) + '_' + LPulito + '.' + AEstensione;
end;

{ TFilesToolsProvider }

function TFilesToolsProvider.GetDynamicToolDefs: TArray<TMCPDynamicToolDef>;

  // Costruisce un TMCPDynamicParamDef: helper locale solo per non ripetere
  // l'assegnazione campo per campo quattro volte sotto.
  function DefParam(const AName, ADescription: string; ARequired: Boolean;
    const AJsonSchemaType: string): TMCPDynamicParamDef;
  begin
    Result.Name := AName;
    Result.Description := ADescription;
    Result.Required := ARequired;
    Result.JsonSchemaType := AJsonSchemaType;
  end;

const
  DESCR_COLONNE =
    'Array di oggetti {"campo": "...", "intestazione": "..."}. "campo" e'' il nome della ' +
    'chiave da leggere in ogni elemento di "righe"; "intestazione" (opzionale) e'' il testo da ' +
    'usare come intestazione di colonna nel file generato - se omessa si usa "campo". Un ' +
    'elemento per ogni colonna, nell''ordine in cui deve comparire nel file.';
  DESCR_RIGHE =
    'Array di oggetti: i dati da esportare, uno per riga. Ogni oggetto deve contenere (almeno) ' +
    'le chiavi elencate in "colonne". Le righe arrivano SEMPRE dal risultato di un altro tool ' +
    'eseguito in questa stessa richiesta: in un piano scrivi il riferimento al passo che ha ' +
    'letto i dati, es. "$1.dettaglio" per get_list_vendite. NON ricopiare a mano righe viste ' +
    'in un turno precedente della conversazione: li'' ne compaiono solo alcune, il file ' +
    'risulterebbe incompleto o con valori inventati. Se i dati sono di un turno precedente, ' +
    'prima va rieseguito il tool che li legge, con gli stessi filtri.';

  // NOTA (03/10/2026) sul testo qui sopra. Prima diceva "copia le righe cosi'
  // come le hai ricevute": con il pianificatore, a un seguito come "esportalo
  // in csv" il modello ricopiava le righe dallo storico della conversazione,
  // che pero' riporta solo le prime 3 di ogni elenco (uStoricoTurni,
  // MaxElementi). Le altre le ricostruiva dal testo della risposta,
  // inventando gli id: il validatore bloccava il piano con
  // VALORE_NON_ANCORATO (conversazione 0B4607C4, turno 4). La strada giusta e'
  // rileggere i dati e passarli per riferimento: il modello non riscrive
  // nessuna riga, quindi non puo' sbagliarla ne' perderla.
  DESCR_NOME_FILE =
    'Nome file suggerito, es. "vendite" (opzionale, un default viene usato se assente). Diventa ' +
    'parte del nome del file scaricabile: viene ripulito da caratteri non validi e reso univoco ' +
    'con un prefisso data/ora, l''estensione la sceglie il server in base al tool invocato.';
begin
  SetLength(Result, 2);

  Result[0].Name := 'generate_csv';
  Result[0].Description :=
    'Genera un file CSV a partire da colonne e righe fornite dal chiamante. Usa questo tool ' +
    'DOPO il tool che legge i dati, nella stessa richiesta: le righe sono il risultato di quel ' +
    'tool (in un piano, un riferimento come "$1.dettaglio"), tu definisci solo quali campi ' +
    'diventano colonne e con quale intestazione. Il risultato e'' un link ' +
    'di download: riportalo all''utente cosi'' com''e'', non descriverne il contenuto al posto del file.';
  Result[0].ControllerClassName := 'TFilesToolsProvider';
  Result[0].Params := TArray<TMCPDynamicParamDef>.Create(
    DefParam('colonne', DESCR_COLONNE, True, 'array'),
    DefParam('righe', DESCR_RIGHE, True, 'array'),
    DefParam('nome_file', DESCR_NOME_FILE, False, 'string')
  );

  Result[1].Name := 'generate_pdf';
  Result[1].Description :=
    'Genera un documento PDF con una tabella, a partire da colonne e righe fornite dal ' +
    'chiamante. Stesso utilizzo di generate_csv: le righe sono il risultato del tool che ha ' +
    'letto i dati nella stessa richiesta (in un piano, un riferimento come "$1.dettaglio"). ' +
    'Il risultato e'' un link di download: riportalo all''utente cosi'' com''e''.';
  Result[1].ControllerClassName := 'TFilesToolsProvider';
  Result[1].Params := TArray<TMCPDynamicParamDef>.Create(
    DefParam('colonne', DESCR_COLONNE, True, 'array'),
    DefParam('righe', DESCR_RIGHE, True, 'array'),
    DefParam('titolo', 'Titolo stampato in cima al documento (opzionale).', False, 'string'),
    DefParam('nome_file', DESCR_NOME_FILE, False, 'string')
  );
end;

function TFilesToolsProvider.InvokeDynamic(const AToolName: string;
  AArguments: TJDOJsonObject): TMCPToolResult;
var
  LDefinizioni: TArray<TDefinizioneColonna>;
  LRighe: TArray<TJDOJsonObject>;
  LNomeFile: string;
  LPercorsoFile: string;
  LUrlDownload: string;
begin
  if AArguments = nil then
    Exit(TMCPToolResult.Error('Argomenti mancanti: servono "colonne" e "righe".'));

  // "colonne" e "righe" sono comuni a entrambi i tool: lette una volta sola
  // qui, prima di smistare su quale file generare.
  try
    LDefinizioni := LeggiDefinizioniColonne(AArguments);
    LRighe := LeggiRighe(AArguments);
  except
    on E: Exception do
      // Errore di formato imputabile a chi ha costruito la chiamata (il
      // modello): .Error (isError=true), non un'eccezione che si propaga
      // come errore di trasporto - il modello vede il messaggio e puo'
      // correggere la chiamata al turno successivo.
      Exit(TMCPToolResult.Error(E.Message));
  end;

  try
    if SameText(AToolName, 'generate_csv') then
    begin
      LNomeFile := CostruisciNomeFileUnico(NomeFileRichiesto(AArguments, 'export'), 'csv');
      LPercorsoFile := TPath.Combine(TConfig.GetInstance.ExportFolder, LNomeFile);

      // TEncoding.UTF8 scrive anche il preambolo BOM: senza, Excel (il
      // consumatore piu' probabile di un CSV su Windows) puo' interpretare
      // male gli accenti italiani nei dati (es. "qualita'" -> caratteri
      // corrotti) aprendo il file con la codifica ANSI di default.
      TFile.WriteAllText(LPercorsoFile,
        TEsportazioneCSV.Costruisci<TJDOJsonObject>(CostruisciColonneCSV(LDefinizioni), LRighe),
        TEncoding.UTF8);
    end
    else if SameText(AToolName, 'generate_pdf') then
    begin
      LNomeFile := CostruisciNomeFileUnico(NomeFileRichiesto(AArguments, 'export'), 'pdf');
      LPercorsoFile := TPath.Combine(TConfig.GetInstance.ExportFolder, LNomeFile);

      TFile.WriteAllBytes(LPercorsoFile,
        TEsportazionePDF.Costruisci<TJDOJsonObject>(
          AArguments.S['titolo'], CostruisciColonnePDF(LDefinizioni), LRighe));
    end
    else
      // Non dovrebbe succedere (TMCPServer.RegisterDynamicProvider dispatcha
      // solo i nomi restituiti da GetDynamicToolDefs), ma un fallback
      // esplicito e' piu' sicuro di un case senza else.
      Exit(TMCPToolResult.Error(Format(
        '"%s" non e'' un tool gestito da questo provider.', [AToolName])));
  except
    on E: Exception do
      // Errore di scrittura su disco (permessi, spazio esaurito, cartella
      // di export rimossa a runtime, ecc.): non e' colpa del modello, ma va
      // comunque restituito come .Error (isError=true) e non lasciato
      // propagare - un'eccezione non gestita qui diventerebbe un errore di
      // trasporto JSON-RPC generico, molto meno utile in chat di un
      // messaggio che spiega cosa e' andato storto.
      Exit(TMCPToolResult.Error('Impossibile generare il file: ' + E.Message));
  end;

  // URL reale (non un'etichetta simbolica): TMVCStaticFilesMiddleware serve
  // ExportFolder su /export (vedi uWebModule.pas), quindi questo link
  // funziona per davvero in un browser o in qualunque client che lo mostri.
  // TMCPToolResult.Text (non .Resource/.ResourceBlob): il contenuto non e'
  // piu' embedded, quindi non c'e' nulla da incorporare come risorsa - solo
  // un messaggio testuale con l'URL, che qualunque client MCP puo' riportare
  // in chat cosi' com'e' (vedi nota in testa alla unit sul perche' di questa
  // scelta rispetto alla prima versione con Resource/ResourceBlob).
  LUrlDownload := TConfig.GetInstance.BaseUrl + '/export/' + LNomeFile;
  Result := TMCPToolResult.Text(Format(
    'File generato con successo: %s'#10'Link per il download: %s',
    [LNomeFile, LUrlDownload]));
end;

// ---------------------------------------------------------------------------
// CONTRATTI DEI TOOL DI QUESTO PROVIDER (tappa 2 del porting del pianificatore,
// vedi agente_ai/tool/uContrattiTool.pas). Portati da mcp_delphi.py del prototipo:
// DEFINIZIONI (output_schema, effetto, conferma), INTEGRAZIONI_INPUT (vincoli
// sugli input) e ALMENO_UNO. Gli schemi di output descrivono le risposte
// costruite piu' sopra in questa unit: se cambia una risposta, va cambiato
// anche il suo schema qui sotto. Il test scripts/prototipo_pianificatore/tests/
// test_contratti_delphi.py li confronta con quelli del prototipo.
// ---------------------------------------------------------------------------

const
  SCHEMA_OUTPUT_GENERATE_CSV =
    '{"type":"object","properties":{"messaggio":{"type":"string"}},"required":["messaggio"]}';

  SCHEMA_OUTPUT_GENERATE_PDF =
    '{"type":"object","properties":{"messaggio":{"type":"string"}},"required":["messaggio"]}';

class function TFilesToolsProvider.ContrattiTool: TArray<TContrattoTool>;
begin
  Result := TArray<TContrattoTool>.Create(
    ContrattoTool('generate_csv', etLettura, False,
      SCHEMA_OUTPUT_GENERATE_CSV),
    ContrattoTool('generate_pdf', etLettura, False,
      SCHEMA_OUTPUT_GENERATE_PDF));
end;

end.
