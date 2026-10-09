unit uMCPToolProvider;

interface

uses
  System.JSON;

type
  // Contratto comune dei tool provider MCP (uno per scenario). Separa il trasporto MCP
  // dalla logica di business, che resta nei Services: un provider e' solo un adattatore
  // JSON <-> Servizio, senza query ne' regole di dominio.
  // ToolDefinition e' cio' che il server invia al modello con il prompt (formato function
  // calling OpenAI); Execute e' cio' che esegue quando il modello risponde con un tool_use
  // per questo tool.
  IMCPToolProvider = interface
    ['{E4B1C3A0-6F1D-4A9E-9C6B-2D8F7A1B5C3E}']

    // Nome univoco del tool: e' il "name" della tool definition e di
    // tool_use.function.name. Deve combaciare con quello di ToolDefinition.
    function ToolName: string;

    // Schema del tool in formato function calling (name, description, parameters come JSON
    // Schema). Il chiamante libera l'oggetto restituito.
    function ToolDefinition: TJSONObject;

    // Esegue il tool con gli argomenti scelti dal modello. Il chiamante libera sia AArgs
    // sia il risultato.
    // Execute non deve mai propagare un'eccezione per un errore di dominio (cliente non
    // trovato, filtro ambiguo): lo restituisce come JSON con un campo "esito" che il
    // modello puo' comunicare. Le eccezioni restano per gli errori imprevisti (DB
    // irraggiungibile), che il trasporto MCP intercetta.
    function Execute(AArgs: TJSONObject): TJSONObject;
  end;

implementation

end.
