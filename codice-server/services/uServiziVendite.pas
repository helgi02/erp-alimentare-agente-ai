unit uServiziVendite;

interface

uses
  System.SysUtils,
  System.DateUtils,
  System.Variants,
  System.Generics.Collections,
  Data.DB,
  DbU;

type
  // Esito della risoluzione di un valore testuale (un elemento di ragione_sociale_cliente o
  // nome_prodotto) sulla rispettiva anagrafica. Il modello non conosce gli ID interni,
  // esprime i filtri come testo: questo passo li traduce in ID prima di costruire la query.
  TEsitoRisoluzione = (erRisolto, erAmbiguo, erNonTrovato);

  // Candidato proposto quando la risoluzione e' ambigua (o anche se risolta): abbastanza
  // informazione per distinguere clienti/prodotti con nome simile.
  TCandidatoCliente = record
    ID: Integer;
    RagioneSociale: string;
    PartitaIva: string;
  end;

  TCandidatoProdotto = record
    ID: Integer;
    Codice: string;
    Denominazione: string;
  end;

  // Risultato di RisolviCliente per un valore. ClienteID e' valido solo se Esito =
  // erRisolto; Candidati e' valorizzato se erAmbiguo (tutti i match, da proporre
  // all'utente) o erRisolto (il singolo match, non obbligatorio da usare).
  TRisoluzioneCliente = class
  public
    ValoreCercato: string;
    Esito: TEsitoRisoluzione;
    ClienteID: Integer;
    Candidati: TArray<TCandidatoCliente>;
  end;

  TRisoluzioneProdotto = class
  public
    ValoreCercato: string;
    Esito: TEsitoRisoluzione;
    ProdottoID: Integer;
    Candidati: TArray<TCandidatoProdotto>;
  end;

  // Riga di dettaglio di un'interrogazione vendite: un prodotto venduto in un ordine che
  // soddisfa i filtri (riga del JOIN ordini_vendita + righe + clienti + prodotti). DTO di
  // sola lettura per il tool_result; porta i nomi (ragione sociale, denominazione) e non
  // solo gli ID, che il modello non saprebbe interpretare.
  TRigaVenditaDettaglio = class
  public
    OrdineID: Integer;
    NumeroOrdine: string;
    DataOrdine: TDateTime;
    Stato: string;
    ClienteID: Integer;
    ClienteRagioneSociale: string;
    ProdottoID: Integer;
    ProdottoDenominazione: string;
    Quantita: Currency;
    UnitaMisura: string;
    PrezzoUnitario: Currency;
    Importo: Currency; // Quantita * PrezzoUnitario, calcolato qui una volta per tutte
  end;

  // Esito positivo di InterrogaVendite: periodo effettivamente applicato (puo' essere il
  // default "ultimo mese", va restituito cosi' il modello lo dichiara), aggregato
  // complessivo e dettaglio. Non aggrega per cliente/prodotto con array di piu' elementi
  // (confronto multi-entita'): incremento successivo, non ancora implementato.
  TRisultatoVendite = class
  public
    DataInizio: TDateTime;
    DataFine: TDateTime;
    TotaleOrdini: Integer;      // ordini DISTINTI coinvolti, non righe
    TotaleQuantita: Currency;
    TotaleFatturato: Currency;
    Dettaglio: TObjectList<TRigaVenditaDettaglio>;

    constructor Create;
    destructor Destroy; override;
  end;

  // Servizio dello scenario 2.2 (interrogazione vendite ad hoc), per il tool
  // get_list_vendite: 1) risolve i filtri testuali (cliente, prodotto) sulle anagrafiche
  // gestendo l'ambiguita'; 2) costruisce ed esegue la query aggregata con WHERE dinamica
  // per qualunque combinazione di filtri opzionali. E' l'unica classe che sa costruire la
  // query, cosi' il tool resta uno solo (principio "tool generico e parametrico").
  TServizioVendite = class
  private
    // Placeholder posizionali ":pN" per un IN (...) di lunghezza variabile. AStartIndex e'
    // il numero di parametri gia' presenti in Params: TDB.getQueryResult lega per
    // posizione, quindi il nome conta solo per essere univoco.
    class function BuildPlaceholders(ACount, AStartIndex: Integer): string;

    // Query aggregata con WHERE dinamica sugli ID risolti: qui non c'e' piu' ambiguita'.
    // ANessunFiltro (vedi InterrogaVendite): se True (cliente, prodotto e periodo assenti)
    // niente WHERE dinamica, solo le ultime vendite senza vincolo di periodo, limitate a
    // MAX_RIGHE_QUERY. Se False, WHERE dinamica su tutti i filtri (periodo incluso, gia'
    // col default "ultimo mese") con lo stesso LIMIT.
    class function EseguiQueryVendite(
      const AClienteIDs, AProdottoIDs: TArray<Integer>;
      ADataInizio, ADataFine: TDateTime;
      ANessunFiltro: Boolean): TRisultatoVendite;
  public
    // Risolve un valore sull'anagrafica clienti: prima match esatto (ILIKE senza jolly), se
    // nulla ripiega sul parziale (ILIKE '%valore%'). L'esatto ha la precedenza assoluta: se
    // l'utente ha scritto il nome preciso (es. da una disambiguazione) non si
    // riproporrebbero altri candidati.
    class function RisolviCliente(const ANome: string): TRisoluzioneCliente;

    // Come sopra per i prodotti: l'esatto su codice e denominazione (si puo' usare l'uno o
    // l'altra), il parziale solo sulla denominazione (un codice e' un identificativo
    // breve).
    class function RisolviProdotto(const ANome: string): TRisoluzioneProdotto;

    // Orchestratore, chiamato dal tool provider. Risolve tutti i nomi; se anche uno solo e'
    // ambiguo o non trovato l'intera richiesta si ferma (Result nil) e tutti i problemi
    // tornano in AProblemiCliente/AProblemiProdotto: una query parziale presentata come
    // completa e' peggio di un rifiuto.
    // AClienteIdEsatto/AProdottoIdEsatto: 0 = non specificato. Se > 0 hanno la precedenza
    // sull'array di nomi, ignorato: niente ILIKE, quindi niente nuova ambiguita'. Per il
    // secondo giro dopo una disambiguazione (l'utente ha scelto un id).
    // ADataInizio/ADataFine = 0: default "ultimo mese" (oggi meno un mese, fino a oggi); il
    // periodo applicato torna sempre in TRisultatoVendite.
    // Ownership: se la risoluzione fallisce gli oggetti in
    // AProblemiCliente/AProblemiProdotto passano al chiamante, che li libera. Se riesce, il
    // chiamante libera il TRisultatoVendite (il Dettaglio lo libera il distruttore).
    class function InterrogaVendite(
      const ANomiCliente: TArray<string>;
      AClienteIdEsatto: Integer;
      const ANomiProdotto: TArray<string>;
      AProdottoIdEsatto: Integer;
      ADataInizio, ADataFine: TDateTime;
      out AProblemiCliente: TArray<TRisoluzioneCliente>;
      out AProblemiProdotto: TArray<TRisoluzioneProdotto>): TRisultatoVendite;
  end;

