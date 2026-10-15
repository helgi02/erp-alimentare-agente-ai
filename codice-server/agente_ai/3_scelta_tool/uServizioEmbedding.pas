unit uServizioEmbedding;

(* ============================================================================
  TServizioEmbedding -- client verso l'endpoint /v1/embeddings di LM Studio
  (API compatibile OpenAI), usato dalla fase 1 dell'orchestratore (retrieval
  semantico dei tool: vedi agente_ai/3_scelta_tool/uIndiceEmbeddingTool.pas).

  -- Cosa fa, e cosa NON fa --------------------------------------------------
  Trasforma un testo in un vettore di numeri (un "embedding"): testi di
  significato simile producono vettori vicini fra loro. Questa unit non sa
  nulla di PostgreSQL/pgvector ne' di tool MCP - riceve stringhe, restituisce
  vettori. Chi li confronta e li salva e' uIndiceEmbeddingTool.

  -- Perche' un modello DIVERSO da quello di chat -----------------------------
  Qwen (il modello di chat, vedi TServizioAgente.ChiamaLLM) e' addestrato per
  generare testo, non per produrre imbedding di buona qualita'. Serve un
  modello dedicato, piccolo (gira su CPU in millisecondi) e MULTILINGUE
  (le domande arrivano in italiano): configurato a parte in
  TConfig.EmbeddingModel, sezione [Embedding] dell'ini, chiave Model
  (endpoint: chiave Endpoint, sempre sul server).
  LM Studio puo' tenere entrambi i modelli caricati in memoria insieme:
  sono due richieste HTTP verso due path diversi dello stesso server
  (.../chat/completions vs .../embeddings), non due processi separati.

  -- Perche' un metodo "batch" e non solo uno per singolo testo --------------
  L'API /v1/embeddings, come tutte le API compatibili OpenAI, accetta "input"
  come array di stringhe e risponde con un embedding per ciascuna, in
  un'UNICA chiamata HTTP. TIndiceEmbeddingTool.Sincronizza deve calcolare
  l'embedding di tutte le frasi nuove/cambiate ad ogni avvio: farlo con una
  chiamata per frase moltiplicherebbe per N la latenza di rete per nessun
  vantaggio (il costo di calcolo lato LM Studio e' comunque per frase).
  Ottieni (singolare) resta utile per la query dell'utente in Cerca, dove
  per costruzione c'e' un solo testo da trasformare.
  ============================================================================ *)

interface

uses
  System.SysUtils;

type
  // Precisione Single, non Double: e' la stessa con cui la colonna
  // "vector(384)" di pgvector memorizza i valori (float a precisione
  // singola), quindi nessuna conversione di precisione fra quello che LM
  // Studio restituisce e quello che finisce sul DB.
  TEmbedding = TArray<Single>;

  TServizioEmbedding = class
  public
    // Embedding di un singolo testo. Implementato sopra OttieniBatch (una
    // chiamata con un solo elemento in "input"): un solo punto che parla
    // con LM Studio, un solo posto dove aggiustare timeout/parsing/errori.
    class function Ottieni(const ATesto: string): TEmbedding;

    // Embedding di piu' testi in un'unica chiamata HTTP. L'ordine del
    // risultato rispecchia ATesti indipendentemente dall'ordine in cui LM
    // Studio elenca gli oggetti in "data": ciascuno porta un campo "index"
    // (la posizione nell'array "input" originale) ed e' quello, non la
    // posizione nella risposta, a decidere dove va il vettore nel
    // risultato - vedi il commento nell'implementazione.
    class function OttieniBatch(const ATesti: TArray<string>): TArray<TEmbedding>;
  end;

implementation

uses
  System.Classes,
  System.JSON,
  System.Net.HttpClient,
  System.Net.HttpClientComponent,
  uConfig;

const
  // Un embedding e' un singolo forward pass su un modello piccolo (~100-300
  // MB, pensato per girare su CPU in millisecondi), non una generazione
  // token per token come la chat: se non risponde in pochi secondi il
  // problema e' quasi certamente "il modello di embedding non e' caricato
  // in LM Studio", non un motore lento al lavoro. Timeout piu' corto di
  // quello usato per la chat (vedi TIMEOUT_LLM_MS in uServiziAgente) per lo
  // stesso motivo per cui quel timeout e' piu' lungo: sono situazioni
  // diverse, non lo stesso numero copiato altrove.
  TIMEOUT_EMBEDDING_MS = 15000;

class function TServizioEmbedding.OttieniBatch(const ATesti: TArray<string>): TArray<TEmbedding>;
var
  LClient: TNetHTTPClient;
  LCorpo: TJSONObject;
  LInput: TJSONArray;
  LStream: TStringStream;
  LRisposta: IHTTPResponse;
  LRispostaJSON: TJSONObject;
  LDati: TJSONArray;
  LVoce: TJSONObject;
  LEmbeddingJSON: TJSONArray;
  LIndice, i, j: Integer;
  LDettaglioErrore: string;
  LTesto: string;
  LModello: string;
