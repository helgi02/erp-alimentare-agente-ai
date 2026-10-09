unit uServiziRitiroRichiamo;

interface

uses
  System.SysUtils,
  System.Generics.Collections,
  uModelNonConformita,
  uModelLottoMateriaPrima,
  uModelLottoProdottoFinito,
  uModelOrdineVenditaRiga,
  uModelOrdineVendita,
  uModelConsumoProduzioneSemilavorato,
  uModelConsumoProduzioneProdottoFinito,
  uModelDDTEntrataRiga,
  uModelDDTEntrata,
  uModelDDTUscitaRiga,
  uModelDDTUscita,
  uModelProdottoFinito,
  uModelCliente;

type
  // Lotto di materia prima in input all'analisi di impatto (RaccogliDatiPerMateriaPrima).
  // Il suo DDT di acquisto e' incluso per la tracciabilita' "a monte" (Reg. CE 178/2002,
  // art. 18, "one step back") e per i documenti di compliance; non serve a raggiungere i
  // lotti di prodotto finito (quel collegamento passa da consumi_produzione_*).
  // DDTEntrataID = 0 e' una sentinella "DDT non determinabile", che non dovrebbe capitare
  // (ddt_entrata_riga_id e' NOT NULL), gestita per robustezza.
  TLottoMateriaPrimaOrigine = class
  public
    LottoMateriaPrimaID: Integer;
    MateriaPrimaID: Integer;
    CodiceLotto: string;
    DDTEntrataID: Integer;
    DDTNumero: string;
    DDTDataRicezione: TDateTime;
    DDTFornitoreID: Integer;
  end;

  // Lotto di prodotto finito raggiunto, con i lotti di materia prima di origine (fra quelli
  // in input) che l'hanno raggiunto. Possono essere piu' di uno: serve a non perdere, nei
  // documenti di compliance, quale lotto non conforme ha raggiunto quale prodotto.
  TLottoProdottoFinitoImpattato = class
  public
    LottoProdottoFinitoID: Integer;
    ProdottoFinitoID: Integer;
    CodiceLotto: string;
    LottiMateriaPrimaOrigineIDs: TArray<Integer>;
  end;

  // Dati intermedi di RaccogliDatiPerMateriaPrima: per ogni lotto di materia prima, il DDT
  // di acquisto e i lotti di prodotto finito raggiunti a valle col lotto di origine che li
  // ha raggiunti. Uso interno di ApriRitiro, mai restituito a un tool. Vendite e DDT di
  // uscita dei clienti coinvolti sono un passo separato (TrovaClientiLottoProdottoFinito).
  TDatiMateriaPrima = class
  public
    LottiOrigine: TObjectList<TLottoMateriaPrimaOrigine>;
    LottiProdottoFinitoImpattati: TObjectList<TLottoProdottoFinitoImpattato>;

    constructor Create;
    destructor Destroy; override;
  end;

  // Una non conformita' aperta da ApriRitiro, una per lotto di materia prima:
  // non_conformita.lotto_materia_prima_id e' una colonna singola, quindi "ritiro su piu'
  // lotti" significa piu' non conformita'. LottiProdottoFinitoIDs sono solo quelli
  // raggiunti da questo lotto (filtrati con LottiMateriaPrimaOrigineIDs), non tutti quelli
  // dell'analisi.
  TNonConformitaAperta = class
  public
    NonConformitaID: Integer;
    CodiceNC: string;
    LottoMateriaPrimaID: Integer;
    LottiProdottoFinitoIDs: TArray<Integer>;

    // Vera anche con RichiedeModelloRichiamoConsumatore sconosciuto: la Scheda di Notifica
    // OSA dipende solo dall'aver raggiunto almeno un lotto di prodotto finito.
    // L'esposizione clienti (vendite/DDT di uscita) e' TrovaClientiLottoProdottoFinito,
    // richiamabile dopo con LottiProdottoFinitoIDs senza rifare la risalita.
    RichiedeSchedaNotificaOSA: Boolean;
  end;

  TEsitoAperturaRitiro = class
  public
    NonConformitaAperte: TObjectList<TNonConformitaAperta>;

    constructor Create;
    destructor Destroy; override;
  end;

  // Una spedizione (DDT di uscita) di una riga ordine per un lotto coinvolto. Elenco
  // perche' una riga puo' essere evasa con piu' DDT
  // (TDDTUscitaRiga.GetByOrdineVenditaRiga).
  TSpedizioneRiga = class
  public
    DDTUscitaID: Integer;
    NumeroDDT: string;
    DataSpedizione: TDateTime;
    QuantitaSpedita: Currency;
  end;

  // Riga ordine che referenzia il lotto, con le spedizioni gia' partite. Solo riferimenti
  // (ClienteID, non l'anagrafica, che si recupera con un tool dedicato): non duplica
  // get_list_vendite, che non filtra per lotto.
  TEsposizioneOrdine = class
  public
    OrdineVenditaRigaID: Integer;
    OrdineVenditaID: Integer;
    NumeroOrdine: string;
    ClienteID: Integer;
    Quantita: Currency;
    Spedizioni: TObjectList<TSpedizioneRiga>;

    constructor Create;
    destructor Destroy; override;
  end;

  // Esposizioni (ordini con eventuali spedizioni) di un lotto di prodotto finito.
  TLottoConClienti = class
  public
    LottoProdottoFinitoID: Integer;
    Esposizioni: TObjectList<TEsposizioneOrdine>;

    constructor Create;
    destructor Destroy; override;
  end;

  // Esito di TrovaClientiLottoProdottoFinito: un TLottoConClienti per ogni lotto in input.
  TEsitoClientiPerLotti = class
  public
    Lotti: TObjectList<TLottoConClienti>;

    constructor Create;
    destructor Destroy; override;
  end;

  // Servizio dello scenario 1 (ritiro/richiamo). Non modifica mai la giacenza: solo
  // lettura/risalita piu' l'apertura della non conformita'. A differenza di
  // TServizioGiacenza non serve una transazione multi-step: ogni operazione tocca una
  // tabella alla volta.
  // Comunicazione per UN cliente e UNO dei due casi (TrovaComunicazioniClienti):
  // MerceSpedita = True, lotti gia' spediti (richiamo); False, lotti in ordini non ancora
  // spediti (ritiro). Un cliente in entrambi i casi ha due comunicazioni (ogni email ha un
  // solo scopo). Righe = una riga di testo pronta per ogni riga d'ordine (prodotto, lotto,
  // quantita', ordine, DDT).
  TComunicazioneCliente = class
  public
    ClienteID: Integer;
    RagioneSociale: string;
    Email: string;
    MerceSpedita: Boolean;
    Righe: TList<string>;
    constructor Create;
    destructor Destroy; override;
  end;

  TServizioRitiroRichiamo = class
  private
    // Esplorazione ricorsiva a valle di un lotto di semilavorato coinvolto: i prodotti
    // finiti che l'hanno consumato direttamente e i semilavorati "genitori" che l'hanno
    // consumato come componente (distinta multi-livello), esplorati a loro volta.
    class procedure EsploraLottoSemilavorato(ALottoSemilavoratoID: Integer;
      AProdottiFinitiTrovati, ASemilavoratiVisitati: TList<Integer>);

    // Raccoglie per uno o piu' lotti di materia prima non conformi i dati per ApriRitiro:
    // risale la filiera (RisaliCatenaConsumoDaMateriaPrima), recupera il DDT di acquisto di
    // ogni lotto di origine e collega ogni lotto di prodotto finito raggiunto al lotto di
    // origine. Raccolta meccanica, senza valutazioni di merito (gravita', urgenza).
    // Privato: serve solo ad ApriRitiro.
    class function RaccogliDatiPerMateriaPrima(
      const ALottiMateriaPrimaID: TArray<Integer>): TDatiMateriaPrima;
  public
    // Risalita da un lotto di materia prima non conforme: gli id di tutti i lotti di
    // prodotto finito potenzialmente coinvolti (diretti o attraverso uno o piu' livelli di
    // semilavorato).
    class function RisaliCatenaConsumoDaMateriaPrima(
      ALottoMateriaPrimaID: Integer): TArray<Integer>;

    // Come sopra, quando il lotto non conforme e' un semilavorato (la NC puo' nascere a
    // qualunque livello, CHECK OR e non XOR su non_conformita).
    class function RisaliCatenaConsumoDaSemilavorato(
      ALottoSemilavoratoID: Integer): TArray<Integer>;

    // Scrittura: apre una non conformita' per ogni lotto di materia prima, riusando
    // RaccogliDatiPerMateriaPrima. ACodiceNCBase e' usato com'e' con un solo lotto; con
    // piu' lotti ogni riga ha il suffisso "-1", "-2", ... nell'ordine di elaborazione: un
    // solo codice dal modello, suffissato dal codice, e' piu' robusto di un array di codici
    // da un modello 9B, che rischierebbe duplicati.
    class function ApriRitiro(const ACodiceNCBase, AMotivo: string;
      const ALottiMateriaPrimaID: TArray<Integer>): TEsitoAperturaRitiro;

    // Tool "B": per uno o piu' lotti di prodotto finito (tipicamente l'esito di
    // ApriRitiro), il dettaglio riga per riga degli ordini che li referenziano e delle
    // spedizioni (DDT di uscita) gia' partite. Sola lettura. Pubblico, a differenza di
    // RaccogliDatiPerMateriaPrima: richiamabile anche da solo.
    class function TrovaClientiLottoProdottoFinito(
      const ALottiProdottoFinitoID: TArray<Integer>): TEsitoClientiPerLotti;

    // I clienti da avvisare per i lotti indicati, divisi nei due casi (spedita / non
    // spedita) e con i dati leggibili per l'email (prodotto, codice lotto, scadenza,
    // cliente). Parte da TrovaClientiLottoProdottoFinito (stessi controlli sugli id).
    // Esclude gli ordini annullati. Sola lettura; lista vuota = nessun cliente coinvolto
    // (caso normale). Il risultato e' del chiamante.
    class function TrovaComunicazioniClienti(
      const ALottiProdottoFinitoID: TArray<Integer>): TObjectList<TComunicazioneCliente>;

  end;

