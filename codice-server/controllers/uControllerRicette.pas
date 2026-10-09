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
  // Controller di sola lettura per le ricette (tabelle ricette_prodotti_
  // finiti e ricette_semilavorati, entrambe versionate - vedi i commenti
  // sui rispettivi model). Non e' un CRUD anagrafico come i controller
  // gemelli: una ricetta non si "modifica" con una PUT, si crea una nuova
  // versione (TRicettaProdottoFinito/TRicettaSemilavorato.CreaNuovaVersione,
  // gia' usato dallo scenario 3 via TServizioRicette) - percio' qui ci
  // sono solo GET, coerenti con l'ambito di questo controller (mostrare le
  // ricette nel frontend, non scriverle: la scrittura resta riservata al
  // flusso di adattamento in chat, uRicetteToolProvider.pas).
  //
  // Tre endpoint, non uno per entita': la ricetta CORRENTE di un prodotto
  // finito o di un semilavorato e' nidificata sotto /api/ricette/<tipo>/
  // ($id) invece che sotto /api/prodotti-finiti/($id)/ricetta - ricette_
  // prodotti_finiti e ricette_semilavorati sono due tabelle con due
  // sequence id INDIPENDENTI, quindi un solo /api/ricette/($id) senza
  // "tipo" nel percorso sarebbe ambiguo (un id potrebbe esistere in
  // entrambe le tabelle, con dati diversi).
  [MVCPath('/api/ricette')]
  TControllerRicette = class(TMVCController)
  public
    // Elenco sintetico di TUTTE le ricette correnti (prodotti finiti +
    // semilavorati insieme): la vista "Ricette e distinte" della sidebar.
    [MVCPath('')]
    [MVCHTTPMethod([httpGET])]
    procedure GetAll(ctx: TWebContext);

    // Ricetta corrente completa (componenti + costo) del prodotto finito
    // ($id). E' quello che aprira' il bottone "vai alla ricetta" nella
    // scheda di un prodotto finito.
    [MVCPath('/prodotti-finiti/($id)')]
    [MVCHTTPMethod([httpGET])]
    procedure GetByProdottoFinito(ctx: TWebContext);

    // Gemello del precedente per un semilavorato ($id).
    [MVCPath('/semilavorati/($id)')]
    [MVCHTTPMethod([httpGET])]
    procedure GetBySemilavorato(ctx: TWebContext);
  end;

implementation

{ Funzioni di supporto, private all'unit }

// Comune a GetByProdottoFinito/GetBySemilavorato: stessa forma
// {tipo, id, denominazione, quantita_standard, unita_misura_dose,
// costo_unitario, costo_totale} gia' usata da uRicetteToolProvider.pas
// per lo stesso DTO (TCostoComponenteRicetta) esposto via MCP - stesse
// chiavi apposta, cosi' un componente di ricetta ha la stessa forma JSON
// sia che arrivi in chat sia che arrivi qui: chi guarda le due integrazioni
// per la relazione di tirocinio vede lo stesso contratto, non due formati
// diversi per lo stesso dato.
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
    // False solo per componenti semilavorato (schema senza resa di
    // produzione, vedi il commento su TCostoComponenteRicetta.
    // CostoDisponibile in uServiziRicette.pas): in quel caso costo_unitario
    // e costo_totale sono 0 per costruzione, non un dato mancante da
    // trattare come tale - il frontend deve mostrarlo come "non disponibile",
    // non come "gratis".
    LObj.AddPair('costo_disponibile', TJSONBool.Create(LComponente.CostoDisponibile));
    Result.AddElement(LObj);
  end;
end;

{ TControllerRicette }

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

  // Distingue "prodotto inesistente" da "prodotto esistente ma senza
  // ancora una ricetta": due situazioni diverse per chi guarda il
  // frontend (la seconda e' normale per un prodotto appena creato, la
  // prima e' un id sbagliato), entrambe un 404 ma con messaggio diverso.
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
    // CalcolaCostoRicettaProdottoFinito solleva la STESSA classe Exception
    // generica sia quando non esiste una ricetta corrente (caso normale,
    // vedi il commento sopra: 404 con messaggio dedicato) sia per QUALSIASI
    // altro problema incontrato calcolando il costo di una ricetta che
    // invece esiste - es. un'incoerenza di unita' di misura intercettata
    // da ConvertiQuantita (uServiziRicette.pas), o un prezzo materia prima
    // del tutto assente (CostoUnitarioMateriaPrima). Va distinto per
    // messaggio (Pos, come gia' fatto altrove - vedi
    // TControllerMateriePrime.Insert per lo stesso idioma): SOLO il primo
    // caso e' un 404 legittimo. Qualunque altro errore NON va nascosto
    // dietro "nessuna ricetta corrente" - sarebbe un dato/calcolo rotto
    // travestito da stato normale, invisibile a chi guarda il frontend
    // (che tratta il 404 di questo endpoint come stato atteso, non come
    // errore - vedi statoNessunaRicetta in view-ricette.js) e persino ai
    // log (la richiesta non completerebbe mai con un errore tracciato).
    // Per questi altri casi si rilancia con "raise": il middleware di
    // DMVCFramework la trasforma in un 500 con il messaggio originale,
    // visibile e diagnosticabile.
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

  // NB: Render(LRoot) prende possesso di LRoot e lo libera lui stesso
  // (overload con AOwns di default True, vedi MVCFramework.pas) - un
  // altro Free qui sarebbe un doppio free (EInvalidPointer a runtime,
  // non un errore di compilazione: e' cosi' che si e' manifestato la
  // prima volta). Per questo LRoot NON compare nel try/finally: solo
  // LCosto, che restiamo noi a possedere, va liberato esplicitamente -
  // stesso principio gia' seguito da TControllerProdottiFiniti.GetByID
  // (Render(LProdotto.ToJSONObject) senza mai liberare quel JSON) e da
  // GetAll qui sopra (LArray passato a Render, mai liberato).
  try
    LRoot := TJSONObject.Create;
    LRoot.AddPair('prodotto_finito_id', TJSONNumber.Create(LCosto.ProdottoFinitoID));
    LRoot.AddPair('ricetta_id', TJSONNumber.Create(LCosto.RicettaID));
    LRoot.AddPair('versione', TJSONNumber.Create(LCosto.Versione));
    LRoot.AddPair('costo_totale', TJSONNumber.Create(LCosto.CostoTotale));
    // Vedi TCostoRicetta.CostoCompleto (uServiziRicette.pas): False se la
    // ricetta contiene almeno un semilavorato, il cui costo non e'
    // calcolabile - costo_totale in quel caso e' parziale, e il frontend
    // deve segnalarlo invece di presentarlo come il costo reale.
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
    // Vedi il commento gemello in GetByProdottoFinito: solo "nessuna
    // ricetta corrente" e' un 404 legittimo, ogni altro errore (es. il
    // conflitto di unita' di misura di ConvertiQuantita) deve propagare
    // com'e', non essere nascosto dietro un placido "nessuna ricetta".
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

  // Vedi il commento gemello in GetByProdottoFinito sul perche' LRoot non
  // va liberato esplicitamente: Render(LRoot) se ne occupa gia'.
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
