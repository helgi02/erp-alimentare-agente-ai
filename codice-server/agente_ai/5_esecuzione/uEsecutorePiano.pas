unit uEsecutorePiano;

// Esecutore del piano. Esegue i passi di un piano gia' validato, in ordine, senza chiamare
// il modello. Per ogni passo: (1) risolve i riferimenti "$N.campo" con i risultati veri dei
// passi precedenti e ricontrolla gli argomenti contro lo schema di input; (2) se il tool
// SCRIVE e richiede conferma, parte solo se l'utente ha confermato, altrimenti il piano si
// ferma (CONFERMA_RICHIESTA); (3) esegue il tool (TMCPBridge.EseguiTool); (4) classifica il
// risultato: errore, richiesta di disambiguazione o risultato valido (conforme
// all'output_schema). Al primo arresto i passi successivi non si eseguono.
// Codici di arresto: RIF_... (riferimento non risolto; RIF_VUOTO = nessun elemento, esito
// normale), CONFERMA_RICHIESTA, ERRORE_TOOL, DISAMBIGUAZIONE (il tool chiede di scegliere
// fra candidati), OUTPUT_NON_CONFORME.
// EseguiProssimoPasso esegue UN passo e torna: il turno a passi lo chiama una volta per
// richiesta del client, cosi' la chat mostra ogni tool man mano. EseguiTutto e' il ciclo
// completo.

interface

uses
  System.SysUtils,
  System.JSON,
  System.Generics.Collections,
  uPianificatore;

const
  ESECUZIONE_IN_CORSO = 'in_corso';
  ESECUZIONE_COMPLETATA = 'completata';
  ESECUZIONE_FERMATA = 'fermata';
  ESECUZIONE_NON_ESEGUITA = 'non_eseguita';

type
  TEsitoPasso = class
  public
    Id: Integer;
    Tool: string;
    // Argomenti con i riferimenti gia' sostituiti; nil se la risoluzione e'
    // fallita. Di proprieta' dell'esito.
    ArgomentiRisolti: TJSONObject;
    // 'ok' oppure un codice di arresto.
    Esito: string;
    // Risultato del tool (anche per errore e disambiguazione); nil se il tool
    // non e' stato chiamato. Di proprieta' dell'esito.
    Output: TJSONObject;
    Dettaglio: string;
    DurataMs: Int64;
    destructor Destroy; override;
  end;

  TEsitoEsecuzione = class
  public
    Stato: string;
    Esiti: TObjectList<TEsitoPasso>;
    CodiceArresto: string;
    PassoArresto: Integer;
    Dettaglio: string;
    constructor Create;
    destructor Destroy; override;
    // "fermata:<codice>" oppure lo stato.
    function Etichetta: string;
  end;

  TEsecutorePiano = class
  private
    FPiano: TPiano;
    FEsito: TEsitoEsecuzione;
    FProssimo: Integer;                            // indice in FPiano.Passi
    FOutputOk: TDictionary<Integer, TJSONObject>;  // id del passo -> output (di FEsito)
    FOutputRipresi: TObjectList<TJSONObject>;      // output di una esecuzione precedente (ripresa)
    procedure Ferma(AEsito: TEsitoPasso);
  public
    // Tool di SCRITTURA che l'utente ha confermato per questo piano ('' =
    // nessuno). Una scrittura che richiede conferma parte solo se il suo
    // tool e' questo; altrimenti il piano si ferma con CONFERMA_RICHIESTA.
    ToolConfermato: string;

    // APiano resta del chiamante e deve vivere quanto l'esecutore.
    constructor Create(APiano: TPiano);
    destructor Destroy; override;

    // RIPRESA dopo una conferma: un piano fermo su una scrittura non si riesegue
    // dall'inizio (i passi gia' fatti potrebbero essere scritture). Si riparte dal passo
    // AIndicePasso (indice in Piano.Passi, da 0) con i risultati che i passi precedenti
    // avevano prodotto allora (AOutputPrecedenti: {"<id passo>": <output>}, del chiamante),
    // cosi' i riferimenti danno gli stessi valori mostrati all'utente. Va chiamata prima di
    // eseguire.
    procedure RiprendiDa(AIndicePasso: Integer; AOutputPrecedenti: TJSONObject);
    // I risultati dei passi riusciti, compresi quelli ripresi:
    // {"<id passo>": <output>}. Copia, del chiamante.
    function OutputRiusciti: TJSONObject;

    // True quando non c'e' altro da eseguire (completata o fermata).
    function Concluso: Boolean;
    // Esegue il prossimo passo. Non fa nulla se Concluso.
    procedure EseguiProssimoPasso;
    // Tutti i passi fino alla fine o al primo arresto.
    procedure EseguiTutto;

    // Di proprieta' dell'esecutore.
    property Esito: TEsitoEsecuzione read FEsito;
    // Cede l'esito al chiamante (che lo libera). Dopo, l'esecutore non va
    // piu' usato.
    function EstraiEsito: TEsitoEsecuzione;
  end;

