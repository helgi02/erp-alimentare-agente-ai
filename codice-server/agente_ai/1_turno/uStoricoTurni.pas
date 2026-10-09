unit uStoricoTurni;

// Storico dei turni per il pianificatore: un record per turno con domanda, piano, esiti,
// risposta e stato.
// Lo stato rende possibili i turni successivi: "si', procedi" ha senso solo dopo
// in_attesa_conferma, "il secondo" solo dopo in_attesa_scelta.
// Al Planner arrivano gli ultimi NTurni turni; i risultati dei tool solo per gli ultimi
// EsitiTurni, ridotti da RiduciOutput per non gonfiare il prompt.
// RiduciOutput tronca gli array ai primi MaxElementi e aggiunge "<nome>__totale" con il
// numero originale; gli id restano. Nello storico gli array di soli valori (id, codici)
// restano interi e gli array annidati non si riportano.

interface

uses
  System.SysUtils,
  System.JSON,
  System.Generics.Collections,
  uPianificatore,
  uEsecutorePiano;

const
  STATO_CONCLUSO = 'concluso';
  STATO_IN_ATTESA_SCELTA = 'in_attesa_scelta';
  STATO_IN_ATTESA_CONFERMA = 'in_attesa_conferma';

type
  TTurnoStorico = class
  public
    Domanda: string;
    // {"esito","risposta","passi"} oppure nil. Di proprieta' del turno.
    Piano: TJSONObject;
    // Array di {"id","tool","argomenti","esito","output"}. Di proprieta' del turno.
    Esiti: TJSONArray;
    Risposta: string;
    Stato: string;
    ToolInAttesa: string;
    constructor Create;
    destructor Destroy; override;
  end;

  TStoricoTurni = class
  public
    NTurni: Integer;        // turni passati visibili al Planner
    MaxElementi: Integer;   // elementi di un array tenuti nello storico
    EsitiTurni: Integer;    // ultimi turni di cui il Planner vede i risultati
    Turni: TObjectList<TTurnoStorico>;
    // Valori predefiniti: 6 turni, 3 elementi, esiti solo dell'ultimo turno.
    constructor Create;
    destructor Destroy; override;

    // Aggiunge un turno (lo storico ne diventa proprietario).
    procedure Aggiungi(ATurno: TTurnoStorico);
    function Ultimo: TTurnoStorico;

    // Tool eseguiti con successo negli ultimi NTurni turni, piu' l'eventuale
    // tool in attesa di conferma.
    function ToolNoti: TArray<string>;
    // True se l'ultimo turno aspetta la conferma proprio di ATool.
    function InAttesaConferma(const ATool: string): Boolean;
    // Resa testuale per il Planner.
    function PerLLM: string;

    // Voci "esiti" di un turno a partire da un'esecuzione, con i risultati
    // ridotti come li vuole lo storico. Del chiamante.
    function EsitiDaEsecuzione(AEsecuzione: TEsitoEsecuzione): TJSONArray;
  end;

// Copia ridotta di un risultato (vedi il commento in testa). Del chiamante.
function RiduciOutput(AValore: TJSONValue; AMaxElementi: Integer = 5;
  AAnnidati: Boolean = True): TJSONValue;

implementation

uses
  uSchemaJSON;

function Contenitore(AValore: TJSONValue): Boolean;
begin
  Result := (AValore is TJSONObject) or (AValore is TJSONArray);
end;

function ContieneContenitori(AArray: TJSONArray): Boolean;
var
  i: Integer;
begin
  Result := False;
  for i := 0 to AArray.Count - 1 do
    if Contenitore(AArray.Items[i]) then
      Exit(True);
end;

function Riduci(AValore: TJSONValue; AMaxElementi: Integer; AAnnidati, AInArray: Boolean): TJSONValue;
var
  LOggetto: TJSONObject;
  LArray: TJSONArray;
  LCoppia: TJSONPair;
  LRidotto: TJSONValue;
  LNome: string;
  i, LQuanti: Integer;
