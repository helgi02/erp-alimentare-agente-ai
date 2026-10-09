unit uControllerDashboard;

interface

uses
  System.SysUtils,
  System.JSON,
  MVCFramework,
  MVCFramework.Commons,
  uServiziDashboard;

type
  // Endpoint di sola lettura per la home. Controller sottile: la logica e' in
  // TServizioDashboard, che restituisce gia' il JSON delle aggregazioni; qui routing e
  // traduzione delle eccezioni in risposta HTTP. Nessun verbo di scrittura.
  [MVCPath('/api/dashboard')]
  TControllerDashboard = class(TMVCController)
  public
    [MVCPath('')]
    [MVCHTTPMethod([httpGET])]
    procedure GetRiepilogo(ctx: TWebContext);
  end;

implementation

procedure TControllerDashboard.GetRiepilogo(ctx: TWebContext);
var
  LRiepilogo: TJSONObject;
begin
  try
    LRiepilogo := TServizioDashboard.Riepilogo;
    // Render prende possesso dell'oggetto JSON e lo libera: niente Free, altrimenti doppia
    // distruzione.
    Render(LRiepilogo);
  except
    on E: Exception do
      Render(HTTP_STATUS.InternalServerError,
        'Errore nel calcolo del riepilogo dashboard: ' + E.Message);
  end;
end;

end.
