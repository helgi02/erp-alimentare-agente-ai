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
  // Lotto di materia prima passato in INPUT all'analisi di impatto (step 1
  // della risalita filiera, vedi TServizioRitiroRichiamo.RaccogliDatiPerMateriaPrima):
  // il suo DDT di acquisto, se presente, e' incluso per la tracciabilita'
  // "a monte" richiesta dal Reg. CE 178/2002 (art. 18, "one step back") -
  // non serve per raggiungere i lotti di prodotto finito (quel collegamento
  // passa da consumi_produzione_*, non dal DDT di acquisto), ma e' un dato
  // utile da avere gia' pronto per la compilazione dei documenti di
  // compliance (scenario successivo, non ancora implementato). DDTEntrataID
  // = 0 e' una sentinella "DDT non determinabile" che in pratica non
  // dovrebbe mai verificarsi (ddt_entrata_riga_id e' NOT NULL a livello di
  // schema), gestita comunque per robustezza contro dati anomali.
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

  // Un lotto di prodotto finito raggiunto dalla risalita, con l'elenco dei
  // lotti di materia prima DI ORIGINE (tra quelli passati in input a
  // RaccogliDatiPerMateriaPrima) che hanno contribuito a raggiungerlo. Non
  // e' detto sia uno solo: se la stessa chiamata analizza piu' lotti di
  // materia prima "andati a male" insieme, e un prodotto finito li ha
  // consumati entrambi, questo campo lo riporta esplicitamente - serve a
  // non perdere, nei documenti di compliance, quale lotto non conforme ha
  // raggiunto quale prodotto.
  TLottoProdottoFinitoImpattato = class
  public
    LottoProdottoFinitoID: Integer;
    ProdottoFinitoID: Integer;
    CodiceLotto: string;
    LottiMateriaPrimaOrigineIDs: TArray<Integer>;
  end;

  // Dati intermedi raccolti da RaccogliDatiPerMateriaPrima (privato, vedi
  // il relativo commento in TServizioRitiroRichiamo): per ogni lotto di
  // materia prima passato, i suoi dati di tracciabilita' a monte (DDT di
  // acquisto), e l'elenco dei lotti di prodotto finito raggiunti a valle
  // con il collegamento a quale lotto di origine li ha raggiunti. Uso
  // interno: costruito e consumato da ApriRitiro nella stessa chiamata,
  // mai restituito a un tool. Il passo successivo (vendite/DDT di uscita
  // dei clienti coinvolti, per ciascun lotto di prodotto finito qui
  // trovato) e' un metodo/tool separato, deliberatamente non incluso qui
  // - vedi la discussione su un futuro TrovaClientiLottoProdottoFinito.
  TDatiMateriaPrima = class
  public
    LottiOrigine: TObjectList<TLottoMateriaPrimaOrigine>;
    LottiProdottoFinitoImpattati: TObjectList<TLottoProdottoFinitoImpattato>;

    constructor Create;
    destructor Destroy; override;
  end;

  // Una singola non conformita' aperta da TServizioRitiroRichiamo.ApriRitiro:
  // una riga per lotto di materia prima (vedi discussione di progetto -
  // non_conformita.lotto_materia_prima_id e' una colonna singola, non un
  // array, quindi "aprire un ritiro su piu' lotti insieme" in pratica vuol
  // dire aprire piu' non conformita', una per lotto, non una sola con piu'
  // riferimenti). LottiProdottoFinitoIDs e' il sottoinsieme di
  // TDatiMateriaPrima.LottiProdottoFinitoImpattati che
  // QUESTO lotto specifico ha raggiunto (filtrato tramite
  // TLottoProdottoFinitoImpattato.LottiMateriaPrimaOrigineIDs) - non tutti
  // i lotti di prodotto finito trovati dall'analisi complessiva, solo
  // quelli di competenza di questa riga.
  TNonConformitaAperta = class
  public
    NonConformitaID: Integer;
    CodiceNC: string;
    LottoMateriaPrimaID: Integer;
    LottiProdottoFinitoIDs: TArray<Integer>;

    // Vera anche con RichiedeModelloRichiamoConsumatore ancora sconosciuto
    // a questo punto: la Scheda di Notifica OSA dipende solo dall'aver
    // raggiunto almeno un lotto di prodotto finito (vedi il commento
    // sopra), non
    // dall'esposizione clienti - quella verifica (vendite/DDT di uscita)
    // e' TrovaClientiLottoProdottoFinito, piu' sotto (il "Tool B" discusso),
    // che Result.LottiProdottoFinitoIDs permette di richiamare in un
    // secondo momento senza dover rifare la risalita di filiera.
    RichiedeSchedaNotificaOSA: Boolean;
  end;

  TEsitoAperturaRitiro = class
  public
    NonConformitaAperte: TObjectList<TNonConformitaAperta>;

    constructor Create;
    destructor Destroy; override;
  end;

  // Una spedizione (DDT di uscita) collegata a una riga ordine per un
  // lotto di prodotto finito coinvolto in un ritiro/richiamo. Elenco, non
  // singolo valore: una riga ordine puo' in teoria essere evasa con piu'
  // DDT (spedizioni parziali) - vedi TDDTUscitaRiga.GetByOrdineVenditaRiga.
  TSpedizioneRiga = class
  public
    DDTUscitaID: Integer;
    NumeroDDT: string;
    DataSpedizione: TDateTime;
    QuantitaSpedita: Currency;
  end;

  // Una riga ordine di vendita che referenzia il lotto di prodotto finito
  // in oggetto, con le eventuali spedizioni (DDT di uscita) gia' partite.
  // Solo riferimenti (ClienteID, non l'anagrafica): l'anagrafica cliente
  // si recupera altrove con un tool dedicato - vedi la discussione di
  // progetto sul perche' questo tool resta deliberatamente minimale (non
  // duplica get_list_vendite, che non sa filtrare per lotto).
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

  // Tutte le esposizioni (ordini, con le eventuali spedizioni) trovate per
  // UN lotto di prodotto finito.
  TLottoConClienti = class
  public
    LottoProdottoFinitoID: Integer;
    Esposizioni: TObjectList<TEsposizioneOrdine>;

    constructor Create;
    destructor Destroy; override;
  end;

  // Esito complessivo di TrovaClientiLottoProdottoFinito: un
  // TLottoConClienti per ciascun lotto di prodotto finito passato in
  // input.
  TEsitoClientiPerLotti = class
  public
    Lotti: TObjectList<TLottoConClienti>;

    constructor Create;
    destructor Destroy; override;
  end;

  // Layer Services per lo scenario 1 del tirocinio (ritiro/richiamo
  // prodotti non conformi). Dipende da TServizioGiacenza solo
  // concettualmente (entrambi orchestrano gli stessi model di lotti e
  // consumi); questa classe in particolare non modifica mai la
  // giacenza — e' un servizio di sola LETTURA/risalita piu' l'apertura
  // della non conformita', mai un decremento di magazzino. Per questo,
  // a differenza di TServizioGiacenza, qui non serve nessuna
  // transazione multi-step: ogni operazione tocca una tabella alla
  // volta (SELECT di risalita, oppure un singolo Insert su
  // non_conformita).
  // Una comunicazione da mandare a UN cliente per UNO dei due casi del
  // ritiro/richiamo (vedi TrovaComunicazioniClienti):
  //   MerceSpedita = True   i lotti non conformi gli sono gia' stati
  //                         spediti (richiamo);
  //   MerceSpedita = False  i lotti sono in suoi ordini non ancora spediti
  //                         (ritiro).
  // Un cliente che ricade in entrambi i casi ha DUE comunicazioni: ogni
  // email ha un solo scopo. Righe = una riga di testo gia' pronta per ogni
  // riga d'ordine coinvolta (prodotto, lotto, quantita', ordine, DDT).
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
    // Esplorazione ricorsiva a valle di UN lotto di semilavorato gia'
    // identificato come coinvolto (contiene, direttamente o
    // indirettamente, il componente non conforme): trova sia i prodotti
    // finiti che lo hanno consumato direttamente sia altri semilavorati
    // "genitori" che lo hanno consumato come componente (distinta base
    // multi-livello), esplorando questi ultimi a loro volta.
    class procedure EsploraLottoSemilavorato(ALottoSemilavoratoID: Integer;
      AProdottiFinitiTrovati, ASemilavoratiVisitati: TList<Integer>);

    // Raccoglie, per uno o piu' lotti di materia prima non conformi, i
    // dati che servono ad ApriRitiro per scrivere: risale la filiera
    // (riusando RisaliCatenaConsumoDaMateriaPrima), recupera il DDT di
    // acquisto di ciascun lotto di origine, e collega ogni lotto di
    // prodotto finito raggiunto al lotto di origine che lo ha raggiunto.
    // Nessuna valutazione di merito qui dentro (niente gravita', urgenza,
    // costi): e' un passo meccanico di raccolta/arricchimento dati, non
    // un'"analisi" in senso decisionale - da qui il nome, deciso apposta
    // per non promettere piu' di quello che la funzione fa davvero.
    // PRIVATE: non ha senso richiamarlo isolatamente, serve solo ad
    // ApriRitiro - nessun tool lo invoca da solo.
    class function RaccogliDatiPerMateriaPrima(
      const ALottiMateriaPrimaID: TArray<Integer>): TDatiMateriaPrima;
  public
    // Risalita di filiera a partire da un lotto di MATERIA PRIMA non
    // conforme: restituisce gli id di tutti i lotti di prodotto finito
    // potenzialmente coinvolti (diretti, o raggiunti attraverso uno o
    // piu' livelli di semilavorato).
    class function RisaliCatenaConsumoDaMateriaPrima(
      ALottoMateriaPrimaID: Integer): TArray<Integer>;

    // Come sopra, ma quando il lotto non conforme e' gia' un
    // SEMILAVORATO (la NC puo' nascere a qualunque dei tre livelli, vedi
    // il CHECK "OR" — non XOR — su non_conformita).
    class function RisaliCatenaConsumoDaSemilavorato(
      ALottoSemilavoratoID: Integer): TArray<Integer>;

    // Passo di SCRITTURA: apre una non conformita' per ciascuno dei lotti
    // di materia prima passati, riusando internamente
    // RaccogliDatiPerMateriaPrima (nessuna query di risalita duplicata).
    // ACodiceNCBase e' usato COSI' COM'E' se e' stato passato un solo
    // lotto; se i lotti sono piu' di uno, ogni riga prende un codice
    // derivato con suffisso "-1", "-2", ... nell'ordine di elaborazione
    // (deciso in fase di progetto: un solo codice fornito dal modello,
    // suffissato automaticamente, invece di chiedere al modello un array
    // di codici gia' pronti - piu' robusto per un modello locale 9B, che
    // altrimenti rischierebbe di generarne di duplicati).
    class function ApriRitiro(const ACodiceNCBase, AMotivo: string;
      const ALottiMateriaPrimaID: TArray<Integer>): TEsitoAperturaRitiro;

    // Tool "B": dati uno o piu' lotti di prodotto finito (tipicamente
    // l'esito di ApriRitiro), restituisce per ciascuno il dettaglio -
    // riga per riga, non solo un aggregato - degli ordini di vendita che
    // lo referenziano e, se gia' partite, delle spedizioni (DDT di
    // uscita) collegate. Pura lettura. A differenza di
    // RaccogliDatiPerMateriaPrima e' PUBLIC: e' pensato per essere
    // richiamabile anche da solo, non solo in coda ad ApriRitiro (vedi
    // discussione di progetto).
    class function TrovaClientiLottoProdottoFinito(
      const ALottiProdottoFinitoID: TArray<Integer>): TEsitoClientiPerLotti;

    // I clienti da avvisare per i lotti di prodotto finito indicati, gia'
    // divisi nei due casi (merce spedita / non spedita) e con i dati che
    // servono al testo dell'email. Parte da TrovaClientiLottoProdottoFinito
    // (stessi controlli sugli id) e aggiunge i dati LEGGIBILI: prodotto,
    // codice lotto, scadenza, cliente. Gli ordini annullati sono esclusi.
    // Sola lettura. Il risultato e' del chiamante; lista vuota = nessun
    // cliente coinvolto (caso normale).
    class function TrovaComunicazioniClienti(
      const ALottiProdottoFinitoID: TArray<Integer>): TObjectList<TComunicazioneCliente>;

  end;

