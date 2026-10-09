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
  // Costo, componente per componente, della ricetta corrente di un prodotto finito (o di un
  // semilavorato, TCostoRicettaSemilavorato). DTO interno, non persistito ne' JSON.
  // CostoUnitario e' nella stessa unita' di UnitaMisuraDose (se la dose e' in 'g', e' un
  // prezzo al grammo), cosi' CostoTotale = QuantitaStandard * CostoUnitario e' corretto
  // anche se la dose differisce dall'unita' di acquisto (es. acquistata in kg, dosata in g:
  // voluto). La conversione la fa TServizioRicette.CostoUnitarioMateriaPrima
  // (ConvertiQuantita). Vale solo per le materie prime: per i semilavorati vedi
  // CostoDisponibile.
  TCostoComponenteRicetta = class
  public
    IsComponenteMateriaPrima: Boolean;
    ComponenteID: Integer;   // materia_prima_id o semilavorato_id, a seconda del flag sopra
    Denominazione: string;   // nome leggibile del componente - vedi il commento in
                              // Vedi CalcolaCostoRicettaProdottoFinito (perche' e' qui e
                              // non solo l'id).
    QuantitaStandard: Currency;
    UnitaMisuraDose: string;
    CostoUnitario: Currency;
    CostoTotale: Currency;   // QuantitaStandard * CostoUnitario

    // False solo per i semilavorati: ricette_semilavorati non censisce la resa di
    // produzione, quindi dal costo dell'intera esecuzione non si ricava un costo per unita'
    // senza gonfiarlo. Se False, CostoUnitario e CostoTotale sono 0 e non entrano nel
    // CostoTotale del padre (lo segnala CostoCompleto). Sempre True per le materie prime
    // (costo da DDT o da ordine).
    CostoDisponibile: Boolean;
  end;

  TCostoRicetta = class
  public
    ProdottoFinitoID: Integer;
    RicettaID: Integer;
    Versione: Integer;
    Componenti: TObjectList<TCostoComponenteRicetta>;
    CostoTotale: Currency;   // somma dei SOLI componenti con CostoDisponibile = True

    // False se un componente e' un semilavorato (CostoDisponibile): CostoTotale e'
    // parziale. Chi lo mostra (uRicetteToolProvider, uControllerRicette) deve segnalarlo.
    CostoCompleto: Boolean;

    constructor Create;
    destructor Destroy; override;
  end;

  // Gemella di TCostoRicetta per un semilavorato (GET /api/ricette/semilavorati/($id),
  // TControllerRicette). Campo SemilavoratoID invece di un EntitaID con flag di tipo: il
  // chiamante sa gia' quale metodo ha scelto.
  TCostoRicettaSemilavorato = class
  public
    SemilavoratoID: Integer;
    RicettaID: Integer;
    Versione: Integer;
    Componenti: TObjectList<TCostoComponenteRicetta>;
    CostoTotale: Currency;   // somma dei SOLI componenti con CostoDisponibile = True

    // Come TCostoRicetta.CostoCompleto: False se un componente e' a sua volta un
    // semilavorato (distinta multi-livello).
    CostoCompleto: Boolean;

    constructor Create;
    destructor Destroy; override;
  end;

  // Riga della lista "tutte le ricette correnti" (prodotti finiti e semilavorati) per
  // "Ricette e distinte" (GET /api/ricette). Leggera: niente componenti ne' costo, solo
  // NumeroComponenti (COUNT in SQL). Il costo di una materia prima richiede gia' una query
  // su DDT/ordini: lo calcola solo il dettaglio della ricetta aperta.
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

  // Una sostituzione di un adattamento: "togli questo componente, metti quest'altro". Un
  // adattamento reale (es. senza lattosio) ne ha piu' d'una (latte in polvere e burro):
  // Simula/ApplicaAdattamentoRicetta lavorano su un array e tutte le righe cambiate
  // producono una sola nuova versione di ricetta (o un solo nuovo prodotto), mai versioni
  // intermedie.
  TSostituzioneComponente = record
    VecchioIsMateriaPrima: Boolean;
    VecchioComponenteID: Integer;
    NuovoIsMateriaPrima: Boolean;
    NuovoComponenteID: Integer;
    NuovaQuantitaStandard: Currency;  // 0 = mantieni la dose del componente sostituito
    NuovaUnitaMisuraDose: string;     // '' = mantieni l'unita' del componente sostituito
  end;

  // Componente nuovo da aggiungere senza sostituire nulla. Caso reale dello scenario 3:
  // togliendo il burro da un frollino si perde struttura e serve un legante che nella
  // ricetta non c'era; TSostituzioneComponente non basta, richiede un componente di
  // partenza. Qui QuantitaStandard e UnitaMisuraDose sono sempre obbligatorie (niente da
  // ereditare): CalcolaRigheFinali solleva un'eccezione se vuote.
  TAggiuntaComponente = record
    IsMateriaPrima: Boolean;
    ComponenteID: Integer;
    QuantitaStandard: Currency;
    UnitaMisuraDose: string;
  end;

  // Componente proposto da CercaComponenti come sostituto, con i propri allergeni, cosi'
  // non serve una seconda interrogazione.
  TCandidatoComponente = class
  public
    IsMateriaPrima: Boolean;
    ID: Integer;
    Codice: string;
    Denominazione: string;
    Allergeni: TObjectList<TAllergene>;  // posseduto

    // Giacenza aggregata (somma sui lotti, TServizioGiacenza) del candidato alla ricerca.
    // Solo informativa: permette al modello di avvisare "non c'e' disponibilita'", ma
    // giacenza zero non esclude il candidato ne' blocca simula/applica_adattamento_ricetta.
    // Un adattamento crea o riusa una variante (una distinta base), non una produzione, e
    // non consuma magazzino.
    GiacenzaDisponibile: Currency;

    destructor Destroy; override;
  end;

  // Esito di SimulaAdattamentoRicetta (turno 1, sola lettura): quanto cambierebbero il
  // costo e gli allergeni della ricetta risultante. In base a questo il modello decide se
  // procedere con ApplicaAdattamentoRicetta.
  // AllergeniAttuali/AllergeniSimulati sono ricalcolati dalla composizione della ricetta
  // (unione degli allergeni delle righe), non letti dall'etichetta
  // anagrafiche_prodotti_finiti_allergeni: il confronto prima/dopo e' coerente con le righe
  // anche se l'etichetta non fosse allineata.
  TSimulazioneAdattamento = class
  public
    ProdottoFinitoID: Integer;
    CostoRicettaAttuale: Currency;
    CostoRicettaSimulata: Currency;
    DeltaCosto: Currency;             // simulata - attuale: positivo = piu' caro

    // False se la ricetta attuale o quella simulata ha un semilavorato (CostoDisponibile):
    // i costi e DeltaCosto sono sulle sole materie prime e il modello deve presentarli come
    // parziali.
    CostoCompleto: Boolean;

    AllergeniAttuali: TObjectList<TAllergene>;
    AllergeniSimulati: TObjectList<TAllergene>;
    AllergeniRimossi: TObjectList<TAllergene>;   // in Attuali ma non in Simulati (posseduti da AllergeniAttuali)
    AllergeniAggiunti: TObjectList<TAllergene>;  // in Simulati ma non in Attuali (posseduti da AllergeniSimulati)

    destructor Destroy; override;
  end;

  // Esito di ApplicaAdattamentoRicetta (turno 2, scrittura). VarianteGiaEsistente distingue
  // "creata una nuova variante" da "trovata e riusata una compatibile" (criterio nel
  // commento del metodo), cosi' il modello dice "ho creato XYZ" o "esiste gia' XYZ" senza
  // duplicati.
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

  // Servizio dello scenario 3 (adattamento ricette con calcolo economico multi-turno). Il
  // multi-turno lo gestisce il modello (ogni turno e' una chiamata tool), non uno stato
  // interno: qui ci sono le operazioni dei turni, CercaComponenti (sostituti compatibili
  // con un vincolo dietetico), SimulaAdattamentoRicetta (turno 1, nessuna scrittura) e
  // ApplicaAdattamentoRicetta (turno 2, si crea la variante).
  // Un adattamento non modifica mai in place la ricetta di partenza: produce una variante,
  // un prodotto finito a se' (codice, denominazione, etichetta), agganciato all'originale
  // con ProdottoFinitoPadreID, riusando una variante compatibile gia' esistente per non
  // accumulare duplicati. L'originale resta in vendita invariato: "senza glutine" e' una
  // variante commerciale, non una correzione.
  TServizioRicette = class
  private
    // Ultimo costo unitario noto di una materia prima: il prezzo realmente pagato (ultima
    // riga DDT di entrata per data di ricezione) ha la precedenza su quello negoziato in
    // ordine (TOrdineFornitoreRiga.PrezzoUnitario); se non e' mai stata consegnata,
    // l'ultimo prezzo d'ordine. Senza alcun dato solleva un'eccezione: meglio fallire che
    // restituire 0 in un calcolo economico.
    // AUnitaMisuraRichiesta e' l'unita' di dose della riga (es. 'g'); il prezzo e'
    // nell'unita' di acquisto (tipicamente 'kg' o 'l'), da convertire con ConvertiQuantita.
    // Se non sono della stessa grandezza fisica (kg vs l) solleva un'eccezione: dato di
    // ricetta incoerente.
    class function CostoUnitarioMateriaPrima(AMateriaPrimaID: Integer;
      const AUnitaMisuraRichiesta: string): Currency;
  public
    // Costo completo, per componente, della ricetta corrente di un prodotto finito.
    class function CalcolaCostoRicettaProdottoFinito(
      AProdottoFinitoID: Integer): TCostoRicetta;

    // Gemella di CalcolaCostoRicettaProdottoFinito per un semilavorato. Un componente
    // semilavorato compare con CostoDisponibile = False (vedi TCostoComponenteRicetta:
    // senza la resa di produzione il costo per unita' si gonfierebbe).
    class function CalcolaCostoRicettaSemilavorato(
      ASemilavoratoID: Integer): TCostoRicettaSemilavorato;

    // Tutte le ricette correnti (prodotti finiti e semilavorati) per "Ricette e distinte".
    // Una sola query (UNION ALL), ordinata dal database.
    class function GetRicetteCorrenti: TObjectList<TRicettaCorrenteSintetica>;

    // Allergeni dichiarati di un componente (il flag sceglie l'anagrafica): centralizza la
    // scelta di quale GetAllergeni chiamare.
    class function GetAllergeniComponente(AIsComponenteMateriaPrima: Boolean;
      AComponenteID: Integer): TObjectList<TAllergene>;

    // Cerca materie prime e/o semilavorati candidati a sostituire un componente, filtrando
    // per allergene da escludere (codice, es. "LAT") e testo sulla denominazione, entrambi
    // opzionali. Un solo metodo per qualunque combinazione di filtri (tool generico e
    // parametrico). AAllergeneEscluso vuoto non filtra; un codice sconosciuto solleva
    // un'eccezione (errore di chi chiama, meglio che zero risultati in silenzio).
    class function CercaComponenti(const AEscludiAllergeneCodice: string;
      AIncludiMateriePrime, AIncludiSemilavorati: Boolean;
      const ATesto: string): TObjectList<TCandidatoComponente>;

    // Turno 1: simula un adattamento (sostituzioni e/o aggiunte) della ricetta corrente,
    // senza scrivere. Restituisce delta di costo e variazione degli allergeni da mostrare
    // al cliente. ASostituzioni e AAggiunte si usano insieme o da sole, ma non entrambe
    // vuote (vedi CalcolaRigheFinali).
    class function SimulaAdattamentoRicetta(AProdottoFinitoID: Integer;
      const ASostituzioni: TArray<TSostituzioneComponente>;
      const AAggiunte: TArray<TAggiuntaComponente>): TSimulazioneAdattamento;

    // Turno 2: applica l'adattamento. Non tocca mai la ricetta di partenza: cerca prima una
    // variante esistente (TProdottoFinito.GetVarianti del radice) la cui etichetta non
    // contiene nessuno degli allergeni che l'adattamento toglie; se c'e', non scrive e la
    // segnala (VarianteGiaEsistente = True). Altrimenti ne crea una
    // (ACodiceNuovoProdotto/ADenominazioneNuovoProdotto obbligatori) con la prima ricetta:
    // righe della ricetta di partenza con sostituzioni applicate e aggiunte accodate (i
    // componenti non toccati restano invariati: un adattamento non e' una ricetta da zero),
    // in una scrittura atomica (TDB.ExecuteInTransaction): tutte le righe corrette o
    // nessuna.
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
  // Prezzo reale pagato: ultima riga DDT di entrata, per data di ricezione. unita_misura e'
  // l'unita' del prezzo: va letta sempre con il prezzo, mai assunta uguale a quella di dose
  // (ConvertiQuantita).
  SQL_COSTO_DA_DDT =
    'SELECT r.prezzo_unitario, r.unita_misura ' +
    'FROM ddt_entrata_righe r ' +
    'JOIN ddt_entrata d ON d.id = r.ddt_entrata_id ' +
    'WHERE r.materia_prima_id = :materia_prima_id ' +
    'ORDER BY d.data_ricezione DESC ' +
    'LIMIT 1';

  // Fallback: prezzo negoziato nell'ultimo ordine fornitore, se mai consegnata.
  SQL_COSTO_DA_ORDINE =
    'SELECT r.prezzo_unitario, r.unita_misura ' +
    'FROM ordini_fornitori_righe r ' +
    'JOIN ordini_fornitori o ON o.id = r.ordine_fornitore_id ' +
    'WHERE r.materia_prima_id = :materia_prima_id ' +
    'ORDER BY o.data_ordine DESC ' +
    'LIMIT 1';

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

