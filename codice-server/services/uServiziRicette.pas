unit uServiziRicette;

interface

uses
  System.SysUtils,
  System.Generics.Collections,
  FireDAC.Comp.Client,
  DbU,
  uModelAllergene,
  uModelMateriaPrima,
  uModelSemilavorato,
  uModelProdottoFinito,
  uModelRicettaProdottoFinito,
  uModelRicettaProdottoFinitoRiga,
  uModelRicettaSemilavorato,
  uModelRicettaSemilavoratoRiga;

type
  // Il costo, componente per componente, della ricetta CORRENTE di un
  // prodotto finito (o di un semilavorato - vedi TCostoRicettaSemilavorato).
  // DTO interno al layer Services: non persistito, non JSON.
  //
  // CostoUnitario e' sempre espresso NELLA STESSA unita' di misura di
  // UnitaMisuraDose (es. se UnitaMisuraDose = 'g', CostoUnitario e' un
  // prezzo al grammo), cosi' CostoTotale = QuantitaStandard *
  // CostoUnitario e' sempre corretto anche quando l'unita' di dose della
  // ricetta differisce da quella di acquisto del componente (es. materia
  // prima acquistata in kg ma dosata in g in ricetta - vedi il commento
  // su TRicettaSemilavoratoRiga.UnitaMisuraDose, e' un caso voluto, non
  // un errore). La conversione la fa
  // TServizioRicette.CostoUnitarioMateriaPrima, non il chiamante - vedi
  // ConvertiQuantita piu' sotto. Vale SOLO per i componenti materia
  // prima: per i componenti semilavorato vedi CostoDisponibile sotto.
  TCostoComponenteRicetta = class
  public
    IsComponenteMateriaPrima: Boolean;
    ComponenteID: Integer;   // materia_prima_id o semilavorato_id, a seconda del flag sopra
    Denominazione: string;   // nome leggibile del componente - vedi il commento in
                              // CalcolaCostoRicettaProdottoFinito sul perche' e' qui e non solo l'id
    QuantitaStandard: Currency;
    UnitaMisuraDose: string;
    CostoUnitario: Currency;
    CostoTotale: Currency;   // QuantitaStandard * CostoUnitario

    // False SOLO per componenti semilavorato: lo schema attuale di
    // ricette_semilavorati non censisce la resa di produzione (quanto
    // produce UNA esecuzione della ricetta), quindi non c'e' modo di
    // derivare un costo per unita' di peso/volume dal costo dell'intera
    // esecuzione senza rischiare di gonfiarlo (vedi il commento in testa
    // a CalcolaCostoRicettaProdottoFinito). Quando False, CostoUnitario e
    // CostoTotale restano a 0 e NON entrano nel CostoTotale aggregato del
    // padre (TCostoRicetta/TCostoRicettaSemilavorato.CostoCompleto lo
    // segnala). Sempre True per le materie prime, il cui costo e' sempre
    // disponibile (da DDT o da ordine, vedi CostoUnitarioMateriaPrima).
    CostoDisponibile: Boolean;
  end;

  TCostoRicetta = class
  public
    ProdottoFinitoID: Integer;
    RicettaID: Integer;
    Versione: Integer;
    Componenti: TObjectList<TCostoComponenteRicetta>;
    CostoTotale: Currency;   // somma dei SOLI componenti con CostoDisponibile = True

    // False se almeno un componente e' un semilavorato (vedi
    // TCostoComponenteRicetta.CostoDisponibile): CostoTotale in quel caso
    // e' un costo PARZIALE, non il costo reale della ricetta. Chi mostra
    // questo dato (uRicetteToolProvider.pas, uControllerRicette.pas) deve
    // segnalarlo esplicitamente invece di presentare CostoTotale come se
    // fosse completo.
    CostoCompleto: Boolean;

    constructor Create;
    destructor Destroy; override;
  end;

  // Gemella di TCostoRicetta, per la ricetta CORRENTE di un semilavorato
  // invece che di un prodotto finito (introdotta per la vista "dettaglio
  // ricetta" della schermata Semilavorati del frontend, GET /api/ricette/
  // semilavorati/($id) — vedi TControllerRicette). Stessa struttura
  // (Componenti + CostoTotale); campo di testata SemilavoratoID al posto
  // di ProdottoFinitoID invece di un campo EntitaID generico con un flag
  // "tipo": il chiamante sa gia' con quale entita' ha a che fare (ha
  // scelto lui quale dei due metodi chiamare), un flag qui non
  // aggiungerebbe informazione, solo un controllo in piu' da fare.
  TCostoRicettaSemilavorato = class
  public
    SemilavoratoID: Integer;
    RicettaID: Integer;
    Versione: Integer;
    Componenti: TObjectList<TCostoComponenteRicetta>;
    CostoTotale: Currency;   // somma dei SOLI componenti con CostoDisponibile = True

    // Vedi il commento gemello su TCostoRicetta.CostoCompleto: False se
    // almeno un componente di QUESTA ricetta e' a sua volta un
    // semilavorato (distinta base multi-livello), il cui costo non e'
    // calcolabile per lo stesso motivo.
    CostoCompleto: Boolean;

    constructor Create;
    destructor Destroy; override;
  end;

  // Una riga della vista trasversale "tutte le ricette correnti" (sia di
  // prodotti finiti sia di semilavorati), usata dalla schermata "Ricette e
  // distinte" del frontend per la lista (GET /api/ricette). Elenco
  // leggero: niente componenti ne' costo, solo NumeroComponenti (un COUNT
  // lato SQL). Calcolare il costo per OGNI riga di una lista sarebbe
  // sforzo sprecato per un dato che li' non serve — il costo di una sola
  // materia prima richiede gia' una query su DDT/ordini fornitore, il
  // dettaglio (GET /api/ricette/prodotti-finiti/($id) o /semilavorati/
  // ($id)) lo calcola solo per LA ricetta che l'utente ha aperto.
  TRicettaCorrenteSintetica = class
  public
    IsProdottoFinito: Boolean;   // False = semilavorato
    EntitaID: Integer;           // prodotto_finito_id o semilavorato_id, a seconda del flag sopra
    Codice: string;
    Denominazione: string;
    RicettaID: Integer;
    Versione: Integer;
    ValidaDal: TDateTime;
    CreatoDa: string;
    Note: string;
    NumeroComponenti: Integer;
  end;

  // Una singola sostituzione richiesta all'interno di un adattamento di
  // ricetta: "togli questo componente, mettine un altro". Un adattamento
  // reale (es. "senza lattosio") tipicamente ne comprende PIU' di una
  // insieme (es. sia il latte in polvere sia il burro) - per questo
  // Simula/ApplicaAdattamentoRicetta lavorano su un ARRAY di questo
  // record, non su una singola sostituzione: tutte le righe cambiate
  // insieme producono UNA sola nuova versione di ricetta (o UN solo nuovo
  // prodotto), mai una versione/un prodotto intermedio per ciascun cambio
  // - la stessa atomicita' che il vecchio ApplicaSostituzioneIngrediente
  // (sostituito da questo file) gia' garantiva per il caso a un solo
  // componente.
  TSostituzioneComponente = record
    VecchioIsMateriaPrima: Boolean;
    VecchioComponenteID: Integer;
    NuovoIsMateriaPrima: Boolean;
    NuovoComponenteID: Integer;
    NuovaQuantitaStandard: Currency;  // 0 = mantieni la dose del componente sostituito
    NuovaUnitaMisuraDose: string;     // '' = mantieni l'unita' del componente sostituito
  end;

  // Un componente NUOVO da aggiungere alla ricetta risultante, SENZA
  // sostituire nulla di esistente - caso reale osservato nello scenario 3:
  // togliendo il burro da un frollino per renderlo senza lattosio si perde
  // struttura, e serve poter aggiungere un legante/addensante che nella
  // ricetta originale non c'era affatto, non solo scambiare un componente
  // con un altro. TSostituzioneComponente da sola non basta a esprimerlo:
  // richiede sempre un "vecchio" componente da cui partire.
  //
  // A differenza di TSostituzioneComponente, qui QuantitaStandard e
  // UnitaMisuraDose sono SEMPRE obbligatorie, non sentinelle opzionali
  // (0/''): non esiste un componente di partenza da cui ereditarle se il
  // chiamante le omette, quindi CalcolaRigheFinali solleva un'eccezione se
  // arrivano vuote invece di indovinare un default privo di senso.
  TAggiuntaComponente = record
    IsMateriaPrima: Boolean;
    ComponenteID: Integer;
    QuantitaStandard: Currency;
    UnitaMisuraDose: string;
  end;

  // Un componente (materia prima o semilavorato) proposto da
  // TServizioRicette.CercaComponenti come possibile sostituto: porta gia'
  // i propri allergeni, cosi' il chiamante (tool MCP, poi il modello) puo'
  // mostrarli senza una seconda interrogazione per elemento.
  TCandidatoComponente = class
  public
    IsMateriaPrima: Boolean;
    ID: Integer;
    Codice: string;
    Denominazione: string;
    Allergeni: TObjectList<TAllergene>;  // posseduto

    // Giacenza disponibile AGGREGATA (somma su tutti i lotti, vedi
    // TServizioGiacenza.GiacenzaDisponibileMateriaPrima/Semilavorato) del
    // componente candidato, al momento della ricerca. PURAMENTE
    // INFORMATIVO: CercaComponenti la calcola e la espone cosi' il
    // modello puo' avvisare il cliente ("posso proporlo, ma al momento
    // non c'e' disponibilita' in magazzino"), ma zero giacenza NON esclude
    // il candidato dai risultati ne' blocca simula_adattamento_ricetta o
    // applica_adattamento_ricetta piu' avanti nel flusso - un adattamento
    // di ricetta crea/riusa una VARIANTE (una distinta base), non una
    // produzione: non consuma magazzino nell'immediato, quindi la
    // giacenza di oggi non e' un vincolo per poter registrare la ricetta,
    // solo un'informazione utile a chi decide se proporla ora.
    GiacenzaDisponibile: Currency;

    destructor Destroy; override;
  end;

  // Esito della simulazione (Turno 1: sola lettura, nessuna scrittura) di
  // un adattamento - una o piu' sostituzioni insieme - alla ricetta
  // corrente di un prodotto finito: quanto cambierebbe il costo e come
  // cambierebbe l'elenco di allergeni della ricetta risultante. E' il
  // tool MCP (o il modello, nel turno conversazionale successivo) a
  // decidere se procedere davvero con
  // TServizioRicette.ApplicaAdattamentoRicetta in base a questo esito.
  //
  // AllergeniAttuali/AllergeniSimulati sono entrambi RICALCOLATI dalla
  // composizione della ricetta (unione degli allergeni di ogni riga), non
  // letti dalla tabella etichetta anagrafiche_prodotti_finiti_allergeni:
  // cosi' il confronto "prima/dopo" e' sempre coerente con le righe
  // davvero coinvolte, anche se l'etichetta del prodotto originale non
  // fosse per qualche motivo perfettamente allineata alla sua ricetta.
  TSimulazioneAdattamento = class
  public
    ProdottoFinitoID: Integer;
    CostoRicettaAttuale: Currency;
    CostoRicettaSimulata: Currency;
    DeltaCosto: Currency;             // simulata - attuale: positivo = piu' caro

    // False se la ricetta attuale o quella simulata contiene almeno un
    // componente semilavorato (vedi TCostoComponenteRicetta.
    // CostoDisponibile): in quel caso CostoRicettaAttuale/Simulata/
    // DeltaCosto sono calcolati sui SOLI componenti materia prima, un
    // dato parziale che il modello deve presentare come tale al cliente,
    // non come il vero delta economico dell'adattamento.
    CostoCompleto: Boolean;

    AllergeniAttuali: TObjectList<TAllergene>;
    AllergeniSimulati: TObjectList<TAllergene>;
    AllergeniRimossi: TObjectList<TAllergene>;   // in Attuali ma non in Simulati (posseduti da AllergeniAttuali)
    AllergeniAggiunti: TObjectList<TAllergene>;  // in Simulati ma non in Attuali (posseduti da AllergeniSimulati)

    destructor Destroy; override;
  end;

  // Esito di ApplicaAdattamentoRicetta (Turno 2: scrittura).
  // VarianteGiaEsistente distingue i due possibili esiti positivi: creata
  // una nuova variante, oppure trovata e riusata una variante compatibile
  // gia' esistente (vedi il commento sul metodo per il criterio di
  // compatibilita') - cosi' il tool MCP puo' far dire al modello "ho
  // creato XYZ" oppure "esiste gia' XYZ, te la apro" invece di creare
  // inutilmente un duplicato.
  TEsitoAdattamentoRicetta = class
  public
    VarianteGiaEsistente: Boolean;
    ProdottoFinitoID: Integer;      // il prodotto (nuovo o riusato) risultante
    Codice: string;
    Denominazione: string;
    ProdottoFinitoPadreID: Integer;
    RicettaID: Integer;             // 0 se VarianteGiaEsistente (nessuna scrittura fatta)
    Versione: Integer;
    CostoRicetta: Currency;         // 0 se VarianteGiaEsistente (non ricalcolato sulla variante trovata)
    CostoRicettaCompleto: Boolean;  // vedi TSimulazioneAdattamento.CostoCompleto - stesso significato
  end;

  // Layer Services per lo scenario 3 del tirocinio (adattamento ricette su
  // richiesta cliente con calcolo economico multi-turno). Il "multi-turno"
  // e' gestito dal modello conversazionale (ogni turno e' una chiamata
  // tool separata, orchestrata da LM Studio/Qwen), non da uno stato
  // interno a questa classe: qui esponiamo le operazioni granulari che i
  // turni tipici richiamano - CercaComponenti (individua i sostituti
  // compatibili con un vincolo dietetico), SimulaAdattamentoRicetta
  // (Turno 1: proponi e mostra l'impatto, nessuna scrittura) e
  // ApplicaAdattamentoRicetta (Turno 2: il cliente conferma, si crea la
  // variante).
  //
  // Scelta di dominio: un adattamento NON modifica mai in-place la
  // ricetta del prodotto di partenza. Produce sempre una VARIANTE - un
  // prodotto finito a se' (proprio codice/denominazione/etichetta),
  // agganciato al prodotto originale tramite
  // TProdottoFinito.ProdottoFinitoPadreID - riusando una variante
  // compatibile gia' esistente quando ce n'e' una, per non accumulare
  // duplicati. Il prodotto originale resta quindi sempre in vendita
  // invariato: coerente con l'idea che "senza glutine" e' una variante
  // commerciale, non una correzione del prodotto esistente.
  TServizioRicette = class
  private
    // Ultimo costo unitario noto di una materia prima: preferenza al
    // prezzo REALMENTE pagato (ultima riga DDT di entrata, per data di
    // ricezione) rispetto al prezzo negoziato in ordine, che puo'
    // differire (vedi il commento di TOrdineFornitoreRiga.PrezzoUnitario).
    // Se la materia prima non e' mai stata ancora consegnata (nessun
    // DDT), si ripiega sull'ultimo prezzo d'ordine disponibile. Se non
    // esiste NESSUN dato di costo (mai ordinata ne' consegnata), solleva
    // un'eccezione: senza un costo non e' possibile fare "calcolo
    // economico", meglio fallire esplicitamente che restituire 0.
    //
    // AUnitaMisuraRichiesta e' l'unita' di dose della riga di ricetta che
    // sta chiamando (es. 'g'): il prezzo che arriva da DDT/ordine e'
    // espresso nell'unita' di ACQUISTO della materia prima (tipicamente
    // 'kg' o 'l'), che puo' differire da quella di dose - vedi
    // ConvertiQuantita per la conversione. Se le due unita' non sono
    // della stessa grandezza fisica (es. 'kg' vs 'l') solleva
    // un'eccezione: e' un dato di ricetta incoerente, non qualcosa da
    // ignorare silenziosamente.
    class function CostoUnitarioMateriaPrima(AMateriaPrimaID: Integer;
      const AUnitaMisuraRichiesta: string): Currency;
  public
    // Costo completo, componente per componente, della ricetta corrente
    // di un prodotto finito.
    class function CalcolaCostoRicettaProdottoFinito(
      AProdottoFinitoID: Integer): TCostoRicetta;

    // Gemella di CalcolaCostoRicettaProdottoFinito, per la ricetta
    // CORRENTE di un semilavorato. Un componente che e' a sua volta un
    // semilavorato compare come riga con CostoDisponibile = False (vedi
    // TCostoComponenteRicetta): lo schema attuale non censisce la resa
    // di produzione, quindi non c'e' modo di ricavarne un costo per
    // unita' senza rischiare di gonfiarlo - vedi il commento in testa a
    // CalcolaCostoRicettaProdottoFinito per il ragionamento completo.
    class function CalcolaCostoRicettaSemilavorato(
      ASemilavoratoID: Integer): TCostoRicettaSemilavorato;

    // Elenco di tutte le ricette CORRENTI esistenti, sia di prodotti
    // finiti sia di semilavorati, per la vista trasversale "Ricette e
    // distinte" del frontend. Una sola query (UNION ALL fra le due
    // coppie anagrafica/ricetta) invece di due letture separate
    // ricomposte in Delphi: piu' semplice, e l'ordinamento finale per
    // denominazione lo fa il database, non l'applicazione.
    class function GetRicetteCorrenti: TObjectList<TRicettaCorrenteSintetica>;

    // Allergeni dichiarati di un componente (materia prima o
    // semilavorato — il flag distingue quale anagrafica interrogare).
    // Sottile ma centralizza la scelta "quale GetAllergeni chiamare" in
    // un unico punto, cosi' il resto del service non deve ripeterla.
    class function GetAllergeniComponente(AIsComponenteMateriaPrima: Boolean;
      AComponenteID: Integer): TObjectList<TAllergene>;

    // Cerca materie prime e/o semilavorati candidati a sostituire un
    // componente di ricetta, filtrando per allergene da escludere
    // (opzionale - codice, es. "LAT") e per testo sulla denominazione
    // (opzionale). Tool generico e parametrico (documento di progetto,
    // sezione 4): un solo metodo per qualunque combinazione di filtri,
    // non uno specifico per "materie prime senza glutine" e uno per
    // "semilavorati senza lattosio". AAllergeneEscluso vuoto/non
    // riconosciuto: '' non filtra affatto, un codice sconosciuto solleva
    // un'eccezione (errore di chi ha costruito la chiamata, da segnalare
    // subito invece di restituire silenziosamente zero risultati).
    class function CercaComponenti(const AEscludiAllergeneCodice: string;
      AIncludiMateriePrime, AIncludiSemilavorati: Boolean;
      const ATesto: string): TObjectList<TCandidatoComponente>;

    // Turno 1: simula un adattamento (una o piu' sostituzioni e/o aggiunte
    // insieme) della ricetta CORRENTE di un prodotto finito, SENZA
    // scrivere nulla sul DB. Restituisce il delta di costo e come
    // cambierebbe l'elenco di allergeni, cosi' il modello puo' presentarli
    // al cliente prima di procedere. ASostituzioni e AAggiunte possono
    // essere usate insieme o singolarmente, ma non entrambe vuote (vedi
    // CalcolaRigheFinali per la differenza fra le due: una sostituzione
    // parte sempre da un componente esistente, un'aggiunta no).
    class function SimulaAdattamentoRicetta(AProdottoFinitoID: Integer;
      const ASostituzioni: TArray<TSostituzioneComponente>;
      const AAggiunte: TArray<TAggiuntaComponente>): TSimulazioneAdattamento;

    // Turno 2: applica DAVVERO l'adattamento. Non tocca mai la ricetta del
    // prodotto di partenza: cerca prima una VARIANTE gia' esistente
    // (TProdottoFinito.GetVarianti sul prodotto radice) la cui etichetta
    // attuale non contenga nessuno degli allergeni che questo adattamento
    // toglie - se la trova, non scrive nulla e la segnala come tale
    // (TEsitoAdattamentoRicetta.VarianteGiaEsistente = True). Solo se
    // nessuna variante compatibile esiste ne crea una nuova (richiede
    // ACodiceNuovoProdotto/ADenominazioneNuovoProdotto, obbligatori in
    // quel caso) con la sua prima versione di ricetta: righe copiate dalla
    // ricetta di partenza, con le sostituzioni richieste applicate E le
    // aggiunte accodate (vedi CalcolaRigheFinali - i componenti NON
    // toccati da ASostituzioni finiscono comunque, invariati, nella nuova
    // ricetta: un adattamento non e' mai una ricetta scritta da zero, e'
    // sempre "quella di partenza, con questi cambiamenti"), in un'unica
    // scrittura atomica (TDB.ExecuteInTransaction) - o la nuova versione
    // ha tutte le righe corrette, o nessuna.
    class function ApplicaAdattamentoRicetta(AProdottoFinitoID: Integer;
      const ASostituzioni: TArray<TSostituzioneComponente>;
      const AAggiunte: TArray<TAggiuntaComponente>;
      const ACodiceNuovoProdotto, ADenominazioneNuovoProdotto: string;
      const ACreatoDa, ANote: string): TEsitoAdattamentoRicetta;
  end;

