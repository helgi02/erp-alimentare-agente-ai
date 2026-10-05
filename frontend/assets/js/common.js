/* =====================================================================
   common.js — fondamenta condivise da tutto il frontend.

   Contiene le sole cose che servono ovunque:
     App.Config   configurazione (URL del backend, flag dati dimostrativi)
     App.Http     wrapper sulle chiamate REST
     App.Utils    formattazione, escape, helper di rendering comuni

   Deve essere il PRIMO script caricato: tutti gli altri file assumono
   che window.App esista gia'.

   Perche' un namespace globale e non i moduli ES:
   il sito e' un insieme di file statici serviti da IIS e aperti anche
   in locale durante lo sviluppo; i moduli ES (import/export) su
   protocollo file:// vengono bloccati dalla CORS policy del browser, e
   non c'e' alcun passo di build che li possa impacchettare. Un unico
   oggetto App con dentro i sottospazi e' la soluzione piu' semplice che
   funziona sia da IIS sia con il doppio clic su index.html.
   ===================================================================== */

window.App = window.App || {};

/* ==================================================================
   CONFIGURAZIONE
   Unico punto in cui si dichiarano indirizzo del backend e modalita'
   dei dati. Cambiare qui si riflette su tutto il sito.
   ================================================================== */
App.Config = {

    // Origin del server DMVCFramework (uConfig.pas -> [Server] HttpPort,
    // default 8080). Il sito e' servito da IIS su un'altra porta: sono
    // due origin diversi, quindi ogni chiamata attraversa il middleware
    // CORS registrato in uWebModule.pas. Perche' funzioni, GlobalU.GUrl
    // lato Delphi deve contenere l'origin di IIS (chi ha il permesso di
    // chiamare), non questo indirizzo.
    //
    // location.hostname invece di 'localhost' (29/09/2026): aprendo il
    // sito da un altro dispositivo (es. telefono su http://192.168.x.y:83)
    // 'localhost' indicherebbe il TELEFONO, non il portatile col server.
    // Cosi' il backend si cerca sempre sulla stessa macchina che ha
    // servito la pagina; sul portatile resta 'localhost' come prima.
    BASE_URL: 'http://' + location.hostname + ':8080',

    // true  = le API restituiscono i dati dimostrativi di mock-data.js
    // false = chiamate REST reali al backend Delphi
    // Le viste non cambiano di una riga fra i due casi.
    MOCK: false,

    // Ritardo artificiale delle risposte mock, per vedere durante lo
    // sviluppo gli stati di caricamento (le attese vere di Qwen 9B in
    // locale sono ben piu' lunghe di cosi').
    MOCK_DELAY: 220,

    // Prefisso statico servito dal Delphi (TMVCStaticFilesMiddleware)
    // dove i tool MCP scrivono i CSV/PDF generati.
    EXPORT_PATH: '/export'
};

/* ==================================================================
   HTTP
   ================================================================== */
