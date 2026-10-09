unit uFilesToolsProvider;

// Tool MCP generici per generare file (CSV, PDF) da dati forniti dal modello, non dal DB.
// Provider dinamico: i parametri "colonne" e "righe" devono essere array veri, e la via
// RTTI supporta solo parametri scalari. GetDynamicToolDefs dichiara a mano i tool
// (JsonSchemaType := 'array' dove serve); InvokeDynamic riceve gli argomenti JSON cosi'
// come arrivano, senza marshalling.
// Flusso: il modello ottiene le righe da un tool dati e le passa a
// generate_csv/generate_pdf con le colonne ({"campo","intestazione"}). Il tool scrive il
// file in TConfig.ExportFolder e risponde con un URL di download, servito da
// TMVCStaticFilesMiddleware (uWebModule.pas).
// Perche' un URL e non il contenuto nel tool_result (Resource/ResourceBlob): LM Studio
// mostra il risultato solo come JSON grezzo, senza renderizzare l'allegato, e l'utente non
// poteva scaricare il file. Un URL e' testo semplice e qualunque client puo' riportarlo.
// Limiti noti: i file in ExportFolder non vengono ripuliti (in produzione servirebbe un job
// di pulizia); /export non richiede autenticazione, accettabile per infrastruttura locale
// ma da rivedere se il server uscisse dalla rete fidata.
// La costruzione di CSV/PDF e' in TEsportazioneCSV/TEsportazionePDF, con T =
// TJDOJsonObject: qui si leggono "colonne"/"righe" e si scrive il file con un nome univoco
// e sicuro (CostruisciNomeFileUnico).

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
    // Contratti dei tool per il pianificatore (vedi uContrattiTool.pas e il fondo di questa
    // unit).
    class function ContrattiTool: TArray<TContrattoTool>;
  end;

implementation

type
  // Voce di "colonne": Campo e' la chiave da leggere in ogni riga, Intestazione il titolo
  // di colonna (uguale a Campo se omessa).
  TDefinizioneColonna = record
    Campo: string;
    Intestazione: string;
  end;

// Legge ACampo da ARiga come stringa stampabile (CSV e PDF passano da qui). TJsonObject.S[]
// fa gia' l'auto-cast tranne per array/object, dove darebbe una stringa vuota che
// nasconderebbe il dato: li' si ripiega sul JSON compatto.
// Se il valore e' una data o data-ora ISO 8601 ("2026-08-01T00:00:00.000Z", "2026-08-01")
// la riformatta in gg/mm/aaaa, con l'orario solo se diverso da mezzanotte (e' quasi sempre
// una colonna DATE con orario fittizio). Altrimenti restituisce il valore invariato:
// riconosce la forma, non il significato del campo.
function FormattaSeData(const AValore: string): string;
const
  // Due pattern separati (con orario / solo data) invece di uno con la parte orario
  // opzionale. Con un gruppo opzionale non partecipante, Groups[4] solleva
  // ERegularExpressionError invece di restituire un gruppo vuoto; l'eccezione veniva
  // inghiottita dall'except Exit e le date senza orario restavano in aaaa-mm-gg. Qui tutti
  // i gruppi di ogni pattern sono obbligatori.
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

// ACampo e' un parametro, non la variabile del ciclo chiamante, di proposito: in un for
// ogni closure catturerebbe la stessa variabile e tutte leggerebbero l'ultimo campo. Il
// parametro da' a ciascuna la propria copia.
function CreaEstrattoreCampo(const ACampo: string): TFunc<TJDOJsonObject, string>;
begin
  Result :=
    function(ARiga: TJDOJsonObject): string
    begin
      Result := LeggiCellaComeStringa(ARiga, ACampo);
    end;
end;