implementation

uses
  System.Variants,
  uServiziGiacenza;

const
  // Prezzo REALE pagato: ultima riga DDT di entrata per la materia
  // prima, ordinata per data di ricezione effettiva. unita_misura e'
  // l'unita' in cui quel prezzo e' espresso (tipicamente 'kg' o 'l' per
  // materie prime alimentari) - va SEMPRE letta insieme al prezzo, mai
  // assunta uguale all'unita' di dose della riga di ricetta che lo
  // consuma (vedi ConvertiQuantita).
  SQL_COSTO_DA_DDT =
    'SELECT r.prezzo_unitario, r.unita_misura ' +
    'FROM ddt_entrata_righe r ' +
    'JOIN ddt_entrata d ON d.id = r.ddt_entrata_id ' +
    'WHERE r.materia_prima_id = :materia_prima_id ' +
    'ORDER BY d.data_ricezione DESC ' +
    'LIMIT 1';

  // Fallback: prezzo negoziato nell'ultimo ordine fornitore, se la
  // materia prima non e' ancora mai stata consegnata.
  SQL_COSTO_DA_ORDINE =
    'SELECT r.prezzo_unitario, r.unita_misura ' +
    'FROM ordini_fornitori_righe r ' +
    'JOIN ordini_fornitori o ON o.id = r.ordine_fornitore_id ' +
    'WHERE r.materia_prima_id = :materia_prima_id ' +
    'ORDER BY o.data_ordine DESC ' +
    'LIMIT 1';

