unit uControllerTracciabilita;

interface

uses
  System.SysUtils,
  System.JSON,
  MVCFramework,
  MVCFramework.Commons,
  uServiziTracciabilita;

type
  // Endpoint di sola lettura per l'albero di propagazione di un lotto
  // (scenario 1, ritiro/richiamo): a partire da un lotto di origine
  // (materia prima, semilavorato o prodotto finito) risale/scende la
  // catena di consumi/produzioni fino ai DDT di uscita e ai clienti
  // raggiunti. Tutta la logica di attraversamento del grafo vive in
  // TServizioTracciabilita (services/uServiziTracciabilita.pas); questo
  // controller si limita, come i suoi gemelli, a leggere l'id, delegare
  // e tradurre l'esito in risposta HTTP.
  //
  //   GET /api/tracciabilita/materie-prime/($id)
  //   GET /api/tracciabilita/semilavorati/($id)
  //   GET /api/tracciabilita/prodotti-finiti/($id)
  //
  // Nested path sotto un'unica base, non tre controller separati come
  // per i lotti: qui i tre endpoint condividono lo stesso "verbo"
  // (traccia questo lotto) e differiscono solo per il tipo di lotto di
  // partenza, esattamente la situazione per cui TControllerRicette usa
  // /api/ricette/<tipo>/($id) invece di tre basi indipendenti - stessa
  // convenzione, stesso motivo (id non ambiguo, un solo controller da
  // registrare per un'unica "funzionalita'" con tre varianti di input).
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

{ TControllerTracciabilita }

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
