unit uSchemaJSON;

(* ============================================================================
  SCHEMA JSON - tappa 3 del porting del pianificatore.
  Porting di scripts/prototipo_pianificatore/pianificatore/schema.py
  (specifica: CONTRATTI.md, paragrafo 2).

  Il sottoinsieme di JSON Schema usato per gli input e gli output dei tool,
  volutamente minimo: solo cio' che i contratti dei tool usano davvero
  (vedi agente_ai/tool/uContrattiTool.pas e le sezioni "CONTRATTI" dei provider).

    type        object | array | string | integer | number | boolean
    object      properties, required   (senza properties = oggetto libero)
    array       items, minItems        (senza items = elementi liberi)
    string      enum, minLength, format = "date" (AAAA-MM-GG, data esistente)
    integer/number   minimum

  Due funzioni:
    ValidaSchema   controlla un valore contro uno schema e restituisce TUTTI
                   gli errori trovati (lista vuota = conforme). Non si ferma
                   al primo: il validatore del piano li riporta insieme.
    Assegnabile    True se un valore del tipo "sorgente" puo' essere passato
                   cosi' com'e' a un parametro del tipo "destinazione". Serve
                   per i riferimenti fra i passi di un piano: il tipo del
                   campo letto dal passo N deve andare bene per il parametro
                   del passo che lo usa.

  Regole che non sono ovvie:
    - null non e' ammesso da nessuno schema;
    - un intero e' anche un numero (non e' una conversione), il contrario no:
      "12.0" non e' un integer;
    - nessuna conversione di tipo: la stringa "12" non e' un integer.
  ============================================================================ *)

interface

uses
  System.SysUtils,
  System.JSON,
  System.Generics.Collections;

// Tipo JSON di un valore, con i nomi di JSON Schema: 'object', 'array',
// 'string', 'integer', 'number', 'boolean'. Stringa vuota per null (o nil).
// Un numero e' 'integer' se e' scritto senza parte decimale ne' esponente
// (118 si', 118.0 e 1e2 no): e' la stessa distinzione che fa Python fra
// int e float leggendo un JSON.
function TipoJSON(AValore: TJSONValue): string;

// Valore testuale del campo ANome di AOggetto ('' se assente o AOggetto nil).
function TestoCampo(AOggetto: TJSONObject; const ANome: string): string;

// Errori di AValore rispetto ad ASchema. APercorso e' il nome del valore nei
// messaggi (vuoto = radice). Ogni messaggio ha la forma "<percorso>: <motivo>".
function ValidaSchema(AValore: TJSONValue; ASchema: TJSONObject;
  const APercorso: string = ''): TArray<string>;

// Regola di assegnabilita' (CONTRATTI.md paragrafo 2).
function Assegnabile(ASorgente, ADestinazione: TJSONObject): Boolean;

implementation

function TipoJSON(AValore: TJSONValue): string;
var
  LTesto: string;
begin
  if (AValore = nil) or (AValore is TJSONNull) then
    Exit('');
  if AValore is TJSONBool then
    Exit('boolean');
  // TJSONNumber PRIMA di TJSONString: in System.JSON un numero e' una
  // sottoclasse di TJSONString.
  if AValore is TJSONNumber then
  begin
    LTesto := AValore.ToString;
    if (Pos('.', LTesto) > 0) or (Pos('e', LTesto) > 0) or (Pos('E', LTesto) > 0) then
      Exit('number');
    Exit('integer');
  end;
  if AValore is TJSONString then
    Exit('string');
  if AValore is TJSONArray then
    Exit('array');
  if AValore is TJSONObject then
    Exit('object');
  Result := '';
end;

function TestoCampo(AOggetto: TJSONObject; const ANome: string): string;
var
  LValore: TJSONValue;
begin
  Result := '';
  if AOggetto = nil then
    Exit;
  LValore := AOggetto.GetValue(ANome);
  if (LValore <> nil) and not (LValore is TJSONNull) then
    Result := LValore.Value;
end;

// True se ANome compare nell'array di stringhe AElenco (es. "required").
function ContieneNome(AElenco: TJSONValue; const ANome: string): Boolean;
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

// Come ParseDataISO + EncodeDate nei provider: formato AAAA-MM-GG esatto.
// AEsiste dice se la data esiste nel calendario (2026-02-30 no).
function FormatoDataValido(const ATesto: string; out AEsiste: Boolean): Boolean;
var
  i, LAnno, LMese, LGiorno: Integer;
  LData: TDateTime;
