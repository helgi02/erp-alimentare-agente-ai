unit uServiziTracciabilita;

interface

uses
  System.SysUtils,
  System.JSON,
  System.DateUtils,
  System.Generics.Collections,
  DbU,
  uServiziLotti,
  uModelConsumoProduzioneSemilavorato,
  uModelConsumoProduzioneProdottoFinito;

type
  // Tracciabilita' "in avanti" di un lotto di materia prima o semilavorato: quali lotti di
  // semilavorato e prodotto finito lo contengono (anche su piu' livelli di distinta) e, per
  // ogni lotto di prodotto finito raggiunto, a quali ordini/clienti e' andato e se e' stato
  // spedito. E' la vista Tracciabilita' lotti (view-tracciabilita.js).
  // Un service a parte e non TServizioRitiroRichiamo: RisaliCatenaConsumoDa* fa gia' la
  // risalita, ma per aprire una non conformita' e restituire solo gli ID. Questa vista
  // serve a esplorare un lotto senza aprire nulla e richiede molti piu' dettagli per riga
  // (codice, denominazione, quantita', ordine/DDT, cliente). Unirli darebbe un servizio con
  // due responsabilita'.
  // "ordinato" vs "spedito": TServizioRitiroRichiamo.VerificaEsposizioneClienti tratta ogni
  // riga d'ordine come esposizione (lettura cautelativa per un richiamo). Qui si incrocia
  // ddt_uscita_righe: un ordine confermato non spedito compare con spedito=False e i campi
  // di spedizione null, senza un numero_ddt inventato. E' il miglioramento futuro segnalato
  // in quel commento.
  TServizioTracciabilita = class
  public
    // nil se il lotto di materia prima non esiste ("non trovato" e' un esito normale, come
    // TServizioLotti.DettaglioX).
    class function AlberoMateriaPrima(ALottoMateriaPrimaID: Integer): TJSONObject;
    class function AlberoSemilavorato(ALottoSemilavoratoID: Integer): TJSONObject;

    // Un lotto di prodotto finito e' gia' il capolinea: niente risalita, solo le sue
    // spedizioni.
    class function AlberoProdottoFinito(ALottoProdottoFinitoID: Integer): TJSONObject;
  end;

implementation

// Spedizioni di un lotto di prodotto finito: una riga per riga d'ordine
// (ordini_vendita_righe.lotto_prodotto_finito_id), con LEFT JOIN su
// ddt_uscita_righe/ddt_uscita, cosi' un ordine non ancora spedito compare con spedito=False
// invece di sparire.
function Spedizioni(ALottoProdottoFinitoID: Integer): TJSONArray;
const
  SQL =
    'SELECT ov.numero_ordine, ov.data_ordine, ov.stato AS stato_ordine, ' +
    'c.ragione_sociale AS cliente, ovr.quantita AS quantita_ordinata, ' +
    'ovr.unita_misura, du.numero_ddt, du.data_spedizione, dur.quantita_spedita ' +
    'FROM ordini_vendita_righe ovr ' +
    'JOIN ordini_vendita ov ON ov.id = ovr.ordine_vendita_id ' +
    'JOIN clienti c ON c.id = ov.cliente_id ' +
    'LEFT JOIN ddt_uscita_righe dur ON dur.ordine_vendita_riga_id = ovr.id ' +
    'LEFT JOIN ddt_uscita du ON du.id = dur.ddt_uscita_id ' +
    'WHERE ovr.lotto_prodotto_finito_id = :lotto_prodotto_finito_id ' +
    'ORDER BY ov.data_ordine';
var
  LAutoQuery: TAutoQuery;
  LRiga: TJSONObject;
