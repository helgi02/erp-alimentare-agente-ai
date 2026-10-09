unit uValidatorePiano;

// Normalizzazione, deduplica e validazione del piano, in quest'ordine, fra il completamento
// e l'esecuzione. Nessuna chiama il modello o un tool.
// 1. NORMALIZZAZIONE (NormalizzaPiano): corregge solo cio' che ha un'unica lettura. Tolti i
// parametri facoltativi null o stringa vuota (assente = nessun filtro); stringhe senza
// spazi iniziali e finali a ogni profondita' (i riferimenti "$N..." restano); intero
// scritto dove il parametro e' una stringa -> stringa (es. 10 -> "10": gli id dei tool sono
// stringhe); dipendenze ricalcolate (restano quelle dichiarate verso un passo precedente,
// piu' quelle implicite nei riferimenti). Niente altre conversioni: "12" non diventa 12.
// 2. DEDUPLICA (DeduplicaPassi): due passi con lo stesso tool e gli stessi argomenti sono
// la stessa operazione; si tiene il primo, i passi sono rinumerati 1..n e i riferimenti al
// passo tolto puntano al gemello.
// 3. VALIDAZIONE (ValidaPiano): controlli sul piano intero prima di eseguire qualunque
// passo; raccoglie tutti gli errori e, se ce n'e' uno, non si esegue niente. Codici:
// ID_NON_CONSECUTIVI, DIPENDENZA_NON_VALIDA (verso un passo non precedente),
// PASSO_INCOMPLETO (senza tool), TOOL_SCONOSCIUTO, TOOL_NON_AMMESSO (scelto dal Completer
// fuori dai candidati), ARGOMENTO_MANCANTE, ARGOMENTO_SCONOSCIUTO, TIPO_ERRATO, RIF_...
// (riferimento non valido, vedi uRiferimentiPiano), RIF_PASSO_NON_VALIDO,
// RIF_TIPO_INCOMPATIBILE.

interface

uses
  System.SysUtils,
  System.JSON,
  System.Generics.Collections,
  uPianificatore,
  uRetrieverPiano;

type
  TErroreValidazione = record
    Codice: string;
    Passo: Integer;      // 0 = errore del piano intero
    Messaggio: string;
  end;

  TValidatorePiano = class
  public
    // Argomenti normalizzati (del chiamante). Le note dicono cosa e' stato
    // tolto o corretto, per il log.
    class function NormalizzaArgomenti(AArgomenti, AInputSchema: TJSONObject;
      ANote: TList<string>): TJSONObject;

    // Normalizza argomenti e dipendenze di ogni passo. Restituisce le note.
    class function NormalizzaPiano(APiano: TPiano): TArray<string>;

    // Toglie i passi duplicati e rinumera. AMappa (del chiamante) riceve vecchio id ->
    // nuovo id (un passo tolto mappa sul gemello); ATolti: id dei passi tolti. Restituisce
    // le note (vuote se non c'erano duplicati: il piano non cambia).
    class function DeduplicaPassi(APiano: TPiano; AMappa: TDictionary<Integer, Integer>;
      out ATolti: TArray<Integer>): TArray<string>;

    // ARetrieval puo' essere nil; ACompletati: id dei passi scritti dal Completer (solo per
    // quelli si controlla che il tool sia fra i candidati). ATestoNoto: domanda dell'utente
    // piu' storico, per il controllo dei valori ancorati; vuoto = controllo saltato.
    class function ValidaPiano(APiano: TPiano; ARetrieval: TRisultatoRetrieval;
      const ACompletati: TArray<Integer>; const ATestoNoto: string = ''): TArray<TErroreValidazione>;
  end;

implementation

uses
  System.Generics.Defaults,
  System.StrUtils,
  System.RegularExpressions,
  uSchemaJSON,
  uRiferimentiPiano;

function EStringa(AValore: TJSONValue): Boolean;
begin
  Result := (AValore is TJSONString) and not (AValore is TJSONNumber);
end;

function Contiene(const AElenco: TArray<Integer>; AValore: Integer): Boolean;
var
  LVoce: Integer;
begin
  Result := False;
  for LVoce in AElenco do
    if LVoce = AValore then
      Exit(True);
end;

function ContieneNome(const AElenco: TArray<string>; const AValore: string): Boolean;
var
  LVoce: string;
