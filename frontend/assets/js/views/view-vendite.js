/* =====================================================================
   views/view-vendite.js — elenco ordini di vendita.

   RUOLO NEL PROGETTO
   E' la schermata che fa da termine di paragone allo scenario 2
   (interrogazione vendite ad hoc). Espone gli stessi quattro filtri che
   il tool MCP get_list_vendite riceve come parametri — cliente,
   prodotto, data inizio, data fine — piu' lo stato, che il tool non ha
   perche' esclude sempre gli annullati. Il confronto in sede di demo
   diventa cosi' immediato e onesto: la stessa domanda si pone
   compilando questi campi, oppure scrivendo una frase.

   I FILTRI STANNO NELL'URL
   /vendite?cliente_id=1&data_inizio=2026-07-01&data_fine=2026-07-31
   Non e' un dettaglio implementativo: e' cio' che permette all'agente,
   dopo aver risposto in chat, di offrire un link che apre questa vista
   GIA' filtrata sugli stessi criteri. Il tool_result contiene i
   cliente_id / prodotto_id gia' risolti dal servizio, quindi il link si
   costruisce senza dover risolvere i nomi una seconda volta.

   /vendite/1902 apre l'elenco con quell'ordine espanso: serve perche'
   anche il singolo ordine sia linkabile, senza costruire una seconda
   schermata.

   Nessuna regola CSS nuova: la vista usa solo classi Bootstrap. Il
   foglio di stile app.css e' gestito dentro Bootstrap Studio, quindi
   aggiungere classi da qui significherebbe perderle al prossimo export.

   NIENTE H1 DI PAGINA: come in view-dashboard.js, il titolo "Vendite"
   vive solo nella topbar (breadcrumb o tab attiva). La vecchia riga
   "Ordini di vendita e relative righe prodotto" sotto il titolo e'
   stata rimossa senza sostituto: era descrittiva e statica, non
   informazione che cambia da un caricamento all'altro, quindi non
   serviva un posto dove spostarla.
   ===================================================================== */

