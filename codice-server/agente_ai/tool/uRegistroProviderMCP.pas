unit uRegistroProviderMCP;

// Catalogo delle descrizioni dei tool provider MCP (uno per dominio), per l'orchestratore e
// non per il protocollo.
// Serve a mandare al modello solo i provider pertinenti: un modello piccolo (9B locale) con
// troppi tool simili sbaglia scelta, e questo e' un problema di accuratezza oltre che di
// token. TCatalogoTool evita gia' la ricostruzione ripetuta dell'elenco; qui c'e' solo il
// catalogo delle descrizioni, non la selezione.
// La selezione va fatta una volta per turno utente e tenuta fissa per le iterazioni del
// ciclo tool_use: cambiarla a meta' farebbe sparire un tool appena usato.
// E' un registro separato perche' TMCPToolProvider della libreria non ha il concetto di
// "descrizione del provider" e non si modifica codice di terze parti. Come TRegistroViste,
// e' una lista piatta con ricerca lineare: i provider sono pochi.
// Registra va chiamato solo in FormCreate, subito dopo la registrazione MCP del provider:
// senza la sua voce un provider verrebbe escluso da ogni turno in silenzio. Poi il registro
// e' solo letto, senza lock.

interface

uses
  System.Generics.Collections;

type
  // Voce del catalogo. Nome e' una chiave stabile (es. 'vendite'), non il nome della
  // classe, cosi' si puo' rinominare la classe senza rompere riferimenti salvati altrove.
  // Descrizione e' il testo letto dall'LLM nella selezione: dominio e quando sceglierlo,
  // non i parametri. NomiTool sono i tool del provider, la chiave per filtrare l'elenco
  // dopo la selezione.
  TDescrizioneProviderMCP = record
    Nome: string;
    Descrizione: string;
    NomiTool: TArray<string>;
  end;

  TRegistroProviderMCP = class
  private
    class var FProvider: TList<TDescrizioneProviderMCP>;
    class constructor Create;
    class destructor Destroy;
  public
    // Registra un provider. Solleva un'eccezione se il nome esiste gia': quasi certamente
    // un copia-incolla sbagliato in FormCreate, meglio che l'avvio fallisca.
    class procedure Registra(const ADescrizione: TDescrizioneProviderMCP); overload;
    class procedure Registra(const ANome, ADescrizione: string;
      const ANomiTool: TArray<string>); overload;

    // Cerca per nome (senza distinzione di maiuscole).
    class function Find(const ANome: string; out ADescrizione: TDescrizioneProviderMCP): Boolean;

    // Tutti i provider, in ordine di registrazione: il "menu" della fase di selezione.
    class function Tutte: TArray<TDescrizioneProviderMCP>;

    // Nomi dei tool dei provider indicati, senza duplicati. Se ANomiProvider e' vuoto
    // restituisce un array vuoto, non "tutti": cosa fare con una selezione vuota o non
    // valida spetta al chiamante.
    class function NomiToolPer(const ANomiProvider: TArray<string>): TArray<string>;

    // Percorso inverso: il provider a cui appartiene ANomeTool, o stringa vuota se nessuno
    // lo rivendica (tool registrato ma dimenticato qui). Usato da TrovaProvider
    // (uIndiceEmbeddingTool) e da TServizioAgente.ProviderUsatiDiRecente.
    class function ProviderDiTool(const ANomeTool: string): string;
  end;

implementation

uses
  System.SysUtils;

class constructor TRegistroProviderMCP.Create;
begin
  FProvider := TList<TDescrizioneProviderMCP>.Create;
end;

class destructor TRegistroProviderMCP.Destroy;
begin
  FProvider.Free;
end;

class procedure TRegistroProviderMCP.Registra(const ADescrizione: TDescrizioneProviderMCP);
var
  LEsistente: TDescrizioneProviderMCP;
begin
  if Find(ADescrizione.Nome, LEsistente) then
    raise Exception.CreateFmt(
      'TRegistroProviderMCP.Registra: il provider "%s" e'' gia'' registrato. Controlla se ' +
      'due chiamate in FormCreate usano lo stesso nome, o se e'' un copia-incolla.',
      [ADescrizione.Nome]);

  FProvider.Add(ADescrizione);
end;

class procedure TRegistroProviderMCP.Registra(const ANome, ADescrizione: string;
  const ANomiTool: TArray<string>);
var
  LDescrizione: TDescrizioneProviderMCP;
begin
  LDescrizione.Nome := ANome;
  LDescrizione.Descrizione := ADescrizione;
  LDescrizione.NomiTool := ANomiTool;
  Registra(LDescrizione);
end;

class function TRegistroProviderMCP.Find(const ANome: string;
  out ADescrizione: TDescrizioneProviderMCP): Boolean;
var
  LProvider: TDescrizioneProviderMCP;
begin
  for LProvider in FProvider do
    if SameText(LProvider.Nome, ANome) then
    begin
      ADescrizione := LProvider;
      Exit(True);
    end;

  Result := False;
end;

class function TRegistroProviderMCP.Tutte: TArray<TDescrizioneProviderMCP>;
begin
  Result := FProvider.ToArray;
end;

class function TRegistroProviderMCP.NomiToolPer(const ANomiProvider: TArray<string>): TArray<string>;
var
  LRisultato: TList<string>;
  LNomeProvider, LNomeTool: string;
  LDescrizione: TDescrizioneProviderMCP;
begin
  LRisultato := TList<string>.Create;
  try
    for LNomeProvider in ANomiProvider do
      if Find(LNomeProvider, LDescrizione) then
        for LNomeTool in LDescrizione.NomiTool do
          if not LRisultato.Contains(LNomeTool) then
            LRisultato.Add(LNomeTool);

    Result := LRisultato.ToArray;
  finally
    LRisultato.Free;
  end;
end;

class function TRegistroProviderMCP.ProviderDiTool(const ANomeTool: string): string;
var
  LProvider: TDescrizioneProviderMCP;
  LNomeTool: string;
begin
  for LProvider in FProvider do
    for LNomeTool in LProvider.NomiTool do
      if SameText(LNomeTool, ANomeTool) then
        Exit(LProvider.Nome);

  Result := '';
end;

end.
