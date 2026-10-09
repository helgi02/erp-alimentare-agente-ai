unit uClientLLM;

// Client LLM: la chiamata HTTP dal server al motore di inferenza.
// Il frontend non sa nulla del modello: e' il SERVER a chiamarlo, con una sola
// configurazione nell'ini, sezione [LLM]: ChatEndpoint (URL di base, API
// OpenAI-compatibile), ChatModel (vuoto = modello caricato), Temperatura (opzionale),
// MaxToken (0 = default del motore), PresencePenalty (opzionale, anti-ripetizione),
// Pensiero (0 = thinking disattivato), TimeoutMs.
// Il motore (LM Studio, llama.cpp server, Ollama, vLLM, Unsloth...) gira sulla stessa
// macchina del server o nella rete interna: i dati non escono dall'infrastruttura. Il
// pannello impostazioni della chat cambia questi valori passando dal server (GET/PUT
// /api/ai/configurazione-llm), che li valida e li riscrive nell'ini (TConfig.SalvaChat).
// Solo formato OpenAI: il formato interno (messaggi system/user/assistant/tool, tool_calls
// con arguments come stringa JSON) e' gia' chat/completions, quindi la richiesta di
// TServizioAgente.PreparaRichiestaLLM si invia quasi com'e' e la risposta non va tradotta.
// API cloud per i test di confronto: lo stesso client puo' chiamare l'API di OpenAI
// (ChatEndpoint=https://api.openai.com/v1). Serve [LLM] ConsentiCloud=1 e una chiave API
// (TConfig.EndpointAmmesso); domande e risultati dei tool ESCONO dall'infrastruttura,
// quindi e' una modalita' di test, spenta di default. Un endpoint non locale cambia quattro
// dettagli (CostruisciCorpo e Completa): intestazione "Authorization: Bearer <chiave>";
// "max_completion_tokens" al posto di "max_tokens"; niente "chat_template_kwargs" ne'
// "presence_penalty" (l'API rifiuta i campi che non conosce); "strict": false nell'output
// vincolato (lo strict di OpenAI pretende additionalProperties false e tutti i campi
// required, ma "argomenti" del piano e' a forma libera: a controllare resta il validatore).
// La Temperatura si manda se configurata (alcuni modelli accettano solo il default:
// lasciarla vuota).
// Sviluppo futuro: separare l'ADATTATORE (formato di richiesta e risposta) dal TRASPORTO
// (chi esegue l'HTTP: il server, oppure il browser verso un LLM sul PC dell'utente).

interface

uses
  System.SysUtils,
  System.JSON,
  uConfig;

type
  // Errore del motore (spento, timeout, HTTP <> 200, JSON non valido). Distinto dalle altre
  // eccezioni perche' il controller lo traduce in 502 con un messaggio per l'utente, e
  // perche' in quel caso nessun tool del passo e' stato ancora eseguito.
  ELLMErrore = class(Exception);

  TClientLLM = class
  public
    // Corpo chat/completions dalla richiesta interna. Funzione pura (nessuna rete ne'
    // configurazione globale), pubblica perche' il programma di prova tests/ProvaClientLLM
    // la verifica senza server. Il risultato e' del chiamante.
    class function CostruisciCorpo(ARichiesta: TJSONObject;
      const AChat: TConfigChat): TJSONObject;

    // ARichiesta (da TServizioAgente.PreparaRichiestaLLM): { "messages": [...], "tools":
    // [...], "consenti_tool": bool, "modello": "..." (solo test), "schema_risposta": {
    // "nome": "...", "schema": {...} } (facoltativo) }. Resta del chiamante.
    // Output vincolato (schema_risposta): Planner e Completer devono restituire un JSON di
    // forma nota. La richiesta porta "response_format": { "type": "json_schema",
    // "json_schema": { "name", "strict": true, "schema" } }; il motore lo traduce in una
    // grammatica, quindi choices[0].message.content e' un JSON valido per costruzione. Il
    // significato (tool esistenti, riferimenti) lo controlla il validatore del piano.
    // Risultato: la risposta del motore nella forma attesa da ElaboraRispostaLLM
    // ({choices:[{message}], usage, model}), del chiamante. ADurataMs: durata della sola
    // chiamata HTTP, per la diagnostica. Solleva ELLMErrore con un messaggio leggibile.
    class function Completa(ARichiesta: TJSONObject; out ADurataMs: Int64): TJSONObject; overload;

    // Come sopra, ma con la configurazione passata dal chiamante (la versione senza AChat
    // usa TConfig.GetInstance.Chat). Serve al programma di prova, che riceve endpoint e
    // modello da riga di comando.
    class function Completa(ARichiesta: TJSONObject; const AChat: TConfigChat;
      out ADurataMs: Int64): TJSONObject; overload;
    // Modelli di chat esposti da un motore (GET <AEndpoint>/models), per il pannello
    // impostazioni: verifica un indirizzo prima di salvarlo e permette di scegliere il
    // modello da un elenco. Esclusi embedding e rerank. Timeout breve (verifica
    // interattiva). Solleva ELLMErrore se il motore non risponde.
    class function ElencaModelli(const AEndpoint: string): TArray<string>;
  end;

