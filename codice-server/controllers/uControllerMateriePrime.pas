unit uControllerMateriePrime;

interface

uses
  System.SysUtils,
  System.JSON,
  System.Generics.Collections,
  MVCFramework,
  MVCFramework.Commons,
  MVCFramework.Logger,
  uModelMateriaPrima,
  uModelAllergene;

type
  // Controller CRUD per l'anagrafica materie prime (tabella
  // anagrafiche_materie_prime), piu' due endpoint dedicati alla gestione
  // degli allergeni dichiarati (tabella ponte
  // anagrafiche_materie_prime_allergeni). Questi ultimi sono nidificati
  // sotto la risorsa /($id)/allergeni perche' rappresentano una relazione
  // di appartenenza (gli allergeni di QUELLA materia prima), non
  // un'anagrafica a se stante da esporre come /api/materie-prime-allergeni.
  [MVCPath('/api/materie-prime')]
  TControllerMateriePrime = class(TMVCController)
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

    [MVCPath('/($id)/allergeni')]
    [MVCHTTPMethod([httpGET])]
    procedure GetAllergeni(ctx: TWebContext);

    [MVCPath('/($id)/allergeni')]
    [MVCHTTPMethod([httpPUT])]
    procedure SetAllergeni(ctx: TWebContext);
  end;

implementation

{ TControllerMateriePrime }

procedure TControllerMateriePrime.GetAll(ctx: TWebContext);
var
  LMateriePrime: TObjectList<TMateriaPrima>;
  LArray: TJSONArray;
  LMateriaPrima: TMateriaPrima;
begin
  LMateriePrime := TMateriaPrima.GetAll;
  try
    LArray := TJSONArray.Create;
    for LMateriaPrima in LMateriePrime do
      LArray.AddElement(LMateriaPrima.ToJSONObject);

    Render(LArray);
  finally
    LMateriePrime.Free;
  end;
end;

procedure TControllerMateriePrime.GetByID(ctx: TWebContext);
var
  LID: Integer;
  LMateriaPrima: TMateriaPrima;
begin
  LID := ctx.Request.Params['id'].ToInteger;

  LMateriaPrima := TMateriaPrima.GetByID(LID);
  if LMateriaPrima = nil then
  begin
    Render(HTTP_STATUS.NotFound, 'Materia prima non trovata.');
    Exit;
  end;

  try
    Render(LMateriaPrima.ToJSONObject);
  finally
    LMateriaPrima.Free;
  end;
end;

procedure TControllerMateriePrime.Create(ctx: TWebContext);
var
  LMateriaPrima: TMateriaPrima;
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
    LMateriaPrima := TMateriaPrima.Create;
    try
      LMateriaPrima.FromJSONObject(LBody);

      // Validazione minima dei campi obbligatori
      if (LMateriaPrima.Codice = '') or (LMateriaPrima.Denominazione = '') then
      begin
        Render(HTTP_STATUS.BadRequest,
          'Campi obbligatori mancanti: codice, denominazione.');
        Exit;
      end;

      try
        LMateriaPrima.Insert;
      except
        on E: Exception do
        begin
          if Pos('anagrafiche_materie_prime_codice_key', E.Message) > 0 then
          begin
            Render(HTTP_STATUS.Conflict,
              'Esiste gi� una materia prima con questo codice.');
            Exit;
          end
          else
            raise;
        end;
      end;

      Render(HTTP_STATUS.Created, LMateriaPrima.ToJSONObject);
    finally
      LMateriaPrima.Free;
    end;
  finally
    LBody.Free;
  end;
end;

