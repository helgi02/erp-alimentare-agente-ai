unit DbU;

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.Generics.Collections,
  Data.DB,
  FireDAC.Stan.Intf,
  FireDAC.Stan.Option,
  FireDAC.Stan.Error,
  FireDAC.UI.Intf,
  FireDAC.Phys.Intf,
  FireDAC.Phys.PG,
  FireDAC.Stan.Def,
  FireDAC.Stan.Pool, Variants,
  FireDAC.Stan.Async,
  FireDAC.Phys,
  FireDAC.Stan.Param,
  FireDAC.DatS,
  FireDAC.DApt.Intf,
  FireDAC.DApt,
  FireDAC.Comp.DataSet,
  FireDAC.Comp.Client,
  uLog,
  uConfig;

const
  DB_POOL_NAME = 'MainPool';

type
  TAutoQuery = class
  private
    FConnection: TFDConnection;
    FQuery: TFDQuery;
    FOwnsConnection: Boolean; // se True, la connessione va rilasciata tramite TDB
  public
    constructor Create(AConnection: TFDConnection; AOwnsConnection: Boolean = True);
    destructor Destroy; override;

    property Query: TFDQuery read FQuery;
    property Connection: TFDConnection read FConnection;
  end;

  TDB = class
  private
    class var FInstance: TDB;
    class var FLock: TCriticalSection;
    class var FConfig: TDatabaseConfig;
    class var FInitialized: Boolean;

    procedure InitializeConnectionDef;
    function CreatePooledConnection: TFDConnection;
    procedure InternalReleasePooledConnection(var AConnection: TFDConnection);
  public
    class procedure Initialize(const AConfig: TDatabaseConfig);
    class function GetInstance: TDB;
    class constructor Create;
    class destructor Destroy;

    constructor Create; reintroduce;
    destructor Destroy; override;

    // Rilascio connessione (usato sia dalla logica app che da TAutoQuery)
    procedure ReleasePooledConnection(var AConnection: TFDConnection);

    // Metodi per query con gestione automatica
    function getQueryResult(aQuery: String): TAutoQuery; overload;
    function getQueryResult(aQuery: String; Params: array of Variant): TAutoQuery; overload;
    function executeQuery(aQuery: String): Boolean; overload;
    function executeQuery(aQuery: String; Params: array of Variant): Boolean; overload;

    // Helper per transazioni thread-safe
    procedure ExecuteInTransaction(AProc: TProc<TFDConnection>);

    // Esegue piu' query (DELETE/INSERT/UPDATE, senza ResultSet atteso)
    // in un'unica transazione: o vanno tutte a buon fine, o nessuna
    // modifica resta sul DB (rollback automatico se una qualsiasi
    // solleva un'eccezione). AQueries[i] usa i parametri posizionali
    // AParamsList[i], con la stessa sintassi :nome_param delle altre
    // query parametriche di questa classe.
    // Pensato per operazioni che devono essere atomiche ma non
    // restituiscono dati (es. sostituire un insieme di associazioni
    // many-to-many, come gli allergeni collegati a una materia prima).
    procedure ExecuteQueriesInTransaction(const AQueries: TArray<string>;
      const AParamsList: TArray<TArray<Variant>>);
  end;

implementation

{ TAutoQuery }

constructor TAutoQuery.Create(AConnection: TFDConnection; AOwnsConnection: Boolean);
begin
  inherited Create;
  FConnection      := AConnection;
  FOwnsConnection  := AOwnsConnection;
  FQuery           := TFDQuery.Create(nil);
  FQuery.Connection := FConnection;
end;

destructor TAutoQuery.Destroy;
begin
  try
    if Assigned(FQuery) then
    begin
      if FQuery.Active then
        FQuery.Close;
      FreeAndNil(FQuery);
    end;

    if FOwnsConnection and (FConnection <> nil) then
    begin
      try
        TDB.GetInstance.ReleasePooledConnection(FConnection);
      except
        on E: Exception do
          Tlog.write('Errore rilascio connessione in TAutoQuery.Destroy: ' +
                     E.ClassName + ' - ' + E.Message);
      end;
    end;
  except
    on E: Exception do
      Tlog.write('Errore critico in TAutoQuery.Destroy: ' +
                 E.ClassName + ' - ' + E.Message);
  end;

  inherited;
end;

{ TDB ------------------------------------------------------------ }

class constructor TDB.Create;
begin
  FLock := TCriticalSection.Create;
  FInitialized := False;
end;