implementation

uses
  System.Classes,
  System.Diagnostics,
  System.Net.HttpClient,
  System.Net.HttpClientComponent,
  System.RegularExpressions,
  System.Generics.Collections;

class function TClientLLM.CostruisciCorpo(ARichiesta: TJSONObject;
  const AChat: TConfigChat): TJSONObject;
var
  LModello, LMotivo: string;
  LTools, LSchemaRisposta, LNomeSchema, LSchema, LStrict: TJSONValue;
  LConsentiTool, LCloud: Boolean;
begin
  // Endpoint non locale = API cloud (vedi l'intestazione).
  LCloud := not TConfig.EndpointLocale(Trim(AChat.Endpoint), LMotivo);

  // Nome del modello: override della batteria di test > ini > 'local-model'
  // (il nome che LM Studio accetta usando il modello gia' caricato).
  LModello := '';
  if ARichiesta.GetValue('modello') <> nil then
    LModello := ARichiesta.GetValue('modello').Value;
  if LModello = '' then
    LModello := AChat.Modello;
  if LModello = '' then
    LModello := 'local-model';

  Result := TJSONObject.Create;
  try
    Result.AddPair('model', LModello);

    // Temperatura solo se configurata: senza, vale il default del motore.
    if AChat.HaTemperatura then
      Result.AddPair('temperature', TJSONNumber.Create(AChat.Temperatura));

    if AChat.MaxToken > 0 then
    begin
      if LCloud then
        Result.AddPair('max_completion_tokens', TJSONNumber.Create(AChat.MaxToken))
      else
        Result.AddPair('max_tokens', TJSONNumber.Create(AChat.MaxToken));
    end;

    // Presence penalty solo se configurata: rompe i loop di ripetizione dei modelli
    // piccoli. Solo ai motori locali.
    if AChat.HaPresencePenalty and not LCloud then
      Result.AddPair('presence_penalty', TJSONNumber.Create(AChat.PresencePenalty));

    // Thinking disattivato: si passa enable_thinking = false al chat template
    // (chat_template_kwargs; i motori che non lo conoscono lo ignorano). Con Pensiero =
    // True non si manda nulla. Solo ai motori locali.
    if (not AChat.Pensiero) and not LCloud then
      Result.AddPair('chat_template_kwargs',
        TJSONObject.Create.AddPair('enable_thinking', TJSONFalse.Create));

    // Clone: il corpo libera i propri oggetti, mentre messaggi e tool restano della
    // richiesta (e dello stato del turno).
    Result.AddPair('messages', ARichiesta.GetValue('messages').Clone as TJSONValue);

    // Paracadute di fine ciclo (consenti_tool = false): non si mandano i tool, il modo piu'
    // affidabile per avere una risposta a parole con i modelli locali.
    LConsentiTool := (ARichiesta.GetValue('consenti_tool') is TJSONBool) and
      TJSONBool(ARichiesta.GetValue('consenti_tool')).AsBoolean;
    LTools := ARichiesta.GetValue('tools');
    if LConsentiTool and (LTools is TJSONArray) and (TJSONArray(LTools).Count > 0) then
    begin
      Result.AddPair('tools', LTools.Clone as TJSONValue);
      Result.AddPair('tool_choice', 'auto');
    end;

    // Output vincolato: solo se la richiesta porta uno schema completo (nome + schema
    // oggetto).
    LSchemaRisposta := ARichiesta.GetValue('schema_risposta');
    if LSchemaRisposta is TJSONObject then
    begin
      LNomeSchema := TJSONObject(LSchemaRisposta).GetValue('nome');
      LSchema := TJSONObject(LSchemaRisposta).GetValue('schema');
      if (LNomeSchema = nil) or (LNomeSchema.Value = '') or not (LSchema is TJSONObject) then
        raise ELLMErrore.Create(
          'schema_risposta non valido: servono "nome" (testo) e "schema" (oggetto JSON Schema).');

      // Locale: strict (grammatica). Cloud: false, vedi "API CLOUD".
      if LCloud then
        LStrict := TJSONFalse.Create
      else
        LStrict := TJSONTrue.Create;

      Result.AddPair('response_format', TJSONObject.Create
        .AddPair('type', 'json_schema')
        .AddPair('json_schema', TJSONObject.Create
          .AddPair('name', LNomeSchema.Value)
          .AddPair('strict', LStrict)
          // Clone: lo schema resta della richiesta (vedi il commento su messages).
          .AddPair('schema', LSchema.Clone as TJSONValue)));
    end;
  except
    Result.Free;
    raise;
  end;