procedure TControllerMateriePrime.Update(ctx: TWebContext);
var
  LID: Integer;
  LMateriaPrima: TMateriaPrima;
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
    LMateriaPrima := TMateriaPrima.GetByID(LID);
    if LMateriaPrima = nil then
    begin
      Render(HTTP_STATUS.NotFound, 'Materia prima non trovata.');
      Exit;
    end;

    try
      LMateriaPrima.FromJSONObject(LBody);

      try
        if not LMateriaPrima.Update then
        begin
          Render(HTTP_STATUS.NotFound, 'Materia prima non trovata.');
          Exit;
        end;
      except
        on E: Exception do
        begin
          if Pos('anagrafiche_materie_prime_codice_key', E.Message) > 0 then
          begin
            Render(HTTP_STATUS.Conflict,
              'Esiste gi� una materia prima con questo codice.');
            Exit;
          end
          else
            raise;
        end;
      end;

      Render(LMateriaPrima.ToJSONObject);
    finally
      LMateriaPrima.Free;
    end;
  finally
    LBody.Free;
  end;
end;

procedure TControllerMateriePrime.Delete(ctx: TWebContext);
var
  LID: Integer;
begin
  LID := ctx.Request.Params['id'].ToInteger;

  // TMateriaPrima.Delete solleva un'eccezione se la materia prima e'
  // referenziata da ordini fornitore, DDT entrata, lotti o righe ricetta
  // (nessun ON DELETE CASCADE lato DB): la intercettiamo per restituire un
  // 409 invece di un 500 generico.
  try
    if TMateriaPrima.Delete(LID) then
      Render(HTTP_STATUS.NoContent, '')
    else
      Render(HTTP_STATUS.NotFound, 'Materia prima non trovata.');
  except
    on E: Exception do
    begin
      Render(HTTP_STATUS.Conflict,
        'Impossibile eliminare: la materia prima e'' gi� utilizzata (ordini, DDT, lotti o ricette).');
    end;
  end;
end;

procedure TControllerMateriePrime.GetAllergeni(ctx: TWebContext);
var
  LID: Integer;
  LAllergeni: TObjectList<TAllergene>;
  LArray: TJSONArray;
  LAllergene: TAllergene;
begin
  LID := ctx.Request.Params['id'].ToInteger;

  // Nessun controllo di esistenza della materia prima: se l'id non esiste
  // la JOIN nel modello restituisce semplicemente una lista vuota, coerente
  // con la semantica di "quali sono gli allergeni di questa entita'".
  LAllergeni := TMateriaPrima.GetAllergeni(LID);
  try
    LArray := TJSONArray.Create;
    for LAllergene in LAllergeni do
      LArray.AddElement(LAllergene.ToJSONObject);

    Render(LArray);
  finally
    LAllergeni.Free;
  end;
end;

procedure TControllerMateriePrime.SetAllergeni(ctx: TWebContext);
var
  LID: Integer;
  LBody: TJSONValue;
  LArray: TJSONArray;
  LIDs: TArray<Integer>;
  i: Integer;
begin
  LID := ctx.Request.Params['id'].ToInteger;

  // Payload atteso: un array JSON di id allergene, es. [1, 3, 7].
  // Non un oggetto con proprieta' perche' la risorsa /allergeni
  // rappresenta gia' l'intera collezione da sostituire (PUT = replace).
  LBody := TJSONObject.ParseJSONValue(ctx.Request.Body);
  if not (LBody is TJSONArray) then
  begin
    Render(HTTP_STATUS.BadRequest,
      'Corpo della richiesta non valido: atteso un array di id allergene, es. [1, 3, 7].');
    LBody.Free;
    Exit;
  end;

  try
    LArray := TJSONArray(LBody);
    SetLength(LIDs, LArray.Count);
    for i := 0 to LArray.Count - 1 do
      LIDs[i] := LArray.Items[i].GetValue<Integer>;

    try
      TMateriaPrima.SetAllergeni(LID, LIDs);
    except
      on E: Exception do
      begin
        // Tipicamente una FK violata (allergene_id inesistente): la
        // transazione in SetAllergeni garantisce che in questo caso non
        // resti scritto nulla di parziale.
        Render(HTTP_STATUS.BadRequest,
          'Uno o piu'' id allergene non sono validi: ' + E.Message);
        Exit;
      end;
    end;

    Render(HTTP_STATUS.NoContent, '');
  finally
    LBody.Free;
  end;
end;

end.
