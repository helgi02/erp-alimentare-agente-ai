unit uWebModule;


interface

  uses
    System.SysUtils,
    System.Classes,
    Web.HTTPApp,
    MVCFramework,
    MVCFramework.MCP.Server, uVenditeToolProvider,
    LoggerU, GlobalU;

  type
    TWebModule1 = class(TWebModule)

      procedure WebModuleCreate(Sender: TObject);
      procedure WebModuleDestroy(Sender: TObject);

      private
        FMVC: TMVCEngine;
        FMCPServer: TMCPServer;

        procedure WebModuleBeforeDispatch(Sender: TObject; Request: TWebRequest;
          Response: TWebResponse; var Handled: Boolean);

    end;

  var
    WebModuleClass: TComponentClass = TWebModule1;

implementation

{$R *.dfm}

uses
  MVCFramework.Commons, System.DateUtils,
  MVCFramework.ActiveRecord,
  MVCFramework.Middleware.Compression,
  MVCFramework.Middleware.CORS,
  MVCFramework.Middleware.JWT,
  MVCFramework.Middleware.StaticFiles,
  MVCFramework.JWT,
  MVCFramework.MCP.Types,
  MVCFramework.MCP.Bridge,
  uConfig, uLog,
  uControllerFornitori, uControllerClienti, uControllerMateriePrime,
  uControllerDashboard, uControllerOrdiniVendita, uControllerProdottiFiniti,
  uControllerSemilavorati, uControllerRicette,
  uControllerLottiMateriePrime, uControllerLottiSemilavorati,
  uControllerLottiProdottiFiniti, uControllerTracciabilita,
  AIAgentControllerU, uControllerEmail;

procedure TWebModule1.WebModuleCreate(Sender: TObject);
begin
  Self.BeforeDispatch := WebModuleBeforeDispatch;

  FMVC := TMVCEngine.Create(Self,
    procedure(Config: TMVCConfig)
    begin
      Config[TMVCConfigKey.SessionTimeout] := '0';
      Config[TMVCConfigKey.DefaultContentType] := TMVCConstants.DEFAULT_CONTENT_TYPE;
      Config[TMVCConfigKey.DefaultContentCharset] := TMVCConstants.DEFAULT_CONTENT_CHARSET;
      Config[TMVCConfigKey.AllowUnhandledAction] := 'false';
      Config[TMVCConfigKey.DefaultViewFileExtension] := 'html';
      Config[TMVCConfigKey.ViewPath] := 'templates';
      Config[TMVCConfigKey.ExposeServerSignature] := 'true';
    end);

  FMVC.AddMiddleware(
    TMVCCORSMiddleware.Create(
      GUrl,                                    // Origin consentiti (separati da virgola)
      True,                                    // AllowCredentials
      '',                                      // ExposeHeaders
      'Content-Type, Authorization',           // AllowHeaders
      'GET,POST,PUT,DELETE,OPTIONS',           // AllowMethods
      600                                      // AccessControlMaxAge (in secondi)
    )
  );

  // File di generate_csv/generate_pdf, serviti su /export. Prima dei controller.
  FMVC.AddMiddleware(
    TMVCStaticFilesMiddleware.Create('/export', TConfig.GetInstance.ExportFolder)
  );

  FMVC.AddController(TControllerFornitori);
  FMVC.AddController(TControllerClienti);
  FMVC.AddController(TControllerMateriePrime);
  FMVC.AddController(TControllerDashboard);
  FMVC.AddController(TControllerOrdiniVendita);
  FMVC.AddController(TControllerProdottiFiniti);
  FMVC.AddController(TControllerSemilavorati);
  // Sola lettura: le ricette si modificano solo dallo scenario 3 in chat.
  FMVC.AddController(TControllerRicette);
  FMVC.AddController(TControllerLottiMateriePrime);
  FMVC.AddController(TControllerLottiSemilavorati);
  FMVC.AddController(TControllerLottiProdottiFiniti);
  FMVC.AddController(TControllerTracciabilita);
  FMVC.AddController(TAIAgentController);
  FMVC.AddController(TControllerEmail);

  // Server MCP: singleton, provider registrati in uFrmMain.
  FMCPServer := TMCPServer.Instance;
  // Factory: un TMCPEndpoint nuovo per ogni richiesta a /mcp.
  FMVC.PublishObject(
    function: TObject
    begin
      Result := FMCPServer.CreatePublishedEndpoint;
    end, MCP_ENDPOINT
  );
  FMVC.AddController(TMCPSessionController);

end;

procedure TWebModule1.WebModuleBeforeDispatch(Sender: TObject; Request: TWebRequest;
  Response: TWebResponse; var Handled: Boolean);
begin
  Handled := False;

  if SameText(Request.Method, 'POST') and (Pos('/mcp', LowerCase(Request.PathInfo)) > 0) then
    TLog.Write('MCP DEBUG - raw request body: ' + Request.Content);
end;

procedure TWebModule1.WebModuleDestroy(Sender: TObject);
begin
  // FMCPServer e' un singleton condiviso, liberato dalla libreria a fine processo.
  FMVC.Free;
end;

end.

