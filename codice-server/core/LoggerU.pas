unit LoggerU;

interface

uses
  System.SysUtils, System.Classes, System.JSON, System.DateUtils, System.IOUtils,
  System.Variants, System.SyncObjs, System.Generics.Collections, System.Math,
  FireDAC.Comp.Client, FireDAC.Stan.Param, FireDAC.Stan.Intf, Data.DB,
  Web.HTTPApp,
  MVCFramework, uLog, DbU;

type
  TLogLevel = (llInfo, llWarning, llError, llSecurity);
  TLogCategory = (lcAuth, lcAPI, lcFileAccess, lcAdmin, lcBusiness, lcAnalytics);
  TLogResult = (lrSuccess, lrFailure, lrDenied);

  TLogItem = record
    LogLevel: TLogLevel;
    Category: TLogCategory;
    Action: string;
    LogResult: TLogResult;
    UserEmail: string;
    IPAddress: string;
    Message: string;
    UserId: Integer;
    ResourceId: string;
    ResourceType: string;
    CreatedAt: TDateTime;
  end;

  TSecurityLogger = class
  private type
    TLogWorker = class(TThread)
    private
      FQueue: TThreadedQueue<TLogItem>;
      FStopEvent: TEvent;
      FBatchSize: Integer;
      FBatchDelay: Cardinal;
      FFallbackPath: string;
      FMaxRetries: Integer;
      FRetryDelay: Cardinal;
      FConnection: TFDConnection;

      procedure EnsureConnection;
      procedure CloseConnection;
      procedure FlushBatch(const Batch: TArray<TLogItem>);
      procedure FallbackToFile(const Item: TLogItem; const ErrMsg: string);
    protected
      procedure Execute; override;
    public
      constructor Create(AQueue: TThreadedQueue<TLogItem>; ABatchSize: Integer;
        ABatchDelay: Cardinal; const AFallbackPath: string);
      destructor Destroy; override;
    end;

  private
    FQueue: TThreadedQueue<TLogItem>;
    FWorker: TLogWorker;
    FBatchSize: Integer;
    FBatchDelay: Cardinal;
    FFallbackPath: string;
    class var FInstance: TSecurityLogger;
    class var FLock: TObject;

    constructor Create;
    procedure WriteLog(
      Level: TLogLevel;
      Category: TLogCategory;
      Action: string;
      LogRes: TLogResult;
      Context: TWebContext = nil;
      UserId: Integer = 0;
      UserEmail: string = '';
      ResourceId: string = '';
      ResourceType: string = '';
      Message: string = ''
    );
    procedure StartWorker;
    procedure StopWorker;

  public
    class function Instance: TSecurityLogger;
    destructor Destroy; override;

    class function LogLevelToString(Level: TLogLevel): string; static;
    class function CategoryToString(Category: TLogCategory): string; static;
    class function LogResultToString(LogRes: TLogResult): string; static;
    class function GetClientIP(Context: TWebContext): string; static;

    class procedure Log(Level: TLogLevel; Category: TLogCategory; Action: string;
      Success: Boolean; Context: TWebContext = nil; UserId: Integer = 0;
      UserEmail: string = ''; ResourceId: string = ''; Message: string = '');
    class procedure Shutdown;
    class procedure LogLogin(Context: TWebContext; UserEmail: string;
      Success: Boolean; Message: string = '');
    class procedure LogFileAccess(Context: TWebContext; UserId: Integer;
      FileName: string; CourseId: Integer; Success: Boolean);
    class procedure LogAdminAction(Context: TWebContext; AdminEmail: string;
      Action: string; ResourceId: string; Success: Boolean; Message: string = '');
    class procedure LogAPICall(Context: TWebContext; Success: Boolean; Message: string = '');
    class procedure LogSecurity(Context: TWebContext; Action: string;
      Message: string; UserId: Integer = 0);
    class procedure LogError(Context: TWebContext; ErrorMessage: string; UserId: Integer = 0);
    class procedure LogAnalyticsEvent(Context: TWebContext; const Action, ResourceId,
      ResourceType: string; const UserId: Integer; const Message: string = '');

    function GetFailedLoginAttempts(IPAddress: string): Integer;
    function IsIPBlocked(IPAddress: string): Boolean;
  end;

