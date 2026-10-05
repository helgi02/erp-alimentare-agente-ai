/* =====================================================================
   core/router.js — router a percorsi puliti (History API).

   Ogni schermata e' identificata da un URL (/dashboard, /lotti/871,
   /vendite?cliente=3) ed e' resa da una funzione registrata dai file
   in views/. Due conseguenze volute:

   1) L'agente puo' linkare le entita' che cita. Quando la chat risponde
      "sono coinvolti 14 clienti", quel testo puo' contenere link veri
      alle schermate del gestionale: e' cio' che rende evidente che
      l'agente sta DENTRO l'applicativo e non di fianco.

   2) Le tab in stile MDI/VCL (vedi core/tabs.js) si aggiungono sopra
      questo strato senza riscriverlo: una tab non e' che una route
      memorizzata, e chi naviga da tastiera o da un link esterno
      continua a funzionare esattamente come prima.

   Una vista si registra cosi', dal proprio file in views/:

       App.Router.registra('vendite', {
           titolo: 'Vendite',
           async render(rotta) { return '<h1>...</h1>'; },
           dopoRender(rotta)   { ... aggancio eventi locali ... }
       });

   PERCHE' History API e non hash
   Con l'hash (#/vendite) il browser non manda MAI il frammento al
   server: qualunque cosa serva index.html per "/" andava bene, zero
   configurazione lato server. Con percorsi puliti (/vendite) invece
   il browser chiede DAVVERO "/vendite" al server quando l'utente
   ricarica la pagina o incolla il link: serve quindi un fallback
   server-side che risponda comunque con index.html per ogni percorso
   che non e' un file statico reale, lasciando poi a questo router il
   compito di leggere location.pathname e disegnare la vista giusta.
   Lato IIS (che serve staticamente questa cartella) il fallback e' in
   web.config, regola URL Rewrite "SPA fallback" - senza quella
   regola F5 su /vendite risponde 404 invece di ricaricare l'app.
   ===================================================================== */

window.App = window.App || {};

