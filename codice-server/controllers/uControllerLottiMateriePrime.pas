unit uControllerLottiMateriePrime;

interface

uses
  System.SysUtils,
  System.JSON,
  MVCFramework,
  MVCFramework.Commons,
  uServiziLotti;

type
  // Endpoint di sola lettura dei lotti di materia prima (tabella
  // lotti_materie_prime), a supporto della vista Lotti del frontend web.
  //
  //   GET /api/lotti-materie-prime                     tutti i lotti (FEFO)
  //   GET /api/lotti-materie-prime?materia_prima_id=7   solo quelli di una materia prima
  //   GET /api/lotti-materie-prime/(id)                 un singolo lotto
  //
  // Nessun POST/PUT/DELETE: vedi il commento di classe in
  // TServizioLotti (services/uServiziLotti.pas) sul perche' la
  // scrittura di un lotto non passa da qui.
  //
  // Controller volutamente sottile (stesso principio di
  // TControllerOrdiniVendita): legge/valida i parametri, delega tutta
  // la query - JOIN sull'anagrafica materie prime compreso - a
  // TServizioLotti, traduce l'esito in risposta HTTP.
  [MVCPath('/api/lotti-materie-prime')]
  TControllerLottiMateriePrime = class(TMVCController)
  private
    // Legge un intero dalla query string; 0 (= "filtro assente") se il
    // parametro manca o non e' numerico. Stessa scelta e stesso motivo
    // di TControllerOrdiniVendita.ParamIntero: un URL sporco non deve
    // rompere la vista, deve solo comportarsi come "nessun filtro".
    function ParamIntero(ctx: TWebContext; const ANome: string): Integer;
  public
    [MVCPath('')]
    [MVCHTTPMethod([httpGET])]
    procedure GetElenco(ctx: TWebContext);

    [MVCPath('/($id)')]
    [MVCHTTPMethod([httpGET])]
    procedure GetDettaglio(ctx: TWebContext);
  end;

implementation

{ TControllerLottiMateriePrime }

function TControllerLottiMateriePrime.ParamIntero(ctx: TWebContext;
  const ANome: string): Integer;
var
  LValore: string;
begin
  LValore := Trim(ctx.Request.QueryStringParam(ANome));
  if (LValore = '') or not TryStrToInt(LValore, Result) then
    Result := 0;
end;

procedure TControllerLottiMateriePrime.GetElenco(ctx: TWebContext);
begin
  try
    Render(TServizioLotti.ElencoMateriePrime(ParamIntero(ctx, 'materia_prima_id')));
  except
    on E: Exception do
      Render(HTTP_STATUS.InternalServerError,
        'Errore nella lettura dei lotti di materia prima: ' + E.Message);
  end;
end;

procedure TControllerLottiMateriePrime.GetDettaglio(ctx: TWebContext);
var
  LID: Integer;
  LLotto: TJSONObject;
begin
  if not TryStrToInt(ctx.Request.Params['id'], LID) then
  begin
    Render(HTTP_STATUS.BadRequest, 'Identificativo lotto non valido.');
    Exit;
  end;

  try
    LLotto := TServizioLotti.DettaglioMateriaPrima(LID);
    if LLotto = nil then
    begin
      Render(HTTP_STATUS.NotFound, 'Lotto di materia prima non trovato.');
      Exit;
    end;

    Render(LLotto);
  except
    on E: Exception do
      Render(HTTP_STATUS.InternalServerError,
        'Errore nella lettura del lotto di materia prima: ' + E.Message);
  end;
end;

end.
