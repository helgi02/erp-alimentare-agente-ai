unit uVenditeToolProvider;

interface

uses
  System.SysUtils,
  System.JSON,
  System.DateUtils,
  System.Generics.Collections,
  MVCFramework.MCP.ToolProvider,
  uContrattiTool,
  MVCFramework.MCP.Attributes,
  uServiziVendite;

type
  // Tool provider MCP per lo scenario 2.2 (interrogazione vendite ad
  // hoc). Una classe per scenario - TMCPServer.RegisterToolProvider
  // accetta piu' provider distinti, quindi ritiro/richiamo e ricette
  // avranno ciascuno il proprio TxxxToolProvider in tools/, invece di
  // accumulare tutti i tool in un'unica classe: stesso principio "un
  // file per responsabilita'" gia' seguito da model/services/controllers
  // in questo progetto.
  //
  // Nessun metodo di costruzione schema qui: TMCPServer scansiona i
  // metodi via RTTI leggendo [MCPTool]/[MCPParam] al momento di
  // RegisterToolProvider (vedi CLAUDE.md della libreria MCP), quindi la
  // generazione dello schema JSON e' interamente a carico del framework.
  //
  // cliente_id/prodotto_id (aggiunti insieme alla UI di disambiguazione
  // lato frontend): quando il frontend mostra i candidati come pulsanti
  // e l''utente ne clicca uno, il round successivo puo'' riferirsi al
  // cliente/prodotto per id invece che per nome. E' lo stesso principio
  // "tool generico e parametrico" del documento di progetto applicato a
  // se stesso: due parametri opzionali in piu' sullo stesso tool, non un
  // secondo tool "get_list_vendite_by_id". Il motivo per cui serve
  // davvero (e non e'' solo comodita''): il match testuale esatto in
  // TServizioVendite.RisolviCliente/RisolviProdotto non garantisce
  // l''unicita'' se due anagrafiche condividono la stessa ragione
  // sociale/denominazione (es. filiali) - in quel caso rimandare il nome
  // esatto ripresenterebbe la stessa ambiguita'' all''infinito, mentre
  // l''id la elimina per costruzione.
  TVenditeToolProvider = class(TMCPToolProvider)
  public
    [MCPTool('get_list_vendite',
      'Restituisce gli ordini di vendita e le relative righe prodotto, filtrabili per cliente, ' +
  'prodotto e periodo. Tutti i filtri sono opzionali e combinabili. Se il periodo non è specificato, ' +
  'usa l''ultimo mese. Se ARagioneSocialeCliente o ANomeProdotto corrispondono a più anagrafiche ' +
  'o a nessuna, restituisce i candidati con i relativi id invece dei dati di vendita. Se AClienteId ' +
  'o AProdottoId sono specificati, hanno precedenza sul relativo filtro testuale e rendono il filtro univoco.')]
    function GetListVendite(
      [MCPParam('Ragione sociale del cliente, anche parziale', TMCPParamPresence.Optional)]
        const ARagioneSocialeCliente: string;
      [MCPParam('ID numerico esatto del cliente (numero intero, preso dai candidati restituiti dal tool). NON e'' la ragione sociale, che va in ARagioneSocialeCliente. Se specificato, ignora ARagioneSocialeCliente.',
        TMCPParamPresence.Optional)]
        const AClienteId: string;
      [MCPParam('Codice prodotto (es. PF003) oppure denominazione, anche parziale. Il codice prodotto va indicato SEMPRE qui.', TMCPParamPresence.Optional)]
        const ANomeProdotto: string;
      [MCPParam('ID numerico esatto del prodotto (numero intero, preso dai candidati restituiti dal tool). NON e'' il codice: un codice come PF003 va in ANomeProdotto. Se specificato, ignora ANomeProdotto.', TMCPParamPresence.Optional)]
        const AProdottoId: string;
      [MCPParam('Data iniziale del periodo, formato YYYY-MM-DD.', TMCPParamPresence.Optional)]
        const ADataInizio: string;
      [MCPParam('Data finale del periodo, formato YYYY-MM-DD.', TMCPParamPresence.Optional)]
        const ADataFine: string
    ): TMCPToolResult;
    // Contratti dei tool di questo provider per il pianificatore: schema del
    // risultato, lettura/scrittura, conferma, vincoli sugli input (vedi
    // agente_ai/tool/uContrattiTool.pas e la sezione in fondo a questa unit).
    class function ContrattiTool: TArray<TContrattoTool>;
  end;

