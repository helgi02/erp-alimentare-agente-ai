unit uControllerSemilavorati;

interface

uses
  System.SysUtils,
  System.JSON,
  System.Generics.Collections,
  MVCFramework,
  MVCFramework.Commons,
  MVCFramework.Logger,
  uModelSemilavorato,
  uModelAllergene;

type
  // Controller di sola lettura per l'anagrafica semilavorati (tabella
  // anagrafiche_semilavorati). Stessa forma di TControllerMateriePrime/
  // TControllerProdottiFiniti (elenco, singolo, allergeni nidificati sotto
  // /($id)/allergeni), ma SENZA Create/Update/Delete: la richiesta che ha
  // originato questo controller era "visualizzare la lista dei prodotti,
  // semilavorati e ricette, e il get del singolo di ogni entita'" - solo
  // lettura, appunto. Il model TSemilavorato ha gia' tutto cio' che
  // servirebbe per la scrittura (Insert/Update/Delete/SetAllergeni): se
  // in futuro serve anche l'anagrafica scrivibile da frontend, aggiungere
  // qui gli endpoint POST/PUT/DELETE e' un mirror immediato di
  // TControllerProdottiFiniti, non richiede toccare il model.
  [MVCPath('/api/semilavorati')]
  TControllerSemilavorati = class(TMVCController)
  public
    [MVCPath('')]
    [MVCHTTPMethod([httpGET])]
    procedure GetAll(ctx: TWebContext);

    [MVCPath('/($id)')]
    [MVCHTTPMethod([httpGET])]
    procedure GetByID(ctx: TWebContext);

    [MVCPath('/($id)/allergeni')]
    [MVCHTTPMethod([httpGET])]
    procedure GetAllergeni(ctx: TWebContext);
  end;

implementation

{ TControllerSemilavorati }

procedure TControllerSemilavorati.GetAll(ctx: TWebContext);
var
  LSemilavorati: TObjectList<TSemilavorato>;
  LArray: TJSONArray;
  LSemilavorato: TSemilavorato;
begin
  LSemilavorati := TSemilavorato.GetAll;
  try
    LArray := TJSONArray.Create;
    for LSemilavorato in LSemilavorati do
      LArray.AddElement(LSemilavorato.ToJSONObject);

    Render(LArray);
  finally
    LSemilavorati.Free;
  end;
end;

procedure TControllerSemilavorati.GetByID(ctx: TWebContext);
var
  LID: Integer;
  LSemilavorato: TSemilavorato;
begin
  LID := ctx.Request.Params['id'].ToInteger;

  LSemilavorato := TSemilavorato.GetByID(LID);
  if LSemilavorato = nil then
  begin
    Render(HTTP_STATUS.NotFound, 'Semilavorato non trovato.');
    Exit;
  end;

  try
    Render(LSemilavorato.ToJSONObject);
  finally
    LSemilavorato.Free;
  end;
end;

procedure TControllerSemilavorati.GetAllergeni(ctx: TWebContext);
var
  LID: Integer;
  LAllergeni: TObjectList<TAllergene>;
  LArray: TJSONArray;
  LAllergene: TAllergene;
begin
  LID := ctx.Request.Params['id'].ToInteger;

  LAllergeni := TSemilavorato.GetAllergeni(LID);
  try
    LArray := TJSONArray.Create;
    for LAllergene in LAllergeni do
      LArray.AddElement(LAllergene.ToJSONObject);

    Render(LArray);
  finally
    LAllergeni.Free;
  end;
end;

end.
