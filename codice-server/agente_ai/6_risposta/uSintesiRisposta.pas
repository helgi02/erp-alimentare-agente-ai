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
  System.RegularExpressions,
  uPianificatore,
  uValidatorePiano,
  uEsecutorePiano;

const
  // Domanda finale FISSA del riepilogo di ritiro quando ci sono clienti
  // coinvolti. E' pubblica perche' il turno successivo la riconosce: se
  // l'utente risponde "si'", il piano non lo scrive il modello ma il codice
  // (TTurnoPianificato.PianoAnteprimaEmail).
  PROPOSTA_ANTEPRIMA_EMAIL = 'Vuoi che ti mostri l''anteprima delle email per i clienti coinvolti?';

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
    // ESITO DI UN INVIO EMAIL (20/10), scritto dal codice come il riepilogo
    // del ritiro: prima la frase complessiva del tool ("Email inviate: 4 su
    // 5", con l'avviso se l'invio e' simulato), poi una riga per email.
    // Se l'invio e' fallito del tutto, il motivo. Stringa vuota se nel piano
    // non c'e' un invio. ASoloInvio = True se TUTTI i passi eseguiti sono
    // invii: allora il blocco e' l'intera risposta e il modello non serve.
    class function BloccoEsitoInvio(AEsecuzione: TEsitoEsecuzione;
      out ASoloInvio: Boolean): string;
    // SCELTA DELLE SOSTITUZIONI (20/10, scenario 3, primo turno). Quando il piano
    // ha solo letto la ricetta e cercato i candidati senza un allergene, la
    // risposta la scrive il codice: ingredienti della ricetta che contengono
    // l'allergene, quanti candidati ci sono, e l'invito a usare il modulo
    // della chat. Il modello, lasciato libero, scriveva "ho simulato" (non era
    // vero), inventava il nome del nuovo prodotto (lo sceglie l'utente nel
    // modulo di conferma) e chiedeva "vuoi applicare?" saltando la simulazione.
    // ASoloRicerca = True se TUTTI i passi sono questi due e sono riusciti:
    // allora il blocco e' l'intera risposta e il modello non serve.
    class function BloccoSceltaSostituzioni(AEsecuzione: TEsitoEsecuzione;
      out ASoloRicerca: Boolean): string;
    // ESITO DELLA SIMULAZIONE (20/10, scenario 3, secondo turno). Costi,
    // allergeni, unita' producibili e prezzo suggerito li scrive il codice
    // dal risultato del tool: il modello, lasciato libero, copiava i numeri
    // con segni sbagliati ("risparmio -0,32") e li presentava a modo suo.
    // ASoloSimulazione = True se TUTTI i passi sono simulazioni riuscite:
    // allora il blocco e' l'intera risposta e il modello non serve.
    class function BloccoEsitoSimulazione(AEsecuzione: TEsitoEsecuzione;
      out ASoloSimulazione: Boolean): string;
    // FEEDBACK 19/10 (punto 2), controllo sul testo. True se nel turno non e'
    // riuscita nessuna scrittura ma ATesto dichiara un salvataggio/creazione
    // avvenuti (es. "e' stata creata", "salvata nel gestionale").
    class function DichiaraScritturaNonAvvenuta(const ATesto: string;
      AEsecuzione: TEsitoEsecuzione): Boolean;
    class function NotaNessunaScrittura: string;
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
  uContrattiTool,
  uSchemaJSON,
  uStoricoTurni,
  uPromptPianificatore,
  // Solo per TestoConferma (20/10): tradurre gli id di prodotti e
  // componenti nei loro nomi. Sono letture puntuali in anagrafica; e'
  // l'unico punto di questa unit che legge il database.
  uModelProdottoFinito,
  uModelMateriaPrima,
  uModelSemilavorato;

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
  TOOL_RICETTA = 'get_ricetta_prodotto_finito';
  TOOL_CERCA_COMPONENTI = 'cerca_componenti_ricetta';
  TOOL_SIMULA = 'simula_adattamento_ricetta';

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

  // FEEDBACK 19/10 (punto 2): istruzione aggiunta al Synthesizer quando nel
  // turno NON e' riuscito nessun tool di scrittura (es. e' stata eseguita
  // solo la simulazione dell'adattamento ricetta, o la scrittura e' ferma in
  // attesa di conferma). In una prova su sei il modello aveva scritto "la
  // variante e' stata salvata nel gestionale" dopo la sola simulazione.
  // E' la prima difesa; la seconda e' il controllo sul testo in
  // TTurnoPianificato.PassoSintesi (vedi DichiaraScrittura).
  ISTRUZIONI_NESSUNA_SCRITTURA =
    #10 +
    'NESSUNA SCRITTURA IN QUESTO TURNO'#10 +
    'In questo turno nel gestionale NON e'' stato creato, salvato, modificato, registrato o inviato ' +
    'nulla ("scritture_eseguite": false). Non scrivere che qualcosa e'' stato creato, salvato, aperto, ' +
    'registrato o inviato. Se e'' stata fatta una simulazione, dillo chiaramente ("simulazione", ' +
    '"nulla e'' stato salvato") e, se serve, chiedi se procedere con il salvataggio.'#10;

// True se almeno un passo di SCRITTURA (secondo il contratto del tool) e'
// stato eseguito con esito positivo in questo turno. Una scrittura ferma in
// CONFERMA_RICHIESTA non conta: non e' ancora avvenuta.
function ScritturaEseguita(AEsecuzione: TEsitoEsecuzione): Boolean;
var
  LEsito: TEsitoPasso;
  LContratto: TContrattoTool;