implementation

constructor TRisultatoVendite.Create;
begin
  inherited Create;
  Dettaglio := TObjectList<TRigaVenditaDettaglio>.Create(True); // possiede le righe
end;

destructor TRisultatoVendite.Destroy;
begin
  Dettaglio.Free;
  inherited;
end;

class function TServizioVendite.BuildPlaceholders(ACount, AStartIndex: Integer): string;
var
  i: Integer;
  LNomi: TArray<string>;
begin
  SetLength(LNomi, ACount);
  for i := 0 to ACount - 1 do
    LNomi[i] := ':p' + IntToStr(AStartIndex + i);
  Result := string.Join(', ', LNomi);
end;

class function TServizioVendite.RisolviCliente(const ANome: string): TRisoluzioneCliente;
var
  LNome: string;
  LCandidati: TList<TCandidatoCliente>;

  procedure EseguiRicerca(const APattern: string);
  var
    LAutoQuery: TAutoQuery;
    LCandidato: TCandidatoCliente;
  begin
    LAutoQuery := TDB.GetInstance.getQueryResult(
      'SELECT id, ragione_sociale, partita_iva FROM clienti ' +
      'WHERE ragione_sociale ILIKE :pattern ORDER BY ragione_sociale',
      [APattern]);
    try
      while not LAutoQuery.Query.Eof do
      begin
        LCandidato.ID             := LAutoQuery.Query.FieldByName('id').AsInteger;
        LCandidato.RagioneSociale := LAutoQuery.Query.FieldByName('ragione_sociale').AsString;
        LCandidato.PartitaIva     := LAutoQuery.Query.FieldByName('partita_iva').AsString;
        LCandidati.Add(LCandidato);
        LAutoQuery.Query.Next;
      end;
    finally
      LAutoQuery.Free;
    end;
  end;