implementation

class procedure TServizioRitiroRichiamo.EsploraLottoSemilavorato(
  ALottoSemilavoratoID: Integer; AProdottiFinitiTrovati, ASemilavoratiVisitati: TList<Integer>);
var
  LConsumiInProdottoFinito: TObjectList<TConsumoProduzioneProdottoFinito>;
  LConsumiInSemilavorato: TObjectList<TConsumoProduzioneSemilavorato>;
  LConsumo1: TConsumoProduzioneProdottoFinito;
  LConsumo2: TConsumoProduzioneSemilavorato;
begin
  // Guardia anti-duplicazione: un lotto di semilavorato puo' essere raggiunto da piu'
  // percorsi. Una distinta non dovrebbe avere cicli, ma la guardia protegge da dati
  // anomali.
  if ASemilavoratiVisitati.Contains(ALottoSemilavoratoID) then
    Exit;
  ASemilavoratiVisitati.Add(ALottoSemilavoratoID);

  // Chi ha consumato questo lotto per un prodotto finito: punto d'arrivo del ramo.
  LConsumiInProdottoFinito :=
    TConsumoProduzioneProdottoFinito.GetByLottoSemilavorato(ALottoSemilavoratoID);
  try
    for LConsumo1 in LConsumiInProdottoFinito do
      if not AProdottiFinitiTrovati.Contains(LConsumo1.LottoProdottoFinitoID) then
        AProdottiFinitiTrovati.Add(LConsumo1.LottoProdottoFinitoID);
  finally
    LConsumiInProdottoFinito.Free;
  end;

  // Chi l'ha consumato come componente di un altro semilavorato: un livello di distinta in
  // piu', da esplorare ricorsivamente.
  LConsumiInSemilavorato :=
    TConsumoProduzioneSemilavorato.GetByLottoSemilavoratoFiglio(ALottoSemilavoratoID);
  try
    for LConsumo2 in LConsumiInSemilavorato do
      EsploraLottoSemilavorato(LConsumo2.LottoSemilavoratoID,
        AProdottiFinitiTrovati, ASemilavoratiVisitati);
  finally
    LConsumiInSemilavorato.Free;
  end;
