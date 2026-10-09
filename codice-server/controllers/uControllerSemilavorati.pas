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
  // Lettura dell'anagrafica semilavorati (elenco, singolo, allergeni sotto
  // /($id)/allergeni), senza Create/Update/Delete: serve solo la visualizzazione. Il model
  // TSemilavorato ha gia' Insert/Update/Delete/SetAllergeni, quindi la scrittura si
  // aggiunge copiando TControllerProdottiFiniti.
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
