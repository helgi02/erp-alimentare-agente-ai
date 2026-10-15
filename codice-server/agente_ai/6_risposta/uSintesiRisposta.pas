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
  uValidatorePiano,
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
      AEsecuzione: TEsitoEsecuzione; AArrestoPreventivo: TJSONObject = nil;
      const ARiepilogoMostrato: string = ''): TJSONObject;

    // Testi fissi.
    class function TestoConferma(const ATool: string; AArgomenti: TJSONObject): string;
    // AProblemi: l'array "richiede_disambiguazione" restituito dal tool.
    class function TestoDisambiguazione(AProblemi: TJSONValue): string;
    class function TestoPianoNonValido: string;
    // Riepilogo FISSO di un ritiro/richiamo, scritto dal codice (non dal
    // modello): per ogni non conformita' aperta, i lotti di prodotto finito
    // raggiunti divisi fra "in magazzino" e "non piu' in magazzino", poi i
    // clienti/spedizioni. Legge gli output COMPLETI dei passi riusciti di
    // apri_non_conformita_materia_prima e trova_ordini_spedizioni_lotto_prodotto_finito.
    // Stringa vuota se il piano non ha nessuno dei due: allora la risposta
    // resta quella del Synthesizer, come prima.
    // ASoloRitiro = True se TUTTI i passi del piano sono i due del ritiro e
    // sono riusciti: allora il blocco e' l'intera risposta (compresa una
    // domanda finale fissa) e il modello non serve. Altrimenti (piani con
    // altri passi, es. le email) il blocco e' solo la prima parte.
    class function BloccoRiepilogoRitiro(AEsecuzione: TEsitoEsecuzione;
      out ASoloRitiro: Boolean): string;
    // Come TestoPianoNonValido, ma se il piano e' stato fermato perche' un
    // codice (es. della non conformita') non compare nella richiesta, dice
    // all'utente quale dato manca invece del messaggio generico.
    class function TestoPianoNonValidoPer(const AErrori: TArray<TErroreValidazione>): string;
    class function TestoAnnullata: string;
    // Testo fisso quando l'utente rifiuta una proposta dell'assistente.
    class function TestoPropostaRifiutata: string;
  end;

// Testo JSON come json.dumps(..., ensure_ascii=False, indent=1) di Python:
// un elemento per riga, rientro di uno spazio per livello.
function JSONIndentatoComePython(AValore: TJSONValue; ALivello: Integer = 0): string;

implementation

uses
  System.Generics.Defaults,
  System.StrUtils,
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


const
  TOOL_APRI_NC = 'apri_non_conformita_materia_prima';
  TOOL_SPEDIZIONI = 'trova_ordini_spedizioni_lotto_prodotto_finito';

  // Istruzioni aggiunte al Synthesizer quando il riepilogo dei dati e' gia'
  // stato scritto dal server (vedi BloccoRiepilogoRitiro): il modello non
  // deve rifare l'elenco, solo commentarlo. Cosi' i dati (codici, lotti,
  // giacenze) non dipendono da come il modello li riformula.
  ISTRUZIONI_COMMENTO =
    #10 +
    'RIEPILOGO GIA'' MOSTRATO'#10 +
    'Per i passi il cui output e'' "mostrato nel riepilogo" il server ha gia'' mostrato all''utente un ' +
    'riepilogo fisso, che trovi in fondo. Tu scrivi SOLO un commento di al massimo due frasi: cosa fare ' +
    'dopo o cosa merita attenzione (ad esempio i lotti ancora in magazzino da bloccare, o i clienti da ' +
    'avvisare). NON ripetere codici, lotti, quantita'', prodotti o clienti e non fare elenchi. Se un altro ' +
    'passo ha prodotto risultati (ad esempio le email), puoi citarlo. Se non hai nulla da aggiungere ' +
    'rispondi soltanto: NESSUN_COMMENTO'#10;

// --- Lettura dei campi di un oggetto JSON, senza eccezioni se manca ---------

function CampoStringa(AObj: TJSONObject; const ANome: string): string;
var
  LValore: TJSONValue;
begin
  Result := '';
  if AObj = nil then
    Exit;
  LValore := AObj.GetValue(ANome);
  if (LValore <> nil) and not (LValore is TJSONNull) then
    Result := LValore.Value;