// Esegue un tool e porta il risultato nella forma comune:
//   {"errore": {"messaggio": "..."}}            il tool ha risposto con un errore
//   {"richiede_disambiguazione": [problemi]}    serve una scelta dell'utente
//   {"messaggio": "..."}                        risposta non JSON (es. il link
//                                               di generate_csv / generate_pdf)
//   <oggetto>                                   il risultato del tool
// Il risultato e' del chiamante.
function EseguiToolAdattato(const ANomeTool: string; AArgomenti: TJSONObject): TJSONObject;

implementation

uses
  System.Diagnostics,
  uSchemaJSON,
  uRiferimentiPiano,
  uContrattiTool,
  uMCPBridge;

function EseguiToolAdattato(const ANomeTool: string; AArgomenti: TJSONObject): TJSONObject;
var
  LTesto, LMessaggio: string;
  LValore, LErrore, LProblemi: TJSONValue;
begin
  // TMCPBridge.EseguiTool non solleva eccezioni: un errore del tool, del
  // server MCP o dei parametri torna come {"errore": "...", "tool": "..."}.
  LTesto := TMCPBridge.EseguiTool(ANomeTool, AArgomenti);
  LValore := TJSONObject.ParseJSONValue(LTesto);

  if not (LValore is TJSONObject) then
  begin
    // Testo libero: diventa un oggetto con un solo campo.
    LValore.Free;
    Exit(TJSONObject.Create.AddPair('messaggio', LTesto));
  end;

  try
    LErrore := TJSONObject(LValore).GetValue('errore');
    if LErrore <> nil then
    begin
      if LErrore is TJSONObject then
        LMessaggio := TestoCampo(TJSONObject(LErrore), 'messaggio')
      else
        LMessaggio := LErrore.Value;
      Exit(TJSONObject.Create.AddPair('errore',
        TJSONObject.Create.AddPair('messaggio', LMessaggio)));
    end;

    if TestoCampo(TJSONObject(LValore), 'esito') = 'richiede_disambiguazione' then
    begin
      LProblemi := TJSONObject(LValore).GetValue('problemi');
      if LProblemi <> nil then
        Exit(TJSONObject.Create.AddPair('richiede_disambiguazione', LProblemi.Clone as TJSONValue));
      Exit(TJSONObject.Create.AddPair('richiede_disambiguazione', TJSONArray.Create));
    end;

    Result := TJSONObject(LValore);
    LValore := nil;       // ceduto al chiamante
  finally
    LValore.Free;
  end;
end;

destructor TEsitoPasso.Destroy;
begin
  ArgomentiRisolti.Free;
  Output.Free;
  inherited;
end;

constructor TEsitoEsecuzione.Create;
begin
  inherited;
  Esiti := TObjectList<TEsitoPasso>.Create(True);
  Stato := ESECUZIONE_NON_ESEGUITA;
end;

destructor TEsitoEsecuzione.Destroy;
begin
  Esiti.Free;
  inherited;
end;

function TEsitoEsecuzione.Etichetta: string;
begin
  if Stato = ESECUZIONE_FERMATA then
    Result := 'fermata:' + CodiceArresto
  else
    Result := Stato;
end;

constructor TEsecutorePiano.Create(APiano: TPiano);
begin
  inherited Create;
  FPiano := APiano;
  FEsito := TEsitoEsecuzione.Create;
  FOutputOk := TDictionary<Integer, TJSONObject>.Create;
  FOutputRipresi := TObjectList<TJSONObject>.Create(True);
  FProssimo := 0;
  if FPiano.Passi.Count = 0 then
    FEsito.Stato := ESECUZIONE_COMPLETATA
  else
    FEsito.Stato := ESECUZIONE_IN_CORSO;
end;

destructor TEsecutorePiano.Destroy;
begin
  FOutputOk.Free;
  FOutputRipresi.Free;
  FEsito.Free;
  inherited;
end;

procedure TEsecutorePiano.RiprendiDa(AIndicePasso: Integer; AOutputPrecedenti: TJSONObject);
var
  LCoppia: TJSONPair;
  LCopia: TJSONObject;
  LId: Integer;
begin
  if AOutputPrecedenti <> nil then
    for LCoppia in AOutputPrecedenti do
      if TryStrToInt(LCoppia.JsonString.Value, LId) and (LCoppia.JsonValue is TJSONObject) then
      begin
        LCopia := LCoppia.JsonValue.Clone as TJSONObject;
        FOutputRipresi.Add(LCopia);
        FOutputOk.AddOrSetValue(LId, LCopia);
      end;
  if (AIndicePasso >= 0) and (AIndicePasso < FPiano.Passi.Count) then
    FProssimo := AIndicePasso;
end;

function TEsecutorePiano.OutputRiusciti: TJSONObject;
var
  LCoppia: TPair<Integer, TJSONObject>;
