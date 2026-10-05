/* =====================================================================
   views/view-lotti.js — lotti di materia prima, semilavorato e prodotto
   finito, in un'unica tabella.

   TRE CHIAMATE, UNA VISTA
   Il backend espone tre risorse separate (vedi il commento in cima ad
   api/api-lotti.js e, piu' esteso, in services/uServiziLotti.pas), ma
   la sidebar ha una sola voce "Lotti": questa vista lancia le tre
   getAll() in parallelo (Promise.all) e le unisce in un solo elenco,
   con un campo "tipo" aggiunto qui per distinguerle a video e per
   sapere, riga per riga, quale rotta di dettaglio aprire con un clic
   (vedi collegaApertura()). E' la stessa idea di "fusione lato client"
   gia' scelta con Helena per il design dei tre endpoint, invece di far
   fare la UNION al database - vedi quel commento per il perche'.

   NESSUNA SCHEDA DI DETTAGLIO PROPRIA
   Un lotto non ha una sua pagina: cliccare l'entita' di una riga porta
   all'anagrafica del prodotto/semilavorato/materia prima (rotte gia'
   esistenti: /materie-prime/(id), /semilavorati/(id),
   /prodotti-finiti/(id)), che e' dove un lotto "vive" concettualmente
   in questa fase del progetto. Una scheda-lotto a se stante (con
   tracciabilita' a valle/a monte) e' invece il compito della vista
   Tracciabilita' lotti (view-tracciabilita.js): il pulsante "Traccia"
   aggiunto in fondo a ogni riga (vedi rigaLotto() piu' sotto) e' il
   punto di ingresso normale a quella vista, gia' con tipo+id del lotto
   di partenza precompilati nell'URL - non serve passare dal selettore
   manuale che quella vista offre a chi ci arriva senza un lotto gia'
   scelto.

   ORDINAMENTO
   FEFO (First Expired, First Out) su chi ha una data_scadenza (materie
   prime e prodotti finiti), poi i lotti di semilavorato (che non ce
   l'hanno, vedi uModelLottoSemilavorato.pas) in coda. Stesso principio
   gia' seguito dai tre TLottoX.GetAll lato backend, qui esteso a un
   elenco che li contiene tutti e tre insieme.
   ===================================================================== */