end;

function CampoNumero(AObj: TJSONObject; const ANome: string): Double;
var
  LValore: TJSONValue;
begin
  Result := 0;
  if AObj = nil then
    Exit;
  LValore := AObj.GetValue(ANome);
  if LValore is TJSONNumber then
    Result := TJSONNumber(LValore).AsDouble;
end;

function CampoVero(AObj: TJSONObject; const ANome: string): Boolean;
var
  LValore: TJSONValue;
begin
  Result := False;
  if AObj = nil then
    Exit;
  LValore := AObj.GetValue(ANome);
  if LValore is TJSONBool then
    Result := TJSONBool(LValore).AsBoolean;
end;

function CampoElenco(AObj: TJSONObject; const ANome: string): TJSONArray;
var
  LValore: TJSONValue;
begin
  Result := nil;
  if AObj = nil then
    Exit;
  LValore := AObj.GetValue(ANome);
  if LValore is TJSONArray then
    Result := TJSONArray(LValore);
end;

// --- Formattazione per l'utente (italiano, indipendente dal sistema) --------

// 85 -> "85", 0.8 -> "0,8", 1013.2 -> "1.013,2".
function NumeroIt(AValore: Double): string;
var
  LFormato: TFormatSettings;
begin
  LFormato := TFormatSettings.Create('it-IT');
  Result := FormatFloat('#,##0.##', AValore, LFormato);
end;

// "2026-12-02" -> "02/12/2026"; un valore diverso resta com'e'.
function DataIt(const AIso: string): string;
begin
  if (Length(AIso) = 10) and (AIso[5] = '-') and (AIso[8] = '-') then
    Result := Copy(AIso, 9, 2) + '/' + Copy(AIso, 6, 2) + '/' + Copy(AIso, 1, 4)
  else
    Result := AIso;
end;

// Elementi di AElenco (oggetti) ordinati per il campo testuale ACampo, cosi'
// lo stesso input da' sempre lo stesso testo.
function OggettiOrdinati(AElenco: TJSONArray; const ACampo: string): TArray<TJSONObject>;
var
  LLista: TList<TJSONObject>;
  i: Integer;
begin
  LLista := TList<TJSONObject>.Create;
  try
    if AElenco <> nil then
      for i := 0 to AElenco.Count - 1 do
        if AElenco.Items[i] is TJSONObject then
          LLista.Add(TJSONObject(AElenco.Items[i]));
    LLista.Sort(TComparer<TJSONObject>.Construct(
      function(const A, B: TJSONObject): Integer
      begin
        Result := CompareStr(CampoStringa(A, ACampo), CampoStringa(B, ACampo));
      end));
    Result := LLista.ToArray;
  finally
    LLista.Free;
  end;
end;

// Riga di tabella Markdown: "| LPF-PF001-002 | Panettone Classico 1kg (PF001) | 85 kg | 02/12/2026 |"
function RigaTabellaLotto(ALotto: TJSONObject): string;
begin
  Result := '| ' + CampoStringa(ALotto, 'codice_lotto') + ' | ' +
    CampoStringa(ALotto, 'denominazione_prodotto') +
    ' (' + CampoStringa(ALotto, 'codice_prodotto') + ') | ' +
    NumeroIt(CampoNumero(ALotto, 'quantita_disponibile')) + ' ' +
    CampoStringa(ALotto, 'unita_misura') + ' | ' +
    DataIt(CampoStringa(ALotto, 'data_scadenza')) + ' |';
end;

// Tabella dei lotti di prodotto finito (intestazione + righe). Le tabelle
// sono lette dal Markdown della chat (components/markdown.js, tabelle GFM):
// quattro colonne si leggono meglio di una riga di testo per lotto.
procedure ScriviTabellaLotti(ALotti: TList<TJSONObject>; ARighe: TList<string>);
var
  LLotto: TJSONObject;
begin
  ARighe.Add('| Lotto | Prodotto | Disponibile | Scadenza |');
  ARighe.Add('|---|---|---:|---|');
  for LLotto in ALotti do
    ARighe.Add(RigaTabellaLotto(LLotto));
end;

