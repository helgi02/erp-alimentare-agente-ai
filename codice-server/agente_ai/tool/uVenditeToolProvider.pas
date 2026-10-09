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
  // Tool provider MCP dello scenario 2.2 (interrogazione vendite ad hoc). Una classe per
  // scenario. Lo schema JSON lo genera la libreria via RTTI da [MCPTool]/[MCPParam].
  // cliente_id/prodotto_id: dopo la disambiguazione in frontend l'utente clicca un
  // candidato e il turno successivo usa l'id. Sono due parametri opzionali in piu' sullo
  // stesso tool, non un secondo tool. Servono davvero: il match esatto sul nome non
  // garantisce l'unicita' (es. filiali con la stessa ragione sociale), mentre l'id si.
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
    // Contratti dei tool per il pianificatore (vedi uContrattiTool.pas e il fondo di questa
    // unit).
    class function ContrattiTool: TArray<TContrattoTool>;
  end;

implementation

uses
  System.Math;

const
  // Limite di payload/contesto sulle righe di dettaglio: una query troppo larga darebbe
  // migliaia di righe, inutili per un modello locale. Non serve all'affidabilita' della
  // narrazione.
  MAX_RIGHE_DETTAGLIO = 100;

// "YYYY-MM-DD" -> TDateTime, 0 se vuota ("non specificata"). Parsing manuale, indipendente
// dal FormatSettings di sistema.
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

  // TryEncodeDate: una data impossibile (2026-02-30, mese 13) da' lo stesso messaggio
  // chiaro del formato sbagliato.
  if not TryEncodeDate(LAnno, LMese, LGiorno, Result) then
    raise Exception.CreateFmt(
      'Data "%s" non valida: il giorno o il mese non esistono (formato atteso YYYY-MM-DD).', [AValore]);
end;

// Stringa -> id positivo, 0 se vuota. ANomeCampo serve solo al messaggio d'errore. L'id e'
// una stringa perche' tutti i parametri [MCPParam] del progetto lo sono (come le date).
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

// Tolleranza sull'errore piu' frequente dei modelli locali: in cliente_id/prodotto_id
// mettono un codice ("PF003") o una ragione sociale. Invece di rifiutare, se non e' un
// intero positivo il valore passa a ATestoFiltro (se libero) e l'id risulta non
// specificato. Il filtro testuale gestisce codici e denominazioni
// (TServizioVendite.RisolviProdotto).
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

// Un valore singolo diventa un array di 0 o 1 elemento per InterrogaVendite, che lavora per
// array; il framework MCP non supporta parametri array in RTTI.
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

// Tool_result per "richiede_disambiguazione": libera anche gli oggetti di risoluzione
// (ownership passata dal servizio, vedi InterrogaVendite).
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

// Tool_result per "ok": periodo applicato, aggregato, dettaglio troncato a
// MAX_RIGHE_DETTAGLIO. Libera ARisultato prima di uscire. AFiltroCliente/AFiltroProdotto:
// la richiesta filtrava per cliente/prodotto; AClienteIdEsatto/AProdottoIdEsatto: l'id
// passato direttamente (<= 0 se no). Servono a "apertura_vista".
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

    // "apertura_vista": la vista Vendite con gli stessi filtri (forma {"vista","parametri"}
    // come in uRicetteToolProvider). "modalita":"pulsante": la chat mostra un pulsante, la
    // vista e' un approfondimento. Se il filtro era un nome, l'id si legge dalla prima riga
    // (risolto a un solo cliente/prodotto); senza righe il campo non si aggiunge: meglio
    // nessun pulsante che una vista piu' larga della domanda.
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
  // Data o id fuori formato: errore di contratto del modello, lasciato propagare; il
  // livello MCP lo trasforma in errore di tool che il modello puo' correggere.
  LDataInizio := ParseDataISO(ADataInizio);
  LDataFine := ParseDataISO(ADataFine);

  // Periodo al contrario: prima la query tornava zero righe, cioe' un falso "nessuna
  // vendita". 0 = data non indicata.
  if (LDataInizio <> 0) and (LDataFine <> 0) and (LDataInizio > LDataFine) then
    raise Exception.CreateFmt(
      'Periodo non valido: ADataInizio (%s) e'' successiva ad ADataFine (%s).',
      [ADataInizio, ADataFine]);

  // Copie locali: i parametri sono const. Un "id" non numerico (es. PF003) diventa filtro
  // testuale (NormalizzaIdOTesto).
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

  // Filtri ambigui o non trovati.
  if LRisultato = nil then
    Exit(TMCPToolResult.Text(
      CostruisciRispostaDisambiguazione(LProblemiCliente, LProblemiProdotto)));

  // CostruisciRispostaOk libera LRisultato: nessun Free qui.
  Result := TMCPToolResult.Text(CostruisciRispostaOk(LRisultato,
    (LClienteIdEsatto > 0) or (Trim(LRagioneSociale) <> ''),
    (LProdottoIdEsatto > 0) or (Trim(LNomeProdotto) <> ''),
    LClienteIdEsatto, LProdottoIdEsatto));
end;

// Contratti (vedi uContrattiTool.pas). Gli schemi di output descrivono le risposte
// costruite sopra: se cambia una risposta, va cambiato anche lo schema.

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