begin
  if AValore is TJSONObject then
  begin
    LOggetto := TJSONObject.Create;
    for LCoppia in TJSONObject(AValore) do
    begin
      LNome := LCoppia.JsonString.Value;
      // Array di oggetti dentro un elemento di array: nello storico resta
      // solo quanti erano.
      if (LCoppia.JsonValue is TJSONArray) and AInArray and not AAnnidati and
         ContieneContenitori(TJSONArray(LCoppia.JsonValue)) then
      begin
        LOggetto.AddPair(LNome + '__totale',
          TJSONNumber.Create(TJSONArray(LCoppia.JsonValue).Count));
        Continue;
      end;
      LRidotto := Riduci(LCoppia.JsonValue, AMaxElementi, AAnnidati, AInArray);
      LOggetto.AddPair(LNome, LRidotto);
      if (LCoppia.JsonValue is TJSONArray) and
         (TJSONArray(LRidotto).Count < TJSONArray(LCoppia.JsonValue).Count) then
        LOggetto.AddPair(LNome + '__totale',
          TJSONNumber.Create(TJSONArray(LCoppia.JsonValue).Count));
    end;
    Exit(LOggetto);
  end;

  if AValore is TJSONArray then
  begin
    // Array di soli valori (id, codici): intero. Costa pochi token e un
    // seguito deve poter passare tutti i lotti, non i primi tre.
    if not AAnnidati and not ContieneContenitori(TJSONArray(AValore)) then
      Exit(AValore.Clone as TJSONValue);
    LArray := TJSONArray.Create;
    LQuanti := TJSONArray(AValore).Count;
    if LQuanti > AMaxElementi then
      LQuanti := AMaxElementi;
    for i := 0 to LQuanti - 1 do
      LArray.AddElement(Riduci(TJSONArray(AValore).Items[i], AMaxElementi, AAnnidati, True));
    Exit(LArray);
  end;

  Result := AValore.Clone as TJSONValue;
end;

function RiduciOutput(AValore: TJSONValue; AMaxElementi: Integer; AAnnidati: Boolean): TJSONValue;
begin
  Result := Riduci(AValore, AMaxElementi, AAnnidati, False);
end;

constructor TTurnoStorico.Create;
begin
  inherited;
  Esiti := TJSONArray.Create;
  Stato := STATO_CONCLUSO;
end;

destructor TTurnoStorico.Destroy;
begin
  Piano.Free;
  Esiti.Free;
  inherited;
end;

constructor TStoricoTurni.Create;
begin
  inherited;
  NTurni := 6;
  MaxElementi := 3;
  EsitiTurni := 1;
  Turni := TObjectList<TTurnoStorico>.Create(True);
end;

destructor TStoricoTurni.Destroy;
begin
  Turni.Free;
  inherited;
end;

procedure TStoricoTurni.Aggiungi(ATurno: TTurnoStorico);
begin
  Turni.Add(ATurno);
end;

function TStoricoTurni.Ultimo: TTurnoStorico;
begin
  if Turni.Count = 0 then
    Result := nil
  else
    Result := Turni[Turni.Count - 1];
end;

function TStoricoTurni.ToolNoti: TArray<string>;
var
  LPrimo, i, j: Integer;
  LVoce: TJSONValue;
  LTool: string;

  procedure AggiungiSeNuovo(const ANome: string);
  var
    LPresente: string;
  begin
    for LPresente in Result do
      if LPresente = ANome then
        Exit;
    Result := Result + [ANome];
  end;

begin
  Result := nil;
  LPrimo := Turni.Count - NTurni;
  if LPrimo < 0 then
    LPrimo := 0;
  for i := LPrimo to Turni.Count - 1 do
    for j := 0 to Turni[i].Esiti.Count - 1 do
    begin
      LVoce := Turni[i].Esiti.Items[j];
      if (LVoce is TJSONObject) and (TestoCampo(TJSONObject(LVoce), 'esito') = 'ok') then
      begin
        LTool := TestoCampo(TJSONObject(LVoce), 'tool');
        AggiungiSeNuovo(LTool);
      end;
    end;
  if (Ultimo <> nil) and (Ultimo.ToolInAttesa <> '') then
    AggiungiSeNuovo(Ultimo.ToolInAttesa);
end;

function TStoricoTurni.InAttesaConferma(const ATool: string): Boolean;
begin
  Result := (Ultimo <> nil) and (Ultimo.Stato = STATO_IN_ATTESA_CONFERMA) and
    (Ultimo.ToolInAttesa = ATool);
end;

function TStoricoTurni.PerLLM: string;
var
  LBlocchi, LRighe: TList<string>;
  LTurno: TTurnoStorico;
  LPassi, LVoce, LOutput: TJSONValue;
  LPasso: TJSONObject;
  LPrimo, LNumero, i, j: Integer;
  LConEsiti: Boolean;
  LTool, LRispostaPiano, LStato, LTestoOutput: string;
