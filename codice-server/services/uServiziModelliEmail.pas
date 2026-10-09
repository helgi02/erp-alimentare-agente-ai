unit uServiziModelliEmail;

// Email a testo fisso: legge un modello dalla tabella modelli_email
// (scripts/004_modelli_email.sql) e sostituisce i segnaposto {{nome}} con i valori
// ricevuti.
// Testo fisso perche' le comunicazioni ufficiali (ritiro/richiamo) devono avere sempre lo
// stesso testo e dati esatti, quindi non le scrive il modello di linguaggio. Il testo sta
// nel database: si corregge con un UPDATE senza ricompilare ed e' classificato per
// categoria.
// Regole: segnaposto {{nome}} senza distinzione di maiuscole, spazi ammessi ({{ nome }});
// un segnaposto senza valore e' un errore (Componi restituisce False e cosa manca), non si
// spedisce una email con un buco; i valori in piu' sono ignorati; un corpo in testo
// semplice diventa HTML (caratteri speciali protetti, a capo -> <br>) perche' TEmailServer
// spedisce HTML; in un corpo gia' HTML ogni valore e' protetto prima dell'inserimento (un
// "<" in una ragione sociale non rompe la pagina).
// Non invia e non conosce il dominio: l'invio e' in Service.EmailServer.pas.

interface

uses
  System.SysUtils,
  System.Generics.Collections;

type
  TModelloEmail = record
    Codice: string;
    Categoria: string;
    Descrizione: string;
    Oggetto: string;
    Corpo: string;
  end;

  // Email pronta. Corpo e' il testo dopo la sostituzione (per l'anteprima); CorpoHtml e'
  // quello da spedire.
  TEmailComposta = record
    Oggetto: string;
    Corpo: string;
    CorpoHtml: string;
  end;

  TServizioModelliEmail = class
  public
    // False se nessun modello ha quel codice (senza distinzione di maiuscole).
    class function Trova(const ACodice: string; out AModello: TModelloEmail): Boolean;
    // "codice1, codice2, ..." per gli errori.
    class function CodiciDisponibili: string;
    // AVariabili: nome (minuscolo) -> valore. Resta del chiamante.
    class function Componi(const AModello: TModelloEmail;
      AVariabili: TDictionary<string, string>; out AEmail: TEmailComposta;
      out AErrore: string): Boolean;
    // True se il testo ha gia' tag HTML comuni.
    class function SembraHtml(const ATesto: string): Boolean;
    // Testo semplice -> HTML (se e' gia' HTML resta com'e').
    class function TestoComeHtml(const ATesto: string): string;
  end;

implementation

uses
  System.NetEncoding,
  DbU;

const
  SQL_SELECT_MODELLO =
    'SELECT codice, categoria, descrizione, oggetto, corpo FROM modelli_email ';

  MESSAGGIO_TABELLA_MANCANTE =
    'Impossibile leggere i modelli di email (tabella modelli_email): eseguire ' +
    'scripts/004_modelli_email.sql sul database. Dettaglio: ';