implementation

uses
  System.Math;

const
  // Limite prudenziale sulle righe di dettaglio restituite al modello:
  // NON e' una misura per proteggere l'affidabilita' della narrazione
  // (quella e' gia' garantita dal fatto che il dettaglio e' dato
  // strutturato, non testo che il modello deve trascrivere), mE' solo un
  // limite di payload/contesto - una interrogazione troppo larga (es.
  // nessun filtro tranne il periodo) potrebbe restituire migliaia di
  // righe, che non ha senso spedire tutte a un modello locale.
  MAX_RIGHE_DETTAGLIO = 100;

{ Funzioni di supporto, private all'unit }

// Converte una stringa "YYYY-MM-DD" in TDateTime, o restituisce 0
// (sentinella "non specificata") se la stringa e' vuota. Parsing manuale
// (non StrToDate) per essere indipendente dal FormatSettings di sistema,
// che potrebbe non usare il separatore/ordine ISO atteso dal modello.
function ParseDataISO(const AValore: string): TDateTime;
var
  LAnno, LMese, LGiorno: Integer;
  LValore: string;
begin
  LValore := Trim(AValore);
  if LValore = '' then
    Exit(0);

  if (Length(LValore) <> 10) or
     not TryStrToInt(Copy(LValore, 1, 4), LAnno) or
     not TryStrToInt(Copy(LValore, 6, 2), LMese) or
     not TryStrToInt(Copy(LValore, 9, 2), LGiorno) then
    raise Exception.CreateFmt(
      'Data "%s" non valida: formato atteso YYYY-MM-DD.', [AValore]);

  // CONTROLLO DI DIFESA (tappa 13): TryEncodeDate invece di EncodeDate, cosi'
  // una data impossibile (es. 2026-02-30 o mese 13) da' lo stesso messaggio
  // chiaro del formato sbagliato, e non l'errore generico della libreria.
  if not TryEncodeDate(LAnno, LMese, LGiorno, Result) then
    raise Exception.CreateFmt(
      'Data "%s" non valida: il giorno o il mese non esistono (formato atteso YYYY-MM-DD).', [AValore]);
end;

// Converte una stringa in un id positivo, o restituisce 0 (sentinella
// "non specificato") se la stringa e' vuota - stesso principio di
// ParseDataISO sopra. ANomeCampo serve solo per un messaggio d'errore
// leggibile ("cliente_id" o "prodotto_id"), non entra nella logica.
//
// Perche' l'id arriva come stringa e non come parametro Integer nativo:
// in questo progetto TUTTI i parametri esposti da [MCPParam] sono
// stringa (vedi anche ADataInizio/ADataFine sopra), convertiti a mano
// nell'implementazione - e' la stessa scelta gia' fatta per le date, qui
// riusata per coerenza invece di introdurre un secondo idioma per i
// parametri numerici opzionali.
function ParseIdOpzionale(const AValore, ANomeCampo: string): Integer;
var
  LValore: string;
begin
  LValore := Trim(AValore);
  if LValore = '' then
    Exit(0);

  if not TryStrToInt(LValore, Result) or (Result <= 0) then
    raise Exception.CreateFmt(
      '%s "%s" non valido: deve essere un numero intero positivo.', [ANomeCampo, AValore]);
end;

// Tolleranza sull'errore piu' frequente osservato nella valutazione con LLM
// locali: il modello mette in cliente_id / prodotto_id un valore che NON e'
// un id numerico (tipicamente il codice prodotto "PF003", oppure una ragione
// sociale). Invece di rifiutare la chiamata - il che costringe l'utente a
// riformulare - il valore viene trattato come filtro TESTUALE: se AIdOTesto
// non e' un intero positivo lo si sposta in ATestoFiltro (solo se il filtro
// testuale non e' gia' valorizzato) e l'id risulta non specificato. Un id
// numerico valido e' lasciato intatto. Il filtro testuale gestisce sia i
// codici sia le denominazioni (vedi TServizioVendite.RisolviProdotto).
procedure NormalizzaIdOTesto(var AIdOTesto, ATestoFiltro: string);
var
  LValore: string;
  LId: Integer;
begin
  LValore := Trim(AIdOTesto);
  if (LValore <> '') and not (TryStrToInt(LValore, LId) and (LId > 0)) then
  begin
    if Trim(ATestoFiltro) = '' then
      ATestoFiltro := LValore;
    AIdOTesto := '';
  end;
end;

// Un valore testuale singolo (parametro del tool) diventa un array di
// zero o un elemento per TServizioVendite.InterrogaVendite, che lavora
// per array in vista di un futuro supporto a filtri multipli - vedi
// discussione di progetto sul perche' oggi il tool espone un solo valore
// per filtro (il framework MCP non supporta parametri array).
function ValoreSingoloComeArray(const AValore: string): TArray<string>;
begin
  if Trim(AValore) = '' then
    Result := []
  else
    Result := [Trim(AValore)];
end;

function CandidatiClienteToJSON(const ACandidati: TArray<TCandidatoCliente>): TJSONArray;
var
  LCand: TCandidatoCliente;
  LObj: TJSONObject;
begin
  Result := TJSONArray.Create;
  for LCand in ACandidati do
  begin
    LObj := TJSONObject.Create;
    LObj.AddPair('id', TJSONNumber.Create(LCand.ID));
    LObj.AddPair('ragione_sociale', LCand.RagioneSociale);
    LObj.AddPair('partita_iva', LCand.PartitaIva);
    Result.AddElement(LObj);
  end;
end;

function CandidatiProdottoToJSON(const ACandidati: TArray<TCandidatoProdotto>): TJSONArray;
var
  LCand: TCandidatoProdotto;
  LObj: TJSONObject;
begin
  Result := TJSONArray.Create;
  for LCand in ACandidati do
  begin
    LObj := TJSONObject.Create;
    LObj.AddPair('id', TJSONNumber.Create(LCand.ID));
    LObj.AddPair('codice', LCand.Codice);
    LObj.AddPair('denominazione', LCand.Denominazione);
    Result.AddElement(LObj);
  end;
end;

// Costruisce il tool_result per il ramo "richiede_disambiguazione":
// libera anche gli oggetti di risoluzione problematici (la loro
// proprieta' e' passata dal servizio a questa funzione, vedi il
// commento di ownership su TServizioVendite.InterrogaVendite).
function CostruisciRispostaDisambiguazione(
  const AProblemiCliente: TArray<TRisoluzioneCliente>;
  const AProblemiProdotto: TArray<TRisoluzioneProdotto>): string;
var
  LRoot: TJSONObject;
  LProblemi: TJSONArray;
  LProblemaObj: TJSONObject;
  LRisC: TRisoluzioneCliente;
  LRisP: TRisoluzioneProdotto;
begin
  LRoot := TJSONObject.Create;
  try
    LRoot.AddPair('esito', 'richiede_disambiguazione');

    LProblemi := TJSONArray.Create;
    LRoot.AddPair('problemi', LProblemi);

    for LRisC in AProblemiCliente do
    begin
      LProblemaObj := TJSONObject.Create;
      LProblemaObj.AddPair('campo', 'ragione_sociale_cliente');
      LProblemaObj.AddPair('valore_cercato', LRisC.ValoreCercato);
      if LRisC.Esito = erAmbiguo then
        LProblemaObj.AddPair('tipo', 'ambiguo')
      else
        LProblemaObj.AddPair('tipo', 'non_trovato');
      LProblemaObj.AddPair('candidati', CandidatiClienteToJSON(LRisC.Candidati));
      LProblemi.AddElement(LProblemaObj);
      LRisC.Free;
    end;

    for LRisP in AProblemiProdotto do
    begin
      LProblemaObj := TJSONObject.Create;
      LProblemaObj.AddPair('campo', 'nome_prodotto');
      LProblemaObj.AddPair('valore_cercato', LRisP.ValoreCercato);
      if LRisP.Esito = erAmbiguo then
        LProblemaObj.AddPair('tipo', 'ambiguo')
      else
        LProblemaObj.AddPair('tipo', 'non_trovato');
      LProblemaObj.AddPair('candidati', CandidatiProdottoToJSON(LRisP.Candidati));
      LProblemi.AddElement(LProblemaObj);
      LRisP.Free;
    end;

    Result := LRoot.ToJSON;
  finally
    LRoot.Free;
  end;
end;

// Costruisce il tool_result per il ramo "ok": periodo effettivamente
// applicato, aggregato complessivo, dettaglio righe (troncato a
// MAX_RIGHE_DETTAGLIO). Libera ARisultato (e il suo Dettaglio, gestito
// dal distruttore di TRisultatoVendite) prima di uscire.
//
// AFiltroCliente/AFiltroProdotto: True se la richiesta filtrava per cliente/
// prodotto (per id o per nome); AClienteIdEsatto/AProdottoIdEsatto: l'id se
// era stato passato direttamente (<= 0 se no). Servono solo a costruire
// "apertura_vista", vedi sotto.
function CostruisciRispostaOk(ARisultato: TRisultatoVendite;
  AFiltroCliente, AFiltroProdotto: Boolean;
  AClienteIdEsatto, AProdottoIdEsatto: Integer): string;
var
  LParametriVista: TJSONObject;
  LClienteVista, LProdottoVista: Integer;
  LVistaCoerente: Boolean;
  LRoot: TJSONObject;
  LDettaglio: TJSONArray;
  LRigaObj: TJSONObject;
  LRiga: TRigaVenditaDettaglio;
  i, LNumRighe: Integer;
begin
  LRoot := TJSONObject.Create;
  try
    LRoot.AddPair('esito', 'ok');
    if ARisultato.DataInizio <> 0 then
      LRoot.AddPair('periodo_data_inizio', DateToISO8601(ARisultato.DataInizio));

    if ARisultato.DataFine <> 0 then
      LRoot.AddPair('periodo_data_fine', DateToISO8601(ARisultato.DataFine));

    LRoot.AddPair('totale_ordini', TJSONNumber.Create(ARisultato.TotaleOrdini));
    LRoot.AddPair('totale_quantita', TJSONNumber.Create(ARisultato.TotaleQuantita));
    LRoot.AddPair('totale_fatturato', TJSONNumber.Create(ARisultato.TotaleFatturato));

    LDettaglio := TJSONArray.Create;
    LRoot.AddPair('dettaglio', LDettaglio);

    LNumRighe := Min(ARisultato.Dettaglio.Count, MAX_RIGHE_DETTAGLIO);
    for i := 0 to LNumRighe - 1 do
    begin
      LRiga := ARisultato.Dettaglio[i];
      LRigaObj := TJSONObject.Create;
      LRigaObj.AddPair('ordine_id', TJSONNumber.Create(LRiga.OrdineID));
      LRigaObj.AddPair('numero_ordine', LRiga.NumeroOrdine);
      LRigaObj.AddPair('data_ordine', DateToISO8601(LRiga.DataOrdine));
      LRigaObj.AddPair('stato', LRiga.Stato);
      LRigaObj.AddPair('cliente', LRiga.ClienteRagioneSociale);
      LRigaObj.AddPair('prodotto', LRiga.ProdottoDenominazione);
      LRigaObj.AddPair('quantita', TJSONNumber.Create(LRiga.Quantita));
      LRigaObj.AddPair('unita_misura', LRiga.UnitaMisura);
      LRigaObj.AddPair('prezzo_unitario', TJSONNumber.Create(LRiga.PrezzoUnitario));
      LRigaObj.AddPair('importo', TJSONNumber.Create(LRiga.Importo));
      LDettaglio.AddElement(LRigaObj);
    end;

    LRoot.AddPair('dettaglio_troncato', TJSONBool.Create(ARisultato.Dettaglio.Count > MAX_RIGHE_DETTAGLIO));

    // "apertura_vista": la vista Vendite del gestionale con GLI STESSI filtri
    // di questa interrogazione (stessa forma {"vista","parametri"} usata da
    // uRicetteToolProvider). "modalita":"pulsante" = la chat non naviga da
    // sola, mostra un pulsante: qui il risultato e' gia' leggibile in chat,
    // la vista e' un approfondimento che sceglie l'utente.
    // Gli id servono risolti: se il filtro era un NOME, l'id si legge dalla
    // prima riga (il nome e' stato risolto a UN solo cliente/prodotto,
    // altrimenti saremmo nel ramo di disambiguazione). Se non ci sono righe
    // da cui leggerlo il campo non si aggiunge: meglio nessun pulsante che
    // una vista con filtri piu' larghi della domanda.
    LClienteVista := AClienteIdEsatto;
    LProdottoVista := AProdottoIdEsatto;
    LVistaCoerente := True;
    if AFiltroCliente and (LClienteVista <= 0) then
    begin
      if ARisultato.Dettaglio.Count > 0 then
        LClienteVista := ARisultato.Dettaglio[0].ClienteID
      else
        LVistaCoerente := False;
    end;
    if AFiltroProdotto and (LProdottoVista <= 0) then
    begin
      if ARisultato.Dettaglio.Count > 0 then
        LProdottoVista := ARisultato.Dettaglio[0].ProdottoID
      else
        LVistaCoerente := False;
    end;
    if LVistaCoerente then
    begin
      LParametriVista := TJSONObject.Create;
      if LClienteVista > 0 then
        LParametriVista.AddPair('cliente_id', TJSONNumber.Create(LClienteVista));
      if LProdottoVista > 0 then
        LParametriVista.AddPair('prodotto_id', TJSONNumber.Create(LProdottoVista));
      if ARisultato.DataInizio <> 0 then
        LParametriVista.AddPair('data_inizio', FormatDateTime('yyyy-mm-dd', ARisultato.DataInizio));
      if ARisultato.DataFine <> 0 then
        LParametriVista.AddPair('data_fine', FormatDateTime('yyyy-mm-dd', ARisultato.DataFine));
      LRoot.AddPair('apertura_vista', TJSONObject.Create
        .AddPair('vista', 'vendite')
        .AddPair('modalita', 'pulsante')
        .AddPair('parametri', LParametriVista));
    end;

    Result := LRoot.ToJSON;
  finally
    LRoot.Free;
    ARisultato.Free;
  end;
end;

{ TVenditeToolProvider }

function TVenditeToolProvider.GetListVendite(const ARagioneSocialeCliente,
  AClienteId, ANomeProdotto, AProdottoId, ADataInizio, ADataFine: string): TMCPToolResult;
var
  LDataInizio, LDataFine: TDateTime;
  LClienteIdEsatto, LProdottoIdEsatto: Integer;
  LProblemiCliente: TArray<TRisoluzioneCliente>;
  LProblemiProdotto: TArray<TRisoluzioneProdotto>;
  LRisultato: TRisultatoVendite;
  LRagioneSociale, LNomeProdotto, LClienteIdTxt, LProdottoIdTxt: string;
begin
  // Il parsing data/id puo' sollevare un'eccezione se il modello passa un
  // valore fuori formato: e' un errore "di contratto" (il modello non ha
  // rispettato la descrizione del parametro), non un caso di dominio -
  // qui e' accettabile lasciarla propagare, il livello di trasporto MCP
  // la trasformera' in un errore di tool_use che il modello vede e puo'
  // correggere al turno successivo.
  LDataInizio := ParseDataISO(ADataInizio);
  LDataFine := ParseDataISO(ADataFine);

  // CONTROLLO DI DIFESA (tappa 13): periodo al contrario. Prima la query
  // girava lo stesso e tornava zero righe, cioe' "nessuna vendita": una
  // risposta falsa. 0 = data non indicata (vedi ParseDataISO).
  if (LDataInizio <> 0) and (LDataFine <> 0) and (LDataInizio > LDataFine) then
    raise Exception.CreateFmt(
      'Periodo non valido: ADataInizio (%s) e'' successiva ad ADataFine (%s).',
      [ADataInizio, ADataFine]);

  // Copie locali: i parametri sono const. Un "id" non numerico (es. il
  // codice PF003 messo in prodotto_id) diventa filtro testuale, vedi
  // NormalizzaIdOTesto.
  LRagioneSociale := ARagioneSocialeCliente;
  LNomeProdotto := ANomeProdotto;
  LClienteIdTxt := AClienteId;
  LProdottoIdTxt := AProdottoId;
  NormalizzaIdOTesto(LClienteIdTxt, LRagioneSociale);
  NormalizzaIdOTesto(LProdottoIdTxt, LNomeProdotto);

  LClienteIdEsatto := ParseIdOpzionale(LClienteIdTxt, 'AClienteId');
  LProdottoIdEsatto := ParseIdOpzionale(LProdottoIdTxt, 'AProdottoId');

  LRisultato := TServizioVendite.InterrogaVendite(
    ValoreSingoloComeArray(LRagioneSociale), LClienteIdEsatto,
    ValoreSingoloComeArray(LNomeProdotto), LProdottoIdEsatto,
    LDataInizio, LDataFine,
    LProblemiCliente, LProblemiProdotto);

  // Nessun risultato: filtri ambigui o non trovati (vedi
  // CostruisciRispostaDisambiguazione).
  if LRisultato = nil then
    Exit(TMCPToolResult.Text(
      CostruisciRispostaDisambiguazione(LProblemiCliente, LProblemiProdotto)));

  // CostruisciRispostaOk libera LRisultato internamente (vedi il suo
  // commento) - per questo non c'e' nessun Free esplicito qui.
  Result := TMCPToolResult.Text(CostruisciRispostaOk(LRisultato,
    (LClienteIdEsatto > 0) or (Trim(LRagioneSociale) <> ''),
    (LProdottoIdEsatto > 0) or (Trim(LNomeProdotto) <> ''),
    LClienteIdEsatto, LProdottoIdEsatto));
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
  SCHEMA_OUTPUT_GET_LIST_VENDITE =
    '{"type":"object","properties":{"esito":{"type":"string","enum":["ok"]},' +
    '"periodo_data_inizio":{"type":"string"},"periodo_data_fine":{"type":"string"},' +
    '"totale_ordini":{"type":"integer"},"totale_quantita":{"type":"number"},' +
    '"totale_fatturato":{"type":"number"},"dettaglio":{"type":"array","items":{"type":"object",' +
    '"properties":{"ordine_id":{"type":"integer"},"numero_ordine":{"type":"string"},' +
    '"data_ordine":{"type":"string"},"stato":{"type":"string"},"cliente":{"type":"string"},' +
    '"prodotto":{"type":"string"},"quantita":{"type":"number"},"unita_misura":{"type":"string"},' +
    '"prezzo_unitario":{"type":"number"},"importo":{"type":"number"}},"required":["ordine_id",' +
    '"numero_ordine","data_ordine","stato","cliente","prodotto","quantita",' +
    '"unita_misura","prezzo_unitario","importo"]}},"dettaglio_troncato":{"type":"boolean"},' +
    '"apertura_vista":{"type":"object"}},' +
    '"required":["esito","totale_ordini","totale_quantita","totale_fatturato",' +
    '"dettaglio","dettaglio_troncato"]}';

  VINCOLO_DATA =
    '{"format":"date"}';

class function TVenditeToolProvider.ContrattiTool: TArray<TContrattoTool>;
begin
  Result := TArray<TContrattoTool>.Create(
    ContrattoTool('get_list_vendite', etLettura, False,
      SCHEMA_OUTPUT_GET_LIST_VENDITE,
      TArray<TVincoloParametro>.Create(
        VincoloParametro('ADataInizio', VINCOLO_DATA),
        VincoloParametro('ADataFine', VINCOLO_DATA))));
end;

end.
