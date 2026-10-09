unit uControllerFornitori;

interface

uses
  System.SysUtils,
  System.JSON,
  System.Generics.Collections,
  MVCFramework,
  MVCFramework.Commons,
  MVCFramework.Logger,
  uModelFornitore;

type
  [MVCPath('/api/fornitori')]
  TControllerFornitori = class(TMVCController)
  public
    [MVCPath('')]
    [MVCHTTPMethod([httpGET])]
    procedure GetAll(ctx: TWebContext);

    [MVCPath('/($id)')]
    [MVCHTTPMethod([httpGET])]
    procedure GetByID(ctx: TWebContext);

    [MVCPath('')]
    [MVCHTTPMethod([httpPOST])]
    procedure Create(ctx: TWebContext);

    [MVCPath('/($id)')]
    [MVCHTTPMethod([httpPUT])]
    procedure Update(ctx: TWebContext);

    [MVCPath('/($id)')]
    [MVCHTTPMethod([httpDELETE])]
    procedure Delete(ctx: TWebContext);
  end;

implementation

{ TControllerFornitori }

procedure TControllerFornitori.GetAll(ctx: TWebContext);
var
  LFornitori: TObjectList<TFornitore>;
  LArray: TJSONArray;
  LFornitore: TFornitore;
begin
  LFornitori := TFornitore.GetAll;
  try
    LArray := TJSONArray.Create;
    for LFornitore in LFornitori do
      LArray.AddElement(LFornitore.ToJSONObject);

    Render(LArray);
  finally
    LFornitori.Free;
  end;
end;

procedure TControllerFornitori.GetByID(ctx: TWebContext);
var
  LID: Integer;
  LFornitore: TFornitore;
begin
  LID := ctx.Request.Params['id'].ToInteger;

  LFornitore := TFornitore.GetByID(LID);
  if LFornitore = nil then
  begin
    Render(HTTP_STATUS.NotFound, 'Fornitore non trovato.');
    Exit;
  end;

  try
    Render(LFornitore.ToJSONObject);
  finally
    LFornitore.Free;
  end;
end;

procedure TControllerFornitori.Create(ctx: TWebContext);
var
  LFornitore: TFornitore;
  LBody: TJSONObject;
begin
  // ctx.Request.BodyAsJSONObject non esiste in TMVCWebRequest: si usa il
  // parser JSON dell'RTL (System.JSON, gia' importato) sul body grezzo.
  // ParseJSONValue restituisce nil se il body non e' JSON valido: il
  // controllo subito dopo evita di passare nil a FromJSONObject.
  LBody := TJSONObject.ParseJSONValue(ctx.Request.Body) as TJSONObject;
  if LBody = nil then
  begin
    Render(HTTP_STATUS.BadRequest, 'Corpo della richiesta non e'' un JSON valido.');
    Exit;
  end;

  try
    LFornitore := TFornitore.Create;
    try
      LFornitore.FromJSONObject(LBody);

      // Validazione minima dei campi obbligatori
      if (LFornitore.RagioneSociale = '') or
         (LFornitore.PartitaIva = '') or
         (LFornitore.Email = '') then
      begin
        Render(HTTP_STATUS.BadRequest,
          'Campi obbligatori mancanti: ragione_sociale, partita_iva, email.');
        Exit;
      end;

      try
        LFornitore.Insert;
      except
        on E: Exception do
        begin
          if Pos('fornitori_partita_iva_key', E.Message) > 0 then
          begin
            Render(HTTP_STATUS.Conflict,
              'Esiste gi� un fornitore con questa partita IVA.');
            Exit;
          end
          else
            raise;
        end;
      end;

      Render(HTTP_STATUS.Created, LFornitore.ToJSONObject);
    finally
      LFornitore.Free;
    end;
  finally
    LBody.Free;
  end;
end;

procedure TControllerFornitori.Update(ctx: TWebContext);
var
  LID: Integer;
  LFornitore: TFornitore;
  LBody: TJSONObject;
begin
  LID := ctx.Request.Params['id'].ToInteger;

  // Vedi commento in TControllerFornitori.Create: BodyAsJSONObject non
  // esiste in TMVCWebRequest, si usa il parser JSON dell'RTL.
  LBody := TJSONObject.ParseJSONValue(ctx.Request.Body) as TJSONObject;
  if LBody = nil then
  begin
    Render(HTTP_STATUS.BadRequest, 'Corpo della richiesta non e'' un JSON valido.');
    Exit;
  end;

  try
    LFornitore := TFornitore.GetByID(LID);
    if LFornitore = nil then
    begin
      Render(HTTP_STATUS.NotFound, 'Fornitore non trovato.');
      Exit;
    end;

    try
      LFornitore.FromJSONObject(LBody);

      try
        if not LFornitore.Update then
        begin
          Render(HTTP_STATUS.NotFound, 'Fornitore non trovato.');
          Exit;
        end;
      except
        on E: Exception do
        begin
          if Pos('fornitori_partita_iva_key', E.Message) > 0 then
          begin
            Render(HTTP_STATUS.Conflict,
              'Esiste gi� un fornitore con questa partita IVA.');
            Exit;
          end
          else
            raise;
        end;
      end;

      Render(LFornitore.ToJSONObject);
    finally
      LFornitore.Free;
    end;
  finally
    LBody.Free;
  end;
end;

procedure TControllerFornitori.Delete(ctx: TWebContext);
var
  LID: Integer;
begin
  LID := ctx.Request.Params['id'].ToInteger;

  if TFornitore.Delete(LID) then
    Render(HTTP_STATUS.NoContent, '')
  else
    Render(HTTP_STATUS.NotFound, 'Fornitore non trovato.');
end;

end.