begin
  if Turni.Count = 0 then
    Exit('(nessun turno precedente)');

  LBlocchi := TList<string>.Create;
  LRighe := TList<string>.Create;
  try
    LPrimo := Turni.Count - NTurni;
    if LPrimo < 0 then
      LPrimo := 0;
    for i := LPrimo to Turni.Count - 1 do
    begin
      LTurno := Turni[i];
      LNumero := i + 1;                       // i turni si contano da 1
      // Risultati dei tool solo per gli ultimi EsitiTurni turni.
      LConEsiti := (EsitiTurni > 0) and (i >= Turni.Count - EsitiTurni);

      LRighe.Clear;
      LRighe.Add(Format('TURNO %d', [LNumero]));
      LRighe.Add('Utente: ' + LTurno.Domanda);

      if LTurno.Piano <> nil then
      begin
        LRighe.Add('Piano: ' + TestoCampo(LTurno.Piano, 'esito'));
        LPassi := LTurno.Piano.GetValue('passi');
        if LPassi is TJSONArray then
          for j := 0 to TJSONArray(LPassi).Count - 1 do
            if TJSONArray(LPassi).Items[j] is TJSONObject then
            begin
              LPasso := TJSONObject(TJSONArray(LPassi).Items[j]);
              LTool := TestoCampo(LPasso, 'tool');
              if LTool <> '' then
                LTool := ' [' + LTool + ']';
              LRighe.Add(Format('  %s. %s%s',
                [TestoCampo(LPasso, 'id'), TestoCampo(LPasso, 'azione'), LTool]));
            end;
        LRispostaPiano := TestoCampo(LTurno.Piano, 'risposta');
        if (LRispostaPiano <> '') and (LTurno.Risposta = '') then
          LRighe.Add('Assistente: ' + LRispostaPiano);
      end
      else if LTurno.Esiti.Count = 0 then
        LRighe.Add('Piano: (non valido)');

      if LConEsiti and (LTurno.Esiti.Count > 0) then
      begin
        LRighe.Add('Passi eseguiti:');
        for j := 0 to LTurno.Esiti.Count - 1 do
        begin
          LVoce := LTurno.Esiti.Items[j];
          if not (LVoce is TJSONObject) then
            Continue;
          LOutput := TJSONObject(LVoce).GetValue('output');
          if (LOutput = nil) or (LOutput is TJSONNull) then
            LTestoOutput := '-'
          else
            LTestoOutput := JSONComePython(LOutput);
          LRighe.Add(Format('  %s. %s %s -> %s: %s',
            [TestoCampo(TJSONObject(LVoce), 'id'), TestoCampo(TJSONObject(LVoce), 'tool'),
             JSONComePython(TJSONObject(LVoce).GetValue('argomenti')),
             TestoCampo(TJSONObject(LVoce), 'esito'), LTestoOutput]));
        end;
      end;

      if LTurno.Risposta <> '' then
        LRighe.Add('Assistente: ' + LTurno.Risposta);
      LStato := LTurno.Stato;
      if LTurno.ToolInAttesa <> '' then
        LStato := LStato + ' (tool: ' + LTurno.ToolInAttesa + ')';
      LRighe.Add('Stato: ' + LStato);

      LBlocchi.Add(string.Join(#10, LRighe.ToArray));
    end;
    Result := string.Join(#10#10, LBlocchi.ToArray);
  finally
    LRighe.Free;
    LBlocchi.Free;
  end;
end;

function TStoricoTurni.EsitiDaEsecuzione(AEsecuzione: TEsitoEsecuzione): TJSONArray;
var
  LEsito: TEsitoPasso;
  LVoce: TJSONObject;
begin
  Result := TJSONArray.Create;
  if AEsecuzione = nil then
    Exit;
  for LEsito in AEsecuzione.Esiti do
  begin
    LVoce := TJSONObject.Create;
    Result.AddElement(LVoce);
    LVoce.AddPair('id', TJSONNumber.Create(LEsito.Id));
    LVoce.AddPair('tool', LEsito.Tool);
    if LEsito.ArgomentiRisolti <> nil then
      LVoce.AddPair('argomenti', LEsito.ArgomentiRisolti.Clone as TJSONValue)
    else
      LVoce.AddPair('argomenti', TJSONNull.Create);
    LVoce.AddPair('esito', LEsito.Esito);
    // Un risultato assente o vuoto non si riporta.
    if (LEsito.Output <> nil) and (LEsito.Output.Count > 0) then
      LVoce.AddPair('output', RiduciOutput(LEsito.Output, MaxElementi, False))
    else
      LVoce.AddPair('output', TJSONNull.Create);
  end;
end;

end.