end;

class function TServizioRitiroRichiamo.RisaliCatenaConsumoDaMateriaPrima(
  ALottoMateriaPrimaID: Integer): TArray<Integer>;
var
  LProdottiFinitiTrovati, LSemilavoratiVisitati: TList<Integer>;
  LConsumiDiretti1: TObjectList<TConsumoProduzioneProdottoFinito>;
  LConsumiDiretti2: TObjectList<TConsumoProduzioneSemilavorato>;
  LConsumo1: TConsumoProduzioneProdottoFinito;
  LConsumo2: TConsumoProduzioneSemilavorato;
begin
  LProdottiFinitiTrovati := TList<Integer>.Create;
  LSemilavoratiVisitati := TList<Integer>.Create;
  try
    // Consumo diretto della materia prima in un prodotto finito, senza semilavorato
    // intermedio.
    LConsumiDiretti1 := TConsumoProduzioneProdottoFinito.GetByLottoMateriaPrima(ALottoMateriaPrimaID);
    try
      for LConsumo1 in LConsumiDiretti1 do
        if not LProdottiFinitiTrovati.Contains(LConsumo1.LottoProdottoFinitoID) then
          LProdottiFinitiTrovati.Add(LConsumo1.LottoProdottoFinitoID);
    finally
      LConsumiDiretti1.Free;
    end;

    // Consumo in un semilavorato: da ciascuno si esplora a valle.
    LConsumiDiretti2 := TConsumoProduzioneSemilavorato.GetByLottoMateriaPrima(ALottoMateriaPrimaID);
    try
      for LConsumo2 in LConsumiDiretti2 do
        EsploraLottoSemilavorato(LConsumo2.LottoSemilavoratoID,
          LProdottiFinitiTrovati, LSemilavoratiVisitati);
    finally
      LConsumiDiretti2.Free;
    end;

    Result := LProdottiFinitiTrovati.ToArray;
  finally
    LProdottiFinitiTrovati.Free;
    LSemilavoratiVisitati.Free;
  end;
