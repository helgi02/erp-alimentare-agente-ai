unit uEsportazioneCSV;

// Motore di export CSV generico e parametrico (stesso scopo della versione in common).
// Evita di duplicare in ogni tool provider join dei campi, escaping RFC4180 e a-capo.
// Le colonne (TColonnaCSV<T>) sanno nome e come estrarre/formattare il valore da una riga T
// (date e valute sono decise dallo scenario); il motore (TEsportazioneCSV.Costruisci<T>) sa
// solo unire colonne e righe in CSV valido. Un nuovo export e' un array di
// TColonnaCSV<TRiga> e una chiamata a Costruisci<TRiga>.
// Sta in services/ perche' e' logica riusabile da qualunque provider, non un tool MCP.

interface

uses
  System.SysUtils,
  System.Classes;

type
  // Una colonna: intestazione e funzione che estrae/formatta il valore da una riga T. Un
  // TFunc e non un nome di campo perche' il valore richiede quasi sempre una formattazione
  // propria, tenuta accanto al nome della colonna.
  TColonnaCSV<T> = record
    Intestazione: string;
    Valore: TFunc<T, string>;
    constructor Create(const AIntestazione: string; const AValore: TFunc<T, string>);
  end;

  // Dato un insieme di colonne e un array di righe T, produce il CSV completo (intestazione
  // + una riga per elemento).
  TEsportazioneCSV = class
  private
    // Escape stile RFC4180: se il valore contiene separatore, virgolette o a-capo, lo
    // racchiude tra virgolette raddoppiando quelle presenti. Vale anche per le
    // intestazioni. E' un metodo non generico perche' Delphi non ammette routine locali
    // annidate in un metodo generico (E2570).
    class function EscapeField(const AValore, ASeparatore: string): string; static;
  public
    // ASeparatore e' una stringa e non un Char: consente separatori multi-carattere e
    // semplifica l'escaping.
    class function Costruisci<T>(
      const AColonne: TArray<TColonnaCSV<T>>;
      const ARighe: TArray<T>;
      const ASeparatore: string = ';'): string; static;
  end;

implementation

constructor TColonnaCSV<T>.Create(const AIntestazione: string; const AValore: TFunc<T, string>);
begin
  Intestazione := AIntestazione;
  Valore := AValore;
end;

class function TEsportazioneCSV.EscapeField(const AValore, ASeparatore: string): string;
begin
  if (Pos(ASeparatore, AValore) > 0) or (Pos('"', AValore) > 0) or
     (Pos(#10, AValore) > 0) or (Pos(#13, AValore) > 0) then
    Result := '"' + StringReplace(AValore, '"', '""', [rfReplaceAll]) + '"'
  else
    Result := AValore;
end;

class function TEsportazioneCSV.Costruisci<T>(
  const AColonne: TArray<TColonnaCSV<T>>;
  const ARighe: TArray<T>;
  const ASeparatore: string): string;
var
  LSB: TStringBuilder;
  LRiga: T;
  I: Integer;
begin
  LSB := TStringBuilder.Create;
  try
    // Intestazione: una colonna per elemento, nell'ordine dichiarato.
    for I := 0 to High(AColonne) do
    begin
      if I > 0 then
        LSB.Append(ASeparatore);
      LSB.Append(EscapeField(AColonne[I].Intestazione, ASeparatore));
    end;
    LSB.AppendLine;

    // Una riga per elemento: per ognuna, il formattatore di ogni colonna nello stesso
    // ordine dell'intestazione.
    for LRiga in ARighe do
    begin
      for I := 0 to High(AColonne) do
      begin
        if I > 0 then
          LSB.Append(ASeparatore);
        LSB.Append(EscapeField(AColonne[I].Valore(LRiga), ASeparatore));
      end;
      LSB.AppendLine;
    end;

    Result := LSB.ToString;
  finally
    LSB.Free;
  end;
end;

end.
