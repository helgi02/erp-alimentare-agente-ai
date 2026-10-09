unit uFrasiEsempioTool;

(* ============================================================================
  TFrasiEsempioTool -- elenco di formulazioni utente, scritte a mano, per
  ciascun tool MCP: la materia prima del retrieval semantico (fase 1
  dell'orchestratore, vedi agente_ai/3_scelta_tool/uIndiceEmbeddingTool.pas).

  -- Perche' queste frasi esistono separate dalla descrizione del tool -------
  La descrizione di un tool (l'attributo [MCPTool] o Description in
  GetDynamicToolDefs) e' scritta per il modello, nel registro tecnico del
  progetto: "Restituisce gli ordini di vendita e le relative righe prodotto,
  filtrabili per cliente, prodotto e periodo". Un utente reale scrive
  "quanto abbiamo venduto ai Rossi a marzo?". Sono due registri linguistici
  distanti: l'embedding del primo non e' vicino all'embedding del secondo
  quanto lo e' l'embedding del secondo a se stesso. Le frasi qui sotto
  colmano proprio quella distanza.

  -- Perche' NomeTool e' una stringa libera, non un riferimento tipizzato ----
  Questo file non importa uCatalogoTool ne' uRegistroProviderMCP: e' puro
  dato, senza dipendenze dal resto del sistema di tool. La conseguenza e'
  che una voce puo' restare orfana (tool rinominato o rimosso) senza che il
  compilatore se ne accorga. La CONVALIDA (verificare che ogni NomeTool
  corrisponda a un tool davvero registrato oggi) avviene altrove, in
  TIndiceEmbeddingTool.Sincronizza - l'unico punto che conosce sia questo
  elenco sia l'elenco reale dei tool - e li' un refuso produce un log di
  avviso e uno scarto della riga, non un crash del server: un buco nel
  retrieval degrada la fase 1, non rende il gestionale inutilizzabile.

  -- Frasi in stile AZIONE (aggiunte il 30/09/2026) ---------------------------
  Oltre alle frasi in stile DOMANDA dell'utente, ogni tool ha 2-4 frasi in stile
  AZIONE ("verbo + oggetto": "elenca le vendite di un cliente"). Servono al
  nuovo orchestratore "pianifica ed esegui": il retrieval non confronta piu'
  la domanda dell'utente ma ogni AZIONE del piano scritto dal modello, e le
  azioni hanno un registro diverso da entrambi quelli sopra (ne' domanda ne'
  descrizione tecnica). Misura nel prototipo (scripts/prototipo_pianificatore,
  esperimento_recall.py --frasi-extra, 60 turni della batteria, stessi piani):
  recall del tool giusto al primo posto 0.733 -> 0.933 sulle azioni e
  0.842 -> 0.875 anche sulla domanda grezza, nessun turno peggiorato.
  Come le altre, sono scritte a partire dalla descrizione del tool, con
  valori generici: nessun nome, codice o periodo del dataset di valutazione.
  Valgono le stesse regole "MAX per tool" dei blocchi sotto (ogni frase
  nomina il proprio dominio). Le frasi sono tenute allineate con
  scripts/prototipo_pianificatore/frasi_azione.json.

  -- Come aggiungere o correggere una frase -----------------------------------
  Aggiungi/modifica una riga qui sotto. Al prossimo avvio del server,
  Sincronizza calcola l'embedding SOLO per le frasi nuove o il cui testo e'
  cambiato (confronto per hash SHA-256, vedi quel file): le altre non
  ripagano alcuna chiamata a LM Studio.
  ============================================================================ *)

interface

type
  TFraseEsempio = record
    NomeTool: string;
    Testo: string;
    constructor Create(const ANomeTool, ATesto: string);
  end;

  TFrasiEsempioTool = class
  public
    class function Elenco: TArray<TFraseEsempio>;
  end;

implementation

{ TFraseEsempio }

constructor TFraseEsempio.Create(const ANomeTool, ATesto: string);
begin
  NomeTool := ANomeTool;
  Testo := ATesto;
end;

{ TFrasiEsempioTool }

class function TFrasiEsempioTool.Elenco: TArray<TFraseEsempio>;
begin
  Result := TArray<TFraseEsempio>.Create(

    // --- get_list_vendite (provider: vendite) -------------------------
    TFraseEsempio.Create('get_list_vendite', 'quanto abbiamo venduto al cliente Rossi a marzo?'),
    TFraseEsempio.Create('get_list_vendite', 'fammi vedere gli ordini di vendita dell''ultimo mese'),
    TFraseEsempio.Create('get_list_vendite', 'che fatturato abbiamo fatto con la mozzarella?'),
    TFraseEsempio.Create('get_list_vendite', 'a chi abbiamo venduto negli ultimi 15 giorni?'),
    TFraseEsempio.Create('get_list_vendite', 'elenco vendite di gennaio'),
    TFraseEsempio.Create('get_list_vendite', 'quanto abbiamo fatturato in totale quest''anno?'),
    TFraseEsempio.Create('get_list_vendite', 'dammi le vendite di marzo'),
    // Formulazioni BREVI e con identificativi (nome cliente, codice PF, id),
    // aggiunte dopo la prima serie di valutazione (Qwen 3.5 9B, nucleo): con
    // le sole frasi lunghe sopra, richieste come 'Vendite a <cliente>.' o
    // 'Vendite del prodotto <codice>.' avevano una similarita' con
    // get_list_vendite (~0.84) quasi indistinguibile da generate_pdf, apri_vista
    // e get_ricetta_prodotto_finito, e il provider 'vendite' veniva scartato.
    // Volutamente NON si usano i nomi di clienti/prodotti/id del dataset di
    // valutazione, per non adattare l'indice ai test (overfitting): le frasi
    // descrivono il PATTERN d'uso, non i casi di prova. Ognuna nomina sempre
    // 'vendite', 'ordini' o 'venduto' (vedi avvertimento MAX per tool sotto).
    TFraseEsempio.Create('get_list_vendite', 'vendite a Pasticceria Bianchi'),
    TFraseEsempio.Create('get_list_vendite', 'vendite del prodotto PF012'),
    TFraseEsempio.Create('get_list_vendite', 'vendite del prodotto con id 12'),
    TFraseEsempio.Create('get_list_vendite', 'ordini di vendita del cliente con id 5'),
    TFraseEsempio.Create('get_list_vendite', 'cosa ha acquistato il cliente Alimentari Verdi?'),
    TFraseEsempio.Create('get_list_vendite', 'quanto abbiamo venduto di questo prodotto?'),
    TFraseEsempio.Create('get_list_vendite', 'vendite al cliente Verdi del prodotto Colomba tra aprile e giugno'),
    TFraseEsempio.Create('get_list_vendite', 'vendite dal 1 gennaio al 31 marzo'),
    TFraseEsempio.Create('get_list_vendite', 'ultime vendite'),
    // Stile AZIONE (per il pianificatore, vedi intestazione)
    TFraseEsempio.Create('get_list_vendite', 'elenca le vendite di un cliente'),
    TFraseEsempio.Create('get_list_vendite', 'interroga le vendite di un prodotto in un periodo'),
    TFraseEsempio.Create('get_list_vendite', 'calcola il totale venduto in un periodo'),
    TFraseEsempio.Create('get_list_vendite', 'elenca gli ordini di vendita con le righe prodotto'),

    // --- get_cliente (provider: clienti) ------------------------------
    // Rischio di confusione con get_list_vendite, che nomina spesso un
    // cliente ("vendite a Pasticceria Bianchi"). Per la regola "MAX per
    // tool" (vedi piu' sotto) ogni frase qui nomina quindi SEMPRE un dato
    // ANAGRAFICO (anagrafica, partita IVA, indirizzo, email, telefono, sede)
    // e mai vendite/ordini/acquisti.
    TFraseEsempio.Create('get_cliente', 'dammi i dati anagrafici del cliente Rossi'),
    TFraseEsempio.Create('get_cliente', 'qual e'' la partita IVA di questo cliente?'),
    TFraseEsempio.Create('get_cliente', 'di chi e'' la partita IVA 12345678901?'),
    TFraseEsempio.Create('get_cliente', 'che indirizzo di consegna ha il cliente Bianchi?'),
    TFraseEsempio.Create('get_cliente', 'mostrami l''anagrafica del cliente con id 5'),
    TFraseEsempio.Create('get_cliente', 'email e telefono del cliente Alimentari Verdi'),
    TFraseEsempio.Create('get_cliente', 'dove ha la sede di fatturazione questo cliente?'),
    // Stile AZIONE (per il pianificatore, vedi intestazione)
    TFraseEsempio.Create('get_cliente', 'leggi i dati anagrafici di un cliente'),
    TFraseEsempio.Create('get_cliente', 'cerca un cliente per partita IVA'),
    TFraseEsempio.Create('get_cliente', 'recupera indirizzi e contatti di un cliente'),

    // --- invia_email (provider: email) --------------------------------
    // Ogni frase nomina SEMPRE "email" o "mail" (regola "MAX per tool", vedi
    // piu' sotto): un generico "avvisa il cliente" o "mandaglielo" si
    // aggancerebbe anche a richieste che con la posta non c'entrano.
    TFraseEsempio.Create('invia_email', 'manda una email a questo indirizzo per avvisare del ritardo'),
    TFraseEsempio.Create('invia_email', 'scrivi una mail al cliente Rossi'),
    TFraseEsempio.Create('invia_email', 'invia questa comunicazione via email'),
    TFraseEsempio.Create('invia_email', 'mandagli una mail con queste informazioni'),
    TFraseEsempio.Create('invia_email', 'avvisa il cliente per email'),
    TFraseEsempio.Create('invia_email', 'puoi inviare una email a questi due indirizzi?'),
    // Stile AZIONE (per il pianificatore, vedi intestazione)
    TFraseEsempio.Create('invia_email', 'invia una email a uno o piu'' destinatari'),
    TFraseEsempio.Create('invia_email', 'scrivi e invia una email con oggetto e testo'),
    TFraseEsempio.Create('invia_email', 'comunica via email un avviso a un cliente'),

    // --- anteprima_email_da_modello (provider: email) -----------------
    // Ogni frase nomina "email" insieme a "anteprima"/"vedere"/"controllare":
    // e' cio' che la separa da invia_email_da_modello (che invia).
    TFraseEsempio.Create('anteprima_email_da_modello', 'fammi vedere le email di richiamo prima di mandarle ai clienti'),
    TFraseEsempio.Create('anteprima_email_da_modello', 'mostrami l''anteprima delle email per i clienti coinvolti'),
    TFraseEsempio.Create('anteprima_email_da_modello', 'che email riceveranno i clienti per questo ritiro?'),
    TFraseEsempio.Create('anteprima_email_da_modello', 'voglio controllare il testo delle email di avviso ai clienti'),
    // Stile AZIONE (per il pianificatore, vedi intestazione)
    TFraseEsempio.Create('anteprima_email_da_modello', 'mostra l''anteprima delle email composte da un modello'),
    TFraseEsempio.Create('anteprima_email_da_modello', 'prepara le bozze delle email per i clienti da avvisare senza inviarle'),

    // --- invia_email_da_modello (provider: email) ---------------------
    // Rischio di confusione con invia_email (testo libero): qui ogni frase
    // nomina le email di richiamo/ritiro/avviso AI CLIENTI COINVOLTI.
    TFraseEsempio.Create('invia_email_da_modello', 'invia le email di richiamo ai clienti coinvolti'),
    TFraseEsempio.Create('invia_email_da_modello', 'manda ai clienti le email di ritiro del lotto non conforme'),
    TFraseEsempio.Create('invia_email_da_modello', 'ok, spedisci le email di avviso ai clienti come da anteprima'),
    TFraseEsempio.Create('invia_email_da_modello', 'avvisa per email tutti i clienti che hanno ricevuto il lotto richiamato'),
    // Stile AZIONE (per il pianificatore, vedi intestazione)
    TFraseEsempio.Create('invia_email_da_modello', 'invia ai clienti da avvisare le email composte da un modello'),
    TFraseEsempio.Create('invia_email_da_modello', 'spedisci le email di ritiro e richiamo ai clienti coinvolti'),

    // --- generate_csv (provider: file) --------------------------------
    TFraseEsempio.Create('generate_csv', 'esportalo in csv'),
    TFraseEsempio.Create('generate_csv', 'scaricami questi dati in un foglio'),
    TFraseEsempio.Create('generate_csv', 'mettimi questo elenco in un csv'),
    TFraseEsempio.Create('generate_csv', 'puoi darmelo in formato csv?'),
    // Stile AZIONE (per il pianificatore, vedi intestazione)
    TFraseEsempio.Create('generate_csv', 'genera un file CSV con i dati del passo precedente'),
    TFraseEsempio.Create('generate_csv', 'esporta in CSV l''elenco ottenuto'),

    // --- generate_pdf (provider: file) --------------------------------
    TFraseEsempio.Create('generate_pdf', 'generami un pdf con questi dati'),
    TFraseEsempio.Create('generate_pdf', 'voglio un documento da stampare con questo elenco'),
    TFraseEsempio.Create('generate_pdf', 'scaricalo in pdf'),
    TFraseEsempio.Create('generate_pdf', 'fammi un report pdf di queste vendite'),
    // Stile AZIONE (per il pianificatore, vedi intestazione)
    TFraseEsempio.Create('generate_pdf', 'genera un file PDF con i dati del passo precedente'),
    TFraseEsempio.Create('generate_pdf', 'crea un documento PDF stampabile con l''elenco ottenuto'),

    // --- apri_vista (provider: navigazione) ---------------------------
    TFraseEsempio.Create('apri_vista', 'aprimi la scheda di questo prodotto'),
    TFraseEsempio.Create('apri_vista', 'mostramelo nell''interfaccia'),
    TFraseEsempio.Create('apri_vista', 'portami alla pagina di questo prodotto finito'),
    TFraseEsempio.Create('apri_vista', 'voglio vedere questo semilavorato nel gestionale'),
    // Stile AZIONE (per il pianificatore, vedi intestazione)
    TFraseEsempio.Create('apri_vista', 'apri nell''interfaccia la scheda di un prodotto finito'),
    TFraseEsempio.Create('apri_vista', 'mostra nel gestionale la scheda di un semilavorato'),

    // --- get_ricetta_prodotto_finito (provider: ricette) --------------
    TFraseEsempio.Create('get_ricetta_prodotto_finito', 'qual e'' la ricetta attuale della mozzarella?'),
    TFraseEsempio.Create('get_ricetta_prodotto_finito', 'fammi vedere gli ingredienti di questo prodotto'),
    TFraseEsempio.Create('get_ricetta_prodotto_finito', 'quanto costa produrre questo prodotto con la ricetta attuale?'),
    TFraseEsempio.Create('get_ricetta_prodotto_finito', 'che allergeni ci sono in questo prodotto?'),
    TFraseEsempio.Create('get_ricetta_prodotto_finito', 'dammi la composizione della ricetta'),
    TFraseEsempio.Create('get_ricetta_prodotto_finito', 'dammi la ricetta del prodotto'),
    // Stile AZIONE (per il pianificatore, vedi intestazione)
    TFraseEsempio.Create('get_ricetta_prodotto_finito', 'mostra la ricetta corrente di un prodotto finito'),
    TFraseEsempio.Create('get_ricetta_prodotto_finito', 'leggi componenti, dosi, allergeni e costo della ricetta di un prodotto'),

    // --- cerca_componenti_ricetta (provider: ricette) -----------------
    TFraseEsempio.Create('cerca_componenti_ricetta', 'con cosa posso sostituire il latte in questa ricetta?'),
    TFraseEsempio.Create('cerca_componenti_ricetta', 'cerca un''alternativa senza glutine per questo ingrediente'),
    TFraseEsempio.Create('cerca_componenti_ricetta', 'abbiamo un semilavorato senza uova da usare come sostituto?'),
    TFraseEsempio.Create('cerca_componenti_ricetta', 'trovami un sostituto senza lattosio per questo componente'),
    // Stile AZIONE (per il pianificatore, vedi intestazione)
    TFraseEsempio.Create('cerca_componenti_ricetta', 'cerca componenti sostitutivi privi di un allergene per una ricetta'),
    TFraseEsempio.Create('cerca_componenti_ricetta', 'trova materie prime o semilavorati alternativi a un ingrediente'),

    // --- simula_adattamento_ricetta (provider: ricette) ---------------
    // Nota: questo tool e' il piu' vicino, semanticamente, a
    // get_ricetta_prodotto_finito e cerca_componenti_ricetta (stesso
    // dominio "ricette"), quindi ha bisogno di piu' frasi ed esempi piu'
    // diversi tra loro per staccarsi bene nel ranking - con solo 4 frasi
    // simili era stato scavalcato da get_ricetta_prodotto_finito su
    // domande riformulate (vedi test_retrieval_embedding.py).
    TFraseEsempio.Create('simula_adattamento_ricetta', 'quanto costerebbe se sostituissi il latte con questa alternativa?'),
    TFraseEsempio.Create('simula_adattamento_ricetta', 'simulami cosa cambia se tolgo questo ingrediente'),
    TFraseEsempio.Create('simula_adattamento_ricetta', 'che impatto avrebbe sul costo e sugli allergeni?'),
    TFraseEsempio.Create('simula_adattamento_ricetta', 'prova a calcolare il nuovo costo della ricetta senza applicare la modifica'),
    TFraseEsempio.Create('simula_adattamento_ricetta', 'vediamo cosa succede se cambio questo ingrediente, senza salvare nulla'),
    TFraseEsempio.Create('simula_adattamento_ricetta', 'fammi una prova di sostituzione dell''ingrediente prima di deciderlo'),
    TFraseEsempio.Create('simula_adattamento_ricetta', 'quanto peserebbe sul prezzo finale del prodotto questa variazione alla ricetta?'),
    TFraseEsempio.Create('simula_adattamento_ricetta', 'testiamo l''effetto di questo cambio sulla ricetta, senza modificarla davvero'),
    // Stile AZIONE (per il pianificatore, vedi intestazione)
    TFraseEsempio.Create('simula_adattamento_ricetta', 'simula la sostituzione di un componente nella ricetta di un prodotto finito'),
    TFraseEsempio.Create('simula_adattamento_ricetta', 'simula l''aggiunta di una materia prima alla ricetta e calcola il nuovo costo'),
    TFraseEsempio.Create('simula_adattamento_ricetta', 'calcola l''impatto economico di una modifica alla ricetta senza salvarla'),

    // --- applica_adattamento_ricetta (provider: ricette) --------------
    // Stesso motivo del blocco sopra: e' il tool che "conferma" una
    // simulazione gia' fatta, quindi rischia di essere confuso sia con
    // simula_adattamento_ricetta sia, per via del verbo "applica/salva",
    // con generate_pdf/generate_csv (che "producono" qualcosa). Piu'
    // frasi di conferma esplicite aiutano a separarlo da entrambi.
    //
    // ATTENZIONE ("MAX per tool", non media) osservata in test: Cerca
    // aggrega per MAX della similarita' su tutte le frasi di un tool (vedi
    // il commento SQL in TIndiceEmbeddingTool.Cerca), quindi basta UNA sola
    // frase troppo generica perche' il tool si agganci a un messaggio che
    // non c'entra nulla - non viene "diluita" dalle altre frasi piu'
    // specifiche. Osservato davvero: prima di questa correzione, frasi come
    // "applica definitivamente la sostituzione" o "procedi pure, crea la
    // nuova versione del prodotto" (senza mai nominare "ricetta" o
    // "ingrediente") hanno agganciato questo tool anche per "ok, ora genera
    // il csv" - una richiesta che con le ricette non ha niente a che fare,
    // ma che condivide con quelle frasi la stessa struttura sintattica
    // (particella affermativa breve + imperativo). Ogni frase qui sotto
    // nomina quindi SEMPRE "ricetta", "ingrediente" o "variante": non basta
    // che la maggioranza lo faccia.
    TFraseEsempio.Create('applica_adattamento_ricetta', 'confermo, applica questa sostituzione di ingrediente e crea la nuova variante della ricetta'),
    TFraseEsempio.Create('applica_adattamento_ricetta', 'si'', procedi con la modifica della ricetta'),
    TFraseEsempio.Create('applica_adattamento_ricetta', 'salva questa variante di ricetta col nuovo codice prodotto'),
    TFraseEsempio.Create('applica_adattamento_ricetta', 'applica definitivamente la sostituzione dell''ingrediente nella ricetta'),
    TFraseEsempio.Create('applica_adattamento_ricetta', 'va bene, rendila definitiva questa modifica alla ricetta'),
    TFraseEsempio.Create('applica_adattamento_ricetta', 'procedi pure, crea la nuova versione del prodotto con questa ricetta aggiornata'),
    TFraseEsempio.Create('applica_adattamento_ricetta', 'confermo la sostituzione dell''ingrediente, salvala nella ricetta'),
    TFraseEsempio.Create('applica_adattamento_ricetta', 'sì, quella modifica alla ricetta applicala per davvero'),
    // Stile AZIONE (per il pianificatore, vedi intestazione)
    TFraseEsempio.Create('applica_adattamento_ricetta', 'applica alla ricetta la modifica già simulata'),
    TFraseEsempio.Create('applica_adattamento_ricetta', 'salva la nuova variante o versione della ricetta del prodotto finito'),

    // --- apri_non_conformita_materia_prima (provider: ritiro_richiamo) --
    // Ogni frase nomina sempre "ritiro"/"richiamo"/"non conforme"/"lotto
    // contaminato" - stesso principio "MAX per tool" spiegato sopra per
    // applica_adattamento_ricetta: una sola frase generica (es. "abbiamo
    // un problema con un lotto") rischierebbe di agganciare anche
    // richieste che non c'entrano nulla con la non conformita'.
    TFraseEsempio.Create('apri_non_conformita_materia_prima', 'dobbiamo ritirare il lotto di farina LMP-MP005-002, abbiamo trovato corpi estranei'),
    TFraseEsempio.Create('apri_non_conformita_materia_prima', 'apri una non conformità per questo lotto di materia prima'),
    TFraseEsempio.Create('apri_non_conformita_materia_prima', 'richiama tutti i prodotti che contengono questo lotto, è contaminato'),
    TFraseEsempio.Create('apri_non_conformita_materia_prima', 'questo lotto di materia prima non è conforme, avviamo il ritiro'),
    TFraseEsempio.Create('apri_non_conformita_materia_prima', 'segnala come non conforme il lotto e trova cosa abbiamo prodotto con quella materia prima'),
    TFraseEsempio.Create('apri_non_conformita_materia_prima', 'abbiamo un lotto di materia prima andato a male, bisogna avviare il richiamo'),
    TFraseEsempio.Create('apri_non_conformita_materia_prima', 'il fornitore ci ha segnalato un lotto difettoso, apri la non conformità'),
    TFraseEsempio.Create('apri_non_conformita_materia_prima', 'procedi con l''apertura della non conformità su questi lotti di materia prima'),
    // Stile AZIONE (per il pianificatore, vedi intestazione)
    TFraseEsempio.Create('apri_non_conformita_materia_prima', 'apri una non conformità su un lotto di materia prima'),
    TFraseEsempio.Create('apri_non_conformita_materia_prima', 'trova i lotti di prodotto finito prodotti con un lotto di materia prima non conforme'),

    // --- trova_ordini_spedizioni_lotto_prodotto_finito (provider: ritiro_richiamo) --
    // Rischio di confusione con get_list_vendite (entrambi parlano di
    // ordini/clienti): la differenza va marcata nominando sempre il
    // contesto di richiamo/lotto non conforme insieme a "già
    // spedito"/"consegnato"/"ricevuto" - get_list_vendite non ha invece
    // mai questo contesto di non conformità nelle sue frasi.
    TFraseEsempio.Create('trova_ordini_spedizioni_lotto_prodotto_finito', 'questo prodotto richiamato è già stato spedito a qualche cliente?'),
    TFraseEsempio.Create('trova_ordini_spedizioni_lotto_prodotto_finito', 'chi ha già ricevuto il lotto di prodotto finito coinvolto nel ritiro?'),
    TFraseEsempio.Create('trova_ordini_spedizioni_lotto_prodotto_finito', 'verifica se il lotto non conforme è già uscito con qualche ddt'),
    TFraseEsempio.Create('trova_ordini_spedizioni_lotto_prodotto_finito', 'dobbiamo sapere se abbiamo già consegnato ai clienti il prodotto di quel lotto ritirato'),
    TFraseEsempio.Create('trova_ordini_spedizioni_lotto_prodotto_finito', 'quali ordini contengono il lotto di prodotto finito da richiamare?'),
    TFraseEsempio.Create('trova_ordini_spedizioni_lotto_prodotto_finito', 'il lotto coinvolto nel richiamo è già partito per qualche cliente?'),
    // Il risultato porta anche i clienti da avvisare ("comunicazioni"): le
    // richieste "chi dobbiamo avvisare" devono arrivare qui.
    TFraseEsempio.Create('trova_ordini_spedizioni_lotto_prodotto_finito', 'quali clienti dobbiamo avvisare per il richiamo di questo lotto?'),
    TFraseEsempio.Create('trova_ordini_spedizioni_lotto_prodotto_finito', 'a chi va mandata la comunicazione di ritiro del lotto non conforme?'),
    // Stile AZIONE (per il pianificatore, vedi intestazione)
    TFraseEsempio.Create('trova_ordini_spedizioni_lotto_prodotto_finito', 'trova le spedizioni ai clienti dei lotti di prodotto finito coinvolti nel richiamo'),
    TFraseEsempio.Create('trova_ordini_spedizioni_lotto_prodotto_finito', 'verifica gli ordini e i DDT che contengono un lotto di prodotto finito non conforme'),
    TFraseEsempio.Create('trova_ordini_spedizioni_lotto_prodotto_finito', 'trova i clienti da avvisare per i lotti di prodotto finito non conformi')

  );
end;

end.