destructor TCandidatoComponente.Destroy;
begin
  Allergeni.Free;
  inherited;
end;

destructor TSimulazioneAdattamento.Destroy;
begin
  // AllergeniRimossi/AllergeniAggiunti non possiedono gli elementi (SottraiAllergeni): sono
  // riferimenti agli oggetti di AllergeniAttuali/AllergeniSimulati, che li liberano.
  AllergeniRimossi.Free;
  AllergeniAggiunti.Free;
  AllergeniSimulati.Free;
  AllergeniAttuali.Free;
  inherited;
end;

// Riga di ricetta risolta: lo stesso componente (IsComponenteMateriaPrima + ComponenteID)
// di TCostoComponenteRicetta/TRicettaProdottoFinitoRiga, senza dipendere dal model (da
// liberare presto) ne' dal DTO di costo. E' la rappresentazione comune per costo e
// allergeni, prima e dopo una sostituzione.
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

// Applica tutte le sostituzioni alle righe della ricetta corrente, accoda le aggiunte e
// restituisce le righe finali (da scrivere o da cui ricalcolare costo e allergeni). I
// componenti non toccati passano invariati: un adattamento e' "la ricetta di partenza, con
// questi cambiamenti", e il chiamante rielenca solo cio' che cambia o si aggiunge.
// Solleva un'eccezione prima di ogni scrittura se una sostituzione non trova la sua riga,
// se due sostituzioni puntano allo stesso componente vecchio, o se un componente (tipo+id)
// comparirebbe due volte fra le righe finali (due sostituzioni verso lo stesso nuovo
// componente, o un'aggiunta che duplica qualcosa gia' in ricetta).
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

    // Righe nuove accodate dopo quelle ereditate/sostituite: l'ordine non conta per il
    // calcolo (somme e unioni), solo per chi legge il risultato grezzo.
    for I := 0 to High(AAggiunte) do
    begin
      LAggiunta := AAggiunte[I];

      // Come TAggiuntaComponente: qui non c'e' un componente da cui ereditare quantita' e
      // unita'; meglio fallire con un messaggio chiaro che scrivere una riga a dose zero.
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

    // Nessun componente (tipo+id) due volte fra le righe finali: segnale di richiesta
    // ambigua. Meglio un messaggio chiaro che una riga doppia in silenzio o un errore di
    // vincolo del DB illeggibile per il modello.
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