// Parte "non conformita' e lotti raggiunti" del riepilogo.
procedure ScriviRiepilogoNC(AOutput: TJSONObject; ARighe: TList<string>);
var
  LNC, LLotto: TJSONObject;
  LInMagazzino, LFuori: TList<TJSONObject>;
begin
  for LNC in OggettiOrdinati(CampoElenco(AOutput, 'non_conformita_aperte'),
    'codice_non_conformita') do
  begin
    ARighe.Add('**Non conformit'#$00E0' ' + CampoStringa(LNC, 'codice_non_conformita') +
      '** - lotto di materia prima ' + CampoStringa(LNC, 'codice_lotto_materia_prima'));
    ARighe.Add('');

    LInMagazzino := TList<TJSONObject>.Create;
    LFuori := TList<TJSONObject>.Create;
    try
      for LLotto in OggettiOrdinati(CampoElenco(LNC, 'dettaglio_lotti_prodotto_finito'),
        'codice_lotto') do
        if CampoVero(LLotto, 'in_magazzino') then
          LInMagazzino.Add(LLotto)
        else
          LFuori.Add(LLotto);

      if LInMagazzino.Count + LFuori.Count = 0 then
      begin
        ARighe.Add('Nessun lotto di prodotto finito raggiunto.');
        ARighe.Add('');
        Continue;
      end;

      ARighe.Add(Format('Lotti di prodotto finito raggiunti: **%d** (in magazzino: %d).',
        [LInMagazzino.Count + LFuori.Count, LInMagazzino.Count]));
      ARighe.Add('');
      if LInMagazzino.Count > 0 then
      begin
        ARighe.Add('**In magazzino**');
        ARighe.Add('');
        ScriviTabellaLotti(LInMagazzino, ARighe);
        ARighe.Add('');
      end;
      if LFuori.Count > 0 then
      begin
        ARighe.Add('**Non pi'#$00F9' in magazzino**');
        ARighe.Add('');
        ScriviTabellaLotti(LFuori, ARighe);
        ARighe.Add('');
      end;
    finally
      LInMagazzino.Free;
      LFuori.Free;
    end;
  end;
end;

// Parte "clienti e spedizioni" del riepilogo: UNA tabella con una riga per
// ordine (non un blocco per lotto), poi i lotti senza ordini su una riga e il
// conteggio dei clienti. Restituisce quanti clienti diversi sono coinvolti.
function ScriviRiepilogoSpedizioni(AOutput: TJSONObject; ARighe: TList<string>): Integer;
var
  LLotto, LOrdine, LSpedizione: TJSONObject;
  LOrdini, LSpedizioni: TArray<TJSONObject>;
  LSenzaOrdini, LSpediti, LNonSpediti, LTutti: TList<string>;
  LStato, LCliente: string;
begin
  LSenzaOrdini := TList<string>.Create;
  LSpediti := TList<string>.Create;
  LNonSpediti := TList<string>.Create;
  LTutti := TList<string>.Create;
  try
    ARighe.Add('**Clienti e spedizioni**');
    ARighe.Add('');
    ARighe.Add('| Lotto | Cliente | Ordine | Stato |');
    ARighe.Add('|---|---|---|---|');
    for LLotto in OggettiOrdinati(CampoElenco(AOutput, 'lotti'), 'codice_lotto') do
    begin
      LOrdini := OggettiOrdinati(CampoElenco(LLotto, 'ordini'), 'numero_ordine');
      if Length(LOrdini) = 0 then
        LSenzaOrdini.Add(CampoStringa(LLotto, 'codice_lotto'));
      for LOrdine in LOrdini do
      begin
        LCliente := CampoStringa(LOrdine, 'ragione_sociale_cliente');
        LSpedizioni := OggettiOrdinati(CampoElenco(LOrdine, 'spedizioni'), 'numero_ddt');
        if Length(LSpedizioni) = 0 then
        begin
          LStato := 'Non ancora spedito (ordinati ' +
            NumeroIt(CampoNumero(LOrdine, 'quantita')) + ')';
          if not LNonSpediti.Contains(LCliente) then
            LNonSpediti.Add(LCliente);
        end
        else
        begin
          LStato := 'Spedito';
          for LSpedizione in LSpedizioni do
            LStato := LStato + ' - DDT ' + CampoStringa(LSpedizione, 'numero_ddt') + ' del ' +
              DataIt(CampoStringa(LSpedizione, 'data_spedizione')) + ' (' +
              NumeroIt(CampoNumero(LSpedizione, 'quantita_spedita')) + ')';
          if not LSpediti.Contains(LCliente) then
            LSpediti.Add(LCliente);
        end;
        if not LTutti.Contains(LCliente) then
          LTutti.Add(LCliente);
        ARighe.Add('| ' + CampoStringa(LLotto, 'codice_lotto') + ' | ' + LCliente + ' | ' +
          CampoStringa(LOrdine, 'numero_ordine') + ' | ' + LStato + ' |');
      end;
    end;
    Result := LTutti.Count;

    if Result = 0 then
    begin
      // Niente righe: la tabella vuota non si mostra.
      ARighe.DeleteRange(ARighe.Count - 4, 4);
      ARighe.Add('**Clienti e spedizioni**');
      ARighe.Add('');
      ARighe.Add('Nessun ordine collegato ai lotti raggiunti.');
    end
    else
    begin
      ARighe.Add('');
      ARighe.Add(Format('Clienti coinvolti: **%d** (merce gi'#$00E0' spedita: %d, ordini non ancora spediti: %d).',
        [LTutti.Count, LSpediti.Count, LNonSpediti.Count]));
      if LSenzaOrdini.Count > 0 then
      begin
        ARighe.Add('');
        ARighe.Add('Lotti senza ordini collegati: ' + string.Join(', ', LSenzaOrdini.ToArray) + '.');
      end;
    end;
    ARighe.Add('');
  finally
    LSenzaOrdini.Free;
    LSpediti.Free;
    LNonSpediti.Free;
    LTutti.Free;
  end;
end;

// Il primo passo RIUSCITO di quel tool, o nil.
function PassoRiuscito(AEsecuzione: TEsitoEsecuzione; const ATool: string): TEsitoPasso;
var
  LEsito: TEsitoPasso;
begin
  Result := nil;
  if AEsecuzione = nil then
    Exit;
  for LEsito in AEsecuzione.Esiti do
    if (LEsito.Tool = ATool) and (LEsito.Esito = 'ok') and (LEsito.Output <> nil) then
      Exit(LEsito);
end;

{ TSintesiRisposta }

class function TSintesiRisposta.RichiestaSintesi(const ADomanda, AOggi: string; APiano: TPiano;
  AEsecuzione: TEsitoEsecuzione; AArrestoPreventivo: TJSONObject;
  const ARiepilogoMostrato: string): TJSONObject;
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
        // Se il riepilogo e' gia' stato scritto dal server, i dati dei due tool
        // del ritiro non si rimandano al modello: li riformulerebbe.
        if (ARiepilogoMostrato <> '') and (LEsito.Esito = 'ok') and
           ((LEsito.Tool = TOOL_APRI_NC) or (LEsito.Tool = TOOL_SPEDIZIONI)) then
          LVoce.AddPair('output', 'mostrato nel riepilogo')
        else if LEsito.Output <> nil then
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
          if (ARiepilogoMostrato <> '') and (LEsito.Esito = 'ok') and
             ((LEsito.Tool = TOOL_APRI_NC) or (LEsito.Tool = TOOL_SPEDIZIONI)) then
            Continue;                   // il suo output e' solo la scritta "mostrato nel riepilogo"
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
      .AddPair('content', TPianificatore.PromptBase(AOggi) + PROMPT_SEZIONE_SINTESI +
        IfThen(ARiepilogoMostrato <> '', ISTRUZIONI_COMMENTO, '')));
    LMessaggi.AddElement(TJSONObject.Create
      .AddPair('role', 'user')
      .AddPair('content', PROMPT_MESSAGGIO_SINTESI_RICHIESTA + ADomanda +
        PROMPT_MESSAGGIO_SINTESI_ESECUZIONE + JSONIndentatoComePython(LDati) +
        IfThen(ARiepilogoMostrato <> '',
          #10#10'RIEPILOGO GIA'' MOSTRATO ALL''UTENTE:'#10 + ARiepilogoMostrato, '')));

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

class function TSintesiRisposta.TestoPianoNonValidoPer(
  const AErrori: TArray<TErroreValidazione>): string;
var
  LErrore: TErroreValidazione;
  LCampo, LDato: string;
  LMancanti: TList<string>;
begin
  // VALORE_NON_ANCORATO su un codice = il modello ha scritto un codice che
  // l'utente non ha mai detto (tipico: ha copiato un esempio della
  // descrizione del tool o ne ha inventato uno). Non e' un piano "sbagliato":
  // manca un dato, e la cosa utile e' chiederlo. Il messaggio d'errore del
  // validatore ha la forma  campo="valore" non compare ...
  LMancanti := TList<string>.Create;
  try
    for LErrore in AErrori do
    begin
      if LErrore.Codice <> 'VALORE_NON_ANCORATO' then
        Continue;
      LCampo := Copy(LErrore.Messaggio, 1, Pos('=', LErrore.Messaggio) - 1);
      if LCampo = 'codice_non_conformita_base' then
        LDato := 'il codice della non conformita'''
      else if LCampo = 'codici_lotto_materia_prima' then
        LDato := 'il codice del lotto di materia prima'
      else if LCampo = 'codice_nuovo_prodotto' then
        LDato := 'il codice del nuovo prodotto'
      else
        Continue;
      if not LMancanti.Contains(LDato) then
        LMancanti.Add(LDato);
    end;
    if LMancanti.Count = 0 then
      Exit(MESSAGGIO_PIANO_NON_VALIDO);
    Result := 'Per procedere mi serve ' + string.Join(' e ', LMancanti.ToArray) +
      ', che non trovo nella tua richiesta. Indicamelo e proseguo.';
  finally
    LMancanti.Free;
  end;
end;

class function TSintesiRisposta.BloccoRiepilogoRitiro(AEsecuzione: TEsitoEsecuzione;
  out ASoloRitiro: Boolean): string;
var
  LApertura, LSpedizioni: TEsitoPasso;
  LEsito: TEsitoPasso;
  LRighe: TList<string>;
  LClienti, LLotti: Integer;
  LArrayLotti: TJSONArray;
begin
  Result := '';
  ASoloRitiro := False;
  LApertura := PassoRiuscito(AEsecuzione, TOOL_APRI_NC);
  LSpedizioni := PassoRiuscito(AEsecuzione, TOOL_SPEDIZIONI);
  if (LApertura = nil) and (LSpedizioni = nil) then
    Exit;

  // "Solo ritiro": nessun passo diverso dai due tool, e tutti riusciti.
  ASoloRitiro := True;
  for LEsito in AEsecuzione.Esiti do
    if not (((LEsito.Tool = TOOL_APRI_NC) or (LEsito.Tool = TOOL_SPEDIZIONI)) and
            (LEsito.Esito = 'ok')) then
      ASoloRitiro := False;

  LClienti := 0;
  LRighe := TList<string>.Create;
  try
    if LApertura <> nil then
      ScriviRiepilogoNC(LApertura.Output, LRighe);
    if LSpedizioni <> nil then
      LClienti := ScriviRiepilogoSpedizioni(LSpedizioni.Output, LRighe);

    // Domanda finale FISSA, al posto del commento del modello (che con un
    // modello piccolo poteva contraddire i dati appena mostrati). Solo se il
    // blocco e' tutta la risposta.
    if ASoloRitiro then
    begin
      if LSpedizioni <> nil then
      begin
        if LClienti > 0 then
          LRighe.Add('Vuoi che ti mostri l''anteprima delle email per i clienti coinvolti?');
      end
      else
      begin
        LLotti := 0;
        LArrayLotti := CampoElenco(LApertura.Output, 'dettaglio_lotti_prodotto_finito');
        if LArrayLotti <> nil then
          LLotti := LArrayLotti.Count;
        if LLotti > 0 then
          LRighe.Add('Vuoi che verifichi a quali clienti sono stati spediti questi lotti?');
      end;
    end;
    Result := Trim(string.Join(#10, LRighe.ToArray));
  finally
    LRighe.Free;
  end;
end;

class function TSintesiRisposta.TestoAnnullata: string;
begin
  Result := 'Operazione annullata: nel gestionale non e'' stato modificato nulla.';
end;

class function TSintesiRisposta.TestoPropostaRifiutata: string;
begin
  Result := 'Va bene, non procedo. Dimmi pure di cosa hai bisogno.';
end;

end.
