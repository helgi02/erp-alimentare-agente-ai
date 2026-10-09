unit uCatalogoTool;

// Elenco dei tool MCP gia' tradotto nel formato "tools" dell'API OpenAI. Costruito una sola
// volta all'avvio, poi solo letto: i tool sono registrati in FormCreate e non cambiano per
// tutta la vita del processo.
// Non si allontana dal protocollo MCP: tools/list e' pensato per essere chiamato una volta
// per sessione e messo in cache (la specifica prevede notifications/tools/list_changed per
// invalidarla). Gli schemi restano generati dal server MCP; cambia solo quando avviene la
// traduzione.
// Costruisci va chiamato in FormCreate dopo tutte le Register*Provider e prima di
// doStartServer: un tool registrato dopo non comparirebbe mai al modello, senza alcun
// errore.
// I worker thread Indy leggono il catalogo in concorrenza senza lock, perche' non viene
// piu' modificato. Per lo stesso motivo Ricostruisci va chiamato solo a server fermo.
// Definizioni restituisce l'array interno, non un clone, per non rifare il lavoro a ogni
// turno.

interface

uses
  System.JSON;

type
  TCatalogoTool = class
  private
    class var FDefinizioni: System.JSON.TJSONArray;
    class destructor Destroy;
  public
    // Costruisce il catalogo da MCP; da chiamare una sola volta in FormCreate. Solleva
    // un'eccezione se e' vuoto: meglio fallire all'avvio che scoprire in chat un modello
    // che "non usa mai i tool".
    class procedure Costruisci;

    // Ricostruisce il catalogo. Solo a server fermo (vedi nota sui thread in testa).
    class procedure Ricostruisci;

    // Definizioni dei tool in formato OpenAI. L'array e' quello interno, condiviso: il
    // chiamante non deve liberarlo ne' modificarlo; se serve una versione modificabile la
    // cloni.
    class function Definizioni: System.JSON.TJSONArray;

    // Numero di tool nel catalogo; conferma rapida nel log di avvio che i provider sono
    // registrati.
    class function Conteggio: Integer;

    class function Costruito: Boolean;
  end;

implementation

uses
  System.SysUtils,
  uMCPBridge;

class destructor TCatalogoTool.Destroy;
begin
  FDefinizioni.Free;
end;

class procedure TCatalogoTool.Costruisci;
begin
  // Doppia costruzione: quasi sempre una doppia chiamata in FormCreate, meglio fallire
  // subito.
  if FDefinizioni <> nil then
    raise Exception.Create(
      'TCatalogoTool.Costruisci: il catalogo e'' gia'' stato costruito. ' +
      'Va chiamato una sola volta, in FormCreate dopo la registrazione dei ' +
      'tool provider. Per una ricostruzione volontaria usa Ricostruisci.');

  FDefinizioni := TMCPBridge.CostruisciElencoToolPerLLM;

  if FDefinizioni.Count = 0 then
  begin
    // Si libera prima di sollevare, per non lasciare il catalogo "costruito ma vuoto".
    FreeAndNil(FDefinizioni);
    raise Exception.Create(
      'TCatalogoTool.Costruisci: il server MCP non espone alcun tool. ' +
      'Verifica che le RegisterToolProvider/RegisterDynamicProvider in ' +
      'FormCreate siano eseguite PRIMA di questa chiamata.');
  end;
end;

class procedure TCatalogoTool.Ricostruisci;
begin
  FreeAndNil(FDefinizioni);
  Costruisci;
end;

class function TCatalogoTool.Definizioni: System.JSON.TJSONArray;
begin
  if FDefinizioni = nil then
    raise Exception.Create(
      'TCatalogoTool.Definizioni: catalogo non costruito. Manca la chiamata ' +
      'a TCatalogoTool.Costruisci in uFrmMain.FormCreate, dopo la ' +
      'registrazione dei tool provider.');

  Result := FDefinizioni;
end;

class function TCatalogoTool.Conteggio: Integer;
begin
  if FDefinizioni = nil then
    Result := 0
  else
    Result := FDefinizioni.Count;
end;

class function TCatalogoTool.Costruito: Boolean;
begin
  Result := FDefinizioni <> nil;
end;

end.
