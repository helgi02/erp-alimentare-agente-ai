 unit uMCPBridge;

interface

uses
  System.SysUtils,
  System.JSON;

// Ponte in processo verso il server MCP (TMCPServer.Instance): stessi tool e stesso
// dispatch di /mcp, senza HTTP. E' l'unico punto che usa l'API della libreria MCP e
// JsonDataObjects; il resto del progetto usa System.JSON. Attenzione: TJSONObject delle due
// librerie ha lo stesso nome per il compilatore, quindi i tipi JsonDataObjects vanno sempre
// qualificati.

type
  TMCPBridge = class
  public
    // Tool registrati nel formato "tools" di chat/completions. Il chiamante libera l'array.
    // Costoso: chiamata una sola volta all'avvio da TCatalogoTool.Costruisci.
    class function CostruisciElencoToolPerLLM: System.JSON.TJSONArray;

    // Esegue un tool e restituisce il tool_result come stringa JSON.
    // Non solleva eccezioni: gli errori tornano al modello come {"errore": ...}.
    class function EseguiTool(const ANomeTool: string;
      AArgomenti: System.JSON.TJSONObject): string;

    // tool_result di errore nella forma unica {"errore": ..., "tool": ...}.
    class function RisultatoErrore(const AMessaggio, ANomeTool: string): string;
  end;

implementation

uses
  System.Generics.Collections,
  MVCFramework.MCP.Server,
  JsonDataObjects;

// Istanza di TMCPEndpoint sul server MCP esistente, come la factory di /mcp.
// Non apre nessun endpoint HTTP.
function CreaGestoreRichiesteMCP: TMCPEndpoint;
var
  LOggetto: TObject;
begin
  LOggetto := TMCPServer.Instance.CreatePublishedEndpoint;
  Result := LOggetto as TMCPEndpoint;
end;

class function TMCPBridge.CostruisciElencoToolPerLLM: System.JSON.TJSONArray;
var
  LGestore: TMCPEndpoint;
  LRispostaMCP: JsonDataObjects.TJsonObject;
  LRisposta: System.JSON.TJSONObject;
  LTools: System.JSON.TJSONArray;
  LTool, LFunzione, LVoce: System.JSON.TJSONObject;
  i: Integer;
begin
  Result := System.JSON.TJSONArray.Create;

  LGestore := CreaGestoreRichiesteMCP;
  try
    LRispostaMCP := LGestore.ToolsList;
    try
      LRisposta := System.JSON.TJSONObject.ParseJSONValue(LRispostaMCP.ToJSON) as System.JSON.TJSONObject;
      if LRisposta = nil then
        Exit;

      try
        LTools := LRisposta.GetValue('tools') as System.JSON.TJSONArray;
        if LTools = nil then
          Exit;

        for i := 0 to LTools.Count - 1 do
        begin
          LTool := LTools.Items[i] as System.JSON.TJSONObject;

          // MCP -> OpenAI: inputSchema diventa parameters.
          LFunzione := System.JSON.TJSONObject.Create;
          LFunzione.AddPair('name', LTool.GetValue('name').Value);

          if LTool.GetValue('description') <> nil then
            LFunzione.AddPair('description', LTool.GetValue('description').Value);

          if LTool.GetValue('inputSchema') <> nil then
            LFunzione.AddPair('parameters',
              (LTool.GetValue('inputSchema') as System.JSON.TJSONObject).Clone as System.JSON.TJSONObject);

          LVoce := System.JSON.TJSONObject.Create;
          LVoce.AddPair('type', 'function');
          LVoce.AddPair('function', LFunzione);

          Result.AddElement(LVoce);
        end;
      finally
        LRisposta.Free;
      end;
    finally
      LRispostaMCP.Free;
    end;
  finally
    LGestore.Free;
  end;
end;

class function TMCPBridge.RisultatoErrore(const AMessaggio, ANomeTool: string): string;
var
  LErrore: System.JSON.TJSONObject;
begin
  LErrore := System.JSON.TJSONObject.Create;
  try
    LErrore.AddPair('errore', AMessaggio);
    LErrore.AddPair('tool', ANomeTool);
    Result := LErrore.ToJSON;
  finally
    LErrore.Free;
  end;
end;

