unit uEsportazioneCSV;

{ ============================================================================
  TEsportazioneCSV — motore di export CSV generico e parametrico.

  Perche' questa unit esiste: il primo scenario che esporta CSV (vendite,
  uVenditeToolProvider.CostruisciCSVVendite) costruiva a mano un TStringBuilder
  con intestazioni ed escaping RFC4180 scritti in linea. Con ritiro/richiamo
  e ricette in arrivo, ciascuno con la propria "riga di dominio" da esportare,
  quella logica (join dei campi, escaping, a-capo) andrebbe duplicata identica
  in ogni tool provider - lo stesso problema che il progetto risolve altrove
  con "tool MCP generici e parametrici" (vedi documento di progetto), qui
  applicato all'export invece che ai filtri di interrogazione.

  Design: DUE responsabilita' nettamente separate.
    1. Le COLONNE (TColonnaCSV<T>): sanno come si chiama una colonna e come
       estrarre/formattare il suo valore da UNA riga di tipo T (record o
       classe che sia - T e' generico, un tipo diverso per ogni scenario:
       TRigaVenditaDettaglio oggi, una futura riga di ritiro/richiamo domani).
       Formattazione (date, valute, TFormatSettings.Invariant, ...) e' decisa
       qui, dallo scenario che dichiara le colonne - questa unit non sa e non
       deve sapere nulla di date o valute.
    2. Il MOTORE (TEsportazioneCSV.Costruisci<T>): sa SOLO come unire colonne
       e righe in testo CSV valido (separatore, escaping, a-capo). Non
       conosce il tipo T ne' il significato dei campi: riceve un array di
       colonne e un array di righe (il "datasource"), itera l'uno dentro
       l'altro e produce la stringa finale.

  Cosi' aggiungere un nuovo export (es. ritiro/richiamo) significa dichiarare
  un array di TColonnaCSV<TRigaRitiro> nel proprio tool provider e chiamare
  Costruisci<TRigaRitiro> - zero codice di join/escaping da riscrivere.

  Nota di collocazione: vive in services/ (non in tools/) perche' e' logica
  di servizio riusabile da qualunque tool provider, non un tool MCP essa
  stessa - stesso principio per cui uServiziVendite.pas sta in services/ e
  non in tools/.
  ============================================================================ }

interface

uses
  System.SysUtils,
  System.Classes;

type
  // Una colonna dell'export: l'intestazione che finisce nella prima riga del
  // CSV, e la funzione che estrae/formatta il valore di QUESTA colonna da
  // una riga di dominio di tipo T.
  //
  // Perche' un TFunc<T,string> e non solo un nome di campo: il valore da
  // scrivere richiede quasi sempre una formattazione (data in yyyy-mm-dd,
  // importo a 2 decimali con punto invariante, ecc.) che varia da colonna a
  // colonna - tenerla qui, accanto al nome della colonna, evita che chi
  // aggiunge/riordina colonne debba toccare due punti diversi del codice
  // (l'intestazione da una parte, il corpo dall'altra).
  TColonnaCSV<T> = record
    Intestazione: string;
    Valore: TFunc<T, string>;
    constructor Create(const AIntestazione: string; const AValore: TFunc<T, string>);
  end;

  // Motore di export: dato un insieme di colonne e un datasource (un array
  // di righe di qualunque tipo T), produce il testo CSV completo
  // (intestazione + una riga per elemento del datasource).
  TEsportazioneCSV = class
  private
    // Escape minimale in stile RFC4180: se il valore contiene il separatore,
    // virgolette o un a-capo, lo racchiude tra virgolette raddoppiando quelle
    // gia' presenti. Applicato sia alle intestazioni sia ai valori: una
    // colonna futura potrebbe avere un'intestazione con caratteri "scomodi"
    // tanto quanto un valore.
    //
    // E' un metodo NON generico a se stante (non una funzione annidata dentro
    // Costruisci<T>) perche' Delphi non supporta funzioni/procedure locali
    // annidate dentro un metodo generico (errore del compilatore E2570) - non
    // dipendendo da T, estrarlo qui e' anche la scelta piu' pulita, non solo
    // quella che compila.
    class function EscapeField(const AValore, ASeparatore: string): string; static;
  public
    // ASeparatore e' una stringa (non un Char): permette anche separatori
    // multi-carattere se mai servisse, e rende l'escaping (Pos/StringReplace,
    // che lavorano su stringhe) piu' diretto senza conversioni implicite.
    class function Costruisci<T>(
      const AColonne: TArray<TColonnaCSV<T>>;
      const ARighe: TArray<T>;
      const ASeparatore: string = ';'): string; static;
  end;

implementation

{ TColonnaCSV<T> }

constructor TColonnaCSV<T>.Create(const AIntestazione: string; const AValore: TFunc<T, string>);
begin
  Intestazione := AIntestazione;
  Valore := AValore;
end;

{ TEsportazioneCSV }

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
    // Riga di intestazione: una colonna per elemento di AColonne, nello
    // stesso ordine in cui e' stato dichiarato dal chiamante.
    for I := 0 to High(AColonne) do
    begin
      if I > 0 then
        LSB.Append(ASeparatore);
      LSB.Append(EscapeField(AColonne[I].Intestazione, ASeparatore));
    end;
    LSB.AppendLine;

    // Una riga per elemento del datasource: per ogni riga, richiama il
    // formattatore di OGNI colonna nello stesso ordine dell'intestazione -
    // e' questo doppio ciclo (righe x colonne) l'unica parte "meccanica"
    // che il motore generico risparmia di riscrivere ad ogni scenario.
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