implementation

class function TSecurityLogger.LogLevelToString(Level: TLogLevel): string;
const
  MAP: array [TLogLevel] of string = ('INFO', 'WARNING', 'ERROR', 'SECURITY');
begin
  Result := MAP[Level];
end;

class function TSecurityLogger.CategoryToString(Category: TLogCategory): string;
const
  MAP: array [TLogCategory] of string = ('AUTH', 'API', 'FILE_ACCESS', 'ADMIN', 'BUSINESS', 'ANALYTICS');
begin
  Result := MAP[Category];
end;

class function TSecurityLogger.LogResultToString(LogRes: TLogResult): string;
const
  MAP: array [TLogResult] of string = ('SUCCESS', 'FAILURE', 'DENIED');
begin
  Result := MAP[LogRes];
end;

class function TSecurityLogger.GetClientIP(Context: TWebContext): string;
begin
  Result := '0.0.0.0';
  if Assigned(Context) and Assigned(Context.Request) then
  begin
    Result := Context.Request.Headers['X-Forwarded-For'];
    if Result.IsEmpty then
      Result := Context.Request.Headers['X-Real-IP'];
    if Result.IsEmpty then
      Result := Context.Request.ClientIP;
    if Result.IsEmpty then
      Result := '0.0.0.0';
  end;
end;

constructor TSecurityLogger.TLogWorker.Create(AQueue: TThreadedQueue<TLogItem>;
  ABatchSize: Integer; ABatchDelay: Cardinal; const AFallbackPath: string);
begin
  inherited Create(False);
  FreeOnTerminate := False;
  Priority := tpLower;

  FQueue := AQueue;
  FStopEvent := TEvent.Create(nil, True, False, '');
  FBatchSize := ABatchSize;
  FBatchDelay := ABatchDelay;
  FFallbackPath := AFallbackPath;
  FMaxRetries := 3;
  FRetryDelay := 1000;
  FConnection := nil;
end;

destructor TSecurityLogger.TLogWorker.Destroy;
begin
  CloseConnection;
  FStopEvent.Free;
  inherited;
end;

procedure TSecurityLogger.TLogWorker.EnsureConnection;
var
  Retry: Integer;
  LastError: string;
begin
  if Assigned(FConnection) and FConnection.Connected then
    Exit;

  CloseConnection;

  for Retry := 1 to FMaxRetries do
  begin
    try
      FConnection := TFDConnection.Create(nil);
      FConnection.ConnectionDefName := 'NaturalCarePool';
      FConnection.LoginPrompt := False;
      FConnection.Connected := True;
      Exit;
    except
      on E: Exception do
      begin
        LastError := E.Message;
        FreeAndNil(FConnection);

        if Retry < FMaxRetries then
          Sleep(FRetryDelay * Retry)
        else
        begin
          Tlog.write(Format('LogWorker: Impossibile connettersi dopo %d tentativi: %s',
            [FMaxRetries, LastError]));
          raise;
        end;
      end;
    end;
  end;
end;

procedure TSecurityLogger.TLogWorker.CloseConnection;
begin
  if Assigned(FConnection) then
  begin
    try
      if FConnection.Connected then
        FConnection.Connected := False;
    except
    end;
    FreeAndNil(FConnection);
  end;
end;

procedure TSecurityLogger.TLogWorker.FallbackToFile(const Item: TLogItem; const ErrMsg: string);
var
  L: string;
  LogFilePath: string;
begin
  try
    if not TDirectory.Exists(FFallbackPath) then
      TDirectory.CreateDirectory(FFallbackPath);

    L := Format('[%s] %s %s %s %s %s UserId:%d ResId:%s ResType:%s | ERR=%s%s',
      [
        FormatDateTime('yyyy-mm-dd hh:nn:ss', Item.CreatedAt),
        TSecurityLogger.LogLevelToString(Item.LogLevel),
        TSecurityLogger.CategoryToString(Item.Category),
        Item.Action,
        TSecurityLogger.LogResultToString(Item.LogResult),
        Item.Message,
        Item.UserId,
        Item.ResourceId,
        Item.ResourceType,
        ErrMsg,
        sLineBreak
      ]);

    LogFilePath := TPath.Combine(FFallbackPath, 'security_fallback.log');
    TFile.AppendAllText(LogFilePath, L, TEncoding.UTF8);
  except
  end;
