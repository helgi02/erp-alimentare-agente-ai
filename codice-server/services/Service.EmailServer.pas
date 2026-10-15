unit Service.EmailServer;

(* ============================================================================
  TEmailServer - invio di una email (corpo HTML + un allegato facoltativo) via
  SMTP, con i componenti Indy.

  -- Configurazione ----------------------------------------------------------
  I parametri SMTP NON si leggono qui: arrivano da TConfig (common/uConfig.pas,
  record TConfigSMTP), che li carica una volta all'avvio dalla sezione [SMTP]
  dello stesso ini del server (AziendaAlimentareERP.ini), come gia' avviene
  per [Database] e [LLM]:

      [SMTP]
      Host=smtp.gmail.com
      Port=465
      Username=nome@dominio.it
      Password=password-per-le-app
      FromName=Nome Cognome
      FromAddress=nome@dominio.it

  Un solo punto che legge l'ini = un solo posto in cui cercare se l'invio non
  funziona, e nessun file riaperto a ogni email.

  -- Errori ------------------------------------------------------------------
  InviaConAllegato non solleva eccezioni: restituisce False e mette il motivo
  in AErrore. Chi la chiama (un tool MCP) puo' cosi' trasformarlo in un
  errore del tool leggibile dal modello.

  -- Limiti noti (sviluppi futuri, vedi il documento sulla sicurezza) --------
  - il certificato del server SMTP non viene verificato (VerifyMode = []);
  - la password sta in chiaro nell'ini, come quella del database;
  - l'invio e' sincrono: la richiesta HTTP aspetta la risposta del server SMTP.
  Servono le DLL di OpenSSL 1.0.2 (libeay32.dll, ssleay32.dll) accanto
  all'eseguibile, della stessa architettura (64 bit).
  ============================================================================ *)

interface

uses
  System.SysUtils,
  System.Classes,
  IdSMTP,
  IdMessage,
  IdSSLOpenSSL,
  IdExplicitTLSClientServerBase,
  IdAttachmentMemory,
  IdText;

type
  // Allegato tenuto in memoria. Contenuto vuoto = nessun allegato.
  TEmailAllegato = record
    NomeFile   : string;
    ContentType: string;   // es. 'application/pdf'
    Contenuto  : TBytes;
  end;

  TEmailServer = class
  public
    // True se la sezione [SMTP] dell'ini ha almeno Host e FromAddress.
    // AMotivo spiega che cosa manca.
    class function Configurato(out AMotivo: string): Boolean;

    // Controllo di FORMA di un indirizzo: una sola @, qualcosa prima, un
    // dominio con almeno un punto dopo. Non garantisce che la casella
    // esista; ferma i valori che un indirizzo non sono (un nome, un id) e i
    // caratteri con cui si potrebbero aggiungere altri destinatari o altre
    // intestazioni al messaggio (virgola, punto e virgola, a capo). Usato
    // sia dai tool MCP sia dall'endpoint /api/email/invio.
    class function IndirizzoValido(const AIndirizzo: string): Boolean;

    class function InviaConAllegato(
      const ADestinatario, AOggetto, ACorpoHtml: string;
      const AAllegato: TEmailAllegato;
      out AErrore: string): Boolean;
  end;

implementation

uses
  System.IOUtils,
  System.SyncObjs,
  System.JSON,
  uConfig;

// Message-Id univoco: <GUID@dominio-del-mittente>. Il GUID evita collisioni
// fra email inviate nello stesso millisecondo da thread diversi.
function NuovoMessageId(const AIndirizzoMittente: string): string;
var
  LDominio, LGuid: string;
  LPos: Integer;
begin
  LDominio := 'localhost';
  LPos := Pos('@', AIndirizzoMittente);
  if (LPos > 0) and (LPos < Length(AIndirizzoMittente)) then
    LDominio := Copy(AIndirizzoMittente, LPos + 1, MaxInt);

  LGuid := TGUID.NewGuid.ToString;                // {XXXXXXXX-...}
  LGuid := Copy(LGuid, 2, Length(LGuid) - 2);     // senza le graffe
  Result := '<' + LGuid + '@' + LDominio + '>';
