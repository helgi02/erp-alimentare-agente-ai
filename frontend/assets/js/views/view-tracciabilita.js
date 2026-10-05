/* =====================================================================
   views/view-tracciabilita.js — albero di propagazione di un lotto
   (scenario 1, ritiro/richiamo).

   E' la vista che rende visibile "a colpo d'occhio" la stessa domanda
   che l'agente puo' rispondere in chat durante un ritiro/richiamo
   (vedi services/uServiziRitiroRichiamo.pas e uServiziTracciabilita.pas
   lato backend): a partire da UN lotto, quali lotti di semilavorato e
   di prodotto finito lo contengono, e per ciascun lotto di prodotto
   finito raggiunto, a quali ordini/clienti e' stato assegnato e se e'
   stato davvero spedito (distinzione "ordinato" vs "spedito", vedi il
   commento di classe nel service).

   ROTTA A DUE PARAMETRI, NON UNO
   /tracciabilita/<tipo>/<id> - tipo prima dell'id (non solo un id,
   come /lotti/871 in view-lotti.js) perche' le tre tabelle di lotto
   hanno tre sequence INDIPENDENTI: l'id da solo sarebbe ambiguo
   (potrebbe esistere sia come lotto materia prima sia come lotto
   prodotto finito, con alberi diversi) - stesso motivo gia' scelto per
   /api/tracciabilita/<tipo>/(id) lato backend (vedi il commento in
   controllers/uControllerTracciabilita.pas).

   NESSUNA SCHEDA "ELENCO"
   A differenza delle altre viste non c'e' un /tracciabilita da solo
   con una tabella di tutti i lotti: tracciare TUTTI i lotti in una
   volta non avrebbe senso (l'albero e' per definizione centrato su un
   punto di partenza). Senza tipo+id la vista mostra un selettore
   manuale (tipo + codice/id) per chi arriva sulla rotta senza passare
   da un link "Traccia" - il punto di ingresso normale resta pero'
   quel pulsante nella vista Lotti (view-lotti.js, funzione
   collegaApertura/rigaLotto).
   ===================================================================== */