end;

procedure TSecurityLogger.TLogWorker.FlushBatch(const Batch: TArray<TLogItem>);
var
  N: Integer;
begin
  if Length(Batch) = 0 then
    Exit;

  N := Length(Batch);

  TDB.GetInstance.ExecuteInTransaction(
    procedure(Conn: TFDConnection)
    var
      Q: TFDQuery;
      I: Integer;
    begin
      Q := TFDQuery.Create(nil);
      try
        Q.Connection := Conn;
        Q.SQL.Text :=
          'INSERT INTO security_audit_log ' +
          '(log_level, category, action, user_email, ip_address, result, message, ' +
          'user_id, resource_id, resource_type, "timestamp") ' +
          'VALUES (:log_level, :category, :action, :user_email, :ip, :result, :message, ' +
          ':user_id, :resource_id, :resource_type, :timestamp)';

        Q.Params.ArraySize := N;

        for I := 0 to N - 1 do
        begin
          Q.ParamByName('log_level').AsStrings[I] := TSecurityLogger.LogLevelToString(Batch[I].LogLevel);
          Q.ParamByName('category').AsStrings[I] := TSecurityLogger.CategoryToString(Batch[I].Category);
          Q.ParamByName('action').AsStrings[I] := Batch[I].Action;
          Q.ParamByName('user_email').AsStrings[I] := Batch[I].UserEmail;
          Q.ParamByName('ip').AsStrings[I] := Batch[I].IPAddress;
          Q.ParamByName('result').AsStrings[I] := TSecurityLogger.LogResultToString(Batch[I].LogResult);
          Q.ParamByName('message').AsStrings[I] := Batch[I].Message;
          Q.ParamByName('user_id').AsIntegers[I] := Batch[I].UserId;
          Q.ParamByName('resource_id').AsStrings[I] := Batch[I].ResourceId;
          Q.ParamByName('resource_type').AsStrings[I] := Batch[I].ResourceType;
          Q.ParamByName('timestamp').AsDateTimes[I] := Batch[I].CreatedAt;
        end;

        Q.Execute(N);
      finally
        Q.Free;
      end;
    end
  );
end;
procedure TSecurityLogger.TLogWorker.Execute;
var
  Items: TArray<TLogItem>;
  Count: Integer;
  Deadline: UInt64;
  Item: TLogItem;
  PopResult: TWaitResult;
  Idx: Integer;
begin
  SetLength(Items, FBatchSize);
  Count := 0;
  Deadline := GetTickCount64 + FBatchDelay;

  while not Terminated do
  begin
    if FStopEvent.WaitFor(0) = wrSignaled then
    begin
      if Count > 0 then
      begin
        try
          FlushBatch(Copy(Items, 0, Count));
        except
          on E: Exception do
            for Idx := 0 to Count - 1 do
              FallbackToFile(Items[Idx], E.Message);
        end;
      end;
      Break;
    end;

    PopResult := FQueue.PopItem(Item);

    if PopResult = wrSignaled then
    begin
      Items[Count] := Item;
      Inc(Count);

      if Count >= FBatchSize then
      begin
        try
          FlushBatch(Items);
        except
          on E: Exception do
          begin
            Tlog.write('LogWorker FlushBatch error: ' + E.Message);
            for Idx := 0 to FBatchSize - 1 do
              FallbackToFile(Items[Idx], E.Message);
          end;
        end;
        Count := 0;
        Deadline := GetTickCount64 + FBatchDelay;
      end;
    end
    else
    begin
      if (Count > 0) and (GetTickCount64 >= Deadline) then
      begin
        try
          FlushBatch(Copy(Items, 0, Count));
        except
          on E: Exception do
          begin
            Tlog.write('LogWorker FlushBatch (partial) error: ' + E.Message);
            for Idx := 0 to Count - 1 do
              FallbackToFile(Items[Idx], E.Message);
          end;
        end;
        Count := 0;
        Deadline := GetTickCount64 + FBatchDelay;
      end;
    end;
  end;

  CloseConnection;
