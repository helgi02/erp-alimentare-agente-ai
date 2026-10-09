unit uEsportazionePDF;

// Motore di export PDF tabellare, generico e parametrico. Come uEsportazioneCSV: le colonne
// (TColonnaPDF<T>) estraggono/formattano il valore da una riga T; il motore
// (TEsportazionePDF.Costruisci<T>) disegna la tabella (intestazione, righe, interruzione di
// pagina, larghezza colonne). Usa Synopse SynPdf con l'API nativa di TPdfDocument
// (Canvas.SetFont/TextOut/TextWidth).
// Perche' non TPdfDocumentGDI.VCLCanvas: una prima versione lo usava e produceva righe e
// colonne sovrapposte. TPdfDocumentGDI converte le coordinate col DPI reale dello schermo
// (ScreenLogPixels) mentre la dimensione del font passa da Font.PixelsPerInch di VCL, due
// impostazioni indipendenti: forzare ScreenLogPixels a 72 sistema le coordinate ma non il
// font, e tenerle sincronizzate a mano e' fragile con scaling di display diversi. L'API
// nativa lavora in punti PDF (1/72 di pollice) senza passare da GDI, quindi non dipende dal
// DPI.
// Larghezza colonne: righe e colonne arrivano dal modello a runtime, quindi il contenuto e'
// imprevedibile. Colonne di larghezza fissa uguale facevano sforare il testo libero (nomi
// cliente, prodotto) nella colonna successiva. Ora due passate: CalcolaLarghezzeColonna
// misura con Canvas.TextWidth (che funziona con qualunque font, a differenza di
// MeasureText/MultilineTextRect, affidabili solo con font embedded; qui si usa Arial) la
// larghezza richiesta da ogni colonna, intestazione compresa, su tutte le righe, e
// distribuisce la larghezza di pagina in proporzione (la tabella occupa sempre tutta la
// pagina). La seconda passata disegna; se un valore non entra comunque, la cella e'
// troncata con "..." (TestoTroncato). La funzione di estrazione di TColonnaPDF<T>.Valore
// viene chiamata due volte per cella (misura e disegno): irrilevante per la lettura di un
// campo JSON, non per un estrattore costoso o con effetti collaterali.
// Limite noto: nessun a-capo dentro una cella, il valore troppo lungo e' troncato. Va bene
// per un export "quello che ha chiesto il modello", non per un documento di compliance a
// layout fisso (per quello, valutare FastReport).
// Risultato: TBytes, i byte grezzi del PDF, perche' uFilesToolsProvider scrive il file su
// disco. Per il Base64 (es. client con resource embedded):
// TNetEncoding.Base64.Encode(ARisultato).

interface

uses
  System.SysUtils,
  System.Classes,
  System.Math,
  SynPdf;

type
  // Una colonna: intestazione (ripetuta in testa a ogni pagina) e funzione che
  // estrae/formatta il valore da una riga T. Come TColonnaCSV<T>: un chiamante con le
  // colonne CSV puo' costruire quelle PDF con la stessa formattazione.
  TColonnaPDF<T> = record
    Intestazione: string;
    Valore: TFunc<T, string>;
    constructor Create(const AIntestazione: string; const AValore: TFunc<T, string>);
  end;

  // Dato un titolo (anche vuoto), le colonne e un array di righe T, produce un PDF con
  // tabella (intestazione ripetuta a ogni pagina, pagina nuova quando la riga non entra,
  // colonne auto-dimensionate) e ne restituisce i byte.
  TEsportazionePDF = class
  public
    class function Costruisci<T>(
      const ATitolo: string;
      const AColonne: TArray<TColonnaPDF<T>>;
      const ARighe: TArray<T>): TBytes; static;
  end;

implementation

constructor TColonnaPDF<T>.Create(const AIntestazione: string; const AValore: TFunc<T, string>);
begin
  Intestazione := AIntestazione;
  Valore := AValore;
end;

class function TEsportazionePDF.Costruisci<T>(
  const ATitolo: string;
  const AColonne: TArray<TColonnaPDF<T>>;
  const ARighe: TArray<T>): TBytes;
const
  MARGINE = 40;
  ALTEZZA_RIGA = 16;
  ALTEZZA_TITOLO = 32;
  DIM_FONT = 9;
  DIM_FONT_TITOLO = 16;
  // Spazio minimo fra una colonna e la successiva, e larghezza minima per colonna (evita
  // che collassi a zero quando ce ne sono molte e sbilanciate).
  PADDING_COLONNA = 8;
  LARGHEZZA_MIN_COLONNA = 30;
  SUFFISSO_TRONCAMENTO = '...';
var
  LPdf: TPdfDocument;
  LPage: TPdfPage;
  LStream: TMemoryStream;
  LY: Single;
  // LY e' la distanza dal margine superiore e cresce verso il basso; la conversione al
  // sistema nativo PDF (origine in basso, Y verso l'alto) avviene solo al disegno, con
  // "LPage.PageHeight - LY".
  LLarghezze: TArray<Single>;          // larghezza assegnata a ciascuna colonna
  LOffsetX: TArray<Single>;            // ascissa di partenza di ciascuna colonna
  LLarghezzaDisponibile: Single;
  LRiga: T;
  I: Integer;
  // Delphi non ammette routine locali annidate in un metodo generico (E2570): le routine di
  // supporto sono variabili locali TProc/TFunc (closure) che catturano
  // LPdf/LPage/LY/AColonne/LLarghezze/LOffsetX come farebbe una procedura annidata.
  CalcolaLarghezzeColonna: TProc;
  DisegnaHeaderColonne: TProc;
  NuovaPagina: TProc;
  TestoTroncato: TFunc<string, Single, string>;

