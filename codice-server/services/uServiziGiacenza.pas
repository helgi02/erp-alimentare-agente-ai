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
  // Giacenza di magazzino: base condivisa del richiamo (quanto di un lotto e' ancora
  // disponibile) e, in futuro, delle vendite (allocare la giacenza su un ordine).
  // Sta qui e non nei model o nei tool MCP perche' le operazioni toccano sempre due tabelle
  // (il lotto componente + la riga di consumo) e devono essere atomiche: mai un consumo
  // senza scarico, ne' viceversa. I model tengono le invarianti di una sola entita'; questa
  // classe orchestra piu' model in una transazione (TDB.ExecuteInTransaction).
  // TDB.getQueryResult/executeQuery aprono ciascuno una connessione pooled propria, quindi
  // due insert di model diversi non condividono una transazione. Per questo
  // TLottoMateriaPrima, TLottoSemilavorato e TConsumoProduzione* hanno overload che
  // accettano una TFDConnection gia' aperta: la stessa connessione fa commit/rollback di
  // tutto.
  TServizioGiacenza = class
  public
    // Ricevimento e produzione: la giacenza disponibile di un lotto appena arrivato o
    // prodotto parte uguale alla quantita' totale (prima era un commento nei model).
    // Singola tabella: il singolo Insert e' gia' atomico.
    class function RegistraRicevimentoMateriaPrima(ALotto: TLottoMateriaPrima): Integer;
    class function RegistraProduzioneSemilavorato(ALotto: TLottoSemilavorato): Integer;
    class function RegistraProduzioneProdottoFinito(ALotto: TLottoProdottoFinito): Integer;

    // Somma di QuantitaDisponibile su tutti i lotti di un'anagrafica: "quanto ne ho in
    // totale". Usata dal richiamo e dalle interrogazioni vendite.
    class function GiacenzaDisponibileMateriaPrima(AMateriaPrimaID: Integer): Currency;
    class function GiacenzaDisponibileSemilavorato(ASemilavoratoID: Integer): Currency;
    class function GiacenzaDisponibileProdottoFinito(AProdottoFinitoID: Integer): Currency;

    // Consumo di produzione (atomico). Le 4 combinazioni dei due XOR dello schema
    // (componente = materia prima o semilavorato; destinazione = semilavorato o prodotto
    // finito). Ognuna, in una transazione, decrementa la giacenza del lotto componente e
    // registra il consumo. Se la giacenza non basta non si scrive nulla (eccezione +
    // rollback). Restituiscono l'id del consumo.
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
  // COALESCE a 0: senza lotti (o esauriti) "zero disponibile", non NULL.
  SQL_GIACENZA_MATERIA_PRIMA =
    'SELECT COALESCE(SUM(quantita_disponibile), 0) AS giacenza ' +
    'FROM lotti_materie_prime WHERE materia_prima_id = :materia_prima_id';

  SQL_GIACENZA_SEMILAVORATO =
    'SELECT COALESCE(SUM(quantita_disponibile), 0) AS giacenza ' +
    'FROM lotti_semilavorati WHERE semilavorato_id = :semilavorato_id';

  SQL_GIACENZA_PRODOTTO_FINITO =
    'SELECT COALESCE(SUM(quantita_disponibile), 0) AS giacenza ' +
    'FROM lotti_prodotti_finiti WHERE prodotto_finito_id = :prodotto_finito_id';

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
      // Se la giacenza non basta DecrementaQuantitaDisponibile non tocca nulla e
      // restituisce False: si solleva un'eccezione per far scattare il rollback, cosi'
      // nessun consumo resta senza scarico.
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

  // Distinta multi-livello: il componente e' un lotto di semilavorato
  // (LottoSemilavoratoFiglioID). Stessa atomicita' del metodo sopra.
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