implementation

{ TServizioRitiroRichiamo }

class procedure TServizioRitiroRichiamo.EsploraLottoSemilavorato(
  ALottoSemilavoratoID: Integer; AProdottiFinitiTrovati, ASemilavoratiVisitati: TList<Integer>);
var
  LConsumiInProdottoFinito: TObjectList<TConsumoProduzioneProdottoFinito>;
  LConsumiInSemilavorato: TObjectList<TConsumoProduzioneSemilavorato>;
  LConsumo1: TConsumoProduzioneProdottoFinito;
  LConsumo2: TConsumoProduzioneSemilavorato;
begin
  // Guardia anti-duplicazione: lo stesso lotto di semilavorato puo'
  // essere raggiunto da piu' percorsi (es. usato in due semilavorati
  // "genitori" diversi, o direttamente in piu' prodotti finiti); senza
  // questa guardia verrebbe esplorato piu' volte inutilmente. Una
  // distinta base di produzione non dovrebbe mai avere cicli (un lotto
  // non puo' consumare se stesso), ma la guardia protegge comunque da
  // un eventuale dato anomalo.
  if ASemilavoratiVisitati.Contains(ALottoSemilavoratoID) then
    Exit;
  ASemilavoratiVisitati.Add(ALottoSemilavoratoID);

  // Chi ha consumato questo lotto per fare un prodotto finito: punto
  // d'arrivo di questo ramo della risalita.
  LConsumiInProdottoFinito :=
    TConsumoProduzioneProdottoFinito.GetByLottoSemilavorato(ALottoSemilavoratoID);
  try
    for LConsumo1 in LConsumiInProdottoFinito do
      if not AProdottiFinitiTrovati.Contains(LConsumo1.LottoProdottoFinitoID) then
        AProdottiFinitiTrovati.Add(LConsumo1.LottoProdottoFinitoID);
  finally
    LConsumiInProdottoFinito.Free;
  end;

  // Chi ha consumato questo lotto come componente "figlio" di un altro
  // semilavorato: un ulteriore livello di distinta base, da esplorare
  // ricorsivamente prima di fermarsi.
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
    // Passo 1: chi ha consumato DIRETTAMENTE questo lotto di materia
    // prima per fare un prodotto finito, senza passare da un
    // semilavorato intermedio.
    LConsumiDiretti1 := TConsumoProduzioneProdottoFinito.GetByLottoMateriaPrima(ALottoMateriaPrimaID);
    try
      for LConsumo1 in LConsumiDiretti1 do
        if not LProdottiFinitiTrovati.Contains(LConsumo1.LottoProdottoFinitoID) then
          LProdottiFinitiTrovati.Add(LConsumo1.LottoProdottoFinitoID);
    finally
      LConsumiDiretti1.Free;
    end;

    // Passo 2: chi ha consumato questo lotto di materia prima per fare
    // un semilavorato — da ciascuno si esplora ricorsivamente a valle.
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