begin
  LNome := Trim(ANome);

  Result := TRisoluzioneCliente.Create;
  Result.ValoreCercato := LNome;

  if LNome = '' then
  begin
    // Guardia: ILIKE '%' + '' + '%' = '%%' troverebbe tutti i clienti. Un elemento vuoto e'
    // un errore di chi chiama: lo si tratta come "non trovato" e non come falso match
    // universale.
    Result.Esito := erNonTrovato;
    Exit;
  end;

  LCandidati := TList<TCandidatoCliente>.Create;
  try
    // Passo 1: match esatto (ILIKE senza '%' e' un'uguaglianza senza distinzione di
    // maiuscole).
    EseguiRicerca(LNome);

    // Passo 2: solo se l'esatto non trova nulla, il parziale ("Rossi" invece di "Rossi
    // Srl").
    if LCandidati.Count = 0 then
      EseguiRicerca('%' + LNome + '%');

    case LCandidati.Count of
      0: Result.Esito := erNonTrovato;
      1:
        begin
          Result.Esito := erRisolto;
          Result.ClienteID := LCandidati[0].ID;
          Result.Candidati := LCandidati.ToArray;
        end;
    else
      Result.Esito := erAmbiguo;
      Result.Candidati := LCandidati.ToArray;
    end;
  finally
    LCandidati.Free;
  end;
end;

class function TServizioVendite.RisolviProdotto(const ANome: string): TRisoluzioneProdotto;
var
  LNome: string;
  LCandidati: TList<TCandidatoProdotto>;

  procedure EseguiRicerca(const ASQL: string; const AParam: string);
  var
    LAutoQuery: TAutoQuery;
    LCandidato: TCandidatoProdotto;
  begin
    LAutoQuery := TDB.GetInstance.getQueryResult(ASQL, [AParam]);
    try
      while not LAutoQuery.Query.Eof do
      begin
        LCandidato.ID            := LAutoQuery.Query.FieldByName('id').AsInteger;
        LCandidato.Codice        := LAutoQuery.Query.FieldByName('codice').AsString;
        LCandidato.Denominazione := LAutoQuery.Query.FieldByName('denominazione').AsString;
        LCandidati.Add(LCandidato);
        LAutoQuery.Query.Next;
      end;
    finally
      LAutoQuery.Free;
    end;
  end;

