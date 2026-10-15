unit uClientLLM;

// CLIENT LLM - la chiamata HTTP dal server al motore di inferenza.
//
// DECISIONE DEL 29/09/2026
// Il frontend non deve sapere nulla del modello: niente profili, formati,
// endpoint o chiavi nel browser. E' il SERVER a chiamare l'LLM, e per
// questo progetto c'e' UNA sola configurazione, nell'ini:
//
//   [LLM]
//   ChatEndpoint=http://localhost:1234/v1   ; URL di base, API OpenAI-compatibile
//   ChatModel=google/gemma-4-12b-qat        ; vuoto = modello caricato in LM Studio
//   Temperatura=0.2                         ; opzionale
//   MaxToken=2048                           ; 0 = default del motore
//   PresencePenalty=1.0                     ; opzionale, anti-ripetizione
//   Pensiero=0                              ; 0 = thinking disattivato
//   TimeoutMs=180000
//
// Il motore (LM Studio, llama.cpp server, Ollama, vLLM...) gira sulla stessa
// macchina del server Delphi (o nella rete interna): i dati aziendali non
// escono dall'infrastruttura e il browser non parla mai con il modello.
// Il pannello impostazioni della chat puo' cambiare questi valori, ma
// passando dal server (GET/PUT /api/ai/configurazione-llm), che li valida
// e li riscrive nell'ini: vedi TConfig.SalvaChat.
//
// PERCHE' SOLO IL FORMATO OPENAI
// Il formato interno dell'orchestratore (storico, finestra dei turni,
// fallback testuale, diagnostica) e' gia' chat/completions: messaggi
// role=system/user/assistant/tool, tool_calls con arguments come stringa
// JSON. Tutti i motori locali citati espongono questa API, quindi la
// richiesta preparata da TServizioAgente.PreparaRichiestaLLM si invia quasi
// cosi' com'e' e la risposta non va tradotta.
//
// API CLOUD PER I TEST DI CONFRONTO (04/10/2026)
// Lo stesso client puo' chiamare anche l'API di OpenAI (ChatGPT), che parla
// lo stesso formato: ChatEndpoint=https://api.openai.com/v1 e ChatModel=<id
// del modello>. Serve [LLM] ConsentiCloud=1 e una chiave API (vedi
// TConfig.EndpointAmmesso): in quel caso domande e risultati dei tool ESCONO
// dall'infrastruttura, quindi e' una modalita' di test, spenta di default.
// Un endpoint non locale ("cloud") cambia quattro dettagli della richiesta,
// tutti in CostruisciCorpo / Completa:
//   - intestazione "Authorization: Bearer <chiave>";
//   - "max_completion_tokens" al posto di "max_tokens" (i modelli OpenAI
//     recenti rifiutano il vecchio nome; per i modelli con ragionamento il
//     tetto comprende anche i token di ragionamento);
//   - niente "chat_template_kwargs" ne' "presence_penalty": sono rimedi per
//     i modelli locali piccoli e l'API OpenAI rifiuta i campi che non conosce;
//   - "strict": false nell'output vincolato. Lo strict di OpenAI pretende
//     "additionalProperties": false e tutti i campi "required" in OGNI
//     oggetto, mentre il piano ha "argomenti" a forma libera: con false il
//     modello segue lo schema senza garanzia formale, e a controllare resta
//     il validatore del piano (come gia' per il significato).
// La Temperatura si manda se configurata: alcuni modelli (famiglia GPT-5)
// accettano solo il default, in quel caso lasciarla vuota.
//
// SVILUPPI FUTURI (per la relazione)
// Una versione precedente (backup in Claude outputs/backup_pulizia_client_llm_
// 2026-09-29/core) aveva piu' profili e un adapter Anthropic. L'estensione
// naturale e' separare l'ADATTATORE (solo formato: costruisci richiesta /
// normalizza risposta) dal TRASPORTO (chi esegue l'HTTP: il server, oppure il
// browser come "postino" verso un LLM sul PC dell'utente). Questa unit e' il
// caso piu' semplice: un adattatore OpenAI con trasporto server.

interface

uses
  System.SysUtils,
  System.JSON,
  uConfig;