App.Http = {

    async richiesta(percorso, opzioni) {
        const url = App.Config.BASE_URL + percorso;
        const cfg = Object.assign({}, opzioni || {});

        // Content-Type SOLO quando c'e' davvero un corpo da inviare.
        // Metterlo anche sulle GET sembra innocuo ma non lo e': un
        // header Content-Type: application/json rende la richiesta
        // "non semplice" secondo le regole CORS, e il browser antepone
        // una preflight OPTIONS anche a una banale lettura. Una GET
        // senza header custom viaggia invece diretta.
        if (cfg.body) {
            cfg.headers = Object.assign({ 'Content-Type': 'application/json' }, cfg.headers || {});
        }

        let risposta;
        try {
            risposta = await fetch(url, cfg);
        } catch (errore) {
            // Qui NON siamo davanti a un errore applicativo: la richiesta
            // non e' proprio partita, o il browser ne ha scartato la
            // risposta. Il messaggio nativo ("Failed to fetch") non dice
            // quale delle due, quindi lo sostituiamo con le tre cause
            // possibili in ordine di probabilita'.
            throw new Error(
                'Impossibile contattare il backend su ' + url + '. Cause possibili: ' +
                '(1) il server Delphi non e\' avviato o ascolta su un\'altra porta ' +
                '[Server] HttpPort; ' +
                '(2) la pagina e\' aperta da disco (file://) invece che da IIS: ' +
                'l\'origin risulta "null" e il browser blocca la chiamata; ' +
                '(3) l\'origin di questa pagina (' + location.origin + ') non e\' fra quelli ' +
                'ammessi dal middleware CORS, cioe\' GlobalU.GUrl lato Delphi.');
        }

        if (!risposta.ok) {
            const errore = new Error('HTTP ' + risposta.status + ' su ' + percorso);
            // Status agganciato all'errore (non solo nel messaggio): un
            // 404 su una ricetta puo' voler dire "questo prodotto non ha
            // ancora una ricetta", uno stato normale da mostrare con una
            // card, non un guasto da mostrare con l'alert rosso del
            // router (vedi la gestione in view-ricette.js). Senza questo
            // campo il chiamante dovrebbe fare parsing del messaggio.
            errore.status = risposta.status;
            // Messaggio del server, se c'e'. Render(HTTP_STATUS.X, 'testo')
            // di DMVC produce un JSON con il campo "message"; se il corpo non
            // e' JSON si tiene il testo cosi' com'e'. Serve all'agente: un 409
            // "passo non atteso" e un 409 "turno superato" richiedono
            // spiegazioni diverse (vedi api/api-agente.js).
            try {
                const testo = await risposta.text();
                try {
                    const json = JSON.parse(testo);
                    errore.dettaglio = json.message || json.detail || testo;
                } catch (e) {
                    errore.dettaglio = testo;
                }
            } catch (e) {
                errore.dettaglio = '';
            }
            throw errore;
        }

        // Ogni 2xx aggiorna l'indicatore di sincronizzazione in topbar
        // (core/shell.js): e' il modo piu' onesto di mostrare un orario
        // "sincronizzato alle HH:MM", perche' riflette l'ultima chiamata
        // REST riuscita per davvero. App.Shell e' gia' inizializzato a
        // questo punto: gli script sono tutti "defer", quindi vengono
        // eseguiti in ordine di dichiarazione prima che possa partire
        // qualunque fetch innescato da un'interazione dell'utente.
        if (App.Shell && App.Shell.segnalaSync) App.Shell.segnalaSync();

        return risposta.json();
    },

    get(percorso) {
        return this.richiesta(percorso);
    },

    post(percorso, corpo) {
        return this.richiesta(percorso, { method: 'POST', body: JSON.stringify(corpo) });
    },

    put(percorso, corpo) {
        return this.richiesta(percorso, { method: 'PUT', body: JSON.stringify(corpo) });
    },

    // Attesa: usata dai rami mock per simulare la latenza di rete.
    attendi(ms) {
        return new Promise((r) => setTimeout(r, ms));
    },

    // URL assoluto di un file generato dai tool MCP. I file in /export
    // li serve il Delphi, NON IIS: un URL relativo verrebbe cercato su
    // IIS e darebbe 404.
    urlExport(nomeFile) {
        return App.Config.BASE_URL + App.Config.EXPORT_PATH + '/' + encodeURIComponent(nomeFile);
    }
};

/* ==================================================================
   UTILITY
   ================================================================== */
