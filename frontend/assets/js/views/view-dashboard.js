/* =====================================================================
   views/view-dashboard.js — schermata iniziale.

   Ha un doppio ruolo nel progetto. E' la home di un gestionale, quindi
   deve dare i numeri che servono davvero (non conformita' aperte, lotti
   in scadenza, ordini da spedire, fatturato). Ed e' il TERMINE DI
   PARAGONE della tesi: risponde a quattro domande decise in fase di
   progettazione, e a nessun'altra. Ogni riquadro porta accanto un'icona
   "chiedi all'assistente" (vedi U.iconaChiedi in common.js) proprio per
   rendere immediato il confronto con la stessa domanda posta
   liberamente in chat.

   NIENTE H1 DI PAGINA: il titolo "Dashboard" vive solo nella topbar
   (breadcrumb o tab attiva, vedi core/tabs.js) — niente fascia bianca
   col titolo ripetuta qui sotto. E' una scelta di layout, non
   un'omissione: la vista comincia direttamente con la riga dei KPI.
   ===================================================================== */

(function () {
    'use strict';

    const U = App.Utils;

    App.Router.registra('dashboard', {
        titolo: 'Dashboard',

        async render() {
            const d = await App.Api.Dashboard.get();

            return '' +
                sezioneKPI(d.kpi) +
                '<div class="row g-3 mt-0">' +
                    '<div class="col-12">' + cardVendite(d.venditeMensili) + '</div>' +
                '</div>' +
                '<div class="row g-3 mt-0">' +
                    '<div class="col-xl-6">' + cardNonConformita(d.nonConformita) + '</div>' +
                    '<div class="col-xl-6">' + cardLottiInScadenza(d.lottiInScadenza) + '</div>' +
                '</div>' +
                '<div class="row g-3 mt-0 mb-3">' +
                    '<div class="col-12">' + cardOrdiniRecenti(d.ordiniRecenti) + '</div>' +
                '</div>';
        }
    });

    /* ------------------------------------------------------------- KPI */

    // Le note sotto ai numeri sono costruite dalle soglie che arrivano
    // dal backend (giorniScadenza, giorniFatturato): se un domani si
    // cambia la finestra temporale in uServiziDashboard.pas, l'etichetta
    // qui segue da sola invece di restare a mentire.
    //
    // "livello" e' il codice colore di urgenza (.kpi-danger / .kpi-
    // warning / .kpi-success in app.css): calcolato dal VALORE, non
    // fisso per categoria. "Lotti in scadenza" torna una card neutra
    // quando lottiInScadenza e' zero, non resta arancione a
    // prescindere — il colore deve segnalare qualcosa di vero, non
    // essere solo un tema grafico. "Ordini da spedire" resta sempre
    // neutro: e' un dato operativo, non un'urgenza.
    function sezioneKPI(k) {
        const carte = [
            { href: App.Router.url('non-conformita'), valore: k.ncAperte, etichetta: 'Non conformit&agrave; aperte',
              nota: 'Richiedono azione', livello: k.ncAperte > 0 ? 'danger' : '' },

            // "< " + giorniScadenza invece di un "30" scritto a mano:
            // il numero arriva dal backend (vedi commento sopra), il
            // testo deve restare corto ma non puo' mentire se la
            // soglia cambia in uServiziDashboard.pas.
            { href: App.Router.url('lotti'), valore: k.lottiInScadenza, etichetta: 'Lotti in scadenza',
              nota: 'Giacenza residua (< ' + k.giorniScadenza + ' gg)',
              livello: k.lottiInScadenza > 0 ? 'warning' : '' },

            { href: App.Router.url('vendite'), valore: k.ordiniDaSpedire, etichetta: 'Ordini da spedire',
              nota: 'Pronti per il carico', livello: '' },

            { href: App.Router.url('vendite'), valore: U.fmtEuro(k.fatturatoPeriodo),
              etichetta: 'Fatturato ' + k.giorniFatturato + ' giorni',
              nota: 'Fatturato netto', livello: 'success' }
        ];

        return '<div class="row g-3">' + carte.map((c) =>
            '<div class="col-6 col-xl-3">' +
                '<a class="kpi-card" href="' + c.href + '">' +
                    '<div class="card' + (c.livello ? ' kpi-' + c.livello : '') + '"><div class="card-body">' +
                        '<div class="kpi-label">' + c.etichetta + '</div>' +
                        '<div class="kpi-value">' + c.valore + '</div>' +
                        '<div class="kpi-note text-body-secondary">' + U.esc(c.nota) + '</div>' +
                    '</div></div>' +
                '</a>' +
            '</div>'
        ).join('') + '</div>';
    }

    /* ---------------------------------------------------------- VENDITE */

    // Grafico a barre in CSS puro: nessuna libreria da CDN (niente
    // Chart.js/D3), quindi nessun rischio che in sede di discussione il
    // grafico non compaia perche' manca la rete. Asse Y, griglie e
    // tooltip sono la stessa filosofia: pseudo-elementi e markup,
    // non canvas ne' SVG generati da terzi (vedi app.css).
    // '2026-08' -> 'ago 26'. Il backend manda il mese in forma neutra e
    // ordinabile, la lingua la mette il frontend.
    function etichettaMese(aaaaMm) {
        const parti = String(aaaaMm).split('-');
        if (parti.length !== 2) return aaaaMm;
        const d = new Date(Number(parti[0]), Number(parti[1]) - 1, 1);
        return d.toLocaleDateString('it-IT', { month: 'short' }) + ' ' + parti[0].slice(2);
    }

    // Arrotonda il massimo della serie al primo "numero pulito" (1/2/5 *
    // 10^n) superiore, cosi' le etichette dell'asse Y sono leggibili
    // (es. "12.000 €") invece di frazioni scomode del valore esatto
    // (es. "11.842 €"). Conseguenza voluta: la barra piu' alta della
    // serie di solito NON tocca il 100% dell'altezza disponibile — e'
    // cosi' che si legge un asse con una scala vera, non normalizzata
    // sul singolo valore massimo.
    function assePulito(massimo) {
        if (massimo <= 0) return 1;
        const esponente = Math.floor(Math.log10(massimo));
        const base = Math.pow(10, esponente);
        const normalizzato = massimo / base;
        let passo = 10;
        if (normalizzato <= 1) passo = 1;
        else if (normalizzato <= 2) passo = 2;
        else if (normalizzato <= 5) passo = 5;
        return passo * base;
    }

    function cardVendite(serie) {
        if (!serie.length) {
            return U.card({
                icona: 'vendite', titolo: 'Fatturato mensile (ultimi 12 mesi)', altezzaPiena: true,
                corpo: '<p class="text-body-secondary mb-0">Nessun ordine di vendita nel periodo.</p>'
            });
        }

        const massimoSerie = Math.max.apply(null, serie.map((s) => s.importo)) || 1;
        const massimoAsse = assePulito(massimoSerie);

        // 5 tacche: 100/75/50/25/0% del massimo pulito, dall'alto verso
        // il basso — lo stesso ordine visivo dell'asse.
        const tacche = [4, 3, 2, 1, 0].map((i) => U.fmtEuro(massimoAsse * i / 4));

        const barre = serie.map((s) =>
            '<div class="bar-col">' +
                '<div class="bar" style="height:' + ((s.importo / massimoAsse) * 100).toFixed(1) + '%" ' +
                    'data-tooltip="' + U.esc(etichettaMese(s.mese) + ': ' + U.fmtEuro(s.importo)) + '" ' +
                    'title="' + U.esc(etichettaMese(s.mese)) + ': ' + U.fmtEuro(s.importo) + '"></div>' +
                '<div class="bar-label">' + U.esc(etichettaMese(s.mese)) + '</div>' +
            '</div>'
        ).join('');

        return U.card({
            icona: 'vendite',
            titolo: 'Fatturato mensile (ultimi 12 mesi)',
            altezzaPiena: true,
            azione: U.iconaChiedi('Confronta il fatturato di quest\'anno con lo stesso periodo ' +
                                    'dell\'anno scorso, diviso per categoria di prodotto'),
            corpo:
                '<div class="bar-chart-wrap">' +
                    '<div class="chart-y-axis">' + tacche.map((t) => '<span>' + t + '</span>').join('') + '</div>' +
                    '<div class="bar-chart">' +
                        '<div class="chart-gridlines">' + tacche.map(() => '<span></span>').join('') + '</div>' +
                        barre +
                    '</div>' +
                '</div>'
        });
    }

    /* -------------------------------------------------- NON CONFORMITA' */

    function cardNonConformita(elenco) {
        const righe = elenco.map((n) =>
            '<tr>' +
                '<td><a href="' + App.Router.url('non-conformita', [n.id]) + '">' +
                    '<code>' + U.esc(n.codice_nc) + '</code></a></td>' +
                '<td><div class="small">' + U.esc(n.motivo) + '</div>' +
                    '<span class="small text-body-secondary">' + U.esc(n.lotto_tipo) +
                    ' <code>' + U.esc(n.lotto) + '</code></span></td>' +
                '<td class="text-nowrap small">' + U.fmtData(n.data_apertura) + '</td>' +
                '<td>' + U.badgeStato(n.stato_nc) + '</td>' +
            '</tr>'
        ).join('');

        return U.card({
            icona: 'nc',
            titolo: 'Non conformit&agrave; recenti',
            altezzaPiena: true,
            azione: U.iconaChiedi('Per la non conformita\' NC-2026-014, dimmi quali prodotti finiti ' +
                                    'contengono il lotto coinvolto e quali clienti li hanno ricevuti'),
            contenuto: U.tabella(
                [{ testo: 'Codice' }, { testo: 'Motivo' }, { testo: 'Apertura' }, { testo: 'Stato' }],
                righe)
        });
    }

    /* ------------------------------------------------------------ LOTTI */

    function cardLottiInScadenza(elenco) {
        // Stessa pillola "soft" di U.badgeStato() (vedi common.js), ma
        // costruita qui perche' la soglia (10 giorni) e' una lettura sul
        // campo "giorni", non uno stato dello schema: rosa quando manca
        // poco davvero, ambra per il resto della lista — coerente con
        // l'accento arancione della card KPI "Lotti in scadenza".
        const righe = elenco.map((l) => {
            const urgente = l.giorni <= 10;
            return '<tr>' +
                '<td><a href="' + App.Router.url('tracciabilita', [l.id]) + '">' +
                    '<code>' + U.esc(l.codice_lotto) + '</code></a></td>' +
                '<td class="small">' + U.esc(l.materia_prima) + '</td>' +
                '<td class="text-nowrap small">' + U.fmtData(l.data_scadenza) +
                    ' <span class="badge-soft ' + (urgente ? 'badge-soft-rosa' : 'badge-soft-ambra') + '">' +
                    l.giorni + ' gg</span></td>' +
                '<td class="text-end text-nowrap small">' +
                    U.fmtNum(l.quantita_disponibile, 2) + ' ' + U.esc(l.um) + '</td>' +
            '</tr>';
        }).join('');

        return U.card({
            icona: 'lotti',
            titolo: 'Lotti in scadenza',
            altezzaPiena: true,
            azione: U.iconaChiedi('Quali lotti scadono entro 15 giorni e quanta giacenza residua hanno?'),
            contenuto: U.tabella(
                [{ testo: 'Lotto' }, { testo: 'Materia prima' }, { testo: 'Scadenza' },
                 { testo: 'Disponibile', allineaDx: true }],
                righe)
        });
    }

    /* ----------------------------------------------------------- ORDINI */

    function cardOrdiniRecenti(elenco) {
        const righe = elenco.map((o) =>
            '<tr>' +
                '<td><a href="' + App.Router.url('vendite', [o.id]) + '">' +
                    '<code>' + U.esc(o.numero_ordine) + '</code></a></td>' +
                '<td class="text-nowrap small">' + U.fmtData(o.data_ordine) + '</td>' +
                '<td>' + U.esc(o.cliente) + '</td>' +
                '<td>' + U.badgeStato(o.stato) + '</td>' +
                '<td class="text-end fw-medium">' + U.fmtEuro(o.totale) + '</td>' +
            '</tr>'
        ).join('');

        return U.card({
            icona: 'vendite',
            titolo: 'Ultimi ordini di vendita',
            azione: U.iconaChiedi('Quanto ha ordinato Supermercati Delta negli ultimi tre mesi? ' +
                                    'Generami il dettaglio in PDF'),
            contenuto: U.tabella(
                [{ testo: 'Ordine' }, { testo: 'Data' }, { testo: 'Cliente' }, { testo: 'Stato' },
                 { testo: 'Totale', allineaDx: true }],
                righe)
        });
    }
})();