{ TCostoRicetta }

constructor TCostoRicetta.Create;
begin
  inherited Create;
  Componenti := TObjectList<TCostoComponenteRicetta>.Create(True);
  CostoTotale := 0;
  CostoCompleto := True; // diventa False al primo componente semilavorato incontrato
end;

destructor TCostoRicetta.Destroy;
begin
  Componenti.Free;
  inherited Destroy;
end;

{ TCostoRicettaSemilavorato }

constructor TCostoRicettaSemilavorato.Create;
begin
  inherited Create;
  Componenti := TObjectList<TCostoComponenteRicetta>.Create(True);
  CostoTotale := 0;
  CostoCompleto := True; // diventa False al primo componente semilavorato incontrato
end;

destructor TCostoRicettaSemilavorato.Destroy;
begin
  Componenti.Free;
  inherited Destroy;
end;

{ TCandidatoComponente }

destructor TCandidatoComponente.Destroy;
begin
  Allergeni.Free;
  inherited;
end;

{ TSimulazioneAdattamento }

destructor TSimulazioneAdattamento.Destroy;
begin
  // AllergeniRimossi/AllergeniAggiunti NON posseggono i propri elementi
  // (vedi SottraiAllergeni sotto): contengono riferimenti agli stessi
  // oggetti di AllergeniAttuali/AllergeniSimulati, che li liberano.
  AllergeniRimossi.Free;
  AllergeniAggiunti.Free;
  AllergeniSimulati.Free;
  AllergeniAttuali.Free;
  inherited;
end;

