unit uServiziGiacenza;

interface

uses
  System.SysUtils,
  FireDAC.Comp.Client,
  DbU,
  uModelLottoMateriaPrima,
  uModelLottoSemilavorato,
  uModelLottoProdottoFinito,
  uModelConsumoProduzioneSemilavorato,
  uModelConsumoProduzioneProdottoFinito;

type
  // Layer Services per la giacenza di magazzino: e' la "fondamenta"
  // condivisa da cui dipendono sia lo scenario di ritiro/richiamo (per
  // sapere quanto di un lotto e' ancora disponibile) sia, in futuro, lo
  // scenario vendite (per verificare/allocare la giacenza su un ordine).
  //
  // Perche' questa logica non sta nei model ne' nei tool MCP: le
  // operazioni qui sotto attraversano SEMPRE almeno due tabelle (il
  // lotto componente consumato + la riga di consumo che lo registra), e
  // in un dominio alimentare devono essere atomiche — non puo' mai
  // restare scritto un consumo senza il corrispondente scarico di
  // giacenza, ne' viceversa. I model restano il posto giusto per le
  // invarianti di UNA singola entita' (vedi TNonConformita.EnsureStatoValido
  // e simili); questa classe invece orchestra piu' model in un'unica
  // transazione tramite TDB.ExecuteInTransaction.
  //
  // Nota di progetto (transazioni multi-model): TDB.getQueryResult /
  // executeQuery aprono ciascuno una connessione pooled propria, quindi
  // due chiamate consecutive a Insert/Update di model diversi NON
  // condividono una transazione. Per risolverlo, ai model coinvolti qui
  // (TLottoMateriaPrima, TLottoSemilavorato, TConsumoProduzione*) sono
  // stati aggiunti metodi/overload che accettano una TFDConnection
  // gia' aperta, cosi' questa classe puo' passare la STESSA connessione
  // (ottenuta da TDB.ExecuteInTransaction) a piu' operazioni di scrittura
  // e farle commit/rollback insieme.
  TServizioGiacenza = class
  public
    // --- Ricevimento / produzione -----------------------------------
    // Applicano la regola di dominio "la giacenza disponibile di un
    // lotto appena arrivato/prodotto parte uguale alla quantita' totale"
    // — regola che prima era lasciata a un commento nei model (vedi
    // Insert di TLottoMateriaPrima/TLottoSemilavorato/TLottoProdottoFinito,
    // "e' responsabilita' del chiamante impostare QuantitaDisponibile").
    // Sono operazioni su una singola tabella: non serve una transazione
    // esplicita, il singolo Insert e' gia' atomico di suo.
    class function RegistraRicevimentoMateriaPrima(ALotto: TLottoMateriaPrima): Integer;
    class function RegistraProduzioneSemilavorato(ALotto: TLottoSemilavorato): Integer;
    class function RegistraProduzioneProdottoFinito(ALotto: TLottoProdottoFinito): Integer;

    // --- Giacenza disponibile aggregata -----------------------------
    // Somma di QuantitaDisponibile su tutti i lotti di un'anagrafica:
    // "quanto ne ho ancora, in totale, a prescindere dal lotto". Usata
    // sia dallo scenario di ritiro/richiamo sia dalle interrogazioni di
    // vendita ad hoc (scenario 2).
    class function GiacenzaDisponibileMateriaPrima(AMateriaPrimaID: Integer): Currency;
    class function GiacenzaDisponibileSemilavorato(ASemilavoratoID: Integer): Currency;
    class function GiacenzaDisponibileProdottoFinito(AProdottoFinitoID: Integer): Currency;

    // --- Consumo di produzione (atomico) ----------------------------
    // Le 4 combinazioni possibili, speculari ai due pattern XOR gia'
    // presenti nello schema (componente = materia prima o semilavorato;
    // destinazione = semilavorato o prodotto finito). Ognuna, in
    // un'unica transazione: decrementa la giacenza del lotto componente
    // e registra la riga di consumo. Se la giacenza non basta, nessuna
    // delle due scritture viene applicata (eccezione + rollback
    // automatico di TDB.ExecuteInTransaction). Restituiscono l'id della
    // riga di consumo creata.
    class function ConsumaMateriaPrimaPerSemilavorato(
      ALottoSemilavoratoDestinazioneID, ALottoMateriaPrimaComponenteID: Integer;
      AQuantitaConsumata: Currency): Integer;
    class function ConsumaSemilavoratoPerSemilavorato(
      ALottoSemilavoratoDestinazioneID, ALottoSemilavoratoFiglioComponenteID: Integer;
      AQuantitaConsumata: Currency): Integer;
    class function ConsumaMateriaPrimaPerProdottoFinito(
      ALottoProdottoFinitoDestinazioneID, ALottoMateriaPrimaComponenteID: Integer;
      AQuantitaConsumata: Currency): Integer;
    class function ConsumaSemilavoratoPerProdottoFinito(
      ALottoProdottoFinitoDestinazioneID, ALottoSemilavoratoComponenteID: Integer;
      AQuantitaConsumata: Currency): Integer;
  end;

