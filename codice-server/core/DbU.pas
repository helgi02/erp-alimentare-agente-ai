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
    FOwnsConnection: Boolean;
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

    // Rilascio connessione (da logica applicativa e da TAutoQuery).
    procedure ReleasePooledConnection(var AConnection: TFDConnection);

    function getQueryResult(aQuery: String): TAutoQuery; overload;
    function getQueryResult(aQuery: String; Params: array of Variant): TAutoQuery; overload;
    function executeQuery(aQuery: String): Boolean; overload;
    function executeQuery(aQuery: String; Params: array of Variant): Boolean; overload;

    procedure ExecuteInTransaction(AProc: TProc<TFDConnection>);

    // Esegue piu' query (DELETE/INSERT/UPDATE senza ResultSet) in un'unica transazione:
    // tutte o nessuna (rollback se una solleva). AQueries[i] usa i parametri posizionali
    // AParamsList[i], con la sintassi :nome_param. Per operazioni atomiche senza dati di
    // ritorno (es. sostituire le associazioni many-to-many degli allergeni).
    procedure ExecuteQueriesInTransaction(const AQueries: TArray<string>;
      const AParamsList: TArray<TArray<Variant>>);
  end;

implementation

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
  // Evita di registrare piu' volte la stessa ConnectionDef.
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

    Params.Add('Pooled=True');
    Params.Add('POOL_MaximumItems=' + FConfig.PoolSize.ToString);
    Params.Add('POOL_ExpireTimeout=90000');
    Params.Add('POOL_CleanupTimeout=30000');

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
        // Parametro Null "puro" (es. valida_al sulla prima versione di una ricetta):
        // VarType(Null) non porta il tipo, e FireDAC manderebbe a PostgreSQL un parametro
        // di tipo sconosciuto, rifiutato con "-335 ... data type is unknown". Dichiarare
        // ftWideString fa inviare un NULL "unknown" per libpq, che PostgreSQL converte al
        // tipo reale della colonna. Un solo punto per tutte le query del DAO, non un fix
        // per colonna.
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
        // Come in getQueryResult: un Null "puro" senza DataType fa fallire PostgreSQL con
        // "-335 ... data type is unknown".
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

  // Riusa ExecuteInTransaction (connessione dedicata, stessa connessione per tutte le
  // query, commit solo senza eccezioni; rollback, log e rilancio sono gia' gestiti). Qui si
  // costruisce solo il TFDQuery condiviso.
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
            // Come in getQueryResult: Null senza DataType, errore "-335".
            if VarIsNull(AParamsList[i][j]) then
            begin
              LQuery.Params[j].DataType := ftWideString;
              LQuery.Params[j].Value := AParamsList[i][j];
            end
            // FireDAC da' ai parametri stringa una Size di 4000 caratteri; oltre, il driver
            // PG rifiuta con "-345 Data too large for variable". Capita in
            // TIndiceEmbeddingTool.Sincronizza: un vettore serializzato in testo supera
            // 4000 caratteri. ftMemo toglie il limite; il cast "::vector" nella SQL decide
            // il tipo reale.
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
