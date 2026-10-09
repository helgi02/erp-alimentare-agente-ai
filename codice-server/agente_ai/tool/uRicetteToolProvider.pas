unit uRicetteToolProvider;

// Tool MCP dello scenario 3 (adattamento ricette con calcolo economico). Provider dinamico
// perche' "sostituzioni" e "aggiunte" sono array veri di oggetti, non esprimibili via RTTI
// (vedi uFilesToolsProvider). Anche i due tool a parametri scalari stanno qui: un provider
// per scenario, un solo punto di registrazione.
// 1. get_ricetta_prodotto_finito (lettura): componenti della ricetta corrente con, per
// ciascuno, gli allergeni (codice + denominazione). Il codice e' il valore da passare come
// escludi_allergene_codice al tool successivo: senza, il modello doveva indovinare quale
// componente portasse l'allergene (con Qwen 9B: 8 iterazioni di tentativi). Il risultato
// porta anche "apertura_vista", che il frontend apre da solo (chat.js,
// aggiungiAperturaVista): un modello piccolo non incatena in modo affidabile una seconda
// tool_use nello stesso turno, mentre questo tool viene chiamato sempre per primo.
// 2. cerca_componenti_ricetta: materie prime/semilavorati che rispettano un vincolo
// dietetico (es. escludi LAT). Una sola chiamata, senza tipo_componente ne' testo, copre
// tutti i componenti che portano quell'allergene (il vincolo e' l'allergene, non il
// componente). Va detto nella description, altrimenti il modello chiama il tool una volta
// per componente.
// 3. simula_adattamento_ricetta (lettura): "sostituzioni" (togli X, metti Y) e/o "aggiunte"
// (metti anche Z), almeno una delle due. Calcola delta di costo e variazione degli
// allergeni senza scrivere. I componenti non menzionati restano invariati: il modello non
// rielenca la ricetta.
// 4. applica_adattamento_ricetta (scrittura, solo dopo conferma): rifa' il calcolo e
// scrive, mai sul prodotto di partenza. Riusa una variante dietetica esistente o crea un
// nuovo prodotto finito con la prima ricetta. La logica e' in
// TServizioRicette.ApplicaAdattamentoRicetta: qui solo l'adattatore JSON.
// Prodotto per id o per nome (anche parziale), come in get_list_vendite: l'id ha la
// precedenza. Se il nome e' ambiguo, "richiede_disambiguazione" con "campo":
// "nome_prodotto"; il frontend (chat.js, aggiungiScelteDisambiguazione) mostra i pulsanti
// senza modifiche.

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
    // Contratti dei tool per il pianificatore (vedi uContrattiTool.pas e il fondo di questa
    // unit).
    class function ContrattiTool: TArray<TContrattoTool>;
  end;

implementation

// 'materia_prima' -> True, 'semilavorato' -> False, altro (anche vuoto) e' un errore: un
// componente deve essere l'uno o l'altro, non c'e' un default sensato.
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

// Legge "sostituzioni" (opzionale): array di {vecchio_tipo, vecchio_id, nuovo_tipo,
// nuovo_id, nuova_quantita?, nuova_unita_misura?}. Assente -> vuoto, non errore: un
// adattamento puo' avere sole aggiunte. Che ce ne sia almeno una fra sostituzioni e
// aggiunte lo verifica PreparaChiamataProdotto. Le eccezioni di formato diventano
// TMCPToolResult.Error, come in uFilesToolsProvider.
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

    // Un id e' un intero positivo: zero o negativo vuol dire che il modello non aveva l'id
    // vero.
    if (LSostituzione.VecchioComponenteID <= 0) or (LSostituzione.NuovoComponenteID <= 0) then
      raise Exception.CreateFmt(
        'Elemento %d di "sostituzioni": "vecchio_id" e "nuovo_id" devono essere interi maggiori ' +
        'di zero, presi dalla ricetta e da cerca_componenti_ricetta.', [I]);

    // Sentinelle "mantieni quella del componente sostituito": 0 / '' se non specificate.
    if LElemento.Contains('nuova_quantita') then
    begin
      LSostituzione.NuovaQuantitaStandard := LElemento.F['nuova_quantita'];
      // Dose negativa: priva di senso, falserebbe il calcolo. Zero e' ammesso (sentinella
      // "mantieni la quantita'").
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

// Legge "aggiunte" (opzionale): array di {tipo, id, quantita, unita_misura}, componenti
// nuovi senza sostituire nulla. Quantita e unita' sono obbligatorie: non c'e' un componente
// da cui ereditarle (TAggiuntaComponente). Assente -> vuoto.
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

// Allergeni come array {codice, denominazione}, senza id interno: al modello serve il
// codice (GLUT, LAT, ...).
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