end;

constructor TSecurityLogger.Create;
begin
  inherited;
  FBatchSize := 50;
  FBatchDelay := 100;
  // Cartella dei log di ripiego: 'logs' accanto all'eseguibile.
  FFallbackPath := TPath.Combine(ExtractFilePath(ParamStr(0)), 'logs');

  if not TDirectory.Exists(FFallbackPath) then
    TDirectory.CreateDirectory(FFallbackPath);

  FQueue := TThreadedQueue<TLogItem>.Create(1024, INFINITE, 10);
  FWorker := nil;
  StartWorker;
end;

destructor TSecurityLogger.Destroy;
begin
  StopWorker;
  FreeAndNil(FQueue);
  inherited;
end;

class function TSecurityLogger.Instance: TSecurityLogger;
begin
  if FInstance = nil then
  begin
    TMonitor.Enter(FLock);
    try
      if FInstance = nil then
        FInstance := TSecurityLogger.Create;
    finally
      TMonitor.Exit(FLock);
    end;
  end;
  Result := FInstance;
end;

procedure TSecurityLogger.StartWorker;
begin
  if Assigned(FWorker) then
    Exit;
  FWorker := TLogWorker.Create(FQueue, FBatchSize, FBatchDelay, FFallbackPath);
end;

procedure TSecurityLogger.StopWorker;
begin
  if Assigned(FWorker) then
  begin
    FWorker.FStopEvent.SetEvent;
    FWorker.WaitFor;
    FreeAndNil(FWorker);
  end;
end;

class procedure TSecurityLogger.Shutdown;
begin
  if Assigned(FInstance) then
  begin
    FInstance.StopWorker;
    FreeAndNil(FInstance);
  end;
end;

procedure TSecurityLogger.WriteLog(Level: TLogLevel; Category: TLogCategory;
  Action: string; LogRes: TLogResult; Context: TWebContext; UserId: Integer;
  UserEmail, ResourceId, ResourceType, Message: string);
var
  Item: TLogItem;
  LogFilePath: string;
begin
  Item.CreatedAt := Now;
  Item.LogLevel := Level;
  Item.Category := Category;
  Item.Action := Action;
  Item.LogResult := LogRes;
  Item.UserEmail := UserEmail;
  Item.Message := Message;
  Item.UserId := UserId;
  Item.ResourceId := ResourceId;
  Item.ResourceType := ResourceType;
  Item.IPAddress := GetClientIP(Context);

  if not Assigned(FQueue) then
    Exit;

  if FQueue.PushItem(Item) <> wrSignaled then
  begin
    try
      if not TDirectory.Exists(FFallbackPath) then
        TDirectory.CreateDirectory(FFallbackPath);

      LogFilePath := TPath.Combine(FFallbackPath, 'security_fallback.log');
      TFile.AppendAllText(LogFilePath,
        Format('[%s] QUEUE_FULL %s %s %s %s from IP %s%s',
          [
            FormatDateTime('yyyy-mm-dd hh:nn:ss', Item.CreatedAt),
            LogLevelToString(Item.LogLevel),
            CategoryToString(Item.Category),
            Item.Action,
            Item.Message,
            Item.IPAddress,
            sLineBreak
          ]),
        TEncoding.UTF8);
    except
    end;
  end;
end;

class procedure TSecurityLogger.Log(Level: TLogLevel; Category: TLogCategory;
  Action: string; Success: Boolean; Context: TWebContext; UserId: Integer;
  UserEmail, ResourceId, Message: string);
var
  LogRes: TLogResult;
begin
  if Success then
    LogRes := lrSuccess
  else
    LogRes := lrFailure;

  Instance.WriteLog(Level, Category, Action, LogRes, Context, UserId, UserEmail,
    ResourceId, '', Message);
end;

class procedure TSecurityLogger.LogLogin(Context: TWebContext; UserEmail: string;
  Success: Boolean; Message: string);
var
  LogRes: TLogResult;
begin
  if Success then
    LogRes := lrSuccess
  else
    LogRes := lrFailure;

  Instance.WriteLog(llSecurity, lcAuth, 'LOGIN_ATTEMPT', LogRes, Context, 0,
    UserEmail, '', '', Message);