{ Funzioni di supporto, private all'unit }

// Una riga di ricetta "risolta": lo stesso componente (IsComponenteMateriaPrima
// + ComponenteID) di TCostoComponenteRicetta/TRicettaProdottoFinitoRiga, ma
// senza dipendere ne' dal model (che va liberato presto) ne' dal DTO di
// costo (che porta anche prezzo, non sempre gia' noto quando serve la
// riga). E' la rappresentazione comune su cui lavorano sia il calcolo
// costo sia il calcolo allergeni, prima e dopo una sostituzione.
type
  TRigaFinale = record
    IsComponenteMateriaPrima: Boolean;
    ComponenteID: Integer;
    QuantitaStandard: Currency;
    UnitaMisuraDose: string;
  end;

function RigaToFinale(ARiga: TRicettaProdottoFinitoRiga): TRigaFinale;
begin
  Result.IsComponenteMateriaPrima := ARiga.IsComponenteMateriaPrima;
  if ARiga.IsComponenteMateriaPrima then
    Result.ComponenteID := ARiga.MateriaPrimaID
  else
    Result.ComponenteID := ARiga.SemilavoratoID;
  Result.QuantitaStandard := ARiga.QuantitaStandard;
  Result.UnitaMisuraDose := ARiga.UnitaMisuraDose;
end;

function RigheToFinali(ARighe: TObjectList<TRicettaProdottoFinitoRiga>): TArray<TRigaFinale>;
var
  LRiga: TRicettaProdottoFinitoRiga;
  LLista: TList<TRigaFinale>;
begin
  LLista := TList<TRigaFinale>.Create;
  try
    for LRiga in ARighe do
      LLista.Add(RigaToFinale(LRiga));
    Result := LLista.ToArray;
  finally
    LLista.Free;
  end;
end;

// Applica TUTTE le sostituzioni richieste alle righe della ricetta
// corrente, poi accoda le righe NUOVE indicate in AAggiunte, in un solo
// passaggio, e restituisce le righe FINALI (quelle da scrivere se si
// procede, o da cui ricalcolare costo/allergeni se si sta solo
// simulando). I componenti della ricetta di partenza non toccati da
// nessuna sostituzione passano INVARIATI (vedi il ramo "else" sotto): un
// adattamento e' sempre "la ricetta di partenza, con questi cambiamenti",
// mai una ricetta riscritta da zero - per questo il chiamante non deve (e
// non puo') rielencare i componenti che restano uguali, solo quelli che
// cambiano o si aggiungono.
//
// Valida che ogni sostituzione richiesta trovi esattamente una riga da
// sostituire nella ricetta di partenza - se una non la trova, o se due
// sostituzioni puntano allo stesso componente vecchio, solleva
// un'eccezione PRIMA che il chiamante possa scrivere qualunque cosa (vedi
// ApplicaAdattamentoRicetta) - e valida che nessun componente (stesso
// tipo+id) finisca per comparire due volte fra le righe finali, che si
// tratti di due sostituzioni verso lo stesso nuovo componente o di
// un'aggiunta che duplica qualcosa gia' in ricetta.
function CalcolaRigheFinali(ARigheOriginali: TObjectList<TRicettaProdottoFinitoRiga>;
  const ASostituzioni: TArray<TSostituzioneComponente>;
  const AAggiunte: TArray<TAggiuntaComponente>): TArray<TRigaFinale>;
var
  LRigaOriginale: TRicettaProdottoFinitoRiga;
  LSostituzione: TSostituzioneComponente;
  LAggiunta: TAggiuntaComponente;
  LUsate: TArray<Boolean>;
  I, J, LIndiceSostituzione: Integer;
  LTrovataSostituzione: Boolean;
  LRigaFinale: TRigaFinale;
  LRisultato: TList<TRigaFinale>;
begin
  SetLength(LUsate, Length(ASostituzioni));  // tutte False di default

  LRisultato := TList<TRigaFinale>.Create;
  try
    for LRigaOriginale in ARigheOriginali do
    begin
      LTrovataSostituzione := False;
      LIndiceSostituzione := -1;

      for I := 0 to High(ASostituzioni) do
      begin
        LSostituzione := ASostituzioni[I];
        if (LRigaOriginale.IsComponenteMateriaPrima = LSostituzione.VecchioIsMateriaPrima) and
           ((LSostituzione.VecchioIsMateriaPrima and (LRigaOriginale.MateriaPrimaID = LSostituzione.VecchioComponenteID)) or
            ((not LSostituzione.VecchioIsMateriaPrima) and (LRigaOriginale.SemilavoratoID = LSostituzione.VecchioComponenteID))) then
        begin
          if LUsate[I] then
            raise Exception.CreateFmt(
              'CalcolaRigheFinali: il componente (isMateriaPrima=%s, id=%d) e'' gia'' ' +
              'indicato da un''altra voce dell''elenco sostituzioni - ogni componente ' +
              'puo'' essere sostituito una sola volta per adattamento.',
              [BoolToStr(LSostituzione.VecchioIsMateriaPrima, True), LSostituzione.VecchioComponenteID]);

          LTrovataSostituzione := True;
          LIndiceSostituzione := I;
          Break;
        end;
      end;

      if LTrovataSostituzione then
      begin
        LUsate[LIndiceSostituzione] := True;
        LSostituzione := ASostituzioni[LIndiceSostituzione];

        LRigaFinale.IsComponenteMateriaPrima := LSostituzione.NuovoIsMateriaPrima;
        LRigaFinale.ComponenteID := LSostituzione.NuovoComponenteID;

        if LSostituzione.NuovaQuantitaStandard = 0 then
          LRigaFinale.QuantitaStandard := LRigaOriginale.QuantitaStandard
        else
          LRigaFinale.QuantitaStandard := LSostituzione.NuovaQuantitaStandard;

        if LSostituzione.NuovaUnitaMisuraDose = '' then
          LRigaFinale.UnitaMisuraDose := LRigaOriginale.UnitaMisuraDose
        else
          LRigaFinale.UnitaMisuraDose := LSostituzione.NuovaUnitaMisuraDose;
      end
      else
        LRigaFinale := RigaToFinale(LRigaOriginale);

      LRisultato.Add(LRigaFinale);
    end;

    for I := 0 to High(ASostituzioni) do
      if not LUsate[I] then
        raise Exception.CreateFmt(
          'CalcolaRigheFinali: il componente da sostituire (isMateriaPrima=%s, id=%d) ' +
          'non e'' presente nella ricetta corrente.',
          [BoolToStr(ASostituzioni[I].VecchioIsMateriaPrima, True), ASostituzioni[I].VecchioComponenteID]);

    // Righe NUOVE, senza sostituire nulla: accodate DOPO le righe
    // ereditate/sostituite qui sopra, non intrecciate con esse - l'ordine
    // finale non e' significativo per il calcolo (costo e allergeni sono
    // entrambi somme/unioni non ordinate), solo per la leggibilita' di chi
    // ispeziona il risultato grezzo.
    for I := 0 to High(AAggiunte) do
    begin
      LAggiunta := AAggiunte[I];

      // Vedi il commento su TAggiuntaComponente: qui, a differenza di una
      // sostituzione, non c'e' un componente di partenza da cui ereditare
      // quantita'/unita' se il chiamante le lascia vuote - meglio fallire
      // subito con un messaggio chiaro che scrivere una riga a dose zero.
      if Trim(LAggiunta.UnitaMisuraDose) = '' then
        raise Exception.CreateFmt(
          'CalcolaRigheFinali: l''aggiunta del componente (isMateriaPrima=%s, id=%d) non ' +
          'specifica un''unita'' di misura - non c''e'' un componente di partenza da cui ereditarla.',
          [BoolToStr(LAggiunta.IsMateriaPrima, True), LAggiunta.ComponenteID]);
      if LAggiunta.QuantitaStandard <= 0 then
        raise Exception.CreateFmt(
          'CalcolaRigheFinali: l''aggiunta del componente (isMateriaPrima=%s, id=%d) richiede ' +
          'una quantita'' maggiore di zero.',
          [BoolToStr(LAggiunta.IsMateriaPrima, True), LAggiunta.ComponenteID]);

      LRigaFinale.IsComponenteMateriaPrima := LAggiunta.IsMateriaPrima;
      LRigaFinale.ComponenteID := LAggiunta.ComponenteID;
      LRigaFinale.QuantitaStandard := LAggiunta.QuantitaStandard;
      LRigaFinale.UnitaMisuraDose := LAggiunta.UnitaMisuraDose;
      LRisultato.Add(LRigaFinale);
    end;

    // Nessun componente (stesso tipo+id) puo' comparire due volte fra le
    // righe finali: segnale di una richiesta ambigua (due sostituzioni
    // verso lo stesso nuovo componente, un'aggiunta che duplica un
    // componente gia' in ricetta o gia' introdotto da un'altra
    // sostituzione/aggiunta) - meglio fallire subito con un messaggio
    // chiaro che scrivere una riga doppia in silenzio (o, peggio, lasciare
    // che sia il DB a rifiutarla con un errore di vincolo illeggibile per
    // il modello).
    for I := 0 to LRisultato.Count - 1 do
      for J := I + 1 to LRisultato.Count - 1 do
        if (LRisultato[I].IsComponenteMateriaPrima = LRisultato[J].IsComponenteMateriaPrima) and
           (LRisultato[I].ComponenteID = LRisultato[J].ComponenteID) then
          raise Exception.CreateFmt(
            'CalcolaRigheFinali: il componente (isMateriaPrima=%s, id=%d) comparirebbe piu'' ' +
            'di una volta nella ricetta risultante - controlla sostituzioni e aggiunte.',
            [BoolToStr(LRisultato[I].IsComponenteMateriaPrima, True), LRisultato[I].ComponenteID]);

    Result := LRisultato.ToArray;
  finally
    LRisultato.Free;
  end;
end;

// Costo totale delle righe finali: stessa somma quantita*costo_unitario
// di CalcolaCostoRicettaProdottoFinito, ma su un TArray<TRigaFinale>
// invece che su TObjectList<TRicettaProdottoFinitoRiga> - cosi' funziona
// sia sulle righe COSI' COME SONO OGGI sia su quelle gia' sostituite,
// senza bisogno di due implementazioni.
//
// ACostoCompleto (out): False se almeno una riga e' un componente
// semilavorato - il suo costo non e' calcolabile (schema senza resa di
// produzione, vedi il commento in testa a
// TServizioRicette.CalcolaCostoRicettaProdottoFinito) e viene escluso da
// Result invece di stimarlo. Il chiamante (SimulaAdattamentoRicetta/
// ApplicaAdattamentoRicetta) deve propagare questo flag, non ignorarlo:
// un delta di costo calcolato solo sulle materie prime di una ricetta
// che contiene anche semilavorati non e' il vero delta economico.
function CalcolaCostoRighe(const ARigheFinali: TArray<TRigaFinale>;
  out ACostoCompleto: Boolean): Currency;
var
  LRiga: TRigaFinale;
begin
  Result := 0;
  ACostoCompleto := True;
  for LRiga in ARigheFinali do
    if LRiga.IsComponenteMateriaPrima then
      Result := Result + (TServizioRicette.CostoUnitarioMateriaPrima(
        LRiga.ComponenteID, LRiga.UnitaMisuraDose) * LRiga.QuantitaStandard)
    else
      ACostoCompleto := False;
end;

// Unione (deduplicata per id) degli allergeni di tutte le righe finali:
// l'insieme di allergeni "derivato dalla ricetta" che finirebbe in
// etichetta se quella ricetta diventasse quella di un prodotto reale.
// Ogni TAllergene nel risultato e' una COPIA nuova (non un riferimento
// preso in prestito dalle liste temporanee lette per ogni componente,
// che vengono liberate riga per riga) - Result e' quindi proprietario di
// tutto cio' che contiene, un normale TObjectList(True).
function CalcolaAllergeniRighe(const ARigheFinali: TArray<TRigaFinale>): TObjectList<TAllergene>;
var
  LRiga: TRigaFinale;
  LAllergeniRiga: TObjectList<TAllergene>;
  LAllergene, LCopia, LEsistente: TAllergene;
  LGiaPresente: Boolean;
begin
  Result := TObjectList<TAllergene>.Create(True);
  try
    for LRiga in ARigheFinali do
    begin
      LAllergeniRiga := TServizioRicette.GetAllergeniComponente(LRiga.IsComponenteMateriaPrima, LRiga.ComponenteID);
      try
        for LAllergene in LAllergeniRiga do
        begin
          LGiaPresente := False;
          for LEsistente in Result do
            if LEsistente.ID = LAllergene.ID then
            begin
              LGiaPresente := True;
              Break;
            end;

          if not LGiaPresente then
          begin
            LCopia := TAllergene.Create;
            LCopia.ID := LAllergene.ID;
            LCopia.Codice := LAllergene.Codice;
            LCopia.Denominazione := LAllergene.Denominazione;
            Result.Add(LCopia);
          end;
        end;
      finally
        LAllergeniRiga.Free;
      end;
    end;
  except
    Result.Free;
    raise;
  end;
end;

// Elementi di AInsieme il cui id NON compare in ADaEscludere. Lista NON
// proprietaria (Create(False)): contiene RIFERIMENTI ad oggetti posseduti
// da AInsieme, che deve restare vivo per tutta la vita del risultato -
// in TSimulazioneAdattamento e' cosi' per costruzione (AllergeniAttuali/
// AllergeniSimulati vivono quanto AllergeniRimossi/AllergeniAggiunti,
// stesso oggetto contenitore, vedi il distruttore sopra).
function SottraiAllergeni(AInsieme, ADaEscludere: TObjectList<TAllergene>): TObjectList<TAllergene>;
var
  LAllergene, LAltro: TAllergene;
  LTrovato: Boolean;
begin
  Result := TObjectList<TAllergene>.Create(False);
  for LAllergene in AInsieme do
  begin
    LTrovato := False;
    for LAltro in ADaEscludere do
      if LAltro.ID = LAllergene.ID then
      begin
        LTrovato := True;
        Break;
      end;
    if not LTrovato then
      Result.Add(LAllergene);
  end;
end;

// Esegue la query filtrata (testo + allergene da escludere, entrambi
// opzionali) su UNA delle due anagrafiche componente e accumula i
// candidati in ADestinazione. ATabella e' il nome della tabella
// anagrafica, ATabellaPonte quello della tabella ponte *_allergeni
// corrispondente, AColonnaFK la sua colonna FK verso l'anagrafica -
// stessi tre valori concettuali gia' usati da TAllergene.GetPerEntita/
// SetPerEntita per la stessa ragione (evitare di duplicare la query per
// materie prime e semilavorati, che sono strutturalmente identiche).
// Il filtro allergene e' un NOT EXISTS invece di un JOIN+filtro: piu'
// leggibile per "nessuna riga della tabella ponte con questo allergene",
// e non rischia di duplicare righe se in futuro si filtrasse per PIU' di
// un allergene contemporaneamente.
procedure AggiungiCandidatiComponente(ADestinazione: TObjectList<TCandidatoComponente>;
  AIsMateriaPrima: Boolean; const ATabella, ATabellaPonte, AColonnaFK: string;
  AAllergeneEsclusoID: Integer; const ATesto: string);
var
  LCondizioni: TArray<string>;
  LParams: TArray<Variant>;
  LSql: string;
  LAutoQuery: TAutoQuery;
  LCandidato: TCandidatoComponente;
begin
  LCondizioni := [];
  LParams := [];

  if ATesto <> '' then
  begin
    LCondizioni := LCondizioni + ['c.denominazione ILIKE :testo'];
    LParams := LParams + ['%' + ATesto + '%'];
  end;

  if AAllergeneEsclusoID > 0 then
  begin
    LCondizioni := LCondizioni + [Format(
      'NOT EXISTS (SELECT 1 FROM %s pa WHERE pa.%s = c.id AND pa.allergene_id = :allergene_escluso_id)',
      [ATabellaPonte, AColonnaFK])];
    LParams := LParams + [AAllergeneEsclusoID];
  end;

  LSql := Format('SELECT c.id, c.codice, c.denominazione FROM %s c ', [ATabella]);
  if Length(LCondizioni) > 0 then
    LSql := LSql + 'WHERE ' + string.Join(' AND ', LCondizioni) + ' ';
  LSql := LSql + 'ORDER BY c.denominazione';

  LAutoQuery := TDB.GetInstance.getQueryResult(LSql, LParams);
  try
    while not LAutoQuery.Query.Eof do
    begin
      LCandidato := TCandidatoComponente.Create;
      LCandidato.IsMateriaPrima := AIsMateriaPrima;
      LCandidato.ID := LAutoQuery.Query.FieldByName('id').AsInteger;
      LCandidato.Codice := LAutoQuery.Query.FieldByName('codice').AsString;
      LCandidato.Denominazione := LAutoQuery.Query.FieldByName('denominazione').AsString;
      LCandidato.Allergeni := TServizioRicette.GetAllergeniComponente(AIsMateriaPrima, LCandidato.ID);

      // Giacenza aggregata del candidato - vedi il commento su
      // TCandidatoComponente.GiacenzaDisponibile per il perche' e' solo
      // informativa. Stessa classe TServizioGiacenza gia' usata dallo
      // scenario di ritiro/richiamo e dalle interrogazioni vendite: nessun
      // nuovo accesso al DB scritto da zero qui.
      if AIsMateriaPrima then
        LCandidato.GiacenzaDisponibile :=
          TServizioGiacenza.GiacenzaDisponibileMateriaPrima(LCandidato.ID)
      else
        LCandidato.GiacenzaDisponibile :=
          TServizioGiacenza.GiacenzaDisponibileSemilavorato(LCandidato.ID);

      ADestinazione.Add(LCandidato);
      LAutoQuery.Query.Next;
    end;
  finally
    LAutoQuery.Free;
  end;
end;

// Fattore di conversione di AUnita rispetto alla sua unita' "base"
// (grammo per la massa, millilitro per il volume, il pezzo stesso per
// 'pz'): quanti AUnita servono a fare 1 unita' base... in realta' usato
// nell'altro verso in ConvertiQuantita, vedi li'. Tabella aperta a nuove
// unita' se il gestionale ne introducesse altre (es. 'cl'): un solo
// punto da modificare.
function FattoreConversione(const AUnita: string): Currency;
var
  LUnita: string;
begin
  LUnita := LowerCase(Trim(AUnita));
  if (LUnita = 'g') or (LUnita = 'ml') or (LUnita = 'pz') then
    Result := 1
  else if (LUnita = 'kg') or (LUnita = 'l') then
    Result := 1000
  else
    raise Exception.CreateFmt(
      'FattoreConversione: unita'' di misura "%s" non riconosciuta ' +
      '(attese: g, kg, ml, l, pz).', [AUnita]);
end;

// Famiglia fisica di un'unita' di misura: due unita' sono convertibili
// tra loro solo se appartengono alla stessa famiglia - non ha senso
// "convertire" grammi in litri, ed e' un segnale di dato di ricetta/DDT
// incoerente se qualcuno ci prova.
function FamigliaUnita(const AUnita: string): string;
var
  LUnita: string;
begin
  LUnita := LowerCase(Trim(AUnita));
  if (LUnita = 'g') or (LUnita = 'kg') then
    Result := 'massa'
  else if (LUnita = 'ml') or (LUnita = 'l') then
    Result := 'volume'
  else if LUnita = 'pz' then
    Result := 'pezzo'
  else
    raise Exception.CreateFmt(
      'FamigliaUnita: unita'' di misura "%s" non riconosciuta ' +
      '(attese: g, kg, ml, l, pz).', [AUnita]);
end;

// Converte AQuantita, espressa in ADaUnita, nell'equivalente quantita'
// in AAUnita (es. ConvertiQuantita(1, 'g', 'kg') = 0.001). E' la
// funzione che risolve il problema all'origine del bug di costo
// individuato nello scenario 3: una dose di ricetta in grammi e un
// prezzo materia prima al kg non sono direttamente moltiplicabili -
// vanno prima ricondotti alla stessa unita'. Se ADaUnita e AAUnita non
// sono della stessa grandezza fisica (vedi FamigliaUnita) solleva
// un'eccezione invece di produrre silenziosamente un numero senza
// senso.
function ConvertiQuantita(AQuantita: Currency; const ADaUnita, AAUnita: string): Currency;
begin
  if SameText(Trim(ADaUnita), Trim(AAUnita)) then
    Exit(AQuantita); // stessa unita', nessuna conversione necessaria

  if FamigliaUnita(ADaUnita) <> FamigliaUnita(AAUnita) then
    raise Exception.CreateFmt(
      'ConvertiQuantita: impossibile convertire "%s" in "%s" - sono unita'' ' +
      'di misura di grandezze fisiche diverse.', [ADaUnita, AAUnita]);

  Result := (AQuantita * FattoreConversione(ADaUnita)) / FattoreConversione(AAUnita);
end;

{ TServizioRicette }

class function TServizioRicette.CostoUnitarioMateriaPrima(AMateriaPrimaID: Integer;
  const AUnitaMisuraRichiesta: string): Currency;
var
  LAutoQuery: TAutoQuery;
  LPrezzo: Currency;
  LUnitaAcquisto: string;
begin
  LAutoQuery := TDB.GetInstance.getQueryResult(SQL_COSTO_DA_DDT, [AMateriaPrimaID]);
  try
    if not LAutoQuery.Query.IsEmpty then
    begin
      LPrezzo := LAutoQuery.Query.FieldByName('prezzo_unitario').AsCurrency;
      LUnitaAcquisto := LAutoQuery.Query.FieldByName('unita_misura').AsString;
      // LPrezzo e' un costo per 1 LUnitaAcquisto (es. euro/kg): per
      // ottenere il costo per 1 AUnitaMisuraRichiesta (es. euro/g) lo si
      // moltiplica per "quanti LUnitaAcquisto c'e' in 1
      // AUnitaMisuraRichiesta" (es. 1 g = 0.001 kg -> 1.2 euro/kg *
      // 0.001 = 0.0012 euro/g).
      Exit(LPrezzo * ConvertiQuantita(1, AUnitaMisuraRichiesta, LUnitaAcquisto));
    end;
  finally
    LAutoQuery.Free;
  end;

  LAutoQuery := TDB.GetInstance.getQueryResult(SQL_COSTO_DA_ORDINE, [AMateriaPrimaID]);
  try
    if not LAutoQuery.Query.IsEmpty then
    begin
      LPrezzo := LAutoQuery.Query.FieldByName('prezzo_unitario').AsCurrency;
      LUnitaAcquisto := LAutoQuery.Query.FieldByName('unita_misura').AsString;
      Exit(LPrezzo * ConvertiQuantita(1, AUnitaMisuraRichiesta, LUnitaAcquisto));
    end;
  finally
    LAutoQuery.Free;
  end;

  raise Exception.CreateFmt(
    'CostoUnitarioMateriaPrima: nessun dato di costo disponibile (ne'' da DDT ' +
    'di entrata ne'' da ordini fornitore) per la materia prima id=%d.',
    [AMateriaPrimaID]);
end;

class function TServizioRicette.CalcolaCostoRicettaProdottoFinito(
  AProdottoFinitoID: Integer): TCostoRicetta;
var
  LRicetta: TRicettaProdottoFinito;
  LRighe: TObjectList<TRicettaProdottoFinitoRiga>;
  LRiga: TRicettaProdottoFinitoRiga;
  LComponente: TCostoComponenteRicetta;
  LMateriaPrima: TMateriaPrima;
  LSemilavorato: TSemilavorato;
begin
  LRicetta := TRicettaProdottoFinito.GetCorrente(AProdottoFinitoID);
  if LRicetta = nil then
    raise Exception.CreateFmt(
      'CalcolaCostoRicettaProdottoFinito: nessuna ricetta corrente per il ' +
      'prodotto finito id=%d.', [AProdottoFinitoID]);

  try
    Result := TCostoRicetta.Create;
    Result.ProdottoFinitoID := AProdottoFinitoID;
    Result.RicettaID := LRicetta.ID;
    Result.Versione := LRicetta.Versione;

    LRighe := TRicettaProdottoFinitoRiga.GetByRicetta(LRicetta.ID);
    try
      for LRiga in LRighe do
      begin
        LComponente := TCostoComponenteRicetta.Create;
        LComponente.IsComponenteMateriaPrima := LRiga.IsComponenteMateriaPrima;
        LComponente.QuantitaStandard := LRiga.QuantitaStandard;
        LComponente.UnitaMisuraDose := LRiga.UnitaMisuraDose;

        // Denominazione: una lettura in piu' per riga (accettabile, una
        // ricetta ha poche righe), ma necessaria - senza il nome leggibile
        // il chiamante (in particolare il tool MCP get_ricetta_prodotto_
        // finito, che espone questo DTO al modello) vedrebbe solo un id
        // numerico nudo, inutilizzabile per proporre una sostituzione
        // all'utente in linguaggio naturale.
        if LRiga.IsComponenteMateriaPrima then
        begin
          LComponente.ComponenteID := LRiga.MateriaPrimaID;
          LComponente.CostoDisponibile := True;
          LComponente.CostoUnitario := CostoUnitarioMateriaPrima(LRiga.MateriaPrimaID, LRiga.UnitaMisuraDose);

          LMateriaPrima := TMateriaPrima.GetByID(LRiga.MateriaPrimaID);
          try
            if Assigned(LMateriaPrima) then
              LComponente.Denominazione := LMateriaPrima.Denominazione;
          finally
            LMateriaPrima.Free;
          end;
        end
        else
        begin
          // Componente = un semilavorato: costo NON calcolabile (vedi il
          // commento su TCostoComponenteRicetta.CostoDisponibile - manca
          // la resa di produzione nello schema attuale). Si mostra
          // comunque la riga (denominazione, quantita', unita') perche'
          // resta utile sapere COSA c'e' in ricetta anche senza saperne
          // il costo, ma CostoUnitario/CostoTotale restano a 0 e NON
          // entrano nel totale della ricetta.
          LComponente.ComponenteID := LRiga.SemilavoratoID;
          LComponente.CostoDisponibile := False;
          LComponente.CostoUnitario := 0;
          Result.CostoCompleto := False;

          LSemilavorato := TSemilavorato.GetByID(LRiga.SemilavoratoID);
          try
            if Assigned(LSemilavorato) then
              LComponente.Denominazione := LSemilavorato.Denominazione;
          finally
            LSemilavorato.Free;
          end;
        end;

        LComponente.CostoTotale := LComponente.CostoUnitario * LComponente.QuantitaStandard;
        Result.Componenti.Add(LComponente);
        if LComponente.CostoDisponibile then
          Result.CostoTotale := Result.CostoTotale + LComponente.CostoTotale;
      end;
    finally
      LRighe.Free;
    end;
  finally
    LRicetta.Free;
  end;
end;

class function TServizioRicette.CalcolaCostoRicettaSemilavorato(
  ASemilavoratoID: Integer): TCostoRicettaSemilavorato;
var
  LRicetta: TRicettaSemilavorato;
  LRighe: TObjectList<TRicettaSemilavoratoRiga>;
  LRiga: TRicettaSemilavoratoRiga;
  LComponente: TCostoComponenteRicetta;
  LMateriaPrima: TMateriaPrima;
  LSemilavorato: TSemilavorato;
begin
  LRicetta := TRicettaSemilavorato.GetCorrente(ASemilavoratoID);
  if LRicetta = nil then
    raise Exception.CreateFmt(
      'CalcolaCostoRicettaSemilavorato: nessuna ricetta corrente per il ' +
      'semilavorato id=%d.', [ASemilavoratoID]);

  try
    Result := TCostoRicettaSemilavorato.Create;
    Result.SemilavoratoID := ASemilavoratoID;
    Result.RicettaID := LRicetta.ID;
    Result.Versione := LRicetta.Versione;

    LRighe := TRicettaSemilavoratoRiga.GetByRicetta(LRicetta.ID);
    try
      for LRiga in LRighe do
      begin
        LComponente := TCostoComponenteRicetta.Create;
        LComponente.IsComponenteMateriaPrima := LRiga.IsComponenteMateriaPrima;
        LComponente.QuantitaStandard := LRiga.QuantitaStandard;
        LComponente.UnitaMisuraDose := LRiga.UnitaMisuraDose;

        if LRiga.IsComponenteMateriaPrima then
        begin
          LComponente.ComponenteID := LRiga.MateriaPrimaID;
          LComponente.CostoDisponibile := True;
          LComponente.CostoUnitario := CostoUnitarioMateriaPrima(LRiga.MateriaPrimaID, LRiga.UnitaMisuraDose);

          LMateriaPrima := TMateriaPrima.GetByID(LRiga.MateriaPrimaID);
          try
            if Assigned(LMateriaPrima) then
              LComponente.Denominazione := LMateriaPrima.Denominazione;
          finally
            LMateriaPrima.Free;
          end;
        end
        else
        begin
          // Componente = un ALTRO semilavorato (distinta base multi-
          // livello): stesso limite del ramo gemello in
          // CalcolaCostoRicettaProdottoFinito, costo non disponibile
          // senza la resa di produzione del figlio.
          LComponente.ComponenteID := LRiga.SemilavoratoFiglioID;
          LComponente.CostoDisponibile := False;
          LComponente.CostoUnitario := 0;
          Result.CostoCompleto := False;

          LSemilavorato := TSemilavorato.GetByID(LRiga.SemilavoratoFiglioID);
          try
            if Assigned(LSemilavorato) then
              LComponente.Denominazione := LSemilavorato.Denominazione;
          finally
            LSemilavorato.Free;
          end;
        end;

        LComponente.CostoTotale := LComponente.CostoUnitario * LComponente.QuantitaStandard;
        Result.Componenti.Add(LComponente);
        if LComponente.CostoDisponibile then
          Result.CostoTotale := Result.CostoTotale + LComponente.CostoTotale;
      end;
    finally
      LRighe.Free;
    end;
  finally
    LRicetta.Free;
  end;
end;

const
  // UNION ALL fra le ricette correnti (valida_al IS NULL) di prodotti
  // finiti e di semilavorati, con il numero di righe di ciascuna
  // (subquery COUNT, piu' leggera di un JOIN+GROUP BY per un dato che ci
  // serve solo come conteggio). La colonna letterale 'prodotto_finito'/
  // 'semilavorato' e' cio' che permette al chiamante Delphi di
  // distinguere le due meta' del risultato senza dover interrogare due
  // dataset separati.
  SQL_RICETTE_CORRENTI =
    'SELECT ''prodotto_finito'' AS tipo, pf.id AS entita_id, pf.codice, pf.denominazione, ' +
    'r.id AS ricetta_id, r.versione, r.valida_dal, r.creato_da, r.note, ' +
    '(SELECT COUNT(*) FROM ricette_prodotti_finiti_righe WHERE ricetta_id = r.id) AS numero_componenti ' +
    'FROM anagrafiche_prodotti_finiti pf ' +
    'JOIN ricette_prodotti_finiti r ON r.prodotto_finito_id = pf.id AND r.valida_al IS NULL ' +
    'UNION ALL ' +
    'SELECT ''semilavorato'', s.id, s.codice, s.denominazione, ' +
    'r2.id, r2.versione, r2.valida_dal, r2.creato_da, r2.note, ' +
    '(SELECT COUNT(*) FROM ricette_semilavorati_righe WHERE ricetta_id = r2.id) ' +
    'FROM anagrafiche_semilavorati s ' +
    'JOIN ricette_semilavorati r2 ON r2.semilavorato_id = s.id AND r2.valida_al IS NULL ' +
    'ORDER BY denominazione';

class function TServizioRicette.GetRicetteCorrenti: TObjectList<TRicettaCorrenteSintetica>;
var
  LAutoQuery: TAutoQuery;
  LRiga: TRicettaCorrenteSintetica;
begin
  Result := TObjectList<TRicettaCorrenteSintetica>.Create(True);
  try
    LAutoQuery := TDB.GetInstance.getQueryResult(SQL_RICETTE_CORRENTI);
    try
      while not LAutoQuery.Query.Eof do
      begin
        LRiga := TRicettaCorrenteSintetica.Create;
        LRiga.IsProdottoFinito := SameText(LAutoQuery.Query.FieldByName('tipo').AsString, 'prodotto_finito');
        LRiga.EntitaID         := LAutoQuery.Query.FieldByName('entita_id').AsInteger;
        LRiga.Codice           := LAutoQuery.Query.FieldByName('codice').AsString;
        LRiga.Denominazione    := LAutoQuery.Query.FieldByName('denominazione').AsString;
        LRiga.RicettaID        := LAutoQuery.Query.FieldByName('ricetta_id').AsInteger;
        LRiga.Versione         := LAutoQuery.Query.FieldByName('versione').AsInteger;
        LRiga.ValidaDal        := LAutoQuery.Query.FieldByName('valida_dal').AsDateTime;
        LRiga.CreatoDa         := LAutoQuery.Query.FieldByName('creato_da').AsString;
        LRiga.Note             := LAutoQuery.Query.FieldByName('note').AsString;
        LRiga.NumeroComponenti := LAutoQuery.Query.FieldByName('numero_componenti').AsInteger;
        Result.Add(LRiga);
        LAutoQuery.Query.Next;
      end;
    finally
      LAutoQuery.Free;
    end;
  except
    Result.Free;
    raise;
  end;
end;

class function TServizioRicette.GetAllergeniComponente(AIsComponenteMateriaPrima: Boolean;
  AComponenteID: Integer): TObjectList<TAllergene>;
begin
  if AIsComponenteMateriaPrima then
    Result := TMateriaPrima.GetAllergeni(AComponenteID)
  else
    Result := TSemilavorato.GetAllergeni(AComponenteID);
end;

class function TServizioRicette.CercaComponenti(const AEscludiAllergeneCodice: string;
  AIncludiMateriePrime, AIncludiSemilavorati: Boolean;
  const ATesto: string): TObjectList<TCandidatoComponente>;
var
  LAllergeneEscluso: TAllergene;
  LAllergeneEsclusoID: Integer;
begin
  LAllergeneEsclusoID := 0;
  if Trim(AEscludiAllergeneCodice) <> '' then
  begin
    LAllergeneEscluso := TAllergene.GetByCodice(Trim(AEscludiAllergeneCodice));
    if LAllergeneEscluso = nil then
      raise Exception.CreateFmt(
        'CercaComponenti: codice allergene "%s" sconosciuto.', [AEscludiAllergeneCodice]);
    try
      LAllergeneEsclusoID := LAllergeneEscluso.ID;
    finally
      LAllergeneEscluso.Free;
    end;
  end;

  Result := TObjectList<TCandidatoComponente>.Create(True);
  try
    if AIncludiMateriePrime then
      AggiungiCandidatiComponente(Result, True, 'anagrafiche_materie_prime',
        'anagrafiche_materie_prime_allergeni', 'materia_prima_id',
        LAllergeneEsclusoID, Trim(ATesto));

    if AIncludiSemilavorati then
      AggiungiCandidatiComponente(Result, False, 'anagrafiche_semilavorati',
        'anagrafiche_semilavorati_allergeni', 'semilavorato_id',
        LAllergeneEsclusoID, Trim(ATesto));
  except
    Result.Free;
    raise;
  end;
end;

class function TServizioRicette.SimulaAdattamentoRicetta(AProdottoFinitoID: Integer;
  const ASostituzioni: TArray<TSostituzioneComponente>;
  const AAggiunte: TArray<TAggiuntaComponente>): TSimulazioneAdattamento;
var
  LRicetta: TRicettaProdottoFinito;
  LRighe: TObjectList<TRicettaProdottoFinitoRiga>;
  LRigheAttuali, LRigheFinali: TArray<TRigaFinale>;
  LCostoAttualeCompleto, LCostoSimulataCompleto: Boolean;
begin
  if (Length(ASostituzioni) = 0) and (Length(AAggiunte) = 0) then
    raise Exception.Create(
      'SimulaAdattamentoRicetta: nessuna modifica indicata - specifica almeno una sostituzione ' +
      'o un''aggiunta.');

  LRicetta := TRicettaProdottoFinito.GetCorrente(AProdottoFinitoID);
  if LRicetta = nil then
    raise Exception.CreateFmt(
      'SimulaAdattamentoRicetta: nessuna ricetta corrente per il prodotto finito id=%d.',
      [AProdottoFinitoID]);

  try
    LRighe := TRicettaProdottoFinitoRiga.GetByRicetta(LRicetta.ID);
    try
      LRigheAttuali := RigheToFinali(LRighe);
      LRigheFinali := CalcolaRigheFinali(LRighe, ASostituzioni, AAggiunte);
    finally
      LRighe.Free;
    end;
  finally
    LRicetta.Free;
  end;

  Result := TSimulazioneAdattamento.Create;
  try
    Result.ProdottoFinitoID := AProdottoFinitoID;
    Result.CostoRicettaAttuale := CalcolaCostoRighe(LRigheAttuali, LCostoAttualeCompleto);
    Result.CostoRicettaSimulata := CalcolaCostoRighe(LRigheFinali, LCostoSimulataCompleto);
    Result.CostoCompleto := LCostoAttualeCompleto and LCostoSimulataCompleto;
    Result.DeltaCosto := Result.CostoRicettaSimulata - Result.CostoRicettaAttuale;
    Result.AllergeniAttuali := CalcolaAllergeniRighe(LRigheAttuali);
    Result.AllergeniSimulati := CalcolaAllergeniRighe(LRigheFinali);
    Result.AllergeniRimossi := SottraiAllergeni(Result.AllergeniAttuali, Result.AllergeniSimulati);
    Result.AllergeniAggiunti := SottraiAllergeni(Result.AllergeniSimulati, Result.AllergeniAttuali);
  except
    Result.Free;
    raise;
  end;
end;

class function TServizioRicette.ApplicaAdattamentoRicetta(AProdottoFinitoID: Integer;
  const ASostituzioni: TArray<TSostituzioneComponente>;
  const AAggiunte: TArray<TAggiuntaComponente>;
  const ACodiceNuovoProdotto, ADenominazioneNuovoProdotto: string;
  const ACreatoDa, ANote: string): TEsitoAdattamentoRicetta;
var
  LProdottoOrigine: TProdottoFinito;
  LProdottoRadiceID: Integer;
  LRicetta: TRicettaProdottoFinito;
  LRighe: TObjectList<TRicettaProdottoFinitoRiga>;
  LRigheFinali: TArray<TRigaFinale>;
  LAllergeniAttuali, LAllergeniSimulati, LAllergeniDaEscludere: TObjectList<TAllergene>;
  LVarianti: TObjectList<TProdottoFinito>;
  LVariante, LVarianteCompatibile: TProdottoFinito;
  LAllergeniVariante: TObjectList<TAllergene>;
  LCompatibile: Boolean;
  LAllergeneDaEscludere, LAllergeneVariante: TAllergene;
  LNuovoProdotto: TProdottoFinito;
  LNuovaRicetta: TRicettaProdottoFinito;
  LAllergeniSimulatiIDs: TArray<Integer>;
  I: Integer;
  LCostoCompleto: Boolean;
begin
  if (Length(ASostituzioni) = 0) and (Length(AAggiunte) = 0) then
    raise Exception.Create(
      'ApplicaAdattamentoRicetta: nessuna modifica indicata - specifica almeno una sostituzione ' +
      'o un''aggiunta.');

  LProdottoOrigine := TProdottoFinito.GetByID(AProdottoFinitoID);
  if LProdottoOrigine = nil then
    raise Exception.CreateFmt(
      'ApplicaAdattamentoRicetta: prodotto finito id=%d non trovato.', [AProdottoFinitoID]);

  LAllergeniAttuali := nil;
  LAllergeniSimulati := nil;
  LAllergeniDaEscludere := nil;
  LVarianteCompatibile := nil;
  try
    // Una variante si aggancia sempre al prodotto RADICE, mai a un'altra
    // variante (vedi il commento su TProdottoFinito.ProdottoFinitoPadreID):
    // se si sta ulteriormente adattando una variante gia' esistente, la
    // nuova variante risultante resta comunque figlia dello stesso
    // prodotto originale, non "nipote".
    if LProdottoOrigine.ProdottoFinitoPadreID <> 0 then
      LProdottoRadiceID := LProdottoOrigine.ProdottoFinitoPadreID
    else
      LProdottoRadiceID := AProdottoFinitoID;

    // --- Fase 1 (sola lettura): stesso calcolo di SimulaAdattamentoRicetta,
    // ripetuto qui (non richiamato direttamente) perche' oltre ai numeri
    // aggregati servono anche le righe finali GREZZE (LRigheFinali), da
    // scrivere se si decide di creare una nuova variante.
    LRicetta := TRicettaProdottoFinito.GetCorrente(AProdottoFinitoID);
    if LRicetta = nil then
      raise Exception.CreateFmt(
        'ApplicaAdattamentoRicetta: nessuna ricetta corrente per il prodotto finito id=%d.',
        [AProdottoFinitoID]);

    try
      LRighe := TRicettaProdottoFinitoRiga.GetByRicetta(LRicetta.ID);
      try
        LAllergeniAttuali := CalcolaAllergeniRighe(RigheToFinali(LRighe));
        // Valida qui, PRIMA di ogni scrittura: se una sostituzione non
        // trova il suo componente nella ricetta di partenza, o un'aggiunta
        // non specifica quantita'/unita', l'eccezione interrompe tutto
        // senza aver toccato il DB.
        LRigheFinali := CalcolaRigheFinali(LRighe, ASostituzioni, AAggiunte);
      finally
        LRighe.Free;
      end;
    finally
      LRicetta.Free;
    end;

    LAllergeniSimulati := CalcolaAllergeniRighe(LRigheFinali);
    LAllergeniDaEscludere := SottraiAllergeni(LAllergeniAttuali, LAllergeniSimulati);

    // --- Fase 2: esiste gia' una variante compatibile? -------------------
    // "Compatibile" = una variante (figlia dello stesso prodotto radice)
    // la cui etichetta ATTUALE (anagrafiche_prodotti_finiti_allergeni, il
    // dato ufficiale gia' salvato per un prodotto reale) non contiene
    // NESSUNO degli allergeni che questo adattamento sta togliendo. Non
    // serve un confronto di uguaglianza totale degli insiemi: se l'utente
    // ha chiesto "senza lattosio", una variante che gia' non contiene
    // lattosio va bene anche se differisce per altri dettagli di ricetta
    // - evitare quel duplicato e' esattamente lo scopo di questo controllo.
    // Se l'adattamento non toglie nessun allergene (caso raro: sostituzione
    // "di gusto", non dietetica) il controllo non ha nulla da escludere e
    // si procede sempre a creare una nuova variante.
    if LAllergeniDaEscludere.Count > 0 then
    begin
      LVarianti := TProdottoFinito.GetVarianti(LProdottoRadiceID);
      try
        for LVariante in LVarianti do
        begin
          // ATTENZIONE: l'id passato qui e' quello della VARIANTE candidata
          // (LVariante.ID), non LProdottoRadiceID - vogliamo gli allergeni
          // di CIASCUNA variante che stiamo esaminando, non sempre quelli
          // del prodotto radice.
          LAllergeniVariante := LVariante.GetAllergeni(LVariante.ID);
          try
            LCompatibile := True;
            for LAllergeneDaEscludere in LAllergeniDaEscludere do
              for LAllergeneVariante in LAllergeniVariante do
                if LAllergeneVariante.ID = LAllergeneDaEscludere.ID then
                  LCompatibile := False;
          finally
            LAllergeniVariante.Free;
          end;

          if LCompatibile then
          begin
            // Copia indipendente (non il riferimento posseduto da
            // LVarianti, che viene liberato qui sotto): deve sopravvivere
            // oltre la fine di questo blocco try, fino a dopo essere stata
            // travasata in Result.
            LVarianteCompatibile := TProdottoFinito.GetByID(LVariante.ID);
            Break;
          end;
        end;
      finally
        LVarianti.Free;
      end;
    end;

    if Assigned(LVarianteCompatibile) then
    begin
      Result := TEsitoAdattamentoRicetta.Create;
      Result.VarianteGiaEsistente := True;
      Result.ProdottoFinitoID := LVarianteCompatibile.ID;
      Result.Codice := LVarianteCompatibile.Codice;
      Result.Denominazione := LVarianteCompatibile.Denominazione;
      Result.ProdottoFinitoPadreID := LVarianteCompatibile.ProdottoFinitoPadreID;
      Result.RicettaID := 0;
      Result.Versione := 0;
      Result.CostoRicetta := 0;
      Result.CostoRicettaCompleto := True; // 0 qui e' "non ricalcolato", non "parziale" - vedi commento sul campo
      Exit;
    end;

    // --- Fase 3: nessuna variante compatibile, se ne crea una nuova ------
    if (Trim(ACodiceNuovoProdotto) = '') or (Trim(ADenominazioneNuovoProdotto) = '') then
      raise Exception.Create(
        'ApplicaAdattamentoRicetta: nessuna variante compatibile esistente - servono ' +
        'codice_nuovo_prodotto e denominazione_nuovo_prodotto per crearne una nuova.');

    LNuovoProdotto := TProdottoFinito.Create;
    try
      LNuovoProdotto.Codice := Trim(ACodiceNuovoProdotto);
      LNuovoProdotto.Denominazione := Trim(ADenominazioneNuovoProdotto);
      LNuovoProdotto.GiorniScadenzaStandard := LProdottoOrigine.GiorniScadenzaStandard;
      LNuovoProdotto.ProdottoFinitoPadreID := LProdottoRadiceID;
      LNuovoProdotto.Insert;

      // Etichetta del nuovo prodotto impostata SUBITO, non lasciata vuota
      // fino a un aggiornamento manuale successivo: e' il dato che finisce
      // in etichetta ai sensi del Reg. UE 1169/2011, e coincide per
      // costruzione con gli allergeni derivati dalla ricetta appena creata.
      SetLength(LAllergeniSimulatiIDs, LAllergeniSimulati.Count);
      for I := 0 to LAllergeniSimulati.Count - 1 do
        LAllergeniSimulatiIDs[I] := LAllergeniSimulati[I].ID;
      TProdottoFinito.SetAllergeni(LNuovoProdotto.ID, LAllergeniSimulatiIDs);

      // Prima (e unica, per ora) versione di ricetta del nuovo prodotto:
      // GetCorrente(nuovo id) e' certamente nil, quindi CreaNuovaVersione
      // esegue il ramo "semplice Insert" - lo stesso metodo gia' usato per
      // il versionamento in-place, riusato qui senza alcuna modifica.
      LNuovaRicetta := TRicettaProdottoFinito.CreaNuovaVersione(LNuovoProdotto.ID, ACreatoDa, ANote);
      try
        TDB.GetInstance.ExecuteInTransaction(
          procedure(AConn: TFDConnection)
          var
            LRigaFinale: TRigaFinale;
            LNuovaRiga: TRicettaProdottoFinitoRiga;
          begin
            for LRigaFinale in LRigheFinali do
            begin
              LNuovaRiga := TRicettaProdottoFinitoRiga.Create;
              try
                LNuovaRiga.RicettaID := LNuovaRicetta.ID;

                if LRigaFinale.IsComponenteMateriaPrima then
                begin
                  LNuovaRiga.MateriaPrimaID := LRigaFinale.ComponenteID;
                  LNuovaRiga.SemilavoratoID := 0;
                end
                else
                begin
                  LNuovaRiga.MateriaPrimaID := 0;
                  LNuovaRiga.SemilavoratoID := LRigaFinale.ComponenteID;
                end;

                LNuovaRiga.QuantitaStandard := LRigaFinale.QuantitaStandard;
                LNuovaRiga.UnitaMisuraDose := LRigaFinale.UnitaMisuraDose;
                LNuovaRiga.Insert(AConn);
              finally
                LNuovaRiga.Free;
              end;
            end;
          end);

        Result := TEsitoAdattamentoRicetta.Create;
        Result.VarianteGiaEsistente := False;
        Result.ProdottoFinitoID := LNuovoProdotto.ID;
        Result.Codice := LNuovoProdotto.Codice;
        Result.Denominazione := LNuovoProdotto.Denominazione;
        Result.ProdottoFinitoPadreID := LNuovoProdotto.ProdottoFinitoPadreID;
        Result.RicettaID := LNuovaRicetta.ID;
        Result.Versione := LNuovaRicetta.Versione;
        Result.CostoRicetta := CalcolaCostoRighe(LRigheFinali, LCostoCompleto);
        Result.CostoRicettaCompleto := LCostoCompleto;
      finally
        LNuovaRicetta.Free;
      end;
    finally
      LNuovoProdotto.Free;
    end;
  finally
    LVarianteCompatibile.Free;
    LAllergeniDaEscludere.Free;
    LAllergeniSimulati.Free;
    LAllergeniAttuali.Free;
    LProdottoOrigine.Free;
  end;
end;

end.