end;

class function TClientLLM.Completa(ARichiesta: TJSONObject; out ADurataMs: Int64): TJSONObject;
begin
  // Copia della configurazione letta una volta: se cambia dal pannello a meta', questa
  // chiamata resta coerente; il cambio vale dal passo successivo.
  Result := Completa(ARichiesta, TConfig.GetInstance.Chat, ADurataMs);
end;

class function TClientLLM.Completa(ARichiesta: TJSONObject; const AChat: TConfigChat;
  out ADurataMs: Int64): TJSONObject;
var
  LChat: TConfigChat;
  LClient: TNetHTTPClient;
  LCorpo: TJSONObject;
  LStream: TStringStream;
  LRisposta: IHTTPResponse;
  LValore: TJSONValue;
  LUrl, LDettaglio, LMotivo: string;
  LCronometro: TStopwatch;
  LCloud: Boolean;
begin
  LChat := AChat;
  // Ultimo controllo prima della rete: l'ini si puo' scrivere a mano, quindi un endpoint
  // pubblico non autorizzato non viene contattato (non riceve dati ne' chiave).
  LCloud := not TConfig.EndpointLocale(Trim(LChat.Endpoint), LMotivo);
  if LCloud and not TConfig.EndpointAmmesso(Trim(LChat.Endpoint), LMotivo) then
    raise ELLMErrore.Create('Indirizzo del modello non ammesso: ' + LMotivo + '.');
  // Endpoint di BASE (es. http://localhost:1234/v1): il suffisso
  // /chat/completions e' lo stesso per tutti i motori OpenAI-compatibili.
  LUrl := LChat.Endpoint.TrimRight(['/']) + '/chat/completions';

  LCorpo := CostruisciCorpo(ARichiesta, LChat);
  try
    LClient := TNetHTTPClient.Create(nil);
    LStream := TStringStream.Create(LCorpo.ToJSON, TEncoding.UTF8);
    try
      LClient.ConnectionTimeout := LChat.TimeoutMs;
      LClient.ResponseTimeout := LChat.TimeoutMs;
      LClient.ContentType := 'application/json';
      // Due chiavi distinte, mai scambiate: la cloud va solo all'host cloud autorizzato;
      // quella locale ([LLM] ChiaveApiLocale) solo a un motore locale che la richiede (es.
      // Unsloth Studio). Senza chiave locale non si manda alcuna intestazione.
      if LCloud then
        LClient.CustomHeaders['Authorization'] := 'Bearer ' + TConfig.ChiaveApiCloud
      else if TConfig.ChiaveApiLocale <> '' then
        LClient.CustomHeaders['Authorization'] := 'Bearer ' + TConfig.ChiaveApiLocale;

      LCronometro := TStopwatch.StartNew;
      try
        LRisposta := LClient.Post(LUrl, LStream);
      except
        on E: Exception do
          // Errore di connessione (motore spento, porta sbagliata, timeout): non c'e' uno
          // status code, quindi si indica l'indirizzo contattato e cosa controllare.
          raise ELLMErrore.CreateFmt(
            'Il motore di inferenza non risponde su %s (%s). Verificare che ' +
            'LM Studio (o il motore indicato nelle impostazioni del modello) sia ' +
            'avviato e abbia un modello caricato.', [LUrl, E.Message]);
      end;
      LCronometro.Stop;
      ADurataMs := LCronometro.ElapsedMilliseconds;

      if LRisposta.StatusCode <> 200 then
      begin
        // Il corpo dell'errore spiega quasi sempre la causa (contesto troppo lungo, modello
        // non caricato...). Troncato per il log.
        LDettaglio := Trim(LRisposta.ContentAsString(TEncoding.UTF8));
        if Length(LDettaglio) > 500 then
          LDettaglio := Copy(LDettaglio, 1, 500) + '...';
        if LDettaglio = '' then
          LDettaglio := '(corpo della risposta vuoto)';
        raise ELLMErrore.CreateFmt(
          'Il motore di inferenza ha risposto con codice %d (%s). Dettaglio: %s',
          [LRisposta.StatusCode, LUrl, LDettaglio]);
      end;

      LValore := TJSONObject.ParseJSONValue(LRisposta.ContentAsString(TEncoding.UTF8));
      if not (LValore is TJSONObject) then
      begin
        LValore.Free;
        raise ELLMErrore.Create('Risposta del motore di inferenza non interpretabile come JSON.');
      end;
      // Gia' nel formato interno: nessuna normalizzazione da fare.
      Result := TJSONObject(LValore);
    finally
      LStream.Free;
      LClient.Free;
    end;
  finally
    LCorpo.Free;
  end;
