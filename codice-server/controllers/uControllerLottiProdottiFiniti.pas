unit uControllerLottiProdottiFiniti;

interface

uses
  System.SysUtils,
  System.JSON,
  MVCFramework,
  MVCFramework.Commons,
  uServiziLotti;

type
  // Lettura dei lotti di prodotto finito. Stessa struttura di uControllerLottiMateriePrime.
  // GET /api/lotti-prodotti-finiti, ?prodotto_finito_id=12, /(id).
  [MVCPath('/api/lotti-prodotti-finiti')]
  TControllerLottiProdottiFiniti = class(TMVCController)
  private
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

function TControllerLottiProdottiFiniti.ParamIntero(ctx: TWebContext;
  const ANome: string): Integer;
var
  LValore: string;
begin
  LValore := Trim(ctx.Request.QueryStringParam(ANome));
  if (LValore = '') or not TryStrToInt(LValore, Result) then
    Result := 0;
end;

procedure TControllerLottiProdottiFiniti.GetElenco(ctx: TWebContext);
begin
  try
    Render(TServizioLotti.ElencoProdottiFiniti(ParamIntero(ctx, 'prodotto_finito_id')));
  except
    on E: Exception do
      Render(HTTP_STATUS.InternalServerError,
        'Errore nella lettura dei lotti di prodotto finito: ' + E.Message);
  end;
end;

procedure TControllerLottiProdottiFiniti.GetDettaglio(ctx: TWebContext);
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
    LLotto := TServizioLotti.DettaglioProdottoFinito(LID);
    if LLotto = nil then
    begin
      Render(HTTP_STATUS.NotFound, 'Lotto di prodotto finito non trovato.');
      Exit;
    end;

    Render(LLotto);
  except
    on E: Exception do
      Render(HTTP_STATUS.InternalServerError,
        'Errore nella lettura del lotto di prodotto finito: ' + E.Message);
  end;
end;

end.
