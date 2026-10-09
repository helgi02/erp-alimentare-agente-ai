unit uControllerRicette;

interface

uses
  System.SysUtils,
  System.JSON,
  System.DateUtils,
  System.Generics.Collections,
  MVCFramework,
  MVCFramework.Commons,
  MVCFramework.Logger,
  uModelProdottoFinito,
  uModelSemilavorato,
  uServiziRicette;

type
  // Lettura delle ricette (ricette_prodotti_finiti e ricette_semilavorati, versionate).
  // Solo GET: una ricetta non si modifica con una PUT, si crea una nuova versione
  // (CreaNuovaVersione, usata dallo scenario 3), e la scrittura resta nel flusso di
  // adattamento in chat.
  // Tre endpoint sotto /api/ricette/<tipo>/($id): le due tabelle hanno sequence
  // indipendenti, quindi un /api/ricette/($id) senza tipo sarebbe ambiguo.
  [MVCPath('/api/ricette')]
  TControllerRicette = class(TMVCController)
  public
    // Elenco sintetico di tutte le ricette correnti (prodotti finiti + semilavorati): vista
    // "Ricette e distinte".
    [MVCPath('')]
    [MVCHTTPMethod([httpGET])]
    procedure GetAll(ctx: TWebContext);

    // Ricetta corrente completa (componenti + costo) del prodotto finito ($id).
    [MVCPath('/prodotti-finiti/($id)')]
    [MVCHTTPMethod([httpGET])]
    procedure GetByProdottoFinito(ctx: TWebContext);

    // Come sopra, per un semilavorato ($id).
    [MVCPath('/semilavorati/($id)')]
    [MVCHTTPMethod([httpGET])]
    procedure GetBySemilavorato(ctx: TWebContext);
  end;

implementation

// Stessa forma JSON di uRicetteToolProvider per TCostoComponenteRicetta {tipo, id,
// denominazione, quantita_standard, unita_misura_dose, costo_unitario, costo_totale}: un
// componente ha lo stesso contratto in chat e qui.
function ComponentiToJSONArray(AComponenti: TObjectList<TCostoComponenteRicetta>): TJSONArray;
var
  LComponente: TCostoComponenteRicetta;
  LObj: TJSONObject;
begin
  Result := TJSONArray.Create;
  for LComponente in AComponenti do
  begin
    LObj := TJSONObject.Create;
    if LComponente.IsComponenteMateriaPrima then
      LObj.AddPair('tipo', 'materia_prima')
    else
      LObj.AddPair('tipo', 'semilavorato');
    LObj.AddPair('id', TJSONNumber.Create(LComponente.ComponenteID));
    LObj.AddPair('denominazione', LComponente.Denominazione);
    LObj.AddPair('quantita_standard', TJSONNumber.Create(LComponente.QuantitaStandard));
    LObj.AddPair('unita_misura_dose', LComponente.UnitaMisuraDose);
    LObj.AddPair('costo_unitario', TJSONNumber.Create(LComponente.CostoUnitario));
    LObj.AddPair('costo_totale', TJSONNumber.Create(LComponente.CostoTotale));
    // False solo per i semilavorati (schema senza resa di produzione, vedi
    // TCostoComponenteRicetta.CostoDisponibile): costo 0 per costruzione, il frontend deve
    // mostrare "non disponibile", non "gratis".
    LObj.AddPair('costo_disponibile', TJSONBool.Create(LComponente.CostoDisponibile));
    Result.AddElement(LObj);
  end;
end;

procedure TControllerRicette.GetAll(ctx: TWebContext);
var
  LRicette: TObjectList<TRicettaCorrenteSintetica>;
  LArray: TJSONArray;
  LRicetta: TRicettaCorrenteSintetica;
  LObj: TJSONObject;
begin
  LRicette := TServizioRicette.GetRicetteCorrenti;
  try
    LArray := TJSONArray.Create;
    for LRicetta in LRicette do
    begin
      LObj := TJSONObject.Create;
      if LRicetta.IsProdottoFinito then
        LObj.AddPair('tipo', 'prodotto_finito')
      else
        LObj.AddPair('tipo', 'semilavorato');
      LObj.AddPair('entita_id', TJSONNumber.Create(LRicetta.EntitaID));
      LObj.AddPair('codice', LRicetta.Codice);
      LObj.AddPair('denominazione', LRicetta.Denominazione);
      LObj.AddPair('ricetta_id', TJSONNumber.Create(LRicetta.RicettaID));
      LObj.AddPair('versione', TJSONNumber.Create(LRicetta.Versione));
      LObj.AddPair('valida_dal', DateToISO8601(LRicetta.ValidaDal));
      LObj.AddPair('creato_da', LRicetta.CreatoDa);
      LObj.AddPair('note', LRicetta.Note);
      LObj.AddPair('numero_componenti', TJSONNumber.Create(LRicetta.NumeroComponenti));
      LArray.AddElement(LObj);
    end;

    Render(LArray);
  finally
    LRicette.Free;
  end;
