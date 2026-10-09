unit uSintesiRisposta;

(* ============================================================================
  RISPOSTA PER L'UTENTE - tappa 10 del porting del pianificatore.
  Porting di scripts/prototipo_pianificatore/pianificatore/synthesizer.py,
  piu' i testi fissi decisi nel piano di lavoro del 02/10.

  -- Due modi di rispondere ----------------------------------------------------
  1. SINTESI (una chiamata al modello, senza tool e senza schema): quando il
     piano ha LETTO dei dati, o si e' fermato per un motivo che va spiegato
     (errore di un tool, nessun elemento trovato, passo non coperto). Il
     modello non decide niente: riceve la richiesta e cio' che e' stato
     eseguito (passi, argomenti, esiti, risultati) e lo racconta. Deve
     basarsi SOLO su quei risultati.
  2. TESTO FISSO (nessuna chiamata al modello): quando non c'e' niente da
     raccontare e una frase sbagliata farebbe danno:
       - richiesta di conferma di una scrittura;
       - richiesta di scelta fra candidati (disambiguazione);
       - piano non valido;
       - operazione annullata.
     Nel prototipo anche questi casi passavano dal modello; qui li scrive il
     codice, cosi' l'utente non puo' leggere "ho aperto la non conformita'"
     quando il sistema sta solo chiedendo conferma.

  Come le altre unit del pianificatore, questa non chiama il modello: prepara
  la richiesta per TClientLLM.Completa. I risultati inseriti nel messaggio
  sono ridotti (array troncati a 50 elementi) per non superare il contesto.
  ============================================================================ *)

interface

uses
  System.SysUtils,
  System.JSON,
  System.Generics.Collections,
  uPianificatore,
  uEsecutorePiano;

type
  TSintesiRisposta = class
  public
    // Richiesta per TClientLLM.Completa (del chiamante): { "messages": [...] }.
    // AEsecuzione puo' essere nil (niente e' stato eseguito).
    // AArrestoPreventivo (facoltativo, resta del chiamante): arresto deciso
    //   PRIMA dell'esecuzione, es. {"codice":"PASSO_NON_COPERTO","passi":[2],
    //   "azioni":["..."]}.
    class function RichiestaSintesi(const ADomanda, AOggi: string; APiano: TPiano;
      AEsecuzione: TEsitoEsecuzione; AArrestoPreventivo: TJSONObject = nil): TJSONObject;

    // Testi fissi.
    class function TestoConferma(const ATool: string; AArgomenti: TJSONObject): string;
    // AProblemi: l'array "richiede_disambiguazione" restituito dal tool.
    class function TestoDisambiguazione(AProblemi: TJSONValue): string;
    class function TestoPianoNonValido: string;
    class function TestoAnnullata: string;
  end;

// Testo JSON come json.dumps(..., ensure_ascii=False, indent=1) di Python:
// un elemento per riga, rientro di uno spazio per livello.
function JSONIndentatoComePython(AValore: TJSONValue; ALivello: Integer = 0): string;

implementation

uses
  uSchemaJSON,
  uStoricoTurni,
  uPromptPianificatore;

function JSONIndentatoComePython(AValore: TJSONValue; ALivello: Integer): string;
var
  LPezzi: TList<string>;
  LCoppia: TJSONPair;
  LRientro, LRientroInterno: string;
  LChiave: TJSONString;
  i: Integer;
begin
  LRientro := StringOfChar(' ', ALivello);
  LRientroInterno := StringOfChar(' ', ALivello + 1);

  if (AValore is TJSONObject) and (TJSONObject(AValore).Count > 0) then
  begin
    LPezzi := TList<string>.Create;
    try
      for LCoppia in TJSONObject(AValore) do
      begin
        LChiave := TJSONString.Create(LCoppia.JsonString.Value);
        try
          LPezzi.Add(LRientroInterno + JSONComePython(LChiave) + ': ' +
            JSONIndentatoComePython(LCoppia.JsonValue, ALivello + 1));
        finally
          LChiave.Free;
        end;
      end;
      Result := '{' + #10 + string.Join(',' + #10, LPezzi.ToArray) + #10 + LRientro + '}';
    finally
      LPezzi.Free;
    end;
  end
  else if (AValore is TJSONArray) and (TJSONArray(AValore).Count > 0) then
  begin
    LPezzi := TList<string>.Create;
    try
      for i := 0 to TJSONArray(AValore).Count - 1 do
        LPezzi.Add(LRientroInterno +
          JSONIndentatoComePython(TJSONArray(AValore).Items[i], ALivello + 1));
      Result := '[' + #10 + string.Join(',' + #10, LPezzi.ToArray) + #10 + LRientro + ']';
    finally
      LPezzi.Free;
    end;
  end
  else
    // Scalari e contenitori vuoti ("{}", "[]") su una riga.
    Result := JSONComePython(AValore);