end;

class function TServizioRitiroRichiamo.RisaliCatenaConsumoDaSemilavorato(
  ALottoSemilavoratoID: Integer): TArray<Integer>;
var
  LProdottiFinitiTrovati, LSemilavoratiVisitati: TList<Integer>;
begin
  LProdottiFinitiTrovati := TList<Integer>.Create;
  LSemilavoratiVisitati := TList<Integer>.Create;
  try
    EsploraLottoSemilavorato(ALottoSemilavoratoID, LProdottiFinitiTrovati, LSemilavoratiVisitati);
    Result := LProdottiFinitiTrovati.ToArray;
  finally
    LProdottiFinitiTrovati.Free;
    LSemilavoratiVisitati.Free;
  end;
end;

constructor TDatiMateriaPrima.Create;
begin
  inherited Create;
  LottiOrigine := TObjectList<TLottoMateriaPrimaOrigine>.Create(True);
  LottiProdottoFinitoImpattati := TObjectList<TLottoProdottoFinitoImpattato>.Create(True);
end;

destructor TDatiMateriaPrima.Destroy;
begin
  LottiOrigine.Free;
  LottiProdottoFinitoImpattati.Free;
  inherited Destroy;
end;

class function TServizioRitiroRichiamo.RaccogliDatiPerMateriaPrima(
  const ALottiMateriaPrimaID: TArray<Integer>): TDatiMateriaPrima;
var
  LIDsProcessati: TList<Integer>;
  // Indice temporaneo lotto_prodotto_finito_id -> oggetto creato. Non possiede gli oggetti
  // (TDictionary, non TObjectDictionary): la proprieta' passa a
  // Result.LottiProdottoFinitoImpattati alla creazione, quindi liberare la mappa non libera
  // gli oggetti.
  LMappaImpattati: TDictionary<Integer, TLottoProdottoFinitoImpattato>;
  LLottoOrigineID: Integer;
  LLottoMP: TLottoMateriaPrima;
  LOrigine: TLottoMateriaPrimaOrigine;
  LDDTRiga: TDDTEntrataRiga;
  LDDT: TDDTEntrata;
  LProdottiFinitiIDs: TArray<Integer>;
  LProdottoFinitoID: Integer;
  LImpattato: TLottoProdottoFinitoImpattato;
  LLottoPF: TLottoProdottoFinito;
begin
  if Length(ALottiMateriaPrimaID) = 0 then
    raise Exception.Create(
      'RaccogliDatiPerMateriaPrima: serve almeno un lotto di materia prima.');

  Result := TDatiMateriaPrima.Create;

  LIDsProcessati := TList<Integer>.Create;
  LMappaImpattati := TDictionary<Integer, TLottoProdottoFinitoImpattato>.Create;
  try
    for LLottoOrigineID in ALottiMateriaPrimaID do
    begin
      // Anti-duplicati: un id ripetuto in input (anche per errore del modello) si elabora
      // una volta.
      if LIDsProcessati.Contains(LLottoOrigineID) then
        Continue;
      LIDsProcessati.Add(LLottoOrigineID);

      LLottoMP := TLottoMateriaPrima.GetByID(LLottoOrigineID);
      if LLottoMP = nil then
        raise Exception.CreateFmt(
          'RaccogliDatiPerMateriaPrima: lotto materia prima id=%d non trovato.',
          [LLottoOrigineID]);
      try
        LOrigine := TLottoMateriaPrimaOrigine.Create;
        LOrigine.LottoMateriaPrimaID := LLottoMP.ID;
        LOrigine.MateriaPrimaID := LLottoMP.MateriaPrimaID;
        LOrigine.CodiceLotto := LLottoMP.CodiceLotto;

        // DDT di acquisto: lotto -> riga DDT -> testata. ddt_entrata_riga_id e' NOT NULL,
        // quindi LDDTRiga non dovrebbe essere nil; il controllo resta per robustezza.
        LDDTRiga := TDDTEntrataRiga.GetByID(LLottoMP.DdtEntrataRigaID);
        if LDDTRiga <> nil then
        try
          LOrigine.DDTEntrataID := LDDTRiga.DDTEntrataID;

          LDDT := TDDTEntrata.GetByID(LDDTRiga.DDTEntrataID);
          if LDDT <> nil then
          try
            LOrigine.DDTNumero := LDDT.NumeroDDT;
            LOrigine.DDTDataRicezione := LDDT.DataRicezione;
            LOrigine.DDTFornitoreID := LDDT.FornitoreID;
          finally
            LDDT.Free;
          end;
        finally
          LDDTRiga.Free;
        end;

        Result.LottiOrigine.Add(LOrigine);
      finally
        LLottoMP.Free;
      end;

      // Risalita a valle: riusa RisaliCatenaConsumoDaMateriaPrima, senza query duplicate.
      LProdottiFinitiIDs := RisaliCatenaConsumoDaMateriaPrima(LLottoOrigineID);

      for LProdottoFinitoID in LProdottiFinitiIDs do
      begin
        if not LMappaImpattati.TryGetValue(LProdottoFinitoID, LImpattato) then
        begin
          LLottoPF := TLottoProdottoFinito.GetByID(LProdottoFinitoID);
          if LLottoPF = nil then
            raise Exception.CreateFmt(
              'RaccogliDatiPerMateriaPrima: lotto prodotto finito id=%d non trovato ' +
              '(riferimento incoerente da consumi_produzione).',
              [LProdottoFinitoID]);
          try
            LImpattato := TLottoProdottoFinitoImpattato.Create;
            LImpattato.LottoProdottoFinitoID := LLottoPF.ID;
            LImpattato.ProdottoFinitoID := LLottoPF.ProdottoFinitoID;
            LImpattato.CodiceLotto := LLottoPF.CodiceLotto;
            LImpattato.LottiMateriaPrimaOrigineIDs := [];
          finally
            LLottoPF.Free;
          end;

          // La proprieta' passa subito a Result: la mappa indicizza solo per riferimento.
          Result.LottiProdottoFinitoImpattati.Add(LImpattato);
          LMappaImpattati.Add(LProdottoFinitoID, LImpattato);
        end;

        // Aggiunge questo lotto di origine a chi ha raggiunto il prodotto finito (puo'
        // ripetersi se piu' lotti di origine lo raggiungono).
        LImpattato.LottiMateriaPrimaOrigineIDs :=
          LImpattato.LottiMateriaPrimaOrigineIDs + [LLottoOrigineID];
      end;
    end;
  finally
    LIDsProcessati.Free;
    LMappaImpattati.Free;
  end;