begin
  Result := TJSONObject.Create;
  for LCoppia in FOutputOk do
    Result.AddPair(IntToStr(LCoppia.Key), LCoppia.Value.Clone as TJSONValue);
end;

function TEsecutorePiano.Concluso: Boolean;
begin
  Result := (FEsito = nil) or (FEsito.Stato <> ESECUZIONE_IN_CORSO);
end;

function TEsecutorePiano.EstraiEsito: TEsitoEsecuzione;
begin
  Result := FEsito;
  FEsito := nil;
  // Gli output del dizionario appartenevano all'esito: non vanno piu' usati.
  FOutputOk.Clear;
end;

procedure TEsecutorePiano.Ferma(AEsito: TEsitoPasso);
begin
  FEsito.Stato := ESECUZIONE_FERMATA;
  FEsito.CodiceArresto := AEsito.Esito;
  FEsito.PassoArresto := AEsito.Id;
  FEsito.Dettaglio := AEsito.Dettaglio;
end;

procedure TEsecutorePiano.EseguiProssimoPasso;
var
  LPasso: TPasso;
  LEsitoPasso: TEsitoPasso;
  LContratto: TContrattoTool;
  LSchemaInput, LSchemaOutput: TJSONObject;
  LCronometro: TStopwatch;
  LErrori: TArray<string>;
  LErrore: TJSONValue;
begin
  if Concluso then
    Exit;

  LPasso := FPiano.Passi[FProssimo];
  LEsitoPasso := TEsitoPasso.Create;
  FEsito.Esiti.Add(LEsitoPasso);
  LEsitoPasso.Id := LPasso.Id;
  LEsitoPasso.Tool := LPasso.Tool;

  // 1. Riferimenti -> valori veri, poi controllo contro lo schema di input.
  LSchemaInput := TPianificatore.SchemaInputTool(LPasso.Tool);
  try
    try
      LEsitoPasso.ArgomentiRisolti := RisolviArgomenti(LPasso.Argomenti, FOutputOk, LSchemaInput);
    except
      on E: ERiferimento do
      begin
        LEsitoPasso.Esito := E.Codice;
        LEsitoPasso.Dettaglio := E.Messaggio;
        Ferma(LEsitoPasso);
        Exit;
      end;
    end;
  finally
    LSchemaInput.Free;
  end;

  // 2. Una scrittura parte solo se l'utente l'ha confermata.
  if TRegistroContrattiTool.Trova(LPasso.Tool, LContratto) and
     (LContratto.Effetto = etScrittura) and LContratto.RichiedeConferma and
     not SameText(ToolConfermato, LPasso.Tool) then
  begin
    LEsitoPasso.Esito := 'CONFERMA_RICHIESTA';
    LEsitoPasso.Dettaglio := 'scrittura proposta, in attesa di conferma dell''utente';
    Ferma(LEsitoPasso);
    Exit;
  end;

  // 3. Esecuzione.
  LCronometro := TStopwatch.StartNew;
  LEsitoPasso.Output := EseguiToolAdattato(LPasso.Tool, LEsitoPasso.ArgomentiRisolti);
  LCronometro.Stop;
  LEsitoPasso.DurataMs := LCronometro.ElapsedMilliseconds;

  // 4. Classificazione del risultato.
  LErrore := LEsitoPasso.Output.GetValue('errore');
  if LErrore <> nil then
  begin
    LEsitoPasso.Esito := 'ERRORE_TOOL';
    if LErrore is TJSONObject then
      LEsitoPasso.Dettaglio := TestoCampo(TJSONObject(LErrore), 'messaggio');
    Ferma(LEsitoPasso);
    Exit;
  end;
  if LEsitoPasso.Output.GetValue('richiede_disambiguazione') <> nil then
  begin
    LEsitoPasso.Esito := 'DISAMBIGUAZIONE';
    LEsitoPasso.Dettaglio := 'serve una scelta dell''utente';
    Ferma(LEsitoPasso);
    Exit;
  end;

  LSchemaOutput := TPianificatore.SchemaOutputTool(LPasso.Tool);
  try
    LErrori := ValidaSchema(LEsitoPasso.Output, LSchemaOutput);
  finally
    LSchemaOutput.Free;
  end;
  if Length(LErrori) > 0 then
  begin
    LEsitoPasso.Esito := 'OUTPUT_NON_CONFORME';
    LEsitoPasso.Dettaglio := string.Join('; ', LErrori);
    Ferma(LEsitoPasso);
    Exit;
  end;

  LEsitoPasso.Esito := 'ok';
  // Da qui i passi successivi possono riferirsi a questo risultato.
  FOutputOk.AddOrSetValue(LPasso.Id, LEsitoPasso.Output);

  Inc(FProssimo);
  if FProssimo >= FPiano.Passi.Count then
    FEsito.Stato := ESECUZIONE_COMPLETATA;
end;

procedure TEsecutorePiano.EseguiTutto;
begin
  while not Concluso do
    EseguiProssimoPasso;
end;

end.
