unit Service.EmailServer;

// Invio di una email (corpo HTML + un allegato facoltativo) via SMTP con Indy.
// I parametri non si leggono qui: arrivano da TConfig (TConfigSMTP), caricati una volta
// all'avvio dalla sezione [SMTP] dell'ini (Host, Port, Username, Password, FromName,
// FromAddress). Un solo punto che legge l'ini, nessun file riaperto a ogni email.
// InviaConAllegato non solleva eccezioni: restituisce False e il motivo in AErrore, cosi'
// un tool MCP lo trasforma in un errore leggibile dal modello.
// Limiti noti (sviluppi futuri, vedi il documento sulla sicurezza): il certificato SMTP non
// e' verificato (VerifyMode = []); la password e' in chiaro nell'ini; l'invio e' sincrono.
// Servono le DLL OpenSSL 1.0.2 (libeay32.dll, ssleay32.dll) a 64 bit accanto
// all'eseguibile.

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
  // Allegato in memoria. Contenuto vuoto = nessun allegato.
  TEmailAllegato = record
    NomeFile   : string;
    ContentType: string;   // es. 'application/pdf'
    Contenuto  : TBytes;
  end;

  TEmailServer = class
  public
    // True se [SMTP] ha almeno Host e FromAddress; AMotivo dice cosa manca.
    class function Configurato(out AMotivo: string): Boolean;

    // Controllo di forma: una sola @, qualcosa prima, un dominio con un punto dopo. Non
    // garantisce che la casella esista; ferma valori che non sono indirizzi (un nome, un
    // id) e i caratteri con cui si aggiungerebbero destinatari o intestazioni (virgola,
    // punto e virgola, a capo). Usato dai tool MCP e da /api/email/invio.
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

// Message-Id <GUID@dominio-del-mittente>: il GUID evita collisioni fra thread nello stesso
// millisecondo.
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
  // Protegge il file delle email simulate: gli invii arrivano da thread diversi.
  GLockEmailSimulate: TCriticalSection;

// [SMTP] Simula=1: invece di spedire, aggiunge una riga JSON a logs\email_simulate.jsonl
// (data, destinatario, oggetto, corpo). Per provare il flusso senza inviare nulla e
// controllare cosa sarebbe partito.
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
  // In simulazione non serve un server SMTP.
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

  // Prima di creare oggetti: senza configurazione l'errore deve dire "manca [SMTP]", non un
  // generico errore di connessione.
  if not Configurato(AErrore) then
    Exit;

  // Copia letta una volta: tutto l'invio usa gli stessi valori.
  LSMTPConfig := TConfig.GetInstance.SMTP;

  // Protezioni per prove e dimostrazioni (TConfigSMTP).
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
      LSSL.SSLOptions.Method      := sslvTLSv1_2;
      LSSL.SSLOptions.Mode        := sslmClient;
      LSSL.SSLOptions.VerifyMode  := [];
      LSSL.SSLOptions.VerifyDepth := 0;

      LSMTP.IOHandler := LSSL;
      LSMTP.Host      := LSMTPConfig.Host;
      LSMTP.Port      := LSMTPConfig.Port;
      LSMTP.Username  := LSMTPConfig.Username;
      LSMTP.Password  := LSMTPConfig.Password;

      // La porta decide il TLS: 465 = implicito (cifrato dal primo byte); 587 o 25 = in
      // chiaro, poi STARTTLS.
      if LSMTPConfig.Port = 465 then
        LSMTP.UseTLS := utUseImplicitTLS
      else
        LSMTP.UseTLS := utUseExplicitTLS;

      LMsg.From.Name    := LSMTPConfig.FromName;
      LMsg.From.Address := LSMTPConfig.FromAddress;
      LMsg.Subject      := LOggetto;
      LMsg.ContentType  := 'multipart/mixed';
      LMsg.CharSet      := 'UTF-8';
      LMsg.Recipients.EMailAddresses := LDestinatario;
      LMsg.MsgId        := NuovoMessageId(LSMTPConfig.FromAddress);

      LHtml := TIdText.Create(LMsg.MessageParts);
      LHtml.ContentType := 'text/html; charset=UTF-8';
      LHtml.CharSet     := 'UTF-8';
      LHtml.Body.Text   := ACorpoHtml;

      if Length(AAllegato.Contenuto) > 0 then
      begin
        LStream.WriteBuffer(AAllegato.Contenuto[0], Length(AAllegato.Contenuto));
        LStream.Position := 0;
        // TIdAttachmentMemory copia il contenuto di LStream senza esserne proprietario:
        // LStream resta nostro e va liberato nel finally.
        LMem := TIdAttachmentMemory.Create(LMsg.MessageParts, LStream);
        LMem.FileName        := AAllegato.NomeFile;
        LMem.ContentType     := AAllegato.ContentType;
        LMem.ContentTransfer := 'base64';
      end;

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