begin
  Result := TJSONArray.Create;

  LAutoQuery := TDB.GetInstance.getQueryResult(SQL, [ALottoProdottoFinitoID]);
  try
    while not LAutoQuery.Query.Eof do
    begin
      with LAutoQuery.Query do
      begin
        LRiga := TJSONObject.Create;
        LRiga.AddPair('numero_ordine', FieldByName('numero_ordine').AsString);
        LRiga.AddPair('data_ordine', DateToISO8601(FieldByName('data_ordine').AsDateTime));
        LRiga.AddPair('stato_ordine', FieldByName('stato_ordine').AsString);
        LRiga.AddPair('cliente', FieldByName('cliente').AsString);
        LRiga.AddPair('quantita_ordinata', TJSONNumber.Create(FieldByName('quantita_ordinata').AsCurrency));
        LRiga.AddPair('unita_misura', FieldByName('unita_misura').AsString);

        if FieldByName('numero_ddt').IsNull then
        begin
          // Nessuna riga DDT: ordine confermato non spedito. I tre campi restano null, non
          // '' o 0: la vista deve distinguere "non spedito" da "spedito zero pezzi".
          LRiga.AddPair('spedito', TJSONBool.Create(False));
          LRiga.AddPair('numero_ddt', TJSONNull.Create);
          LRiga.AddPair('data_spedizione', TJSONNull.Create);
          LRiga.AddPair('quantita_spedita', TJSONNull.Create);
        end
        else
        begin
          LRiga.AddPair('spedito', TJSONBool.Create(True));
          LRiga.AddPair('numero_ddt', FieldByName('numero_ddt').AsString);
          LRiga.AddPair('data_spedizione', DateToISO8601(FieldByName('data_spedizione').AsDateTime));
          LRiga.AddPair('quantita_spedita', TJSONNumber.Create(FieldByName('quantita_spedita').AsCurrency));
        end;
      end;

      Result.AddElement(LRiga);
      LAutoQuery.Query.Next;
    end;
  finally
    LAutoQuery.Free;
  end;
end;

// Appendono un elemento a un elenco "raggiunti" (semilavorati o prodotti finiti),
// risolvendo l'anagrafica con TServizioLotti (stessa forma
// "entita_codice/entita_denominazione" della vista Lotti).
// "consumato_direttamente": True solo se il consumo parte esattamente dal lotto origine,
// senza livelli intermedi; indica quanto si e' lontani nella distinta.
// Unita' della quantita' consumata: quantita_consumata (consumi_produzione_*) non ha
// unita_misura propria, ed e' nell'unita' del lotto consumato (il componente a monte), non
// di quello prodotto a valle. Mostrarla con l'unita' del lotto raggiunto coincideva solo
// perche' i dati di test erano in kg: con i prodotti a pezzi (003_unita_vendita_pezzi.sql)
// "20 kg di canditi" sarebbe diventato "20 pz". Ogni nodo riceve quindi AUnitaConsumata,
// esposta come "unita_misura_consumata"; "unita_misura" resta quella del lotto raggiunto.
function UnitaMisuraDi(ALotto: TJSONObject): string;
var
  LValore: TJSONValue;
begin
  Result := '';
  if ALotto = nil then
    Exit;
  LValore := ALotto.GetValue('unita_misura');
  if (LValore <> nil) and not (LValore is TJSONNull) then
    Result := LValore.Value;
end;

// Unita' del semilavorato raggiunto ('' se il lotto non esiste piu'): serve alla ricorsione
// a valle, dove questo lotto diventa il componente consumato.
function AggiungiSemilavoratoRaggiunto(AArray: TJSONArray; ALottoSemilavoratoID: Integer;
  AConsumatoDirettamente: Boolean; AQuantitaConsumata: Currency;
  const AUnitaConsumata: string): string;
var
  LInfo: TJSONObject;
begin
  Result := '';
  LInfo := TServizioLotti.DettaglioSemilavorato(ALottoSemilavoratoID);
  if LInfo = nil then
    Exit; // dato anomalo (lotto referenziato da un consumo ma non piu' in anagrafica): si ignora questo nodo, non si blocca il resto dell'albero

  Result := UnitaMisuraDi(LInfo);
  LInfo.AddPair('consumato_direttamente', TJSONBool.Create(AConsumatoDirettamente));
  LInfo.AddPair('quantita_consumata', TJSONNumber.Create(AQuantitaConsumata));
  LInfo.AddPair('unita_misura_consumata', AUnitaConsumata);
  AArray.AddElement(LInfo);
end;

procedure AggiungiProdottoFinitoRaggiunto(AArray: TJSONArray; ALottoProdottoFinitoID: Integer;
  AConsumatoDirettamente: Boolean; AQuantitaConsumata: Currency;
  const AUnitaConsumata: string);
var
  LInfo: TJSONObject;
begin
  LInfo := TServizioLotti.DettaglioProdottoFinito(ALottoProdottoFinitoID);
  if LInfo = nil then
    Exit;

  LInfo.AddPair('consumato_direttamente', TJSONBool.Create(AConsumatoDirettamente));
  LInfo.AddPair('quantita_consumata', TJSONNumber.Create(AQuantitaConsumata));
  LInfo.AddPair('unita_misura_consumata', AUnitaConsumata);
  LInfo.AddPair('spedizioni', Spedizioni(ALottoProdottoFinitoID));
  AArray.AddElement(LInfo);