end;

class function TClientLLM.ElencaModelli(const AEndpoint: string): TArray<string>;
const
  TIMEOUT_VERIFICA_MS = 5000;
var
  LClient: TNetHTTPClient;
  LRisposta: IHTTPResponse;
  LValore, LVoce: TJSONValue;
  LDati: TJSONValue;
  LElenco: TList<string>;
  LUrl, LId, LTesto, LMotivo: string;
  LStatus: Integer;
begin
  LUrl := AEndpoint.Trim.TrimRight(['/']) + '/models';
  LClient := TNetHTTPClient.Create(nil);
  try
    LClient.ConnectionTimeout := TIMEOUT_VERIFICA_MS;
    LClient.ResponseTimeout := TIMEOUT_VERIFICA_MS;
    // Anche l'elenco dei modelli puo' richiedere la chiave, con la stessa regola di
    // Completa: motore locale -> chiave locale; cloud autorizzata -> chiave cloud;
    // altrimenti nessuna.
    if TConfig.EndpointLocale(AEndpoint.Trim, LMotivo) then
    begin
      if TConfig.ChiaveApiLocale <> '' then
        LClient.CustomHeaders['Authorization'] := 'Bearer ' + TConfig.ChiaveApiLocale;
    end
    else if TConfig.EndpointAmmesso(AEndpoint.Trim, LMotivo) then
      LClient.CustomHeaders['Authorization'] := 'Bearer ' + TConfig.ChiaveApiCloud;
    try
      LRisposta := LClient.Get(LUrl);
    except
      on E: Exception do
        raise ELLMErrore.CreateFmt('Nessuna risposta da %s (%s). Il motore di inferenza ' +
          'e'' avviato e ascolta su quella porta?', [LUrl, E.Message]);
    end;
    // Letti PRIMA di liberare il client.
    LStatus := LRisposta.StatusCode;
    LTesto := LRisposta.ContentAsString(TEncoding.UTF8);
  finally
    LClient.Free;
  end;

  // 401/403: l'URL e' giusto ma la chiave manca o e' sbagliata; messaggio dedicato per non
  // far cercare l'errore nell'indirizzo.
  if (LStatus = 401) or (LStatus = 403) then
    raise ELLMErrore.CreateFmt('%s ha risposto con codice %d: chiave API mancante o non ' +
      'valida. Per un motore locale impostare [LLM] ChiaveApiLocale nell''ini del server ' +
      '(per il cloud: ChiaveApi) e riavviare.', [LUrl, LStatus]);
  if LStatus <> 200 then
    raise ELLMErrore.CreateFmt('%s ha risposto con codice %d: e'' davvero l''URL di base ' +
      'di un''API compatibile OpenAI (di solito termina con /v1)?', [LUrl, LStatus]);

  // Formato standard: { "data": [ { "id": "..." }, ... ] }
  LValore := TJSONObject.ParseJSONValue(LTesto);
  LElenco := TList<string>.Create;
  try
    try
      LDati := nil;
      if LValore is TJSONObject then
        LDati := TJSONObject(LValore).GetValue('data');
      if not (LDati is TJSONArray) then
        raise ELLMErrore.CreateFmt('%s non ha restituito un elenco di modelli nel formato ' +
          'atteso ({"data": [...]}).', [LUrl]);
      for LVoce in TJSONArray(LDati) do
        if (LVoce is TJSONObject) and (TJSONObject(LVoce).GetValue('id') <> nil) then
        begin
          LId := TJSONObject(LVoce).GetValue('id').Value;
          // I modelli di embedding e rerank non sanno conversare.
          if not TRegEx.IsMatch(LId, 'embed|rerank', [roIgnoreCase]) then
            LElenco.Add(LId);
        end;
    finally
      LValore.Free;
    end;
    Result := LElenco.ToArray;
  finally
    LElenco.Free;
  end;
end;

end.