{ TDatiMateriaPrima }

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
  // Indice temporaneo lotto_prodotto_finito_id -> oggetto gia' creato: NON
  // possiede gli oggetti (TDictionary semplice, non TObjectDictionary) -
  // la proprieta' passa a Result.LottiProdottoFinitoImpattati nel momento
  // stesso in cui l'oggetto viene creato (vedi sotto), quindi liberare
  // questa mappa alla fine libera solo la struttura della mappa, mai gli
  // oggetti che indicizza.
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
      // Guardia anti-duplicati: se lo stesso id compare piu' volte in
      // input (es. ripetuto per errore dal modello), lo si elabora una
      // sola volta - stesso principio gia' usato in EsploraLottoSemilavorato.
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

        // DDT di acquisto: risale da lotto -> riga DDT -> testata DDT.
        // ddt_entrata_riga_id e' NOT NULL a livello di schema, quindi
        // LDDTRiga non dovrebbe mai essere nil - il controllo resta
        // comunque per robustezza (vedi commento di classe sopra).
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

      // Risalita a valle: riusa TAL QUALE RisaliCatenaConsumoDaMateriaPrima,
      // gia' esistente e verificata, nessuna duplicazione di query.
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

          // La proprieta' dell'oggetto passa SUBITO a Result: la mappa lo
          // indicizza solo per riferimento (vedi commento sulla var sopra).
          Result.LottiProdottoFinitoImpattati.Add(LImpattato);
          LMappaImpattati.Add(LProdottoFinitoID, LImpattato);
        end;

        // Aggiunge questo lotto di origine all'elenco di chi ha raggiunto
        // il prodotto finito - puo' capitare piu' di una volta per lo
        // stesso prodotto se piu' lotti di origine lo raggiungono entrambi
        // (vedi commento di classe su TLottoProdottoFinitoImpattato).
        LImpattato.LottiMateriaPrimaOrigineIDs :=
          LImpattato.LottiMateriaPrimaOrigineIDs + [LLottoOrigineID];
      end;
    end;
  finally
    LIDsProcessati.Free;
    LMappaImpattati.Free;
  end;