end;

constructor TEsitoAperturaRitiro.Create;
begin
  inherited Create;
  NonConformitaAperte := TObjectList<TNonConformitaAperta>.Create(True);
end;

destructor TEsitoAperturaRitiro.Destroy;
begin
  NonConformitaAperte.Free;
  inherited Destroy;
end;

class function TServizioRitiroRichiamo.ApriRitiro(const ACodiceNCBase, AMotivo: string;
  const ALottiMateriaPrimaID: TArray<Integer>): TEsitoAperturaRitiro;
var
  LIDsProcessati: TList<Integer>;
  LDati: TDatiMateriaPrima;
  LLottoOrigineID: Integer;
  LIndiceRiga: Integer;
  LCodiceNC: string;
  LNC: TNonConformita;
  LAperta: TNonConformitaAperta;
  LImpattato: TLottoProdottoFinitoImpattato;
  LPFIDs: TArray<Integer>;
  LEsistente: TNonConformita;
  LCodiciOccupati: string;
begin
  if Length(ALottiMateriaPrimaID) = 0 then
    raise Exception.Create(
      'ApriRitiro: serve almeno un lotto di materia prima.');

  // Il codice della non conformita' deve essere unico. Si verifica prima di scrivere
  // ("tutto o niente"): se un codice e' occupato non si apre nulla e l'errore dice quale.
  // Caso reale nei test (S1-B): il modello riproponeva l'apertura di una NC appena aperta,
  // creando un doppione. Si controllano sia il codice base sia quelli con suffisso "-1",
  // "-2", perche' quale servira' dipende dal numero di lotti distinti.
  LCodiciOccupati := '';
  LIDsProcessati := TList<Integer>.Create;
  try
    for LLottoOrigineID in ALottiMateriaPrimaID do
      if not LIDsProcessati.Contains(LLottoOrigineID) then
        LIDsProcessati.Add(LLottoOrigineID);
    for LIndiceRiga := 1 to LIDsProcessati.Count do
    begin
      if LIDsProcessati.Count = 1 then
        LCodiceNC := ACodiceNCBase
      else
        LCodiceNC := ACodiceNCBase + '-' + IntToStr(LIndiceRiga);
      LEsistente := TNonConformita.GetByCodice(LCodiceNC);
      if LEsistente <> nil then
      begin
        LEsistente.Free;
        if LCodiciOccupati <> '' then
          LCodiciOccupati := LCodiciOccupati + ', ';
        LCodiciOccupati := LCodiciOccupati + LCodiceNC;
      end;
    end;
  finally
    LIDsProcessati.Free;
  end;
  if LCodiciOccupati <> '' then
    raise Exception.CreateFmt(
      'Esiste gia'' una non conformita'' con codice %s: nessuna non conformita'' aperta. ' +
      'Se e'' quella appena aperta non va riaperta; per aprirne una nuova serve un codice diverso.',
      [LCodiciOccupati]);

  // Riusa RaccogliDatiPerMateriaPrima (stessa risalita e stesso DDT, nessuna query
  // duplicata). LDati e' di questo metodo (Free nel finally).
  LDati := RaccogliDatiPerMateriaPrima(ALottiMateriaPrimaID);
  try
    Result := TEsitoAperturaRitiro.Create;

    // Stessa guardia anti-duplicati: evita di aprire due volte la NC sullo stesso lotto e
    // di sbagliare il suffisso (Length(ALottiMateriaPrimaID) da solo potrebbe contare
    // ripetizioni).
    LIDsProcessati := TList<Integer>.Create;
    try
      for LLottoOrigineID in ALottiMateriaPrimaID do
        if not LIDsProcessati.Contains(LLottoOrigineID) then
          LIDsProcessati.Add(LLottoOrigineID);

      LIndiceRiga := 0;
      for LLottoOrigineID in LIDsProcessati do
      begin
        Inc(LIndiceRiga);

        // Un solo lotto (dopo dedup): codice com'e'. Piu' lotti: suffisso "-1", "-2", ...
        // nell'ordine di elaborazione.
        if LIDsProcessati.Count = 1 then
          LCodiceNC := ACodiceNCBase
        else
          LCodiceNC := ACodiceNCBase + '-' + IntToStr(LIndiceRiga);

        // 1) Scrittura: una riga in non_conformita per lotto. EnsureAlmenoUnLottoValido (in
        // Insert) non puo' fallire: LottoMateriaPrimaID e' sempre valorizzato.
        LNC := TNonConformita.Create;
        try
          LNC.CodiceNC := LCodiceNC;
          LNC.Motivo := AMotivo;
          LNC.LottoMateriaPrimaID := LLottoOrigineID;
          LNC.Insert;

          LAperta := TNonConformitaAperta.Create;
          LAperta.NonConformitaID := LNC.ID;
          LAperta.CodiceNC := LNC.CodiceNC;
          LAperta.LottoMateriaPrimaID := LLottoOrigineID;
        finally
          LNC.Free;
        end;

        // 2) Dall'analisi gia' calcolata, solo i lotti di prodotto finito raggiunti da
        // questo lotto di origine (TNonConformitaAperta).
        LPFIDs := [];
        for LImpattato in LDati.LottiProdottoFinitoImpattati do
          if TArray.Contains<Integer>(LImpattato.LottiMateriaPrimaOrigineIDs, LLottoOrigineID) then
            LPFIDs := LPFIDs + [LImpattato.LottoProdottoFinitoID];

        LAperta.LottiProdottoFinitoIDs := LPFIDs;
        LAperta.RichiedeSchedaNotificaOSA := Length(LPFIDs) > 0;

        Result.NonConformitaAperte.Add(LAperta);
      end;
    finally
      LIDsProcessati.Free;
    end;
  finally
    LDati.Free;
  end;