end;

procedure TControllerRicette.GetByProdottoFinito(ctx: TWebContext);
var
  LID: Integer;
  LProdotto: TProdottoFinito;
  LCosto: TCostoRicetta;
  LRoot: TJSONObject;
begin
  LID := ctx.Request.Params['id'].ToInteger;

  // Distingue "prodotto inesistente" da "prodotto senza ancora una ricetta" (normale per un
  // prodotto appena creato): due 404 con messaggio diverso.
  LProdotto := TProdottoFinito.GetByID(LID);
  if LProdotto = nil then
  begin
    Render(HTTP_STATUS.NotFound, 'Prodotto finito non trovato.');
    Exit;
  end;
  LProdotto.Free;

  try
    LCosto := TServizioRicette.CalcolaCostoRicettaProdottoFinito(LID);
  except
    // CalcolaCostoRicettaProdottoFinito solleva la stessa Exception generica sia se non
    // c'e' una ricetta corrente (404 legittimo) sia per qualunque altro problema nel
    // calcolo (unita' di misura incoerenti in ConvertiQuantita, prezzo mancante). Si
    // distingue dal messaggio (Pos, come in TControllerMateriePrime.Insert): solo il primo
    // caso e' un 404. Gli altri non vanno travestiti da "nessuna ricetta" (il frontend
    // tratta quel 404 come stato atteso, view-ricette.js statoNessunaRicetta, e non
    // finirebbero nei log): si rilanciano con raise e DMVCFramework li rende un 500 col
    // messaggio originale.
    on E: Exception do
    begin
      if Pos('nessuna ricetta corrente', E.Message) > 0 then
      begin
        Render(HTTP_STATUS.NotFound, 'Nessuna ricetta corrente per questo prodotto finito.');
        Exit;
      end
      else
        raise;
    end;
  end;

  // Render(LRoot) libera LRoot: un altro Free sarebbe un doppio free (EInvalidPointer a
  // runtime). Nel try/finally resta solo LCosto, di cui siamo proprietari.
  try
    LRoot := TJSONObject.Create;
    LRoot.AddPair('prodotto_finito_id', TJSONNumber.Create(LCosto.ProdottoFinitoID));
    LRoot.AddPair('ricetta_id', TJSONNumber.Create(LCosto.RicettaID));
    LRoot.AddPair('versione', TJSONNumber.Create(LCosto.Versione));
    LRoot.AddPair('costo_totale', TJSONNumber.Create(LCosto.CostoTotale));
    // False se la ricetta ha un semilavorato (TCostoRicetta.CostoCompleto): costo_totale e'
    // parziale e il frontend deve segnalarlo.
    LRoot.AddPair('costo_completo', TJSONBool.Create(LCosto.CostoCompleto));
    LRoot.AddPair('componenti', ComponentiToJSONArray(LCosto.Componenti));

    Render(LRoot);
  finally
    LCosto.Free;
  end;
end;

procedure TControllerRicette.GetBySemilavorato(ctx: TWebContext);
var
  LID: Integer;
  LSemilavorato: TSemilavorato;
  LCosto: TCostoRicettaSemilavorato;
  LRoot: TJSONObject;
begin
  LID := ctx.Request.Params['id'].ToInteger;

  LSemilavorato := TSemilavorato.GetByID(LID);
  if LSemilavorato = nil then
  begin
    Render(HTTP_STATUS.NotFound, 'Semilavorato non trovato.');
    Exit;
  end;
  LSemilavorato.Free;

  try
    LCosto := TServizioRicette.CalcolaCostoRicettaSemilavorato(LID);
  except
    // Come in GetByProdottoFinito: solo "nessuna ricetta corrente" e' un 404, gli altri
    // errori propagano.
    on E: Exception do
    begin
      if Pos('nessuna ricetta corrente', E.Message) > 0 then
      begin
        Render(HTTP_STATUS.NotFound, 'Nessuna ricetta corrente per questo semilavorato.');
        Exit;
      end
      else
        raise;
    end;
  end;

  // Come in GetByProdottoFinito: Render libera LRoot.
  try
    LRoot := TJSONObject.Create;
    LRoot.AddPair('semilavorato_id', TJSONNumber.Create(LCosto.SemilavoratoID));
    LRoot.AddPair('ricetta_id', TJSONNumber.Create(LCosto.RicettaID));
    LRoot.AddPair('versione', TJSONNumber.Create(LCosto.Versione));
    LRoot.AddPair('costo_totale', TJSONNumber.Create(LCosto.CostoTotale));
    LRoot.AddPair('costo_completo', TJSONBool.Create(LCosto.CostoCompleto));
    LRoot.AddPair('componenti', ComponentiToJSONArray(LCosto.Componenti));

    Render(LRoot);
  finally
    LCosto.Free;
  end;
end;

end.