end;

{ TSintesiRisposta }

class function TSintesiRisposta.RichiestaSintesi(const ADomanda, AOggi: string; APiano: TPiano;
  AEsecuzione: TEsitoEsecuzione; AArrestoPreventivo: TJSONObject): TJSONObject;
var
  LDati, LVoce: TJSONObject;
  LPassi, LMessaggi: TJSONArray;
  LEsito: TEsitoPasso;
  LPasso: TPasso;
  LAzione, LStato: string;
  LTrovata: Boolean;
  LCoppiaTolta: TJSONPair;
  i, j: Integer;
const
  // TETTO DI GRANDEZZA dei dati mandati al Synthesizer (argomenti e risultati
  // di tutti i passi insieme), in caratteri. Con un turno che produce molti
  // elementi lunghi (es. l'anteprima di 15 email di richiamo: i messaggi
  // compaiono negli argomenti E nel risultato) il prompt superava il contesto
  // del modello e LM Studio rispondeva 400: i tool erano stati eseguiti, ma
  // l'utente riceveva un errore (run delphi_20261004_114744, caso S1-G).
  // 24000 caratteri sono circa 7-8 mila token: resta spazio per il resto del
  // prompt e per la risposta in un contesto da 16384.
  MAX_CARATTERI_DATI_SINTESI = 24000;
  // Sopra il tetto gli array si accorciano per gradi: prima 10 elementi,
  // poi 3, poi 1. Accanto a ogni array accorciato resta "<nome>__totale",
  // quindi il modello sa quanti erano e puo' dirlo. I dati completi li ha
  // comunque il frontend (campo tool_calls della risposta).
  RIDUZIONI: array[0..2] of Integer = (10, 3, 1);