end;

constructor TEsposizioneOrdine.Create;
begin
  inherited Create;
  Spedizioni := TObjectList<TSpedizioneRiga>.Create(True);
end;

destructor TEsposizioneOrdine.Destroy;
begin
  Spedizioni.Free;
  inherited Destroy;
end;

constructor TLottoConClienti.Create;
begin
  inherited Create;
  Esposizioni := TObjectList<TEsposizioneOrdine>.Create(True);
end;

destructor TLottoConClienti.Destroy;
begin
  Esposizioni.Free;
  inherited Destroy;
end;

constructor TEsitoClientiPerLotti.Create;
begin
  inherited Create;
  Lotti := TObjectList<TLottoConClienti>.Create(True);
end;

destructor TEsitoClientiPerLotti.Destroy;
begin
  Lotti.Free;
  inherited Destroy;
end;

// Tool "B": per ogni lotto, le righe ordine che lo referenziano
// (TOrdineVenditaRiga.GetByLottoProdottoFinito), l'header ordine (cliente, numero) e le
// righe DDT di uscita gia' emesse. Sola lettura, multi-lotto come
// RaccogliDatiPerMateriaPrima.
class function TServizioRitiroRichiamo.TrovaClientiLottoProdottoFinito(
  const ALottiProdottoFinitoID: TArray<Integer>): TEsitoClientiPerLotti;
var
  LLottoProdottoFinitoID: Integer;
  LLottoConClienti: TLottoConClienti;
  LRigheOrdine: TObjectList<TOrdineVenditaRiga>;
  LRigaOrdine: TOrdineVenditaRiga;
  LOrdine: TOrdineVendita;
  LEsposizione: TEsposizioneOrdine;
  LRigheDDT: TObjectList<TDDTUscitaRiga>;
  LRigaDDT: TDDTUscitaRiga;
  LDDT: TDDTUscita;
  LSpedizione: TSpedizioneRiga;
  LLotto: TLottoProdottoFinito;
  LInesistenti: string;
