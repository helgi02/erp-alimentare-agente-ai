unit uControllerLottiSemilavorati;

interface

uses
  System.SysUtils,
  System.JSON,
  MVCFramework,
  MVCFramework.Commons,
  uServiziLotti;

type
  // Endpoint di sola lettura dei lotti di semilavorato (tabella
  // lotti_semilavorati). Vedi il commento gemello e piu' esteso in
  // uControllerLottiMateriePrime.pas: stessa struttura, stessi motivi.
  //
  //   GET /api/lotti-semilavorati
  //   GET /api/lotti-semilavorati?semilavorato_id=101
  //   GET /api/lotti-semilavorati/(id)
  [MVCPath('/api/lotti-semilavorati')]
  TControllerLottiSemilavorati = class(TMVCController)
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

{ TControllerLottiSemilavorati }

function TControllerLottiSemilavorati.ParamIntero(ctx: TWebContext;
  const ANome: string): Integer;
var
  LValore: string;
begin
  LValore := Trim(ctx.Request.QueryStringParam(ANome));
  if (LValore = '') or not TryStrToInt(LValore, Result) then
    Result := 0;
end;

procedure TControllerLottiSemilavorati.GetElenco(ctx: TWebContext);
begin
  try
    Render(TServizioLotti.ElencoSemilavorati(ParamIntero(ctx, 'semilavorato_id')));
  except
    on E: Exception do
      Render(HTTP_STATUS.InternalServerError,
        'Errore nella lettura dei lotti di semilavorato: ' + E.Message);
  end;
end;

procedure TControllerLottiSemilavorati.GetDettaglio(ctx: TWebContext);
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
    LLotto := TServizioLotti.DettaglioSemilavorato(LID);
    if LLotto = nil then
    begin
      Render(HTTP_STATUS.NotFound, 'Lotto di semilavorato non trovato.');
      Exit;
    end;

    Render(LLotto);
  except
    on E: Exception do
      Render(HTTP_STATUS.InternalServerError,
        'Errore nella lettura del lotto di semilavorato: ' + E.Message);
  end;
end;

end.
