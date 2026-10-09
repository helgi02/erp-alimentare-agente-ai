unit uRicetteToolProvider;

(* ============================================================================
  TRicetteToolProvider — tool MCP per lo scenario 3 del tirocinio
  (adattamento ricette su richiesta cliente con calcolo economico
  multi-turno). Quattro tool, un solo file/classe, registrata come
  provider "dinamico" (RegisterDynamicProvider, non RegisterToolProvider)
  per lo stesso motivo di TFilesToolsProvider/TNavigazioneToolProvider: i
  parametri "sostituzioni" e "aggiunte" di simula_adattamento_ricetta/
  applica_adattamento_ricetta sono ARRAY veri di oggetti, non esprimibili
  con gli attributi [MCPTool]/[MCPParam] via RTTI (vedi il commento in
  testa a uFilesToolsProvider.pas sul perche'). get_ricetta_prodotto_finito
  e cerca_componenti_ricetta avrebbero potuto restare RTTI (parametri
  tutti scalari), ma stanno comunque qui: un solo provider per scenario,
  con un solo punto di registrazione in uFrmMain, invece di spezzare uno
  scenario su piu' classi per un motivo puramente tecnico che al modello
  non deve interessare.

  ── I quattro tool, in ordine d'uso tipico ───────────────────────────────────
  1. get_ricetta_prodotto_finito (sola lettura): mostra i componenti della
     ricetta CORRENTE di un prodotto finito (tipo, id, denominazione,
     quantita', unita', costo) E, per ciascuno, gli allergeni che porta
     (codice + denominazione, stessa forma usata dai candidati del tool
     successivo). E' il punto di partenza indispensabile: senza sapere
     cosa c'e' davvero in ricetta oggi - e QUALE componente porta
     l'allergene da togliere - ne' il modello ne' l'utente potrebbero
     scegliere in modo sensato quale componente sostituire nei tool
     successivi. Prima di questa aggiunta il modello doveva INDOVINARE
     quale componente contenesse l'allergene (per nome: "crema" suona
     lattiero, "impasto" no) e scoprirlo solo a posteriori dal risultato
     di simula_adattamento_ricetta - osservato in pratica con Qwen 9B
     locale: 8 iterazioni consumate a tentativi su nomi plausibili prima
     di arrivare a una simulazione utile. Il codice allergene di ciascun
     componente e' esattamente il valore da passare come
     escludi_allergene_codice al tool successivo. Il risultato porta anche
     un campo "apertura_vista" ({"vista":"ricetta_prodotto_finito",
     "parametri":{"prodotto_finito_id":...}}) che il FRONTEND apre da solo
     (components/chat.js, aggiungiAperturaVista), senza che il modello
     debba chiamare apri_vista di sua iniziativa: un LLM locale piccolo che
     deve incatenare una seconda tool_use subito dopo la prima, nello
     stesso turno, si e' rivelato inaffidabile in pratica (anche con
     un'istruzione esplicita "SEMPRE" in description) - per un'azione che
     deve avvenire OGNI volta (mostrare la ricetta di PARTENZA mentre
     l'utente sceglie le sostituzioni nel form dedicato) e' piu' robusto
     incorporarla nel risultato di questo tool, che viene comunque chiamato
     per primo sempre, invece di dipendere da una seconda iniziativa del
     modello.
  2. cerca_componenti_ricetta: dato un vincolo dietetico (es. "escludi
     l'allergene LAT" - il codice va preso dall'array "allergeni" del
     componente da sostituire, restituito da get_ricetta_prodotto_finito),
     restituisce le materie prime/semilavorati che lo rispettano - i
     candidati fra cui scegliere il sostituto. UNA SOLA chiamata, SENZA
     tipo_componente ne' testo, copre gia' TUTTI i componenti della
     ricetta che portano quell'allergene: il vincolo e' l'allergene, non
     il componente da sostituire, quindi lo stesso elenco di candidati
     serve per scegliere il sostituto di ognuno (anche se in ricetta sono
     piu' di uno - es. sia il burro sia la panna se il vincolo e' "senza
     lattosio"). Anche questo e' un correttivo osservato in pratica: senza
     questa precisazione esplicita nella description, il modello richiama
     il tool una volta per componente (o con filtri via via diversi),
     moltiplicando le chiamate per un dato che una singola interrogazione
     restituisce gia' per intero.
  3. simula_adattamento_ricetta (Turno 1, sola lettura): dato un prodotto
     finito, uno o piu' "sostituisci X con Y" e/o "aggiungi Z" insieme,
     calcola il delta di costo e come cambierebbe l'elenco di allergeni,
     SENZA scrivere nulla. "sostituzioni" copre il caso "togli questo,
     mettine un altro" (un componente della ricetta scompare, un altro lo
     rimpiazza); "aggiunte" copre il caso "in piu', metti anche questo"
     (nessun componente scompare - es. uno stabilizzante reso necessario
     da un'altra sostituzione, che nella ricetta originale non c'era
     affatto). Sono array indipendenti, entrambi opzionali ma non
     entrambi vuoti insieme: si possono usare singolarmente o combinati
     nella stessa chiamata. I componenti della ricetta NON menzionati in
     nessuno dei due restano automaticamente invariati nel risultato - il
     modello non deve mai rielencare l'intera ricetta, solo cio' che
     cambia. Il modello mostra questo risultato all'utente e chiede
     conferma prima di procedere.
  4. applica_adattamento_ricetta (Turno 2, scrittura, SOLO dopo conferma
     esplicita dell'utente): riesegue lo stesso calcolo e lo scrive
     davvero - ma mai sul prodotto di partenza. Cerca prima una variante
     dietetica gia' esistente (stesso prodotto radice, etichetta gia'
     priva degli allergeni tolti); se non la trova, crea un nuovo prodotto
     finito con la sua prima versione di ricetta. Tutta la logica di
     dominio (dove si aggancia una variante, quando riusarne una invece
     di duplicarla) vive in TServizioRicette.ApplicaAdattamentoRicetta:
     qui c'e' solo l'adattatore JSON <-> Servizio (vedi uMCPToolProvider.pas).

  ── Risoluzione del prodotto: id o nome, stesso schema di get_list_vendite ──
  Ciascuno dei tool 2 e 3 accetta prodotto_finito_id (se gia' noto, es. da
  una chiamata precedente) OPPURE nome_prodotto (testo, anche parziale).
  Se il nome e' ambiguo o non trovato, il tool_result e' un esito
  "richiede_disambiguazione" con "campo": "nome_prodotto" e i candidati -
  stessa forma gia' usata da get_list_vendite (uVenditeToolProvider.pas) e
  gia' capita dal frontend (chat.js, aggiungiScelteDisambiguazione): un
  campo diverso da "ragione_sociale_cliente" prende automaticamente il
  ramo "prodotto" del rendering, quindi non serve nessuna modifica lato
  chat.js per far comparire i bottoni di scelta anche per questo scenario.
  ============================================================================ *)

interface

uses
  System.SysUtils,
  System.Generics.Collections,
  JsonDataObjects,
  MVCFramework.MCP.ToolProvider,
  uContrattiTool,
  uModelAllergene,
  uServiziRicette,
  uServiziVendite;

type
  TRicetteToolProvider = class(TMCPToolProvider)
  public
    function GetDynamicToolDefs: TArray<TMCPDynamicToolDef>; override;
    function InvokeDynamic(const AToolName: string;
      AArguments: TJDOJsonObject): TMCPToolResult; override;
    // Contratti dei tool di questo provider per il pianificatore: schema del
    // risultato, lettura/scrittura, conferma, vincoli sugli input (vedi
    // agente_ai/tool/uContrattiTool.pas e la sezione in fondo a questa unit).
    class function ContrattiTool: TArray<TContrattoTool>;
  end;

implementation

{ Funzioni di supporto, private all'unit }

// 'materia_prima' -> True, 'semilavorato' -> False, qualunque altro
// valore (incluso vuoto) e' un errore di chi ha costruito la chiamata:
// a differenza di altri parametri opzionali di questo progetto, qui non
// esiste un default sensato - un componente DEVE essere l'uno o l'altro.
function TipoAIsMateriaPrima(const ATipo, ANomeCampo: string): Boolean;
begin
  if SameText(ATipo, 'materia_prima') then
    Exit(True);
  if SameText(ATipo, 'semilavorato') then
    Exit(False);

  raise Exception.CreateFmt(
    '%s "%s" non valido: deve essere "materia_prima" o "semilavorato".',
    [ANomeCampo, ATipo]);
end;

// Legge e valida il parametro "sostituzioni", OPZIONALE: un array di
// oggetti {vecchio_tipo, vecchio_id, nuovo_tipo, nuovo_id, nuova_quantita
// (opzionale), nuova_unita_misura (opzionale)}. Assente del tutto -> Result
// vuoto, NON un errore: un adattamento puo' essere fatto di sole aggiunte
// (vedi LeggiAggiunte), senza sostituire nulla di esistente - e' il
// chiamante (PreparaChiamataProdotto) a verificare che almeno UNA fra
// sostituzioni e aggiunte sia presente. Le eccezioni sollevate qui sono di
// formato (imputabili al modello): InvokeDynamic le trasforma in
// TMCPToolResult.Error, non le lascia propagare come errore di trasporto -
// stesso principio di LeggiDefinizioniColonne/LeggiRighe in
// uFilesToolsProvider.pas.
function LeggiSostituzioni(AArguments: TJDOJsonObject): TArray<TSostituzioneComponente>;
var
  LArray: TJDOJsonArray;
  LElemento: TJDOJsonObject;
  I: Integer;
  LSostituzioni: TArray<TSostituzioneComponente>;
  LSostituzione: TSostituzioneComponente;
begin
  if not AArguments.Contains('sostituzioni') then
    Exit(nil);

  if AArguments.Types['sostituzioni'] <> jdtArray then
    raise Exception.Create(
      'Parametro "sostituzioni", se presente, deve essere un array di oggetti ' +
      '{"vecchio_tipo", "vecchio_id", "nuovo_tipo", "nuovo_id"} (uno per ogni componente da sostituire).');

  LArray := AArguments.A['sostituzioni'];
  SetLength(LSostituzioni, LArray.Count);
  for I := 0 to LArray.Count - 1 do
  begin
    if LArray.Types[I] <> jdtObject then
      raise Exception.CreateFmt(
        'Elemento %d di "sostituzioni" non e'' un oggetto: atteso {"vecchio_tipo", ' +
        '"vecchio_id", "nuovo_tipo", "nuovo_id"}.', [I]);

    LElemento := LArray.O[I];

    if not (LElemento.Contains('vecchio_id') and LElemento.Contains('nuovo_id')) then
      raise Exception.CreateFmt(
        'Elemento %d di "sostituzioni": servono sia "vecchio_id" sia "nuovo_id".', [I]);

    LSostituzione.VecchioIsMateriaPrima := TipoAIsMateriaPrima(LElemento.S['vecchio_tipo'],
      Format('Elemento %d di "sostituzioni": "vecchio_tipo"', [I]));
    LSostituzione.VecchioComponenteID := LElemento.I['vecchio_id'];

    LSostituzione.NuovoIsMateriaPrima := TipoAIsMateriaPrima(LElemento.S['nuovo_tipo'],
      Format('Elemento %d di "sostituzioni": "nuovo_tipo"', [I]));
    LSostituzione.NuovoComponenteID := LElemento.I['nuovo_id'];

    // CONTROLLO DI DIFESA (tappa 13): un id e' sempre un intero positivo.
    // Zero o negativo significa che il modello non aveva l'id vero.
    if (LSostituzione.VecchioComponenteID <= 0) or (LSostituzione.NuovoComponenteID <= 0) then
      raise Exception.CreateFmt(
        'Elemento %d di "sostituzioni": "vecchio_id" e "nuovo_id" devono essere interi maggiori ' +
        'di zero, presi dalla ricetta e da cerca_componenti_ricetta.', [I]);

    // Sentinelle "mantieni quella del componente sostituito", stesso
    // principio gia' seguito da TServizioRicette.ApplicaAdattamentoRicetta
    // (e prima ancora dal vecchio ApplicaSostituzioneIngrediente a un
    // solo componente): 0/'' quando il chiamante non specifica un valore.
    if LElemento.Contains('nuova_quantita') then
    begin
      LSostituzione.NuovaQuantitaStandard := LElemento.F['nuova_quantita'];
      // CONTROLLO DI DIFESA (tappa 13): una dose negativa non ha senso e
      // falserebbe il calcolo economico. Zero resta ammesso: e' la
      // sentinella "mantieni la quantita' del componente sostituito".
      if LSostituzione.NuovaQuantitaStandard < 0 then
        raise Exception.CreateFmt(
          'Elemento %d di "sostituzioni": "nuova_quantita" non puo'' essere negativa ' +
          '(ometti il campo per mantenere la quantita'' attuale).', [I]);
    end
    else
      LSostituzione.NuovaQuantitaStandard := 0;

    if LElemento.Contains('nuova_unita_misura') then
      LSostituzione.NuovaUnitaMisuraDose := LElemento.S['nuova_unita_misura']
    else
      LSostituzione.NuovaUnitaMisuraDose := '';

    LSostituzioni[I] := LSostituzione;
  end;

  Result := LSostituzioni;
end;

// Legge e valida il parametro "aggiunte", OPZIONALE: un array di oggetti
// {tipo, id, quantita, unita_misura} - componenti NUOVI da aggiungere alla
// ricetta risultante, SENZA sostituire nulla di esistente (es. uno
// stabilizzante reso necessario da un'altra sostituzione). A differenza di
// "sostituzioni", qui "quantita" e "unita_misura" sono SEMPRE obbligatorie
// per ogni elemento: non c'e' un componente di partenza da cui ereditarle
// se il chiamante le omette (vedi TAggiuntaComponente in
// uServiziRicette.pas). Assente del tutto -> Result vuoto, non un errore -
// stesso principio di LeggiSostituzioni qui sopra.
function LeggiAggiunte(AArguments: TJDOJsonObject): TArray<TAggiuntaComponente>;
var
  LArray: TJDOJsonArray;
  LElemento: TJDOJsonObject;
  I: Integer;
  LAggiunte: TArray<TAggiuntaComponente>;
  LAggiunta: TAggiuntaComponente;
begin
  if not AArguments.Contains('aggiunte') then
    Exit(nil);

  if AArguments.Types['aggiunte'] <> jdtArray then
    raise Exception.Create(
      'Parametro "aggiunte", se presente, deve essere un array di oggetti ' +
      '{"tipo", "id", "quantita", "unita_misura"} (uno per ogni componente nuovo da aggiungere).');

  LArray := AArguments.A['aggiunte'];
  SetLength(LAggiunte, LArray.Count);
  for I := 0 to LArray.Count - 1 do
  begin
    if LArray.Types[I] <> jdtObject then
      raise Exception.CreateFmt(
        'Elemento %d di "aggiunte" non e'' un oggetto: atteso {"tipo", "id", "quantita", ' +
        '"unita_misura"}.', [I]);

    LElemento := LArray.O[I];

    if not (LElemento.Contains('id') and LElemento.Contains('quantita') and
            LElemento.Contains('unita_misura')) then
      raise Exception.CreateFmt(
        'Elemento %d di "aggiunte": servono "tipo", "id", "quantita" e "unita_misura" (tutti ' +
        'obbligatori - non c''e'' un componente di partenza da cui ereditarli).', [I]);

    LAggiunta.IsMateriaPrima := TipoAIsMateriaPrima(LElemento.S['tipo'],
      Format('Elemento %d di "aggiunte": "tipo"', [I]));
    LAggiunta.ComponenteID := LElemento.I['id'];
    // CONTROLLO DI DIFESA (tappa 13): stesso principio delle sostituzioni.
    if LAggiunta.ComponenteID <= 0 then
      raise Exception.CreateFmt(
        'Elemento %d di "aggiunte": "id" deve essere un intero maggiore di zero.', [I]);
    LAggiunta.QuantitaStandard := LElemento.F['quantita'];
    LAggiunta.UnitaMisuraDose := LElemento.S['unita_misura'];

    if LAggiunta.QuantitaStandard <= 0 then
      raise Exception.CreateFmt(
        'Elemento %d di "aggiunte": "quantita" deve essere maggiore di zero.', [I]);
    if Trim(LAggiunta.UnitaMisuraDose) = '' then
      raise Exception.CreateFmt(
        'Elemento %d di "aggiunte": "unita_misura" mancante.', [I]);

    LAggiunte[I] := LAggiunta;
  end;

  Result := LAggiunte;
end;

// Traduce un elenco di allergeni in un array JSON {codice, denominazione}
// - usato per ogni campo "allergeni_*" dei tool_result sotto. Non porta
// l'id interno: al modello e all'utente in chat serve il codice (GLUT,
// LAT, ...), non una chiave tecnica.
function AllergeniToJSON(AAllergeni: TObjectList<TAllergene>): TJDOJsonArray;
var
  LAllergene: TAllergene;
  LObj: TJDOJsonObject;
begin
  Result := TJDOJsonArray.Create;
  for LAllergene in AAllergeni do
  begin
    LObj := Result.AddObject;
    LObj.S['codice'] := LAllergene.Codice;
    LObj.S['denominazione'] := LAllergene.Denominazione;
  end;
end;

// Risolve il prodotto finito su cui operare: prodotto_finito_id (se
// presente) ha SEMPRE precedenza su nome_prodotto, esattamente come
// cliente_id/prodotto_id in get_list_vendite (vedi il commento su
// TVenditeToolProvider) - nessuna nuova ricerca testuale, quindi nessuna
// nuova ambiguita' possibile quando l'id e' gia' noto.
//
// Restituisce True e AProdottoID valorizzato se la risoluzione ha
// successo. Restituisce False se il nome e' ambiguo o non trovato: in tal
// caso AJSONDisambiguazione (di proprieta' del CHIAMANTE, che deve
// liberarlo) e' il tool_result gia' pronto da restituire cosi' com'e'.
function RisolviProdottoFinito(const AProdottoFinitoIDTesto, ANomeProdotto: string;
  out AProdottoID: Integer; out AJSONDisambiguazione: TJDOJsonObject): Boolean;
var
  LIDTesto: string;
  LRisoluzione: TRisoluzioneProdotto;
  LCandidati: TJDOJsonArray;
  LCandObj: TJDOJsonObject;
  LCandidato: TCandidatoProdotto;
  LProblemi: TJDOJsonArray;
  LProblemaObj: TJDOJsonObject;
begin
  AJSONDisambiguazione := nil;

  LIDTesto := Trim(AProdottoFinitoIDTesto);
  if LIDTesto <> '' then
  begin
    if not TryStrToInt(LIDTesto, AProdottoID) or (AProdottoID <= 0) then
      raise Exception.CreateFmt(
        'prodotto_finito_id "%s" non valido: deve essere un numero intero positivo.', [LIDTesto]);
    Exit(True);
  end;

  if Trim(ANomeProdotto) = '' then
    raise Exception.Create(
      'Servono "prodotto_finito_id" (se gia'' noto) oppure "nome_prodotto" (anche parziale).');

  LRisoluzione := TServizioVendite.RisolviProdotto(ANomeProdotto);
  try
    if LRisoluzione.Esito = erRisolto then
    begin
      AProdottoID := LRisoluzione.ProdottoID;
      Exit(True);
    end;

    // Ambiguo o non trovato: stessa forma "richiede_disambiguazione" gia'
    // usata da get_list_vendite, cosi' il frontend la riconosce senza
    // bisogno di sapere da quale tool arriva.
    AJSONDisambiguazione := TJDOJsonObject.Create;
    AJSONDisambiguazione.S['esito'] := 'richiede_disambiguazione';

    LProblemi := AJSONDisambiguazione.A['problemi'];
    LProblemaObj := LProblemi.AddObject;
    LProblemaObj.S['campo'] := 'nome_prodotto';
    LProblemaObj.S['valore_cercato'] := LRisoluzione.ValoreCercato;
    if LRisoluzione.Esito = erAmbiguo then
      LProblemaObj.S['tipo'] := 'ambiguo'
    else
      LProblemaObj.S['tipo'] := 'non_trovato';

    LCandidati := LProblemaObj.A['candidati'];
    for LCandidato in LRisoluzione.Candidati do
    begin
      LCandObj := LCandidati.AddObject;
      LCandObj.I['id'] := LCandidato.ID;
      LCandObj.S['codice'] := LCandidato.Codice;
      LCandObj.S['denominazione'] := LCandidato.Denominazione;
    end;

    Result := False;
  finally
    LRisoluzione.Free;
  end;
end;

{ TRicetteToolProvider }

function TRicetteToolProvider.GetDynamicToolDefs: TArray<TMCPDynamicToolDef>;

  function DefParam(const AName, ADescription: string; ARequired: Boolean;
    const AJsonSchemaType: string): TMCPDynamicParamDef;
  begin
    Result.Name := AName;
    Result.Description := ADescription;
    Result.Required := ARequired;
    Result.JsonSchemaType := AJsonSchemaType;
  end;

const
  DESCR_PRODOTTO_FINITO_ID =
    'ID del prodotto finito, se già noto. Ha precedenza su nome_prodotto.';

  DESCR_NOME_PRODOTTO =
    'Nome anche parziale del prodotto finito. Usato solo se prodotto_finito_id è assente.';

  DESCR_SOSTITUZIONI =
    'OPZIONALE. Oggetti per componenti ESISTENTI da sostituire: ' +
    '{"vecchio_tipo":"materia_prima"|"semilavorato","vecchio_id",' +
    '"nuovo_tipo":"materia_prima"|"semilavorato","nuovo_id",' +
    '"nuova_quantita" (opzionale),"nuova_unita_misura" (opzionale)}. ' +
    'Se quantità o unità non sono specificate, mantengono i valori attuali. ' +
    'I componenti non elencati restano invariati. Per aggiungere un componente senza sostituirne uno esistente usa aggiunte. ' +
    'Più sostituzioni nello stesso array vengono applicate insieme, ed è legittimo passare sostituzioni e aggiunte ' +
    'nella stessa chiamata. Se l''utente indica direttamente gli id dei componenti della ricetta da sostituire, ' +
    'usali qui senza richiamare prima cerca_componenti_ricetta per cercarli di nuovo: quella ricerca serve solo ' +
    'quando gli id dei componenti non sono ancora noti.';

  DESCR_AGGIUNTE =
    'OPZIONALE. Oggetti per componenti NUOVI da aggiungere senza sostituire componenti esistenti: ' +
    '{"tipo":"materia_prima"|"semilavorato","id","quantita","unita_misura"}. ' +
    'quantita e unita_misura sono sempre obbligatorie.';

begin
  SetLength(Result, 4);

  Result[0].Name := 'get_ricetta_prodotto_finito';
  Result[0].Description :=
    'Restituisce la ricetta CORRENTE di un prodotto finito: componenti, tipo, id, denominazione, ' +
    'quantità, unità, costo e allergeni. Gli id restituiti identificano i componenti reali della ' +
    'ricetta e devono essere usati senza inventarne altri. Il campo allergeni contiene i codici ' +
    'degli allergeni presenti nel componente. Se costo_disponibile=false, il costo del componente ' +
    'non è calcolabile. Se costo_completo=false, il costo totale della ricetta è parziale. ' +
    'apertura_vista indica che la scheda del prodotto è già stata aperta nell''interfaccia.';
  Result[0].ControllerClassName := 'TRicetteToolProvider';
  Result[0].Params := TArray<TMCPDynamicParamDef>.Create(
    DefParam('prodotto_finito_id', DESCR_PRODOTTO_FINITO_ID, False, 'string'),
    DefParam('nome_prodotto', DESCR_NOME_PRODOTTO, False, 'string')
  );

  Result[1].Name := 'cerca_componenti_ricetta';
  Result[1].Description :=
    'Cerca materie prime e/o semilavorati privi di un allergene, candidati alla sostituzione. ' +
    'Usa per escludi_allergene_codice il codice presente in allergeni della ricetta: non inventarlo. ' +
    'Senza tipo_componente né testo cerca candidati per tutti i componenti con quell''allergene. ' +
    'Codici validi: GLUT, CROST, UOV, PESCE, ARAC, SOIA, LAT, FRSC, SED, SEN, SESAM, SOLF, LUPIN, MOLL. ' +
    'Ogni candidato riporta anche giacenza_disponibile (quantità attualmente in magazzino, sommata su ' +
    'tutti i lotti): è un dato puramente informativo, da segnalare al cliente se pari a zero, ma NON ' +
    'esclude il candidato dai risultati né impedisce di proseguire con simula_adattamento_ricetta o ' +
    'applica_adattamento_ricetta. ' +
    'NON usare testo per indovinare il nome del prodotto sostituto: è un filtro esatto sulla ' +
    'denominazione già in anagrafica, e un nome indovinato che non corrisponde restituisce candidati=[] ' +
    'anche se un sostituto valido esiste con un altro nome. Alla prima ricerca lascia testo e ' +
    'tipo_componente entrambi assenti: restituisce insieme materie prime e semilavorati compatibili con ' +
    'l''allergene escluso, da cui scegliere. Usa testo/tipo_componente solo per restringere un elenco ' +
    'già visto, o se l''utente ha indicato lui stesso un nome o una categoria.';
  Result[1].ControllerClassName := 'TRicetteToolProvider';
  Result[1].Params := TArray<TMCPDynamicParamDef>.Create(
    DefParam(
      'escludi_allergene_codice',
      'Codice allergene da escludere, preso dal campo allergeni della ricetta (es. LAT). ' +
      'Se assente, nessun filtro allergene.',
      False,
      'string'
    ),
    DefParam(
      'tipo_componente',
      'materia_prima o semilavorato. Se assente, cerca in entrambe le anagrafiche.',
      False,
      'string'
    ),
    DefParam(
      'testo',
      'Filtro parziale sulla denominazione. Se assente, nessun filtro. ' +
      'Un testo senza corrispondenze restituisce un elenco vuoto.',
      False,
      'string'
    )
  );

  Result[2].Name := 'simula_adattamento_ricetta';
  Result[2].Description :=
    'Simula sulla ricetta CORRENTE una o più sostituzioni e/o aggiunte, senza modificare dati. ' +
    'Restituisce costo attuale, costo simulato, delta e variazione degli allergeni. ' +
    'Se costo_completo=false, il delta considera solo le materie prime. ' +
    'NON chiamarlo nello stesso turno di cerca_componenti_ricetta se l''utente non ha ancora indicato ' +
    'quali sostituzioni/aggiunte vuole: in quel caso fermati, mostra i candidati e chiedi all''utente di ' +
    'scegliere. Chiamalo solo quando sai già, con certezza, quali sostituzioni/aggiunte simulare - ' +
    'perché l''utente le ha specificate nel messaggio corrente (in chat, o tramite il form "Simula" del ' +
    'frontend) oppure in un turno precedente.';
  Result[2].ControllerClassName := 'TRicetteToolProvider';
  Result[2].Params := TArray<TMCPDynamicParamDef>.Create(
    DefParam('prodotto_finito_id', DESCR_PRODOTTO_FINITO_ID, False, 'string'),
    DefParam('nome_prodotto', DESCR_NOME_PRODOTTO, False, 'string'),
    DefParam('sostituzioni', DESCR_SOSTITUZIONI, False, 'array'),
    DefParam('aggiunte', DESCR_AGGIUNTE, False, 'array')
  );

  Result[3].Name := 'applica_adattamento_ricetta';
  Result[3].Description :=
    'Applica a una ricetta una o più sostituzioni e/o aggiunte. Richiede che l''utente abbia confermato ' +
    'esplicitamente di voler procedere con la modifica a questa ricetta - se conferma senza ripetere ' +
    'sostituzioni/aggiunte, usa qui esattamente quelle dell''ultima simulazione fatta con ' +
    'simula_adattamento_ricetta in questa conversazione, non chiederle di nuovo. ' +
    'Non modifica la ricetta di partenza: riusa una variante compatibile se esiste, ' +
    'altrimenti ne crea una con codice_nuovo_prodotto e denominazione_nuovo_prodotto. ' +
    'I componenti non modificati restano invariati. Restituisce il prodotto finito risultante.';
  Result[3].ControllerClassName := 'TRicetteToolProvider';
  Result[3].Params := TArray<TMCPDynamicParamDef>.Create(
    DefParam('prodotto_finito_id', DESCR_PRODOTTO_FINITO_ID, False, 'string'),
    DefParam('nome_prodotto', DESCR_NOME_PRODOTTO, False, 'string'),
    DefParam('sostituzioni', DESCR_SOSTITUZIONI, False, 'array'),
    DefParam('aggiunte', DESCR_AGGIUNTE, False, 'array'),
    DefParam(
      'codice_nuovo_prodotto',
      'Codice univoco del nuovo prodotto, richiesto solo se deve essere creata una nuova variante.',
      False,
      'string'
    ),
    DefParam(
      'denominazione_nuovo_prodotto',
      'Nome commerciale del nuovo prodotto, richiesto solo se deve essere creata una nuova variante.',
      False,
      'string'
    ),
    DefParam(
      'creato_da',
      'Utente che conferma l''operazione, per la tracciabilità.',
      True,
      'string'
    ),
    DefParam(
      'note',
      'Note libere opzionali.',
      False,
      'string'
    )
  );
end;

function TRicetteToolProvider.InvokeDynamic(const AToolName: string;
  AArguments: TJDOJsonObject): TMCPToolResult;

  // Comune ai due tool "prodotto": legge sostituzioni E aggiunte, verifica
  // che almeno una delle due non sia vuota, poi risolve il prodotto, in
  // quest'ordine (la validazione del formato non dipende dalla
  // risoluzione del prodotto, ha senso segnalarla per prima).
  // AProdottoID/ASostituzioni/AAggiunte sono valorizzati solo se la
  // funzione restituisce True; se restituisce False, ARisultato e' gia'
  // il TMCPToolResult da restituire cosi' com'e' (un errore di formato,
  // "nessuna modifica indicata", o una richiesta di disambiguazione).
  function PreparaChiamataProdotto(out AProdottoID: Integer;
    out ASostituzioni: TArray<TSostituzioneComponente>;
    out AAggiunte: TArray<TAggiuntaComponente>;
    out ARisultato: TMCPToolResult): Boolean;
  var
    LJSONDisambiguazione: TJDOJsonObject;
  begin
    // Niente "ARisultato := nil": TMCPToolResult e' un record (non una
    // classe), quindi non e' compatibile con nil - e comunque un parametro
    // "out" arriva gia' azzerato dal chiamante, non serve inizializzarlo
    // a mano prima di valorizzarlo nei rami sotto.
    try
      ASostituzioni := LeggiSostituzioni(AArguments);
      AAggiunte := LeggiAggiunte(AArguments);
    except
      on E: Exception do
      begin
        ARisultato := TMCPToolResult.Error(E.Message);
        Exit(False);
      end;
    end;

    if (Length(ASostituzioni) = 0) and (Length(AAggiunte) = 0) then
    begin
      ARisultato := TMCPToolResult.Error(
        'Nessuna modifica indicata: specifica almeno un componente in "sostituzioni" (per ' +
        'sostituire un componente esistente) o in "aggiunte" (per aggiungerne uno nuovo).');
      Exit(False);
    end;

    try
      if not RisolviProdottoFinito(AArguments.S['prodotto_finito_id'], AArguments.S['nome_prodotto'],
           AProdottoID, LJSONDisambiguazione) then
      begin
        try
          ARisultato := TMCPToolResult.Text(LJSONDisambiguazione.ToJSON);
        finally
          LJSONDisambiguazione.Free;
        end;
        Exit(False);
      end;
    except
      on E: Exception do
      begin
        ARisultato := TMCPToolResult.Error(E.Message);
        Exit(False);
      end;
    end;

    Result := True;
  end;

var
  LProdottoID: Integer;
  LSostituzioni: TArray<TSostituzioneComponente>;
  LAggiunte: TArray<TAggiuntaComponente>;
  LRisultatoPreparazione: TMCPToolResult;
  LCandidati: TObjectList<TCandidatoComponente>;
  LCandidato: TCandidatoComponente;
  LTipoComponente: string;
  LIncludiMP, LIncludiSL: Boolean;
  LRoot: TJDOJsonObject;
  LArray: TJDOJsonArray;
  LObj: TJDOJsonObject;
  LSimulazione: TSimulazioneAdattamento;
  LEsito: TEsitoAdattamentoRicetta;
  LJSONDisambiguazione: TJDOJsonObject;
  LCosto: TCostoRicetta;
  LComponente: TCostoComponenteRicetta;
  LAllergeniComponente: TObjectList<TAllergene>;
begin
  if AArguments = nil then
    Exit(TMCPToolResult.Error('Argomenti mancanti per "' + AToolName + '".'));

  if SameText(AToolName, 'get_ricetta_prodotto_finito') then
  begin
    try
      if not RisolviProdottoFinito(AArguments.S['prodotto_finito_id'], AArguments.S['nome_prodotto'],
           LProdottoID, LJSONDisambiguazione) then
      begin
        try
          Exit(TMCPToolResult.Text(LJSONDisambiguazione.ToJSON));
        finally
          LJSONDisambiguazione.Free;
        end;
      end;
    except
      on E: Exception do
        Exit(TMCPToolResult.Error(E.Message));
    end;

    try
      LCosto := TServizioRicette.CalcolaCostoRicettaProdottoFinito(LProdottoID);
    except
      on E: Exception do
        Exit(TMCPToolResult.Error(E.Message));
    end;

    try
      LRoot := TJDOJsonObject.Create;
      try
        LRoot.S['esito'] := 'ok';
        LRoot.I['prodotto_finito_id'] := LCosto.ProdottoFinitoID;
        LRoot.I['ricetta_id'] := LCosto.RicettaID;
        LRoot.I['versione'] := LCosto.Versione;
        LRoot.F['costo_totale'] := LCosto.CostoTotale;
        // False se la ricetta contiene almeno un componente semilavorato:
        // costo_totale in quel caso somma SOLO le materie prime (vedi
        // TCostoRicetta.CostoCompleto in uServiziRicette.pas) - il modello
        // DEVE avvisare l'utente che il costo mostrato e' parziale, non
        // presentarlo come il costo reale della ricetta.
        LRoot.B['costo_completo'] := LCosto.CostoCompleto;

        LArray := LRoot.A['componenti'];
        for LComponente in LCosto.Componenti do
        begin
          LObj := LArray.AddObject;
          if LComponente.IsComponenteMateriaPrima then
            LObj.S['tipo'] := 'materia_prima'
          else
            LObj.S['tipo'] := 'semilavorato';
          LObj.I['id'] := LComponente.ComponenteID;
          LObj.S['denominazione'] := LComponente.Denominazione;
          LObj.F['quantita_standard'] := LComponente.QuantitaStandard;
          LObj.S['unita_misura_dose'] := LComponente.UnitaMisuraDose;
          LObj.F['costo_unitario'] := LComponente.CostoUnitario;
          LObj.F['costo_totale'] := LComponente.CostoTotale;
          // Vedi il commento su TCostoComponenteRicetta.CostoDisponibile:
          // False solo per i semilavorati (costo_unitario/costo_totale
          // sono 0 per costruzione in quel caso, non "gratis").
          LObj.B['costo_disponibile'] := LComponente.CostoDisponibile;

          // Allergeni DICHIARATI di QUESTO componente, stessa forma
          // {"codice","denominazione"} usata per "allergeni" nei candidati
          // di cerca_componenti_ricetta: il modello puo' prendere il
          // "codice" da qui e passarlo tale e quale come
          // escludi_allergene_codice, invece di indovinare quale
          // componente porti l'allergene da togliere (vedi il commento in
          // testa alla unit sul perche' questo campo e' stato aggiunto -
          // prima mancava e il modello scopriva l'errore di bersaglio solo
          // DOPO aver simulato una sostituzione a vuoto).
          // GetAllergeniComponente e' la stessa funzione gia' usata da
          // CercaComponenti per i candidati (uServiziRicette.pas): nessuna
          // nuova query, solo lo stesso dato esposto anche qui.
          LAllergeniComponente := TServizioRicette.GetAllergeniComponente(
            LComponente.IsComponenteMateriaPrima, LComponente.ComponenteID);
          try
            LObj.A['allergeni'] := AllergeniToJSON(LAllergeniComponente);
          finally
            LAllergeniComponente.Free;
          end;
        end;

        // Apertura vista DETERMINISTICA, non affidata al modello. Prima
        // questo tool si limitava a ISTRUIRE il modello ("chiama SEMPRE
        // apri_vista dopo aver ricevuto questo risultato") - in pratica,
        // con Qwen 9B locale, un LLM piccolo che deve incatenare una
        // SECONDA tool_use nello stesso turno subito dopo la prima e'
        // inaffidabile: a volte lo fa, a volte si ferma al testo. Per
        // un'azione che deve avvenire OGNI volta (mostrare la ricetta di
        // partenza appena letta) e' piu' robusto incorporarla nel
        // risultato di QUESTO tool - che il modello chiama comunque per
        // primo, sempre, per costruzione (vedi il commento in testa alla
        // unit) - invece di sperare in una sua seconda iniziativa.
        //
        // Stessa forma {"vista", "parametri"} gia' prodotta da apri_vista
        // (TNavigazioneToolProvider), qui pero' sotto la chiave
        // "apertura_vista" per non confondersi con "esito" (che qui vale
        // "ok" per il risultato del tool, non per l'apertura): il
        // frontend riconosce ENTRAMBE le forme con la stessa funzione
        // (components/chat.js, aggiungiAperturaVista), sia che arrivino
        // da una vera chiamata ad apri_vista sia incorporate qui.
        LObj := LRoot.O['apertura_vista'];
        LObj.S['vista'] := 'ricetta_prodotto_finito';
        LObj.O['parametri'].I['prodotto_finito_id'] := LCosto.ProdottoFinitoID;

        Result := TMCPToolResult.Text(LRoot.ToJSON);
      finally
        LRoot.Free;
      end;
    finally
      LCosto.Free;
    end;
  end

  else if SameText(AToolName, 'cerca_componenti_ricetta') then
  begin
    LTipoComponente := Trim(AArguments.S['tipo_componente']);
    // CONTROLLO DI DIFESA (tappa 13): prima un valore sconosciuto (es.
    // "ingrediente") veniva trattato in silenzio come "nessun filtro" e il
    // modello credeva di aver filtrato. Ora e' un errore che dice i valori
    // ammessi. Vuoto/assente resta "entrambi i tipi".
    if (LTipoComponente <> '') and not SameText(LTipoComponente, 'materia_prima') and
       not SameText(LTipoComponente, 'semilavorato') then
      Exit(TMCPToolResult.Error(Format(
        'Parametro "tipo_componente" non valido ("%s"): valori ammessi "materia_prima" o ' +
        '"semilavorato"; omettilo per cercare in entrambi.', [LTipoComponente])));
    LIncludiMP := not SameText(LTipoComponente, 'semilavorato');
    LIncludiSL := not SameText(LTipoComponente, 'materia_prima');

    try
      LCandidati := TServizioRicette.CercaComponenti(
        AArguments.S['escludi_allergene_codice'], LIncludiMP, LIncludiSL, AArguments.S['testo']);
    except
      on E: Exception do
        Exit(TMCPToolResult.Error(E.Message));
    end;

    try
      LRoot := TJDOJsonObject.Create;
      try
        LRoot.S['esito'] := 'ok';
        LArray := LRoot.A['candidati'];
        for LCandidato in LCandidati do
        begin
          LObj := LArray.AddObject;
          if LCandidato.IsMateriaPrima then
            LObj.S['tipo'] := 'materia_prima'
          else
            LObj.S['tipo'] := 'semilavorato';
          LObj.I['id'] := LCandidato.ID;
          LObj.S['codice'] := LCandidato.Codice;
          LObj.S['denominazione'] := LCandidato.Denominazione;
          LObj.A['allergeni'] := AllergeniToJSON(LCandidato.Allergeni);
          // Vedi il commento su TCandidatoComponente.GiacenzaDisponibile:
          // informativo, non un filtro - un candidato con giacenza 0
          // resta comunque nell'elenco.
          LObj.F['giacenza_disponibile'] := LCandidato.GiacenzaDisponibile;
        end;

        Result := TMCPToolResult.Text(LRoot.ToJSON);
      finally
        LRoot.Free;
      end;
    finally
      LCandidati.Free;
    end;
  end

  else if SameText(AToolName, 'simula_adattamento_ricetta') then
  begin
    if not PreparaChiamataProdotto(LProdottoID, LSostituzioni, LAggiunte, LRisultatoPreparazione) then
      Exit(LRisultatoPreparazione);

    try
      LSimulazione := TServizioRicette.SimulaAdattamentoRicetta(LProdottoID, LSostituzioni, LAggiunte);
    except
      on E: Exception do
        Exit(TMCPToolResult.Error(E.Message));
    end;

    try
      LRoot := TJDOJsonObject.Create;
      try
        LRoot.S['esito'] := 'ok';
        LRoot.I['prodotto_finito_id'] := LSimulazione.ProdottoFinitoID;
        LRoot.F['costo_ricetta_attuale'] := LSimulazione.CostoRicettaAttuale;
        LRoot.F['costo_ricetta_simulata'] := LSimulazione.CostoRicettaSimulata;
        LRoot.F['delta_costo'] := LSimulazione.DeltaCosto;
        // False se la ricetta attuale o quella simulata include un
        // semilavorato: i tre valori di costo qui sopra sono calcolati
        // sulle sole materie prime (vedi TSimulazioneAdattamento.
        // CostoCompleto) - il modello NON deve presentare delta_costo come
        // il vero impatto economico dell'adattamento in quel caso, deve
        // dirlo esplicitamente al cliente.
        LRoot.B['costo_completo'] := LSimulazione.CostoCompleto;
        LRoot.A['allergeni_attuali'] := AllergeniToJSON(LSimulazione.AllergeniAttuali);
        LRoot.A['allergeni_simulati'] := AllergeniToJSON(LSimulazione.AllergeniSimulati);
        LRoot.A['allergeni_rimossi'] := AllergeniToJSON(LSimulazione.AllergeniRimossi);
        LRoot.A['allergeni_aggiunti'] := AllergeniToJSON(LSimulazione.AllergeniAggiunti);

        Result := TMCPToolResult.Text(LRoot.ToJSON);
      finally
        LRoot.Free;
      end;
    finally
      LSimulazione.Free;
    end;
  end

  else if SameText(AToolName, 'applica_adattamento_ricetta') then
  begin
    if not PreparaChiamataProdotto(LProdottoID, LSostituzioni, LAggiunte, LRisultatoPreparazione) then
      Exit(LRisultatoPreparazione);

    // CONTROLLO DI DIFESA (tappa 13): la libreria MCP verifica solo che la
    // chiave "creato_da" ci sia, non che abbia un valore. Una scrittura
    // senza autore non e' tracciabile, quindi non parte.
    if Trim(AArguments.S['creato_da']) = '' then
      Exit(TMCPToolResult.Error(
        'Parametro "creato_da" vuoto: serve il nome di chi conferma l''operazione (tracciabilita'').'));

    try
      LEsito := TServizioRicette.ApplicaAdattamentoRicetta(LProdottoID, LSostituzioni, LAggiunte,
        AArguments.S['codice_nuovo_prodotto'], AArguments.S['denominazione_nuovo_prodotto'],
        AArguments.S['creato_da'], AArguments.S['note']);
    except
      on E: Exception do
        // Errore di dominio (es. "nessuna variante compatibile e mancano
        // codice/denominazione", o un componente indicato non presente
        // nella ricetta): .Error, non un'eccezione di trasporto - il
        // modello vede il messaggio e puo' correggere la chiamata (es.
        // proponendo un codice) al turno successivo, senza che l'utente
        // debba ripetere tutto da capo.
        Exit(TMCPToolResult.Error(E.Message));
    end;

    try
      LRoot := TJDOJsonObject.Create;
      try
        if LEsito.VarianteGiaEsistente then
          LRoot.S['esito'] := 'variante_gia_esistente'
        else
          LRoot.S['esito'] := 'variante_creata';

        LRoot.I['prodotto_finito_id'] := LEsito.ProdottoFinitoID;
        LRoot.S['codice'] := LEsito.Codice;
        LRoot.S['denominazione'] := LEsito.Denominazione;
        LRoot.I['prodotto_finito_padre_id'] := LEsito.ProdottoFinitoPadreID;

        if not LEsito.VarianteGiaEsistente then
        begin
          LRoot.I['ricetta_id'] := LEsito.RicettaID;
          LRoot.I['versione'] := LEsito.Versione;
          LRoot.F['costo_ricetta'] := LEsito.CostoRicetta;
          // Vedi il commento gemello in simula_adattamento_ricetta.
          LRoot.B['costo_ricetta_completo'] := LEsito.CostoRicettaCompleto;
        end;

        // Apertura vista DETERMINISTICA sul prodotto RISULTANTE (la variante
        // appena creata o quella riusata), con la sua ricetta corrente: stesso
        // canale "apertura_vista" di get_ricetta_prodotto_finito, vedi il
        // commento li' sopra. Senza questo la chat restava sulla ricetta di
        // PARTENZA (aperta dalla lettura iniziale) anche dopo la scrittura.
        LRoot.O['apertura_vista'].S['vista'] := 'ricetta_prodotto_finito';
        LRoot.O['apertura_vista'].O['parametri'].I['prodotto_finito_id'] := LEsito.ProdottoFinitoID;

        Result := TMCPToolResult.Text(LRoot.ToJSON);
      finally
        LRoot.Free;
      end;
    finally
      LEsito.Free;
    end;
  end

  else
    // Non dovrebbe succedere (TMCPServer.RegisterDynamicProvider dispatcha
    // solo i nomi restituiti da GetDynamicToolDefs), ma un fallback
    // esplicito e' piu' sicuro di un case senza else (vedi lo stesso
    // pattern in uFilesToolsProvider.pas).
    Result := TMCPToolResult.Error(Format(
      '"%s" non e'' un tool gestito da questo provider.', [AToolName]));
end;

// ---------------------------------------------------------------------------
// CONTRATTI DEI TOOL DI QUESTO PROVIDER (tappa 2 del porting del pianificatore,
// vedi agente_ai/tool/uContrattiTool.pas). Portati da mcp_delphi.py del prototipo:
// DEFINIZIONI (output_schema, effetto, conferma), INTEGRAZIONI_INPUT (vincoli
// sugli input) e ALMENO_UNO. Gli schemi di output descrivono le risposte
// costruite piu' sopra in questa unit: se cambia una risposta, va cambiato
// anche il suo schema qui sotto. Il test scripts/prototipo_pianificatore/tests/
// test_contratti_delphi.py li confronta con quelli del prototipo.
// ---------------------------------------------------------------------------

const
  SCHEMA_OUTPUT_GET_RICETTA_PRODOTTO_FINITO =
    '{"type":"object","properties":{"esito":{"type":"string","enum":["ok"]},' +
    '"prodotto_finito_id":{"type":"integer"},"ricetta_id":{"type":"integer"},' +
    '"versione":{"type":"integer"},"costo_totale":{"type":"number"},"costo_completo":{"type":"boolean"},' +
    '"componenti":{"type":"array","items":{"type":"object","properties":{"tipo":{"type":"string",' +
    '"enum":["materia_prima","semilavorato"]},"id":{"type":"integer"},"denominazione":{"type":"string"},' +
    '"quantita_standard":{"type":"number"},"unita_misura_dose":{"type":"string"},' +
    '"costo_unitario":{"type":"number"},"costo_totale":{"type":"number"},"costo_disponibile":{"type":"boolean"},' +
    '"allergeni":{"type":"array","items":{"type":"object","properties":{"codice":{"type":"string"},' +
    '"denominazione":{"type":"string"}},"required":["codice","denominazione"]}}},' +
    '"required":["tipo","id","denominazione","quantita_standard","unita_misura_dose",' +
    '"costo_unitario","costo_totale","costo_disponibile","allergeni"]}},"apertura_vista":{"type":"object",' +
    '"properties":{"vista":{"type":"string"},"parametri":{"type":"object"}},' +
    '"required":["vista","parametri"]}},"required":["esito","prodotto_finito_id",' +
    '"ricetta_id","versione","costo_totale","costo_completo","componenti","apertura_vista"]}';

  SCHEMA_OUTPUT_CERCA_COMPONENTI_RICETTA =
    '{"type":"object","properties":{"esito":{"type":"string","enum":["ok"]},' +
    '"candidati":{"type":"array","items":{"type":"object","properties":{"tipo":{"type":"string",' +
    '"enum":["materia_prima","semilavorato"]},"id":{"type":"integer"},"codice":{"type":"string"},' +
    '"denominazione":{"type":"string"},"allergeni":{"type":"array","items":{"type":"object",' +
    '"properties":{"codice":{"type":"string"},"denominazione":{"type":"string"}},' +
    '"required":["codice","denominazione"]}},"giacenza_disponibile":{"type":"number"}},' +
    '"required":["tipo","id","codice","denominazione","allergeni","giacenza_disponibile"]}}},' +
    '"required":["esito","candidati"]}';

  SCHEMA_OUTPUT_SIMULA_ADATTAMENTO_RICETTA =
    '{"type":"object","properties":{"esito":{"type":"string","enum":["ok"]},' +
    '"prodotto_finito_id":{"type":"integer"},"costo_ricetta_attuale":{"type":"number"},' +
    '"costo_ricetta_simulata":{"type":"number"},"delta_costo":{"type":"number"},' +
    '"costo_completo":{"type":"boolean"},"allergeni_attuali":{"type":"array",' +
    '"items":{"type":"object","properties":{"codice":{"type":"string"},"denominazione":{"type":"string"}},' +
    '"required":["codice","denominazione"]}},"allergeni_simulati":{"type":"array",' +
    '"items":{"type":"object","properties":{"codice":{"type":"string"},"denominazione":{"type":"string"}},' +
    '"required":["codice","denominazione"]}},"allergeni_rimossi":{"type":"array",' +
    '"items":{"type":"object","properties":{"codice":{"type":"string"},"denominazione":{"type":"string"}},' +
    '"required":["codice","denominazione"]}},"allergeni_aggiunti":{"type":"array",' +
    '"items":{"type":"object","properties":{"codice":{"type":"string"},"denominazione":{"type":"string"}},' +
    '"required":["codice","denominazione"]}}},"required":["esito","prodotto_finito_id",' +
    '"costo_ricetta_attuale","costo_ricetta_simulata","delta_costo","costo_completo",' +
    '"allergeni_attuali","allergeni_simulati","allergeni_rimossi","allergeni_aggiunti"]}';

  VINCOLO_SOSTITUZIONI =
    '{"items":{"type":"object","properties":{"vecchio_tipo":{"type":"string",' +
    '"enum":["materia_prima","semilavorato"]},"vecchio_id":{"type":"integer",' +
    '"minimum":1},"nuovo_tipo":{"type":"string","enum":["materia_prima","semilavorato"]},' +
    '"nuovo_id":{"type":"integer","minimum":1},"nuova_quantita":{"type":"number"},' +
    '"nuova_unita_misura":{"type":"string"}},"required":["vecchio_tipo","vecchio_id",' +
    '"nuovo_tipo","nuovo_id"]}}';

  VINCOLO_AGGIUNTE =
    '{"items":{"type":"object","properties":{"tipo":{"type":"string","enum":["materia_prima",' +
    '"semilavorato"]},"id":{"type":"integer","minimum":1},"quantita":{"type":"number"},' +
    '"unita_misura":{"type":"string","minLength":1}},"required":["tipo","id",' +
    '"quantita","unita_misura"]}}';

  SCHEMA_OUTPUT_APPLICA_ADATTAMENTO_RICETTA =
    '{"type":"object","properties":{"esito":{"type":"string","enum":["variante_creata",' +
    '"variante_gia_esistente"]},"prodotto_finito_id":{"type":"integer"},"codice":{"type":"string"},' +
    '"denominazione":{"type":"string"},"prodotto_finito_padre_id":{"type":"integer"},' +
    '"ricetta_id":{"type":"integer"},"versione":{"type":"integer"},"costo_ricetta":{"type":"number"},' +
    '"costo_ricetta_completo":{"type":"boolean"},"apertura_vista":{"type":"object"}},' +
    '"required":["esito","prodotto_finito_id",' +
    '"codice","denominazione","prodotto_finito_padre_id"]}';

class function TRicetteToolProvider.ContrattiTool: TArray<TContrattoTool>;
begin
  Result := TArray<TContrattoTool>.Create(
    ContrattoTool('get_ricetta_prodotto_finito', etLettura, False,
      SCHEMA_OUTPUT_GET_RICETTA_PRODOTTO_FINITO,
      nil,
      TArray<TArray<string>>.Create(
        TArray<string>.Create('prodotto_finito_id', 'nome_prodotto'))),
    ContrattoTool('cerca_componenti_ricetta', etLettura, False,
      SCHEMA_OUTPUT_CERCA_COMPONENTI_RICETTA),
    ContrattoTool('simula_adattamento_ricetta', etLettura, False,
      SCHEMA_OUTPUT_SIMULA_ADATTAMENTO_RICETTA,
      TArray<TVincoloParametro>.Create(
        VincoloParametro('sostituzioni', VINCOLO_SOSTITUZIONI),
        VincoloParametro('aggiunte', VINCOLO_AGGIUNTE)),
      TArray<TArray<string>>.Create(
        TArray<string>.Create('prodotto_finito_id', 'nome_prodotto'),
        TArray<string>.Create('sostituzioni', 'aggiunte'))),
    ContrattoTool('applica_adattamento_ricetta', etScrittura, True,
      SCHEMA_OUTPUT_APPLICA_ADATTAMENTO_RICETTA,
      TArray<TVincoloParametro>.Create(
        VincoloParametro('sostituzioni', VINCOLO_SOSTITUZIONI),
        VincoloParametro('aggiunte', VINCOLO_AGGIUNTE)),
      TArray<TArray<string>>.Create(
        TArray<string>.Create('prodotto_finito_id', 'nome_prodotto'),
        TArray<string>.Create('sostituzioni', 'aggiunte'))));
end;

end.