// Costo totale delle righe finali: stessa somma di CalcolaCostoRicettaProdottoFinito ma su
// TArray<TRigaFinale>, per righe sia attuali sia gia' sostituite.
// ACostoCompleto (out): False se una riga e' un semilavorato, il cui costo non e'
// calcolabile (vedi TCostoComponenteRicetta.CostoDisponibile) ed e' escluso da Result. Il
// chiamante deve propagare il flag: un delta sulle sole materie prime non e' il vero delta
// economico.
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

// Unione (senza doppioni per id) degli allergeni delle righe finali: quelli che finirebbero
// in etichetta. Ogni TAllergene e' una copia nuova (le liste temporanee per componente
// vengono liberate), quindi Result possiede tutto (TObjectList(True)).
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

// Elementi di AInsieme il cui id non e' in ADaEscludere. Lista non proprietaria
// (Create(False)): riferimenti a oggetti di AInsieme, che deve vivere quanto il risultato
// (in TSimulazioneAdattamento, come AllergeniAttuali/AllergeniSimulati).
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

// Query filtrata (testo + allergene da escludere, opzionali) su una delle due anagrafiche
// componente, accumulando i candidati in ADestinazione. ATabella, ATabellaPonte e
// AColonnaFK come in TAllergene.GetPerEntita/SetPerEntita, per non duplicare la query fra
// materie prime e semilavorati. Il filtro allergene e' un NOT EXISTS e non JOIN+filtro:
// piu' leggibile e senza righe duplicate se in futuro si filtrasse per piu' allergeni.
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

      // Giacenza aggregata del candidato, solo informativa
      // (TCandidatoComponente.GiacenzaDisponibile). Riusa TServizioGiacenza.
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