begin
  LDati := TJSONObject.Create;
  try
    if AArrestoPreventivo <> nil then
      LStato := 'fermata:' + TestoCampo(AArrestoPreventivo, 'codice')
    else if AEsecuzione <> nil then
      LStato := AEsecuzione.Etichetta
    else
      LStato := ESECUZIONE_NON_ESEGUITA;
    LDati.AddPair('stato', LStato);

    LPassi := TJSONArray.Create;
    LDati.AddPair('passi', LPassi);
    if AEsecuzione <> nil then
      for LEsito in AEsecuzione.Esiti do
      begin
        LVoce := TJSONObject.Create;
        LPassi.AddElement(LVoce);
        LVoce.AddPair('id', TJSONNumber.Create(LEsito.Id));

        // L'azione del passo, come l'aveva scritta il Planner.
        LTrovata := False;
        LAzione := '';
        for LPasso in APiano.Passi do
          if LPasso.Id = LEsito.Id then
          begin
            LAzione := LPasso.Azione;
            LTrovata := True;
          end;
        if LTrovata then
          LVoce.AddPair('azione', LAzione)
        else
          LVoce.AddPair('azione', TJSONNull.Create);

        LVoce.AddPair('tool', LEsito.Tool);
        if LEsito.ArgomentiRisolti <> nil then
          LVoce.AddPair('argomenti', LEsito.ArgomentiRisolti.Clone as TJSONValue)
        else
          LVoce.AddPair('argomenti', TJSONNull.Create);
        LVoce.AddPair('esito', LEsito.Esito);
        if LEsito.Dettaglio <> '' then
          LVoce.AddPair('dettaglio', LEsito.Dettaglio)
        else
          LVoce.AddPair('dettaglio', TJSONNull.Create);
        // Risultato ridotto: array troncati a 50 elementi (forma completa,
        // a differenza dello storico: qui il modello deve poter citare i dati).
        if LEsito.Output <> nil then
          LVoce.AddPair('output', RiduciOutput(LEsito.Output, 50, True))
        else
          LVoce.AddPair('output', TJSONNull.Create);
      end;

    // Applicazione del tetto (vedi MAX_CARATTERI_DATI_SINTESI). Nel caso
    // normale il primo controllo e' gia' sotto il limite e non cambia nulla:
    // il comportamento resta quello di prima.
    if AEsecuzione <> nil then
      for j := Low(RIDUZIONI) to High(RIDUZIONI) do
      begin
        if Length(LDati.ToJSON) <= MAX_CARATTERI_DATI_SINTESI then
          Break;
        for i := 0 to LPassi.Count - 1 do
        begin
          LVoce := TJSONObject(LPassi.Items[i]);
          LEsito := AEsecuzione.Esiti[i];
          if LEsito.ArgomentiRisolti <> nil then
          begin
            LCoppiaTolta := LVoce.RemovePair('argomenti');
            LCoppiaTolta.Free;
            LVoce.AddPair('argomenti', RiduciOutput(LEsito.ArgomentiRisolti, RIDUZIONI[j], True));
          end;
          if LEsito.Output <> nil then
          begin
            LCoppiaTolta := LVoce.RemovePair('output');
            LCoppiaTolta.Free;
            LVoce.AddPair('output', RiduciOutput(LEsito.Output, RIDUZIONI[j], True));
          end;
        end;
      end;

    if AArrestoPreventivo <> nil then
      LDati.AddPair('arresto', AArrestoPreventivo.Clone as TJSONValue);

    LMessaggi := TJSONArray.Create;
    LMessaggi.AddElement(TJSONObject.Create
      .AddPair('role', 'system')
      .AddPair('content', TPianificatore.PromptBase(AOggi) + PROMPT_SEZIONE_SINTESI));
    LMessaggi.AddElement(TJSONObject.Create
      .AddPair('role', 'user')
      .AddPair('content', PROMPT_MESSAGGIO_SINTESI_RICHIESTA + ADomanda +
        PROMPT_MESSAGGIO_SINTESI_ESECUZIONE + JSONIndentatoComePython(LDati)));

    Result := TJSONObject.Create.AddPair('messages', LMessaggi);
  finally
    LDati.Free;
  end;
end;

class function TSintesiRisposta.TestoConferma(const ATool: string; AArgomenti: TJSONObject): string;
begin
  Result :=
    'Per procedere serve la tua conferma, perche'' l''operazione modifica i dati del gestionale.' + #10 +
    'Operazione: ' + ATool + #10 +
    'Dati: ' + JSONComePython(AArgomenti) + #10 +
    'Confermi?';
end;

class function TSintesiRisposta.TestoDisambiguazione(AProblemi: TJSONValue): string;
var
  LRighe: TList<string>;
  LProblema, LCandidati: TJSONValue;
  LCosa: string;
  i, j: Integer;
begin
  LRighe := TList<string>.Create;
  try
    LRighe.Add('Mi serve una tua scelta prima di proseguire.');
    if AProblemi is TJSONArray then
      for i := 0 to TJSONArray(AProblemi).Count - 1 do
      begin
        LProblema := TJSONArray(AProblemi).Items[i];
        if not (LProblema is TJSONObject) then
          Continue;
        if TestoCampo(TJSONObject(LProblema), 'tipo') = 'non_trovato' then
          LCosa := 'non trovato'
        else
          LCosa := 'piu'' corrispondenze';
        LRighe.Add(Format('- "%s" (%s): %s',
          [TestoCampo(TJSONObject(LProblema), 'valore_cercato'),
           TestoCampo(TJSONObject(LProblema), 'campo'), LCosa]));
        LCandidati := TJSONObject(LProblema).GetValue('candidati');
        if LCandidati is TJSONArray then
          for j := 0 to TJSONArray(LCandidati).Count - 1 do
            LRighe.Add('    ' + JSONComePython(TJSONArray(LCandidati).Items[j]));
      end;
    Result := string.Join(#10, LRighe.ToArray);
  finally
    LRighe.Free;
  end;
end;

class function TSintesiRisposta.TestoPianoNonValido: string;
begin
  Result := MESSAGGIO_PIANO_NON_VALIDO;
end;

class function TSintesiRisposta.TestoAnnullata: string;
begin
  Result := 'Operazione annullata: nel gestionale non e'' stato modificato nulla.';
end;

end.