implementation

const
  // COALESCE a 0: un'anagrafica senza lotti (o con soli lotti esauriti)
  // deve restituire "zero disponibile", non NULL.
  SQL_GIACENZA_MATERIA_PRIMA =
    'SELECT COALESCE(SUM(quantita_disponibile), 0) AS giacenza ' +
    'FROM lotti_materie_prime WHERE materia_prima_id = :materia_prima_id';

  SQL_GIACENZA_SEMILAVORATO =
    'SELECT COALESCE(SUM(quantita_disponibile), 0) AS giacenza ' +
    'FROM lotti_semilavorati WHERE semilavorato_id = :semilavorato_id';

  SQL_GIACENZA_PRODOTTO_FINITO =
    'SELECT COALESCE(SUM(quantita_disponibile), 0) AS giacenza ' +
    'FROM lotti_prodotti_finiti WHERE prodotto_finito_id = :prodotto_finito_id';

{ TServizioGiacenza }

class function TServizioGiacenza.RegistraRicevimentoMateriaPrima(
  ALotto: TLottoMateriaPrima): Integer;
begin
  ALotto.QuantitaDisponibile := ALotto.Quantita;
  Result := ALotto.Insert;
end;

class function TServizioGiacenza.RegistraProduzioneSemilavorato(
  ALotto: TLottoSemilavorato): Integer;
begin
  ALotto.QuantitaDisponibile := ALotto.Quantita;
  Result := ALotto.Insert;
end;

class function TServizioGiacenza.RegistraProduzioneProdottoFinito(
  ALotto: TLottoProdottoFinito): Integer;
begin
  ALotto.QuantitaDisponibile := ALotto.Quantita;
  Result := ALotto.Insert;
end;

class function TServizioGiacenza.GiacenzaDisponibileMateriaPrima(
  AMateriaPrimaID: Integer): Currency;
var
  LAutoQuery: TAutoQuery;
begin
  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_GIACENZA_MATERIA_PRIMA, [AMateriaPrimaID]);
  try
    Result := LAutoQuery.Query.FieldByName('giacenza').AsCurrency;
  finally
    LAutoQuery.Free;
  end;
end;

class function TServizioGiacenza.GiacenzaDisponibileSemilavorato(
  ASemilavoratoID: Integer): Currency;
var
  LAutoQuery: TAutoQuery;
begin
  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_GIACENZA_SEMILAVORATO, [ASemilavoratoID]);
  try
    Result := LAutoQuery.Query.FieldByName('giacenza').AsCurrency;
  finally
    LAutoQuery.Free;
  end;
end;

class function TServizioGiacenza.GiacenzaDisponibileProdottoFinito(
  AProdottoFinitoID: Integer): Currency;
var
  LAutoQuery: TAutoQuery;
begin
  LAutoQuery := TDB.GetInstance.getQueryResult(
    SQL_GIACENZA_PRODOTTO_FINITO, [AProdottoFinitoID]);
  try
    Result := LAutoQuery.Query.FieldByName('giacenza').AsCurrency;
  finally
    LAutoQuery.Free;
  end;
end;

class function TServizioGiacenza.ConsumaMateriaPrimaPerSemilavorato(
  ALottoSemilavoratoDestinazioneID, ALottoMateriaPrimaComponenteID: Integer;
  AQuantitaConsumata: Currency): Integer;
var
  LNuovoID: Integer;
begin
  LNuovoID := 0;

  TDB.GetInstance.ExecuteInTransaction(
    procedure(AConn: TFDConnection)
    var
      LConsumo: TConsumoProduzioneSemilavorato;
    begin
      // Se la giacenza non basta, DecrementaQuantitaDisponibile non
      // tocca nessuna riga e restituisce False: solleviamo un'eccezione
      // per far scattare il rollback automatico di ExecuteInTransaction
      // (nessun consumo viene registrato senza il relativo scarico).
      if not TLottoMateriaPrima.DecrementaQuantitaDisponibile(
        ALottoMateriaPrimaComponenteID, AQuantitaConsumata, AConn) then
        raise Exception.CreateFmt(
          'Giacenza disponibile insufficiente sul lotto materia prima id=%d ' +
          'per consumare %s unita''.',
          [ALottoMateriaPrimaComponenteID, CurrToStr(AQuantitaConsumata)]);

      LConsumo := TConsumoProduzioneSemilavorato.Create;
      try
        LConsumo.LottoSemilavoratoID := ALottoSemilavoratoDestinazioneID;
        LConsumo.LottoMateriaPrimaID := ALottoMateriaPrimaComponenteID;
        LConsumo.QuantitaConsumata   := AQuantitaConsumata;
        LNuovoID := LConsumo.Insert(AConn);
      finally
        LConsumo.Free;
      end;
    end);

  Result := LNuovoID;