begin
  AEsiste := False;
  Result := False;
  if Length(ATesto) <> 10 then
    Exit;
  for i := 1 to 10 do
    if i in [5, 8] then
    begin
      if ATesto[i] <> '-' then
        Exit;
    end
    else if not CharInSet(ATesto[i], ['0'..'9']) then
      Exit;
  Result := True;
  LAnno := StrToInt(Copy(ATesto, 1, 4));
  LMese := StrToInt(Copy(ATesto, 6, 2));
  LGiorno := StrToInt(Copy(ATesto, 9, 2));
  AEsiste := TryEncodeDate(LAnno, LMese, LGiorno, LData);
end;

procedure Valida(AValore: TJSONValue; ASchema: TJSONObject; const APercorso: string;
  AErrori: TList<string>);
var
  LAtteso, LTrovato, LDove, LNome, LTesto, LSotto: string;
  LProprieta, LOggetto: TJSONObject;
  LObbligatori, LEnum: TJSONValue;
  LCoppia: TJSONPair;
  LArray: TJSONArray;
  LMinimo: TJSONValue;
  LEsiste, LAmmesso: Boolean;
  i: Integer;
begin
  LAtteso := TestoCampo(ASchema, 'type');
  LTrovato := TipoJSON(AValore);
  if APercorso = '' then
    LDove := '(radice)'
  else
    LDove := APercorso;

  // integer e' un caso particolare di number: non e' una conversione.
  if not ((LTrovato = LAtteso) or ((LAtteso = 'number') and (LTrovato = 'integer'))) then
  begin
    if LTrovato = '' then
      LTrovato := 'null';
    AErrori.Add(Format('%s: atteso %s, trovato %s', [LDove, LAtteso, LTrovato]));
    Exit;
  end;

  if LAtteso = 'object' then
  begin
    // Oggetto libero (es. "parametri" di apri_vista, che dipendono dalla
    // vista scelta): lo schema dichiara solo il tipo, i campi li controlla
    // il tool.
    if not (ASchema.GetValue('properties') is TJSONObject) then
      Exit;
    LProprieta := TJSONObject(ASchema.GetValue('properties'));
    LOggetto := TJSONObject(AValore);
    LObbligatori := ASchema.GetValue('required');
    if LObbligatori is TJSONArray then
      for i := 0 to TJSONArray(LObbligatori).Count - 1 do
      begin
        LNome := TJSONArray(LObbligatori).Items[i].Value;
        if LOggetto.GetValue(LNome) = nil then
          AErrori.Add(Format('%s: campo obbligatorio ''%s'' mancante', [LDove, LNome]));
      end;
    for LCoppia in LOggetto do
    begin
      LNome := LCoppia.JsonString.Value;
      if not (LProprieta.GetValue(LNome) is TJSONObject) then
        AErrori.Add(Format('%s: campo ''%s'' non ammesso', [LDove, LNome]))
      else
      begin
        if APercorso = '' then
          LSotto := LNome
        else
          LSotto := APercorso + '.' + LNome;
        Valida(LCoppia.JsonValue, TJSONObject(LProprieta.GetValue(LNome)), LSotto, AErrori);
      end;
    end;
  end
  else if LAtteso = 'array' then
  begin
    LArray := TJSONArray(AValore);
    LMinimo := ASchema.GetValue('minItems');
    if (LMinimo is TJSONNumber) and (LArray.Count < TJSONNumber(LMinimo).AsInt) then
      AErrori.Add(Format('%s: servono almeno %d elementi, trovati %d',
        [LDove, TJSONNumber(LMinimo).AsInt, LArray.Count]));
    // I parametri array dei tool possono non dichiarare gli elementi.
    if ASchema.GetValue('items') is TJSONObject then
      for i := 0 to LArray.Count - 1 do
        Valida(LArray.Items[i], TJSONObject(ASchema.GetValue('items')),
          Format('%s[%d]', [APercorso, i]), AErrori);
  end
  else if LAtteso = 'string' then
  begin
    LTesto := AValore.Value;
    LEnum := ASchema.GetValue('enum');
    if LEnum is TJSONArray then
    begin
      LAmmesso := False;
      for i := 0 to TJSONArray(LEnum).Count - 1 do
        if TJSONArray(LEnum).Items[i].Value = LTesto then
          LAmmesso := True;
      if not LAmmesso then
        AErrori.Add(Format('%s: ''%s'' non e'' fra i valori ammessi %s', [LDove, LTesto, LEnum.ToJSON]));
    end;
    LMinimo := ASchema.GetValue('minLength');
    if (LMinimo is TJSONNumber) and (Length(LTesto) < TJSONNumber(LMinimo).AsInt) then
      AErrori.Add(Format('%s: stringa vuota', [LDove]));
    if TestoCampo(ASchema, 'format') = 'date' then
    begin
      if not FormatoDataValido(LTesto, LEsiste) then
        AErrori.Add(Format('%s: ''%s'' non e'' una data AAAA-MM-GG', [LDove, LTesto]))
      else if not LEsiste then
        AErrori.Add(Format('%s: ''%s'' non e'' una data esistente', [LDove, LTesto]));
    end;
  end
  else if (LAtteso = 'integer') or (LAtteso = 'number') then
  begin
    // Come ParseIdOpzionale nei provider: gli id sono interi POSITIVI
    // ("minimum": 1 nello schema).
    LMinimo := ASchema.GetValue('minimum');
    if (LMinimo is TJSONNumber) and
       (TJSONNumber(AValore).AsDouble < TJSONNumber(LMinimo).AsDouble) then
      AErrori.Add(Format('%s: %s e'' minore di %s', [LDove, AValore.ToString, LMinimo.ToString]));
  end;