// Protegge & < > e trasforma gli a capo in <br>.
function ProteggiPerHtml(const ATesto: string): string;
begin
  Result := TNetEncoding.HTML.Encode(ATesto);
  Result := StringReplace(Result, #13#10, #10, [rfReplaceAll]);
  Result := StringReplace(Result, #13, #10, [rfReplaceAll]);
  Result := StringReplace(Result, #10, '<br>' + #13#10, [rfReplaceAll]);
end;

// Sostituisce i segnaposto {{nome}}. I nomi senza valore vanno in AMancanti (una volta
// sola) e restano nel testo. AProteggiValori = True se ATesto e' HTML.
function SostituisciSegnaposto(const ATesto: string;
  AVariabili: TDictionary<string, string>; AMancanti: TList<string>;
  AProteggiValori: Boolean): string;
var
  LPosizione, LApre, LChiude: Integer;
  LNome, LValore: string;
begin
  Result := '';
  LPosizione := 1;
  while True do
  begin
    LApre := Pos('{{', ATesto, LPosizione);
    if LApre = 0 then
      Break;
    LChiude := Pos('}}', ATesto, LApre + 2);
    if LChiude = 0 then
      Break;

    Result := Result + Copy(ATesto, LPosizione, LApre - LPosizione);
    LNome := LowerCase(Trim(Copy(ATesto, LApre + 2, LChiude - LApre - 2)));
    if AVariabili.TryGetValue(LNome, LValore) and (Trim(LValore) <> '') then
    begin
      if AProteggiValori then
        LValore := ProteggiPerHtml(LValore);
      Result := Result + LValore;
    end
    else
    begin
      if not AMancanti.Contains(LNome) then
        AMancanti.Add(LNome);
      Result := Result + Copy(ATesto, LApre, LChiude + 2 - LApre);
    end;
    LPosizione := LChiude + 2;
  end;
  Result := Result + Copy(ATesto, LPosizione, MaxInt);
end;

class function TServizioModelliEmail.Trova(const ACodice: string;
  out AModello: TModelloEmail): Boolean;
var
  LAutoQuery: TAutoQuery;
begin
  Result := False;
  try
    // LOWER su entrambi i lati: il codice arriva da un argomento di tool e non deve fallire
    // per una maiuscola.
    LAutoQuery := TDB.GetInstance.getQueryResult(
      SQL_SELECT_MODELLO + 'WHERE LOWER(codice) = LOWER(:codice)', [Trim(ACodice)]);
  except
    on E: Exception do
      raise Exception.Create(MESSAGGIO_TABELLA_MANCANTE + E.Message);
  end;
  try
    if not LAutoQuery.Query.IsEmpty then
    begin
      AModello.Codice      := LAutoQuery.Query.FieldByName('codice').AsString;
      AModello.Categoria   := LAutoQuery.Query.FieldByName('categoria').AsString;
      AModello.Descrizione := LAutoQuery.Query.FieldByName('descrizione').AsString;
      AModello.Oggetto     := LAutoQuery.Query.FieldByName('oggetto').AsString;
      AModello.Corpo       := LAutoQuery.Query.FieldByName('corpo').AsString;
      Result := True;
    end;
  finally
    LAutoQuery.Free;
  end;
end;

class function TServizioModelliEmail.CodiciDisponibili: string;
var
  LAutoQuery: TAutoQuery;
begin
  Result := '';
  try
    LAutoQuery := TDB.GetInstance.getQueryResult(
      'SELECT codice FROM modelli_email ORDER BY categoria, codice');
  except
    on E: Exception do
      raise Exception.Create(MESSAGGIO_TABELLA_MANCANTE + E.Message);
  end;
  try
    while not LAutoQuery.Query.Eof do
    begin
      if Result <> '' then
        Result := Result + ', ';
      Result := Result + LAutoQuery.Query.FieldByName('codice').AsString;
      LAutoQuery.Query.Next;
    end;
  finally
    LAutoQuery.Free;
  end;
  if Result = '' then
    Result := '(nessun modello presente)';
end;

class function TServizioModelliEmail.SembraHtml(const ATesto: string): Boolean;
const
  // Non e' un parser: basta distinguere "testo con tag" da "testo semplice", dove un "<" e'
  // solo un carattere.
  TAG_COMUNI: array[0..9] of string =
    ('</', '<br', '<p>', '<p ', '<div', '<table', '<ul', '<ol', '<h1', '<h2');
var
  LMinuscolo, LTag: string;
begin
  LMinuscolo := LowerCase(ATesto);
  for LTag in TAG_COMUNI do
    if Pos(LTag, LMinuscolo) > 0 then
      Exit(True);
  Result := False;
end;

class function TServizioModelliEmail.TestoComeHtml(const ATesto: string): string;
begin
  if SembraHtml(ATesto) then
    Result := ATesto
  else
    Result := ProteggiPerHtml(ATesto);
end;

class function TServizioModelliEmail.Componi(const AModello: TModelloEmail;
  AVariabili: TDictionary<string, string>; out AEmail: TEmailComposta;
  out AErrore: string): Boolean;
var
  LMancanti: TList<string>;
begin
  AErrore := '';
  LMancanti := TList<string>.Create;
  try
    // Oggetto: un'intestazione, mai HTML, su una riga.
    AEmail.Oggetto := SostituisciSegnaposto(AModello.Oggetto, AVariabili, LMancanti, False);
    AEmail.Oggetto := StringReplace(AEmail.Oggetto, #13, ' ', [rfReplaceAll]);
    AEmail.Oggetto := Trim(StringReplace(AEmail.Oggetto, #10, ' ', [rfReplaceAll]));

    if SembraHtml(AModello.Corpo) then
    begin
      AEmail.Corpo := SostituisciSegnaposto(AModello.Corpo, AVariabili, LMancanti, True);
      AEmail.CorpoHtml := AEmail.Corpo;
    end
    else
    begin
      AEmail.Corpo := SostituisciSegnaposto(AModello.Corpo, AVariabili, LMancanti, False);
      AEmail.CorpoHtml := ProteggiPerHtml(AEmail.Corpo);
    end;

    Result := LMancanti.Count = 0;
    if not Result then
      AErrore := Format('Il modello "%s" richiede valori che mancano: %s.',
        [AModello.Codice, string.Join(', ', LMancanti.ToArray)]);
  finally
    LMancanti.Free;
  end;
end;

end.
