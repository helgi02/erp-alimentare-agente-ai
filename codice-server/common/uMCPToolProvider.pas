unit uMCPToolProvider;

interface

uses
  System.JSON;

type
  // Contratto comune a tutti i "tool provider" MCP del gestionale (uno
  // per scenario del tirocinio: vendite, ritiro/richiamo, ricette, ...).
  // Serve a disaccoppiare il livello di TRASPORTO MCP (il componente che
  // riceve da LM Studio/Qwen il tool_use e instrada la chiamata verso il
  // tool giusto - non ancora scritto, sara' il prossimo passo dopo il
  // primo tool concreto) dalla LOGICA DI BUSINESS di ciascuno scenario,
  // che resta nei rispettivi layer Services (uServiziVendite,
  // uServiziRitiroRichiamo, uServiziRicette): un tool provider e' solo un
  // adattatore JSON <-> Servizio, non contiene query ne' regole di
  // dominio proprie.
  //
  // Corrispondenza con il flusso descritto nelle note di progetto:
  // ToolDefinition e' cio' che il server Delphi invia a LM Studio insieme
  // al prompt (l'elenco dei tool disponibili, in formato "function
  // calling" compatibile OpenAI); Execute e' cio' che il server esegue
  // quando Qwen risponde con un tool_use per QUESTO tool, e il suo
  // risultato (il tool_result) torna al modello per la risposta finale.
  IMCPToolProvider = interface
    ['{E4B1C3A0-6F1D-4A9E-9C6B-2D8F7A1B5C3E}']

    // Nome univoco del tool: e' il valore che compare nel campo "name"
    // della tool definition inviata al modello, e in tool_use.function.name
    // quando il modello lo richiama. Deve combaciare esattamente con il
    // "name" restituito da ToolDefinition.
    function ToolName: string;

    // Schema del tool in formato "function calling" (name, description,
    // parameters come JSON Schema) da includere nella richiesta a LM
    // Studio. Il chiamante e' responsabile di liberare l'oggetto
    // restituito.
    function ToolDefinition: TJSONObject;

    // Esegue il tool con gli argomenti scelti dal modello (gia'
    // deserializzati dal livello di trasporto MCP, un oggetto JSON con le
    // stesse chiavi definite in ToolDefinition.parameters) e restituisce
    // il tool_result. Il chiamante e' responsabile di liberare sia AArgs
    // sia l'oggetto restituito.
    //
    // Nota di progetto importante: Execute non deve MAI propagare
    // un'eccezione per un errore "di dominio" (es. cliente non trovato,
    // filtro ambiguo) - quello va restituito come JSON con un campo
    // "esito" che il modello puo' interpretare e comunicare all'utente
    // (vedi TServizioVendite e il futuro TToolProviderVendite). Le
    // eccezioni restano riservate a errori realmente imprevisti (es. DB
    // irraggiungibile), che il livello di trasporto MCP dovra' comunque
    // intercettare per non far crashare la conversazione.
    function Execute(AArgs: TJSONObject): TJSONObject;
  end;

implementation

end.
