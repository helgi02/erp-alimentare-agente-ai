unit uControllerProdottiFiniti;

interface

uses
  System.SysUtils,
  System.JSON,
  System.Generics.Collections,
  MVCFramework,
  MVCFramework.Commons,
  MVCFramework.Logger,
  uModelProdottoFinito,
  uModelAllergene;

type
  // Controller CRUD per l'anagrafica prodotti finiti (tabella
  // anagrafiche_prodotti_finiti). Stessa struttura di
  // TControllerMateriePrime, allergeni compresi: gli allergeni
  // dichiarati sono la stessa relazione many-to-many (qui la tabella
  // ponte e' anagrafiche_prodotti_finiti_allergeni) e restano nidificati
  // sotto /($id)/allergeni perche' appartengono a QUEL prodotto, non
  // sono un'anagrafica a se'.
  //
  // Sul prodotto finito gli allergeni pesano piu' che sulla materia
  // prima: sono il dato che finisce in etichetta ai sensi del Reg. UE
  // 1169/2011, ed e' quello che lo scenario 3 (adattamento ricetta)
  // deve poter verificare.
  [MVCPath('/api/prodotti-finiti')]
  TControllerProdottiFiniti = class(TMVCController)
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

{ TControllerProdottiFiniti }

procedure TControllerProdottiFiniti.GetAll(ctx: TWebContext);
var
  LProdotti: TObjectList<TProdottoFinito>;
  LArray: TJSONArray;
  LProdotto: TProdottoFinito;
begin
  LProdotti := TProdottoFinito.GetAll;
  try
    LArray := TJSONArray.Create;
    for LProdotto in LProdotti do
      LArray.AddElement(LProdotto.ToJSONObject);

    Render(LArray);
  finally
    LProdotti.Free;
  end;
end;

procedure TControllerProdottiFiniti.GetByID(ctx: TWebContext);
var
  LID: Integer;
  LProdotto: TProdottoFinito;
begin
  LID := ctx.Request.Params['id'].ToInteger;

  LProdotto := TProdottoFinito.GetByID(LID);
  if LProdotto = nil then
  begin
    Render(HTTP_STATUS.NotFound, 'Prodotto finito non trovato.');
    Exit;
  end;

  try
    Render(LProdotto.ToJSONObject);
  finally
    LProdotto.Free;
  end;
end;

procedure TControllerProdottiFiniti.Create(ctx: TWebContext);
var
  LProdotto: TProdottoFinito;
  LJSON: TJSONObject;
  LNuovoID: Integer;
begin
  LJSON := TJSONObject.ParseJSONValue(ctx.Request.Body) as TJSONObject;
  if LJSON = nil then
  begin
    Render(HTTP_STATUS.BadRequest, 'Corpo della richiesta non valido.');
    Exit;
  end;

  LProdotto := TProdottoFinito.Create;
  try
    try
      LProdotto.FromJSONObject(LJSON);
      LNuovoID := LProdotto.Insert;
      LProdotto.ID := LNuovoID;

      Context.Response.StatusCode := HTTP_STATUS.Created;
      Render(LProdotto.ToJSONObject);
    except
      on E: Exception do
        Render(HTTP_STATUS.BadRequest,
          'Impossibile creare il prodotto finito: ' + E.Message);
    end;
  finally
    LProdotto.Free;
    LJSON.Free;
  end;
end;

procedure TControllerProdottiFiniti.Update(ctx: TWebContext);
var
  LID: Integer;
  LProdotto: TProdottoFinito;
  LJSON: TJSONObject;
begin
  LID := ctx.Request.Params['id'].ToInteger;

  LProdotto := TProdottoFinito.GetByID(LID);
  if LProdotto = nil then
  begin
    Render(HTTP_STATUS.NotFound, 'Prodotto finito non trovato.');
    Exit;
  end;

  LJSON := TJSONObject.ParseJSONValue(ctx.Request.Body) as TJSONObject;
  if LJSON = nil then
  begin
    LProdotto.Free;
    Render(HTTP_STATUS.BadRequest, 'Corpo della richiesta non valido.');
    Exit;
  end;

  try
    try
      LProdotto.FromJSONObject(LJSON);
      // L'ID resta quello dell'URL: e' l'URL a identificare la risorsa,
      // non il corpo della richiesta. Cosi' un id diverso nel JSON non
      // puo' far aggiornare per sbaglio un altro record.
      LProdotto.ID := LID;
      LProdotto.Update;

      Render(LProdotto.ToJSONObject);
    except
      on E: Exception do
        Render(HTTP_STATUS.BadRequest,
          'Impossibile aggiornare il prodotto finito: ' + E.Message);
    end;
  finally
    LProdotto.Free;
    LJSON.Free;
  end;
end;

procedure TControllerProdottiFiniti.Delete(ctx: TWebContext);
var
  LID: Integer;
begin
  LID := ctx.Request.Params['id'].ToInteger;

  try
    if not TProdottoFinito.Delete(LID) then
    begin
      Render(HTTP_STATUS.NotFound, 'Prodotto finito non trovato.');
      Exit;
    end;

    Context.Response.StatusCode := HTTP_STATUS.NoContent;
  except
    on E: Exception do
      // Tipicamente una violazione di foreign key: il prodotto e' gia'
      // usato in ricette, lotti o righe d'ordine. Non e' un errore del
      // server ma un conflitto con dati esistenti, da cui il 409.
      Render(HTTP_STATUS.Conflict,
        'Impossibile eliminare il prodotto finito: ' + E.Message);
  end;
end;

procedure TControllerProdottiFiniti.GetAllergeni(ctx: TWebContext);
var
  LID: Integer;
  LAllergeni: TObjectList<TAllergene>;
  LArray: TJSONArray;
  LAllergene: TAllergene;
begin
  LID := ctx.Request.Params['id'].ToInteger;

  LAllergeni := TProdottoFinito.GetAllergeni(LID);
  try
    LArray := TJSONArray.Create;
    for LAllergene in LAllergeni do
      LArray.AddElement(LAllergene.ToJSONObject);

    Render(LArray);
  finally
    LAllergeni.Free;
  end;
end;

procedure TControllerProdottiFiniti.SetAllergeni(ctx: TWebContext);
var
  LID, i: Integer;
  LJSON: TJSONValue;
  LArray: TJSONArray;
  LIDs: TArray<Integer>;
begin
  LID := ctx.Request.Params['id'].ToInteger;

  // Il corpo atteso e' un array di id allergene: [1, 4, 7].
  // Sostituzione integrale, non aggiunta: e' un PUT, quindi il corpo
  // descrive lo stato finale della relazione.
  LJSON := TJSONObject.ParseJSONValue(ctx.Request.Body);
  if not (LJSON is TJSONArray) then
  begin
    LJSON.Free;
    Render(HTTP_STATUS.BadRequest,
      'Corpo della richiesta non valido: atteso un array di id allergene.');
    Exit;
  end;

  LArray := TJSONArray(LJSON);
  try
    SetLength(LIDs, LArray.Count);
    for i := 0 to LArray.Count - 1 do
      LIDs[i] := (LArray.Items[i] as TJSONNumber).AsInt;

    TProdottoFinito.SetAllergeni(LID, LIDs);
    Context.Response.StatusCode := HTTP_STATUS.NoContent;
  except
    on E: Exception do
      Render(HTTP_STATUS.BadRequest,
        'Impossibile aggiornare gli allergeni: ' + E.Message);
  end;

  LArray.Free;
end;

end.