class destructor TDB.Destroy;
begin
  FreeAndNil(FInstance);
  FreeAndNil(FLock);
end;

class procedure TDB.Initialize(const AConfig: TDatabaseConfig);
begin
  FLock.Enter;
  try
    FConfig := AConfig;
    FInitialized := True;
    Tlog.write('TDB.Initialize: configurazione del pool ricevuta.');
  finally
    FLock.Leave;
  end;
end;

constructor TDB.Create;
begin
  inherited Create;

  if not FInitialized then
    raise Exception.Create(
      'TDB non inizializzato. Chiamare TDB.Initialize(AConfig) prima di ' +
      'utilizzare TDB.GetInstance.');

  InitializeConnectionDef;
end;

destructor TDB.Destroy;
begin
  inherited;
end;

procedure TDB.InitializeConnectionDef;
var
  Params: TStrings;
begin
  // Evita di registrare più volte la stessa ConnectionDef
  if FDManager.ConnectionDefs.FindConnectionDef(DB_POOL_NAME) <> nil then
    Exit;

  Params := TStringList.Create;
  try
    Params.Add('DriverID=PG');
    Params.Add('Server=' + FConfig.Server);
    Params.Add('Port=' + FConfig.Port.ToString);
    Params.Add('Database=' + FConfig.Database);
    Params.Add('User_Name=' + FConfig.UserName);
    Params.Add('Password=' + FConfig.Password);

    // Pooling FireDAC
    Params.Add('Pooled=True');
    Params.Add('POOL_MaximumItems=' + FConfig.PoolSize.ToString);
    Params.Add('POOL_ExpireTimeout=90000');   // 90 secondi
    Params.Add('POOL_CleanupTimeout=30000');  // 30 secondi

    FDManager.AddConnectionDef(DB_POOL_NAME, 'PG', Params);
    Tlog.write('Connection pool configurato con successo (max ' +
               FConfig.PoolSize.ToString + ' connessioni).');
  finally
    Params.Free;
  end;
end;

function TDB.CreatePooledConnection: TFDConnection;
begin
  Result := TFDConnection.Create(nil);
  Result.ConnectionDefName := DB_POOL_NAME;
  Result.LoginPrompt := False;

  try
    Result.Connected := True;
  except
    on E: Exception do
    begin
      Tlog.write('ERRORE connessione al pool: ' + E.Message);
      FreeAndNil(Result);
      raise;
    end;
  end;
end;

procedure TDB.InternalReleasePooledConnection(var AConnection: TFDConnection);
begin
  try
    if AConnection = nil then
      Exit;

    try
      if AConnection.InTransaction then
      begin
        try
          AConnection.Rollback;
        except
          on E: Exception do
            Tlog.write('Rollback fallito in ReleasePooledConnection: ' + E.Message);
        end;
      end;
    except
      on E: Exception do
        Tlog.write('Errore controllo transazione in ReleasePooledConnection: ' + E.Message);
    end;

    try
      if AConnection.Connected then
        AConnection.Connected := False;
    except
      on E: Exception do
        Tlog.write('Errore disconnessione in ReleasePooledConnection: ' + E.Message);
    end;

    try
      FreeAndNil(AConnection);
    except
      on E: Exception do
        Tlog.write('Errore FreeAndNil connessione in ReleasePooledConnection: ' + E.Message);
    end;

  except
    on E: Exception do
      Tlog.write('Errore generale in ReleasePooledConnection: ' + E.Message);
  end;
end;

procedure TDB.ReleasePooledConnection(var AConnection: TFDConnection);
begin
  InternalReleasePooledConnection(AConnection);
end;

class function TDB.GetInstance: TDB;
begin
  FLock.Enter;
  try
    if FInstance = nil then
      FInstance := TDB.Create;
    Result := FInstance;
  finally
    FLock.Leave;
  end;
end;

function TDB.getQueryResult(aQuery: String): TAutoQuery;
var
  Conn: TFDConnection;
begin
  Result := nil;
  Conn := nil;
  try
    Conn   := CreatePooledConnection;
    Result := TAutoQuery.Create(Conn, True);
    Conn := nil;
    try
      Result.Query.SQL.Text := aQuery;
      Result.Query.Open;
      if not Result.Query.IsEmpty then
        Result.Query.First;
    except
      on E: Exception do
      begin
        FreeAndNil(Result);
        raise;
      end;
    end;
  except
    on E: Exception do
    begin
      Tlog.write('Errore getQueryResult: ' + E.Message);
      if Assigned(Conn) then
        ReleasePooledConnection(Conn);
      raise;
    end;
  end;
