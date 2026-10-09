unit uRiferimentiPiano;

// Riferimenti fra i passi di un piano.
// Il modello scrive tutto il piano prima di eseguire i tool, quindi non conosce i valori
// dei passi precedenti. Dove serve il risultato di un altro passo scrive un riferimento:
// $N.a.b.c (campo c nell'output del passo N) oppure $N.a[*].b.c (a e' un array: per ogni
// elemento il suo campo b.c; il risultato e' un array, stesso ordine e stessi doppioni).
// Esempio: "lotti_prodotto_finito_id": "$1.lotti_prodotto_finito_id".
// Il valore vero lo mette il codice, non il modello, cosi' un id non puo' essere sbagliato
// o inventato. Una stringa che comincia con "$$" e' un letterale che comincia con "$"
// ("$$Dollaro srl" vale "$Dollaro srl").
// Prima di eseguire (validatore): AnalizzaRiferimento controlla la sintassi; TipoStatico
// ricava dall'output_schema del passo sorgente il tipo del valore e controlla che il
// percorso sia percorribile (campi dichiarati e obbligatori, array attraversati solo con
// [*]).
// Durante l'esecuzione: RisolviArgomenti sostituisce ogni riferimento con il valore letto
// dall'output reale e ricontrolla gli argomenti contro lo schema di input.
// Codici di errore: RIF_SINTASSI (scritto male), RIF_ARRAY_SENZA_STELLA (array attraversato
// senza [*]), RIF_CAMPO_INESISTENTE (non dichiarato nell'output_schema),
// RIF_NON_REFERENZIABILE (campo facoltativo), RIF_STELLA_NON_ARRAY ([*] su un non-array); a
// runtime RIF_NON_RISOLTO (passo senza output o campo assente), RIF_VUOTO (array vuoto
// verso un parametro che vuole almeno un elemento: "nessun lotto coinvolto" e' un esito
// normale, non un errore del piano) e RIF_VALORE_NON_CONFORME (argomenti risolti contrari
// allo schema di input).

interface

uses
  System.SysUtils,
  System.JSON,
  System.Generics.Collections;

type
  ERiferimento = class(Exception)
  private
    FCodice: string;
    FMessaggio: string;
  public
    constructor Create(const ACodice, AMessaggio: string);
    property Codice: string read FCodice;
    property Messaggio: string read FMessaggio;
  end;

  TSegmentoRiferimento = record
    Campo: string;
    Stella: Boolean;     // True se il campo e' seguito da [*]
  end;

  TRiferimento = record
    Testo: string;
    Passo: Integer;
    Segmenti: TArray<TSegmentoRiferimento>;
  end;

// Ogni stringa che inizia con "$" e' un riferimento, tranne "$$..."
// (letterale con "$" iniziale).
function EUnRiferimento(AValore: TJSONValue): Boolean;

// Sintassi. Solleva ERiferimento (RIF_SINTASSI) se il testo non e' valido.
function AnalizzaRiferimento(const ATesto: string): TRiferimento;

// Schema del valore prodotto dal riferimento. Il risultato e' del chiamante.
function TipoStatico(const ARiferimento: TRiferimento; AOutputSchema: TJSONObject): TJSONObject;

// Valore del riferimento sull'output reale del passo sorgente, senza conversioni. Copia del
// chiamante.
function RisolviRiferimento(const ARiferimento: TRiferimento; AOutput: TJSONValue): TJSONValue;

// Tutti i riferimenti presenti in un valore, a qualunque profondita'.
function TrovaRiferimenti(AValore: TJSONValue): TArray<string>;

// Argomenti con i riferimenti sostituiti dai valori veri e ricontrollati contro
// AInputSchema. AOutputPassi: solo gli output dei passi riusciti (numero passo -> output;
// gli oggetti restano del chiamante). Il risultato e' del chiamante.
function RisolviArgomenti(AArgomenti: TJSONObject;
  AOutputPassi: TDictionary<Integer, TJSONObject>; AInputSchema: TJSONObject): TJSONObject;

implementation

uses
  uSchemaJSON;

constructor ERiferimento.Create(const ACodice, AMessaggio: string);
begin
  inherited Create(ACodice + ': ' + AMessaggio);
  FCodice := ACodice;
  FMessaggio := AMessaggio;
end;

// True se AValore e' una stringa JSON vera (in System.JSON anche i numeri
// derivano da TJSONString).
function EStringa(AValore: TJSONValue): Boolean;
begin
  Result := (AValore is TJSONString) and not (AValore is TJSONNumber);
end;

function EUnRiferimento(AValore: TJSONValue): Boolean;
var
  LTesto: string;
