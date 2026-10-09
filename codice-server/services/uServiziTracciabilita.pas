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
  // Risalita "in avanti" della tracciabilita' di un lotto: dato un lotto
  // di materia prima o di semilavorato, quali lotti di semilavorato e di
  // prodotto finito lo contengono (direttamente o attraverso uno o piu'
  // livelli di distinta base), e per ciascun lotto di prodotto finito
  // raggiunto, a quali ordini/clienti e' stato assegnato e se e' stato
  // davvero spedito. E' la vista Tracciabilita' lotti del frontend web
  // (assets/js/views/view-tracciabilita.js).
  //
  // PERCHE' UN SERVICE A SE E NON UN'ESTENSIONE DI TServizioRitiroRichiamo
  // TServizioRitiroRichiamo.RisaliCatenaConsumoDa* fa gia' esattamente
  // questa risalita (vedi services/uServiziRitiroRichiamo.pas), ma per
  // uno scopo diverso: apre una non conformita' e restituisce solo gli ID
  // dei lotti di prodotto finito raggiunti, il minimo che serve per
  // decidere se servono la Scheda di Notifica OSA e il Modello di
  // Richiamo al Consumatore. Questa vista invece serve a ESPLORARE la
  // tracciabilita' di un lotto SENZA aprire alcuna non conformita' (un
  // operatore puo' voler vedere "dove e' finito questo lotto" anche solo
  // per curiosita' o controllo, non solo durante un ritiro/richiamo vero)
  // e ha bisogno di molti piu' dettagli per riga (codice, denominazione,
  // quantita', numero ordine/DDT, cliente) per essere leggibile a video,
  // non solo di un elenco di ID. Estendere TServizioRitiroRichiamo con
  // tutto questo lo avrebbe reso un servizio con due responsabilita'
  // diverse cucite insieme; separarlo mantiene entrambi piu' semplici.
  //
  // DISTINZIONE "ordinato" vs "spedito"
  // A differenza di TServizioRitiroRichiamo.VerificaEsposizioneClienti
  // (che tratta ogni riga d'ordine come "esposizione", la lettura piu'
  // cautelativa per un ritiro/richiamo reale - vedi il commento su
  // TEsposizioneLottoProdottoFinito), qui distinguiamo i due stati
  // incrociando ddt_uscita_righe: un ordine confermato ma non ancora
  // spedito (nessuna riga DDT collegata) compare con spedito=False e i
  // campi di spedizione a null, non con un numero_ddt inventato. E'
  // l'affinamento che lo stesso commento di TServizioRitiroRichiamo
  // segnalava come miglioramento futuro.
  TServizioTracciabilita = class
  public
    // Restituisce nil se il lotto di materia prima non esiste (stesso
    // pattern "nil = non trovato" di TServizioLotti.DettaglioX, non
    // un'eccezione: "non trovato" e' un esito normale per il chiamante).
    class function AlberoMateriaPrima(ALottoMateriaPrimaID: Integer): TJSONObject;
    class function AlberoSemilavorato(ALottoSemilavoratoID: Integer): TJSONObject;

    // Un lotto di prodotto finito e' gia' il capolinea della distinta
    // base: nessuna risalita in avanti da fare, solo le sue spedizioni.
    class function AlberoProdottoFinito(ALottoProdottoFinitoID: Integer): TJSONObject;
  end;

implementation

// ---------------------------------------------------------------------
// Spedizioni di un lotto di prodotto finito: una riga per ogni riga
// d'ordine che lo referenzia (ordini_vendita_righe.lotto_prodotto_finito_id),
// con LEFT JOIN su ddt_uscita_righe/ddt_uscita - cosi' un ordine
// confermato ma non ancora spedito compare comunque (spedito=False),
// invece di sparire dall'elenco o di essere confuso con uno spedito.
// ---------------------------------------------------------------------
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
          // Nessuna riga DDT collegata: l'ordine e' confermato ma non
          // ancora spedito. I tre campi restano null, non stringa vuota
          // o zero: la vista deve poter distinguere "non spedito" da
          // "spedito zero pezzi", che non ha senso.
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