end;

// Esplorazione ricorsiva a valle di un lotto di semilavorato gia' raggiunto (non l'origine:
// qui "consumato_direttamente" e' sempre False). Gemella di
// TServizioRitiroRichiamo.EsploraLottoSemilavorato, ma accumula oggetti JSON completi e non
// solo ID.
procedure EsploraSemilavorato(ALottoSemilavoratoID: Integer; const AUnitaLotto: string;
  ASemilavoratiRaggiunti, AProdottiFinitiRaggiunti: TJSONArray; AVisitati: TList<Integer>);
var
  LConsumiInProdottoFinito: TObjectList<TConsumoProduzioneProdottoFinito>;
  LConsumiInSemilavorato: TObjectList<TConsumoProduzioneSemilavorato>;
  LConsumo1: TConsumoProduzioneProdottoFinito;
  LConsumo2: TConsumoProduzioneSemilavorato;
  LUnitaFiglio: string;
begin
  // Guardia anti-ciclo e anti-duplicazione, come nel gemello: un lotto puo' essere
  // raggiunto da piu' percorsi.
  if AVisitati.Contains(ALottoSemilavoratoID) then
    Exit;
  AVisitati.Add(ALottoSemilavoratoID);

  LConsumiInProdottoFinito :=
    TConsumoProduzioneProdottoFinito.GetByLottoSemilavorato(ALottoSemilavoratoID);
  try
    for LConsumo1 in LConsumiInProdottoFinito do
      AggiungiProdottoFinitoRaggiunto(AProdottiFinitiRaggiunti,
        LConsumo1.LottoProdottoFinitoID, False, LConsumo1.QuantitaConsumata, AUnitaLotto);
  finally
    LConsumiInProdottoFinito.Free;
  end;

  LConsumiInSemilavorato :=
    TConsumoProduzioneSemilavorato.GetByLottoSemilavoratoFiglio(ALottoSemilavoratoID);
  try
    for LConsumo2 in LConsumiInSemilavorato do
    begin
      LUnitaFiglio := AggiungiSemilavoratoRaggiunto(ASemilavoratiRaggiunti,
        LConsumo2.LottoSemilavoratoID, False, LConsumo2.QuantitaConsumata, AUnitaLotto);
      EsploraSemilavorato(LConsumo2.LottoSemilavoratoID, LUnitaFiglio,
        ASemilavoratiRaggiunti, AProdottiFinitiRaggiunti, AVisitati);
    end;
  finally
    LConsumiInSemilavorato.Free;
  end;
end;

class function TServizioTracciabilita.AlberoMateriaPrima(ALottoMateriaPrimaID: Integer): TJSONObject;
var
  LOrigine: TJSONObject;
  LSemilavoratiRaggiunti, LProdottiFinitiRaggiunti: TJSONArray;
  LVisitati: TList<Integer>;
  LConsumiDiretti1: TObjectList<TConsumoProduzioneProdottoFinito>;
  LConsumiDiretti2: TObjectList<TConsumoProduzioneSemilavorato>;
  LConsumo1: TConsumoProduzioneProdottoFinito;
  LConsumo2: TConsumoProduzioneSemilavorato;
  LUnitaFiglio: string;
begin
  LOrigine := TServizioLotti.DettaglioMateriaPrima(ALottoMateriaPrimaID);
  if LOrigine = nil then
    Exit(nil);

  LSemilavoratiRaggiunti := TJSONArray.Create;
  LProdottiFinitiRaggiunti := TJSONArray.Create;
  LVisitati := TList<Integer>.Create;
  try
    // Consumi diretti materia prima -> prodotto finito, senza semilavorato intermedio.
    LConsumiDiretti1 := TConsumoProduzioneProdottoFinito.GetByLottoMateriaPrima(ALottoMateriaPrimaID);
    try
      for LConsumo1 in LConsumiDiretti1 do
        AggiungiProdottoFinitoRaggiunto(LProdottiFinitiRaggiunti,
          LConsumo1.LottoProdottoFinitoID, True, LConsumo1.QuantitaConsumata,
          UnitaMisuraDi(LOrigine));
    finally
      LConsumiDiretti1.Free;
    end;

    // Consumi diretti materia prima -> semilavorato, poi esplorazione ricorsiva a valle di
    // ciascuno.
    LConsumiDiretti2 := TConsumoProduzioneSemilavorato.GetByLottoMateriaPrima(ALottoMateriaPrimaID);
    try
      for LConsumo2 in LConsumiDiretti2 do
      begin
        LUnitaFiglio := AggiungiSemilavoratoRaggiunto(LSemilavoratiRaggiunti,
          LConsumo2.LottoSemilavoratoID, True, LConsumo2.QuantitaConsumata,
          UnitaMisuraDi(LOrigine));
        EsploraSemilavorato(LConsumo2.LottoSemilavoratoID, LUnitaFiglio,
          LSemilavoratiRaggiunti, LProdottiFinitiRaggiunti, LVisitati);
      end;
    finally
      LConsumiDiretti2.Free;
    end;

    Result := TJSONObject.Create;
    Result.AddPair('lotto_origine', LOrigine);
    Result.AddPair('semilavorati_coinvolti', LSemilavoratiRaggiunti);
    Result.AddPair('prodotti_finiti_raggiunti', LProdottiFinitiRaggiunti);
  finally
    LVisitati.Free;
  end;