// Risolve il prodotto: prodotto_finito_id ha sempre precedenza su nome_prodotto, come in
// get_list_vendite, senza nuova ricerca e quindi senza nuova ambiguita'. Se False,
// AJSONDisambiguazione (da liberare a cura del chiamante) e' il tool_result gia' pronto.
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

    // Stessa forma "richiede_disambiguazione" di get_list_vendite, riconosciuta dal
    // frontend.
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

  // Comune ai due tool "prodotto": legge sostituzioni e aggiunte, verifica che non siano
  // entrambe vuote, poi risolve il prodotto (il formato si segnala prima). Se restituisce
  // False, ARisultato e' gia' il TMCPToolResult da restituire (errore di formato, "nessuna
  // modifica indicata" o disambiguazione).
  function PreparaChiamataProdotto(out AProdottoID: Integer;
    out ASostituzioni: TArray<TSostituzioneComponente>;
    out AAggiunte: TArray<TAggiuntaComponente>;
    out ARisultato: TMCPToolResult): Boolean;
  var
    LJSONDisambiguazione: TJDOJsonObject;
  begin
    // Niente "ARisultato := nil": TMCPToolResult e' un record, non compatibile con nil.
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
        // False se c'e' un semilavorato: costo_totale somma solo le materie prime
        // (TCostoRicetta.CostoCompleto) e il modello deve avvisare che il costo e'
        // parziale.
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
          // False solo per i semilavorati: costo 0 per costruzione, non "gratis".
          LObj.B['costo_disponibile'] := LComponente.CostoDisponibile;

          // Allergeni dichiarati di questo componente, nella forma dei candidati di
          // cerca_componenti_ricetta: il modello passa il "codice" come
          // escludi_allergene_codice invece di indovinare quale componente lo porti. Stessa
          // funzione di CercaComponenti (GetAllergeniComponente), nessuna nuova query.
          LAllergeniComponente := TServizioRicette.GetAllergeniComponente(
            LComponente.IsComponenteMateriaPrima, LComponente.ComponenteID);
          try
            LObj.A['allergeni'] := AllergeniToJSON(LAllergeniComponente);
          finally
            LAllergeniComponente.Free;
          end;
        end;

        // Apertura vista deterministica, non affidata al modello (vedi nota in testa).
        // Stessa forma {"vista","parametri"} di apri_vista, ma sotto "apertura_vista" per
        // non confondersi con "esito"; il frontend riconosce entrambe con la stessa
        // funzione (chat.js, aggiungiAperturaVista).
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
    // Un valore sconosciuto (es. "ingrediente") prima era trattato come "nessun filtro" e
    // il modello credeva di aver filtrato. Ora e' un errore che elenca i valori ammessi.
    // Vuoto = entrambi i tipi.
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
          // Informativo, non un filtro: un candidato con giacenza 0 resta nell'elenco.
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
        // False se la ricetta attuale o quella simulata ha un semilavorato: i costi sono
        // sulle sole materie prime (TSimulazioneAdattamento.CostoCompleto) e delta_costo
        // non e' il vero impatto economico; il modello deve dirlo.
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

    // La libreria MCP controlla che "creato_da" ci sia, non che abbia un valore. Senza
    // autore la scrittura non e' tracciabile e non parte.
    if Trim(AArguments.S['creato_da']) = '' then
      Exit(TMCPToolResult.Error(
        'Parametro "creato_da" vuoto: serve il nome di chi conferma l''operazione (tracciabilita'').'));

    try
      LEsito := TServizioRicette.ApplicaAdattamentoRicetta(LProdottoID, LSostituzioni, LAggiunte,
        AArguments.S['codice_nuovo_prodotto'], AArguments.S['denominazione_nuovo_prodotto'],
        AArguments.S['creato_da'], AArguments.S['note']);
    except
      on E: Exception do
        // Errore di dominio: .Error, non eccezione di trasporto, cosi' il modello puo'
        // correggere la chiamata al turno successivo.
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
          LRoot.B['costo_ricetta_completo'] := LEsito.CostoRicettaCompleto;
        end;

        // Apertura vista deterministica sul prodotto risultante (variante creata o
        // riusata), stesso canale di get_ricetta_prodotto_finito. Senza, la chat restava
        // sulla ricetta di partenza.
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
    // Non dovrebbe succedere (si dispatchano solo i nomi di GetDynamicToolDefs), ma meglio
    // un fallback esplicito.
    Result := TMCPToolResult.Error(Format(
      '"%s" non e'' un tool gestito da questo provider.', [AToolName]));
end;

// Contratti (vedi uContrattiTool.pas). Gli schemi di output descrivono le risposte
// costruite sopra: se cambia una risposta, va cambiato anche lo schema.

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