end;

var
  // Protegge il file delle email simulate: gli invii arrivano da thread
  // diversi (una richiesta HTTP per thread).
  GLockEmailSimulate: TCriticalSection;

// [SMTP] Simula=1: invece di spedire, aggiunge una riga JSON a
// logs\email_simulate.jsonl accanto all'eseguibile (data, destinatario,
// oggetto, corpo). Serve a provare l'intero flusso - batteria di test
// compresa - senza che parta nulla, e a controllare dopo che cosa sarebbe
// partito.
procedure RegistraEmailSimulata(const ADestinatario, AOggetto, ACorpoHtml: string);
var
  LCartella: string;
  LRiga: TJSONObject;
begin
  LCartella := TPath.Combine(ExtractFilePath(ParamStr(0)), 'logs');
  LRiga := TJSONObject.Create;
  try
    LRiga.AddPair('data', FormatDateTime('yyyy-mm-dd hh:nn:ss', Now));
    LRiga.AddPair('destinatario', ADestinatario);
    LRiga.AddPair('oggetto', AOggetto);
    LRiga.AddPair('corpo', ACorpoHtml);
    GLockEmailSimulate.Enter;
    try
      ForceDirectories(LCartella);
      TFile.AppendAllText(TPath.Combine(LCartella, 'email_simulate.jsonl'),
        LRiga.ToJSON + sLineBreak, TEncoding.UTF8);
    finally
      GLockEmailSimulate.Leave;
    end;
  finally
    LRiga.Free;
  end;
end;

class function TEmailServer.IndirizzoValido(const AIndirizzo: string): Boolean;
var
  LCarattere: Char;
  LPosChiocciola: Integer;
  LDominio: string;
begin
  Result := False;
  if (AIndirizzo = '') or (Length(AIndirizzo) > 254) then
    Exit;
  for LCarattere in AIndirizzo do
    if (LCarattere <= ' ') or CharInSet(LCarattere, [',', ';', '<', '>', '"', '(', ')']) then
      Exit;

  LPosChiocciola := Pos('@', AIndirizzo);
  if (LPosChiocciola <= 1) or (LPosChiocciola <> LastDelimiter('@', AIndirizzo)) then
    Exit;

  LDominio := Copy(AIndirizzo, LPosChiocciola + 1, MaxInt);
  Result := (Pos('.', LDominio) > 1) and not LDominio.EndsWith('.') and
    (Pos('..', LDominio) = 0);
end;

class function TEmailServer.Configurato(out AMotivo: string): Boolean;
var
  LSMTPConfig: TConfigSMTP;
begin
  LSMTPConfig := TConfig.GetInstance.SMTP;
  // In simulazione non serve nessun server SMTP.
  Result := LSMTPConfig.Simula or
    ((LSMTPConfig.Host <> '') and (LSMTPConfig.FromAddress <> ''));
  if Result then
    AMotivo := ''
  else
    AMotivo := 'Invio email non configurato: nel file ini del server manca la sezione ' +
      '[SMTP] oppure le chiavi Host e FromAddress.';
end;

class function TEmailServer.InviaConAllegato(
  const ADestinatario, AOggetto, ACorpoHtml: string;
  const AAllegato: TEmailAllegato;
  out AErrore: string): Boolean;
var
  LSMTPConfig: TConfigSMTP;
  LSMTP  : TIdSMTP;
  LMsg   : TIdMessage;
  LSSL   : TIdSSLIOHandlerSocketOpenSSL;
  LHtml  : TIdText;
  LMem   : TIdAttachmentMemory;
  LStream: TMemoryStream;
  LDestinatario, LOggetto: string;