// Parametri scritti dal modello che il tool NON dichiara. La libreria MCP (DoToolsCall)
// ignora in silenzio i parametri non dichiarati: se il modello scrive "data_inizio" al
// posto di "ADataInizio", il filtro sparisce e il tool risponde "ok" con i valori
// predefiniti, senza alcun segnale. Con questo controllo la chiamata non parte e il modello
// riceve un errore con i nomi giusti. Confronto senza distinzione di maiuscole (come
// FindArgName). Restituisce i nomi non dichiarati separati da virgola ('' se validi);
// AValidi riceve i parametri dichiarati. Tool sconosciuto: '' (ci pensa la libreria con
// "Tool not found").
function ParametriNonDichiarati(const ANomeTool: string;
  AArgomenti: System.JSON.TJSONObject; out AValidi: string): string;
var
  LInfo: TMCPToolInfo;
  LNome: string;
  LDichiarato: Boolean;
  i, j: Integer;
begin
  Result := '';
  AValidi := '';

  if AArgomenti = nil then
    Exit;
  if not TMCPServer.Instance.Tools.TryGetValue(LowerCase(ANomeTool), LInfo) then
    Exit;

  for j := 0 to High(LInfo.Params) do
  begin
    if AValidi <> '' then
      AValidi := AValidi + ', ';
    AValidi := AValidi + LInfo.Params[j].Name;
  end;

  for i := 0 to AArgomenti.Count - 1 do
  begin
    LNome := AArgomenti.Pairs[i].JsonString.Value;

    LDichiarato := False;
    for j := 0 to High(LInfo.Params) do
      if SameText(LInfo.Params[j].Name, LNome) then
      begin
        LDichiarato := True;
        Break;
      end;

    if not LDichiarato then
    begin
      if Result <> '' then
        Result := Result + ', ';
      Result := Result + LNome;
    end;
  end;
end;

class function TMCPBridge.EseguiTool(const ANomeTool: string;
  AArgomenti: System.JSON.TJSONObject): string;
var
  LGestore: TMCPEndpoint;
  LArgomentiMCP, LRisultatoMCP: JsonDataObjects.TJsonObject;
  LBusta: System.JSON.TJSONObject;
  LContenuto: System.JSON.TJSONArray;
  LBlocco: System.JSON.TJSONObject;
  LTesto: System.JSON.TJSONValue;
  LNonDichiarati, LValidi: string;
begin
  try
    // Prima di eseguire: nessun parametro fuori da quelli dichiarati dal tool
    // (vedi ParametriNonDichiarati). Il tool NON viene eseguito.
    LNonDichiarati := ParametriNonDichiarati(ANomeTool, AArgomenti, LValidi);
    if LNonDichiarati <> '' then
      Exit(RisultatoErrore(Format(
        'Parametri non riconosciuti: %s. Il tool "%s" accetta solo questi parametri: %s. ' +
        'Ripeti la chiamata usando esattamente questi nomi.',
        [LNonDichiarati, ANomeTool, LValidi]), ANomeTool));

    LGestore := CreaGestoreRichiesteMCP;
    try
      if AArgomenti <> nil then
        LArgomentiMCP := JsonDataObjects.TJsonObject.Parse(AArgomenti.ToString) as JsonDataObjects.TJsonObject
      else
        LArgomentiMCP := JsonDataObjects.TJsonObject.Create;

      try
        LRisultatoMCP := LGestore.ToolsCall(ANomeTool, LArgomentiMCP);
        try
          // Si toglie la busta MCP {content:[{text}], isError}: al modello e
          // al frontend serve il JSON del tool.
          Result := LRisultatoMCP.ToJSON;

          LBusta := System.JSON.TJSONObject.ParseJSONValue(Result) as System.JSON.TJSONObject;
          if LBusta <> nil then
          try
            LContenuto := LBusta.GetValue('content') as System.JSON.TJSONArray;
            if (LContenuto <> nil) and (LContenuto.Count > 0) then
            begin
              LBlocco := LContenuto.Items[0] as System.JSON.TJSONObject;
              if LBlocco <> nil then
              begin
                LTesto := LBlocco.GetValue('text');
                // Forma inattesa: resta la busta intera.
                if LTesto <> nil then
                  Result := LTesto.Value;
              end;
            end;

            // isError=true: stessa forma del ramo except.
            if (LBusta.GetValue('isError') is System.JSON.TJSONBool) and
               System.JSON.TJSONBool(LBusta.GetValue('isError')).AsBoolean then
              Result := RisultatoErrore(Result, ANomeTool);
          finally
            LBusta.Free;
          end;
        finally
          LRisultatoMCP.Free;
        end;
      finally
        LArgomentiMCP.Free;
      end;
    finally
      LGestore.Free;
    end;
  except
    on E: Exception do
      Result := RisultatoErrore(E.Message, ANomeTool);
  end;
end;

end.
