/* =====================================================================
   core/tabs.js — barra delle tab in stile MDI/VCL.

   Il router (vedi il commento in cima a router.js) prevedeva gia' questa
   estensione: "una tab non e' che una route memorizzata". Questo modulo
   non introduce un secondo sistema di navigazione — la fonte di verita'
   resta l'URL (pathname + query, via History API). Si limita a tenere
   un elenco delle rotte gia' aperte e a evidenziare quella corrente, un
   po' come i tab di un browser sopra un sito che in realta' e' fatto di
   semplici URL.

   IDENTITA' DI UNA TAB
   La chiave e' la rotta per intero — nome, parametri posizionali e
   query — non solo il nome della vista. Scelta deliberata: aprire
   /vendite?cliente_id=1 e poi /vendite?cliente_id=2 sono due contesti
   di lavoro diversi (due clienti diversi) e restano aperti fianco a
   fianco, come due form MDI distinte in un gestionale VCL. Ri-navigare
   verso una rotta IDENTICA mette invece a fuoco la tab gia' aperta,
   senza duplicarla.

   MARKUP
   La barra (<ul id="tabBar">) sta in index.html DENTRO la topbar,
   accanto al breadcrumb (<nav id="breadcrumb">): sono la stessa riga,
   si alternano — mai due righe sommate in altezza. Classe custom
   .tab-strip in assets/css/app.css, non piu' le .nav/.nav-tabs di
   Bootstrap (troppo "pesanti" per stare nei 52px della topbar). NB:
   index.html e assets/css/app.css vengono rigenerati da Bootstrap
   Studio a ogni export (vedi il commento in view-vendite.js): se si
   riesporta il progetto da li', sia #tabBar sia la regola .tab-strip
   vanno riportati a mano, altrimenti questo modulo trova il DOM senza
   barra e si limita a non disegnare nulla (vedi render()).
   ===================================================================== */

window.App = window.App || {};

