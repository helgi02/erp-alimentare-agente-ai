unit uControllerOrdiniVendita;

interface

uses
  System.SysUtils,
  System.JSON,
  MVCFramework,
  MVCFramework.Commons,
  uServiziOrdiniVendita;

type
  // Lettura degli ordini di vendita per la schermata Vendite. GET /api/ordini-vendita con
  // filtri cliente_id, prodotto_id, data_inizio, data_fine (YYYY-MM-DD), stato, pagina,
  // per_pagina; GET /api/ordini-vendita/(id).
  // Differenze dai controller delle anagrafiche: l'elenco non e' un GetAll (gli ordini
  // crescono senza limite, quindi filtro e paginazione stanno nell'endpoint); niente
  // POST/PUT/DELETE, perche' nessuno scenario modifica ordini e sarebbe codice mai
  // esercitato.
  // Controller sottile: valida i parametri e delega a TServizioOrdiniVendita.
  [MVCPath('/api/ordini-vendita')]
  TControllerOrdiniVendita = class(TMVCController)
  private
    // Intero dalla query string; 0 se assente o non numerico, la sentinella di "filtro non
    // applicato" di TFiltriOrdiniVendita: un URL sporco non deve rompere la vista.
    function ParamIntero(ctx: TWebContext; const ANome: string): Integer;

    // Data ISO YYYY-MM-DD, con parsing manuale per non dipendere dai FormatSettings.
    // Solleva un'eccezione se presente ma non valida: ignorarla in silenzio darebbe numeri
    // plausibili e sbagliati.
    function ParamData(ctx: TWebContext; const ANome: string): TDateTime;
  public
    [MVCPath('')]
    [MVCHTTPMethod([httpGET])]
    procedure GetElenco(ctx: TWebContext);

    [MVCPath('/($id)')]
    [MVCHTTPMethod([httpGET])]
    procedure GetDettaglio(ctx: TWebContext);
  end;

implementation

function TControllerOrdiniVendita.ParamIntero(ctx: TWebContext;
  const ANome: string): Integer;
var
  LValore: string;
begin
  LValore := Trim(ctx.Request.QueryStringParam(ANome));
  if (LValore = '') or not TryStrToInt(LValore, Result) then
    Result := 0;
end;

function TControllerOrdiniVendita.ParamData(ctx: TWebContext;
  const ANome: string): TDateTime;
var
  LValore: string;
  LAnno, LMese, LGiorno: Integer;
begin
  LValore := Trim(ctx.Request.QueryStringParam(ANome));
  if LValore = '' then
    Exit(0);

  if (Length(LValore) <> 10) or
     not TryStrToInt(Copy(LValore, 1, 4), LAnno) or
     not TryStrToInt(Copy(LValore, 6, 2), LMese) or
     not TryStrToInt(Copy(LValore, 9, 2), LGiorno) then
    raise Exception.CreateFmt(
      'Parametro "%s": data "%s" non valida, formato atteso YYYY-MM-DD.',
      [ANome, LValore]);

  Result := EncodeDate(LAnno, LMese, LGiorno);
end;

procedure TControllerOrdiniVendita.GetElenco(ctx: TWebContext);
var
  LFiltri: TFiltriOrdiniVendita;
begin
  try
    LFiltri.ClienteID  := ParamIntero(ctx, 'cliente_id');
    LFiltri.ProdottoID := ParamIntero(ctx, 'prodotto_id');
    LFiltri.DataInizio := ParamData(ctx, 'data_inizio');
    LFiltri.DataFine   := ParamData(ctx, 'data_fine');
    LFiltri.Stato      := Trim(ctx.Request.QueryStringParam('stato'));
    LFiltri.Pagina     := ParamIntero(ctx, 'pagina');
    LFiltri.PerPagina  := ParamIntero(ctx, 'per_pagina');

    // Uno stato inesistente e' una richiesta priva di senso: meglio dirlo che mostrare un
    // elenco vuoto.
    if (LFiltri.Stato <> '') and
       not TServizioOrdiniVendita.StatoValido(LFiltri.Stato) then
    begin
      Render(HTTP_STATUS.BadRequest,
        'Stato "' + LFiltri.Stato + '" non valido. Valori ammessi: ' +
        'confermato, spedito, consegnato, annullato.');
      Exit;
    end;

    // Periodo rovesciato: quasi sempre un errore di compilazione dei campi.
    if (LFiltri.DataInizio > 0) and (LFiltri.DataFine > 0) and
       (LFiltri.DataInizio > LFiltri.DataFine) then
    begin
      Render(HTTP_STATUS.BadRequest,
        'Il parametro data_inizio e'' successivo a data_fine.');
      Exit;
    end;

    // Render libera l'oggetto: niente Free.
    Render(TServizioOrdiniVendita.Elenco(LFiltri));
  except
    on E: Exception do
      Render(HTTP_STATUS.InternalServerError,
        'Errore nella lettura degli ordini di vendita: ' + E.Message);
  end;
end;

procedure TControllerOrdiniVendita.GetDettaglio(ctx: TWebContext);
var
  LID: Integer;
  LOrdine: TJSONObject;
begin
  if not TryStrToInt(ctx.Request.Params['id'], LID) then
  begin
    Render(HTTP_STATUS.BadRequest, 'Identificativo ordine non valido.');
    Exit;
  end;

  try
    LOrdine := TServizioOrdiniVendita.Dettaglio(LID);
    if LOrdine = nil then
    begin
      Render(HTTP_STATUS.NotFound, 'Ordine di vendita non trovato.');
      Exit;
    end;

    Render(LOrdine);
  except
    on E: Exception do
      Render(HTTP_STATUS.InternalServerError,
        'Errore nella lettura dell''ordine di vendita: ' + E.Message);
  end;
end;

end.
