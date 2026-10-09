unit uRetrieverPiano;

(* ============================================================================
  RETRIEVAL PER AZIONE - tappa 5 del porting del pianificatore.
  Porting di scripts/prototipo_pianificatore/pianificatore/retriever.py
  (specifica: CONTRATTI.md, paragrafo 6).

  -- Differenza rispetto all'orchestratore attuale -----------------------------
  TServizioAgente.SelezionaToolPerDomanda cerca i tool sulla DOMANDA intera
  dell'utente e seleziona per provider. Qui la ricerca si fa su ogni AZIONE
  del piano ("trova le spedizioni ai clienti dei lotti del passo 1"): un
  testo breve che descrive una sola operazione si avvicina a un solo tool
  molto piu' di una domanda che ne contiene due.

  -- Cosa fa -------------------------------------------------------------------
  Per ogni passo del piano:
    1. calcola i punteggi di tutti i tool rispetto all'azione (una sola
       richiesta di embedding per tutte le azioni del piano);
    2. sceglie i CANDIDATI: i primi K per punteggio, piu' quelli entro un
       MARGINE dal migliore, al massimo KMax;
    3. se il passo e' concreto (il Planner ha gia' scritto un tool noto),
       controlla la scelta: il tool si tiene solo se e' il PRIMO per punteggio
       su quell'azione. Altrimenti il passo viene DECLASSATO: perde tool e
       argomenti e torna astratto, sara' il Completer a scegliere fra i
       candidati. (Regola del 01/10: il Planner tendeva a riusare un tool
       noto anche per un'azione diversa.)
    4. se il passo e' astratto e non ha candidati, e' NON COPERTO: il
       gestionale non ha un tool per quell'azione e il turno si ferma.

  Deterministico: nessuna chiamata al modello di chat.
  ============================================================================ *)

interface

uses
  System.SysUtils,
  System.Generics.Collections,
  uIndiceEmbeddingTool,
  uPianificatore;

type
  TConfigRetrieval = record
    K: Integer;          // candidati sempre ammessi (i primi K)
    Margine: Double;     // ammessi anche quelli entro Margine dal migliore
    KMax: Integer;       // tetto ai candidati di un passo
    SMin: Double;        // punteggio minimo (0 = nessun minimo)
    // Valori del run conv_20261001_235839: K=2, Margine=0.03, KMax=6, SMin=0.
    class function Predefinita: TConfigRetrieval; static;
  end;

  TDecisionePasso = class
  public
    Id: Integer;
    Azione: string;
    // Tutti i tool con il loro punteggio su questa azione, dal migliore.
    Punteggi: TArray<TToolPertinente>;
    Candidati: TArray<string>;
    // Solo per i passi che il Planner aveva scritto concreti.
    ToolDichiarato: string;
    RangoDichiarato: Integer;    // 1 = primo; 0 = tool non presente nell'indice
    Declassato: Boolean;
    NonCoperto: Boolean;
  end;

  TRisultatoRetrieval = class
  public
    Decisioni: TObjectList<TDecisionePasso>;
    constructor Create;
    destructor Destroy; override;
    function Declassamenti: Integer;
    function NonCoperti: TArray<Integer>;
    // Candidati del passo AIdPasso (vuoto se il passo non c'e').
    function CandidatiDi(AIdPasso: Integer): TArray<string>;
    // I passi ancora astratti con i loro candidati, nell'ordine del piano:
    // e' l'ingresso di TPianificatore.RichiestaCompletamento.
    function CandidatiPerCompletamento(APiano: TPiano): TArray<TCandidatiPasso>;
  end;

  TRetrieverPiano = class
  public
    // C = (primi K  U  {punteggio >= migliore - Margine})  con punteggio >=
    // SMin, al massimo max(KMax, K), in ordine di punteggio.
    class function Candidati(const APunteggi: TArray<TToolPertinente>;
      const AConfig: TConfigRetrieval): TArray<string>;

    // Calcola i candidati di ogni passo e DECLASSA i passi concreti il cui
    // tool non passa il controllo. MODIFICA il piano: un passo declassato
    // perde tool e argomenti, l'azione resta. Il risultato e' del chiamante.
    class function SelezionaToolPerAzioni(APiano: TPiano;
      const AConfig: TConfigRetrieval): TRisultatoRetrieval;
  end;

implementation

{ TConfigRetrieval }

class function TConfigRetrieval.Predefinita: TConfigRetrieval;
begin
  Result.K := 2;
  Result.Margine := 0.03;
  Result.KMax := 6;
  Result.SMin := 0.0;
end;

{ TRisultatoRetrieval }