(function () {
    'use strict';

    const U = App.Utils;

    // Tipo -> { etichetta, classeBadge, rotta anagrafica, nome del campo
    // che porta l'id dell'anagrafica }. Un solo posto da aggiornare se
    // un domani cambia una di queste quattro cose per un tipo.
    const TIPI = {
        materia_prima:   { etichetta: 'Materia prima',   badge: 'badge-soft-blu',   rotta: 'materie-prime',   campoID: 'materia_prima_id',   segTracciabilita: 'materie-prime' },
        semilavorato:    { etichetta: 'Semilavorato',    badge: 'badge-soft-ambra', rotta: 'semilavorati',    campoID: 'semilavorato_id',    segTracciabilita: 'semilavorati' },
        prodotto_finito: { etichetta: 'Prodotto finito',  badge: 'badge-soft-verde', rotta: 'prodotti-finiti', campoID: 'prodotto_finito_id', segTracciabilita: 'prodotti-finiti' }
    };

    App.Router.registra('lotti', {
        titolo: 'Lotti',

        async render() {
            const elenco = await caricaElenco();
            return barraFiltri() + tabellaLotti(elenco);
        },

        dopoRender() {
            collegaFiltri();
            collegaApertura();
        }
    });

    /* ==============================================================
       CARICAMENTO E FUSIONE DEI TRE ELENCHI
       ============================================================== */

    async function caricaElenco() {
        const [materiePrime, semilavorati, prodottiFiniti] = await Promise.all([
            App.Api.LottiMateriePrime.getAll(),
            App.Api.LottiSemilavorati.getAll(),
            App.Api.LottiProdottiFiniti.getAll()
        ]);

        const elenco = [].concat(
            materiePrime.map((l) => Object.assign({ tipo: 'materia_prima' }, l)),
            semilavorati.map((l) => Object.assign({ tipo: 'semilavorato' }, l)),
            prodottiFiniti.map((l) => Object.assign({ tipo: 'prodotto_finito' }, l))
        );

        // FEFO: chi ha data_scadenza prima (ordine crescente), chi non
        // ce l'ha (semilavorati) dopo tutti, ordinato per codice lotto
        // solo per avere un ordine stabile e prevedibile.
        elenco.sort((a, b) => {
            const chiaveA = a.data_scadenza ? new Date(a.data_scadenza).getTime() : Infinity;
            const chiaveB = b.data_scadenza ? new Date(b.data_scadenza).getTime() : Infinity;
            return chiaveA - chiaveB || a.codice_lotto.localeCompare(b.codice_lotto);
        });

        return elenco;
    }

    /* ==============================================================
       FILTRI (tipo + ricerca testuale, entrambi client-side: come le
       altre anagrafiche, l'elenco e' gia' tutto in memoria dopo il
       caricamento, non serve una nuova richiesta HTTP a ogni carattere
       o cambio di tendina)
       ============================================================== */

    function barraFiltri() {
        return '<div class="mb-3 d-flex flex-wrap gap-2">' +
            '<input type="search" class="form-control form-control-sm" style="max-width:22rem" ' +
                'id="ricercaLotti" placeholder="Cerca per codice lotto o denominazione&hellip;">' +
            '<select class="form-select form-select-sm" style="max-width:14rem" id="filtroTipoLotto">' +
                '<option value="">Tutti i tipi</option>' +
                '<option value="materia_prima">Materie prime</option>' +
                '<option value="semilavorato">Semilavorati</option>' +
                '<option value="prodotto_finito">Prodotti finiti</option>' +
            '</select>' +
        '</div>';
    }

    function collegaFiltri() {
        const input = U.$('#ricercaLotti');
        const select = U.$('#filtroTipoLotto');
        if (!input || !select) return;

        const applica = () => {
            const testo = input.value.trim().toLowerCase();
            const tipo = select.value;

            U.$$('[data-riga-lotto]').forEach((tr) => {
                const passaTesto = !testo || tr.dataset.ricerca.indexOf(testo) !== -1;
                const passaTipo = !tipo || tr.dataset.tipo === tipo;
                tr.classList.toggle('d-none', !(passaTesto && passaTipo));
            });
        };

        input.addEventListener('input', applica);
        select.addEventListener('change', applica);
    }

    /* ==============================================================
       TABELLA
       ============================================================== */

    function tabellaLotti(elenco) {
        if (!elenco.length) {
            return '<div class="card"><div class="card-body text-body-secondary">' +
                'Nessun lotto in giacenza.</div></div>';
        }

        const righe = elenco.map(rigaLotto).join('');

        return '<div class="card">' +
            U.tabella([
                { testo: 'Tipo' }, { testo: 'Codice lotto' }, { testo: 'Entit&agrave;' },
                { testo: 'Quantit&agrave; disponibile', allineaDx: true }, { testo: 'Scadenza' }, { testo: '' }
            ], righe) +
        '</div>';
    }

    function rigaLotto(l) {
        const def = TIPI[l.tipo];
        const nomeRicerca = (l.codice_lotto + ' ' + l.entita_codice + ' ' + l.entita_denominazione).toLowerCase();
        const esaurito = l.quantita_disponibile <= 0
            ? ' <span class="badge-soft badge-soft-grigio">esaurito</span>' : '';

        return '<tr class="align-middle" data-riga-lotto data-tipo="' + l.tipo + '" ' +
                'data-entita="' + l[def.campoID] + '" data-ricerca="' + U.esc(nomeRicerca) + '">' +
            '<td><span class="badge-soft ' + def.badge + '">' + def.etichetta + '</span></td>' +
            '<td><code>' + U.esc(l.codice_lotto) + '</code></td>' +
            '<td style="cursor:pointer" data-apri-entita>' +
                U.esc(l.entita_denominazione) +
                '<div class="small text-body-secondary">' + U.esc(l.entita_codice) + '</div>' +
            '</td>' +
            '<td class="text-end">' +
                U.fmtNum(l.quantita_disponibile, 2) + ' ' + U.esc(l.unita_misura || '') + esaurito +
            '</td>' +
            '<td>' + cellaScadenza(l) + '</td>' +
            '<td class="text-end">' +
                '<a class="btn btn-sm btn-outline-secondary" href="' +
                    App.Router.url('tracciabilita', [def.segTracciabilita, l.id]) + '" title="Traccia la propagazione di questo lotto">' +
                    U.icona('tracciabilita') + ' Traccia</a>' +
            '</td>' +
        '</tr>';
    }

    // Per i semilavorati (nessuna data_scadenza in anagrafica, vedi il
    // commento in cima al file) mostriamo la data di produzione, senza
    // badge di urgenza: non c'e' una soglia di scadenza da segnalare.
    function cellaScadenza(l) {
        if (l.tipo === 'semilavorato') {
            return '<span class="text-body-secondary small">Prodotto il ' + U.fmtData(l.data_produzione) + '</span>';
        }
        return U.fmtData(l.data_scadenza) + ' ' + badgeScadenza(l.data_scadenza);
    }

    // Soglie in giorni alla scadenza, coerenti con quelle gia' usate dal
    // KPI "lotti in scadenza" della dashboard (30 giorni, vedi
    // App.MockData.dashboard.kpi.giorniScadenza): sotto i 7 giorni e'
    // urgenza rossa, sotto i 30 e' attenzione ambra, oltre e' verde.
    function badgeScadenza(iso) {
        if (!iso) return '<span class="text-body-secondary small">&mdash;</span>';

        const oggi = new Date();
        oggi.setHours(0, 0, 0, 0);
        const giorni = Math.round((new Date(iso) - oggi) / 86400000);

        let classe = 'badge-soft-verde';
        let testo = giorni + ' gg';
        if (giorni < 0) {
            classe = 'badge-soft-grigio';
            testo = 'scaduto';
        } else if (giorni <= 7) {
            classe = 'badge-soft-rosa';
        } else if (giorni <= 30) {
            classe = 'badge-soft-ambra';
        }

        return '<span class="badge-soft ' + classe + '">' + U.esc(testo) + '</span>';
    }

    // Un solo listener delegato (stesso pattern di collegaApertura() nelle
    // altre viste): il clic sulla cella entita' naviga alla rotta di
    // anagrafica del tipo di QUELLA riga, letta da data-tipo/data-entita
    // invece che ricalcolata qui.
    function collegaApertura() {
        const contenitore = U.$('#content');
        if (!contenitore) return;

        contenitore.addEventListener('click', (e) => {
            const cella = e.target.closest('[data-apri-entita]');
            if (!cella) return;

            const riga = cella.closest('[data-riga-lotto]');
            const def = TIPI[riga.dataset.tipo];
            App.Router.vaiA(App.Router.url(def.rotta, [riga.dataset.entita]));
        });
    }
})();
