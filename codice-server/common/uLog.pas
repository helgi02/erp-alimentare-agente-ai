unit uLog;

interface

uses

  Winapi.Messages,
  Winapi.Windows,

  System.SysUtils,
  System.Classes,
  System.ioUtils,

  Vcl.ComCtrls,
  Vcl.Graphics,

  uType, Vcl.StdCtrls;

type

  TLog = Class

  Private
    class var FComponentLog: TComponent;
    class var FVerbosity: TVerbosity;
    class var FFullPathFileLog: String;

  public
    class procedure Initialize(AComponent: TComponent; AVerbosityLevel: TVerbosity; AFullPathFileLog: String);
    class procedure SetVerbosity(AVerbosityMinimalLevel: TVerbosity);
    class Procedure Write(const AMessage: string; AVerbosityMinimalLevel: TVerbosity = vbMinimale; ALogType: TLogType = ltMessage);

  End;

implementation

class procedure TLog.Initialize(AComponent: TComponent; AVerbosityLevel: TVerbosity; AFullPathFileLog: String);
begin

  FComponentLog := AComponent;
  FVerbosity := AVerbosityLevel;
  FFullPathFileLog := AFullPathFileLog;

end;

class procedure TLog.SetVerbosity(AVerbosityMinimalLevel: TVerbosity);
begin

  FVerbosity := AVerbosityMinimalLevel;

end;

class Procedure TLog.Write(const AMessage: string; AVerbosityMinimalLevel: TVerbosity = vbMinimale; ALogType: TLogType = ltMessage);
var
  LTimestampedMessage: string;
begin

  if not (FComponentLog is TMemo) then
    Exit;

  if AVerbosityMinimalLevel > FVerbosity then
    Exit;

  LTimestampedMessage := FormatDateTime('dd/mm/yyyy hh:mm:ss.zzz', now) + '   ' + AMessage;

  // Scrittura su file: non tocca la VCL, resta sul thread chiamante.
  if FVerbosity = vbDettagliataSuFile then
    TFile.AppendAllText(FFullPathFileLog, LTimestampedMessage + sLineBreak);

  // Scrittura sul TMemo: va marshalled sul thread principale, perche' puo' arrivare dai
  // thread Indy.
  TThread.Queue(nil,
    procedure
    begin
      TMemo(FComponentLog).Lines.BeginUpdate;
      try
        TMemo(FComponentLog).Lines.Add(LTimestampedMessage);
        TMemo(FComponentLog).Perform(WM_VSCROLL, SB_BOTTOM, SB_THUMBTRACK);
      finally
        TMemo(FComponentLog).Lines.EndUpdate;
      end;
    end);

end;

end.