end;

function ValidaSchema(AValore: TJSONValue; ASchema: TJSONObject;
  const APercorso: string): TArray<string>;
var
  LErrori: TList<string>;
begin
  LErrori := TList<string>.Create;
  try
    Valida(AValore, ASchema, APercorso, LErrori);
    Result := LErrori.ToArray;
  finally
    LErrori.Free;
  end;
end;

function Assegnabile(ASorgente, ADestinazione: TJSONObject): Boolean;
var
  LTipoS, LTipoD, LNome: string;
  LPropS, LPropD: TJSONObject;
  LObbligatoriS, LObbligatoriD: TJSONValue;
  LCoppia: TJSONPair;
  i: Integer;
begin
  LTipoS := TestoCampo(ASorgente, 'type');
  LTipoD := TestoCampo(ADestinazione, 'type');

  if LTipoS <> LTipoD then
    // integer -> number: nessuna conversione. integer -> string (contratto
    // v1.2): gli id negli output dei tool sono interi, nei parametri sono
    // stringhe; chi risolve il riferimento scrive l'intero in decimale.
    Exit((LTipoS = 'integer') and ((LTipoD = 'number') or (LTipoD = 'string')));

  if LTipoS = 'array' then
  begin
    // Array senza tipo degli elementi: il controllo lo fa il tool.
    if not (ADestinazione.GetValue('items') is TJSONObject) or
       not (ASorgente.GetValue('items') is TJSONObject) then
      Exit(True);
    Exit(Assegnabile(TJSONObject(ASorgente.GetValue('items')),
      TJSONObject(ADestinazione.GetValue('items'))));
  end;

  if LTipoS = 'object' then
  begin
    // Oggetto libero nella destinazione.
    if not (ADestinazione.GetValue('properties') is TJSONObject) then
      Exit(True);
    LPropD := TJSONObject(ADestinazione.GetValue('properties'));
    if ASorgente.GetValue('properties') is TJSONObject then
      LPropS := TJSONObject(ASorgente.GetValue('properties'))
    else
      LPropS := nil;
    LObbligatoriS := ASorgente.GetValue('required');
    LObbligatoriD := ADestinazione.GetValue('required');

    // Ogni campo obbligatorio della destinazione deve essere obbligatorio
    // (quindi sempre presente) anche nella sorgente, con tipo assegnabile.
    if LObbligatoriD is TJSONArray then
      for i := 0 to TJSONArray(LObbligatoriD).Count - 1 do
      begin
        LNome := TJSONArray(LObbligatoriD).Items[i].Value;
        if (LPropS = nil) or not (LPropS.GetValue(LNome) is TJSONObject) or
           not ContieneNome(LObbligatoriS, LNome) or
           not (LPropD.GetValue(LNome) is TJSONObject) or
           not Assegnabile(TJSONObject(LPropS.GetValue(LNome)), TJSONObject(LPropD.GetValue(LNome))) then
          Exit(False);
      end;

    // La sorgente non puo' portare campi che la destinazione non ammette.
    if LPropS <> nil then
      for LCoppia in LPropS do
      begin
        LNome := LCoppia.JsonString.Value;
        if not (LPropD.GetValue(LNome) is TJSONObject) or
           not (LCoppia.JsonValue is TJSONObject) or
           not Assegnabile(TJSONObject(LCoppia.JsonValue), TJSONObject(LPropD.GetValue(LNome))) then
          Exit(False);
      end;
    Exit(True);
  end;

  // Tipi scalari uguali. Un enum nella destinazione si controlla quando il
  // riferimento viene risolto (valore vero).
  Result := True;
end;

end.