begin
  if Length(ALottiProdottoFinitoID) = 0 then
    raise Exception.Create(
      'TrovaClientiLottoProdottoFinito: serve almeno un lotto di prodotto finito.');

  // Ogni id deve essere un lotto di prodotto finito esistente. Prima un id inventato dava
  // "nessun ordine", cioe' un falso "non e' stato spedito a nessuno" in uno scenario di
  // richiamo. Ora "lotto senza ordini" (lista vuota, normale) e "lotto inesistente"
  // (errore) sono distinti.
  LInesistenti := '';
  for LLottoProdottoFinitoID in ALottiProdottoFinitoID do
  begin
    LLotto := TLottoProdottoFinito.GetByID(LLottoProdottoFinitoID);
    if LLotto = nil then
    begin
      if LInesistenti <> '' then
        LInesistenti := LInesistenti + ', ';
      LInesistenti := LInesistenti + IntToStr(LLottoProdottoFinitoID);
    end
    else
      LLotto.Free;
  end;
  if LInesistenti <> '' then
    raise Exception.CreateFmt(
      'Lotto di prodotto finito inesistente (id: %s). Gli id vanno presi dal risultato di ' +
      'apri_non_conformita_materia_prima (campo lotti_prodotto_finito_id), non inventati.',
      [LInesistenti]);

  Result := TEsitoClientiPerLotti.Create;

  for LLottoProdottoFinitoID in ALottiProdottoFinitoID do
  begin
    // Esistenza gia' verificata sopra. Un lotto senza ordini e' un caso normale:
    // Esposizioni resta vuota.
    LLottoConClienti := TLottoConClienti.Create;
    LLottoConClienti.LottoProdottoFinitoID := LLottoProdottoFinitoID;
    Result.Lotti.Add(LLottoConClienti);

    LRigheOrdine := TOrdineVenditaRiga.GetByLottoProdottoFinito(LLottoProdottoFinitoID);
    try
      for LRigaOrdine in LRigheOrdine do
      begin
        LEsposizione := TEsposizioneOrdine.Create;
        LEsposizione.OrdineVenditaRigaID := LRigaOrdine.ID;
        LEsposizione.OrdineVenditaID := LRigaOrdine.OrdineVenditaID;
        LEsposizione.Quantita := LRigaOrdine.Quantita;

        // Solo l'header porta cliente e numero ordine, non la riga.
        LOrdine := TOrdineVendita.GetByID(LRigaOrdine.OrdineVenditaID);
        if LOrdine <> nil then
        try
          LEsposizione.NumeroOrdine := LOrdine.NumeroOrdine;
          LEsposizione.ClienteID := LOrdine.ClienteID;
        finally
          LOrdine.Free;
        end;

        // Spedizioni gia' emesse per questa riga: zero, una o piu' (evasione parziale su
        // piu' DDT).
        LRigheDDT := TDDTUscitaRiga.GetByOrdineVenditaRiga(LRigaOrdine.ID);
        try
          for LRigaDDT in LRigheDDT do
          begin
            LDDT := TDDTUscita.GetByID(LRigaDDT.DDTUscitaID);
            if LDDT <> nil then
            try
              LSpedizione := TSpedizioneRiga.Create;
              LSpedizione.DDTUscitaID := LDDT.ID;
              LSpedizione.NumeroDDT := LDDT.NumeroDDT;
              LSpedizione.DataSpedizione := LDDT.DataSpedizione;
              LSpedizione.QuantitaSpedita := LRigaDDT.QuantitaSpedita;
              LEsposizione.Spedizioni.Add(LSpedizione);
            finally
              LDDT.Free;
            end;
          end;
        finally
          LRigheDDT.Free;
        end;

        LLottoConClienti.Esposizioni.Add(LEsposizione);
      end;
    finally
      LRigheOrdine.Free;
    end;
  end;
end;

constructor TComunicazioneCliente.Create;
begin
  inherited Create;
  Righe := TList<string>.Create;
end;

destructor TComunicazioneCliente.Destroy;
begin
  Righe.Free;
  inherited;
end;

class function TServizioRitiroRichiamo.TrovaComunicazioniClienti(
  const ALottiProdottoFinitoID: TArray<Integer>): TObjectList<TComunicazioneCliente>;