end;

{ TEsitoAperturaRitiro }

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

  // CONTROLLO DI DIFESA (tappa 13): il codice della non conformita' deve
  // essere unico. Lo verifichiamo PRIMA di scrivere qualunque riga ("tutto o
  // niente"): se anche uno solo dei codici che stiamo per usare esiste gia',
  // non si apre nulla e l'errore dice quale codice e' occupato, cosi' chi
  // chiama (utente o modello) sa cosa correggere. Caso reale osservato nei
  // test (S1-B): il modello riproponeva l'apertura di una non conformita'
  // appena aperta, e senza questo controllo ne sarebbe nata una doppia.
  // Si controllano sia il codice base sia quelli con suffisso "-1", "-2"...
  // perche' quale dei due verra' usato dipende dal numero di lotti distinti.
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

  // Riusa RaccogliDatiPerMateriaPrima: stessa risalita di filiera, stesso
  // DDT di acquisto, nessuna query duplicata. LDati resta di proprieta'
  // di questo metodo (Free nel finally), i dati che servono all'esito
  // vengono copiati/filtrati in LottiProdottoFinitoIDs.
  LDati := RaccogliDatiPerMateriaPrima(ALottiMateriaPrimaID);
  try
    Result := TEsitoAperturaRitiro.Create;

    // Stessa guardia anti-duplicati di RaccogliDatiPerMateriaPrima: serve
    // anche qui, sia per non aprire due volte la stessa non conformita'
    // sullo stesso lotto sia per calcolare correttamente se serve o meno
    // il suffisso numerico sul codice (Length(ALottiMateriaPrimaID) da
    // solo non basta, potrebbe contenere ripetizioni).
    LIDsProcessati := TList<Integer>.Create;
    try
      for LLottoOrigineID in ALottiMateriaPrimaID do
        if not LIDsProcessati.Contains(LLottoOrigineID) then
          LIDsProcessati.Add(LLottoOrigineID);

      LIndiceRiga := 0;
      for LLottoOrigineID in LIDsProcessati do
      begin
        Inc(LIndiceRiga);

        // Un solo lotto (dopo dedup): il codice fornito resta cosi'
        // com'e'. Piu' di uno: suffisso "-1", "-2", ... nell'ordine di
        // elaborazione (vedi commento sulla dichiarazione del metodo).
        if LIDsProcessati.Count = 1 then
          LCodiceNC := ACodiceNCBase
        else
          LCodiceNC := ACodiceNCBase + '-' + IntToStr(LIndiceRiga);

        // 1) Scrittura vera e propria: una riga in non_conformita per
        //    questo lotto. EnsureAlmenoUnLottoValido (dentro Insert) non
        //    puo' fallire qui: LottoMateriaPrimaID e' sempre valorizzato.
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

        // 2) Filtra dall'analisi gia' calcolata i soli lotti di prodotto
        //    finito raggiunti DA QUESTO lotto di origine (vedi commento
        //    di classe su TNonConformitaAperta).
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