begin
  LNome := Trim(ANome);

  Result := TRisoluzioneProdotto.Create;
  Result.ValoreCercato := LNome;

  if LNome = '' then
  begin
    // Come in RisolviCliente.
    Result.Esito := erNonTrovato;
    Exit;
  end;

  LCandidati := TList<TCandidatoProdotto>.Create;
  try
    // Passo 1: match esatto su codice o denominazione.
    EseguiRicerca(
      'SELECT id, codice, denominazione FROM anagrafiche_prodotti_finiti ' +
      'WHERE codice ILIKE :val OR denominazione ILIKE :val ORDER BY denominazione',
      LNome);

    // Passo 2: parziale solo sulla denominazione (un codice non si cerca "contenuto in" un
    // altro).
    if LCandidati.Count = 0 then
      EseguiRicerca(
        'SELECT id, codice, denominazione FROM anagrafiche_prodotti_finiti ' +
        'WHERE denominazione ILIKE :val ORDER BY denominazione',
        '%' + LNome + '%');

    case LCandidati.Count of
      0: Result.Esito := erNonTrovato;
      1:
        begin
          Result.Esito := erRisolto;
          Result.ProdottoID := LCandidati[0].ID;
          Result.Candidati := LCandidati.ToArray;
        end;
    else
      Result.Esito := erAmbiguo;
      Result.Candidati := LCandidati.ToArray;
    end;
  finally
    LCandidati.Free;
  end;
end;

class function TServizioVendite.EseguiQueryVendite(
  const AClienteIDs, AProdottoIDs: TArray<Integer>;
  ADataInizio, ADataFine: TDateTime;
  ANessunFiltro: Boolean): TRisultatoVendite;
const
  // I JOIN a clienti e anagrafiche_prodotti_finiti ci sono sempre: servono a restituire i
  // nomi, di cui il modello ha bisogno. Varia solo il WHERE.
  SQL_BASE =
    'SELECT ov.id AS ordine_id, ov.numero_ordine, ov.data_ordine, ov.stato, ' +
    'c.id AS cliente_id, c.ragione_sociale, ' +
    'apf.id AS prodotto_id, apf.denominazione, ' +
    'ovr.quantita, ovr.unita_misura, ovr.prezzo_unitario ' +
    'FROM ordini_vendita ov ' +
    'JOIN clienti c ON c.id = ov.cliente_id ' +
    'JOIN ordini_vendita_righe ovr ON ovr.ordine_vendita_id = ov.id ' +
    'JOIN anagrafiche_prodotti_finiti apf ON apf.id = ovr.prodotto_finito_id ';
  // LIMIT sempre in coda, con o senza filtri, per non dare al modello un numero arbitrario
  // di righe.
  MAX_RIGHE_QUERY = 100;
var
  LWhere: TList<string>;
  LParams: TList<Variant>;
  LSQL: string;
  i: Integer;
  LAutoQuery: TAutoQuery;
  LRiga: TRigaVenditaDettaglio;
  LOrdiniDistinti: TList<Integer>;
