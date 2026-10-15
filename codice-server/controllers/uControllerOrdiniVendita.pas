unit uControllerOrdiniVendita;

interface

uses
  System.SysUtils,
  System.JSON,
  MVCFramework,
  MVCFramework.Commons,
  uServiziOrdiniVendita;

type
  // Endpoint di sola lettura degli ordini di vendita, a supporto della
  // schermata Vendite del frontend web.
  //
  //   GET /api/ordini-vendita
  //       ?cliente_id=  &prodotto_id=
  //       &data_inizio= &data_fine=     (YYYY-MM-DD)
  //       &stato=       &pagina=  &per_pagina=
  //   GET /api/ordini-vendita/(id)
  //
  // DUE DIFFERENZE RISPETTO AI CONTROLLER DELLE ANAGRAFICHE
  //
  // 1) L'elenco non e' un GetAll. TCliente.GetAll restituisce l'intera
  //    tabella e va bene: i clienti sono qualche centinaio. Gli ordini
  //    di vendita crescono senza limite, quindi filtro e paginazione
  //    devono stare nell'endpoint, non nel browser.
  //
  // 2) Non ci sono POST/PUT/DELETE. Nessuno dei tre scenari del
  //    tirocinio crea o modifica ordini di vendita: esporre verbi di
  //    scrittura che nessuno usa significherebbe scrivere e mantenere
  //    codice non esercitato, cioe' codice di cui non si sa se funziona.
  //
  // Il controller resta sottile come gli altri: legge e valida i
  // parametri, delega a TServizioOrdiniVendita, traduce l'esito in
  // risposta HTTP.
  [MVCPath('/api/ordini-vendita')]
  TControllerOrdiniVendita = class(TMVCController)
  private
    // Legge un parametro intero dalla query string. Restituisce 0 se
    // assente o non numerico: 0 e' la sentinella di "filtro non
    // applicato" usata da TFiltriOrdiniVendita, quindi un valore
    // spazzatura si comporta come un filtro assente invece di far
    // fallire la richiesta. Su una query string di una schermata e' la
    // scelta giusta: la vista non deve rompersi per un URL sporco.
    function ParamIntero(ctx: TWebContext; const ANome: string): Integer;

    // Legge una data in formato ISO YYYY-MM-DD. Parsing manuale e non
    // StrToDate per non dipendere dai FormatSettings del server, che
    // potrebbero attendersi un ordine o un separatore diversi.
    // Solleva un'eccezione se la stringa c'e' ma non e' valida: qui, a
    // differenza degli interi, ignorare in silenzio sarebbe pericoloso
    // (un periodo interpretato male produce numeri plausibili e
    // sbagliati).
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

{ TControllerOrdiniVendita }

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

    // Uno stato inesistente non e' un filtro sbagliato ma una richiesta
    // priva di senso: meglio dirlo, altrimenti si otterrebbe un elenco
    // vuoto e si penserebbe che non ci sono ordini.
    if (LFiltri.Stato <> '') and
       not TServizioOrdiniVendita.StatoValido(LFiltri.Stato) then
    begin
      Render(HTTP_STATUS.BadRequest,
        'Stato "' + LFiltri.Stato + '" non valido. Valori ammessi: ' +
        'confermato, spedito, consegnato, annullato.');
      Exit;
    end;

    // Periodo rovesciato: non produce risultati e quasi sempre e' un
    // errore di compilazione dei campi, non una richiesta voluta.
    if (LFiltri.DataInizio > 0) and (LFiltri.DataFine > 0) and
       (LFiltri.DataInizio > LFiltri.DataFine) then
    begin
      Render(HTTP_STATUS.BadRequest,
        'Il parametro data_inizio e'' successivo a data_fine.');
      Exit;
    end;

    // Render assume la proprieta' dell'oggetto e lo libera dopo la
    // serializzazione: nessuna Free esplicita qui.
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
