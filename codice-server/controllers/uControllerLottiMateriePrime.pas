unit uControllerLottiMateriePrime;

interface

uses
  System.SysUtils,
  System.JSON,
  MVCFramework,
  MVCFramework.Commons,
  uServiziLotti;

type
  // Lettura dei lotti di materia prima per la vista Lotti. GET /api/lotti-materie-prime
  // (tutti, FEFO), ?materia_prima_id=7 (una materia prima), /(id) (un lotto). Niente
  // POST/PUT/DELETE: vedi TServizioLotti sul perche' la scrittura di un lotto non passa da
  // qui. Controller sottile: valida i parametri e delega la query (con la JOIN sulle
  // materie prime) a TServizioLotti.
  [MVCPath('/api/lotti-materie-prime')]
  TControllerLottiMateriePrime = class(TMVCController)
  private
    // Intero dalla query string; 0 ("filtro assente") se manca o non e' numerico: un URL
    // sporco non deve rompere la vista (come TControllerOrdiniVendita.ParamIntero).
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