type
  // Errore del motore di inferenza (spento, timeout, HTTP <> 200, JSON non
  // valido). Tenuto distinto dalle altre eccezioni perche' il controller lo
  // traduce in 502 con un messaggio per l'utente, e perche' quando si
  // verifica NESSUN tool di quel passo e' stato ancora eseguito.
  ELLMErrore = class(Exception);

  TClientLLM = class
  public
    // Corpo chat/completions a partire dalla richiesta interna. Funzione
    // pura (nessuna rete, nessuna configurazione globale): e' pubblica
    // perche' il programma di prova tests/ProvaClientLLM la verifica senza
    // avviare ne' il server ne' il motore di inferenza. Il risultato e' del
    // chiamante.
    class function CostruisciCorpo(ARichiesta: TJSONObject;
      const AChat: TConfigChat): TJSONObject;

    // ARichiesta: oggetto prodotto da TServizioAgente.PreparaRichiestaLLM
    //   { "messages": [...], "tools": [...], "consenti_tool": bool,
    //     "modello": "..." (solo batteria di test),
    //     "schema_risposta": { "nome": "...", "schema": {...} } (facoltativo) }
    //   Resta del chiamante: qui lo si legge e basta.
    //
    // OUTPUT VINCOLATO (schema_risposta) - tappa 1 del porting del
    // pianificatore. Planner e Completer non rispondono a parole ne' con
    // tool_calls: devono restituire un JSON di forma nota (il piano). Con
    // "schema_risposta" la richiesta porta al motore
    //   "response_format": { "type": "json_schema",
    //       "json_schema": { "name": <nome>, "strict": true, "schema": <schema> } }
    // LM Studio / llama.cpp traducono lo schema in una grammatica: il
    // modello puo' generare SOLO testo che la rispetta, quindi il contenuto
    // della risposta (choices[0].message.content) e' un JSON sintatticamente
    // valido per costruzione. Resta da controllare il SIGNIFICATO (tool
    // esistenti, riferimenti...): e' il compito del validatore del piano.
    // Stesso meccanismo e stessi campi del prototipo Python
    // (scripts/prototipo_pianificatore/pianificatore/llm.py, LLMLMStudio.completa).
    // Risultato: la risposta del motore, gia' nella forma che
    //   ElaboraRispostaLLM si aspetta ({choices:[{message}], usage, model}).
    //   Appartiene al chiamante, che la libera.
    // ADurataMs: tempo della sola chiamata HTTP, per la diagnostica.
    // Solleva ELLMErrore con un messaggio leggibile in caso di problemi.
    class function Completa(ARichiesta: TJSONObject; out ADurataMs: Int64): TJSONObject; overload;

    // Come sopra, ma con la configurazione passata dal chiamante invece che
    // letta da TConfig. La versione senza AChat richiama questa con
    // TConfig.GetInstance.Chat. Serve al programma di prova, che non ha un
    // TConfig (l'ini del server) e riceve endpoint e modello da riga di comando.
    class function Completa(ARichiesta: TJSONObject; const AChat: TConfigChat;
      out ADurataMs: Int64): TJSONObject; overload;
    // Modelli di chat esposti da un motore (GET <AEndpoint>/models), per il
    // pannello impostazioni: serve a verificare un indirizzo PRIMA di
    // salvarlo e a scegliere il modello da un elenco invece di scriverlo a
    // mano. I modelli di embedding/rerank sono esclusi. Timeout breve: e'
    // una verifica interattiva. Solleva ELLMErrore se il motore non risponde.
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
  // Endpoint non locale = API cloud (vedi "API CLOUD" in testa alla unit).
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

    // Presence penalty solo se configurata: rompe i loop di ripetizione dei
    // modelli piccoli (stesso paragrafo ripetuto fino al timeout).
    // Solo ai motori locali (vedi "API CLOUD").
    if AChat.HaPresencePenalty and not LCloud then
      Result.AddPair('presence_penalty', TJSONNumber.Create(AChat.PresencePenalty));

    // Thinking disattivato: si passa enable_thinking = false al chat template
    // (chat_template_kwargs, supportato da llama.cpp server e vLLM; i motori
    // che non lo conoscono ignorano il campo). Con Pensiero = True non si
    // manda nulla e vale il comportamento predefinito del modello.
    // Solo ai motori locali: l'API cloud rifiuta i campi che non conosce.
    if (not AChat.Pensiero) and not LCloud then
      Result.AddPair('chat_template_kwargs',
        TJSONObject.Create.AddPair('enable_thinking', TJSONFalse.Create));

    // Clone: il corpo possiede i propri oggetti e li libera con se stesso,
    // mentre messaggi e tool restano della richiesta (e dello stato del
    // turno, che li riusa al passo successivo).
    Result.AddPair('messages', ARichiesta.GetValue('messages').Clone as TJSONValue);

    // Paracadute di fine ciclo (consenti_tool = false): non si mandano
    // proprio i tool. Con i modelli locali e' il modo piu' affidabile di
    // ottenere una risposta a parole.
    LConsentiTool := (ARichiesta.GetValue('consenti_tool') is TJSONBool) and
      TJSONBool(ARichiesta.GetValue('consenti_tool')).AsBoolean;
    LTools := ARichiesta.GetValue('tools');
    if LConsentiTool and (LTools is TJSONArray) and (TJSONArray(LTools).Count > 0) then
    begin
      Result.AddPair('tools', LTools.Clone as TJSONValue);
      Result.AddPair('tool_choice', 'auto');
    end;

    // Output vincolato: solo se la richiesta porta uno schema completo
    // (nome + schema oggetto). Una richiesta senza "schema_risposta" produce
    // lo stesso corpo di prima: l'orchestratore attuale non cambia.
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
  // Copia della configurazione letta UNA volta: se nel frattempo qualcuno
  // la cambia dal pannello, questa chiamata resta coerente (endpoint, modello
  // e timeout dello stesso momento); il cambio vale dal passo successivo.
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
  // Ultimo controllo prima della rete. Il pannello valida gia' l'indirizzo,
  // ma l'ini si puo' anche scrivere a mano: un endpoint pubblico non
  // autorizzato non viene contattato (e non riceve ne' dati ne' chiave).
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
      // Due chiavi distinte, mai scambiate: quella cloud va SOLO all'host
      // cloud autorizzato; quella locale ([LLM] ChiaveApiLocale) SOLO a un
      // motore locale che la richiede (es. Unsloth Studio). Senza chiave
      // locale non si manda alcuna intestazione (LM Studio, Ollama...).
      if LCloud then
        LClient.CustomHeaders['Authorization'] := 'Bearer ' + TConfig.ChiaveApiCloud
      else if TConfig.ChiaveApiLocale <> '' then
        LClient.CustomHeaders['Authorization'] := 'Bearer ' + TConfig.ChiaveApiLocale;

      LCronometro := TStopwatch.StartNew;
      try
        LRisposta := LClient.Post(LUrl, LStream);
      except
        on E: Exception do
          // Errore di CONNESSIONE (motore spento, porta sbagliata, timeout):
          // non c'e' uno status code, quindi si dice QUALE indirizzo si
          // stava contattando e cosa controllare.
          raise ELLMErrore.CreateFmt(
            'Il motore di inferenza non risponde su %s (%s). Verificare che ' +
            'LM Studio (o il motore indicato nelle impostazioni del modello) sia ' +
            'avviato e abbia un modello caricato.', [LUrl, E.Message]);
      end;
      LCronometro.Stop;
      ADurataMs := LCronometro.ElapsedMilliseconds;

      if LRisposta.StatusCode <> 200 then
      begin
        // Il corpo dell'errore spiega quasi sempre la causa vera (contesto
        // troppo lungo, modello non caricato...). Troncato per il log.
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
    // Anche l'elenco dei modelli puo' richiedere la chiave. Stessa regola
    // di Completa: motore locale -> chiave locale (se impostata); API cloud
    // autorizzata -> chiave cloud; altrimenti nessuna intestazione.
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

  // 401/403 = l'URL e' giusto ma manca (o e' sbagliata) la chiave: messaggio
  // dedicato, per non far cercare l'errore nell'indirizzo.
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
          // Stesso filtro che usava il vecchio client: i modelli di
          // embedding e rerank non sanno conversare.
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
