/* =====================================================================
   core/shell.js — cornice dell'applicazione.

   Gestisce cio' che sta INTORNO alle viste e resta immutato durante la
   navigazione: comandi della sidebar, apertura/chiusura e
   ridimensionamento del drawer della chat, ponte pagina -> chat.
   ===================================================================== */

window.App = window.App || {};

App.Shell = {

    inizializza() {
        this.collegaSidebar();
        this.collegaMenuMobile();
        this.collegaChat();
        this.collegaSplitter();
        this.collegaPonteVersoChat();
        this.aggiornaIndicatoreSync();
    },

    // Un solo comando per la sidebar, nel suo stesso footer: prima
    // c'era anche un pulsante hamburger in topbar che nascondeva
    // completamente la sidebar (larghezza 0, terzo stato 'nascosta').
    // Tolto perche' ridondante con questo — due pulsanti per un solo
    // pannello confondevano piu' di quanto aiutassero — e lo stato
    // 'nascosta' e' stato eliminato con lui (vedi core/ui-state.js)
    // invece di restare come funzionalita' irraggiungibile dall'UI.
    collegaSidebar() {
        const U = App.Utils;

        // Rail: solo icone. E' lo stato pensato per quando la chat e'
        // aperta, o piu' in generale quando serve recuperare spazio
        // orizzontale senza far sparire la navigazione.
        U.$('#btnSidebarRail').addEventListener('click', () => {
            App.UI.set('sidebar', App.UI.stato.sidebar === 'rail' ? 'estesa' : 'rail');
        });
    },

    // Menu su smartphone (< 768px, vedi responsive.css): la sidebar e'
    // un drawer fuori schermo. Pulsante e velo sono creati QUI e non in
    // index.html perche' index.html viene rigenerato da Bootstrap Studio
    // a ogni export (vedi ALLINEA_BOOTSTRAP_STUDIO.txt): cio' che vive
    // solo nel JS non puo' essere cancellato da un export.
    // Lo stato aperto/chiuso NON passa da App.UI: e' transitorio, non ha
    // senso ritrovarlo aperto al prossimo caricamento.
    collegaMenuMobile() {
        const topbar = document.querySelector('.topbar');
        if (!topbar) return;

        const btn = document.createElement('button');
        btn.type = 'button';
        btn.className = 'btn btn-light btn-menu-mobile';
        btn.title = 'Menu';
        btn.setAttribute('aria-label', 'Apri il menu');
        btn.innerHTML = '<svg class="ico"><use href="#ico-menu"></use></svg>';
        topbar.prepend(btn);

        const velo = document.createElement('div');
        velo.className = 'sidebar-velo';
        document.body.appendChild(velo);

        const chiudi = () => document.body.classList.remove('menu-mobile-aperto');
        btn.addEventListener('click', () => {
            document.body.classList.toggle('menu-mobile-aperto');
            // Menu e chat a tutto schermo non devono sovrapporsi
            if (document.body.classList.contains('menu-mobile-aperto')) {
                App.UI.set('chatAperta', false);
            }
        });
        velo.addEventListener('click', chiudi);
        // Scelta una voce, il drawer si chiude da solo (come ogni app mobile)
        App.Utils.$('#sidebarNav').addEventListener('click', (e) => {
            if (e.target.closest('.nav-item')) chiudi();
        });

        // Al primo caricamento su telefono la chat parte CHIUSA anche se
        // lo stato salvato (magari da desktop) la vuole aperta: a tutto
        // schermo nasconderebbe la pagina appena aperta. Si modifica solo
        // lo stato in memoria, senza salvarlo, per non cambiare la
        // preferenza desktop.
        if (window.matchMedia('(max-width: 767.98px)').matches) {
            App.UI.stato.chatAperta = false;
            App.UI.applica();
        }
    },

    collegaChat() {
        const U = App.Utils;

        // Gestore unico per l'apertura/chiusura via topbar
        const toggleChat = () => {
            App.UI.set('chatAperta', !App.UI.stato.chatAperta);
        };

        // Aggancio al nuovo pulsante in topbar
        const btnPepper = U.$('#btnTogglePepper');
        if (btnPepper) {
            btnPepper.addEventListener('click', toggleChat);
        }

        // Fallback sul vecchio ID se ancora presente
        const btnOldToggle = U.$('#btnChatToggle');
        if (btnOldToggle) {
            btnOldToggle.addEventListener('click', toggleChat);
        }

        U.$('#btnChatClose').addEventListener('click', () => {
            App.UI.set('chatAperta', false);
            document.body.classList.remove('chat-full');
        });

        U.$('#btnChatFull').addEventListener('click', () => {
            document.body.classList.toggle('chat-full');
        });

        U.$('#chkIspettore').addEventListener('change', (e) => {
            App.UI.set('ispettore', e.target.checked);
        });
    },

    // Ridimensionamento del drawer col mouse, come una form VCL.
    collegaSplitter() {
        const splitter = App.Utils.$('#splitter');
        let trascinamento = false;

        splitter.addEventListener('mousedown', (e) => {
            trascinamento = true;
            document.body.classList.add('resizing');
            e.preventDefault();
        });

        document.addEventListener('mousemove', (e) => {
            if (!trascinamento) return;
            // La chat e' ancorata a destra: la sua larghezza e' la
            // distanza del cursore dal bordo destro della finestra.
            const larghezza = window.innerWidth - e.clientX;
            const limitata = Math.min(Math.max(larghezza, 320), window.innerWidth - 420);
            document.documentElement.style.setProperty('--chat-w', limitata + 'px');
            App.UI.stato.chatLarghezza = Math.round(limitata);
        });

        document.addEventListener('mouseup', () => {
            if (!trascinamento) return;
            trascinamento = false;
            document.body.classList.remove('resizing');
            App.UI.salva();   // si salva a fine trascinamento, non a ogni pixel
        });
    },

    // Ponte pagina -> chat. Delega di evento sul document: funziona
    // anche sui pulsanti creati dopo dal router o dalla chat stessa,
    // senza doverli riagganciare a ogni render.
    collegaPonteVersoChat() {
        document.addEventListener('click', (e) => {
            const bottone = e.target.closest('[data-chiedi]');
            if (bottone) {
                e.preventDefault();
                App.Chat.apri(bottone.dataset.chiedi);
                return;
            }
        });
    },

    // Indicatore di stato sincronizzazione: pallino + testo, nel footer
    // della sidebar (non piu' in topbar, dove ora c'e' il badge utente —
    // vedi index.html). Non e' solo un restyling — l'orario si aggiorna
    // da solo a ogni risposta REST andata a buon fine (vedi segnalaSync(),
    // agganciato in App.Http.richiesta() dentro common.js), quindi
    // riflette l'ultimo scambio reale col backend Delphi e non un orario
    // fisso preso all'avvio pagina. Il testo vive in .sync-label perche'
    // in modalita' rail (sidebar a sole icone) si nasconde tutto tranne
    // il pallino, stesso trattamento di .brand-text e .nav-item span.
    aggiornaIndicatoreSync() {
        const el = App.Utils.$('#syncStatus');
        if (!el) return;

        if (App.Config.MOCK) {
            // La distinzione dati veri/dati finti resta importante
            // quanto lo era col vecchio badge: durante una discussione
            // e' meglio non lasciarla implicita. Pallino ambra invece
            // di verde, nessun orario: non c'e' nessun backend con cui
            // essere "sincronizzati".
            el.classList.add('is-demo');
            el.title = 'I dati mostrati sono di esempio (App.Config.MOCK = true in common.js), non provengono dal database.';
            el.innerHTML = '<span class="sync-dot"></span><span class="sync-label">Dati dimostrativi</span>';
            return;
        }

        this.segnalaSync();
    },

    // Chiamato da App.Http (common.js) dopo ogni risposta REST 2xx.
    // Difensivo sull'esistenza di #syncStatus per lo stesso motivo di
    // App.Tabs.render(): se in futuro l'elemento sparisse da index.html,
    // il resto dell'app deve continuare a funzionare invece di lanciare
    // un errore a ogni chiamata HTTP.
    segnalaSync() {
        if (App.Config.MOCK) return;
        const el = App.Utils.$('#syncStatus');
        if (!el) return;

        const adesso = new Date();
        // toLocaleDateString('it-IT') rende il mese abbreviato in
        // minuscolo ("13 ago"): nell'indicatore compatto la maiuscola
        // si legge meglio accanto all'orario ("13 Ago, 10:37").
        const data = adesso.toLocaleDateString('it-IT', { day: '2-digit', month: 'short' });
        const dataMaiuscola = data.charAt(0).toUpperCase() + data.slice(1);
        const ora = adesso.toLocaleTimeString('it-IT', { hour: '2-digit', minute: '2-digit' });

        el.title = 'Ultima risposta ricevuta dal server Delphi il ' + dataMaiuscola + ' alle ' + ora + '.';
        el.innerHTML = '<span class="sync-dot"></span><span class="sync-label">Sincronizzato ' +
            '<span class="sync-sep">&bull;</span> <span class="sync-time">' + dataMaiuscola + ', ' + ora + '</span></span>';
    }
};
