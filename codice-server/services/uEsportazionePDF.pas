unit uEsportazionePDF;

{ ============================================================================
  TEsportazionePDF — motore di export PDF tabellare, generico e parametrico.

  Stessa filosofia di uEsportazioneCSV.pas (vedi commento li'), applicata al
  PDF: le COLONNE (TColonnaPDF<T>) sanno come si chiama una colonna e come
  estrarre/formattare il suo valore da una riga di tipo T; il MOTORE
  (TEsportazionePDF.Costruisci<T>) sa solo disegnare una tabella su pagine
  PDF (intestazione, righe, interruzione di pagina, larghezza colonne) - non
  conosce il significato dei campi ne' il tipo T.

  Usa Synopse SynPdf (https://github.com/synopse/SynPDF, licenza MPL/GPL/LGPL
  tri-license) tramite l'API NATIVA di TPdfDocument (Canvas: TPdfCanvas,
  SetFont/TextOut/TextWidth) - NON tramite TPdfDocumentGDI.VCLCanvas.

  *** NOTA STORICA - perche' NON si usa VCLCanvas ***
  Una prima versione usava TPdfDocumentGDI.VCLCanvas (un TCanvas VCL
  "normale" su cui disegnare con Font/TextOut standard, che l'engine
  converte poi in comandi PDF tramite un TMetaFile intermedio). In test
  reali sulla macchina dell'utente, questo produceva una tabella con righe e
  colonne completamente sovrapposte - causa: TPdfDocumentGDI calcola il suo
  fattore di conversione pixel->punti PDF (ScreenLogPixels, di default
  GetDeviceCaps(FDC, LOGPIXELSY), cioe' il DPI REALE dello schermo/scaling
  di Windows della macchina che genera il PDF) per le COORDINATE, ma la
  dimensione del FONT passa per Font.PixelsPerInch di VCL, che usa lo stesso
  DPI reale in un punto del tutto indipendente e non sincronizzato. Forzare
  ScreenLogPixels a 72 (1 punto = 1 pixel) sistema le coordinate ma NON la
  dimensione del font (che resta legata al DPI reale dello schermo) -
  risultato: testo troppo grande per righe dimensionate correttamente,
  quindi ancora sovrapposto. Le due impostazioni andrebbero tenute
  sincronizzate manualmente (Font.PixelsPerInch := 72 ad ogni impostazione
  di Font.Size) - fragile, e soggetto a rompersi di nuovo su qualunque
  macchina con uno scaling del display diverso.
  L'API nativa (Canvas.SetFont/Canvas.TextOut, entrambi nativamente in punti
  PDF - 1/72 di pollice, per dichiarazione della libreria stessa) non passa
  mai da GDI/Windows per calcolare posizioni o dimensioni: e' quindi
  indipendente per costruzione dal DPI/scaling della macchina che genera il
  PDF, e non e' soggetta a questa classe di bug.

  *** LARGHEZZA COLONNE: auto-dimensionamento proporzionale al contenuto ***
  Le colonne/righe di questo export sono fornite dal MODELLO a runtime (vedi
  uFilesToolsProvider.pas): la lunghezza tipica del contenuto di ciascuna
  colonna e' quindi imprevedibile a priori (un "id ordine" e un "ragione
  sociale cliente" possono benissimo comparire fianco a fianco). Una prima
  versione divideva la larghezza pagina in colonne di uguale larghezza fissa:
  in test reali, qualunque colonna con testo libero (nomi cliente, prodotto)
  sforava sistematicamente nella colonna successiva, illeggibile.
  Questa versione fa due passate: la prima (CalcolaLarghezzeColonna) misura
  con Canvas.TextWidth - che a differenza di MeasureText/MultilineTextRect
  funziona con QUALUNQUE font, non solo quelli embedded, e qui si usa un
  font TrueType di sistema ('Arial') - la larghezza reale richiesta da
  ciascuna colonna (intestazione compresa) su TUTTE le righe, poi distribuisce
  la larghezza di pagina disponibile in proporzione a quanto richiesto da
  ciascuna colonna (se il totale richiesto supera lo spazio disponibile, le
  colonne si restringono tutte proporzionalmente; se e' inferiore, lo spazio
  in piu' si distribuisce allo stesso modo, cosi' la tabella occupa sempre
  l'intera larghezza pagina). La seconda passata disegna: come rete di
  sicurezza per il caso limite in cui, anche dopo il ridimensionamento
  proporzionale, un singolo valore eccezionalmente lungo non entri comunque
  nella colonna assegnata, ogni cella viene troncata con "..." finale se piu'
  larga dello spazio disponibile (funzione TestoTroncato, anch'essa basata su
  TextWidth per lo stesso motivo).
  Effetto collaterale accettato: la funzione di estrazione valore di ogni
  colonna (TColonnaPDF<T>.Valore) viene invocata due volte per cella (una in
  fase di misurazione, una in fase di disegno) invece di una - irrilevante
  per un'estrazione pura/economica come leggere un campo JSON (vedi
  CreaEstrattoreCampo in uFilesToolsProvider.pas), non lo sarebbe per un
  estrattore con effetti collaterali o costoso: nessuno dei chiamanti attuali
  rientra in questo caso.

  Limiti noti residui di questa versione (accettabili per un tool generico,
  documentati cosi' non sono sorprese silenziose):
    - Nessun a-capo multi-riga all'interno di una cella: un valore troppo
      lungo viene troncato con "...", mai spezzato su piu' righe. Va bene per
      un export "quello che il modello ha chiesto", non per un documento di
      compliance con layout fisso (per quello, vedi nota architetturale gia'
      condivisa: valutare FastReport o un designer visuale).

  Nota di collocazione: vive in services/ (non in tools/) perche' e' logica
  di servizio riusabile da qualunque tool provider, non un tool MCP essa
  stessa - stesso principio per cui uServiziVendite.pas sta in services/ e
  non in tools/.

  Formato del risultato: TBytes (i byte grezzi del PDF), non una stringa
  Base64. La prima versione restituiva gia' il Base64 perche' pensata per
  TMCPToolResult.ResourceBlob (contenuto embedded nel tool_result); ora che
  uFilesToolsProvider scrive il file su disco (cartella di export servita
  staticamente, vedi uWebModule.pas) serve scrivere byte, non testo - TBytes
  e' la forma piu' diretta e senza ambiguita' di codifica: chi avesse ancora
  bisogno del Base64 (es. un futuro client MCP che supporta le resource
  embedded) puo' ottenerlo con TNetEncoding.Base64.Encode(ARisultato).
  ============================================================================ }