(function () {
    'use strict';

    const U = App.Utils;

    const STATI = ['confermato', 'spedito', 'consegnato', 'annullato'];

    // Vista apribile dall'agente (vedi core/registro-viste.js): stesso nome
    // registrato lato backend in uFrmMain.pas. I parametri sono i filtri
    // gia' risolti (id e date) che il tool get_list_vendite mette in
    // "apertura_vista": qui diventano la query string di questa vista.
    App.RegistroViste.registra('vendite', 'Apri nelle vendite', (parametri) => urlConFiltri({
        cliente_id: parametri.cliente_id,
        prodotto_id: parametri.prodotto_id,
        data_inizio: String(parametri.data_inizio || '').slice(0, 10),
        data_fine: String(parametri.data_fine || '').slice(0, 10)
    }));

    App.Router.registra('vendite', {
        titolo: 'Vendite',

        async render(rotta) {
            const filtri = leggiFiltri(rotta);

            // Le tre letture sono indipendenti: si lanciano insieme
            // invece che in fila, altrimenti l'apertura della pagina
            // costerebbe la somma delle tre attese.
            //
            // Ma non hanno la stessa importanza: gli ordini sono la
            // ragione d'essere della schermata, le due anagrafiche
            // servono solo a riempire due tendine. Con Promise.all il
            // fallimento di una qualsiasi avrebbe fatto cadere tutta la
            // vista — ed e' esattamente cosi' che un endpoint anagrafica
            // mancante faceva sparire anche gli ordini. Con allSettled
            // le tendine degradano a "non disponibile" e il resto della
            // pagina resta utilizzabile.
            const [esitoOrdini, esitoClienti, esitoProdotti] = await Promise.allSettled([
                App.Api.Vendite.elenco(filtri),
                App.Api.Clienti.getAll(),
                App.Api.ProdottiFiniti.getAll()
            ]);

            if (esitoOrdini.status === 'rejected') throw esitoOrdini.reason;

            const risultato = esitoOrdini.value;
            const clienti = esitoClienti.status === 'fulfilled' ? esitoClienti.value : [];
            const prodotti = esitoProdotti.status === 'fulfilled' ? esitoProdotti.value : [];

            const avvisi =
                avvisoAnagrafica(esitoClienti, 'clienti', '/api/clienti') +
                avvisoAnagrafica(esitoProdotti, 'prodotti finiti', '/api/prodotti-finiti');

            return avvisi +
                barraFiltri(filtri, clienti, prodotti) +
                riepilogo(risultato, filtri) +
                tabellaOrdini(risultato, rotta.parametri[0]) +
                paginazione(risultato, filtri);
        },

        dopoRender(rotta) {
            collegaFiltri();
            collegaEspansione();

            // Deep link /vendite/1902: apre l'ordine indicato.
            if (rotta.parametri[0]) {
                const riga = U.$('[data-ordine="' + rotta.parametri[0] + '"]');
                if (riga) riga.click();
            }
        }
    });

    /* ==============================================================
       FILTRI
       ============================================================== */

    // I filtri vivono nella query string, non in una variabile di
    // modulo: cosi' lo stato della schermata e' interamente descritto
    // dall'URL, la pagina si puo' ricaricare o linkare senza perderlo,
    // e il tasto indietro del browser funziona da solo.
    function leggiFiltri(rotta) {
        const q = rotta.query || {};
        return {
            cliente_id: q.cliente_id || '',
            prodotto_id: q.prodotto_id || '',
            data_inizio: q.data_inizio || '',
            data_fine: q.data_fine || '',
            stato: q.stato || '',
            pagina: Number(q.pagina) || 1
        };
    }

    // Avviso discreto quando una delle due anagrafiche non risponde: la
    // tendina resta vuota, ma chi guarda deve sapere PERCHE', altrimenti
    // pensa che il gestionale non abbia clienti o prodotti.
    function avvisoAnagrafica(esito, nome, endpoint) {
        if (esito.status !== 'rejected') return '';
        return '<div class="alert alert-warning py-2 px-3 small">' +
            'Elenco <strong>' + nome + '</strong> non disponibile: il filtro corrispondente resta vuoto. ' +
            '<span class="text-body-secondary">(' + U.esc(endpoint) + ' &rarr; ' +
            U.esc(esito.reason.message) + ')</span></div>';
    }

    function urlConFiltri(filtri) {
        const qs = new URLSearchParams();
        Object.keys(filtri).forEach((k) => {
            // pagina=1 e' il default: non sporca l'URL
            if (filtri[k] && !(k === 'pagina' && Number(filtri[k]) === 1)) {
                qs.set(k, filtri[k]);
            }
        });
        const s = qs.toString();
        return App.Router.url('vendite') + (s ? '?' + s : '');
    }

    function barraFiltri(f, clienti, prodotti) {
        const opzioniCliente = clienti.map((c) =>
            '<option value="' + c.id + '"' + (String(c.id) === String(f.cliente_id) ? ' selected' : '') + '>' +
            U.esc(c.ragione_sociale) + '</option>').join('');

        const opzioniProdotto = prodotti.map((p) =>
            '<option value="' + p.id + '"' + (String(p.id) === String(f.prodotto_id) ? ' selected' : '') + '>' +
            U.esc(p.denominazione) + '</option>').join('');

        const opzioniStato = STATI.map((s) =>
            '<option value="' + s + '"' + (s === f.stato ? ' selected' : '') + '>' +
            U.esc(s) + '</option>').join('');

        return '' +
        '<div class="card mb-3"><div class="card-body pb-2">' +
            '<form id="formFiltriVendite" class="row g-2 align-items-end">' +
                campo('Cliente', 'col-md-3',
                    '<select class="form-select form-select-sm" name="cliente_id">' +
                    '<option value="">Tutti</option>' + opzioniCliente + '</select>') +
                campo('Prodotto', 'col-md-3',
                    '<select class="form-select form-select-sm" name="prodotto_id">' +
                    '<option value="">Tutti</option>' + opzioniProdotto + '</select>') +
                campo('Dal', 'col-md-2',
                    '<input type="date" class="form-control form-control-sm" name="data_inizio" value="' +
                    U.esc(f.data_inizio) + '">') +
                campo('Al', 'col-md-2',
                    '<input type="date" class="form-control form-control-sm" name="data_fine" value="' +
                    U.esc(f.data_fine) + '">') +
                campo('Stato', 'col-md-2',
                    '<select class="form-select form-select-sm" name="stato">' +
                    '<option value="">Tutti</option>' + opzioniStato + '</select>') +
                '<div class="col-12 d-flex gap-2 align-items-center pt-1">' +
                    '<button type="submit" class="btn btn-sm btn-primary">Applica filtri</button>' +
                    '<a href="' + App.Router.url('vendite') + '" class="btn btn-sm btn-outline-secondary">Azzera</a>' +
                    '<button type="button" class="btn btn-sm btn-outline-secondary" id="btnEsportaVendite">' +
                        'Esporta CSV</button>' +
                    bottoneChiediConFiltri(f, clienti, prodotti) +
                '</div>' +
            '</form>' +
        '</div></div>';
    }

    function campo(etichetta, colonna, controllo) {
        return '<div class="' + colonna + '">' +
            '<label class="form-label small text-body-secondary mb-1">' + etichetta + '</label>' +
            controllo + '</div>';
    }

    // Traduce i filtri attivi nella domanda equivalente in linguaggio
    // naturale. E' il cuore del confronto che la tesi vuole mostrare:
    // gli stessi criteri, espressi nei due modi. Con la differenza che
    // in chat si puo' poi chiedere un taglio dei dati che questi campi
    // non prevedono.
    function bottoneChiediConFiltri(f, clienti, prodotti) {
        const cliente = clienti.find((c) => String(c.id) === String(f.cliente_id));
        const prodotto = prodotti.find((p) => String(p.id) === String(f.prodotto_id));

        let domanda = 'Quanto abbiamo venduto';
        if (prodotto) domanda += ' di ' + prodotto.denominazione;
        if (cliente) domanda += ' a ' + cliente.ragione_sociale;
        if (f.data_inizio && f.data_fine) {
            domanda += ' dal ' + U.fmtData(f.data_inizio) + ' al ' + U.fmtData(f.data_fine);
        } else if (f.data_inizio) {
            domanda += ' dal ' + U.fmtData(f.data_inizio);
        }
        domanda += '?';

        return U.iconaChiedi(domanda);
    }

    function collegaFiltri() {
        const form = U.$('#formFiltriVendite');
        if (!form) return;

        // Applicare un filtro significa cambiare l'URL: al resto pensa
        // il router, che ridisegna la vista tramite App.Router.vaiA
        // (pushState + naviga, vedi router.js). Nessuno stato da tenere
        // sincronizzato a mano.
        form.addEventListener('submit', (e) => {
            e.preventDefault();
            const dati = new FormData(form);
            App.Router.vaiA(urlConFiltri({
                cliente_id: dati.get('cliente_id'),
                prodotto_id: dati.get('prodotto_id'),
                data_inizio: dati.get('data_inizio'),
                data_fine: dati.get('data_fine'),
                stato: dati.get('stato'),
                pagina: 1        // cambiando filtro si riparte dalla prima pagina
            }));
        });

        const btn = U.$('#btnEsportaVendite');
        if (btn) btn.addEventListener('click', () => esportaCsv(form));
    }

    /* ==============================================================
       RIEPILOGO E TABELLA
       ============================================================== */

    function riepilogo(r, f) {
        const periodo = (f.data_inizio || f.data_fine)
            ? 'dal ' + (f.data_inizio ? U.fmtData(f.data_inizio) : '…') +
              ' al ' + (f.data_fine ? U.fmtData(f.data_fine) : '…')
            : 'su tutto lo storico';

        return '<div class="d-flex flex-wrap gap-4 align-items-baseline mb-3 px-1">' +
            '<div><span class="fs-4 fw-semibold">' + U.fmtNum(r.totale_ordini) + '</span>' +
                '<span class="text-body-secondary small ms-2">ordini trovati</span></div>' +
            '<div><span class="fs-4 fw-semibold">' + U.fmtEuro(r.totale_fatturato) + '</span>' +
                '<span class="text-body-secondary small ms-2">valore complessivo</span></div>' +
            '<div class="text-body-secondary small">' + U.esc(periodo) + '</div>' +
        '</div>';
    }

    function tabellaOrdini(r) {
        if (!r.ordini.length) {
            return '<div class="card"><div class="card-body text-body-secondary">' +
                'Nessun ordine corrisponde ai filtri impostati.' +
            '</div></div>';
        }

        const righe = r.ordini.map((o) =>
            // Due <tr> per ordine: quello visibile e quello del
            // dettaglio, nascosto finche' non si espande. Il dettaglio
            // non e' precaricato — viene richiesto a
            // GET /api/ordini-vendita/(id) al primo clic.
            '<tr class="align-middle" style="cursor:pointer" data-ordine="' + o.id + '">' +
                '<td><code>' + U.esc(o.numero_ordine) + '</code></td>' +
                '<td class="text-nowrap small">' + U.fmtData(o.data_ordine) + '</td>' +
                '<td>' + U.esc(o.cliente) + '</td>' +
                '<td>' + U.badgeStato(o.stato) + '</td>' +
                '<td class="text-end small text-body-secondary">' + o.numero_righe + '</td>' +
                '<td class="text-end fw-medium">' + U.fmtEuro(o.totale) + '</td>' +
            '</tr>' +
            '<tr class="d-none" data-dettaglio="' + o.id + '">' +
                '<td colspan="6" class="bg-body-tertiary p-0"></td>' +
            '</tr>'
        ).join('');

        return '<div class="card">' +
            U.tabella([
                { testo: 'Ordine' }, { testo: 'Data' }, { testo: 'Cliente' }, { testo: 'Stato' },
                { testo: 'Righe', allineaDx: true }, { testo: 'Totale', allineaDx: true }
            ], righe) +
        '</div>';
    }

    // Espansione della riga. Delega di evento su tutta l'area contenuto:
    // un solo listener invece di uno per riga, e continua a funzionare
    // dopo che il router ha ridisegnato la tabella.
    function collegaEspansione() {
        const contenitore = U.$('#content');
        if (!contenitore) return;

        contenitore.addEventListener('click', async (e) => {
            const riga = e.target.closest('[data-ordine]');
            if (!riga) return;

            const id = riga.dataset.ordine;
            const dettaglio = U.$('[data-dettaglio="' + id + '"]');
            if (!dettaglio) return;

            const cella = dettaglio.querySelector('td');

            if (!dettaglio.classList.contains('d-none')) {
                dettaglio.classList.add('d-none');
                return;
            }

            dettaglio.classList.remove('d-none');

            // Si carica una volta sola: alla seconda apertura il
            // contenuto e' gia' li'.
            if (cella.dataset.caricato) return;
            cella.innerHTML = '<div class="p-3 text-body-secondary small">Caricamento righe&hellip;</div>';

            try {
                const ordine = await App.Api.Vendite.dettaglio(id);
                cella.innerHTML = tabellaRighe(ordine);
                cella.dataset.caricato = '1';
            } catch (errore) {
                cella.innerHTML = '<div class="p-3 text-danger small">' + U.esc(errore.message) + '</div>';
            }
        });
    }

    function tabellaRighe(o) {
        if (!o || !o.righe.length) {
            return '<div class="p-3 text-body-secondary small">Nessuna riga.</div>';
        }

        const righe = o.righe.map((r) =>
            '<tr>' +
                '<td class="small">' + U.esc(r.prodotto) + '</td>' +
                // Il lotto e' il punto di aggancio con lo scenario 1:
                // da qui si risalira' alla tracciabilita' del prodotto
                // finito venduto.
                '<td class="small">' + (r.lotto
                    ? '<a href="' + App.Router.url('tracciabilita', [U.esc(r.lotto)]) + '">' +
                      '<code>' + U.esc(r.lotto) + '</code></a>'
                    : '<span class="text-body-secondary">&mdash;</span>') + '</td>' +
                '<td class="text-end small text-nowrap">' + U.fmtNum(r.quantita) + ' ' + U.esc(r.unita_misura) + '</td>' +
                '<td class="text-end small text-nowrap">' + U.fmtNum(r.prezzo_unitario, 2) + ' &euro;</td>' +
                '<td class="text-end small fw-medium text-nowrap">' + U.fmtEuro(r.importo) + '</td>' +
            '</tr>'
        ).join('');

        return '<div class="p-3">' +
            (o.note ? '<p class="small text-body-secondary mb-2"><strong>Note:</strong> ' +
                      U.esc(o.note) + '</p>' : '') +
            '<table class="table table-sm mb-0 align-middle bg-body">' +
                '<thead><tr>' +
                    '<th class="small">Prodotto</th><th class="small">Lotto</th>' +
                    '<th class="small text-end">Quantit&agrave;</th>' +
                    '<th class="small text-end">Prezzo unit.</th>' +
                    '<th class="small text-end">Importo</th>' +
                '</tr></thead>' +
                '<tbody>' + righe + '</tbody>' +
                '<tfoot><tr><th colspan="4" class="text-end small">Totale ordine</th>' +
                    '<th class="text-end">' + U.fmtEuro(o.totale) + '</th></tr></tfoot>' +
            '</table>' +
        '</div>';
    }

    /* ==============================================================
       PAGINAZIONE
       ============================================================== */

    function paginazione(r, f) {
        const pagine = Math.ceil(r.totale_ordini / r.per_pagina);
        if (pagine <= 1) return '';

        let voci = '';
        for (let p = 1; p <= pagine; p++) {
            const attiva = p === r.pagina;
            voci += '<li class="page-item' + (attiva ? ' active' : '') + '">' +
                '<a class="page-link" href="' +
                urlConFiltri(Object.assign({}, f, { pagina: p })) + '">' + p + '</a></li>';
        }

        return '<nav class="mt-3"><ul class="pagination pagination-sm mb-0">' + voci + '</ul></nav>';
    }

    /* ==============================================================
       ESPORTAZIONE
       ============================================================== */

    // Export costruito nel browser sulle righe correntemente filtrate.
    //
    // NOTA per l'evoluzione: la versione definitiva dovrebbe chiamare un
    // endpoint che usa lo STESSO generatore dei tool MCP
    // (services/uEsportazioneCSV.pas), cosi' che il file ottenuto dalla
    // schermata e quello ottenuto chiedendolo in chat siano identici.
    // Due generatori diversi per lo stesso documento sono due formati
    // che prima o poi divergono.
    async function esportaCsv(form) {
        const dati = new FormData(form);
        const filtri = {
            cliente_id: dati.get('cliente_id'),
            prodotto_id: dati.get('prodotto_id'),
            data_inizio: dati.get('data_inizio'),
            data_fine: dati.get('data_fine'),
            stato: dati.get('stato'),
            pagina: 1,
            per_pagina: 100000   // export = tutte le righe, non la pagina a video
        };

        const r = await App.Api.Vendite.elenco(filtri);

        const intestazioni = ['numero_ordine', 'data_ordine', 'cliente', 'stato', 'numero_righe', 'totale'];
        const virgolette = (v) => '"' + String(v == null ? '' : v).replace(/"/g, '""') + '"';

        const csv = [intestazioni.join(';')]
            .concat(r.ordini.map((o) => intestazioni.map((c) => virgolette(o[c])).join(';')))
            .join('\r\n');

        // BOM UTF-8: senza, Excel in italiano apre il file interpretando
        // i byte come ANSI e le lettere accentate arrivano corrotte.
        const blob = new Blob(['﻿' + csv], { type: 'text/csv;charset=utf-8;' });
        const link = document.createElement('a');
        link.href = URL.createObjectURL(blob);
        link.download = 'vendite.csv';
        link.click();
        URL.revokeObjectURL(link.href);
    }
})();
