unit TextFileWriterU;

{
  Scrittura generica di righe di testo timestampate su file, in append,
  thread-safe. Non ha alcuna conoscenza del dominio (email, campagne, ecc.):
  prende in input una cartella e un nome file, e scrive.

  Per performance, l'handle del file viene aperto una sola volta (alla prima
  WriteLine) e tenuto aperto per tutta la vita dell'istanza, invece di
  aprire/scrivere/chiudere ad ogni riga. AutoFlush garantisce comunque che
  ogni riga sia scritta su disco subito dopo la chiamata.

  Ogni istanza ha il proprio lock (non più uno globale condiviso da tutte le
  istanze): scritture su file diversi non si serializzano più a vicenda,
  importante ora che questa unit è pensata per essere riusata in più punti
  dell'applicazione.

  Il file viene aperto con condivisione piena (fmShareDenyNone): se in futuro
  più istanze o processi dovessero puntare allo STESSO file contemporaneamente,
  non otterrai un errore di sharing violation, ma le loro scritture non sono
  coordinate tra loro (ogni istanza serializza solo le proprie). Per un uso
  con un file dedicato per istanza (il caso attuale) non è un problema.

  Politica di errore: NON ingoia le eccezioni. Se la scrittura fallisce
  (cartella non creabile, disco pieno, permessi...) l'eccezione risale al
  chiamante, che decide come gestirla (es. un fallback su un altro canale).
}

interface

uses
  System.SysUtils, System.IOUtils, System.SyncObjs, System.Classes;

type
  TTextFileWriter = class
  private
    FFolder  : String;
    FFileName: String;
    FLock    : TCriticalSection; // per istanza: file diversi non si bloccano a vicenda
    FWriter  : TStreamWriter;    // handle tenuto aperto, creato lazy alla prima WriteLine
    function GetFullPath: String;
    procedure EnsureWriter;
  public
    constructor Create(const AFolder, AFileName: String);
    destructor  Destroy; override;

    // Scrive AMessage su una nuova riga, con timestamp automatico in testa.
    // Crea la cartella se non esiste (solo alla prima chiamata). Solleva
    // un'eccezione se la scrittura fallisce: il chiamante è responsabile
    // di gestirla.
    procedure WriteLine(const AMessage: String);
    // Come WriteLine ma SENZA il prefisso data/ora: serve per formati
    // strutturati (es. CSV) in cui ogni riga deve essere esattamente quella
    // passata dal chiamante. Stessa politica di errore di WriteLine.
    procedure WriteRawLine(const AMessage: String);
  end;

implementation

{ TTextFileWriter }

constructor TTextFileWriter.Create(const AFolder, AFileName: String);
begin
  inherited Create;
  FFolder   := AFolder;
  FFileName := AFileName;
  FLock     := TCriticalSection.Create;
  // FWriter non viene aperto qui, ma alla prima WriteLine: così un eventuale
  // problema (cartella non creabile, permessi) emerge al primo utilizzo
  // reale, non alla semplice creazione dell'oggetto.
end;

destructor TTextFileWriter.Destroy;
begin
  FLock.Enter;
  try
    FWriter.Free; // chiude lo stream sottostante (di cui è proprietario)
  finally
    FLock.Leave;
  end;
  FLock.Free;
  inherited;
end;

function TTextFileWriter.GetFullPath: String;
begin
  Result := TPath.Combine(FFolder, FFileName);
end;

procedure TTextFileWriter.EnsureWriter;
var
  lStream: TFileStream;
begin
  if Assigned(FWriter) then Exit;

  if not TDirectory.Exists(FFolder) then
    TDirectory.CreateDirectory(FFolder);

  if TFile.Exists(GetFullPath) then
    lStream := TFileStream.Create(GetFullPath, fmOpenReadWrite or fmShareDenyNone)
  else
    lStream := TFileStream.Create(GetFullPath, fmCreate or fmShareDenyNone);
  lStream.Seek(0, soEnd);

  FWriter := TStreamWriter.Create(lStream, TEncoding.UTF8);
  FWriter.OwnStream;      // il writer libera lo stream quando viene liberato lui
  FWriter.AutoFlush := True;
end;

procedure TTextFileWriter.WriteLine(const AMessage: String);
var
  lLine: String;
begin
  FLock.Enter;
  try
    EnsureWriter;
    lLine := FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', Now) + '  ' + AMessage;
    FWriter.WriteLine(lLine);
  finally
    FLock.Leave;
  end;
end;

procedure TTextFileWriter.WriteRawLine(const AMessage: String);
begin
  FLock.Enter;
  try
    EnsureWriter;
    FWriter.WriteLine(AMessage);
  finally
    FLock.Leave;
  end;
end;

end.