const
  // Le virgolette fissano la barra: "/" da solo sarebbe il separatore di data di Windows.
  FORMATO_DATA = 'dd"/"mm"/"yyyy';

  // La comunicazione di (cliente, caso) gia' in elenco, o una nuova.
  function ComunicazionePer(AElenco: TObjectList<TComunicazioneCliente>;
    AClienteID: Integer; AMerceSpedita: Boolean): TComunicazioneCliente;
  var
    LEsistente: TComunicazioneCliente;
    LCliente: TCliente;
  begin
    for LEsistente in AElenco do
      if (LEsistente.ClienteID = AClienteID) and (LEsistente.MerceSpedita = AMerceSpedita) then
        Exit(LEsistente);

    Result := TComunicazioneCliente.Create;
    Result.ClienteID := AClienteID;
    Result.MerceSpedita := AMerceSpedita;
    LCliente := TCliente.GetByID(AClienteID);
    if LCliente <> nil then
    try
      Result.RagioneSociale := LCliente.RagioneSociale;
      Result.Email := LCliente.Email;
    finally
      LCliente.Free;
    end;
    AElenco.Add(Result);
  end;

var
  LEsito: TEsitoClientiPerLotti;
  LLottoConClienti: TLottoConClienti;
  LEsposizione: TEsposizioneOrdine;
  LSpedizione: TSpedizioneRiga;
  LLotto: TLottoProdottoFinito;
  LProdotto: TProdottoFinito;
  LOrdine: TOrdineVendita;
  LRigaOrdine: TOrdineVenditaRiga;
  LDescrizioneLotto, LUnitaMisura, LDataOrdine, LTesto: string;
  LAnnullato: Boolean;
  LFormato: TFormatSettings;
begin
  // Numeri con la virgola decimale, qualunque sia la lingua di Windows.
  LFormato := TFormatSettings.Create('it-IT');

  // Stessa ricerca (e controlli sugli id) dell'altro tool: un solo punto decide quali
  // ordini e DDT riguardano un lotto.
  LEsito := TrovaClientiLottoProdottoFinito(ALottiProdottoFinitoID);
  try
    Result := TObjectList<TComunicazioneCliente>.Create(True);
    try
      for LLottoConClienti in LEsito.Lotti do
      begin
        // "Prodotto (codice), lotto X, scadenza gg/mm/aaaa": quello che il cliente legge
        // sulla confezione, non l'id del database.
        LDescrizioneLotto := Format('lotto id %d', [LLottoConClienti.LottoProdottoFinitoID]);
        LLotto := TLottoProdottoFinito.GetByID(LLottoConClienti.LottoProdottoFinitoID);
        if LLotto <> nil then
        try
          LProdotto := TProdottoFinito.GetByID(LLotto.ProdottoFinitoID);
          if LProdotto <> nil then
          try
            LDescrizioneLotto := Format('%s (%s), lotto %s, scadenza %s',
              [LProdotto.Denominazione, LProdotto.Codice, LLotto.CodiceLotto,
               FormatDateTime(FORMATO_DATA, LLotto.DataScadenza)]);
          finally
            LProdotto.Free;
          end;
        finally
          LLotto.Free;
        end;

        for LEsposizione in LLottoConClienti.Esposizioni do
        begin
          LAnnullato := False;
          LDataOrdine := '';
          LOrdine := TOrdineVendita.GetByID(LEsposizione.OrdineVenditaID);
          if LOrdine <> nil then
          try
            LAnnullato := SameText(LOrdine.Stato, 'annullato');
            LDataOrdine := FormatDateTime(FORMATO_DATA, LOrdine.DataOrdine);
          finally
            LOrdine.Free;
          end;
          // Un ordine annullato non verra' consegnato: nessun avviso.
          if LAnnullato then
            Continue;

          LUnitaMisura := '';
          LRigaOrdine := TOrdineVenditaRiga.GetByID(LEsposizione.OrdineVenditaRigaID);
          if LRigaOrdine <> nil then
          try
            LUnitaMisura := LRigaOrdine.UnitaMisura;
          finally
            LRigaOrdine.Free;
          end;

          LTesto := Format('- %s: %s %s - ordine %s del %s',
            [LDescrizioneLotto, FormatFloat('0.###', LEsposizione.Quantita, LFormato),
             LUnitaMisura, LEsposizione.NumeroOrdine, LDataOrdine]);
          for LSpedizione in LEsposizione.Spedizioni do
            LTesto := LTesto + Format(', DDT %s del %s',
              [LSpedizione.NumeroDDT, FormatDateTime(FORMATO_DATA, LSpedizione.DataSpedizione)]);

          // Il caso si decide per riga d'ordine: almeno un DDT = spedita.
          ComunicazionePer(Result, LEsposizione.ClienteID,
            LEsposizione.Spedizioni.Count > 0).Righe.Add(LTesto);
        end;
      end;
    except
      Result.Free;
      raise;
    end;
  finally
    LEsito.Free;
  end;
end;

end.