App.Utils = {

    // Selettore breve
    $(selettore, contesto) {
        return (contesto || document).querySelector(selettore);
    },

    $$(selettore, contesto) {
        return Array.prototype.slice.call((contesto || document).querySelectorAll(selettore));
    },

    // Escape HTML. Obbligatorio ovunque si stampi un valore che arriva
    // dal database o — a maggior ragione — dal modello linguistico:
    // il testo generato da Qwen non e' contenuto fidato.
    esc(valore) {
        return String(valore == null ? '' : valore)
            .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
    },

    // decimali (opzionale): quante cifre decimali mostrare. Di default 0
    // (euro intero) - va bene per importi "grandi" come fatturati e
    // totali ordine, dove il centesimo non e' significativo. Per importi
    // piccoli come il costo di UNA riga di ricetta (dosi in grammi, spesso
    // sotto 1 euro) va passato un numero di decimali maggiore, altrimenti
    // 0,04 euro e 0,60 euro finiscono entrambi arrotondati a "0 EUR"/"1
    // EUR" (bug segnalato su schermata "Ricetta corrente": vedi le
    // chiamate con decimali=2 in view-ricette.js e affini).
    fmtEuro(n, decimali) {
        const cifre = decimali == null ? 0 : decimali;
        return new Intl.NumberFormat('it-IT', {
            style: 'currency', currency: 'EUR',
            minimumFractionDigits: cifre, maximumFractionDigits: cifre
        }).format(n || 0);
    },

    fmtNum(n, decimali) {
        return new Intl.NumberFormat('it-IT', {
            minimumFractionDigits: decimali || 0, maximumFractionDigits: decimali || 0
        }).format(n || 0);
    },

    fmtData(iso) {
        if (!iso) return '';
        const d = new Date(iso);
        return isNaN(d) ? this.esc(iso) : d.toLocaleDateString('it-IT');
    },

    // Badge degli stati previsti dallo schema: stato_nc_enum
    // (non_conformita) e chk_stato_ordine_vendita / ordine fornitore.
    // Pillole "soft" — sfondo tenue, testo scuro della stessa tinta —
    // non piu' i badge Bootstrap a tinta piena (bianco su rosso/verde
    // saturo): su una tabella di piu' righe il colore pieno diventa
    // rumore visivo invece di un segnale. Stessa mappa semantica di
    // prima (rosso/aperta, verde/chiuso, ecc.), solo il rendering
    // cambia. Vedi .badge-soft-* in app.css.
    badgeStato(stato) {
        const mappa = {
            aperta: 'badge-soft-rosa', in_gestione: 'badge-soft-ambra', chiusa: 'badge-soft-verde',
            confermato: 'badge-soft-blu', spedito: 'badge-soft-ciano',
            consegnato: 'badge-soft-verde', annullato: 'badge-soft-grigio'
        };
        const classe = mappa[stato] || 'badge-soft-grigio';
        return '<span class="badge-soft ' + classe + '">' +
            this.esc(String(stato).replace(/_/g, ' ')) + '</span>';
    },

    // Icona dello sprite SVG definito in index.html
    icona(nome, classe) {
        return '<svg class="ico ' + (classe || '') + '"><use href="#ico-' + nome + '"/></svg>';
    },

    // ---- Helper di rendering comuni a tutte le viste ----------------

    // NB: qui c'era intestazioneVista(), che generava la fascia con H1 +
    // sottotitolo ripetuta in cima a ogni vista. Rimossa insieme a tutte
    // le sue chiamate (view-dashboard.js, view-vendite.js,
    // view-da-costruire.js): il titolo della vista corrente vive ormai
    // una volta sola, nella topbar (breadcrumb o tab attiva — vedi
    // core/tabs.js), non piu' anche qui sotto. Altezza utile recuperata
    // su ogni schermata, non solo sulla dashboard.

    // Icona "chiedi all'assistente": presente nell'header di ogni card,
    // apre il drawer con la domanda gia' scritta. E' il ponte pagina ->
    // chat, cioe' la dimostrazione visiva che l'agente e' una funzione
    // del gestionale e non un'applicazione affiancata — ma qui, a
    // differenza della vecchia versione testuale, resta un'azione
    // discreta: il punto di accesso PRINCIPALE all'assistente e' un
    // solo pulsante flottante (vedi .chat-fab in index.html), sempre
    // nello stesso posto. L'aggancio del click e' delegato in
    // core/shell.js sullo stesso attributo data-chiedi, quindi funziona
    // anche sui pulsanti creati dopo dal router.
    iconaChiedi(domanda) {
        return '<button type="button" class="btn-ask-icon" ' +
            'data-chiedi="' + this.esc(domanda) + '" title="Chiedi all\'assistente">' +
            this.icona('sparkle') + '</button>';
    },

    // Tabella compatta: intestazioni + righe gia' formattate in HTML.
    tabella(intestazioni, righeHtml) {
        return '<div class="table-responsive"><table class="table table-sm mb-0 align-middle">' +
            '<thead><tr>' + intestazioni.map((h) =>
                '<th' + (h.allineaDx ? ' class="text-end"' : '') + '>' + h.testo + '</th>'
            ).join('') + '</tr></thead>' +
            '<tbody>' + righeHtml + '</tbody></table></div>';
    },

    // Riquadro standard con testata, icona e azione opzionale.
    card(opzioni) {
        return '<div class="card' + (opzioni.altezzaPiena ? ' h-100' : '') + '">' +
            '<div class="card-header">' + this.icona(opzioni.icona) + opzioni.titolo +
                (opzioni.azione || '') +
            '</div>' +
            (opzioni.corpo ? '<div class="card-body">' + opzioni.corpo + '</div>' : '') +
            (opzioni.contenuto || '') +
        '</div>';
    }
};