// Legge "colonne": array non vuoto di {"campo", "intestazione" (opzionale)}. Su qualunque
// forma imprevista solleva un'eccezione con messaggio per il modello, che InvokeDynamic
// trasforma in errore del tool: il modello puo' correggere la chiamata.
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
      // Senza intestazione: il nome del campo (meglio tecnico che nessuna intestazione).
      Result[I].Intestazione := Result[I].Campo;
  end;
end;

// Legge "righe": array non vuoto di oggetti. Sono riferimenti dentro AArguments, di
// proprieta' del framework: non vanno liberati.
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

// Colonne generiche -> formato del motore CSV condiviso.
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

// Come sopra, per il motore PDF.
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

// Nome richiesto dal modello ("nome_file"), o ADefault se vuoto. Non validato qui: va
// ripulito da CostruisciNomeFileUnico.
function NomeFileRichiesto(AArguments: TJDOJsonObject; const ADefault: string): string;
begin
  if AArguments.Contains('nome_file') and (Trim(AArguments.S['nome_file']) <> '') then
    Result := Trim(AArguments.S['nome_file'])
  else
    Result := ADefault;
end;

// Nome file sicuro e univoco per ExportFolder. Il nome arriva dal modello, quindi non e'
// fidato: GetFileNameWithoutExtension scarta i componenti di percorso e il filtro tiene
// solo lettere, cifre, underscore e trattino, quindi niente path traversal. Il prefisso
// timestamp con millisecondi evita che due export ravvicinati si sovrascrivano.
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

function TFilesToolsProvider.GetDynamicToolDefs: TArray<TMCPDynamicToolDef>;

  // Helper per non ripetere l'assegnazione campo per campo.
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

  // Prima il testo diceva "copia le righe cosi' come le hai ricevute": a un seguito come
  // "esportalo in csv" il modello ricopiava le righe dallo storico, che riporta solo le
  // prime 3 di ogni elenco (uStoricoTurni, MaxElementi), e inventava gli id
  // (VALORE_NON_ANCORATO). Meglio rileggere i dati e passarli per riferimento: il modello
  // non riscrive righe.
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

  // "colonne" e "righe" sono comuni ai due tool: lette qui prima di smistare.
  try
    LDefinizioni := LeggiDefinizioniColonne(AArguments);
    LRighe := LeggiRighe(AArguments);
  except
    on E: Exception do
      // Formato errato imputabile al modello: .Error, non un'eccezione, cosi' puo'
      // correggere la chiamata.
      Exit(TMCPToolResult.Error(E.Message));
  end;

  try
    if SameText(AToolName, 'generate_csv') then
    begin
      LNomeFile := CostruisciNomeFileUnico(NomeFileRichiesto(AArguments, 'export'), 'csv');
      LPercorsoFile := TPath.Combine(TConfig.GetInstance.ExportFolder, LNomeFile);

      // Con BOM: senza, Excel puo' leggere male gli accenti.
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
      // Non dovrebbe succedere (si dispatchano solo i nomi di GetDynamicToolDefs), ma
      // meglio un fallback esplicito.
      Exit(TMCPToolResult.Error(Format(
        '"%s" non e'' un tool gestito da questo provider.', [AToolName])));
  except
    on E: Exception do
      // Errore di scrittura (permessi, spazio, cartella rimossa): non e' colpa del modello,
      // ma va restituito come .Error e non propagato come errore di trasporto generico.
      Exit(TMCPToolResult.Error('Impossibile generare il file: ' + E.Message));
  end;

  // URL reale: TMVCStaticFilesMiddleware serve ExportFolder su /export (uWebModule.pas).
  // Solo testo (.Text), senza Resource: vedi la nota in testa.
  LUrlDownload := TConfig.GetInstance.BaseUrl + '/export/' + LNomeFile;
  Result := TMCPToolResult.Text(Format(
    'File generato con successo: %s'#10'Link per il download: %s',
    [LNomeFile, LUrlDownload]));
end;

// Contratti (vedi uContrattiTool.pas). Gli schemi di output descrivono le risposte
// costruite sopra: se cambia una risposta, va cambiato anche lo schema.

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