// Fattore di conversione di AUnita rispetto all'unita' base (grammo per la massa,
// millilitro per il volume, il pezzo per 'pz'), usato in ConvertiQuantita. Tabella aperta a
// nuove unita' (es. 'cl'): un solo punto da modificare.
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

// Famiglia fisica di un'unita': convertibili solo unita' della stessa famiglia. Convertire
// grammi in litri indica un dato di ricetta o DDT incoerente.
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

// Converte AQuantita da ADaUnita ad AAUnita (ConvertiQuantita(1, 'g', 'kg') = 0.001).
// Risolve il bug di costo dello scenario 3: una dose in grammi e un prezzo al kg non si
// moltiplicano direttamente. Solleva un'eccezione se le unita' non sono della stessa
// grandezza (FamigliaUnita).
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
      // LPrezzo e' per 1 LUnitaAcquisto (euro/kg): per avere il costo per 1
      // AUnitaMisuraRichiesta (euro/g) si moltiplica per quanti LUnitaAcquisto stanno in 1
      // AUnitaMisuraRichiesta (1 g = 0.001 kg: 1.2 euro/kg * 0.001 = 0.0012 euro/g).
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

        // Denominazione: una lettura in piu' per riga (le righe sono poche), ma senza il
        // nome leggibile il modello (get_ricetta_prodotto_finito) vedrebbe solo un id.
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
          // Componente semilavorato: costo non calcolabile (manca la resa di produzione,
          // vedi CostoDisponibile). La riga si mostra comunque (denominazione, quantita',
          // unita'), ma CostoUnitario/CostoTotale restano 0 e fuori dal totale.
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
          // Semilavorato in un semilavorato (distinta multi-livello): costo non disponibile
          // come sopra.
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
  // UNION ALL fra le ricette correnti (valida_al IS NULL) di prodotti finiti e
  // semilavorati, con il numero di righe (subquery COUNT, piu' leggera di JOIN+GROUP BY per
  // un solo conteggio). La colonna letterale 'prodotto_finito'/'semilavorato' distingue le
  // due meta' del risultato.
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
    // Una variante si aggancia sempre al prodotto radice, mai a un'altra variante
    // (ProdottoFinitoPadreID): adattando una variante, la nuova resta figlia
    // dell'originale, non "nipote".
    if LProdottoOrigine.ProdottoFinitoPadreID <> 0 then
      LProdottoRadiceID := LProdottoOrigine.ProdottoFinitoPadreID
    else
      LProdottoRadiceID := AProdottoFinitoID;

    // Fase 1 (sola lettura): stesso calcolo di SimulaAdattamentoRicetta, ripetuto perche'
    // servono anche le righe finali grezze (LRigheFinali) da scrivere per una nuova
    // variante.
    LRicetta := TRicettaProdottoFinito.GetCorrente(AProdottoFinitoID);
    if LRicetta = nil then
      raise Exception.CreateFmt(
        'ApplicaAdattamentoRicetta: nessuna ricetta corrente per il prodotto finito id=%d.',
        [AProdottoFinitoID]);

    try
      LRighe := TRicettaProdottoFinitoRiga.GetByRicetta(LRicetta.ID);
      try
        LAllergeniAttuali := CalcolaAllergeniRighe(RigheToFinali(LRighe));
        // Si valida prima di ogni scrittura: se una sostituzione non trova il suo
        // componente o un'aggiunta non ha quantita'/unita', l'eccezione interrompe tutto
        // senza toccare il DB.
        LRigheFinali := CalcolaRigheFinali(LRighe, ASostituzioni, AAggiunte);
      finally
        LRighe.Free;
      end;
    finally
      LRicetta.Free;
    end;

    LAllergeniSimulati := CalcolaAllergeniRighe(LRigheFinali);
    LAllergeniDaEscludere := SottraiAllergeni(LAllergeniAttuali, LAllergeniSimulati);

    // Fase 2: esiste gia' una variante compatibile? E' compatibile una variante (figlia
    // dello stesso radice) la cui etichetta attuale (anagrafiche_prodotti_finiti_allergeni)
    // non contiene nessuno degli allergeni che l'adattamento toglie. Basta questo e non
    // l'uguaglianza degli insiemi: per "senza lattosio" va bene una variante gia' senza
    // lattosio anche se differisce per altro, ed evitare quel duplicato e' lo scopo. Se non
    // toglie allergeni (adattamento di gusto) non c'e' nulla da escludere e si crea sempre
    // una variante nuova.
    if LAllergeniDaEscludere.Count > 0 then
    begin
      LVarianti := TProdottoFinito.GetVarianti(LProdottoRadiceID);
      try
        for LVariante in LVarianti do
        begin
          // Qui serve l'id della variante candidata (LVariante.ID), non LProdottoRadiceID:
          // si vogliono gli allergeni di ciascuna variante esaminata.
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
            // Copia indipendente: il riferimento in LVarianti viene liberato qui sotto e
            // deve sopravvivere fino al travaso in Result.
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

    // Fase 3: nessuna variante compatibile, se ne crea una.
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

      // Etichetta del nuovo prodotto impostata subito, non lasciata vuota (finisce in
      // etichetta, Reg. UE 1169/2011): coincide per costruzione con gli allergeni derivati
      // dalla ricetta appena creata.
      SetLength(LAllergeniSimulatiIDs, LAllergeniSimulati.Count);
      for I := 0 to LAllergeniSimulati.Count - 1 do
        LAllergeniSimulatiIDs[I] := LAllergeniSimulati[I].ID;
      TProdottoFinito.SetAllergeni(LNuovoProdotto.ID, LAllergeniSimulatiIDs);

      // Prima versione di ricetta del nuovo prodotto: GetCorrente(nuovo id) e' nil, quindi
      // CreaNuovaVersione esegue il semplice Insert.
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
