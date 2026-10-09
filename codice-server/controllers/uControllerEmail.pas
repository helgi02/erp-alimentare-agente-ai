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
  // Invio di email GIA' PRONTE (destinatario, oggetto, testo) su richiesta
  // diretta del frontend.
  //
  // -- A cosa serve ---------------------------------------------------------
  // Dopo anteprima_email_da_modello la chat mostra le bozze in un modulo in
  // cui l'utente puo' correggere oggetto e testo di ogni email. Il testo
  // corretto NON puo' ripassare dall'agente: invia_email_da_modello
  // ricompone le email dal modello e le correzioni andrebbero perse (e far
  // riscrivere il testo al modello di linguaggio e' proprio cio' che si e'
  // voluto evitare). Il pulsante "Invia" del modulo chiama quindi questo
  // endpoint, senza passare dal modello: stesso principio dei pulsanti di
  // conferma, dove il clic dell'utente sostituisce una chiamata all'LLM.
  //
  // -- Chi conferma ---------------------------------------------------------
  // Il clic su "Invia" E' la conferma: l'utente ha il testo definitivo sotto
  // gli occhi. Per questo qui non c'e' il passaggio di conferma che il
  // pianificatore impone ai tool di scrittura.
  //
  // -- Limiti ---------------------------------------------------------------
  // Come il resto delle API del gestionale, l'endpoint non richiede
  // autenticazione (vedi il documento sugli sviluppi futuri di sicurezza):
  // chi raggiunge il server puo' far partire email dalla casella aziendale.
  // L'agente non viene informato dell'invio: lo storico della conversazione
  // contiene l'anteprima, non l'esito.
  //
  // Controller sottile: validazione, un ciclo di invii con TEmailServer e
  // l'esito riga per riga (stessa forma di invia_email_da_modello).
  [MVCPath('/api/email')]
  TControllerEmail = class(TMVCController)
  public
    // Corpo:    { "messaggi": [ { "email", "oggetto", "corpo" }, ... ] }
    // Risposta: { "inviate", "non_inviate",
    //             "dettaglio": [ { "email", "oggetto", "inviata", "errore" } ] }
    // 400 se un messaggio non e' valido (non parte NESSUNA email).
    [MVCPath('/invio')]
    [MVCHTTPMethod([httpPOST])]
    procedure Invia(ctx: TWebContext);
  end;

implementation

const
  // Stesso tetto di invia_email_da_modello (uEmailToolProvider.pas).
  MAX_MESSAGGI = 100;

// Valore testuale di un campo, '' se assente o non stringa.
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

// Oggetto su una riga sola: e' un'intestazione del messaggio.
function OggettoSuUnaRiga(const AOggetto: string): string;
begin
  Result := StringReplace(AOggetto, #13, ' ', [rfReplaceAll]);
  Result := Trim(StringReplace(Result, #10, ' ', [rfReplaceAll]));
end;

{ TControllerEmail }

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

    // 1. Validazione di TUTTI i messaggi prima di inviarne uno: un modulo
    //    compilato male non deve produrre un invio a meta'.
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

    // 2. Invio, una email separata per destinatario. Un errore riguarda la
    //    singola email: le altre si tentano comunque e la risposta dice,
    //    riga per riga, che cosa e' partito.
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

        // Il testo arriva dalla textarea come testo semplice: TestoComeHtml
        // protegge i caratteri speciali e trasforma gli a capo in <br>.
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

    // Render prende possesso di LRisposta e lo libera (vedi
    // uControllerDashboard.pas): nessuna Free qui.
    Render(LRisposta);
  finally
    LValore.Free;
  end;
end;

end.