end;

class procedure TSecurityLogger.LogFileAccess(Context: TWebContext; UserId: Integer;
  FileName: string; CourseId: Integer; Success: Boolean);
var
  LogRes: TLogResult;
begin
  if Success then
    LogRes := lrSuccess
  else
    LogRes := lrFailure;

  Instance.WriteLog(llInfo, lcFileAccess, 'FILE_DOWNLOAD', LogRes, Context, UserId,
    '', IntToStr(CourseId), '', FileName);
end;

class procedure TSecurityLogger.LogAdminAction(Context: TWebContext; AdminEmail: string;
  Action: string; ResourceId: string; Success: Boolean; Message: string);
var
  LogRes: TLogResult;
begin
  if Success then
    LogRes := lrSuccess
  else
    LogRes := lrFailure;

  Instance.WriteLog(llSecurity, lcAdmin, Action, LogRes, Context, 0, AdminEmail,
    ResourceId, '', Message);
end;

class procedure TSecurityLogger.LogAPICall(Context: TWebContext; Success: Boolean;
  Message: string);
var
  LogRes: TLogResult;
begin
  if Success then
    LogRes := lrSuccess
  else
    LogRes := lrFailure;

  Instance.WriteLog(llInfo, lcAPI, 'API_CALL', LogRes, Context, 0, '', '', '', Message);
end;

class procedure TSecurityLogger.LogSecurity(Context: TWebContext; Action: string;
  Message: string; UserId: Integer);
begin
  Instance.WriteLog(llSecurity, lcAuth, Action, lrDenied, Context, UserId, '', '', '', Message);
end;

class procedure TSecurityLogger.LogError(Context: TWebContext; ErrorMessage: string;
  UserId: Integer);
begin
  Instance.WriteLog(llError, lcAPI, 'EXCEPTION', lrFailure, Context, UserId, '', '', '',
    ErrorMessage);
end;

class procedure TSecurityLogger.LogAnalyticsEvent(Context: TWebContext;
  const Action, ResourceId, ResourceType: string; const UserId: Integer;
  const Message: string = '');
begin
  Instance.WriteLog(llInfo, lcAnalytics, Action, lrSuccess, Context, UserId, '',
    ResourceId, ResourceType, Message);
end;

function TSecurityLogger.GetFailedLoginAttempts(IPAddress: string): Integer;
var
  AQ: TAutoQuery;
  ErrMsg: string;
  LogFilePath: string;
begin
  Result := 0;

  try
    AQ := tDB.GetInstance.getQueryResult(
      'SELECT COUNT(*) AS attempts ' +
      'FROM security_audit_log ' +
      'WHERE ip_address = :ip AND action = :act AND result = :res ' +
      'AND "timestamp" > (now() - interval ''1 hour'')',
      [IPAddress, 'LOGIN_ATTEMPT', 'FAILURE']
    );
    try
      if not AQ.Query.IsEmpty then
        Result := AQ.Query.FieldByName('attempts').AsInteger;
    finally
      AQ.Free;
    end;
  except
    on E: Exception do
    begin
      try
        if not TDirectory.Exists(FFallbackPath) then
          TDirectory.CreateDirectory(FFallbackPath);

        ErrMsg := Format('[%s] ERROR GetFailedLoginAttempts IP=%s: %s%s',
          [FormatDateTime('yyyy-mm-dd hh:nn:ss', Now), IPAddress, E.Message, sLineBreak]);

        LogFilePath := TPath.Combine(FFallbackPath, 'security_fallback.log');
        TFile.AppendAllText(LogFilePath, ErrMsg, TEncoding.UTF8);
      except
      end;
      Result := 0;
    end;
  end;
end;

function TSecurityLogger.IsIPBlocked(IPAddress: string): Boolean;
begin
  Result := GetFailedLoginAttempts(IPAddress) >= 5;
end;

initialization
  TSecurityLogger.FLock := TObject.Create;

finalization
  if Assigned(TSecurityLogger.FInstance) then
  begin
    TSecurityLogger.FInstance.StopWorker;
    FreeAndNil(TSecurityLogger.FInstance);
  end;
  FreeAndNil(TSecurityLogger.FLock);

end.
