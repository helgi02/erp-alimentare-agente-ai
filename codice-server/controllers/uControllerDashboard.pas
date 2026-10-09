unit uControllerDashboard;

interface

uses
  System.SysUtils,
  System.JSON,
  MVCFramework,
  MVCFramework.Commons,
  uServiziDashboard;

type
  // Endpoint di sola lettura per la home del frontend web.
  //
  // Controller volutamente sottile, come gli altri del progetto: tutta
  // la logica sta in TServizioDashboard (services/uServiziDashboard.pas),
  // qui restano solo il routing e la traduzione di un'eccezione in
  // risposta HTTP. La differenza rispetto ai controller CRUD delle
  // anagrafiche e' che non c'e' un model da serializzare: i dati sono
  // aggregazioni, e il servizio restituisce gia' il JSON finale.
  //
  // Non espone verbi di scrittura: la dashboard non modifica nulla.
  [MVCPath('/api/dashboard')]
  TControllerDashboard = class(TMVCController)
  public
    [MVCPath('')]
    [MVCHTTPMethod([httpGET])]
    procedure GetRiepilogo(ctx: TWebContext);
  end;

implementation

{ TControllerDashboard }

procedure TControllerDashboard.GetRiepilogo(ctx: TWebContext);
var
  LRiepilogo: TJSONObject;
begin
  try
    LRiepilogo := TServizioDashboard.Riepilogo;
    // Render assume la proprieta' dell'oggetto JSON e lo libera dopo
    // averlo serializzato: nessuna Free esplicita, e nessun try..finally
    // attorno (liberarlo qui provocherebbe una doppia distruzione).
    Render(LRiepilogo);
  except
    on E: Exception do
      Render(HTTP_STATUS.InternalServerError,
        'Errore nel calcolo del riepilogo dashboard: ' + E.Message);
  end;
end;

end.