begin
  Result := False;
  for LVoce in AElenco do
    if LVoce = AValore then
      Exit(True);
end;

function NomeObbligatorio(ASchema: TJSONObject; const ANome: string): Boolean;
var
  LElenco: TJSONValue;
  i: Integer;
begin
  Result := False;
  LElenco := ASchema.GetValue('required');
  if LElenco is TJSONArray then
    for i := 0 to TJSONArray(LElenco).Count - 1 do
      if TJSONArray(LElenco).Items[i].Value = ANome then
        Exit(True);
end;

// Copia di AValore con le stringhe ripulite dagli spazi iniziali e finali, a
// qualunque profondita'. I riferimenti restano intatti.
function Pulisci(AValore: TJSONValue): TJSONValue;
var
  LOggetto: TJSONObject;
  LArray: TJSONArray;
  LCoppia: TJSONPair;
  i: Integer;
begin
  if EStringa(AValore) then
  begin
    if EUnRiferimento(AValore) then
      Exit(AValore.Clone as TJSONValue);
    Exit(TJSONString.Create(Trim(AValore.Value)));
  end;
  if AValore is TJSONObject then
  begin
    LOggetto := TJSONObject.Create;
    for LCoppia in TJSONObject(AValore) do
      LOggetto.AddPair(LCoppia.JsonString.Value, Pulisci(LCoppia.JsonValue));
    Exit(LOggetto);
  end;
  if AValore is TJSONArray then
  begin
    LArray := TJSONArray.Create;
    for i := 0 to TJSONArray(AValore).Count - 1 do
      LArray.AddElement(Pulisci(TJSONArray(AValore).Items[i]));
    Exit(LArray);
  end;
  Result := AValore.Clone as TJSONValue;
end;

// Testo JSON con le chiavi ordinate: due valori uguali danno lo stesso testo
// qualunque sia l'ordine in cui il modello ha scritto le chiavi.
function Canonico(AValore: TJSONValue): string;
var
  LChiavi: TArray<string>;
  LPezzi: TList<string>;
  LCoppia: TJSONPair;
  LChiave: string;
  i: Integer;
begin
  if AValore is TJSONObject then
  begin
    LChiavi := nil;
    for LCoppia in TJSONObject(AValore) do
      LChiavi := LChiavi + [LCoppia.JsonString.Value];
    TArray.Sort<string>(LChiavi, TComparer<string>.Construct(
      function(const L, R: string): Integer
      begin
        Result := CompareStr(L, R);
      end));
    LPezzi := TList<string>.Create;
    try
      for LChiave in LChiavi do
        LPezzi.Add('"' + LChiave + '":' + Canonico(TJSONObject(AValore).GetValue(LChiave)));
      Result := '{' + string.Join(',', LPezzi.ToArray) + '}';
    finally
      LPezzi.Free;
    end;
  end
  else if AValore is TJSONArray then
  begin
    LPezzi := TList<string>.Create;
    try
      for i := 0 to TJSONArray(AValore).Count - 1 do
        LPezzi.Add(Canonico(TJSONArray(AValore).Items[i]));
      Result := '[' + string.Join(',', LPezzi.ToArray) + ']';
    finally
      LPezzi.Free;
    end;
  end
  else
    Result := JSONComePython(AValore);
end;

class function TValidatorePiano.NormalizzaArgomenti(AArgomenti, AInputSchema: TJSONObject;
  ANote: TList<string>): TJSONObject;
var
  LProprieta: TJSONValue;
  LSchemaParametro: TJSONValue;
  LCoppia: TJSONPair;
  LValore: TJSONValue;
  LNome, LCome: string;
  LVuoto: Boolean;
