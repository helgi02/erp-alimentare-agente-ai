unit uClientiToolProvider;

// Tool MCP get_cliente: anagrafica di un cliente, cercato per id, partita IVA o ragione
// sociale.
// Un solo tool con tre chiavi facoltative (ne serve almeno una): meno tool nel catalogo,
// meno errori di scelta del modello. Se ne arrivano piu' vince la piu' precisa: id >
// partita IVA > ragione sociale (le prime due sono univoche, la terza puo' essere
// parziale).
// Provider RTTI: i parametri sono stringhe semplici, lo schema lo genera la libreria.
// AClienteId e ARagioneSocialeCliente hanno lo stesso nome di get_list_vendite, cosi' il
// modello ritrova lo stesso nome per lo stesso concetto.
// Nessuna logica di dominio: usa TCliente.GetByID/GetByPartitaIva e
// TServizioVendite.RisolviCliente (la stessa risoluzione di get_list_vendite).
// Risposte: "ok" con il cliente; "richiede_disambiguazione" se la ragione sociale e'
// ambigua o non trovata (stessa forma di get_list_vendite, cosi' i pulsanti di scelta in
// chat funzionano); errore del tool se manca la chiave, la partita IVA e' malformata o
// id/partita IVA non esistono.

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
    // Contratto del tool per il pianificatore (vedi uContrattiTool.pas e il fondo di questa
    // unit).
    class function ContrattiTool: TArray<TContrattoTool>;
  end;

implementation

const
  // Partita IVA italiana: 11 cifre.
  LUNGHEZZA_PARTITA_IVA = 11;

// Toglie spazi e prefisso "IT" ("IT 012 345 678 90" -> "01234567890"). Non valida: per
// quello c'e' SembraPartitaIva.
function NormalizzaPartitaIva(const AValore: string): string;
begin
  Result := UpperCase(StringReplace(Trim(AValore), ' ', '', [rfReplaceAll]));
  if Result.StartsWith('IT') then
    Result := Result.Substring(2);
end;

// True se sono esattamente 11 cifre. Controllo di forma, non della cifra di controllo.
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

// Risposta "ok": anagrafica come la produce TCliente.ToJSONObject. Se questo cambia,
// aggiornare SCHEMA_OUTPUT_GET_CLIENTE in fondo.
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

// Risposta "richiede_disambiguazione": stessa forma di uVenditeToolProvider (un problema,
// campo "ragione_sociale_cliente", candidati con id/ragione_sociale/partita_iva).
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

function TClientiToolProvider.GetCliente(const AClienteId, ARagioneSocialeCliente,
  APartitaIva: string): TMCPToolResult;
var
  LIdTxt, LNome, LPartitaIva: string;
  LId: Integer;
  LCliente: TCliente;
  LRisoluzione: TRisoluzioneCliente;
begin
  LIdTxt := Trim(AClienteId);
  LNome := Trim(ARagioneSocialeCliente);
  LPartitaIva := NormalizzaPartitaIva(APartitaIva);

  // Tolleranza sul parametro sbagliato: i modelli locali sbagliano la casella piu' del
  // valore. Quindi: 11 cifre in id o ragione sociale sono una partita IVA (un id SERIAL non
  // arriva a 11 cifre); un "id" non intero positivo e' una ragione sociale.
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

  // Dalla chiave piu' precisa alla meno precisa.
  if LId > 0 then
  begin
    LCliente := TCliente.GetByID(LId);
    if LCliente = nil then
      Exit(TMCPToolResult.Error(Format('Nessun cliente con id %d.', [LId])));
  end
  else if LPartitaIva <> '' then
  begin
    // Controllo di forma prima della query: "partita IVA scritta male" e "partita IVA di
    // nessun cliente" sono risposte diverse.
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
      // Piu' clienti o nessuno: decide l'utente.
      if LRisoluzione.Esito <> erRisolto then
        Exit(TMCPToolResult.Text(CostruisciRispostaDisambiguazione(LRisoluzione)));
      // RisolviCliente porta solo id, ragione sociale e partita IVA: l'anagrafica completa
      // si rilegge per id.
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

// Schema di output della risposta "ok" (contratto in uContrattiTool.pas): "cliente" ha
// esattamente i campi di TCliente.ToJSONObject. I campi facoltativi arrivano come stringa
// vuota, mai null, quindi sono tutti "required". "id" e' integer: un piano puo' passarlo ad
// AClienteId di get_list_vendite ("$1.cliente.id").

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
  // Lettura, nessuna conferma. Lo schema non esprime che serve almeno una delle tre chiavi.
  Result := TArray<TContrattoTool>.Create(
    ContrattoTool('get_cliente', etLettura, False,
      SCHEMA_OUTPUT_GET_CLIENTE,
      nil,
      TArray<TArray<string>>.Create(
        TArray<string>.Create('AClienteId', 'APartitaIva', 'ARagioneSocialeCliente'))));
end;

end.