constructor TRisultatoRetrieval.Create;
begin
  inherited;
  Decisioni := TObjectList<TDecisionePasso>.Create(True);
end;

destructor TRisultatoRetrieval.Destroy;
begin
  Decisioni.Free;
  inherited;
end;

function TRisultatoRetrieval.Declassamenti: Integer;
var
  LDecisione: TDecisionePasso;
begin
  Result := 0;
  for LDecisione in Decisioni do
    if LDecisione.Declassato then
      Inc(Result);
end;

function TRisultatoRetrieval.NonCoperti: TArray<Integer>;
var
  LDecisione: TDecisionePasso;
begin
  Result := nil;
  for LDecisione in Decisioni do
    if LDecisione.NonCoperto then
      Result := Result + [LDecisione.Id];
end;

function TRisultatoRetrieval.CandidatiDi(AIdPasso: Integer): TArray<string>;
var
  LDecisione: TDecisionePasso;
begin
  Result := nil;
  for LDecisione in Decisioni do
    if LDecisione.Id = AIdPasso then
      Exit(LDecisione.Candidati);
end;

function TRisultatoRetrieval.CandidatiPerCompletamento(APiano: TPiano): TArray<TCandidatiPasso>;
var
  LPasso: TPasso;
  LVoce: TCandidatiPasso;
begin
  Result := nil;
  for LPasso in APiano.Passi do
    if not LPasso.Concreto then
    begin
      LVoce.Id := LPasso.Id;
      LVoce.Azione := LPasso.Azione;
      LVoce.Tool := CandidatiDi(LPasso.Id);
      Result := Result + [LVoce];
    end;
end;

{ TRetrieverPiano }

class function TRetrieverPiano.Candidati(const APunteggi: TArray<TToolPertinente>;
  const AConfig: TConfigRetrieval): TArray<string>;
var
  LMigliore: Double;
  LTetto, i: Integer;
begin
  Result := nil;
  if Length(APunteggi) = 0 then
    Exit;
  LMigliore := APunteggi[0].Similarita;
  LTetto := AConfig.KMax;
  if AConfig.K > LTetto then
    LTetto := AConfig.K;

  for i := 0 to High(APunteggi) do
  begin
    if Length(Result) >= LTetto then
      Break;
    // i + 1 e' il rango (1 = migliore).
    if ((i + 1 <= AConfig.K) or (APunteggi[i].Similarita >= LMigliore - AConfig.Margine)) and
       (APunteggi[i].Similarita >= AConfig.SMin) then
      Result := Result + [APunteggi[i].NomeTool];
  end;
end;

class function TRetrieverPiano.SelezionaToolPerAzioni(APiano: TPiano;
  const AConfig: TConfigRetrieval): TRisultatoRetrieval;
var
  LAzioni: TArray<string>;
  LTutti: TArray<TArray<TToolPertinente>>;
  LPasso: TPasso;
  LDecisione: TDecisionePasso;
  i, j: Integer;
begin
  SetLength(LAzioni, APiano.Passi.Count);
  for i := 0 to APiano.Passi.Count - 1 do
    LAzioni[i] := APiano.Passi[i].Azione;
  // Una sola richiesta di embedding per tutte le azioni del piano.
  LTutti := TIndiceEmbeddingTool.PunteggiPerTesti(LAzioni);

  Result := TRisultatoRetrieval.Create;
  try
    for i := 0 to APiano.Passi.Count - 1 do
    begin
      LPasso := APiano.Passi[i];
      LDecisione := TDecisionePasso.Create;
      Result.Decisioni.Add(LDecisione);
      LDecisione.Id := LPasso.Id;
      LDecisione.Azione := LPasso.Azione;
      LDecisione.Punteggi := LTutti[i];
      LDecisione.Candidati := Candidati(LTutti[i], AConfig);

      if LPasso.Concreto then
      begin
        LDecisione.ToolDichiarato := LPasso.Tool;
        LDecisione.RangoDichiarato := 0;
        for j := 0 to High(LTutti[i]) do
          if LTutti[i][j].NomeTool = LPasso.Tool then
          begin
            LDecisione.RangoDichiarato := j + 1;
            Break;
          end;
        // Il tool scelto dal Planner si tiene solo se e' il PRIMO per
        // punteggio su questa azione; altrimenti il passo torna astratto.
        if LDecisione.RangoDichiarato <> 1 then
        begin
          LDecisione.Declassato := True;
          LPasso.Tool := '';
          FreeAndNil(LPasso.Argomenti);
        end;
      end;

      if not LPasso.Concreto and (Length(LDecisione.Candidati) = 0) then
        LDecisione.NonCoperto := True;
    end;
  except
    Result.Free;
    raise;
  end;
end;

end.
