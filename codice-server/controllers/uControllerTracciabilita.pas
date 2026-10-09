unit uControllerTracciabilita;

interface

uses
  System.SysUtils,
  System.JSON,
  MVCFramework,
  MVCFramework.Commons,
  uServiziTracciabilita;

type
  // Albero di propagazione di un lotto (scenario 1): da un lotto di origine (materia prima,
  // semilavorato o prodotto finito) la catena di consumi/produzioni fino ai DDT di uscita e
  // ai clienti raggiunti. L'attraversamento del grafo e' in TServizioTracciabilita; qui si
  // legge l'id, si delega e si traduce l'esito.
  // GET /api/tracciabilita/materie-prime/($id), /semilavorati/($id),
  // /prodotti-finiti/($id).
  // Percorso nidificato in un solo controller, come /api/ricette/<tipo>/($id): i tre
  // endpoint differiscono solo per il tipo di lotto di partenza.
  [MVCPath('/api/tracciabilita')]
  TControllerTracciabilita = class(TMVCController)
  public
    [MVCPath('/materie-prime/($id)')]
    [MVCHTTPMethod([httpGET])]
    procedure GetAlberoMateriaPrima(ctx: TWebContext);

    [MVCPath('/semilavorati/($id)')]
    [MVCHTTPMethod([httpGET])]
    procedure GetAlberoSemilavorato(ctx: TWebContext);

    [MVCPath('/prodotti-finiti/($id)')]
    [MVCHTTPMethod([httpGET])]
    procedure GetAlberoProdottoFinito(ctx: TWebContext);
  end;

implementation

procedure TControllerTracciabilita.GetAlberoMateriaPrima(ctx: TWebContext);
var
  LID: Integer;
  LAlbero: TJSONObject;
begin
  if not TryStrToInt(ctx.Request.Params['id'], LID) then
  begin
    Render(HTTP_STATUS.BadRequest, 'Identificativo lotto non valido.');
    Exit;
  end;

  try
    LAlbero := TServizioTracciabilita.AlberoMateriaPrima(LID);
    if LAlbero = nil then
    begin
      Render(HTTP_STATUS.NotFound, 'Lotto di materia prima non trovato.');
      Exit;
    end;

    Render(LAlbero);
  except
    on E: Exception do
      Render(HTTP_STATUS.InternalServerError,
        'Errore nella ricostruzione della tracciabilita'' del lotto di materia prima: ' + E.Message);
  end;
end;

procedure TControllerTracciabilita.GetAlberoSemilavorato(ctx: TWebContext);
var
  LID: Integer;
  LAlbero: TJSONObject;
begin
  if not TryStrToInt(ctx.Request.Params['id'], LID) then
  begin
    Render(HTTP_STATUS.BadRequest, 'Identificativo lotto non valido.');
    Exit;
  end;

  try
    LAlbero := TServizioTracciabilita.AlberoSemilavorato(LID);
    if LAlbero = nil then
    begin
      Render(HTTP_STATUS.NotFound, 'Lotto di semilavorato non trovato.');
      Exit;
    end;

    Render(LAlbero);
  except
    on E: Exception do
      Render(HTTP_STATUS.InternalServerError,
        'Errore nella ricostruzione della tracciabilita'' del lotto di semilavorato: ' + E.Message);
  end;
end;

procedure TControllerTracciabilita.GetAlberoProdottoFinito(ctx: TWebContext);
var
  LID: Integer;
  LAlbero: TJSONObject;
begin
  if not TryStrToInt(ctx.Request.Params['id'], LID) then
  begin
    Render(HTTP_STATUS.BadRequest, 'Identificativo lotto non valido.');
    Exit;
  end;

  try
    LAlbero := TServizioTracciabilita.AlberoProdottoFinito(LID);
    if LAlbero = nil then
    begin
      Render(HTTP_STATUS.NotFound, 'Lotto di prodotto finito non trovato.');
      Exit;
    end;

    Render(LAlbero);
  except
    on E: Exception do
      Render(HTTP_STATUS.InternalServerError,
        'Errore nella ricostruzione della tracciabilita'' del lotto di prodotto finito: ' + E.Message);
  end;
end;

end.