begin
  if Length(AColonne) = 0 then
    raise Exception.Create('TEsportazionePDF.Costruisci: nessuna colonna specificata.');

  // Misura con Canvas.TextWidth la larghezza naturale di ogni colonna (intestazione
  // compresa) su tutte le righe, poi distribuisce la larghezza disponibile in proporzione,
  // mantenendo l'ordine.
  CalcolaLarghezzeColonna :=
    procedure
    var
      LNaturali: TArray<Single>;
      LTotaleNaturale, LFattoreScala, LX: Single;
      J: Integer;
      LRigaMisura: T;
    begin
      SetLength(LNaturali, Length(AColonne));

      LPdf.Canvas.SetFont('Arial', DIM_FONT, [pfsBold]);
      for J := 0 to High(AColonne) do
        LNaturali[J] := LPdf.Canvas.TextWidth(AnsiString(AColonne[J].Intestazione));

      LPdf.Canvas.SetFont('Arial', DIM_FONT, []);
      for LRigaMisura in ARighe do
        for J := 0 to High(AColonne) do
          LNaturali[J] := Max(LNaturali[J],
            LPdf.Canvas.TextWidth(AnsiString(AColonne[J].Valore(LRigaMisura))));

      for J := 0 to High(LNaturali) do
        LNaturali[J] := Max(LNaturali[J] + PADDING_COLONNA, LARGHEZZA_MIN_COLONNA);

      LTotaleNaturale := 0;
      for J := 0 to High(LNaturali) do
        LTotaleNaturale := LTotaleNaturale + LNaturali[J];
      LFattoreScala := LLarghezzaDisponibile / LTotaleNaturale;

      SetLength(LLarghezze, Length(AColonne));
      SetLength(LOffsetX, Length(AColonne));
      LX := MARGINE;
      for J := 0 to High(LNaturali) do
      begin
        LLarghezze[J] := LNaturali[J] * LFattoreScala;
        LOffsetX[J] := LX;
        LX := LX + LLarghezze[J];
      end;
    end;

  // Rete di sicurezza: tronca carattere per carattere (misurando con TextWidth) finche'
  // "testo..." entra in AMaxWidth. Il chiamante deve aver gia' impostato con SetFont lo
  // stile con cui il testo verra' disegnato, perche' TextWidth misura nel font corrente.
  TestoTroncato :=
    function(AText: string; AMaxWidth: Single): string
    begin
      Result := AText;
      if LPdf.Canvas.TextWidth(AnsiString(Result)) <= AMaxWidth then
        Exit;
      while (Result <> '') and
            (LPdf.Canvas.TextWidth(AnsiString(Result + SUFFISSO_TRONCAMENTO)) > AMaxWidth) do
        Delete(Result, Length(Result), 1);
      if Result <> '' then
        Result := Result + SUFFISSO_TRONCAMENTO;
    end;

  // Intestazione di pagina, ripetuta a ogni AddPage.
  DisegnaHeaderColonne :=
    procedure
    var
      J: Integer;
    begin
      LPdf.Canvas.SetFont('Arial', DIM_FONT, [pfsBold]);
      for J := 0 to High(AColonne) do
        LPdf.Canvas.TextOut(LOffsetX[J], LPage.PageHeight - LY,
          AnsiString(TestoTroncato(AColonne[J].Intestazione, LLarghezze[J] - PADDING_COLONNA)));
      LY := LY + ALTEZZA_RIGA;
    end;

  NuovaPagina :=
    procedure
    begin
      LPage := LPdf.AddPage;   // AddPage riassocia automaticamente LPdf.Canvas alla nuova pagina
      LY := MARGINE;
      DisegnaHeaderColonne();
    end;

  LPdf := TPdfDocument.Create;
  try
    LPage := LPdf.AddPage;
    LY := MARGINE;

    // PageWidth e' gia' in punti PDF: nessuna conversione.
    LLarghezzaDisponibile := LPage.PageWidth - 2 * MARGINE;
    CalcolaLarghezzeColonna();

    if not ATitolo.IsEmpty then
    begin
      LPdf.Canvas.SetFont('Arial', DIM_FONT_TITOLO, [pfsBold]);
      LPdf.Canvas.TextOut(MARGINE, LPage.PageHeight - LY, AnsiString(ATitolo));
      LY := LY + ALTEZZA_TITOLO;
    end;

    DisegnaHeaderColonne();

    for LRiga in ARighe do
    begin
      // Overflow: se la riga successiva non entra nel margine inferiore, pagina nuova (con
      // intestazione ripetuta) prima di disegnarla.
      if LY + ALTEZZA_RIGA > LPage.PageHeight - MARGINE then
        NuovaPagina();

      LPdf.Canvas.SetFont('Arial', DIM_FONT, []);
      for I := 0 to High(AColonne) do
        LPdf.Canvas.TextOut(LOffsetX[I], LPage.PageHeight - LY,
          AnsiString(TestoTroncato(AColonne[I].Valore(LRiga), LLarghezze[I] - PADDING_COLONNA)));
      LY := LY + ALTEZZA_RIGA;
    end;

    LStream := TMemoryStream.Create;
    try
      LPdf.SaveToStream(LStream);
      // Copia i byte dello stream in un TBytes (SetLength + Move). La guardia "> 0" evita
      // un Move su array vuoto.
      SetLength(Result, LStream.Size);
      if LStream.Size > 0 then
        Move(LStream.Memory^, Result[0], LStream.Size);
    finally
      LStream.Free;
    end;
  finally
    LPdf.Free;
  end;
end;

end.