begin
  Result := False;
  if not EStringa(AValore) then
    Exit;
  LTesto := AValore.Value;
  Result := (LTesto <> '') and (LTesto[1] = '$') and
    not ((Length(LTesto) >= 2) and (LTesto[2] = '$'));
end;

function AnalizzaRiferimento(const ATesto: string): TRiferimento;
var
  LPos, LInizio, LStelle: Integer;
  LSegmento: TSegmentoRiferimento;
begin
  Result.Testo := ATesto;
  Result.Segmenti := nil;

  // Intestazione: "$" seguito dal numero del passo (da 1, senza zeri iniziali).
  LPos := 2;
  if (Length(ATesto) < 2) or (ATesto[1] <> '$') or not CharInSet(ATesto[2], ['1'..'9']) then
    raise ERiferimento.Create('RIF_SINTASSI', Format('''%s'': manca ''$<numero passo>''', [ATesto]));
  while (LPos <= Length(ATesto)) and CharInSet(ATesto[LPos], ['0'..'9']) do
    Inc(LPos);
  if not TryStrToInt(Copy(ATesto, 2, LPos - 2), Result.Passo) then
    raise ERiferimento.Create('RIF_SINTASSI', Format('''%s'': numero del passo non valido', [ATesto]));

  // Segmenti: ".campo" con campo = [a-z_][a-z0-9_]*, eventualmente seguito da "[*]".
  while LPos <= Length(ATesto) do
  begin
    if (ATesto[LPos] <> '.') or (LPos = Length(ATesto)) or
       not CharInSet(ATesto[LPos + 1], ['a'..'z', '_']) then
      raise ERiferimento.Create('RIF_SINTASSI',
        Format('''%s'': segmento non valido da posizione %d', [ATesto, LPos - 1]));
    LInizio := LPos + 1;
    LPos := LInizio;
    while (LPos <= Length(ATesto)) and CharInSet(ATesto[LPos], ['a'..'z', '0'..'9', '_']) do
      Inc(LPos);
    LSegmento.Campo := Copy(ATesto, LInizio, LPos - LInizio);
    LSegmento.Stella := Copy(ATesto, LPos, 3) = '[*]';
    if LSegmento.Stella then
      Inc(LPos, 3);
    Result.Segmenti := Result.Segmenti + [LSegmento];
  end;

  if Length(Result.Segmenti) = 0 then
    raise ERiferimento.Create('RIF_SINTASSI',
      Format('''%s'': serve almeno un campo dopo il passo', [ATesto]));
  LStelle := 0;
  for LSegmento in Result.Segmenti do
    if LSegmento.Stella then
      Inc(LStelle);
  if LStelle > 1 then
    raise ERiferimento.Create('RIF_SINTASSI', Format('''%s'': al massimo una [*]', [ATesto]));
  if Result.Segmenti[High(Result.Segmenti)].Stella then
    raise ERiferimento.Create('RIF_SINTASSI',
      Format('''%s'': [*] sull''ultimo segmento e'' ridondante', [ATesto]));
end;

// True se ANome compare nell'array di stringhe AElenco (il campo "required").
function Obbligatorio(AElenco: TJSONValue; const ANome: string): Boolean;
var
  i: Integer;
begin
  Result := False;
  if not (AElenco is TJSONArray) then
    Exit;
  for i := 0 to TJSONArray(AElenco).Count - 1 do
    if TJSONArray(AElenco).Items[i].Value = ANome then
      Exit(True);
end;

function TipoStatico(const ARiferimento: TRiferimento; AOutputSchema: TJSONObject): TJSONObject;
var
  LCorrente: TJSONObject;
  LProprieta: TJSONValue;
  LSegmento: TSegmentoRiferimento;
  LDentroStella: Boolean;
begin
  LCorrente := AOutputSchema;
  LDentroStella := False;
  for LSegmento in ARiferimento.Segmenti do
  begin
    if TestoCampo(LCorrente, 'type') = 'array' then
      raise ERiferimento.Create('RIF_ARRAY_SENZA_STELLA',
        Format('''%s'': si attraversa un array prima di ''%s'' senza [*]',
          [ARiferimento.Testo, LSegmento.Campo]));
    LProprieta := LCorrente.GetValue('properties');
    if (TestoCampo(LCorrente, 'type') <> 'object') or not (LProprieta is TJSONObject) or
       not (TJSONObject(LProprieta).GetValue(LSegmento.Campo) is TJSONObject) then
      raise ERiferimento.Create('RIF_CAMPO_INESISTENTE',
        Format('''%s'': campo ''%s'' non dichiarato', [ARiferimento.Testo, LSegmento.Campo]));
    // Solo i campi SEMPRE presenti si possono usare in un riferimento.
    if not Obbligatorio(LCorrente.GetValue('required'), LSegmento.Campo) then
      raise ERiferimento.Create('RIF_NON_REFERENZIABILE',
        Format('''%s'': ''%s'' e'' facoltativo, quindi non referenziabile',
          [ARiferimento.Testo, LSegmento.Campo]));
    LCorrente := TJSONObject(TJSONObject(LProprieta).GetValue(LSegmento.Campo));
    if LSegmento.Stella then
    begin
      // Un array senza "items" dichiarati non si puo' attraversare: non si saprebbe il tipo
      // degli elementi.
      if (TestoCampo(LCorrente, 'type') <> 'array') or
         not (LCorrente.GetValue('items') is TJSONObject) then
        raise ERiferimento.Create('RIF_STELLA_NON_ARRAY',
          Format('''%s'': ''%s'' non e'' un array', [ARiferimento.Testo, LSegmento.Campo]));
      LCorrente := TJSONObject(LCorrente.GetValue('items'));
      LDentroStella := True;
    end;
  end;

  if LDentroStella then
    Result := TJSONObject.Create
      .AddPair('type', 'array')
      .AddPair('items', LCorrente.Clone as TJSONValue)
  else
    Result := LCorrente.Clone as TJSONObject;
end;

// Scende nei segmenti a partire da AIndice. Con [*] il resto del percorso
// viene applicato a ogni elemento dell'array.
function Scendi(const ARiferimento: TRiferimento; AValore: TJSONValue; AIndice: Integer): TJSONValue;
var
  i, j: Integer;
  LSegmento: TSegmentoRiferimento;
  LArray: TJSONArray;
begin
  for i := AIndice to High(ARiferimento.Segmenti) do
  begin
    LSegmento := ARiferimento.Segmenti[i];
    if not (AValore is TJSONObject) or (TJSONObject(AValore).GetValue(LSegmento.Campo) = nil) then
      raise ERiferimento.Create('RIF_NON_RISOLTO',
        Format('''%s'': ''%s'' assente nell''output', [ARiferimento.Testo, LSegmento.Campo]));
    AValore := TJSONObject(AValore).GetValue(LSegmento.Campo);
    if LSegmento.Stella then
    begin
      if not (AValore is TJSONArray) then
        raise ERiferimento.Create('RIF_NON_RISOLTO',
          Format('''%s'': ''%s'' non e'' un array', [ARiferimento.Testo, LSegmento.Campo]));
      LArray := TJSONArray.Create;
      try
        for j := 0 to TJSONArray(AValore).Count - 1 do
          LArray.AddElement(Scendi(ARiferimento, TJSONArray(AValore).Items[j], i + 1));
      except
        LArray.Free;
        raise;
      end;
      Exit(LArray);
    end;
  end;
  // Nessuna conversione, nessuna deduplica, nessun riordino: il valore e'
  // copiato cosi' com'e'.
  Result := AValore.Clone as TJSONValue;
end;

function RisolviRiferimento(const ARiferimento: TRiferimento; AOutput: TJSONValue): TJSONValue;
begin
  Result := Scendi(ARiferimento, AOutput, 0);
end;

procedure RaccogliRiferimenti(AValore: TJSONValue; AElenco: TList<string>);
var
  LCoppia: TJSONPair;
  i: Integer;
begin
  if EUnRiferimento(AValore) then
    AElenco.Add(AValore.Value)
  else if AValore is TJSONObject then
  begin
    for LCoppia in TJSONObject(AValore) do
      RaccogliRiferimenti(LCoppia.JsonValue, AElenco);
  end
  else if AValore is TJSONArray then
    for i := 0 to TJSONArray(AValore).Count - 1 do
      RaccogliRiferimenti(TJSONArray(AValore).Items[i], AElenco);
end;

function TrovaRiferimenti(AValore: TJSONValue): TArray<string>;
var
  LElenco: TList<string>;
begin
  LElenco := TList<string>.Create;
  try
    RaccogliRiferimenti(AValore, LElenco);
    Result := LElenco.ToArray;
  finally
    LElenco.Free;
  end;
end;

// Copia di AValore con ogni riferimento sostituito dal suo valore.
function Sostituisci(AValore: TJSONValue; AOutputPassi: TDictionary<Integer, TJSONObject>): TJSONValue;
var
  LRiferimento: TRiferimento;
  LOutput: TJSONObject;
  LOggetto: TJSONObject;
  LArray: TJSONArray;
  LCoppia: TJSONPair;
  LTesto: string;
  i: Integer;
begin
  if EStringa(AValore) and (Copy(AValore.Value, 1, 2) = '$$') then
  begin
    // Letterale con "$" iniziale: si toglie il primo "$".
    LTesto := AValore.Value;
    Exit(TJSONString.Create(Copy(LTesto, 2, MaxInt)));
  end;

  if EUnRiferimento(AValore) then
  begin
    LRiferimento := AnalizzaRiferimento(AValore.Value);
    if not AOutputPassi.TryGetValue(LRiferimento.Passo, LOutput) then
      raise ERiferimento.Create('RIF_NON_RISOLTO',
        Format('''%s'': il passo %d non ha un output', [AValore.Value, LRiferimento.Passo]));
    Exit(RisolviRiferimento(LRiferimento, LOutput));
  end;

  if AValore is TJSONObject then
  begin
    LOggetto := TJSONObject.Create;
    try
      for LCoppia in TJSONObject(AValore) do
        LOggetto.AddPair(LCoppia.JsonString.Value, Sostituisci(LCoppia.JsonValue, AOutputPassi));
    except
      LOggetto.Free;
      raise;
    end;
    Exit(LOggetto);
  end;

  if AValore is TJSONArray then
  begin
    LArray := TJSONArray.Create;
    try
      for i := 0 to TJSONArray(AValore).Count - 1 do
        LArray.AddElement(Sostituisci(TJSONArray(AValore).Items[i], AOutputPassi));
    except
      LArray.Free;
      raise;
    end;
    Exit(LArray);
  end;

  Result := AValore.Clone as TJSONValue;
end;

// Unica conversione ammessa oltre integer -> number: un riferimento a un intero verso un
// parametro stringa diventa la sua scrittura decimale (anche per ogni elemento di un
// array). Serve per gli id: interi negli output, stringhe nei parametri. Restituisce una
// copia.
function AStringa(AValore: TJSONValue; ASchema: TJSONObject): TJSONValue;
var
  LArray: TJSONArray;
  i: Integer;
begin
  if (TestoCampo(ASchema, 'type') = 'string') and (TipoJSON(AValore) = 'integer') then
    Exit(TJSONString.Create(AValore.ToString));

  if (TestoCampo(ASchema, 'type') = 'array') and (AValore is TJSONArray) and
     (ASchema.GetValue('items') is TJSONObject) then
  begin
    LArray := TJSONArray.Create;
    for i := 0 to TJSONArray(AValore).Count - 1 do
      LArray.AddElement(AStringa(TJSONArray(AValore).Items[i], TJSONObject(ASchema.GetValue('items'))));
    Exit(LArray);
  end;

  Result := AValore.Clone as TJSONValue;
end;

function RisolviArgomenti(AArgomenti: TJSONObject;
  AOutputPassi: TDictionary<Integer, TJSONObject>; AInputSchema: TJSONObject): TJSONObject;
var
  LProprieta, LSchemaParametro: TJSONObject;
  LCoppia, LRimossa: TJSONPair;
  LValore, LConvertito, LMinimo: TJSONValue;
  LNome: string;
  LErrori: TArray<string>;
begin
  Result := Sostituisci(AArgomenti, AOutputPassi) as TJSONObject;
  try
    if AInputSchema.GetValue('properties') is TJSONObject then
      LProprieta := TJSONObject(AInputSchema.GetValue('properties'))
    else
      LProprieta := nil;

    // Conversione intero -> stringa e controllo "array vuoto": solo per gli
    // argomenti che ERANO un riferimento (i valori scritti dal modello non
    // vengono mai convertiti).
    for LCoppia in AArgomenti do
    begin
      if not EUnRiferimento(LCoppia.JsonValue) then
        Continue;
      LNome := LCoppia.JsonString.Value;
      if (LProprieta = nil) or not (LProprieta.GetValue(LNome) is TJSONObject) then
        Continue;
      LSchemaParametro := TJSONObject(LProprieta.GetValue(LNome));

      LValore := Result.GetValue(LNome);
      LConvertito := AStringa(LValore, LSchemaParametro);
      LRimossa := Result.RemovePair(LNome);
      LRimossa.Free;
      Result.AddPair(LNome, LConvertito);

      // "Nessun lotto coinvolto" e' un esito normale, non un errore del piano.
      LMinimo := LSchemaParametro.GetValue('minItems');
      if (LConvertito is TJSONArray) and (TJSONArray(LConvertito).Count = 0) and
         (LMinimo is TJSONNumber) and (TJSONNumber(LMinimo).AsInt >= 1) then
        raise ERiferimento.Create('RIF_VUOTO',
          Format('''%s'' vale [] ma ''%s'' richiede almeno un elemento',
            [LCoppia.JsonValue.Value, LNome]));
    end;

    LErrori := ValidaSchema(Result, AInputSchema);
    if Length(LErrori) > 0 then
      raise ERiferimento.Create('RIF_VALORE_NON_CONFORME', string.Join('; ', LErrori));
  except
    Result.Free;
    raise;
  end;
end;

end.
