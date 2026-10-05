/* =====================================================================
   core/registro-viste.js — catalogo lato frontend delle viste apribili
   dall'agente tramite il tool MCP apri_vista.

   E' lo specchio di common/uRegistroViste.pas sul backend: la'
   TRegistroViste sa QUALI viste esistono e quali parametri richiedono,
   per costruire la descrizione del tool apri_vista e validare la
   richiesta del modello (vedi tools/uNavigazioneToolProvider.pas). Qui
   serve lo stesso catalogo per il motivo opposto: tradurre il
   tool_result {"vista": "...", "parametri": {...}} che arriva gia'
   validato dal backend in un vero URL della SPA, da aprire con
   App.Router.vaiA().

   STESSO PRINCIPIO DI WIRING ESPLICITO
   Nessuna vista si "auto-registra" per magia: ogni file in views/ che
   possiede una schermata sensata da aprire su richiesta dell'agente la
   dichiara qui esplicitamente, con App.RegistroViste.registra(), esattamente
   come il corrispondente tool provider Delphi la dichiara in
   TRegistroViste.Registra (uFrmMain.pas). Il "nome" usato per registrarla
   e' la chiave che tiene allineati i due registri: deve combaciare
   ESATTAMENTE con il nome usato lato backend, altrimenti la vista risulta
   "sconosciuta" qui (vedi risolvi()) anche se il backend l'ha gia' aperta
   con successo.

   PERCHE' chat.js NON COSTRUISCE L'URL DA SOLO
   components/chat.js legge SOLO questo registro (vedi
   App.Chat.aggiungiAperturaVista): non conosce mai i dettagli di un
   singolo scenario (che rotta ha "ricetta_prodotto_finito", quale
   parametro diventa quale segmento di URL, ...). Quando si aggiungeranno
   le viste degli altri due scenari del tirocinio (ritiro/richiamo,
   eventualmente vendite), chat.js non cambia: cambia solo il file della
   vista interessata, che aggiunge una riga di registra() in piu'.
   ===================================================================== */

window.App = window.App || {};

App.RegistroViste = {

    _viste: {},

    // ARisolutore: (parametri) => percorso stringa (es. "/ricette/prodotti-finiti/12"),
    // costruito a partire dai "parametri" che arrivano gia' validati dal
    // backend (TRegistroViste.ChiaviRichieste li garantisce tutti presenti):
    // qui non si rivalida nulla, ci si fida di quel controllo gia' fatto.
    registra(nome, etichetta, risolutore) {
        this._viste[nome] = { etichetta, risolutore };
    },

    // Restituisce { etichetta, url } per il pulsante da mostrare in chat,
    // o null se "nome" non e' stato registrato da nessuna vista frontend.
    // Puo' succedere (es. il backend guadagna una nuova vista prima che
    // questo file venga aggiornato): si preferisce ignorare in silenzio
    // piuttosto che rompere la conversazione per un pulsante che comunque
    // non sapremmo disegnare - vedi il commento gemello lato backend in
    // TNavigazioneToolProvider su "nessuna vista disponibile" come esito
    // normale, non un bug.
    risolvi(nome, parametri) {
        const definizione = this._viste[nome];
        if (!definizione) return null;
        return { etichetta: definizione.etichetta, url: definizione.risolutore(parametri || {}) };
    }
};