// ---------------------------------------------------------------------
// Le due funzioni seguenti appendono UN elemento a un elenco "raggiunti"
// (semilavorati o prodotti finiti), risolvendo l'anagrafica del lotto
// tramite TServizioLotti (stessa forma "entita_codice/entita_
// denominazione" gia' vista nella vista Lotti: chi consuma questo JSON
// non deve imparare due formati diversi per lo stesso concetto).
//
// "consumato_direttamente": True solo se il consumo che lo raggiunge
// parte ESATTAMENTE dal lotto origine della richiesta, senza livelli
// intermedi. Falso per tutto cio' che si raggiunge attraverso un
// ulteriore salto (es. materia prima -> semilavorato A -> semilavorato
// B): la vista lo mostra come indicazione di "quanto lontano" nella
// distinta base si e' arrivati.
// ---------------------------------------------------------------------
// UNITA' DELLA QUANTITA' CONSUMATA
// quantita_consumata (tabelle consumi_produzione_*) non ha una colonna
// unita_misura propria: e' espressa nell'unita' del lotto CONSUMATO (il
// componente a monte: la materia prima o il semilavorato usati), NON in
// quella del lotto prodotto a valle. Prima si mostrava accanto
// all'unita_misura del lotto raggiunto, che coincideva solo perche' nei
// dati di test era tutto in kg: con i prodotti finiti a pezzi (script
// 003_unita_vendita_pezzi.sql) "20 kg di canditi consumati" sarebbe
// diventato "20 pz". Per questo ogni nodo riceve ora anche
// AUnitaConsumata (l'unita' del lotto a monte) e la espone come
// "unita_misura_consumata"; "unita_misura" resta quella del lotto
// raggiunto (serve per la sua quantita'/disponibilita').
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

// Restituisce l'unita' di misura del semilavorato raggiunto ('' se il
// lotto non esiste piu'): serve al chiamante per l'esplorazione ricorsiva
// a valle, dove QUESTO lotto diventa il componente consumato.
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

// ---------------------------------------------------------------------
// Esplorazione ricorsiva a valle di UN lotto di semilavorato gia'
// raggiunto (non il lotto origine: vedi il commento su
// "consumato_direttamente" sopra, qui e' sempre False). Gemella di
// TServizioRitiroRichiamo.EsploraLottoSemilavorato, con la differenza
// che qui si accumulano oggetti JSON completi, non solo ID.
// ---------------------------------------------------------------------
procedure EsploraSemilavorato(ALottoSemilavoratoID: Integer; const AUnitaLotto: string;
  ASemilavoratiRaggiunti, AProdottiFinitiRaggiunti: TJSONArray; AVisitati: TList<Integer>);
var
  LConsumiInProdottoFinito: TObjectList<TConsumoProduzioneProdottoFinito>;
  LConsumiInSemilavorato: TObjectList<TConsumoProduzioneSemilavorato>;
  LConsumo1: TConsumoProduzioneProdottoFinito;
  LConsumo2: TConsumoProduzioneSemilavorato;
  LUnitaFiglio: string;
begin
  // Guardia anti-ciclo/anti-duplicazione: stesso motivo del gemello in
  // TServizioRitiroRichiamo (un lotto puo' essere raggiunto da piu' di
  // un percorso).
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

{ TServizioTracciabilita }

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
    // Consumi diretti: materia prima -> prodotto finito, senza
    // semilavorato intermedio.
    LConsumiDiretti1 := TConsumoProduzioneProdottoFinito.GetByLottoMateriaPrima(ALottoMateriaPrimaID);
    try
      for LConsumo1 in LConsumiDiretti1 do
        AggiungiProdottoFinitoRaggiunto(LProdottiFinitiRaggiunti,
          LConsumo1.LottoProdottoFinitoID, True, LConsumo1.QuantitaConsumata,
          UnitaMisuraDi(LOrigine));
    finally
      LConsumiDiretti1.Free;
    end;

    // Consumi diretti: materia prima -> semilavorato, poi esplorazione
    // ricorsiva a valle di ciascuno.
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
    // Il lotto origine non va mai riesplorato come se fosse un
    // componente di se stesso (puo' succedere se la distinta base ha un
    // ciclo anomalo che lo riporta a monte di se stesso): lo segnamo
    // gia' visitato prima di iniziare.
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
