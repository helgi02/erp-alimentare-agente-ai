unit uControllerEmail;

interface

uses
  System.SysUtils,
  System.JSON,
  MVCFramework,
  MVCFramework.Commons,
  Service.EmailServer,
  uServiziModelliEmail;

type
  // Invio di email gia' pronte (destinatario, oggetto, testo) su richiesta diretta del
  // frontend.
  // Dopo anteprima_email_da_modello la chat mostra le bozze modificabili. Il testo corretto
  // non puo' ripassare dall'agente: invia_email_da_modello ricomporrebbe le email dal
  // modello perdendo le correzioni (e farle riscrivere al modello e' cio' che si voleva
  // evitare). Il pulsante "Invia" chiama quindi questo endpoint, come i pulsanti di
  // conferma. Il clic e' la conferma: l'utente ha il testo definitivo sotto gli occhi.
  // Limiti: come il resto delle API, nessuna autenticazione (vedi sviluppi futuri di
  // sicurezza): chi raggiunge il server puo' far partire email dalla casella aziendale.
  // L'agente non sa dell'invio: lo storico contiene l'anteprima, non l'esito.
  // Controller sottile: validazione, ciclo di invii con TEmailServer, esito riga per riga
  // (come invia_email_da_modello).
  [MVCPath('/api/email')]
  TControllerEmail = class(TMVCController)
  public
    // Corpo: { "messaggi": [ { "email", "oggetto", "corpo" } ] }. Risposta: { "inviate",
    // "non_inviate", "dettaglio": [ { "email", "oggetto", "inviata", "errore" } ] }. 400 se
    // un messaggio non e' valido (non parte nessuna email).
    [MVCPath('/invio')]
    [MVCHTTPMethod([httpPOST])]
    procedure Invia(ctx: TWebContext);
  end;

implementation

const
  // Stesso tetto di invia_email_da_modello.
  MAX_MESSAGGI = 100;

function Testo(AOggetto: TJSONObject; const ANome: string): string;
var
  LValore: TJSONValue;
begin
  LValore := AOggetto.GetValue(ANome);
  if LValore is TJSONString then
    Result := TJSONString(LValore).Value
  else
    Result := '';
end;

// Oggetto su una riga: e' un'intestazione.
function OggettoSuUnaRiga(const AOggetto: string): string;
begin
  Result := StringReplace(AOggetto, #13, ' ', [rfReplaceAll]);
  Result := Trim(StringReplace(Result, #10, ' ', [rfReplaceAll]));
end;

procedure TControllerEmail.Invia(ctx: TWebContext);
var
  LBody, LMessaggio, LRisposta, LRiga: TJSONObject;
  LValore: TJSONValue;
  LMessaggi, LDettaglio: TJSONArray;
  LEmail, LOggetto, LErrore: string;
  LInviate, LNonInviate, I: Integer;
  LInviata: Boolean;
begin
  LValore := TJSONObject.ParseJSONValue(ctx.Request.Body);
  try
    if not (LValore is TJSONObject) then
    begin
      Render(HTTP_STATUS.BadRequest, 'Corpo della richiesta non e'' un JSON valido.');
      Exit;
    end;
    LBody := TJSONObject(LValore);

    if not (LBody.GetValue('messaggi') is TJSONArray) then
    begin
      Render(HTTP_STATUS.BadRequest, 'Campo "messaggi" mancante: serve un elenco di email.');
      Exit;
    end;
    LMessaggi := TJSONArray(LBody.GetValue('messaggi'));
    if (LMessaggi.Count = 0) or (LMessaggi.Count > MAX_MESSAGGI) then
    begin
      Render(HTTP_STATUS.BadRequest,
        Format('Le email da inviare devono essere fra 1 e %d.', [MAX_MESSAGGI]));
      Exit;
    end;

    // Si validano tutti i messaggi prima di inviarne uno: un modulo compilato male non deve
    // produrre un invio a meta'.
    for I := 0 to LMessaggi.Count - 1 do
    begin
      if not (LMessaggi.Items[I] is TJSONObject) then
      begin
        Render(HTTP_STATUS.BadRequest, Format('Email %d: formato non valido.', [I + 1]));
        Exit;
      end;
      LMessaggio := TJSONObject(LMessaggi.Items[I]);
      LEmail := Trim(Testo(LMessaggio, 'email'));
      if not TEmailServer.IndirizzoValido(LEmail) then
      begin
        Render(HTTP_STATUS.BadRequest,
          Format('Email %d: "%s" non e'' un indirizzo valido.', [I + 1, LEmail]));
        Exit;
      end;
      if OggettoSuUnaRiga(Testo(LMessaggio, 'oggetto')) = '' then
      begin
        Render(HTTP_STATUS.BadRequest, Format('Email %d (%s): l''oggetto e'' vuoto.', [I + 1, LEmail]));
        Exit;
      end;
      if Trim(Testo(LMessaggio, 'corpo')) = '' then
      begin
        Render(HTTP_STATUS.BadRequest, Format('Email %d (%s): il testo e'' vuoto.', [I + 1, LEmail]));
        Exit;
      end;
    end;

    if not TEmailServer.Configurato(LErrore) then
    begin
      Render(HTTP_STATUS.InternalServerError, LErrore);
      Exit;
    end;

    // Una email separata per destinatario. Un errore riguarda la singola email: le altre si
    // tentano e la risposta dice riga per riga cosa e' partito.
    LInviate := 0;
    LNonInviate := 0;
    LRisposta := TJSONObject.Create;
    try
      LDettaglio := TJSONArray.Create;
      LRisposta.AddPair('dettaglio', LDettaglio);
      for I := 0 to LMessaggi.Count - 1 do
      begin
        LMessaggio := TJSONObject(LMessaggi.Items[I]);
        LEmail := Trim(Testo(LMessaggio, 'email'));
        LOggetto := OggettoSuUnaRiga(Testo(LMessaggio, 'oggetto'));

        // Il testo e' semplice: TestoComeHtml protegge i caratteri speciali e trasforma gli
        // a capo in <br>.
        LInviata := TEmailServer.InviaConAllegato(LEmail, LOggetto,
          TServizioModelliEmail.TestoComeHtml(Testo(LMessaggio, 'corpo')),
          Default(TEmailAllegato), LErrore);
        if LInviata then
          Inc(LInviate)
        else
          Inc(LNonInviate);

        LRiga := TJSONObject.Create;
        LDettaglio.AddElement(LRiga);
        LRiga.AddPair('email', LEmail);
        LRiga.AddPair('oggetto', LOggetto);
        LRiga.AddPair('inviata', TJSONBool.Create(LInviata));
        LRiga.AddPair('errore', LErrore);
      end;
      LRisposta.AddPair('inviate', TJSONNumber.Create(LInviate));
      LRisposta.AddPair('non_inviate', TJSONNumber.Create(LNonInviate));
    except
      LRisposta.Free;
      raise;
    end;

    // Render libera LRisposta (vedi uControllerDashboard): niente Free.
    Render(LRisposta);
  finally
    LValore.Free;
  end;
end;

end.