begin
  Result := False;
  if AEsecuzione = nil then
    Exit;
  for LEsito in AEsecuzione.Esiti do
    if (LEsito.Esito = 'ok') and TRegistroContrattiTool.Trova(LEsito.Tool, LContratto) and
       (LContratto.Effetto = etScrittura) then
      Exit(True);
end;

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

// FEEDBACK 20/10 (prova vendite): il modello scriveva "Il gestionale ha gia'
// aperto la schermata" mentre sotto la risposta c'era solo un PULSANTE, anche se
// il prompt gli vietava di nominare schermata e pulsante. Un divieto scritto nel
// prompt non e' una garanzia (Qwen 9B non lo rispetta sempre): se non vuole che
// il modello ne parli, il dato non gli si deve dare. Il frontend riceve il
// risultato completo dal campo tool_calls della risposta e costruisce il
// pulsante da li'; qui si toglie solo la COPIA mandata al Synthesizer.
// Si tolgono "apertura_vista" / "aperture_vista" quando sono TUTTE in modalita'
// "pulsante". Una vista aperta direttamente (senza "modalita") resta, perche'
// in quel caso la schermata si apre davvero e il modello puo' dirlo.
// AValore e' una copia gia' ridotta, di proprieta' del chiamante: si modifica
// sul posto e la si restituisce.
function TogliVistePulsante(AValore: TJSONValue): TJSONValue;
var
  LObj: TJSONObject;
  LVista: TJSONValue;
  LArray: TJSONArray;
  LElemento: TJSONValue;
  LTutte: Boolean;
  LPulsante: string;
  LCoppia: TJSONPair;
begin
  Result := AValore;
  if not (AValore is TJSONObject) then
    Exit;
  LObj := TJSONObject(AValore);

  // Una sola vista: {"vista":..., "modalita":"pulsante", "parametri":...}
  LVista := LObj.GetValue('apertura_vista');
  if (LVista is TJSONObject) and
     TJSONObject(LVista).TryGetValue<string>('modalita', LPulsante) and
     (LPulsante = 'pulsante') then
  begin
    LCoppia := LObj.RemovePair('apertura_vista');
    LCoppia.Free;
  end;

  // Piu' viste (es. una per ogni non conformita' aperta).
  LVista := LObj.GetValue('aperture_vista');
  if (LVista is TJSONArray) then
  begin
    LArray := TJSONArray(LVista);
    LTutte := LArray.Count > 0;
    for LElemento in LArray do
      if not ((LElemento is TJSONObject) and
              TJSONObject(LElemento).TryGetValue<string>('modalita', LPulsante) and
              (LPulsante = 'pulsante')) then
        LTutte := False;
    if LTutte then
    begin
      LCoppia := LObj.RemovePair('aperture_vista');
      LCoppia.Free;
    end;
  end;
end;

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
          LVoce.AddPair('output', TogliVistePulsante(RiduciOutput(LEsito.Output, 50, True)))
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
            LVoce.AddPair('output', TogliVistePulsante(RiduciOutput(LEsito.Output, RIDUZIONI[j], True)));
          end;
        end;
      end;

    if AArrestoPreventivo <> nil then
      LDati.AddPair('arresto', AArrestoPreventivo.Clone as TJSONValue);

    // FEEDBACK 19/10 (punto 2): il modello deve sapere, come FATTO e non da
    // dedurre, se nel turno qualcosa e' stato scritto nel gestionale.
    LDati.AddPair('scritture_eseguite', TJSONBool.Create(ScritturaEseguita(AEsecuzione)));

    LMessaggi := TJSONArray.Create;
    LMessaggi.AddElement(TJSONObject.Create
      .AddPair('role', 'system')
      .AddPair('content', TPianificatore.PromptBase(AOggi) + PROMPT_SEZIONE_SINTESI +
        IfThen(ARiepilogoMostrato <> '', ISTRUZIONI_COMMENTO, '') +
        IfThen(not ScritturaEseguita(AEsecuzione), ISTRUZIONI_NESSUNA_SCRITTURA, '')));
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

// --- Richiesta di conferma in forma leggibile (20/10) ---------------------
// Prima: "Operazione: applica_adattamento_ricetta / Dati: {JSON}". Ora una
// frase per operazione, con i nomi al posto degli id. L'utente conferma
// QUELLO che legge, quindi il testo deve descrivere esattamente gli
// argomenti che verranno usati: nessun dato e' omesso o riassunto, cambia
// solo la forma. Tool di scrittura non previsti qui: elenco "campo: valore"
// generico, comunque senza JSON.

function NomeProdottoFinito(const AIDTesto: string): string;
var
  LID: Integer;
  LProdotto: TProdottoFinito;
begin
  Result := AIDTesto;                   // codice o testo: si mostra com'e'
  if not TryStrToInt(Trim(AIDTesto), LID) then
    Exit;
  try
    LProdotto := TProdottoFinito.GetByID(LID);
    if LProdotto <> nil then
      try
        Result := LProdotto.Denominazione + ' (' + LProdotto.Codice + ')';
      finally
        LProdotto.Free;
      end;
  except
    // Lettura non riuscita: resta l'id, la conferma non deve fallire.
  end;
end;

function NomeComponente(const ATipo: string; AID: Integer): string;
var
  LMateria: TMateriaPrima;
  LSemi: TSemilavorato;