(function () {
    'use strict';

    const U = App.Utils;

    // tipo (segmento URL) -> { etichetta, funzione App.Api.Tracciabilita
    // da chiamare, elenco lotti da cui pescare le opzioni del
    // selettore manuale }. Stessa idea della mappa TIPI di
    // view-lotti.js: un solo posto da aggiornare per le tre varianti.
    const TIPI = {
        'materie-prime': {
            etichetta: 'Materia prima',
            chiamaApi: (id) => App.Api.Tracciabilita.alberoMateriaPrima(id),
            getAllLotti: () => App.Api.LottiMateriePrime.getAll()
        },
        semilavorati: {
            etichetta: 'Semilavorato',
            chiamaApi: (id) => App.Api.Tracciabilita.alberoSemilavorato(id),
            getAllLotti: () => App.Api.LottiSemilavorati.getAll()
        },
        'prodotti-finiti': {
            etichetta: 'Prodotto finito',
            chiamaApi: (id) => App.Api.Tracciabilita.alberoProdottoFinito(id),
            getAllLotti: () => App.Api.LottiProdottiFiniti.getAll()
        }
    };

    // Vista apribile dall'agente (vedi core/registro-viste.js): stesso nome
    // registrato lato backend in uFrmMain.pas. "tipo_lotto" arriva con il
    // nome usato nei JSON del backend, qui tradotto nel segmento di URL.
    const SEGMENTO_TIPO_LOTTO = {
        materia_prima: 'materie-prime',
        semilavorato: 'semilavorati',
        prodotto_finito: 'prodotti-finiti'
    };
    App.RegistroViste.registra('tracciabilita_lotto', 'Apri la tracciabilit\u00e0', (parametri) =>
        App.Router.url('tracciabilita',
            [SEGMENTO_TIPO_LOTTO[parametri.tipo_lotto] || parametri.tipo_lotto, parametri.lotto_id]));

    App.Router.registra('tracciabilita', {
        titolo: 'Tracciabilit&agrave; lotti',

        async render(rotta) {
            const [tipo, id] = rotta.parametri;
            if (!tipo || !id) return renderSelettore(tipo);
            return renderAlbero(tipo, id);
        },

        dopoRender(rotta) {
            const [tipo, id] = rotta.parametri;
            if (!tipo || !id) {
                collegaSelettore();
            } else {
                collegaApertura();
            }
        }
    });

    /* ==============================================================
       SELETTORE MANUALE (nessun tipo/id nell'URL)
       ============================================================== */

    function renderSelettore(tipoPreselezionato) {
        const opzioniTipo = Object.keys(TIPI).map((chiave) =>
            '<option value="' + chiave + '"' + (chiave === tipoPreselezionato ? ' selected' : '') + '>' +
                TIPI[chiave].etichetta + '</option>'
        ).join('');

        return '<div class="placeholder-view"><div style="max-width:28rem">' +
            U.icona('box', 'ico-grande') +
            '<h2 class="h5 mt-3 mb-1">Traccia un lotto</h2>' +
            '<p class="mb-3 text-body-secondary">Scegli il tipo e l&rsquo;identificativo del lotto di partenza: ' +
                'la stessa scelta che compare come pulsante &laquo;Traccia&raquo; nella vista Lotti.</p>' +
            '<form id="formTracciaLotto" class="d-flex flex-wrap gap-2 justify-content-center">' +
                '<select class="form-select form-select-sm" style="max-width:12rem" id="tracciaTipo">' +
                    opzioniTipo +
                '</select>' +
                '<input type="number" min="1" class="form-control form-control-sm" style="max-width:8rem" ' +
                    'id="tracciaId" placeholder="Id lotto" required>' +
                '<button type="submit" class="btn btn-sm btn-primary">Traccia</button>' +
            '</form>' +
        '</div></div>';
    }

    function collegaSelettore() {
        const form = U.$('#formTracciaLotto');
        if (!form) return;

        form.addEventListener('submit', (e) => {
            e.preventDefault();
            const tipo = U.$('#tracciaTipo').value;
            const id = U.$('#tracciaId').value.trim();
            if (!id) return;
            App.Router.vaiA(App.Router.url('tracciabilita', [tipo, id]));
        });
    }

    /* ==============================================================
       ALBERO
       ============================================================== */

    async function renderAlbero(tipo, id) {
        const def = TIPI[tipo];
        if (!def) return statoTipoNonValido(tipo);

        const albero = await def.chiamaApi(id);
        if (!albero) return statoNonTrovato(tipo, id);

        return tipo === 'prodotti-finiti'
            ? renderAlberoProdottoFinito(tipo, id, albero)
            : renderAlberoConPropagazione(tipo, id, albero);
    }

    function statoTipoNonValido(tipo) {
        return '<div class="placeholder-view"><div>' +
            U.icona('box', 'ico-grande') +
            '<h2 class="h5 mt-3 mb-1">Tipo di lotto non valido</h2>' +
            '<p class="mb-3 text-body-secondary">&laquo;' + U.esc(tipo) + '&raquo; non &egrave; un tipo di lotto ' +
                'riconosciuto.</p>' +
            '<a class="btn btn-sm btn-outline-secondary" href="' + App.Router.url('tracciabilita') + '">' +
                'Traccia un altro lotto</a>' +
        '</div></div>';
    }

    function statoNonTrovato(tipo, id) {
        const def = TIPI[tipo];
        return '<div class="placeholder-view"><div>' +
            U.icona('box', 'ico-grande') +
            '<h2 class="h5 mt-3 mb-1">Lotto non trovato</h2>' +
            '<p class="mb-3 text-body-secondary">Nessun lotto di tipo &laquo;' + U.esc(def.etichetta) +
                '&raquo; con id ' + U.esc(id) + '.</p>' +
            '<a class="btn btn-sm btn-outline-secondary" href="' + App.Router.url('tracciabilita') + '">' +
                'Traccia un altro lotto</a>' +
        '</div></div>';
    }

    // Intestazione comune ai due layout: lotto di origine + link
    // "cambia lotto" per tornare al selettore senza dover navigare a
    // ritroso con il tasto Indietro del browser.
    function intestazioneOrigine(tipo, lottoOrigine) {
        return '<a class="small text-body-secondary d-inline-block mb-2" href="' + App.Router.url('tracciabilita') + '">' +
                '&larr; Traccia un altro lotto</a>' +
            '<div class="d-flex flex-wrap align-items-center gap-2 mb-3">' +
                U.icona('box') +
                '<h2 class="h5 mb-0">' + U.esc(lottoOrigine.entita_denominazione) + '</h2>' +
                '<span class="badge-soft badge-soft-grigio">' + U.esc(lottoOrigine.entita_codice) + '</span>' +
                '<code>' + U.esc(lottoOrigine.codice_lotto) + '</code>' +
                '<span class="badge-soft badge-soft-blu">' + U.esc(TIPI[tipo].etichetta) + '</span>' +
            '</div>';
    }

    // Materia prima / semilavorato: due colonne di card, una per i
    // semilavorati coinvolti e una per i prodotti finiti raggiunti -
    // esattamente le due liste che TServizioTracciabilita.AlberoX
    // restituisce (semilavorati_coinvolti, prodotti_finiti_raggiunti).
    function renderAlberoConPropagazione(tipo, id, albero) {
        const nessunaPropagazione = !albero.semilavorati_coinvolti.length && !albero.prodotti_finiti_raggiunti.length;

        if (nessunaPropagazione) {
            return '<div data-vista-dettaglio>' +
                intestazioneOrigine(tipo, albero.lotto_origine) +
                '<div class="placeholder-view"><div>' +
                    U.icona('box', 'ico-grande') +
                    '<h2 class="h5 mt-3 mb-1">Nessuna propagazione registrata</h2>' +
                    '<p class="mb-0 text-body-secondary" style="max-width:34rem">Questo lotto non risulta ancora ' +
                        'consumato in nessuna produzione: nessun semilavorato o prodotto finito lo contiene, al ' +
                        'momento, un eventuale ritiro/richiamo si fermerebbe qui.</p>' +
                '</div></div>' +
            '</div>';
        }

        return '<div data-vista-dettaglio>' +
            intestazioneOrigine(tipo, albero.lotto_origine) +
            '<div class="row g-3">' +
                '<div class="col-lg-6">' +
                    U.card({
                        icona: 'box', titolo: 'Semilavorati coinvolti (' + albero.semilavorati_coinvolti.length + ')',
                        contenuto: tabellaSemilavoratiCoinvolti(albero.semilavorati_coinvolti)
                    }) +
                '</div>' +
                '<div class="col-lg-6">' +
                    U.card({
                        icona: 'box', titolo: 'Prodotti finiti raggiunti (' + albero.prodotti_finiti_raggiunti.length + ')',
                        contenuto: elencoProdottiFinitiRaggiunti(albero.prodotti_finiti_raggiunti)
                    }) +
                '</div>' +
            '</div>' +
        '</div>';
    }

    function tabellaSemilavoratiCoinvolti(elenco) {
        if (!elenco.length) {
            return '<div class="card-body text-body-secondary small">Nessuno.</div>';
        }

        const righe = elenco.map((l) =>
            '<tr class="align-middle" style="cursor:pointer" data-apri-semilavorato="' + l.semilavorato_id + '">' +
                '<td>' + U.esc(l.entita_denominazione) +
                    '<div class="small text-body-secondary">' + U.esc(l.entita_codice) + '</div>' +
                '</td>' +
                '<td><code>' + U.esc(l.codice_lotto) + '</code></td>' +
                '<td>' + badgeDirettezza(l.consumato_direttamente) + '</td>' +
                '<td class="text-end">' + U.fmtNum(l.quantita_consumata, 2) + ' ' + U.esc(l.unita_misura_consumata || l.unita_misura || '') + '</td>' +
            '</tr>'
        ).join('');

        return U.tabella([
            { testo: 'Semilavorato' }, { testo: 'Lotto' }, { testo: 'Consumo' },
            { testo: 'Quantit&agrave; consumata', allineaDx: true }
        ], righe);
    }

    // Non una tabella ma un elenco di card espandibili, una per lotto di
    // prodotto finito raggiunto: ognuna porta gia' con se' le proprie
    // spedizioni (array annidato nell'oggetto JSON, vedi
    // AggiungiProdottoFinitoRaggiunto lato backend), che una singola
    // riga di tabella non potrebbe mostrare in modo leggibile.
    function elencoProdottiFinitiRaggiunti(elenco) {
        if (!elenco.length) {
            return '<div class="card-body text-body-secondary small">Nessuno.</div>';
        }

        return '<div class="card-body p-0">' +
            elenco.map((pf, indice) => cardProdottoFinitoRaggiunto(pf, indice)).join('') +
        '</div>';
    }

    function cardProdottoFinitoRaggiunto(pf, indice) {
        const idCollapse = 'spedizioniPf' + indice;

        return '<div class="p-3' + (indice > 0 ? ' border-top' : '') + '">' +
            '<div class="d-flex flex-wrap align-items-center gap-2" style="cursor:pointer" ' +
                    'data-apri-prodotto-finito="' + pf.prodotto_finito_id + '">' +
                '<div class="flex-grow-1">' +
                    U.esc(pf.entita_denominazione) +
                    '<div class="small text-body-secondary"><code>' + U.esc(pf.codice_lotto) + '</code> &middot; ' +
                        U.esc(pf.entita_codice) + '</div>' +
                '</div>' +
                badgeDirettezza(pf.consumato_direttamente) +
                '<div class="text-end small">' +
                    U.fmtNum(pf.quantita_consumata, 2) + ' ' + U.esc(pf.unita_misura_consumata || pf.unita_misura || '') +
                '</div>' +
            '</div>' +
            '<button type="button" class="btn btn-sm btn-link px-0 mt-1" data-toggle-collapse="' + idCollapse + '">' +
                pf.spedizioni.length + ' spedizion' + (pf.spedizioni.length === 1 ? 'e' : 'i') +
                ' &nbsp;&rsaquo;' +
            '</button>' +
            '<div id="' + idCollapse + '" class="d-none mt-2">' +
                tabellaSpedizioni(pf.spedizioni) +
            '</div>' +
        '</div>';
    }

    // Prodotto finito: nessuna propagazione a valle (e' gia' il
    // capolinea della distinta base, vedi AlberoProdottoFinito lato
    // backend), solo le sue spedizioni - stessa tabellaSpedizioni() dei
    // prodotti finiti raggiunti dal ramo materia prima/semilavorato,
    // qui in prima pagina invece che dentro una card collassabile.
    function renderAlberoProdottoFinito(tipo, id, albero) {
        return '<div data-vista-dettaglio>' +
            intestazioneOrigine(tipo, albero.lotto_origine) +
            U.card({
                icona: 'vendite', titolo: 'Spedizioni (' + albero.spedizioni.length + ')',
                contenuto: albero.spedizioni.length
                    ? '<div class="card-body p-0">' + tabellaSpedizioni(albero.spedizioni) + '</div>'
                    : '<div class="card-body text-body-secondary small">Nessun ordine di vendita referenzia questo lotto.</div>'
            }) +
        '</div>';
    }

    function tabellaSpedizioni(spedizioni) {
        if (!spedizioni.length) {
            return '<div class="text-body-secondary small p-3">Nessuna.</div>';
        }

        const righe = spedizioni.map((s) =>
            '<tr class="align-middle">' +
                '<td><code>' + U.esc(s.numero_ordine) + '</code>' +
                    '<div class="small text-body-secondary">' + U.fmtData(s.data_ordine) + '</div>' +
                '</td>' +
                '<td>' + U.esc(s.cliente) + '</td>' +
                '<td>' + App.Utils.badgeStato(s.stato_ordine) + '</td>' +
                '<td class="text-end">' + U.fmtNum(s.quantita_ordinata, 0) + ' ' + U.esc(s.unita_misura || '') + '</td>' +
                '<td>' + badgeSpedizione(s) + '</td>' +
            '</tr>'
        ).join('');

        return U.tabella([
            { testo: 'Ordine' }, { testo: 'Cliente' }, { testo: 'Stato ordine' },
            { testo: 'Quantit&agrave; ordinata', allineaDx: true }, { testo: 'Spedizione' }
        ], righe);
    }

    // Distinzione "ordinato" vs "spedito" (vedi il commento di classe
    // in uServiziTracciabilita.pas): un ordine confermato ma non ancora
    // spedito non ha DDT, quindi mostriamo un badge di attesa invece del
    // numero DDT/data che semplicemente non esistono ancora.
    function badgeSpedizione(s) {
        if (!s.spedito) {
            return '<span class="badge-soft badge-soft-ambra">In attesa di spedizione</span>';
        }
        return '<span class="badge-soft badge-soft-verde">' + U.esc(s.numero_ddt) + '</span>' +
            '<div class="small text-body-secondary">' + U.fmtData(s.data_spedizione) +
                ' &middot; ' + U.fmtNum(s.quantita_spedita, 0) + '</div>';
    }

    function badgeDirettezza(consumatoDirettamente) {
        return consumatoDirettamente
            ? '<span class="badge-soft badge-soft-blu">Consumo diretto</span>'
            : '<span class="badge-soft badge-soft-grigio">Via semilavorato</span>';
    }

    // Un solo listener delegato per tre cose: apertura anagrafica
    // semilavorato/prodotto finito raggiunto (stesso pattern di
    // collegaApertura() in view-lotti.js) e il toggle degli
    // approfondimenti "spedizioni" per ogni prodotto finito raggiunto
    // (mostra/nasconde, niente da ricaricare: i dati sono gia' nel DOM).
    function collegaApertura() {
        const contenitore = U.$('#content');
        if (!contenitore) return;

        contenitore.addEventListener('click', (e) => {
            const apriSemilavorato = e.target.closest('[data-apri-semilavorato]');
            if (apriSemilavorato) {
                App.Router.vaiA(App.Router.url('semilavorati', [apriSemilavorato.dataset.apriSemilavorato]));
                return;
            }

            const apriProdottoFinito = e.target.closest('[data-apri-prodotto-finito]');
            if (apriProdottoFinito) {
                App.Router.vaiA(App.Router.url('prodotti-finiti', [apriProdottoFinito.dataset.apriProdottoFinito]));
                return;
            }

            const toggle = e.target.closest('[data-toggle-collapse]');
            if (toggle) {
                const pannello = U.$('#' + toggle.dataset.toggleCollapse);
                if (pannello) pannello.classList.toggle('d-none');
            }
        });
    }
})();
