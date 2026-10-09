unit uServizioEmbedding;

// Client dell'endpoint /v1/embeddings (API compatibile OpenAI), usato dal retrieval
// semantico dei tool (uIndiceEmbeddingTool.pas). Trasforma un testo in un vettore: testi
// simili danno vettori vicini. Non conosce PostgreSQL ne' i tool: riceve stringhe,
// restituisce vettori.
// Usa un modello diverso da quello di chat (piccolo, multilingue, adatto agli embedding),
// configurato in [Embedding] dell'ini (Endpoint e Model). Il server di inferenza puo'
// tenere in memoria entrambi i modelli: sono due path dello stesso server.
// Il metodo batch esiste perche' l'API accetta un array di testi in una sola chiamata:
// Sincronizza ne calcola molti a ogni avvio. Ottieni (singolare) serve per la domanda in
// Cerca.

interface

uses
  System.SysUtils;

type
  // Single (non Double): e' la precisione della colonna vector di pgvector, nessuna
  // conversione.
  TEmbedding = TArray<Single>;

  TServizioEmbedding = class
  public
    // Embedding di un singolo testo, sopra OttieniBatch: un solo punto da cui si parla con
    // il server (timeout, parsing, errori).
    class function Ottieni(const ATesto: string): TEmbedding;

    // Embedding di piu' testi in una sola chiamata. L'ordine del risultato segue ATesti
    // grazie al campo "index" di ogni oggetto in "data", non alla posizione nella risposta.
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
  // Timeout piu' corto di quello della chat: un embedding e' un solo passaggio su un
  // modello piccolo, quindi se non risponde in pochi secondi di solito il modello non e'
  // caricato.
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
          // Come in ChiamaLLM: il corpo dell'errore spiega il motivo (modello non caricato,
          // richiesta malformata) meglio del solo status code.
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

            // "index" e' la posizione nell'array "input" originale: l'API non garantisce
            // che "data" torni nello stesso ordine.
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