begin
  Result := TRisultatoVendite.Create;
  Result.DataInizio := ADataInizio;
  Result.DataFine := ADataFine;

  LWhere := TList<string>.Create;
  LParams := TList<Variant>.Create;
  LOrdiniDistinti := TList<Integer>.Create;
  try
    if ANessunFiltro then
    begin
      // Nessun filtro: niente WHERE dinamica, solo l'esclusione degli annullati e il LIMIT.
      // Nessun parametro da legare.
      LSQL := SQL_BASE +
        'WHERE ov.stato <> ''annullato'' ' +
        'ORDER BY ov.data_ordine DESC ' +
        'LIMIT ' + IntToStr(MAX_RIGHE_QUERY);

      LAutoQuery := TDB.GetInstance.getQueryResult(LSQL);
    end
    else
    begin
      // Un ordine annullato non e' una vendita: escluso sempre. Interrogare gli annullati
      // sara' un tool o parametro a parte, non una variante di get_list_vendite.
      LWhere.Add('ov.stato <> ''annullato''');

      // Il periodo qui e' sempre applicato: InterrogaVendite ha gia' risolto il default
      // "ultimo mese" (ANessunFiltro = False implica almeno un filtro).
      LWhere.Add('ov.data_ordine BETWEEN :data_inizio AND :data_fine');
      LParams.Add(ADataInizio);
      LParams.Add(ADataFine);

      if Length(AClienteIDs) > 0 then
      begin
        LWhere.Add('c.id IN (' + BuildPlaceholders(Length(AClienteIDs), LParams.Count) + ')');
        for i := 0 to High(AClienteIDs) do
          LParams.Add(AClienteIDs[i]);
      end;

      if Length(AProdottoIDs) > 0 then
      begin
        LWhere.Add('apf.id IN (' + BuildPlaceholders(Length(AProdottoIDs), LParams.Count) + ')');
        for i := 0 to High(AProdottoIDs) do
          LParams.Add(AProdottoIDs[i]);
      end;

      LSQL := SQL_BASE + 'WHERE ' + string.Join(' AND ', LWhere.ToArray) +
        ' ORDER BY ov.data_ordine DESC LIMIT ' + IntToStr(MAX_RIGHE_QUERY);

      LAutoQuery := TDB.GetInstance.getQueryResult(LSQL, LParams.ToArray);
    end;

    try
      while not LAutoQuery.Query.Eof do
      begin
        LRiga := TRigaVenditaDettaglio.Create;
        LRiga.OrdineID              := LAutoQuery.Query.FieldByName('ordine_id').AsInteger;
        LRiga.NumeroOrdine          := LAutoQuery.Query.FieldByName('numero_ordine').AsString;
        LRiga.DataOrdine            := LAutoQuery.Query.FieldByName('data_ordine').AsDateTime;
        LRiga.Stato                 := LAutoQuery.Query.FieldByName('stato').AsString;
        LRiga.ClienteID             := LAutoQuery.Query.FieldByName('cliente_id').AsInteger;
        LRiga.ClienteRagioneSociale := LAutoQuery.Query.FieldByName('ragione_sociale').AsString;
        LRiga.ProdottoID            := LAutoQuery.Query.FieldByName('prodotto_id').AsInteger;
        LRiga.ProdottoDenominazione := LAutoQuery.Query.FieldByName('denominazione').AsString;
        LRiga.Quantita              := LAutoQuery.Query.FieldByName('quantita').AsCurrency;
        LRiga.UnitaMisura           := LAutoQuery.Query.FieldByName('unita_misura').AsString;
        LRiga.PrezzoUnitario        := LAutoQuery.Query.FieldByName('prezzo_unitario').AsCurrency;
        LRiga.Importo               := LRiga.Quantita * LRiga.PrezzoUnitario;

        Result.Dettaglio.Add(LRiga);
        Result.TotaleQuantita  := Result.TotaleQuantita + LRiga.Quantita;
        Result.TotaleFatturato := Result.TotaleFatturato + LRiga.Importo;
        if not LOrdiniDistinti.Contains(LRiga.OrdineID) then
          LOrdiniDistinti.Add(LRiga.OrdineID);

        LAutoQuery.Query.Next;
      end;
    finally
      LAutoQuery.Free;
    end;

    Result.TotaleOrdini := LOrdiniDistinti.Count;
  finally
    LWhere.Free;
    LParams.Free;
    LOrdiniDistinti.Free;
  end;
end;

class function TServizioVendite.InterrogaVendite(
  const ANomiCliente: TArray<string>;
  AClienteIdEsatto: Integer;
  const ANomiProdotto: TArray<string>;
  AProdottoIdEsatto: Integer;
  ADataInizio, ADataFine: TDateTime;
  out AProblemiCliente: TArray<TRisoluzioneCliente>;
  out AProblemiProdotto: TArray<TRisoluzioneProdotto>): TRisultatoVendite;
var
  LClienteIDs, LProdottoIDs: TList<Integer>;
  LProblemiCliente: TList<TRisoluzioneCliente>;
  LProblemiProdotto: TList<TRisoluzioneProdotto>;
  LRisoluzioneC: TRisoluzioneCliente;
  LRisoluzioneP: TRisoluzioneProdotto;
  LNome: string;
  LNessunFiltro: Boolean;