begin
  Result := TJSONObject.Create;
  if AArgomenti = nil then
    Exit;
  try
    LProprieta := AInputSchema.GetValue('properties');
    for LCoppia in AArgomenti do
    begin
      LNome := LCoppia.JsonString.Value;
      LValore := Pulisci(LCoppia.JsonValue);
      try
        LVuoto := (LValore is TJSONNull) or (EStringa(LValore) and (LValore.Value = ''));
        if LVuoto and not NomeObbligatorio(AInputSchema, LNome) then
        begin
          if LValore is TJSONNull then
            LCome := 'null'
          else
            LCome := 'stringa vuota';
          ANote.Add(Format('''%s'' facoltativo e vuoto (%s): tolto', [LNome, LCome]));
          Continue;
        end;

        // Intero letterale verso un parametro stringa: il tool lo leggerebbe
        // comunque come testo ("10"). Un'unica lettura possibile.
        LSchemaParametro := nil;
        if LProprieta is TJSONObject then
          LSchemaParametro := TJSONObject(LProprieta).GetValue(LNome);
        if (LSchemaParametro is TJSONObject) and
           (TestoCampo(TJSONObject(LSchemaParametro), 'type') = 'string') and
           (TipoJSON(LValore) = 'integer') then
        begin
          ANote.Add(Format('''%s'': intero %s scritto come stringa', [LNome, LValore.ToString]));
          Result.AddPair(LNome, TJSONString.Create(LValore.ToString));
          Continue;
        end;

        // Un obbligatorio vuoto resta com'e': lo segnalera' la validazione.
        Result.AddPair(LNome, LValore);
        LValore := nil;      // ora appartiene a Result
      finally
        LValore.Free;
      end;
    end;
  except
    Result.Free;
    raise;
  end;
end;

// Numeri dei passi a cui gli argomenti fanno riferimento. I riferimenti
// scritti male vengono ignorati qui: li segnala la validazione.
function PassiRiferiti(AArgomenti: TJSONObject): TArray<Integer>;
var
  LTesto: string;
  LPasso: Integer;
begin
  Result := nil;
  for LTesto in TrovaRiferimenti(AArgomenti) do
    try
      LPasso := AnalizzaRiferimento(LTesto).Passo;
      if not Contiene(Result, LPasso) then
        Result := Result + [LPasso];
    except
      on E: ERiferimento do
        ;
    end;
end;

class function TValidatorePiano.NormalizzaPiano(APiano: TPiano): TArray<string>;
var
  LNote, LNotePasso: TList<string>;
  LPasso: TPasso;
  LValide: TArray<Integer>;
  LDipendenza: Integer;
  LSchema, LArgomenti: TJSONObject;
  LNota: string;
begin
  LNote := TList<string>.Create;
  LNotePasso := TList<string>.Create;
  try
    for LPasso in APiano.Passi do
    begin
      // Dipendenze: solo passi precedenti, senza doppioni, in ordine.
      LValide := nil;
      for LDipendenza in LPasso.Dipendenze do
        if (LDipendenza >= 1) and (LDipendenza < LPasso.Id) then
        begin
          if not Contiene(LValide, LDipendenza) then
            LValide := LValide + [LDipendenza];
        end
        else
          LNote.Add(Format('passo %d: dipendenza %d scartata (non e'' un passo precedente)',
            [LPasso.Id, LDipendenza]));
      if LPasso.Concreto and (LPasso.Argomenti <> nil) and (LPasso.Argomenti.Count > 0) then
        for LDipendenza in PassiRiferiti(LPasso.Argomenti) do
          if (LDipendenza >= 1) and (LDipendenza < LPasso.Id) and
             not Contiene(LValide, LDipendenza) then
          begin
            LNote.Add(Format('passo %d: dipendenza %d aggiunta (riferimento $%d negli argomenti)',
              [LPasso.Id, LDipendenza, LDipendenza]));
            LValide := LValide + [LDipendenza];
          end;
      TArray.Sort<Integer>(LValide);
      LPasso.Dipendenze := LValide;

      // Passo incompleto o tool sconosciuto: lo segnalera' la validazione.
      if not LPasso.Concreto or not TPianificatore.ToolConosciuto(LPasso.Tool) then
        Continue;

      LSchema := TPianificatore.SchemaInputTool(LPasso.Tool);
      try
        LNotePasso.Clear;
        LArgomenti := NormalizzaArgomenti(LPasso.Argomenti, LSchema, LNotePasso);
        LPasso.Argomenti.Free;
        LPasso.Argomenti := LArgomenti;
        for LNota in LNotePasso do
          LNote.Add(Format('passo %d (%s): %s', [LPasso.Id, LPasso.Tool, LNota]));
      finally
        LSchema.Free;
      end;
    end;
    Result := LNote.ToArray;
  finally
    LNotePasso.Free;
    LNote.Free;
  end;
end;

// Riscrive i riferimenti "$N..." secondo la nuova numerazione dei passi
// ("$$..." resta un letterale). Restituisce una copia.
function Rinumera(AValore: TJSONValue; AMappa: TDictionary<Integer, Integer>): TJSONValue;
var
  LTesto: string;
  LPos, LVecchio, LNuovo: Integer;
  LOggetto: TJSONObject;
  LArray: TJSONArray;
  LCoppia: TJSONPair;
  i: Integer;
begin
  if EStringa(AValore) then
  begin
    LTesto := AValore.Value;
    if (Length(LTesto) >= 2) and (LTesto[1] = '$') and CharInSet(LTesto[2], ['0'..'9']) then
    begin
      LPos := 2;
      while (LPos <= Length(LTesto)) and CharInSet(LTesto[LPos], ['0'..'9']) do
        Inc(LPos);
      // Dopo il numero: fine del testo, oppure "." o "[".
      if ((LPos > Length(LTesto)) or CharInSet(LTesto[LPos], ['.', '['])) and
         TryStrToInt(Copy(LTesto, 2, LPos - 2), LVecchio) and
         AMappa.TryGetValue(LVecchio, LNuovo) then
        Exit(TJSONString.Create('$' + IntToStr(LNuovo) + Copy(LTesto, LPos, MaxInt)));
    end;
    Exit(AValore.Clone as TJSONValue);
  end;
  if AValore is TJSONObject then
  begin
    LOggetto := TJSONObject.Create;
    for LCoppia in TJSONObject(AValore) do
      LOggetto.AddPair(LCoppia.JsonString.Value, Rinumera(LCoppia.JsonValue, AMappa));
    Exit(LOggetto);
  end;
  if AValore is TJSONArray then
  begin
    LArray := TJSONArray.Create;
    for i := 0 to TJSONArray(AValore).Count - 1 do
      LArray.AddElement(Rinumera(TJSONArray(AValore).Items[i], AMappa));
    Exit(LArray);
  end;
  Result := AValore.Clone as TJSONValue;
end;

class function TValidatorePiano.DeduplicaPassi(APiano: TPiano;
  AMappa: TDictionary<Integer, Integer>; out ATolti: TArray<Integer>): TArray<string>;
var
  LVisti: TDictionary<string, Integer>;     // tool + argomenti -> nuovo id
  LTenuti, LDaTogliere: TList<TPasso>;
  LNote: TList<string>;
  LPasso: TPasso;
  LChiave: string;
  LNuovo, LDipendenza, LMappata: Integer;
  LDipendenze: TArray<Integer>;
  LArgomenti: TJSONValue;
begin
  ATolti := nil;
  AMappa.Clear;
  LVisti := TDictionary<string, Integer>.Create;
  LTenuti := TList<TPasso>.Create;
  LDaTogliere := TList<TPasso>.Create;
  LNote := TList<string>.Create;
  try
    for LPasso in APiano.Passi do
    begin
      LChiave := '';
      if LPasso.Concreto then
      begin
        LChiave := LPasso.Tool + Canonico(LPasso.Argomenti);
        if LVisti.TryGetValue(LChiave, LNuovo) then
        begin
          AMappa.AddOrSetValue(LPasso.Id, LNuovo);
          ATolti := ATolti + [LPasso.Id];
          LNote.Add(Format('passo %d: uguale al passo %d (%s), tolto', [LPasso.Id, LNuovo, LPasso.Tool]));
          LDaTogliere.Add(LPasso);
          Continue;
        end;
      end;
      LNuovo := LTenuti.Count + 1;
      AMappa.AddOrSetValue(LPasso.Id, LNuovo);
      if LPasso.Concreto then
        LVisti.AddOrSetValue(LChiave, LNuovo);
      LTenuti.Add(LPasso);
    end;

    // Nessun duplicato: il piano resta com'e' (nessuna rinumerazione).
    if Length(ATolti) = 0 then
      Exit(nil);

    for LPasso in LTenuti do
    begin
      LPasso.Id := AMappa[LPasso.Id];
      if (LPasso.Argomenti <> nil) and (LPasso.Argomenti.Count > 0) then
      begin
        LArgomenti := Rinumera(LPasso.Argomenti, AMappa);
        LPasso.Argomenti.Free;
        LPasso.Argomenti := LArgomenti as TJSONObject;
      end;
      LDipendenze := nil;
      for LDipendenza in LPasso.Dipendenze do
        if AMappa.TryGetValue(LDipendenza, LMappata) and (LMappata < LPasso.Id) and
           not Contiene(LDipendenze, LMappata) then
          LDipendenze := LDipendenze + [LMappata];
      TArray.Sort<Integer>(LDipendenze);
      LPasso.Dipendenze := LDipendenze;
    end;
    // La lista del piano possiede i passi: togliendoli vengono liberati.
    for LPasso in LDaTogliere do
      APiano.Passi.Remove(LPasso);

    Result := LNote.ToArray;
  finally
    LNote.Free;
    LDaTogliere.Free;
    LTenuti.Free;
    LVisti.Free;
  end;
end;

function DescriviSchema(ASchema: TJSONObject): string;
begin
  if (TestoCampo(ASchema, 'type') = 'array') and (ASchema.GetValue('items') is TJSONObject) then
    Result := 'array di ' + DescriviSchema(TJSONObject(ASchema.GetValue('items')))
  else
    Result := TestoCampo(ASchema, 'type');
end;

type
  // Dati del passo in esame, passati alla funzione ricorsiva sotto.
  TContestoPasso = record
    Id: Integer;
    Dipendenze: TArray<Integer>;
    // id del passo -> nome del tool, solo per i passi gia' risultati validi.
    ToolDelPasso: TDictionary<Integer, string>;
    Errori: TList<TErroreValidazione>;
  end;

procedure Aggiungi(const AContesto: TContestoPasso; const ACodice, AMessaggio: string);
var
  LErrore: TErroreValidazione;
begin
  LErrore.Codice := ACodice;
  LErrore.Passo := AContesto.Id;
  LErrore.Messaggio := AMessaggio;
  AContesto.Errori.Add(LErrore);
end;

// Controlla un argomento che puo' contenere riferimenti a qualunque
// profondita'. Un riferimento vale per il suo TIPO STATICO (ricavato
// dall'output_schema del passo sorgente); tutto il resto e' un letterale e
// si controlla con lo schema.
procedure ControllaValore(AValore: TJSONValue; ASchema: TJSONObject; const APercorso: string;
  const AContesto: TContestoPasso);
var
  LRiferimento: TRiferimento;
  LToolSorgente, LNome, LMessaggio: string;
  LSchemaOutput, LTipo, LProprieta: TJSONObject;
  LLetterale: TJSONString;
  LObbligatori, LMinimo: TJSONValue;
  LCoppia: TJSONPair;
  i: Integer;
begin
  // Letterale che comincia con "$": si controlla senza il primo "$".
  if EStringa(AValore) and (Copy(AValore.Value, 1, 2) = '$$') then
  begin
    LLetterale := TJSONString.Create(Copy(AValore.Value, 2, MaxInt));
    try
      for LMessaggio in ValidaSchema(LLetterale, ASchema, APercorso) do
        Aggiungi(AContesto, 'TIPO_ERRATO', LMessaggio);
    finally
      LLetterale.Free;
    end;
    Exit;
  end;

  if EUnRiferimento(AValore) then
  begin
    try
      LRiferimento := AnalizzaRiferimento(AValore.Value);
    except
      on E: ERiferimento do
      begin
        Aggiungi(AContesto, E.Codice, E.Messaggio);
        Exit;
      end;
    end;
    if (LRiferimento.Passo >= AContesto.Id) or not Contiene(AContesto.Dipendenze, LRiferimento.Passo) then
    begin
      Aggiungi(AContesto, 'RIF_PASSO_NON_VALIDO',
        Format('''%s'': il passo %d deve precedere il %d ed essere nelle dipendenze',
          [AValore.Value, LRiferimento.Passo, AContesto.Id]));
      Exit;
    end;
    // Il passo sorgente ha gia' un errore: non si puo' ricavare il tipo, e
    // l'errore e' gia' registrato.
    if not AContesto.ToolDelPasso.TryGetValue(LRiferimento.Passo, LToolSorgente) then
      Exit;

    LSchemaOutput := TPianificatore.SchemaOutputTool(LToolSorgente);
    try
      LTipo := nil;
      try
        try
          LTipo := TipoStatico(LRiferimento, LSchemaOutput);
        except
          on E: ERiferimento do
          begin
            Aggiungi(AContesto, E.Codice, E.Messaggio);
            Exit;
          end;
        end;
        if not Assegnabile(LTipo, ASchema) then
          Aggiungi(AContesto, 'RIF_TIPO_INCOMPATIBILE',
            Format('''%s'' e'' %s, il parametro ''%s'' vuole %s',
              [AValore.Value, DescriviSchema(LTipo), APercorso, DescriviSchema(ASchema)]));
      finally
        LTipo.Free;
      end;
    finally
      LSchemaOutput.Free;
    end;
    Exit;
  end;

  // Letterale che puo' contenere riferimenti piu' in basso: si scende
  // seguendo lo schema.
  if (AValore is TJSONObject) and (TestoCampo(ASchema, 'type') = 'object') and
     (ASchema.GetValue('properties') is TJSONObject) then
  begin
    LProprieta := TJSONObject(ASchema.GetValue('properties'));
    LObbligatori := ASchema.GetValue('required');
    if LObbligatori is TJSONArray then
      for i := 0 to TJSONArray(LObbligatori).Count - 1 do
      begin
        LNome := TJSONArray(LObbligatori).Items[i].Value;
        if TJSONObject(AValore).GetValue(LNome) = nil then
          Aggiungi(AContesto, 'TIPO_ERRATO',
            Format('%s: campo obbligatorio ''%s'' mancante', [APercorso, LNome]));
      end;
    for LCoppia in TJSONObject(AValore) do
    begin
      LNome := LCoppia.JsonString.Value;
      if not (LProprieta.GetValue(LNome) is TJSONObject) then
        Aggiungi(AContesto, 'TIPO_ERRATO', Format('%s: campo ''%s'' non ammesso', [APercorso, LNome]))
      else
        ControllaValore(LCoppia.JsonValue, TJSONObject(LProprieta.GetValue(LNome)),
          APercorso + '.' + LNome, AContesto);
    end;
    Exit;
  end;

  if (AValore is TJSONArray) and (TestoCampo(ASchema, 'type') = 'array') and
     (ASchema.GetValue('items') is TJSONObject) then
  begin
    LMinimo := ASchema.GetValue('minItems');
    if (LMinimo is TJSONNumber) and (TJSONArray(AValore).Count < TJSONNumber(LMinimo).AsInt) then
      Aggiungi(AContesto, 'TIPO_ERRATO',
        Format('%s: servono almeno %d elementi', [APercorso, TJSONNumber(LMinimo).AsInt]));
    for i := 0 to TJSONArray(AValore).Count - 1 do
      ControllaValore(TJSONArray(AValore).Items[i], TJSONObject(ASchema.GetValue('items')),
        Format('%s[%d]', [APercorso, i]), AContesto);
    Exit;
  end;

  for LMessaggio in ValidaSchema(AValore, ASchema, APercorso) do
    Aggiungi(AContesto, 'TIPO_ERRATO', LMessaggio);
end;

// Controlli di difesa

// Un valore "vuoto" non conta come indicato: assente, null, "" oppure [].
function ValoreIndicato(AValore: TJSONValue): Boolean;
begin
  if (AValore = nil) or (AValore is TJSONNull) then
    Exit(False);
  if AValore is TJSONArray then
    Exit(TJSONArray(AValore).Count > 0);
  if AValore is TJSONString and not (AValore is TJSONNumber) then
    Exit(Trim(AValore.Value) <> '');
  Result := True;
end;

// ALMENO UNO FRA: alcuni tool hanno tutti i parametri facoltativi ma non possono lavorare
// senza almeno uno di un gruppo (es. la ricetta si cerca per nome O per id prodotto). I
// gruppi sono nel contratto del tool, nella chiave interna "x_almeno_uno" dello schema di
// input. Il controllo qui fa uscire l'errore prima di eseguire e prima di chiedere conferma
// per una scrittura incompleta.
procedure ControllaAlmenoUno(ASchema, AArgomenti: TJSONObject; const ATool: string;
  const AContesto: TContestoPasso);
var
  LGruppi, LGruppo, LNome: TJSONValue;
  LTrovato: Boolean;
  LNomi: string;
begin
  LGruppi := ASchema.GetValue('x_almeno_uno');
  if not (LGruppi is TJSONArray) then
    Exit;
  for LGruppo in TJSONArray(LGruppi) do
  begin
    if not (LGruppo is TJSONArray) then
      Continue;
    LTrovato := False;
    LNomi := '';
    for LNome in TJSONArray(LGruppo) do
    begin
      if LNomi <> '' then
        LNomi := LNomi + ', ';
      LNomi := LNomi + LNome.Value;
      if (AArgomenti <> nil) and ValoreIndicato(AArgomenti.GetValue(LNome.Value)) then
        LTrovato := True;
    end;
    if not LTrovato then
      Aggiungi(AContesto, 'ALMENO_UNO_MANCANTE',
        Format('%s: serve almeno uno fra %s', [ATool, LNomi]));
  end;
end;

// VALORI ANCORATI: un id o un codice scritto dal modello deve comparire nella domanda
// dell'utente o nello storico (ATestoNoto); altrimenti e' inventato o copiato male e il
// piano non si esegue (rischio: leggere o scrivere sul lotto o prodotto sbagliato).
// Si controllano solo gli id (chiavi "id", "..._id", "...Id" con sole cifre) e i codici che
// scrive sempre l'utente (CODICI_ANCORATI). Non i testi liberi (motivo, note, nomi) ne' i
// codici che il modello ricava da solo (es. LAT da "lattosio"). I riferimenti "$N.campo" si
// saltano: il valore arriva dai risultati veri.
const
  CODICI_ANCORATI: array[0..2] of string = (
    'codici_lotto_materia_prima', 'codice_non_conformita_base', 'codice_nuovo_prodotto');

function ChiaveDiId(const AChiave: string): Boolean;
var
  LLunghezza: Integer;
begin
  LLunghezza := Length(AChiave);
  Result := (AChiave = 'id') or AChiave.EndsWith('_id') or
    ((LLunghezza > 2) and AChiave.EndsWith('Id') and CharInSet(AChiave[LLunghezza - 2], ['a'..'z']));
end;

procedure ControllaAncorati(AValore: TJSONValue; const AChiave, ATestoNoto: string;
  const AContesto: TContestoPasso);
var
  LCoppia: TJSONPair;
  LElemento: TJSONValue;
  LTesto: string;
  LSoloCifre: Boolean;
  LCarattere: Char;
begin
  if AValore is TJSONObject then
  begin
    for LCoppia in TJSONObject(AValore) do
      ControllaAncorati(LCoppia.JsonValue, LCoppia.JsonString.Value, ATestoNoto, AContesto);
    Exit;
  end;
  if AValore is TJSONArray then
  begin
    // Gli elementi di un array ereditano la chiave dell'array.
    for LElemento in TJSONArray(AValore) do
      ControllaAncorati(LElemento, AChiave, ATestoNoto, AContesto);
    Exit;
  end;
  if (AValore = nil) or (AValore is TJSONNull) or (AValore is TJSONBool) then
    Exit;

  LTesto := Trim(AValore.Value);
  if (LTesto = '') or LTesto.StartsWith('$') then
    Exit;

  if ChiaveDiId(AChiave) then
  begin
    LSoloCifre := True;
    for LCarattere in LTesto do
      if not CharInSet(LCarattere, ['0'..'9']) then
        LSoloCifre := False;
    // Il numero deve comparire "intero": 47 non e' ancorato da 147 o 470.
    if LSoloCifre and not TRegEx.IsMatch(ATestoNoto, '(?<!\d)' + LTesto + '(?!\d)') then
      Aggiungi(AContesto, 'VALORE_NON_ANCORATO',
        Format('%s=%s non compare ne'' nella domanda ne'' nella conversazione', [AChiave, LTesto]));
  end
  else if MatchStr(AChiave, CODICI_ANCORATI) and not ContainsText(ATestoNoto, LTesto) then
    Aggiungi(AContesto, 'VALORE_NON_ANCORATO',
      Format('%s="%s" non compare ne'' nella domanda ne'' nella conversazione', [AChiave, LTesto]));
end;

class function TValidatorePiano.ValidaPiano(APiano: TPiano; ARetrieval: TRisultatoRetrieval;
  const ACompletati: TArray<Integer>; const ATestoNoto: string): TArray<TErroreValidazione>;
var
  LContesto: TContestoPasso;
  LPasso: TPasso;
  LSchema: TJSONObject;
  LProprieta, LObbligatori: TJSONValue;
  LCoppia: TJSONPair;
  LErrore: TErroreValidazione;
  LNome: string;
  LDipendenza, i: Integer;
  LConsecutivi: Boolean;
begin
  LContesto.Errori := TList<TErroreValidazione>.Create;
  LContesto.ToolDelPasso := TDictionary<Integer, string>.Create;
  try
    LConsecutivi := True;
    for i := 0 to APiano.Passi.Count - 1 do
      if APiano.Passi[i].Id <> i + 1 then
        LConsecutivi := False;
    if not LConsecutivi then
    begin
      LErrore.Codice := 'ID_NON_CONSECUTIVI';
      LErrore.Passo := 0;
      LErrore.Messaggio := Format('gli id dei passi devono essere 1..%d, in ordine', [APiano.Passi.Count]);
      Exit(TArray<TErroreValidazione>.Create(LErrore));
    end;

    for LPasso in APiano.Passi do
    begin
      LContesto.Id := LPasso.Id;
      LContesto.Dipendenze := LPasso.Dipendenze;

      for LDipendenza in LPasso.Dipendenze do
        if not ((LDipendenza >= 1) and (LDipendenza < LPasso.Id)) then
          Aggiungi(LContesto, 'DIPENDENZA_NON_VALIDA',
            Format('dipendenza %d non precede il passo %d', [LDipendenza, LPasso.Id]));

      if not LPasso.Concreto then
      begin
        Aggiungi(LContesto, 'PASSO_INCOMPLETO', 'passo senza tool dopo il completamento');
        Continue;
      end;
      if not TPianificatore.ToolConosciuto(LPasso.Tool) then
      begin
        Aggiungi(LContesto, 'TOOL_SCONOSCIUTO', Format('''%s'' non esiste nel catalogo', [LPasso.Tool]));
        Continue;
      end;
      if (ARetrieval <> nil) and Contiene(ACompletati, LPasso.Id) and
         not ContieneNome(ARetrieval.CandidatiDi(LPasso.Id), LPasso.Tool) then
      begin
        Aggiungi(LContesto, 'TOOL_NON_AMMESSO',
          Format('''%s'' non e'' fra i candidati [%s]',
            [LPasso.Tool, string.Join(', ', ARetrieval.CandidatiDi(LPasso.Id))]));
        Continue;
      end;

      LContesto.ToolDelPasso.AddOrSetValue(LPasso.Id, LPasso.Tool);
      LSchema := TPianificatore.SchemaInputTool(LPasso.Tool);
      try
        LProprieta := LSchema.GetValue('properties');
        LObbligatori := LSchema.GetValue('required');
        if LObbligatori is TJSONArray then
          for i := 0 to TJSONArray(LObbligatori).Count - 1 do
          begin
            LNome := TJSONArray(LObbligatori).Items[i].Value;
            if (LPasso.Argomenti = nil) or (LPasso.Argomenti.GetValue(LNome) = nil) then
              Aggiungi(LContesto, 'ARGOMENTO_MANCANTE',
                Format('''%s'' obbligatorio per %s', [LNome, LPasso.Tool]));
          end;
        if LPasso.Argomenti <> nil then
          for LCoppia in LPasso.Argomenti do
          begin
            LNome := LCoppia.JsonString.Value;
            if not (LProprieta is TJSONObject) or
               not (TJSONObject(LProprieta).GetValue(LNome) is TJSONObject) then
              Aggiungi(LContesto, 'ARGOMENTO_SCONOSCIUTO',
                Format('''%s'' non e'' un parametro di %s', [LNome, LPasso.Tool]))
            else
              ControllaValore(LCoppia.JsonValue, TJSONObject(TJSONObject(LProprieta).GetValue(LNome)),
                LNome, LContesto);
          end;

        // Controlli "almeno uno fra" e "valori ancorati" (vedi sopra).
        ControllaAlmenoUno(LSchema, LPasso.Argomenti, LPasso.Tool, LContesto);
        if (ATestoNoto <> '') and (LPasso.Argomenti <> nil) then
          ControllaAncorati(LPasso.Argomenti, '', ATestoNoto, LContesto);
      finally
        LSchema.Free;
      end;
    end;

    Result := LContesto.Errori.ToArray;
  finally
    LContesto.ToolDelPasso.Free;
    LContesto.Errori.Free;
  end;
end;

end.