interface

uses
  System.SysUtils,
  System.Classes,
  System.Math,
  SynPdf;

type
  // Una colonna dell'export PDF: l'intestazione stampata nella riga di
  // testata (ripetuta ad ogni pagina) e la funzione che estrae/formatta il
  // valore di QUESTA colonna da una riga di dominio di tipo T. Stesso ruolo
  // di TColonnaCSV<T> in uEsportazioneCSV.pas - infatti un chiamante che ha
  // gia' le colonne per il CSV puo' costruire l'elenco analogo per il PDF
  // con la stessa logica di formattazione.
  TColonnaPDF<T> = record
    Intestazione: string;
    Valore: TFunc<T, string>;
    constructor Create(const AIntestazione: string; const AValore: TFunc<T, string>);
  end;

  // Motore di export: dato un titolo (puo' essere vuoto), un insieme di
  // colonne e un datasource (array di righe di qualunque tipo T), produce
  // un PDF con una tabella (intestazione ripetuta su ogni pagina, righe che
  // vanno a pagina nuova quando non entrano piu' in quella corrente, colonne
  // auto-dimensionate sul contenuto - vedi commento in testa alla unit) e
  // restituisce i byte grezzi del file (vedi nota "Formato del risultato"
  // in testa alla unit).
  TEsportazionePDF = class
  public
    class function Costruisci<T>(
      const ATitolo: string;
      const AColonne: TArray<TColonnaPDF<T>>;
      const ARighe: TArray<T>): TBytes; static;
  end;

implementation

{ TColonnaPDF<T> }

constructor TColonnaPDF<T>.Create(const AIntestazione: string; const AValore: TFunc<T, string>);
begin
  Intestazione := AIntestazione;
  Valore := AValore;
end;