begin
  Result := nil;
  AProblemiCliente := [];
  AProblemiProdotto := [];

  // Richiesta senza alcun filtro (cliente, prodotto, periodo), calcolato prima del default
  // "ultimo mese": dopo, le date non sarebbero piu' 0 e il flag risulterebbe sempre False.
  // Se True, EseguiQueryVendite non usa WHERE dinamica ne' periodo ("ultime N vendite").
  // AClienteIdEsatto/AProdottoIdEsatto contano come filtri, come gli array di nomi.
  LNessunFiltro :=
    (Length(ANomiCliente) = 0) and (AClienteIdEsatto = 0) and
    (Length(ANomiProdotto) = 0) and (AProdottoIdEsatto = 0) and
    (ADataInizio = 0) and
    (ADataFine = 0);

  LClienteIDs := TList<Integer>.Create;
  LProdottoIDs := TList<Integer>.Create;
  // Questi non possiedono gli oggetti contenuti: i risolti si liberano subito (l'ID e'
  // estratto), i problematici passano al chiamante tramite
  // AProblemiCliente/AProblemiProdotto. Si libera solo il contenitore, mai gli oggetti
  // (vedi finally).
  LProblemiCliente := TList<TRisoluzioneCliente>.Create;
  LProblemiProdotto := TList<TRisoluzioneProdotto>.Create;
  try
    // 1) Risoluzione. Se c'e' l'id esatto ha la precedenza e si salta
    // RisolviCliente/RisolviProdotto: elimina l'ambiguita' per costruzione, anche nel caso
    // raro di omonimia perfetta fra due anagrafiche.
    if AClienteIdEsatto > 0 then
      LClienteIDs.Add(AClienteIdEsatto)
    else
      for LNome in ANomiCliente do
      begin
        LRisoluzioneC := RisolviCliente(LNome);
        if LRisoluzioneC.Esito = erRisolto then
        begin
          LClienteIDs.Add(LRisoluzioneC.ClienteID);
          LRisoluzioneC.Free;
        end
        else
          LProblemiCliente.Add(LRisoluzioneC);
      end;

    if AProdottoIdEsatto > 0 then
      LProdottoIDs.Add(AProdottoIdEsatto)
    else
      for LNome in ANomiProdotto do
      begin
        LRisoluzioneP := RisolviProdotto(LNome);
        if LRisoluzioneP.Esito = erRisolto then
        begin
          LProdottoIDs.Add(LRisoluzioneP.ProdottoID);
          LRisoluzioneP.Free;
        end
        else
          LProblemiProdotto.Add(LRisoluzioneP);
      end;

    // Se un solo filtro e' ambiguo o non trovato l'intera richiesta si ferma e non parte
    // nessuna query. Si riportano tutti i problemi insieme, cosi' l'utente li risolve in un
    // turno solo.
    if (LProblemiCliente.Count > 0) or (LProblemiProdotto.Count > 0) then
    begin
      AProblemiCliente := LProblemiCliente.ToArray;
      AProblemiProdotto := LProblemiProdotto.ToArray;
      Exit; // Result resta nil
    end;

    // 2) Periodo: default "ultimo mese" se non specificato (0 = non valorizzato). Solo se
    // esiste almeno un filtro: senza filtri non si restringe all'ultimo mese un risultato
    // che l'utente non ha vincolato (EseguiQueryVendite ignora comunque le date).
    if not LNessunFiltro then
    begin
      if ADataFine = 0 then
        ADataFine := Now;
      if ADataInizio = 0 then
        ADataInizio := IncMonth(ADataFine, -1);
    end;

    // 3) Query. Nessun filtro: ultime MAX_RIGHE_QUERY vendite, senza WHERE dinamica ne'
    // periodo. Almeno un filtro: WHERE dinamica su cliente/prodotto/periodo, con lo stesso
    // LIMIT.
    Result := EseguiQueryVendite(LClienteIDs.ToArray, LProdottoIDs.ToArray,
      ADataInizio, ADataFine, LNessunFiltro);
  finally
    LClienteIDs.Free;
    LProdottoIDs.Free;
    LProblemiCliente.Free;
    LProblemiProdotto.Free;
  end;
end;

end.
