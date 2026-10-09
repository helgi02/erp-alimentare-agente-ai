unit uRegistroViste;

// Catalogo condiviso delle viste del gestionale apribili dal modello con il tool apri_vista
// (uNavigazioneToolProvider).
// apri_vista non deve conoscere ogni scenario, ma qualcuno deve sapere che la vista
// "ricetta_prodotto_finito" esiste e richiede "prodotto_finito_id": il provider dello
// scenario. Ogni provider con una vista sensata (non tutti: le vendite stanno gia' bene in
// una tabella di chat) la registra qui una sola volta in FormCreate, accanto alla
// registrazione dei suoi tool. Wiring esplicito, niente scoperta automatica via RTTI o unit
// initialization.
// TNavigazioneToolProvider legge solo questo registro, senza importare unit di scenario.
// Lista piatta con ricerca lineare: le viste sono una manciata.
// Registra va chiamato solo all'avvio, prima che il server accetti richieste. Poi il
// registro e' solo letto, in concorrenza fra i worker Indy, senza lock.

interface

uses
  System.Generics.Collections;

type
  // Una voce: Nome e' l'identificatore stabile che il modello passa ad apri_vista e il
  // frontend usa per navigare (es. 'ricetta_prodotto_finito'); Descrizione e' una riga per
  // il modello, nella descrizione di apri_vista; ChiaviRichieste sono le chiavi
  // obbligatorie di "parametri" (es. ['prodotto_finito_id']).
  TDefinizioneVista = record
    Nome: string;
    Descrizione: string;
    ChiaviRichieste: TArray<string>;
  end;

  TRegistroViste = class
  private
    // class var, non un'istanza con GetInstance: e' stato condiviso per la durata del
    // processo, senza un proprietario che lo crei; lo inizializza e libera class
    // constructor/destructor.
    class var FViste: TList<TDefinizioneVista>;
    class constructor Create;
    class destructor Destroy;
  public
    // Registra una vista. Solleva un'eccezione se il nome esiste gia': quasi certamente un
    // copia-incolla sbagliato, meglio che l'avvio fallisca (come "Duplicate tool name" di
    // TMCPServer).
    class procedure Registra(const ADefinizione: TDefinizioneVista); overload;
    class procedure Registra(const ANome, ADescrizione: string;
      const AChiaviRichieste: TArray<string>); overload;

    // Cerca per nome (senza distinzione di maiuscole). False se non registrata:
    // TNavigazioneToolProvider.InvokeDynamic la trasforma in un errore di dominio che il
    // modello puo' correggere, non in un'eccezione.
    class function Find(const ANome: string; out ADefinizione: TDefinizioneVista): Boolean;

    // Tutte le viste, in ordine di registrazione. Descrizione del tool e validazione
    // partono dalla stessa fonte, quindi non possono disallinearsi.
    class function GetAll: TArray<TDefinizioneVista>;
  end;

implementation

uses
  System.SysUtils;

class constructor TRegistroViste.Create;
begin
  FViste := TList<TDefinizioneVista>.Create;
end;

class destructor TRegistroViste.Destroy;
begin
  FViste.Free;
end;

class procedure TRegistroViste.Registra(const ADefinizione: TDefinizioneVista);
var
  LEsistente: TDefinizioneVista;
begin
  if Find(ADefinizione.Nome, LEsistente) then
    raise Exception.CreateFmt(
      'TRegistroViste.Registra: la vista "%s" e'' gia'' registrata. Controlla se ' +
      'due tool provider dichiarano lo stesso nome, o se FormCreate la registra ' +
      'due volte per errore.',
      [ADefinizione.Nome]);

  FViste.Add(ADefinizione);
end;

class procedure TRegistroViste.Registra(const ANome, ADescrizione: string;
  const AChiaviRichieste: TArray<string>);
var
  LDefinizione: TDefinizioneVista;
begin
  LDefinizione.Nome := ANome;
  LDefinizione.Descrizione := ADescrizione;
  LDefinizione.ChiaviRichieste := AChiaviRichieste;
  Registra(LDefinizione);
end;

class function TRegistroViste.Find(const ANome: string;
  out ADefinizione: TDefinizioneVista): Boolean;
var
  LVista: TDefinizioneVista;
begin
  for LVista in FViste do
    if SameText(LVista.Nome, ANome) then
    begin
      ADefinizione := LVista;
      Exit(True);
    end;

  Result := False;
end;

class function TRegistroViste.GetAll: TArray<TDefinizioneVista>;
begin
  Result := FViste.ToArray;
end;

end.