end;

class function TServizioTracciabilita.AlberoSemilavorato(ALottoSemilavoratoID: Integer): TJSONObject;
var
  LOrigine: TJSONObject;
  LSemilavoratiRaggiunti, LProdottiFinitiRaggiunti: TJSONArray;
  LVisitati: TList<Integer>;
  LConsumiInProdottoFinito: TObjectList<TConsumoProduzioneProdottoFinito>;
  LConsumiInSemilavorato: TObjectList<TConsumoProduzioneSemilavorato>;
  LConsumo1: TConsumoProduzioneProdottoFinito;
  LConsumo2: TConsumoProduzioneSemilavorato;
  LUnitaFiglio: string;
begin
  LOrigine := TServizioLotti.DettaglioSemilavorato(ALottoSemilavoratoID);
  if LOrigine = nil then
    Exit(nil);

  LSemilavoratiRaggiunti := TJSONArray.Create;
  LProdottiFinitiRaggiunti := TJSONArray.Create;
  LVisitati := TList<Integer>.Create;
  try
    // Il lotto origine non va riesplorato come componente di se stesso (possibile con una
    // distinta anomala ciclica): lo si segna visitato prima di iniziare.
    LVisitati.Add(ALottoSemilavoratoID);

    LConsumiInProdottoFinito :=
      TConsumoProduzioneProdottoFinito.GetByLottoSemilavorato(ALottoSemilavoratoID);
    try
      for LConsumo1 in LConsumiInProdottoFinito do
        AggiungiProdottoFinitoRaggiunto(LProdottiFinitiRaggiunti,
          LConsumo1.LottoProdottoFinitoID, True, LConsumo1.QuantitaConsumata,
          UnitaMisuraDi(LOrigine));
    finally
      LConsumiInProdottoFinito.Free;
    end;

    LConsumiInSemilavorato :=
      TConsumoProduzioneSemilavorato.GetByLottoSemilavoratoFiglio(ALottoSemilavoratoID);
    try
      for LConsumo2 in LConsumiInSemilavorato do
      begin
        LUnitaFiglio := AggiungiSemilavoratoRaggiunto(LSemilavoratiRaggiunti,
          LConsumo2.LottoSemilavoratoID, True, LConsumo2.QuantitaConsumata,
          UnitaMisuraDi(LOrigine));
        EsploraSemilavorato(LConsumo2.LottoSemilavoratoID, LUnitaFiglio,
          LSemilavoratiRaggiunti, LProdottiFinitiRaggiunti, LVisitati);
      end;
    finally
      LConsumiInSemilavorato.Free;
    end;

    Result := TJSONObject.Create;
    Result.AddPair('lotto_origine', LOrigine);
    Result.AddPair('semilavorati_coinvolti', LSemilavoratiRaggiunti);
    Result.AddPair('prodotti_finiti_raggiunti', LProdottiFinitiRaggiunti);
  finally
    LVisitati.Free;
  end;
end;

class function TServizioTracciabilita.AlberoProdottoFinito(ALottoProdottoFinitoID: Integer): TJSONObject;
var
  LOrigine: TJSONObject;
begin
  LOrigine := TServizioLotti.DettaglioProdottoFinito(ALottoProdottoFinitoID);
  if LOrigine = nil then
    Exit(nil);

  Result := TJSONObject.Create;
  Result.AddPair('lotto_origine', LOrigine);
  Result.AddPair('spedizioni', Spedizioni(ALottoProdottoFinitoID));
end;

end.