begin
  Result := False;

  // Prima di creare qualunque oggetto: senza configurazione il messaggio
  // d'errore deve dire "manca [SMTP]", non un generico errore di connessione.
  if not Configurato(AErrore) then
    Exit;

  // Copia letta UNA volta: tutto l'invio lavora sugli stessi valori.
  LSMTPConfig := TConfig.GetInstance.SMTP;

  // Protezioni per prove e dimostrazioni (vedi TConfigSMTP in uConfig.pas).
  if LSMTPConfig.Simula then
  begin
    RegistraEmailSimulata(ADestinatario, AOggetto, ACorpoHtml);
    AErrore := '';
    Exit(True);
  end;
  LDestinatario := ADestinatario;
  LOggetto := AOggetto;
  if LSMTPConfig.ReindirizzaA <> '' then
  begin
    LOggetto := '[per: ' + ADestinatario + '] ' + AOggetto;
    LDestinatario := LSMTPConfig.ReindirizzaA;
  end;

  LSMTP   := TIdSMTP.Create(nil);
  LMsg    := TIdMessage.Create(nil);
  LSSL    := TIdSSLIOHandlerSocketOpenSSL.Create(nil);
  LStream := TMemoryStream.Create;
  try
    try
      // --- SSL / TLS ---
      LSSL.SSLOptions.Method      := sslvTLSv1_2;
      LSSL.SSLOptions.Mode        := sslmClient;
      LSSL.SSLOptions.VerifyMode  := [];
      LSSL.SSLOptions.VerifyDepth := 0;

      // --- Parametri SMTP (sezione [SMTP] dell'ini, via TConfig) ---
      LSMTP.IOHandler := LSSL;
      LSMTP.Host      := LSMTPConfig.Host;
      LSMTP.Port      := LSMTPConfig.Port;
      LSMTP.Username  := LSMTPConfig.Username;
      LSMTP.Password  := LSMTPConfig.Password;

      // La porta decide il tipo di TLS: 465 = cifrato dal primo byte
      // (implicito); 587 o 25 = connessione in chiaro che passa a TLS con
      // il comando STARTTLS (esplicito).
      if LSMTPConfig.Port = 465 then
        LSMTP.UseTLS := utUseImplicitTLS
      else
        LSMTP.UseTLS := utUseExplicitTLS;

      // --- Intestazione messaggio ---
      LMsg.From.Name    := LSMTPConfig.FromName;
      LMsg.From.Address := LSMTPConfig.FromAddress;
      LMsg.Subject      := LOggetto;
      LMsg.ContentType  := 'multipart/mixed';
      LMsg.CharSet      := 'UTF-8';
      LMsg.Recipients.EMailAddresses := LDestinatario;
      LMsg.MsgId        := NuovoMessageId(LSMTPConfig.FromAddress);

      // --- Corpo HTML ---
      LHtml := TIdText.Create(LMsg.MessageParts);
      LHtml.ContentType := 'text/html; charset=UTF-8';
      LHtml.CharSet     := 'UTF-8';
      LHtml.Body.Text   := ACorpoHtml;

      // --- Allegato da memoria ---
      if Length(AAllegato.Contenuto) > 0 then
      begin
        LStream.WriteBuffer(AAllegato.Contenuto[0], Length(AAllegato.Contenuto));
        LStream.Position := 0;
        // TIdAttachmentMemory COPIA il contenuto di LStream in un proprio
        // stream interno: non ne diventa proprietario. LStream resta
        // quindi nostro e va liberato nel finally (prima non veniva
        // liberato: a ogni email con allegato restava occupata memoria).
        LMem := TIdAttachmentMemory.Create(LMsg.MessageParts, LStream);
        LMem.FileName        := AAllegato.NomeFile;
        LMem.ContentType     := AAllegato.ContentType;
        LMem.ContentTransfer := 'base64';
      end;

      // --- Invio (sincrono) ---
      LSMTP.Connect;
      try
        LSMTP.Send(LMsg);
      finally
        LSMTP.Disconnect;
      end;

      AErrore := '';
      Result  := True;
    except
      on E: Exception do
      begin
        AErrore := E.Message;
        Result  := False;
      end;
    end;
  finally
    // LHtml e LMem appartengono a LMsg.MessageParts: li libera LMsg.Free.
    LStream.Free;
    LSSL.Free;
    LMsg.Free;
    LSMTP.Free;
  end;
end;

initialization
  GLockEmailSimulate := TCriticalSection.Create;

finalization
  GLockEmailSimulate.Free;

end.