{ TEsposizioneOrdine }

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

{ TLottoConClienti }

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

{ TEsitoClientiPerLotti }

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

// Tool "B" (vedi discussione di progetto e commento sulla dichiarazione,
// piu' sopra): per ogni lotto di prodotto finito passato, trova le righe
// ordine che lo referenziano (TOrdineVenditaRiga.GetByLottoProdottoFinito,
// gia' esistente) e, per ciascuna, risale all'header ordine (cliente,
// numero) e alle eventuali righe di DDT di uscita gia' emesse per quella
// riga specifica. Pura lettura, nessuna scrittura, multi-lotto in input
// come RaccogliDatiPerMateriaPrima - stesso principio "tool generico e
// parametrico" del documento di progetto.
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

  // CONTROLLO DI DIFESA (tappa 13): ogni id deve essere un lotto di prodotto
  // finito che esiste. Prima un id inventato dava "nessun ordine", cioe' una
  // risposta rassicurante e FALSA ("non e' stato spedito a nessuno") proprio
  // in uno scenario di richiamo. Ora "lotto esistente senza ordini" (lista
  // vuota, caso normale) e "lotto inesistente" (errore) restano distinti.
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
    // L'esistenza del lotto e' gia' stata verificata sopra. Un lotto di
    // prodotto finito senza ordini collegati e' un caso normale
    // (semplicemente Esposizioni resta vuota), non un errore.
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

        // Header ordine: solo da qui si arriva al cliente e al numero
        // ordine, la riga non li porta (vedi commento di classe).
        LOrdine := TOrdineVendita.GetByID(LRigaOrdine.OrdineVenditaID);
        if LOrdine <> nil then
        try
          LEsposizione.NumeroOrdine := LOrdine.NumeroOrdine;
          LEsposizione.ClienteID := LOrdine.ClienteID;
        finally
          LOrdine.Free;
        end;

        // Spedizioni gia' emesse per QUESTA riga specifica: zero, una, o
        // piu' di una in caso di evasione parziale su piu' DDT.
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

{ TComunicazioneCliente }

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
  // Le virgolette tengono fissa la barra: "/" da solo sarebbe il separatore
  // di data delle impostazioni di Windows.
  FORMATO_DATA = 'dd"/"mm"/"yyyy';

  // La comunicazione di (cliente, caso) gia' in elenco, oppure una nuova.
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

  // Stessa ricerca (e stessi controlli sugli id) dell'altro tool: un solo
  // punto decide quali ordini e quali DDT riguardano un lotto.
  LEsito := TrovaClientiLottoProdottoFinito(ALottiProdottoFinitoID);
  try
    Result := TObjectList<TComunicazioneCliente>.Create(True);
    try
      for LLottoConClienti in LEsito.Lotti do
      begin
        // "Prodotto (codice), lotto X, scadenza gg/mm/aaaa": e' cio' che il
        // cliente trova scritto sulla confezione, non l'id del database.
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
          // Un ordine annullato non verra' mai consegnato: nessun avviso.
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

          // Il caso si decide per RIGA d'ordine: almeno un DDT = spedita.
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