end;

function TDB.getQueryResult(aQuery: String; Params: array of Variant): TAutoQuery;
var
  i: Integer;
  Conn: TFDConnection;
  sVal: String;
begin
  Result := nil;
  Conn := nil;
  try
    Conn   := CreatePooledConnection;
    Result := TAutoQuery.Create(Conn, True);
    Conn := nil;
    try
      Result.Query.SQL.Text := aQuery;
      for i := 0 to High(Params) do
      begin
        // Parametro Null "puro" (es. un campo opzionale non valorizzato,
        // come TRicettaProdottoFinito.Insert per valida_al sulla PRIMA
        // versione di una ricetta): VarType(Null) non porta nessuna
        // informazione di tipo, quindi senza questo ramo FireDAC manda a
        // PostgreSQL un parametro "di tipo sconosciuto" e il driver lo
        // rifiuta con "[FireDAC][Phys][PG]-335 ... data type is unknown"
        // (esattamente l'errore osservato in log durante
        // ApplicaAdattamentoRicetta). Dichiarare qui ftWideString fa si'
        // che FireDAC invii comunque un NULL, ma "tipizzato testo" (e' il
        // tipo "unknown" del protocollo libpq): in un INSERT/UPDATE
        // PostgreSQL lo converte da solo al tipo REALE della colonna di
        // destinazione (date, integer, ...) - non serve che questo layer
        // generico lo sappia. Un solo punto per ogni query di questo DAO
        // che passa Null come parametro, non un fix per-colonna.
        if VarIsNull(Params[i]) then
        begin
          Result.Query.Params[i].DataType := ftWideString;
          Result.Query.Params[i].Value := Params[i];
        end
        else if (VarType(Params[i]) = varString) or
         (VarType(Params[i]) = varOleStr) or
         (VarType(Params[i]) = varUString) then
        begin
          sVal := VarToStr(Params[i]);
          if Length(sVal) > 4000 then
          begin
            Result.Query.Params[i].DataType := ftMemo;
            Result.Query.Params[i].AsMemo   := sVal;
          end
          else
            Result.Query.Params[i].Value := Params[i];
        end
        else
          Result.Query.Params[i].Value := Params[i];
      end;

      Result.Query.Open;
      if not Result.Query.IsEmpty then
        Result.Query.First;
    except
      on E: Exception do
      begin
        FreeAndNil(Result);
        raise;
      end;
    end;
  except
    on E: Exception do
    begin
      Tlog.write('Errore getQueryResult (con parametri): ' + E.Message);
      if Assigned(Conn) then
        ReleasePooledConnection(Conn);
      raise;
    end;
  end;
end;

function TDB.executeQuery(aQuery: String): Boolean;
var
  Conn: TFDConnection;
  Q: TFDQuery;
begin
  Result := False;
  Conn := nil;
  Q := nil;
  try
    try
      Conn := CreatePooledConnection;
      Q := TFDQuery.Create(nil);
      Q.Connection := Conn;
      Q.SQL.Text := aQuery;
      Q.ExecSQL;
      Result := True;
    except
      on E: Exception do
      begin
        Tlog.write('Errore executeQuery: ' + E.Message);
        Result := False;
      end;
    end;
  finally
    if Assigned(Q) then
      FreeAndNil(Q);
    if Assigned(Conn) then
      ReleasePooledConnection(Conn);
  end;
end;

function TDB.executeQuery(aQuery: String; Params: array of Variant): Boolean;
var
  i: Integer;
  Conn: TFDConnection;
  Q: TFDQuery;
  sVal: String;
begin
  Result := False;
  Conn := nil;
  Q := nil;
  try
    try
      Conn := CreatePooledConnection;
      Q := TFDQuery.Create(nil);
      Q.Connection := Conn;
      Q.SQL.Text := aQuery;
      for i := 0 to High(Params) do
      begin
        // Vedi il commento gemello in getQueryResult (stesso DAO, stesso
        // motivo): un parametro Null "puro" senza DataType esplicito fa
        // fallire PostgreSQL con "-335 ... data type is unknown".
        if VarIsNull(Params[i]) then
        begin
          Q.Params[i].DataType := ftWideString;
          Q.Params[i].Value := Params[i];
        end
        else if (VarType(Params[i]) = varString) or
         (VarType(Params[i]) = varOleStr) or
         (VarType(Params[i]) = varUString) then
        begin
          sVal := VarToStr(Params[i]);
          if Length(sVal) > 4000 then
          begin
            Q.Params[i].DataType := ftMemo;
            Q.Params[i].AsMemo   := sVal;
          end
          else
            Q.Params[i].Value := Params[i];
        end
        else
          Q.Params[i].Value := Params[i];
      end;

      Q.ExecSQL;
      Result := True;
    except
      on E: Exception do
      begin
        Tlog.write('Errore executeQuery (con parametri): ' + E.Message);
        Result := False;
      end;
    end;
  finally
    if Assigned(Q) then
      FreeAndNil(Q);
    if Assigned(Conn) then
      ReleasePooledConnection(Conn);
  end;