App.Tabs = {

    CHIAVE_STORAGE: 'aa-erp-tabs',
    MASSIMO: 12,   // oltre, la barra scorre all'infinito senza essere piu' utile

    // Chiavi di query che NON contano ai fini dell'identita' della tab:
    // cambiano dentro lo stesso contesto di lavoro invece di aprirne uno
    // nuovo. "pagina" e' l'esempio che ha fatto scoprire il problema:
    // sfogliare i risultati di una ricerca (view-vendite.js) e' ancora
    // la STESSA domanda, non una domanda diversa ogni volta che cambia
    // il numero di pagina — a differenza di cliente_id o data_inizio,
    // che restano intenzionalmente chiavi di identita' (vedi il
    // commento "IDENTITA' DI UNA TAB" qui sopra: due clienti diversi
    // sono due contesti MDI diversi, due pagine dello stesso cliente no).
    CHIAVI_NEUTRE: ['pagina'],

    elenco: [],    // [{ chiave, nome, titolo, parametri, query, percorso }]
    attiva: null,  // chiave della tab corrente

    // Ricostruisce la stringa canonica di una rotta: e' la chiave della
    // tab. La query va ordinata, altrimenti ?a=1&b=2 e ?b=2&a=1
    // finirebbero per contare come due tab diverse pur essendo la
    // stessa domanda posta con le chiavi in un ordine diverso. Le
    // CHIAVI_NEUTRE (es. "pagina") si escludono qui: non partecipano
    // all'identita', anche se restano nell'URL vero e proprio.
    chiave(rotta) {
        const query = Object.keys(rotta.query)
            .filter((k) => this.CHIAVI_NEUTRE.indexOf(k) === -1)
            .sort()
            .map((k) => k + '=' + rotta.query[k]).join('&');
        return [rotta.nome].concat(rotta.parametri).join('/') + (query ? '?' + query : '');
    },

    carica() {
        try {
            const salvato = localStorage.getItem(this.CHIAVE_STORAGE);
            if (salvato) {
                const dati = JSON.parse(salvato);
                if (Array.isArray(dati.elenco)) this.elenco = dati.elenco;

                // Migrazione da tab salvate PRIMA del passaggio da router
                // a hash a History API (vedi router.js): quelle vecchie
                // hanno ancora il campo "hash" (es. "#/vendite") invece
                // di "percorso". Senza questo aggiustamento le tab
                // rimaste in localStorage da una sessione precedente
                // punterebbero a un href con # che il router non sa piu'
                // interpretare.
                this.elenco.forEach((tab) => {
                    if (tab.percorso === undefined && typeof tab.hash === 'string') {
                        tab.percorso = tab.hash.replace(/^#/, '') || '/dashboard';
                        delete tab.hash;
                    }
                });
            }
        } catch (e) {
            // Stesso approccio non bloccante di ui-state.js: senza
            // localStorage si riparte semplicemente senza tab salvate.
            console.warn('Tab non ripristinate:', e);
        }
    },

    salva() {
        try {
            localStorage.setItem(this.CHIAVE_STORAGE, JSON.stringify({ elenco: this.elenco }));
        } catch (e) { /* non bloccante */ }
    },

    // Chiamata dal router a ogni navigazione andata a buon fine (solo
    // per rotte con una configurazione valida: le voci "fuori dal
    // perimetro" non aprono una tab, altrimenti si finirebbe con una
    // tab che promette una schermata che non esiste).
    registra(rotta, titolo) {
        const chiave = this.chiave(rotta);
        let tab = this.elenco.find((t) => t.chiave === chiave);

        if (!tab) {
            tab = { chiave, nome: rotta.nome, titolo, parametri: rotta.parametri, query: rotta.query, percorso: location.pathname + location.search };
            this.elenco.push(tab);
            if (this.elenco.length > this.MASSIMO) this.elenco.shift();
        } else {
            // Stessa tab, contesto interno cambiato (tipicamente la
            // pagina): si aggiornano parametri/query/percorso cosi' la
            // tab riapre esattamente dov'era rimasta, non sempre a
            // pagina 1.
            tab.parametri = rotta.parametri;
            tab.query = rotta.query;
            tab.percorso = location.pathname + location.search;
        }

        this.attiva = chiave;
        this.salva();
        this.render();
    },

    // Permette a una vista di DETTAGLIO (es. l'anagrafica di un singolo
    // prodotto finito, aperta su /prodotti-finiti/(id)) di sostituire, a
    // posteriori, il "#id" mostrato in tab con qualcosa di leggibile - la
    // denominazione del prodotto. Necessariamente a posteriori: quando il
    // router chiama registra() la tab nasce SOLO dall'URL (vedi naviga()
    // in router.js, chiamato PRIMA di render()), quindi l'unico dato
    // disponibile a quel punto e' l'id numerico nei parametri. La vista
    // richiama questo metodo dal proprio dopoRender(), una volta che la
    // fetch e' tornata (vedi view-prodotti-finiti.js/view-semilavorati.js,
    // funzione collegaDettaglio()).
    //
    // Confronto su tab.dettaglio prima di salvare/ridisegnare: senza,
    // ogni rientro nella stessa scheda gia' etichettata ridisegnerebbe la
    // barra per niente.
    impostaDettaglio(chiave, testo) {
        const tab = this.elenco.find((t) => t.chiave === chiave);
        if (!tab || tab.dettaglio === testo) return;

        tab.dettaglio = testo;
        this.salva();
        this.render();
    },

    chiudi(chiave, evento) {
        if (evento) evento.stopPropagation(); // non deve anche attivare la tab che sta per sparire

        const indice = this.elenco.findIndex((t) => t.chiave === chiave);
        if (indice === -1) return;

        const eraAttiva = this.attiva === chiave;
        this.elenco.splice(indice, 1);
        this.salva();

        if (!eraAttiva) {
            this.render();
            return;
        }

        // Si mette a fuoco la tab rimasta alla stessa posizione (quella
        // che era subito a destra prende il posto), o l'ultima a
        // sinistra se si chiudeva la tab piu' a destra. Senza tab
        // restanti si torna alla dashboard, che ne ricrea comunque una.
        const successiva = this.elenco[Math.max(0, indice - 1)];
        App.Router.vaiA(successiva ? successiva.percorso : '/dashboard');
        this.render(); // aggiorna subito la barra, senza aspettare popstate/naviga()
    },

    render() {
        const barra = App.Utils.$('#tabBar');
        const breadcrumb = App.Utils.$('#breadcrumb');
        if (!barra) return;

        // Con una sola tab la barra e' rumore, non informazione: si
        // mostra solo da due in su, come le tab di un browser. Sotto
        // quella soglia il breadcrumb da solo basta a dire "dove sono".
        if (this.elenco.length <= 1) {
            barra.innerHTML = '';
            barra.classList.add('d-none');
            if (breadcrumb) breadcrumb.classList.remove('d-none');
            return;
        }

        // Da due tab in su il breadcrumb diventerebbe ridondante: la
        // tab attiva gia' mostra lo stesso titolo, evidenziato. I due
        // elementi condividono la stessa riga della topbar (vedi
        // index.html): si alternano, non si sommano mai in altezza.
        if (breadcrumb) breadcrumb.classList.add('d-none');
        barra.classList.remove('d-none');

        // NB: il <li> non porta la classe Bootstrap "nav-item". app.css
        // la ridefinisce pesantemente per i link della sidebar (colori
        // chiari su sfondo scuro, padding proprio, hover bianco
        // trasparente): riusarla qui creerebbe una collisione di nome,
        // non di intento, e la tab erediterebbe uno stile pensato per
        // tutt'altro contesto. Bootstrap non la richiede per far
        // funzionare .nav-tabs, quindi si omette e basta.
        barra.innerHTML = this.elenco.map((t) => {
            const attiva = t.chiave === this.attiva;
            return '' +
                '<li>' +
                '<a class="nav-link d-flex align-items-center gap-2 py-1 px-2' + (attiva ? ' active' : '') + '" href="' + App.Utils.esc(t.percorso) + '">' +
                '<span class="text-truncate" style="max-width:11rem">' + this.etichetta(t) + '</span>' +
                '<button type="button" class="btn-close" style="font-size:.55rem" data-chiudi-tab="' + App.Utils.esc(t.chiave) + '" title="Chiudi scheda" aria-label="Chiudi scheda"></button>' +
                '</a></li>';
        }).join('');
    },

    // Titolo della vista piu' un dettaglio che distingue tab con lo
    // stesso nome ma parametri diversi (es. due clienti diversi su
    // "Vendite"): il primo parametro posizionale, altrimenti la prima
    // coppia della query.
    //
    // ATTENZIONE all'escaping qui dentro: tab.titolo arriva da
    // configurazione.titolo (vedi router.js), che e' testo di fiducia
    // scritto a mano nei file views/ e puo' contenere entita' HTML
    // (es. "Tracciabilit&agrave; lotti") destinate a passare per
    // innerHTML — esattamente come fa gia' il breadcrumb esistente.
    // Va quindi usato COSI' COM'E', senza esc(). Il dettaglio in coda
    // invece viene da un parametro o da una query string, cioe' da un
    // valore che in teoria l'utente potrebbe manipolare nell'URL: quello
    // si escapa sempre.
    etichetta(tab) {
        // tab.dettaglio (vedi impostaDettaglio() sopra) ha sempre la
        // precedenza sul semplice id: "Prodotti finiti · Sugo al
        // basilico 320g" dice dove si e' molto piu' di "Prodotti finiti
        // · #12". Escaping qui perche', a differenza di tab.titolo, il
        // testo arriva da un dato di anagrafica (denominazione), non da
        // una stringa scritta a mano nei file views/.
        if (tab.dettaglio) return tab.titolo + ' · ' + App.Utils.esc(tab.dettaglio);
        if (tab.parametri.length) return tab.titolo + ' · #' + App.Utils.esc(tab.parametri[0]);

        // Stesse CHIAVI_NEUTRE escluse qui: se l'unica chiave rimasta in
        // query e' "pagina" (nessun filtro impostato, solo paginazione),
        // il dettaglio in coda deve sparire — "Vendite · 2" letto veloce
        // sembra un filtro, invece e' solo il numero di pagina.
        const chiavi = Object.keys(tab.query).filter((k) => this.CHIAVI_NEUTRE.indexOf(k) === -1);
        if (chiavi.length) return tab.titolo + ' · ' + App.Utils.esc(tab.query[chiavi[0]]);
        return tab.titolo;
    },

    inizializza() {
        this.carica();

        const barra = App.Utils.$('#tabBar');
        if (!barra) {
            // Vedi la nota MARKUP in cima al file: senza #tabBar in
            // index.html il modulo resta silenzioso invece di rompere
            // l'avvio dell'app.
            console.warn('#tabBar non trovato in index.html: barra delle tab disattivata.');
            return;
        }

        barra.addEventListener('click', (e) => {
            const bottone = e.target.closest('[data-chiudi-tab]');
            if (bottone) {
                e.preventDefault();
                this.chiudi(bottone.dataset.chiudiTab, e);
            }
            // altrimenti e' un click sul link: naviga da solo via href
        });
    }
};