App.Router = {

    rotte: {},

    registra(nome, configurazione) {
        this.rotte[nome] = configurazione;
    },

    // "/lotti/871?x=1" -> { nome:'lotti', parametri:['871'], query:{x:'1'} }
    analizza() {
        const segmenti = location.pathname.split('/').filter(Boolean);
        const query = {};
        new URLSearchParams(location.search).forEach((v, k) => { query[k] = v; });

        return { nome: segmenti[0] || 'dashboard', parametri: segmenti.slice(1), query };
    },

    // Helper per costruire link dalle viste e dalle risposte dell'agente
    url(nome, parametri) {
        return '/' + [nome].concat(parametri || []).join('/');
    },

    // Navigazione da codice (es. submit di un filtro, chiusura di una
    // tab che rimette a fuoco quella precedente): aggiorna la barra
    // degli indirizzi con pushState - un vero URL nella cronologia,
    // navigabile con Indietro/Avanti - poi ridisegna come farebbe un
    // click su un link o l'evento popstate.
    //
    // Restituisce la Promise di naviga() (gia' risolta se la vista e'
    // quella corrente): chi deve fare qualcosa a vista DISEGNATA, come
    // evidenzia() qui sotto, puo' aspettarla. Chi non la usa non cambia.
    vaiA(percorso) {
        const attuale = location.pathname + location.search;
        if (percorso === attuale) return Promise.resolve();
        history.pushState(null, '', percorso);
        return this.naviga();
    },

    // Segnale visivo "questa vista l'ha aperta l'agente": senza, il
    // contenuto cambia mentre l'utente guarda la chat e non se ne
    // accorge. Tre effetti brevi, tutti sul contenuto appena disegnato:
    //  - il contenuto entra con una dissolvenza e un piccolo scorrimento;
    //  - un bordo interno del colore primario compare e sfuma;
    //  - la tab attiva (se la barra delle tab e' visibile) lampeggia una volta.
    //
    // Web Animations API e non una classe CSS: app.css e' gestito dentro
    // Bootstrap Studio, una regola aggiunta a mano andrebbe persa al
    // prossimo export (stesso vincolo descritto in views/view-vendite.js).
    // Le animazioni non lasciano stili sull'elemento: a fine corsa tutto
    // torna com'era. Con "riduci movimento" attivo nel sistema resta solo
    // il bordo che sfuma, senza spostamenti.
    evidenzia() {
        const contenuto = App.Utils.$('#content');
        if (!contenuto || !contenuto.animate) return;

        const colore = getComputedStyle(document.documentElement)
            .getPropertyValue('--bs-primary').trim() || '#0d6efd';
        const menoMovimento = window.matchMedia &&
            window.matchMedia('(prefers-reduced-motion: reduce)').matches;

        if (!menoMovimento) {
            contenuto.animate(
                [{ opacity: 0.25, transform: 'translateY(10px)' },
                 { opacity: 1, transform: 'translateY(0)' }],
                { duration: 380, easing: 'cubic-bezier(0.2, 0.8, 0.2, 1)' });
        }

        contenuto.animate(
            [{ boxShadow: 'inset 0 0 0 3px ' + colore },
             { boxShadow: 'inset 0 0 0 3px ' + colore, offset: 0.35 },
             { boxShadow: 'inset 0 0 0 3px transparent' }],
            { duration: 1600, easing: 'ease-out' });

        const tab = App.Utils.$('#tabBar .nav-link.active');
        if (tab && !menoMovimento) {
            tab.animate(
                [{ transform: 'scale(1)' }, { transform: 'scale(1.08)' }, { transform: 'scale(1)' }],
                { duration: 500, easing: 'ease-in-out' });
        }
    },

    async naviga() {
        const U = App.Utils;
        const rotta = this.analizza();
        const configurazione = this.rotte[rotta.nome];
        const contenuto = U.$('#content');

        // Evidenzia la voce di menu corrispondente
        U.$$('.nav-item').forEach((a) => {
            a.classList.toggle('active', a.dataset.route === rotta.nome);
        });

        if (!configurazione) {
            U.$('#breadcrumb').innerHTML = '<strong>Non disponibile</strong>';
            contenuto.innerHTML = this.vistaFuoriPerimetro(rotta.nome);
            return;
        }

        U.$('#breadcrumb').innerHTML = '<strong>' + configurazione.titolo + '</strong>';
        App.Tabs.registra(rotta, configurazione.titolo);
        contenuto.innerHTML =
            '<div class="placeholder-view"><div>' +
            '<div class="spinner-border text-secondary" role="status"></div>' +
            '<p class="mt-2 mb-0">Caricamento&hellip;</p></div></div>';

        try {
            contenuto.innerHTML = await configurazione.render(rotta);
            contenuto.scrollTop = 0;
            if (configurazione.dopoRender) configurazione.dopoRender(rotta);
        } catch (errore) {
            console.error(errore);
            // Il nome della vista nel messaggio non e' un dettaglio: una
            // schermata puo' leggere piu' risorse, e senza sapere QUALE
            // vista sta fallendo si finisce a cercare il guasto altrove
            // (es. un 404 su /api/prodotti-finiti mentre si e' cliccato
            // "Vendite").
            contenuto.innerHTML =
                '<div class="alert alert-danger">' +
                '<strong>Errore nel caricamento della vista &laquo;' +
                U.esc(configurazione.titolo) + '&raquo;.</strong>' +
                '<div class="small mt-1">' + U.esc(errore.message) + '</div>' +
                '<div class="small mt-2 text-body-secondary">Se il backend non &egrave; avviato, verifica che ' +
                '<code>App.Config.MOCK</code> sia <code>true</code> in assets/js/common.js.</div></div>';
        }
    },

    // Pagina delle voci di menu dichiarate fuori perimetro. Meglio una
    // pagina che spiega lo scope di un link che non fa niente: chi
    // valuta il progetto deve distinguere "non implementato per scelta"
    // da "rotto".
    vistaFuoriPerimetro(nome) {
        return '' +
            '<div class="placeholder-view"><div>' +
            '<svg class="ico ico-grande"><use href="#ico-lock"/></svg>' +
            '<h2 class="h5 mt-3 mb-1">Sezione fuori dal perimetro del tirocinio</h2>' +
            '<p class="mb-0" style="max-width:34rem">Questa voce esiste per rispecchiare la struttura di un ' +
            'gestionale alimentare reale, ma non &egrave; implementata: il lavoro &egrave; concentrato sui tre ' +
            'scenari di integrazione dell\'agente MCP (ritiro/richiamo, interrogazione vendite, adattamento ricette).</p>' +
            '<code class="small d-block mt-3 text-body-tertiary">/' + App.Utils.esc(nome) + '</code>' +
            '</div></div>';
    },

    // Intercetta i click sui link interni: senza questo, un normale
    // <a href="/vendite"> ricaricherebbe l'intera pagina dal server
    // (comportamento nativo del browser per un percorso "vero", a
    // differenza di un #hash) invece di lasciar disegnare la vista a
    // questo router. Delegato su document cosi' funziona anche per i
    // link generati dinamicamente dalle viste e dalle risposte
    // dell'agente in chat, senza dover riagganciare un listener ogni
    // volta che il contenuto viene ridisegnato.
    //
    // Condizioni per NON intercettare (si lascia fare al browser):
    // - tasto diverso dal sinistro, o un modificatore (Ctrl/Cmd/Shift)
    //   premuto: l'utente sta chiedendo esplicitamente "apri in una
    //   nuova scheda/finestra";
    //   - target="_blank" o download: stessa intenzione, dichiarata nel
    //   markup;
    // - href assente, esterno (http/https verso un altro host) o
    //   speciale (mailto:, tel:, ecc.): non e' una rotta di questa app.
    intercettaClick(evento) {
        if (evento.defaultPrevented || evento.button !== 0) return;
        if (evento.metaKey || evento.ctrlKey || evento.shiftKey || evento.altKey) return;

        const link = evento.target.closest('a[href]');
        if (!link || link.target === '_blank' || link.hasAttribute('download')) return;

        // Confronto sull'oggetto URL (non sulla stringa href grezza):
        // cosi' un href relativo tipo "vendite" o assoluto tipo
        // "/vendite" vengono normalizzati e il controllo "stesso host"
        // e' affidabile anche con base href diverse.
        const destinazione = new URL(link.href, location.href);
        if (destinazione.origin !== location.origin) return;

        evento.preventDefault();
        this.vaiA(destinazione.pathname + destinazione.search);
    },

    avvia() {
        window.addEventListener('popstate', () => this.naviga());
        document.addEventListener('click', (e) => this.intercettaClick(e));

        // Percorso "/" (prima apertura, nessuna rotta nell'URL): si
        // riscrive la barra degli indirizzi su /dashboard con
        // replaceState (non pushState, altrimenti "Indietro" dalla
        // dashboard tornerebbe a una "/" mai davvero visitata) prima di
        // disegnare - stesso comportamento del vecchio "se manca
        // l'hash, imposta #/dashboard".
        if (location.pathname === '/' || location.pathname === '') {
            history.replaceState(null, '', '/dashboard');
        }
        this.naviga();
    }
};