end;

procedure TDB.ExecuteInTransaction(AProc: TProc<TFDConnection>);
var
  Conn: TFDConnection;
begin
  Conn := nil;

  try
    Conn := CreatePooledConnection;
    Conn.StartTransaction;

    try
      AProc(Conn);
      Conn.Commit;
    except
      on E: Exception do
      begin
        if Conn.InTransaction then
        begin
          Conn.Rollback;
          Tlog.write('Transazione annullata (rollback)');
        end;
        Tlog.write('Errore transazione: ' + E.Message);
        raise;
      end;
    end;
  finally
    if Assigned(Conn) then
      ReleasePooledConnection(Conn);
  end;
end;

procedure TDB.ExecuteQueriesInTransaction(const AQueries: TArray<string>;
  const AParamsList: TArray<TArray<Variant>>);
begin
  if Length(AQueries) <> Length(AParamsList) then
    raise Exception.Create(
      'ExecuteQueriesInTransaction: AQueries e AParamsList devono avere la stessa lunghezza.');

  // Riusa ExecuteInTransaction: apre una connessione dedicata, avvia la
  // transazione, esegue in sequenza tutte le query sulla STESSA
  // connessione, e fa commit solo se nessuna solleva eccezione.
  // ExecuteInTransaction gestisce gia' rollback + log + rilancio
  // dell'eccezione in caso di errore: qui costruiamo solo il TFDQuery
  // condiviso e ci scorriamo AQueries/AParamsList in parallelo.
  ExecuteInTransaction(
    procedure(AConn: TFDConnection)
    var
      LQuery: TFDQuery;
      i, j: Integer;
      sVal: String;
    begin
      LQuery := TFDQuery.Create(nil);
      try
        LQuery.Connection := AConn;
        for i := 0 to High(AQueries) do
        begin
          LQuery.SQL.Text := AQueries[i];
          for j := 0 to High(AParamsList[i]) do
          begin
            // Stesso motivo dei due commenti gemelli in getQueryResult/
            // executeQuery: un parametro Null senza DataType esplicito fa
            // fallire PostgreSQL con "-335 ... data type is unknown".
            if VarIsNull(AParamsList[i][j]) then
            begin
              LQuery.Params[j].DataType := ftWideString;
              LQuery.Params[j].Value := AParamsList[i][j];
            end
            // Stesso motivo del terzo commento gemello: FireDAC assegna ai
            // parametri stringa una Size fissa (di default 4000 caratteri,
            // vedi ftString/ftWideString) finche' non gli si dice il
            // contrario. Sopra quella soglia il driver PG rifiuta con
            // "-345 Data too large for variable". Emerso con
            // TIndiceEmbeddingTool.Sincronizza (common/uIndiceEmbeddingTool.
            // pas): un vettore a 384 dimensioni serializzato in testo supera
            // facilmente i 4000 caratteri. ftMemo lascia che FireDAC invii
            // il parametro senza un limite di lunghezza fisso - il cast
            // "::vector" nella SQL del chiamante decide comunque il tipo
            // reale lato Postgres, esattamente come per i parametri Null.
            else if (VarType(AParamsList[i][j]) = varString) or
               (VarType(AParamsList[i][j]) = varOleStr) or
               (VarType(AParamsList[i][j]) = varUString) then
            begin
              sVal := VarToStr(AParamsList[i][j]);
              if Length(sVal) > 4000 then
              begin
                LQuery.Params[j].DataType := ftMemo;
                LQuery.Params[j].AsMemo := sVal;
              end
              else
                LQuery.Params[j].Value := AParamsList[i][j];
            end
            else
              LQuery.Params[j].Value := AParamsList[i][j];
          end;
          LQuery.ExecSQL;
        end;
      finally
        LQuery.Free;
      end;
    end);
end;

end.
