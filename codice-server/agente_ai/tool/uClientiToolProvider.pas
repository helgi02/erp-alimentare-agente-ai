unit uClientiToolProvider;

(* ============================================================================
  TClientiToolProvider - tool MCP get_cliente: restituisce l'anagrafica di UN
  cliente (tabella clienti), cercato per id, per partita IVA oppure per
  ragione sociale.

  -- Un solo tool con tre parametri opzionali --------------------------------
  Principio "tool generico e parametrico" del documento di progetto: non tre
  tool (get_cliente_by_id, ..._by_partita_iva, ..._by_ragione_sociale) ma uno
  solo, con tre chiavi di ricerca facoltative di cui ne serve almeno una.
  Meno tool nel catalogo = meno possibilita' che un modello piccolo scelga
  quello sbagliato.

  Se arrivano piu' chiavi insieme vince la piu' precisa:
      id  >  partita IVA  >  ragione sociale
  (id e partita IVA sono univoche - PRIMARY KEY e UNIQUE nel DDL - mentre la
  ragione sociale puo' essere parziale e corrispondere a piu' clienti).

  -- Perche' e' un provider RTTI (come TVenditeToolProvider) -----------------
  I tre parametri sono stringhe semplici: bastano [MCPTool]/[MCPParam] e lo
  schema JSON lo genera la libreria. I provider "dinamici" (ricette, file...)
  servono solo quando un parametro e' un array o un oggetto. Come per
  get_list_vendite, i nomi dei parametri visti dal modello sono quelli Pascal
  (AClienteId, ARagioneSocialeCliente, APartitaIva): i primi due sono
  volutamente GLI STESSI di get_list_vendite, cosi' il modello ritrova lo
  stesso nome per lo stesso concetto.

  -- Nessuna logica di dominio qui -------------------------------------------
  Il provider e' solo un adattatore fra il protocollo MCP e codice che esiste
  gia':
    - TCliente.GetByID / GetByPartitaIva   (models/uModelCliente.pas)
    - TServizioVendite.RisolviCliente      (services/uServiziVendite.pas):
      match esatto sulla ragione sociale, poi parziale - la stessa risoluzione
      usata da get_list_vendite, quindi lo stesso nome da' lo stesso cliente
      in entrambi i tool.

  -- Le tre risposte possibili -----------------------------------------------
    1. {"esito":"ok","cliente":{...}}       trovato un solo cliente;
    2. {"esito":"richiede_disambiguazione","problemi":[...]}
                                            ragione sociale ambigua o non
                                            trovata: stessa forma di
                                            get_list_vendite (campo
                                            "ragione_sociale_cliente"), quindi
                                            l'esecutore del piano e i pulsanti
                                            di scelta in chat.js funzionano
                                            senza modifiche;
    3. errore del tool (TMCPToolResult.Error)
                                            nessuna chiave di ricerca, partita
                                            IVA malformata, id o partita IVA
                                            inesistenti.
  ============================================================================ *)

interface

uses
  System.SysUtils,
  System.JSON,
  MVCFramework.MCP.ToolProvider,
  MVCFramework.MCP.Attributes,
  uContrattiTool,
  uModelCliente,
  uServiziVendite;

type
  TClientiToolProvider = class(TMCPToolProvider)
  public
    [MCPTool('get_cliente',
      'Restituisce i dati anagrafici di UN cliente: ragione sociale, partita IVA, email, ' +
      'telefono, indirizzo di fatturazione e indirizzo di consegna. Il cliente si indica con ' +
      'UNO fra AClienteId, APartitaIva e ARagioneSocialeCliente (ne serve almeno uno; se sono ' +
      'piu'' di uno vale il primo in quest''ordine). Se ARagioneSocialeCliente corrisponde a ' +
      'piu'' clienti o a nessuno, restituisce i candidati con i relativi id invece dei dati. ' +
      'NON restituisce ordini o vendite del cliente: per quelli usa get_list_vendite.')]
    function GetCliente(
      [MCPParam('ID numerico esatto del cliente (numero intero). NON e'' la ragione sociale ne'' la partita IVA.',
        TMCPParamPresence.Optional)]
        const AClienteId: string;
      [MCPParam('Ragione sociale del cliente, anche parziale.', TMCPParamPresence.Optional)]
        const ARagioneSocialeCliente: string;
      [MCPParam('Partita IVA del cliente: 11 cifre, senza spazi.', TMCPParamPresence.Optional)]
        const APartitaIva: string
    ): TMCPToolResult;
    // Contratto del tool per il pianificatore (vedi agente_ai/tool/
    // uContrattiTool.pas e la sezione in fondo a questa unit).
    class function ContrattiTool: TArray<TContrattoTool>;
  end;

implementation

const
  // Partita IVA italiana: 11 cifre (vedi COMMENT ON COLUMN clienti.partita_iva
  // e VARCHAR(11) nel DDL).
  LUNGHEZZA_PARTITA_IVA = 11;

