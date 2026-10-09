unit uControllerClienti;

interface

uses
  System.SysUtils,
  System.JSON,
  System.Generics.Collections,
  MVCFramework,
  MVCFramework.Commons,
  MVCFramework.Logger,
  uModelCliente;

type
  // Controller CRUD per l'anagrafica clienti (tabella clienti).
  // Stessa struttura di TControllerFornitori: e' il pattern standard che
  // replichiamo per ogni anagrafica del gestionale (vedi commento in
  // uModelCliente sulla differenza di indirizzi fatturazione/consegna,
  // che qui non cambia nulla a livello di controller perche' la
  // serializzazione resta delegata a ToJSONObject/FromJSONObject).
  [MVCPath('/api/clienti')]
  TControllerClienti = class(TMVCController)
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

{ TControllerClienti }

procedure TControllerClienti.GetAll(ctx: TWebContext);
var
  LClienti: TObjectList<TCliente>;
  LArray: TJSONArray;
  LCliente: TCliente;
begin
  LClienti := TCliente.GetAll;
  try
    LArray := TJSONArray.Create;
    for LCliente in LClienti do
      LArray.AddElement(LCliente.ToJSONObject);

    Render(LArray);
  finally
    LClienti.Free;
  end;
end;

procedure TControllerClienti.GetByID(ctx: TWebContext);
var
  LID: Integer;
  LCliente: TCliente;
begin
  LID := ctx.Request.Params['id'].ToInteger;

  LCliente := TCliente.GetByID(LID);
  if LCliente = nil then
  begin
    Render(HTTP_STATUS.NotFound, 'Cliente non trovato.');
    Exit;
  end;

  try
    Render(LCliente.ToJSONObject);
  finally
    LCliente.Free;
  end;
end;

procedure TControllerClienti.Create(ctx: TWebContext);
var
  LCliente: TCliente;
  LBody: TJSONObject;
begin
  // Vedi commento in TControllerFornitori.Create: BodyAsJSONObject non
  // esiste in TMVCWebRequest, si usa il parser JSON dell'RTL.
  LBody := TJSONObject.ParseJSONValue(ctx.Request.Body) as TJSONObject;
  if LBody = nil then
  begin
    Render(HTTP_STATUS.BadRequest, 'Corpo della richiesta non e'' un JSON valido.');
    Exit;
  end;

  try
    LCliente := TCliente.Create;
    try
      LCliente.FromJSONObject(LBody);

      // Validazione minima dei campi obbligatori
      if (LCliente.RagioneSociale = '') or
         (LCliente.PartitaIva = '') or
         (LCliente.Email = '') then
      begin
        Render(HTTP_STATUS.BadRequest,
          'Campi obbligatori mancanti: ragione_sociale, partita_iva, email.');
        Exit;
      end;

      try
        LCliente.Insert;
      except
        on E: Exception do
        begin
          if Pos('clienti_partita_iva_key', E.Message) > 0 then
          begin
            Render(HTTP_STATUS.Conflict,
              'Esiste gi� un cliente con questa partita IVA.');
            Exit;
          end
          else
            raise;
        end;
      end;

      Render(HTTP_STATUS.Created, LCliente.ToJSONObject);
    finally
      LCliente.Free;
    end;
  finally
    LBody.Free;
  end;
end;

procedure TControllerClienti.Update(ctx: TWebContext);
var
  LID: Integer;
  LCliente: TCliente;
  LBody: TJSONObject;
begin
  LID := ctx.Request.Params['id'].ToInteger;

  LBody := TJSONObject.ParseJSONValue(ctx.Request.Body) as TJSONObject;
  if LBody = nil then
  begin
    Render(HTTP_STATUS.BadRequest, 'Corpo della richiesta non e'' un JSON valido.');
    Exit;
  end;

  try
    LCliente := TCliente.GetByID(LID);
    if LCliente = nil then
    begin
      Render(HTTP_STATUS.NotFound, 'Cliente non trovato.');
      Exit;
    end;

    try
      LCliente.FromJSONObject(LBody);

      try
        if not LCliente.Update then
        begin
          Render(HTTP_STATUS.NotFound, 'Cliente non trovato.');
          Exit;
        end;
      except
        on E: Exception do
        begin
          if Pos('clienti_partita_iva_key', E.Message) > 0 then
          begin
            Render(HTTP_STATUS.Conflict,
              'Esiste gi� un cliente con questa partita IVA.');
            Exit;
          end
          else
            raise;
        end;
      end;

      Render(LCliente.ToJSONObject);
    finally
      LCliente.Free;
    end;
  finally
    LBody.Free;
  end;
end;

procedure TControllerClienti.Delete(ctx: TWebContext);
var
  LID: Integer;
begin
  LID := ctx.Request.Params['id'].ToInteger;

  // TCliente.Delete solleva un'eccezione se il cliente e' referenziato da
  // ordini_vendita o ddt_uscita (nessun ON DELETE CASCADE lato DB): la
  // intercettiamo per restituire un 409 invece di un 500 generico.
  try
    if TCliente.Delete(LID) then
      Render(HTTP_STATUS.NoContent, '')
    else
      Render(HTTP_STATUS.NotFound, 'Cliente non trovato.');
  except
    on E: Exception do
    begin
      Render(HTTP_STATUS.Conflict,
        'Impossibile eliminare: il cliente ha ordini o DDT collegati.');
    end;
  end;
end;

end.
