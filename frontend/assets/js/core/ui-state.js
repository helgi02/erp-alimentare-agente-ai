/* =====================================================================
   core/ui-state.js — stato dell'interfaccia.

   Sidebar, drawer della chat e ispettore sono descritti da un solo
   oggetto, e l'unico punto in cui quello stato diventa aspetto visivo
   e' applica(): da li' si scrivono classi su <body> e variabili CSS.
   Nessun'altra parte del codice tocca direttamente le classi di layout.

   Lo stato e' persistito in localStorage: in demo conta davvero, si
   apre il sito ed e' gia' nella configurazione voluta, senza doverla
   sistemare davanti a chi sta guardando.
   ===================================================================== */

window.App = window.App || {};

App.UI = {

    CHIAVE: 'aa-erp-ui',

    stato: {
        // Due soli stati: 'estesa' (piena, con etichette) o 'rail' (solo
        // icone). C'era anche 'nascosta' (larghezza 0, per un pulsante
        // dedicato in topbar): rimossa insieme al pulsante — vedi il
        // commento su collegaSidebar() in core/shell.js.
        sidebar: 'estesa',      // 'estesa' | 'rail'
        chatAperta: true,
        chatLarghezza: 350,
        ispettore: true
    },

    carica() {
        try {
            const salvato = localStorage.getItem(this.CHIAVE);
            if (salvato) Object.assign(this.stato, JSON.parse(salvato));
        } catch (e) {
            // localStorage puo' essere disabilitato dalle policy del
            // browser: non e' un errore bloccante, si usano i default.
            console.warn('Stato UI non ripristinato:', e);
        }
        this.applica();
    },

    salva() {
        try {
            localStorage.setItem(this.CHIAVE, JSON.stringify(this.stato));
        } catch (e) { /* non bloccante */ }
    },

    applica() {
        const b = document.body;
        b.classList.toggle('sidebar-rail',   this.stato.sidebar === 'rail');
        b.classList.toggle('chat-open',      this.stato.chatAperta);
        b.classList.toggle('hide-ispettore', !this.stato.ispettore);

        document.documentElement.style.setProperty('--chat-w', this.stato.chatLarghezza + 'px');

        const chk = document.getElementById('chkIspettore');
        if (chk) chk.checked = this.stato.ispettore;
    },

    set(chiave, valore) {
        this.stato[chiave] = valore;
        this.applica();
        this.salva();
    }
};