end;

class function TServizioGiacenza.ConsumaSemilavoratoPerSemilavorato(
  ALottoSemilavoratoDestinazioneID, ALottoSemilavoratoFiglioComponenteID: Integer;
  AQuantitaConsumata: Currency): Integer;
var
  LNuovoID: Integer;
begin
  LNuovoID := 0;

  // Distinta base multi-livello: qui il componente consumato e' a sua
  // volta un lotto di semilavorato (LottoSemilavoratoFiglioID), non una
  // materia prima. Stessa logica di atomicita' del metodo gemello sopra.
  TDB.GetInstance.ExecuteInTransaction(
    procedure(AConn: TFDConnection)
    var
      LConsumo: TConsumoProduzioneSemilavorato;
    begin
      if not TLottoSemilavorato.DecrementaQuantitaDisponibile(
        ALottoSemilavoratoFiglioComponenteID, AQuantitaConsumata, AConn) then
        raise Exception.CreateFmt(
          'Giacenza disponibile insufficiente sul lotto semilavorato id=%d ' +
          'per consumare %s unita''.',
          [ALottoSemilavoratoFiglioComponenteID, CurrToStr(AQuantitaConsumata)]);

      LConsumo := TConsumoProduzioneSemilavorato.Create;
      try
        LConsumo.LottoSemilavoratoID       := ALottoSemilavoratoDestinazioneID;
        LConsumo.LottoSemilavoratoFiglioID := ALottoSemilavoratoFiglioComponenteID;
        LConsumo.QuantitaConsumata         := AQuantitaConsumata;
        LNuovoID := LConsumo.Insert(AConn);
      finally
        LConsumo.Free;
      end;
    end);

  Result := LNuovoID;
end;

class function TServizioGiacenza.ConsumaMateriaPrimaPerProdottoFinito(
  ALottoProdottoFinitoDestinazioneID, ALottoMateriaPrimaComponenteID: Integer;
  AQuantitaConsumata: Currency): Integer;
var
  LNuovoID: Integer;
begin
  LNuovoID := 0;

  TDB.GetInstance.ExecuteInTransaction(
    procedure(AConn: TFDConnection)
    var
      LConsumo: TConsumoProduzioneProdottoFinito;
    begin
      if not TLottoMateriaPrima.DecrementaQuantitaDisponibile(
        ALottoMateriaPrimaComponenteID, AQuantitaConsumata, AConn) then
        raise Exception.CreateFmt(
          'Giacenza disponibile insufficiente sul lotto materia prima id=%d ' +
          'per consumare %s unita''.',
          [ALottoMateriaPrimaComponenteID, CurrToStr(AQuantitaConsumata)]);

      LConsumo := TConsumoProduzioneProdottoFinito.Create;
      try
        LConsumo.LottoProdottoFinitoID := ALottoProdottoFinitoDestinazioneID;
        LConsumo.LottoMateriaPrimaID   := ALottoMateriaPrimaComponenteID;
        LConsumo.QuantitaConsumata     := AQuantitaConsumata;
        LNuovoID := LConsumo.Insert(AConn);
      finally
        LConsumo.Free;
      end;
    end);

  Result := LNuovoID;
end;

class function TServizioGiacenza.ConsumaSemilavoratoPerProdottoFinito(
  ALottoProdottoFinitoDestinazioneID, ALottoSemilavoratoComponenteID: Integer;
  AQuantitaConsumata: Currency): Integer;
var
  LNuovoID: Integer;
begin
  LNuovoID := 0;

  TDB.GetInstance.ExecuteInTransaction(
    procedure(AConn: TFDConnection)
    var
      LConsumo: TConsumoProduzioneProdottoFinito;
    begin
      if not TLottoSemilavorato.DecrementaQuantitaDisponibile(
        ALottoSemilavoratoComponenteID, AQuantitaConsumata, AConn) then
        raise Exception.CreateFmt(
          'Giacenza disponibile insufficiente sul lotto semilavorato id=%d ' +
          'per consumare %s unita''.',
          [ALottoSemilavoratoComponenteID, CurrToStr(AQuantitaConsumata)]);

      LConsumo := TConsumoProduzioneProdottoFinito.Create;
      try
        LConsumo.LottoProdottoFinitoID := ALottoProdottoFinitoDestinazioneID;
        LConsumo.LottoSemilavoratoID   := ALottoSemilavoratoComponenteID;
        LConsumo.QuantitaConsumata     := AQuantitaConsumata;
        LNuovoID := LConsumo.Insert(AConn);
      finally
        LConsumo.Free;
      end;
    end);

  Result := LNuovoID;
end;

end.
