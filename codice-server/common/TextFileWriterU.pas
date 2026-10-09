unit TextFileWriterU;

// Scrive righe di testo con timestamp su file, in append, thread-safe, senza conoscenza del
// dominio.
// L'handle si apre una sola volta (alla prima WriteLine) e resta aperto; AutoFlush scrive
// comunque ogni riga subito. Ogni istanza ha il proprio lock, quindi file diversi non si
// bloccano a vicenda.
// Il file e' aperto con fmShareDenyNone: piu' istanze sullo stesso file non danno errore ma
// le scritture non sono coordinate (va bene con un file per istanza).
// Le eccezioni non vengono ingoiate (cartella non creabile, disco pieno...): le gestisce il
// chiamante.

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

    // Scrive AMessage su una riga con timestamp; crea la cartella alla prima chiamata.
    // Solleva un'eccezione se la scrittura fallisce.
    procedure WriteLine(const AMessage: String);
    // Come WriteLine senza timestamp, per formati strutturati (CSV).
    procedure WriteRawLine(const AMessage: String);
  end;

implementation

constructor TTextFileWriter.Create(const AFolder, AFileName: String);
begin
  inherited Create;
  FFolder   := AFolder;
  FFileName := AFileName;
  FLock     := TCriticalSection.Create;
  // FWriter si apre alla prima WriteLine, cosi' un problema (cartella, permessi) emerge al
  // primo uso e non alla creazione.
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