begin
  SetLength(Result, Length(ATesti));
  if Length(ATesti) = 0 then
    Exit;

  LModello := TConfig.GetInstance.EmbeddingModel;
  if LModello = '' then
    raise Exception.Create(
      'TServizioEmbedding.OttieniBatch: nessun modello di embedding configurato. ' +
      'Aggiungi "Model=<nome-modello-caricato-in-LM-Studio>" alla sezione ' +
      '[Embedding] del file .ini - deve essere un modello DI EMBEDDING (es. un ' +
      'multilingual-e5-small), non il modello di chat ([LLM] ChatModel).');

  LClient := TNetHTTPClient.Create(nil);
  try
    LClient.ConnectionTimeout := TIMEOUT_EMBEDDING_MS;
    LClient.ResponseTimeout := TIMEOUT_EMBEDDING_MS;
    LClient.ContentType := 'application/json';

    LCorpo := TJSONObject.Create;
    try
      LCorpo.AddPair('model', LModello);

      LInput := TJSONArray.Create;
      for LTesto in ATesti do
        LInput.Add(LTesto);
      LCorpo.AddPair('input', LInput);

      LStream := TStringStream.Create(LCorpo.ToJSON, TEncoding.UTF8);
      try
        LRisposta := LClient.Post(
          TConfig.GetInstance.EmbeddingEndpoint + '/embeddings', LStream);

        if LRisposta.StatusCode <> 200 then
        begin
          // Stessa logica di ChiamaLLM (uServiziAgente.pas): il corpo
          // dell'errore di LM Studio spiega quasi sempre il motivo vero
          // (modello non caricato, richiesta malformata) meglio dello
          // status code da solo.
          LDettaglioErrore := Trim(LRisposta.ContentAsString(TEncoding.UTF8));
          if Length(LDettaglioErrore) > 500 then
            LDettaglioErrore := Copy(LDettaglioErrore, 1, 500) + '...';
          if LDettaglioErrore = '' then
            LDettaglioErrore := '(corpo della risposta vuoto)';

          raise Exception.CreateFmt(
            'LM Studio ha risposto con codice %d a /v1/embeddings. Verifica che il ' +
            'modello di embedding "%s" sia caricato (in LM Studio un modello di chat ' +
            'e uno di embedding possono stare in memoria insieme, ma vanno caricati ' +
            'entrambi separatamente). Dettaglio: %s',
            [LRisposta.StatusCode, LModello, LDettaglioErrore]);
        end;

        LRispostaJSON := TJSONObject.ParseJSONValue(
          LRisposta.ContentAsString(TEncoding.UTF8)) as TJSONObject;

        if LRispostaJSON = nil then
          raise Exception.Create('Risposta di /v1/embeddings non interpretabile come JSON.');

        try
          LDati := LRispostaJSON.GetValue('data') as TJSONArray;
          if LDati = nil then
            raise Exception.Create('Risposta di /v1/embeddings priva del campo "data".');

          if LDati.Count <> Length(ATesti) then
            raise Exception.CreateFmt(
              'Risposta di /v1/embeddings inattesa: attesi %d embedding, ricevuti %d.',
              [Length(ATesti), LDati.Count]);

          for i := 0 to LDati.Count - 1 do
          begin
            LVoce := LDati.Items[i] as TJSONObject;

            // "index" e' la posizione nell'array "input" ORIGINALE: la API
            // OpenAI-compatibile non garantisce che "data" torni nello
            // stesso ordine di "input" (in pratica con LM Studio succede,
            // ma non c'e' motivo di fidarsene silenziosamente quando il
            // campo che lo garantisce esiste apposta).
            LIndice := LVoce.GetValue<Integer>('index');
            LEmbeddingJSON := LVoce.GetValue('embedding') as TJSONArray;

            SetLength(Result[LIndice], LEmbeddingJSON.Count);
            for j := 0 to LEmbeddingJSON.Count - 1 do
              Result[LIndice][j] := (LEmbeddingJSON.Items[j] as TJSONNumber).AsDouble;
          end;
        finally
          LRispostaJSON.Free;
        end;
      finally
        LStream.Free;
      end;
    finally
      LCorpo.Free;
    end;
  finally
    LClient.Free;
  end;
end;

class function TServizioEmbedding.Ottieni(const ATesto: string): TEmbedding;
var
  LRisultati: TArray<TEmbedding>;
begin
  LRisultati := OttieniBatch(TArray<string>.Create(ATesto));
  Result := LRisultati[0];
end;

end.
