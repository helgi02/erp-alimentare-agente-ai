unit uCORSController;

interface

uses
  MVCFramework,
  MVCFramework.Commons,
  System.SysUtils,      // <--- Fondamentale per TEncoding
  GlobalU,
//  AppConfigU,
//  JOSE.Core.JWT,
//  JOSE.Core.JWS,
//  JOSE.Core.Builder,
//  JOSE.Core.JWK,
//  JOSE.Types.Bytes,
//  JOSE.Encoding.Base64,
  JsonDataObjects;

type
  TMVCCORSBaseController = class(TMVCController)
  public
    procedure OnBeforeAction(Context: TWebContext; const AActionName: string; var Handled: Boolean); override;

     //function ValidateToken(aToken: string; out aSub: string; out aRole: string): TTokenValidationResult;
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

//function TMVCCORSBaseController.ValidateToken(aToken: string; out aSub: string; out aRole: string): TTokenValidationResult;
//var
//  lJwt: TJWT;
//  LKey: TJWK;
//  lJsonObj: TJSONObject;
//begin
//  aSub := '';
//  aRole := '';
//
//  if (aToken = '') or (aToken = 'null') then
//    Exit(tvrMissing);
//
//  LKey := TJWK.Create(TEncoding.UTF8.GetBytes(TKeyManager.GetJWTSecret));
//  try
//    try
//      lJwt := TJOSE.Verify(LKey, aToken);
//      try
//        if not Assigned(lJwt) then
//          Exit(tvrDecodedInvalid);
//
//        if not lJwt.Verified then
//          Exit(tvrInvalid);
//
//        // Controlla scadenza
//        if Now > lJwt.Claims.Expiration then
//          Exit(tvrExpired);
//
//        lJsonObj := nil;
//        try
//          lJsonObj := TJSONObject.Parse(lJwt.Claims.JSON.ToJSON) as TJSONObject;
//          if Assigned(lJsonObj) then
//          begin
//            aSub := lJsonObj.Values['sub'].Value;
//            if lJsonObj.Contains('role') then
//              aRole := lJsonObj.Values['role'].Value;
//          end;
//        finally
//          lJsonObj.Free;
//        end;
//
//        Exit(tvrValid);
//
//      finally
//        lJwt.Free;
//      end;
//    except
//      on E: Exception do
//      begin
//        aSub := '{"error": "JWT_ERROR"}';
//        Exit(tvrError);
//      end;
//    end;
//  finally
//    LKey.Free;
//  end;
//end;

end.