{ TEsportazionePDF }

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
  // Spazio minimo tra il testo di una colonna e l'inizio della successiva,
  // e larghezza minima garantita per colonna (evita che una colonna
  // collassi a (quasi) zero quando ce ne sono molte e/o molto sbilanciate).
  PADDING_COLONNA = 8;
  LARGHEZZA_MIN_COLONNA = 30;
  SUFFISSO_TRONCAMENTO = '...';
var
  LPdf: TPdfDocument;
  LPage: TPdfPage;
  LStream: TMemoryStream;
  LY: Single;
  // LY misura la distanza dal margine SUPERIORE e cresce verso il basso,
  // esattamente come nella versione precedente (stessa logica di overflow
  // pagina) - la conversione verso il sistema di coordinate nativo di PDF
  // (origine in basso a sinistra, Y che cresce verso l'alto) avviene solo
  // nel punto in cui si disegna, con "LPage.PageHeight - LY".
  LLarghezze: TArray<Single>;          // larghezza assegnata a ciascuna colonna
  LOffsetX: TArray<Single>;            // ascissa di partenza di ciascuna colonna
  LLarghezzaDisponibile: Single;
  LRiga: T;
  I: Integer;
  // Delphi non supporta procedure/funzioni locali ANNIDATE dentro un metodo
  // generico (errore E2570: "Local procedure in generic method ... is not
  // supported") - Costruisci<T> lo e'. Le routine di supporto sono percio'
  // variabili locali di tipo TProc/TFunc (closure), non "procedure Nome;"
  // annidate: catturano LPdf/LPage/LY/AColonne/LLarghezze/LOffsetX
  // esattamente come farebbe una procedura annidata, ma sono un valore
  // assegnato a una variabile, non una dichiarazione di routine - per
  // questo il compilatore le accetta anche qui dentro.
  CalcolaLarghezzeColonna: TProc;
  DisegnaHeaderColonne: TProc;
  NuovaPagina: TProc;
  TestoTroncato: TFunc<string, Single, string>;

begin
  if Length(AColonne) = 0 then
    raise Exception.Create('TEsportazionePDF.Costruisci: nessuna colonna specificata.');

  // Vedi "LARGHEZZA COLONNE" in testa alla unit. Misura con Canvas.TextWidth
  // (funziona con qualunque font, a differenza di MeasureText/
  // MultilineTextRect che SynPdf stessa dichiara affidabili solo con font
  // embedded) la larghezza naturale di ciascuna colonna - intestazione
  // compresa - su tutte le righe, poi distribuisce la larghezza disponibile
  // in proporzione, mantenendo l'ordine delle colonne.
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

  // Rete di sicurezza per il caso limite in cui, anche dopo il
  // ridimensionamento proporzionale, un singolo valore non entri comunque
  // nello spazio assegnato: tronca carattere per carattere (misurando ogni
  // volta con TextWidth, per lo stesso motivo di CalcolaLarghezzeColonna)
  // finche' "testo..." non entra in AMaxWidth. Il chiamante deve aver gia'
  // impostato con SetFont lo stile/dimensione con cui il testo verra'
  // davvero disegnato, perche' TextWidth misura nel font CORRENTE del canvas.
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

  // Intestazione di pagina: ripetuta identica ad ogni AddPage (sia quello
  // iniziale sia quelli per overflow righe), per questo fattorizzata.
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

    // PageWidth e' nativamente in punti PDF (1/72 di pollice, per
    // dichiarazione della libreria) - nessuna conversione o assunzione sul
    // DPI della macchina e' necessaria qui.
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
      // Overflow pagina: se la riga successiva non ci sta piu' nel margine
      // inferiore, si passa a una pagina nuova (con header colonne ripetuto)
      // PRIMA di disegnare la riga corrente.
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
      // Copia i byte dello stream in un TBytes: SetLength alloca l'array,
      // Move copia in blocco (piu' diretto di leggere byte per byte).
      // La guardia "> 0" evita un Move con lunghezza 0 su un array vuoto
      // (caso limite: nessuna riga e titolo vuoto produrrebbero comunque
      // un PDF con solo l'intestazione colonne, quindi Size > 0 in pratica,
      // ma la guardia costa nulla e rende il codice corretto anche se in
      // futuro cambiasse).
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