{ Funzioni di supporto, private all'unit }

// Toglie quello che un utente (o il modello) aggiunge spesso a una partita
// IVA senza cambiarne il significato: spazi e il prefisso paese "IT".
// "IT 012 345 678 90" -> "01234567890". Non controlla che il risultato sia
// valido: per quello c'e' SembraPartitaIva.
function NormalizzaPartitaIva(const AValore: string): string;
begin
  Result := UpperCase(StringReplace(Trim(AValore), ' ', '', [rfReplaceAll]));
  if Result.StartsWith('IT') then
    Result := Result.Substring(2);
end;

// True se AValore e' fatto di esattamente 11 cifre. Controllo di FORMA, non
// della cifra di controllo: qui serve solo a distinguere una partita IVA da
// un id o da una ragione sociale.
function SembraPartitaIva(const AValore: string): Boolean;
var
  LCarattere: Char;
begin
  if Length(AValore) <> LUNGHEZZA_PARTITA_IVA then
    Exit(False);
  for LCarattere in AValore do
    if not CharInSet(LCarattere, ['0'..'9']) then
      Exit(False);
  Result := True;
end;

// Risposta "ok": l'anagrafica completa, cosi' come la produce gia'
// TCliente.ToJSONObject per le API REST del gestionale (stessi nomi di campo
// del database). Se ToJSONObject cambia, va aggiornato SCHEMA_OUTPUT_GET_CLIENTE
// in fondo a questa unit.
function CostruisciRispostaOk(ACliente: TCliente): string;
var
  LRoot: TJSONObject;
begin
  LRoot := TJSONObject.Create;
  try
    LRoot.AddPair('esito', 'ok');
    LRoot.AddPair('cliente', ACliente.ToJSONObject);
    Result := LRoot.ToJSON;
  finally
    LRoot.Free;
  end;
end;

// Risposta "richiede_disambiguazione" per una ragione sociale ambigua o non
// trovata. Stessa forma costruita da uVenditeToolProvider (un solo problema,
// campo "ragione_sociale_cliente", candidati con id/ragione_sociale/
// partita_iva). ARisoluzione resta del chiamante.
function CostruisciRispostaDisambiguazione(ARisoluzione: TRisoluzioneCliente): string;
var
  LRoot, LProblema, LCandidatoObj: TJSONObject;
  LProblemi, LCandidati: TJSONArray;
  LCandidato: TCandidatoCliente;
begin
  LRoot := TJSONObject.Create;
  try
    LRoot.AddPair('esito', 'richiede_disambiguazione');
    LProblemi := TJSONArray.Create;
    LRoot.AddPair('problemi', LProblemi);

    LProblema := TJSONObject.Create;
    LProblemi.AddElement(LProblema);
    LProblema.AddPair('campo', 'ragione_sociale_cliente');
    LProblema.AddPair('valore_cercato', ARisoluzione.ValoreCercato);
    if ARisoluzione.Esito = erAmbiguo then
      LProblema.AddPair('tipo', 'ambiguo')
    else
      LProblema.AddPair('tipo', 'non_trovato');

    LCandidati := TJSONArray.Create;
    LProblema.AddPair('candidati', LCandidati);
    for LCandidato in ARisoluzione.Candidati do
    begin
      LCandidatoObj := TJSONObject.Create;
      LCandidatoObj.AddPair('id', TJSONNumber.Create(LCandidato.ID));
      LCandidatoObj.AddPair('ragione_sociale', LCandidato.RagioneSociale);
      LCandidatoObj.AddPair('partita_iva', LCandidato.PartitaIva);
      LCandidati.AddElement(LCandidatoObj);
    end;

    Result := LRoot.ToJSON;
  finally
    LRoot.Free;
  end;
end;

{ TClientiToolProvider }

function TClientiToolProvider.GetCliente(const AClienteId, ARagioneSocialeCliente,
  APartitaIva: string): TMCPToolResult;
var
  LIdTxt, LNome, LPartitaIva: string;
  LId: Integer;
  LCliente: TCliente;
  LRisoluzione: TRisoluzioneCliente;
begin
  // Copie locali: i parametri sono const e qui sotto possono cambiare posto.
  LIdTxt := Trim(AClienteId);
  LNome := Trim(ARagioneSocialeCliente);
  LPartitaIva := NormalizzaPartitaIva(APartitaIva);

  // TOLLERANZA sul parametro sbagliato. Con i modelli locali l'errore piu'
  // frequente non e' il valore ma la CASELLA in cui viene messo (vedi
  // NormalizzaIdOTesto in uVenditeToolProvider). Invece di rifiutare la
  // chiamata, il valore viene spostato dove ha senso:
  //  - 11 cifre in AClienteId o in ARagioneSocialeCliente sono una partita
  //    IVA (un id di 11 cifre non puo' esistere: la colonna e' SERIAL, al
  //    massimo 10 cifre);
  //  - un "id" che non e' un intero positivo e' una ragione sociale.
  if (LPartitaIva = '') and SembraPartitaIva(NormalizzaPartitaIva(LIdTxt)) then
  begin
    LPartitaIva := NormalizzaPartitaIva(LIdTxt);
    LIdTxt := '';
  end;
  if (LPartitaIva = '') and SembraPartitaIva(NormalizzaPartitaIva(LNome)) then
  begin
    LPartitaIva := NormalizzaPartitaIva(LNome);
    LNome := '';
  end;
  LId := 0;
  if (LIdTxt <> '') and not (TryStrToInt(LIdTxt, LId) and (LId > 0)) then
  begin
    if LNome = '' then
      LNome := LIdTxt;
    LId := 0;
  end;

  // Ricerca, dalla chiave piu' precisa alla meno precisa.
  if LId > 0 then
  begin
    LCliente := TCliente.GetByID(LId);
    if LCliente = nil then
      Exit(TMCPToolResult.Error(Format('Nessun cliente con id %d.', [LId])));
  end
  else if LPartitaIva <> '' then
  begin
    // Controllo di forma PRIMA della query: "partita IVA scritta male" e
    // "partita IVA che non e' di nessun cliente" sono due risposte diverse.
    if not SembraPartitaIva(LPartitaIva) then
      Exit(TMCPToolResult.Error(Format(
        'Partita IVA "%s" non valida: deve essere di %d cifre.',
        [APartitaIva, LUNGHEZZA_PARTITA_IVA])));
    LCliente := TCliente.GetByPartitaIva(LPartitaIva);
    if LCliente = nil then
      Exit(TMCPToolResult.Error(Format('Nessun cliente con partita IVA %s.', [LPartitaIva])));
  end
  else if LNome <> '' then
  begin
    LRisoluzione := TServizioVendite.RisolviCliente(LNome);
    try
      // Piu' clienti o nessuno: decide l'utente, non il tool.
      if LRisoluzione.Esito <> erRisolto then
        Exit(TMCPToolResult.Text(CostruisciRispostaDisambiguazione(LRisoluzione)));
      // RisolviCliente porta solo id, ragione sociale e partita IVA:
      // l'anagrafica completa si rilegge per id.
      LCliente := TCliente.GetByID(LRisoluzione.ClienteID);
    finally
      LRisoluzione.Free;
    end;
    if LCliente = nil then
      Exit(TMCPToolResult.Error(Format('Cliente "%s" non piu'' presente in anagrafica.', [LNome])));
  end
  else
    Exit(TMCPToolResult.Error(
      'Serve almeno uno fra AClienteId, APartitaIva e ARagioneSocialeCliente.'));

  try
    Result := TMCPToolResult.Text(CostruisciRispostaOk(LCliente));
  finally
    LCliente.Free;
  end;
end;

// ---------------------------------------------------------------------------
// CONTRATTO DEL TOOL (vedi agente_ai/tool/uContrattiTool.pas). Lo schema di
// output descrive la risposta "ok" costruita piu' sopra: "cliente" ha
// esattamente i campi di TCliente.ToJSONObject (lo schema non ammette campi
// in piu'). I campi facoltativi nel database (telefono, indirizzi) arrivano
// come stringa vuota, mai null, quindi sono tutti "required".
// "id" e' integer: un piano puo' passarlo a un parametro stringa come
// AClienteId di get_list_vendite ("$1.cliente.id"), l'assegnazione
// integer -> string e' ammessa dal validatore.
// ---------------------------------------------------------------------------

const
  SCHEMA_OUTPUT_GET_CLIENTE =
    '{"type":"object","properties":{"esito":{"type":"string","enum":["ok"]},' +
    '"cliente":{"type":"object","properties":{"id":{"type":"integer"},' +
    '"ragione_sociale":{"type":"string"},"partita_iva":{"type":"string"},' +
    '"email":{"type":"string"},"telefono":{"type":"string"},' +
    '"via_fatturazione":{"type":"string"},"citta_fatturazione":{"type":"string"},' +
    '"provincia_fatturazione":{"type":"string"},"cap_fatturazione":{"type":"string"},' +
    '"paese_fatturazione":{"type":"string"},"via_consegna":{"type":"string"},' +
    '"citta_consegna":{"type":"string"},"provincia_consegna":{"type":"string"},' +
    '"cap_consegna":{"type":"string"},"paese_consegna":{"type":"string"},' +
    '"creato_il":{"type":"string"},"aggiornato_il":{"type":"string"}},' +
    '"required":["id","ragione_sociale","partita_iva","email","telefono",' +
    '"via_fatturazione","citta_fatturazione","provincia_fatturazione",' +
    '"cap_fatturazione","paese_fatturazione","via_consegna","citta_consegna",' +
    '"provincia_consegna","cap_consegna","paese_consegna","creato_il",' +
    '"aggiornato_il"]}},"required":["esito","cliente"]}';

class function TClientiToolProvider.ContrattiTool: TArray<TContrattoTool>;
begin
  // Lettura, nessuna conferma. Unico vincolo che lo schema del server non
  // esprime: serve almeno una delle tre chiavi di ricerca.
  Result := TArray<TContrattoTool>.Create(
    ContrattoTool('get_cliente', etLettura, False,
      SCHEMA_OUTPUT_GET_CLIENTE,
      nil,
      TArray<TArray<string>>.Create(
        TArray<string>.Create('AClienteId', 'APartitaIva', 'ARagioneSocialeCliente'))));
end;

end.