begin
  Result := Format('componente %d', [AID]);
  try
    if ATipo = 'semilavorato' then
    begin
      LSemi := TSemilavorato.GetByID(AID);
      if LSemi <> nil then
        try
          Result := LSemi.Denominazione;
        finally
          LSemi.Free;
        end;
    end
    else
    begin
      LMateria := TMateriaPrima.GetByID(AID);
      if LMateria <> nil then
        try
          Result := LMateria.Denominazione;
        finally
          LMateria.Free;
        end;
    end;
  except
  end;
end;

// Il componente di una sostituzione/aggiunta: il nome se il modello l'ha
// scritto (ANomeChiave), altrimenti l'id tradotto (AIdChiave + ATipoChiave).
function ComponenteDi(AObj: TJSONObject; const ANomeChiave, AIdChiave, ATipoChiave: string): string;
var
  LID: Integer;
begin
  Result := CampoStringa(AObj, ANomeChiave);
  if Result <> '' then
    Exit;
  if TryStrToInt(CampoStringa(AObj, AIdChiave), LID) then
    Result := NomeComponente(CampoStringa(AObj, ATipoChiave), LID)
  else
    Result := '?';
end;

function QuantitaDi(AObj: TJSONObject; const AQuantita, AUnita: string): string;
begin
  Result := '';
  if CampoStringa(AObj, AQuantita) <> '' then
    Result := Trim(NumeroIt(CampoNumero(AObj, AQuantita)) + ' ' + CampoStringa(AObj, AUnita));
end;

// Valore qualsiasi in testo semplice: array di valori -> "a, b"; oggetto ->
// "chiave: valore; ..."; mai parentesi graffe.
function ValoreInTesto(AValore: TJSONValue): string;
var
  LPezzi: TList<string>;
  LElemento: TJSONValue;
  LCoppia: TJSONPair;
begin
  if (AValore = nil) or (AValore is TJSONNull) then
    Exit('');
  if not ((AValore is TJSONArray) or (AValore is TJSONObject)) then
    Exit(AValore.Value);
  LPezzi := TList<string>.Create;
  try
    if AValore is TJSONArray then
      for LElemento in TJSONArray(AValore) do
        LPezzi.Add(ValoreInTesto(LElemento))
    else
      for LCoppia in TJSONObject(AValore) do
        LPezzi.Add(StringReplace(LCoppia.JsonString.Value, '_', ' ', [rfReplaceAll]) + ': ' +
          ValoreInTesto(LCoppia.JsonValue));
    if AValore is TJSONArray then
      Result := string.Join(', ', LPezzi.ToArray)
    else
      Result := string.Join('; ', LPezzi.ToArray);
  finally
    LPezzi.Free;
  end;
end;

class function TSintesiRisposta.TestoConferma(const ATool: string; AArgomenti: TJSONObject): string;
var
  LRighe: TList<string>;
  LElenco: TJSONArray;
  LVoce: TJSONValue;
  LObj, LVariabili: TJSONObject;
  LQuantita, LProdotto, LDestinatario: string;
  LCoppia: TJSONPair;
