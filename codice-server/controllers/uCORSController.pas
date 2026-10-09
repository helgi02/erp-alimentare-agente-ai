unit uCORSController;

interface

uses
  MVCFramework,
  MVCFramework.Commons,
  System.SysUtils,
  GlobalU,
  JsonDataObjects;

type
  TMVCCORSBaseController = class(TMVCController)
  public
    procedure OnBeforeAction(Context: TWebContext; const AActionName: string; var Handled: Boolean); override;

end;

implementation

procedure TMVCCORSBaseController.OnBeforeAction(Context: TWebContext; const AActionName: string; var Handled: Boolean);
begin
  if Context.Request.HTTPMethod = httpOPTIONS then
  begin
    Context.Response.StatusCode := 204;
    Handled := True;
    Exit;
  end;
  inherited;
end;

end.