begin
  LRighe := TList<string>.Create;
  try
    LRighe.Add('Per procedere serve la tua conferma, perche'' l''operazione modifica i dati del gestionale.');
    LRighe.Add('');

    if ATool = 'apri_non_conformita_materia_prima' then
    begin
      LRighe.Add('Apro la non conformita'' ' + CampoStringa(AArgomenti, 'codice_non_conformita_base'));
      LRighe.Add('- Lotti di materia prima: ' + ValoreInTesto(AArgomenti.GetValue('codici_lotto_materia_prima')));
      LRighe.Add('- Motivo: ' + CampoStringa(AArgomenti, 'motivo_non_conformita'));
    end

    else if ATool = 'applica_adattamento_ricetta' then
    begin
      LProdotto := CampoStringa(AArgomenti, 'nome_prodotto');
      if CampoStringa(AArgomenti, 'prodotto_finito_id') <> '' then
        LProdotto := NomeProdottoFinito(CampoStringa(AArgomenti, 'prodotto_finito_id'));
      LRighe.Add('Salvo l''adattamento della ricetta di ' + LProdotto);
      LElenco := CampoElenco(AArgomenti, 'sostituzioni');
      if LElenco <> nil then
        for LVoce in LElenco do
          if LVoce is TJSONObject then
          begin
            LObj := TJSONObject(LVoce);
            LQuantita := QuantitaDi(LObj, 'nuova_quantita', 'nuova_unita_misura');
            LRighe.Add('- Sostituisco ' + ComponenteDi(LObj, 'vecchio_nome', 'vecchio_id', 'vecchio_tipo') +
              ' con ' + ComponenteDi(LObj, 'nuovo_nome', 'nuovo_id', 'nuovo_tipo') +
              IfThen(LQuantita <> '', ' (' + LQuantita + ')', ''));
          end;
      LElenco := CampoElenco(AArgomenti, 'aggiunte');
      if LElenco <> nil then
        for LVoce in LElenco do
          if LVoce is TJSONObject then
          begin
            LObj := TJSONObject(LVoce);
            LQuantita := QuantitaDi(LObj, 'quantita', 'unita_misura');
            LRighe.Add('- Aggiungo ' + ComponenteDi(LObj, 'nome', 'id', 'tipo') +
              IfThen(LQuantita <> '', ' (' + LQuantita + ')', ''));
          end;
      if CampoStringa(AArgomenti, 'codice_nuovo_prodotto') <> '' then
        LRighe.Add('- Nuovo prodotto: ' + CampoStringa(AArgomenti, 'denominazione_nuovo_prodotto') +
          ' (' + CampoStringa(AArgomenti, 'codice_nuovo_prodotto') + ')')
      else
        LRighe.Add('- Nuovo prodotto: non indicato (se non esiste gia'' una variante compatibile ' +
          'ti chiedero'' codice e denominazione)');
    end

    else if ATool = 'invia_email' then
    begin
      LRighe.Add('Invio un''email');
      LRighe.Add('- A: ' + ValoreInTesto(AArgomenti.GetValue('destinatari')));
      LRighe.Add('- Oggetto: ' + CampoStringa(AArgomenti, 'oggetto'));
      LRighe.Add('- Testo:');
      LRighe.Add(CampoStringa(AArgomenti, 'corpo'));
    end

    else if ATool = 'invia_email_da_modello' then
    begin
      LElenco := CampoElenco(AArgomenti, 'messaggi');
      if LElenco <> nil then
        LRighe.Add(Format('Invio %d email (testi come nell''anteprima):', [LElenco.Count]))
      else
        LRighe.Add('Invio le email');
      if LElenco <> nil then
        for LVoce in LElenco do
          if LVoce is TJSONObject then
          begin
            LObj := TJSONObject(LVoce);
            LDestinatario := CampoStringa(LObj, 'email');
            if LObj.GetValue('variabili') is TJSONObject then
            begin
              LVariabili := TJSONObject(LObj.GetValue('variabili'));
              if CampoStringa(LVariabili, 'ragione_sociale') <> '' then
                LDestinatario := CampoStringa(LVariabili, 'ragione_sociale') + ' <' + LDestinatario + '>';
            end;
            LRighe.Add('- ' + LDestinatario);
          end;
    end

    else
    begin
      // Tool di scrittura non previsto sopra: elenco generico.
      LRighe.Add('Operazione: ' + StringReplace(ATool, '_', ' ', [rfReplaceAll]));
      if AArgomenti <> nil then
        for LCoppia in AArgomenti do
          LRighe.Add('- ' + StringReplace(LCoppia.JsonString.Value, '_', ' ', [rfReplaceAll]) + ': ' +
            ValoreInTesto(LCoppia.JsonValue));
    end;

    if (AArgomenti <> nil) and (CampoStringa(AArgomenti, 'creato_da') <> '') and
       (ATool <> 'invia_email') and (ATool <> 'invia_email_da_modello') then
      LRighe.Add('- Autorizzato da: ' + CampoStringa(AArgomenti, 'creato_da'));

    LRighe.Add('');
    LRighe.Add('Confermi?');
    Result := string.Join(#10, LRighe.ToArray);
  finally
    LRighe.Free;
  end;
end;

// --- Disambiguazione in forma leggibile (20/10) -------------------------
// Prima ogni candidato era stampato come JSON grezzo
// ({"id": 3, "codice": "PF003", ...}) e la riga del problema riportava il
// nome tecnico del parametro ("nome_prodotto"). L'utente non deve vedere
// ne' l'uno ne' l'altro: i pulsanti di scelta della chat (che usano gli id)
// restano, il testo diventa una frase per problema e una riga per candidato.

// Come chiamare il parametro in italiano. Un campo non previsto (tool nuovo)
// prende una descrizione generica invece del nome tecnico.
function DescriviCampo(const ACampo: string): string;
begin
  if (ACampo = 'nome_prodotto') or (ACampo = 'prodotto_finito_id') then
    Result := 'prodotto'
  else if ACampo = 'ragione_sociale_cliente' then
    Result := 'cliente'
  else if ACampo = 'codici_lotto_materia_prima' then
    Result := 'lotto di materia prima'
  else if ACampo = 'vecchio_nome' then
    Result := 'componente da sostituire'
  else if ACampo = 'nuovo_nome' then
    Result := 'componente sostitutivo'
  else if ACampo = 'nome' then
    Result := 'componente da aggiungere'
  else
    Result := 'valore';
end;

// Una riga leggibile per un candidato, qualunque tool l'abbia prodotto.
// Forme note: prodotto {codice, denominazione}; componente {tipo, codice,
// denominazione}; cliente {ragione_sociale, partita_iva?}; lotto
// {codice_lotto, materia_prima, data_scadenza}. Nome principale + dettagli
// fra parentesi; l'id (chiave tecnica) non si mostra mai.
function DescriviCandidato(ACandidato: TJSONValue): string;
var
  LObj: TJSONObject;
  LNome, LValore: string;
  LDettagli: TList<string>;
  LCoppia: TJSONPair;
begin
  if not (ACandidato is TJSONObject) then
    Exit(Trim(ACandidato.Value));
  LObj := TJSONObject(ACandidato);

  LNome := CampoStringa(LObj, 'denominazione');
  if LNome = '' then
    LNome := CampoStringa(LObj, 'ragione_sociale');
  if LNome = '' then
    LNome := CampoStringa(LObj, 'codice_lotto');
  if LNome = '' then
    LNome := CampoStringa(LObj, 'nome');

  LDettagli := TList<string>.Create;
  try
    LValore := CampoStringa(LObj, 'codice');
    if (LValore <> '') and (LValore <> LNome) then
      LDettagli.Add(LValore);
    LValore := CampoStringa(LObj, 'tipo');
    if LValore = 'materia_prima' then
      LDettagli.Add('materia prima')
    else if LValore <> '' then
      LDettagli.Add(LValore);
    LValore := CampoStringa(LObj, 'materia_prima');
    if LValore <> '' then
      LDettagli.Add(LValore);
    LValore := CampoStringa(LObj, 'data_scadenza');
    if LValore <> '' then
      LDettagli.Add('scadenza ' + DataIt(LValore));
    LValore := CampoStringa(LObj, 'partita_iva');
    if LValore <> '' then
      LDettagli.Add('P.IVA ' + LValore);

    // Forma sconosciuta: i valori di testo, senza chiavi e senza id.
    if (LNome = '') and (LDettagli.Count = 0) then
      for LCoppia in LObj do
        if (LCoppia.JsonString.Value <> 'id') and (LCoppia.JsonValue is TJSONString) and
           (Trim(LCoppia.JsonValue.Value) <> '') then
          LDettagli.Add(LCoppia.JsonValue.Value);

    if LNome = '' then
      Result := string.Join(', ', LDettagli.ToArray)
    else if LDettagli.Count > 0 then
      Result := LNome + ' (' + string.Join(', ', LDettagli.ToArray) + ')'
    else
      Result := LNome;
  finally
    LDettagli.Free;
  end;
end;

class function TSintesiRisposta.TestoDisambiguazione(AProblemi: TJSONValue): string;
var
  LRighe: TList<string>;
  LProblema, LCandidati: TJSONValue;
  LCercato, LCosa: string;
  LCandidatiNum, i, j: Integer;
  LQualcunaScelta: Boolean;
begin
  LRighe := TList<string>.Create;
  try
    // FEEDBACK 20/10 (prova vendite, cliente inesistente): con un valore
    // "non trovato" e NESSUN candidato simile non c'e' niente da scegliere, e
    // l'intestazione "Mi serve una tua scelta" confondeva. L'intestazione si
    // decide dopo aver visto i problemi: si scrive "scelta" solo se almeno un
    // problema offre dei candidati.
    LQualcunaScelta := False;
    LRighe.Add('');                    // segnaposto: l'intestazione si mette in fondo
    if AProblemi is TJSONArray then
      for i := 0 to TJSONArray(AProblemi).Count - 1 do
      begin
        LProblema := TJSONArray(AProblemi).Items[i];
        if not (LProblema is TJSONObject) then
          Continue;
        LCercato := TestoCampo(TJSONObject(LProblema), 'valore_cercato');
        LCosa := DescriviCampo(TestoCampo(TJSONObject(LProblema), 'campo'));
        LCandidati := TJSONObject(LProblema).GetValue('candidati');
        LCandidatiNum := 0;
        if LCandidati is TJSONArray then
          LCandidatiNum := TJSONArray(LCandidati).Count;
        if LCandidatiNum > 0 then
          LQualcunaScelta := True;

        if TestoCampo(TJSONObject(LProblema), 'tipo') = 'non_trovato' then
        begin
          if LCandidatiNum > 0 then
            LRighe.Add(Format('- Non trovo il %s "%s". Forse intendevi uno di questi:', [LCosa, LCercato]))
          else
            LRighe.Add(Format('- Non trovo il %s "%s".', [LCosa, LCercato]));
        end
        else
          LRighe.Add(Format('- Per il %s "%s" ho trovato piu'' corrispondenze:', [LCosa, LCercato]));

        for j := 0 to LCandidatiNum - 1 do
          LRighe.Add('    - ' + DescriviCandidato(TJSONArray(LCandidati).Items[j]));
      end;
    if LQualcunaScelta then
      LRighe[0] := 'Mi serve una tua scelta prima di proseguire.'
    else
    begin
      // Nessun candidato: l'utente puo' solo correggere il dato.
      LRighe[0] := 'Non posso proseguire.';
      LRighe.Add('Controlla il nome e riprova, oppure indicamene un altro.');
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
    // FEEDBACK 19/10 (punto 1): stessa domanda all'utente anche quando il
    // codice NON c'e' (ARGOMENTO_MANCANTE, che ora copre anche null e ""),
    // non solo quando e' inventato. Formati dei messaggi del validatore:
    //   VALORE_NON_ANCORATO   campo="valore" non compare ...
    //   ARGOMENTO_MANCANTE    'campo' obbligatorio per <tool>
    for LErrore in AErrori do
    begin
      if LErrore.Codice = 'VALORE_NON_ANCORATO' then
        LCampo := Copy(LErrore.Messaggio, 1, Pos('=', LErrore.Messaggio) - 1)
      else if LErrore.Codice = 'ARGOMENTO_MANCANTE' then
        LCampo := Copy(LErrore.Messaggio, 2, Pos(''' ', LErrore.Messaggio) - 2)
      else
        Continue;
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
          LRighe.Add(PROPOSTA_ANTEPRIMA_EMAIL);
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

class function TSintesiRisposta.DichiaraScritturaNonAvvenuta(const ATesto: string;
  AEsecuzione: TEsitoEsecuzione): Boolean;
const
  // Forme passive/perfette che affermano un fatto compiuto: "e' stata
  // creata", "sono stati salvati", "ho salvato", "e' stato registrato".
  // Volutamente NON si cercano le parole da sole ("creare", "salvare",
  // "vuoi che la salvi?"): una proposta o una domanda e' lecita.
  MODELLO =
    '\b(e''|\x{E8}|sono|ho|abbiamo|viene|vengono)\s+(stat[aoie]\s+)?' +
    '(creat|salvat|registrat|inserit|memorizzat|aggiornat|aperta|invi?at)[aoie]?\b';
begin
  Result := (not ScritturaEseguita(AEsecuzione)) and
    TRegEx.IsMatch(ATesto, MODELLO, [roIgnoreCase]);
end;

class function TSintesiRisposta.NotaNessunaScrittura: string;
begin
  Result := 'Attenzione: in questo turno nel gestionale non e'' stato salvato nulla. ' +
    'Se vuoi rendere effettiva l''operazione, chiedimelo e ti chiedero'' conferma.';
end;

// 12.5 -> "12,50" (due decimali fissi, formato italiano).
function SoldiIt(AValore: Double): string;
var
  LFormato: TFormatSettings;
begin
  LFormato := TFormatSettings.Create('it-IT');
  Result := FormatFloat('#,##0.00', AValore, LFormato);
end;

// "nome1, nome2" dalle "denominazione" di un array di oggetti; "nessuno" se
// l'array manca o e' vuoto.
function ElencoDenominazioni(AOggetto: TJSONObject; const ANomeArray: string): string;
var
  LValore: TJSONValue;
  LNomi: TList<string>;
  i: Integer;
begin
  LValore := AOggetto.GetValue(ANomeArray);
  LNomi := TList<string>.Create;
  try
    if LValore is TJSONArray then
      for i := 0 to TJSONArray(LValore).Count - 1 do
        if TJSONArray(LValore).Items[i] is TJSONObject then
          LNomi.Add(TestoCampo(TJSONObject(TJSONArray(LValore).Items[i]), 'denominazione'));
    if LNomi.Count = 0 then
      Result := 'nessuno'
    else
      Result := string.Join(', ', LNomi.ToArray);
  finally
    LNomi.Free;
  end;
end;

class function TSintesiRisposta.BloccoEsitoSimulazione(AEsecuzione: TEsitoEsecuzione;
  out ASoloSimulazione: Boolean): string;
const
  EURO = #$20AC;
var
  LPasso, LEsito: TEsitoPasso;
  LOut, LPrezzo, LElemento: TJSONObject;
  LRighe: TList<string>;
  LAttuale, LSimulato, LNecessaria, LDisponibile, LPrezzoAtt, LPrezzoSug: Double;
  LCentAttuale, LCentSimulato, LDeltaCent: Int64;
  LProducibili, LProducibiliAtt: Int64;
  LCostoCompleto, LProducibiliCompleto, LPrezzoDisp: Boolean;
  LLimitante, LUnita, LFonte, LMotivo, LSegno: string;
  LInsufficienti: TJSONValue;
  i: Integer;
begin
  Result := '';
  ASoloSimulazione := False;
  LPasso := PassoRiuscito(AEsecuzione, TOOL_SIMULA);
  if (LPasso = nil) or (LPasso.Output = nil) then
    Exit;
  LOut := LPasso.Output;
  // Senza i tre costi non si scrive nulla: meglio la risposta del modello.
  if not (LOut.TryGetValue<Double>('costo_ricetta_attuale', LAttuale) and
          LOut.TryGetValue<Double>('costo_ricetta_simulata', LSimulato)) then
    Exit;

  ASoloSimulazione := True;
  for LEsito in AEsecuzione.Esiti do
    if not ((LEsito.Tool = TOOL_SIMULA) and (LEsito.Esito = 'ok')) then
      ASoloSimulazione := False;

  LCostoCompleto := True;
  LOut.TryGetValue<Boolean>('costo_completo', LCostoCompleto);

  LRighe := TList<string>.Create;
  try
    LRighe.Add('**Simulazione dell''adattamento** (nulla e'' stato salvato)');
    LRighe.Add('');

    // COSTO per unita'. Si arrotondano PRIMA i due costi al centesimo e la
    // differenza si fa sui valori mostrati: cosi' i tre numeri che l'utente
    // legge tornano fra loro (6,01 -> 6,57 = +0,56, non +0,57 da un delta
    // calcolato sui valori non arrotondati).
    LCentAttuale := Round(LAttuale * 100);
    LCentSimulato := Round(LSimulato * 100);
    LDeltaCent := LCentSimulato - LCentAttuale;
    if LDeltaCent > 0 then
      LSegno := '+' + SoldiIt(LDeltaCent / 100) + ' ' + EURO + ', piu'' caro'
    else if LDeltaCent < 0 then
      LSegno := '-' + SoldiIt(Abs(LDeltaCent) / 100) + ' ' + EURO + ', piu'' economico'
    else
      LSegno := 'invariato';
    LRighe.Add('- Costo degli ingredienti per unita'': ' + SoldiIt(LCentAttuale / 100) + ' ' + EURO +
      ' -> ' + SoldiIt(LCentSimulato / 100) + ' ' + EURO);
    LRighe.Add('  - Variazione: ' + LSegno);
    if not LCostoCompleto then
      LRighe.Add('  - Attenzione: il costo e'' parziale, ci sono semilavorati di cui non si conosce il costo.');

    // ALLERGENI.
    LRighe.Add('- Allergeni rimossi: ' + ElencoDenominazioni(LOut, 'allergeni_rimossi'));
    LRighe.Add('- Allergeni aggiunti: ' + ElencoDenominazioni(LOut, 'allergeni_aggiunti'));

    // UNITA' PRODUCIBILI (se il tool le ha calcolate).
    if LOut.TryGetValue<Int64>('unita_producibili', LProducibili) then
    begin
      LProducibiliAtt := 0;
      LOut.TryGetValue<Int64>('unita_producibili_attuali', LProducibiliAtt);
      LProducibiliCompleto := True;
      LOut.TryGetValue<Boolean>('unita_producibili_completo', LProducibiliCompleto);
      LLimitante := TestoCampo(LOut, 'componente_limitante');
      LRighe.Add('- Unita'' producibili con la giacenza di oggi: ' + IntToStr(LProducibili) +
        ' (con la ricetta attuale: ' + IntToStr(LProducibiliAtt) + ')');
      LInsufficienti := LOut.GetValue('componenti_insufficienti');
      if (LProducibili = 0) and (LInsufficienti is TJSONArray) and (TJSONArray(LInsufficienti).Count > 0) then
      begin
        LRighe.Add('  - Non se ne puo'' produrre nemmeno una: mancano queste materie prime:');
        for i := 0 to TJSONArray(LInsufficienti).Count - 1 do
          if TJSONArray(LInsufficienti).Items[i] is TJSONObject then
          begin
            LElemento := TJSONObject(TJSONArray(LInsufficienti).Items[i]);
            LNecessaria := 0;
            LDisponibile := 0;
            LElemento.TryGetValue<Double>('necessaria_per_unita', LNecessaria);
            LElemento.TryGetValue<Double>('disponibile', LDisponibile);
            LUnita := TestoCampo(LElemento, 'unita_misura');
            LRighe.Add('    - ' + TestoCampo(LElemento, 'denominazione') + ': servono ' +
              NumeroIt(LNecessaria) + ' ' + LUnita + ' per unita'', disponibili ' +
              NumeroIt(LDisponibile) + ' ' + LUnita);
          end;
      end
      else if LLimitante <> '' then
        LRighe.Add('  - Ingrediente che limita la produzione: ' + LLimitante);
      if not LProducibiliCompleto then
        LRighe.Add('  - Calcolo parziale: per alcuni ingredienti non si e'' potuta confrontare la giacenza.');
    end;

    // PREZZO DI VENDITA SUGGERITO.
    LPrezzo := nil;
    if LOut.GetValue('prezzo_vendita') is TJSONObject then
      LPrezzo := TJSONObject(LOut.GetValue('prezzo_vendita'));
    if LPrezzo <> nil then
    begin
      LPrezzoDisp := False;
      LPrezzo.TryGetValue<Boolean>('disponibile', LPrezzoDisp);
      if LPrezzoDisp and LPrezzo.TryGetValue<Double>('attuale', LPrezzoAtt) and
         LPrezzo.TryGetValue<Double>('suggerito', LPrezzoSug) then
      begin
        LFonte := TestoCampo(LPrezzo, 'fonte_prezzo_attuale');
        LRighe.Add('- Prezzo di vendita suggerito: ' + SoldiIt(LPrezzoSug) + ' ' + EURO +
          ' (prezzo attuale ' + SoldiIt(LPrezzoAtt) + ' ' + EURO +
          IfThen(LFonte <> '', ', da ' + LFonte, '') + ')');
        LRighe.Add('  - Mantiene lo stesso rapporto prezzo/costo del prodotto di partenza, calcolato ' +
          'solo sul costo degli ingredienti: e'' un supporto alla decisione, non un prezzo definitivo.');
      end
      else
      begin
        LMotivo := TestoCampo(LPrezzo, 'motivo');
        LRighe.Add('- Prezzo di vendita suggerito: non calcolabile' +
          IfThen(LMotivo <> '', ' (' + LMotivo + ')', '') + '.');
      end;
    end;

    LRighe.Add('');
    LRighe.Add('Per creare la variante compila il modulo qui sotto (codice e nome del nuovo prodotto) ' +
      'e premi **Conferma e crea**.');
    Result := string.Join(#10, LRighe.ToArray);
  finally
    LRighe.Free;
  end;
end;

class function TSintesiRisposta.BloccoSceltaSostituzioni(AEsecuzione: TEsitoEsecuzione;
  out ASoloRicerca: Boolean): string;
var
  LRicetta, LCerca, LEsito: TEsitoPasso;
  LCodice, LNomeAllergene, LUnita: string;
  LRighe: TList<string>;
  LRadice, LComponente, LAllergene: TJSONValue;
  LComponenti, LAllergeni, LCandidati: TJSONArray;
  LQuantita: Double;
  LVersione, LNumCandidati, i, j: Integer;
  LContiene: Boolean;
begin
  Result := '';
  ASoloRicerca := False;
  LRicetta := PassoRiuscito(AEsecuzione, TOOL_RICETTA);
  LCerca := PassoRiuscito(AEsecuzione, TOOL_CERCA_COMPONENTI);
  if (LRicetta = nil) or (LCerca = nil) then
    Exit;
  // Serve l'allergene cercato: senza, non si sa quali ingredienti elencare.
  if LCerca.ArgomentiRisolti = nil then
    Exit;
  LCodice := TestoCampo(LCerca.ArgomentiRisolti, 'escludi_allergene_codice');
  if LCodice = '' then
    Exit;
  if not ((LRicetta.Output is TJSONObject) and (LCerca.Output is TJSONObject)) then
    Exit;

  // Solo questi due tool, tutti riusciti. Se il piano ha altro (una
  // simulazione, per esempio) la risposta resta quella del modello.
  ASoloRicerca := True;
  for LEsito in AEsecuzione.Esiti do
    if not (((LEsito.Tool = TOOL_RICETTA) or (LEsito.Tool = TOOL_CERCA_COMPONENTI)) and
            (LEsito.Esito = 'ok')) then
      ASoloRicerca := False;

  LRadice := LRicetta.Output;
  LVersione := 0;
  TJSONObject(LRadice).TryGetValue<Integer>('versione', LVersione);
  LNomeAllergene := LCodice;
  LRighe := TList<string>.Create;
  try
    // Ingredienti della ricetta che portano l'allergene (il nome esteso
    // dell'allergene si legge dal primo che lo contiene).
    if TJSONObject(LRadice).GetValue('componenti') is TJSONArray then
    begin
      LComponenti := TJSONArray(TJSONObject(LRadice).GetValue('componenti'));
      for i := 0 to LComponenti.Count - 1 do
      begin
        LComponente := LComponenti.Items[i];
        if not (LComponente is TJSONObject) then
          Continue;
        LContiene := False;
        if TJSONObject(LComponente).GetValue('allergeni') is TJSONArray then
        begin
          LAllergeni := TJSONArray(TJSONObject(LComponente).GetValue('allergeni'));
          for j := 0 to LAllergeni.Count - 1 do
          begin
            LAllergene := LAllergeni.Items[j];
            if (LAllergene is TJSONObject) and
               (TestoCampo(TJSONObject(LAllergene), 'codice') = LCodice) then
            begin
              LContiene := True;
              if TestoCampo(TJSONObject(LAllergene), 'denominazione') <> '' then
                LNomeAllergene := TestoCampo(TJSONObject(LAllergene), 'denominazione');
            end;
          end;
        end;
        if LContiene then
        begin
          LQuantita := 0;
          TJSONObject(LComponente).TryGetValue<Double>('quantita_standard', LQuantita);
          LUnita := TestoCampo(TJSONObject(LComponente), 'unita_misura_dose');
          LRighe.Add('- ' + TestoCampo(TJSONObject(LComponente), 'denominazione') + ': ' +
            Trim(NumeroIt(LQuantita) + ' ' + LUnita));
        end;
      end;
    end;

    LNumCandidati := 0;
    if TJSONObject(LCerca.Output).GetValue('candidati') is TJSONArray then
    begin
      LCandidati := TJSONArray(TJSONObject(LCerca.Output).GetValue('candidati'));
      LNumCandidati := LCandidati.Count;
    end;

    if LRighe.Count = 0 then
      Result := Format('Nella ricetta attuale (versione %d) nessun ingrediente contiene "%s".',
        [LVersione, LNomeAllergene])
    else
      Result := Format('Ingredienti della ricetta attuale (versione %d) che contengono "%s":',
        [LVersione, LNomeAllergene]) + #10 + string.Join(#10, LRighe.ToArray);

    if LNumCandidati = 0 then
      Result := Result + #10#10 +
        'In anagrafica non ci sono ingredienti privi di questo allergene da proporre come sostituti.'
    else
      Result := Result + #10#10 + Format(
        'In anagrafica ho trovato %d ingredienti (materie prime e semilavorati) privi di questo ' +
        'allergene. Nel modulo qui sotto scegli con cosa sostituire ciascun ingrediente e in che ' +
        'quantita'', poi premi **Simula**: calcolo l''impatto su costo e allergeni senza salvare nulla.',
        [LNumCandidati]);
  finally
    LRighe.Free;
  end;
end;

class function TSintesiRisposta.BloccoEsitoInvio(AEsecuzione: TEsitoEsecuzione;
  out ASoloInvio: Boolean): string;
var
  LEsito: TEsitoPasso;
  LRighe: TList<string>;
  LElenco: TJSONArray;
  LVoce, LErrore: TJSONValue;
  LRiga: TJSONObject;
  LTrovato: Boolean;
  LMotivo: string;
begin
  Result := '';
  ASoloInvio := False;
  if AEsecuzione = nil then
    Exit;

  LTrovato := False;
  ASoloInvio := True;
  LRighe := TList<string>.Create;
  try
    for LEsito in AEsecuzione.Esiti do
    begin
      if (LEsito.Tool <> 'invia_email') and (LEsito.Tool <> 'invia_email_da_modello') then
      begin
        ASoloInvio := False;
        Continue;
      end;
      if LEsito.Esito = 'ok' then
      begin
        LTrovato := True;
        LRighe.Add('**' + CampoStringa(LEsito.Output, 'messaggio') + '**');
        LElenco := CampoElenco(LEsito.Output, 'dettaglio');
        if LElenco <> nil then
          for LVoce in LElenco do
          begin
            if not (LVoce is TJSONObject) then
              Continue;
            LRiga := TJSONObject(LVoce);
            if CampoVero(LRiga, 'inviata') then
              LRighe.Add('- ' + CampoStringa(LRiga, 'email') + ': inviata')
            else
              LRighe.Add('- ' + CampoStringa(LRiga, 'email') + ': NON inviata (' +
                CampoStringa(LRiga, 'errore') + ')');
          end;
        LElenco := CampoElenco(LEsito.Output, 'destinatari');
        if LElenco <> nil then
          for LVoce in LElenco do
            LRighe.Add('- ' + LVoce.Value + ': inviata');
      end
      else if LEsito.Esito = 'ERRORE_TOOL' then
      begin
        LTrovato := True;
        LMotivo := LEsito.Dettaglio;
        if LEsito.Output <> nil then
        begin
          LErrore := LEsito.Output.GetValue('errore');
          if LErrore is TJSONObject then
            LMotivo := TestoCampo(TJSONObject(LErrore), 'messaggio')
          else if LErrore <> nil then
            LMotivo := LErrore.Value;
        end;
        LRighe.Add('**Nessuna email inviata.** Motivo: ' + LMotivo);
      end
      else
        ASoloInvio := False;           // es. ancora in attesa di conferma
    end;
    if not LTrovato then
    begin
      ASoloInvio := False;
      Exit;
    end;
    Result := string.Join(#10, LRighe.ToArray);
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
