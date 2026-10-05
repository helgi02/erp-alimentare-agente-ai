/* =====================================================================
   views/view-materie-prime.js — anagrafica materie prime.

   Terza vista della stessa famiglia di view-prodotti-finiti.js e
   view-semilavorati.js: elenco con ricerca client-side + scheda
   anagrafica aperta in una tab propria (vedi i commenti "DUE MODALITA'
   SULLA STESSA ROTTA" e "CAMPI VOLUTAMENTE FUORI DA QUESTA SCHEDA" in
   cima a view-prodotti-finiti.js, stessi principi qui).

   COSA MANCA RISPETTO ALLE ALTRE DUE, E PERCHE'
   Nessuna CTA "Vai alla ricetta": una materia prima non HA una ricetta
   propria (e' un ingrediente ACQUISTATO, non prodotto internamente) -
   compare come componente nelle ricette di prodotti finiti e
   semilavorati, mai come intestazione di una ricetta sua. Per lo stesso
   motivo anagrafiche_materie_prime non ha ne' scadenza standard ne'
   variante padre (vedi uModelMateriaPrima.pas): la scheda qui sotto ha
   solo codice, denominazione, allergeni dichiarati e i due campi di
   audit - ancora piu' scarna di quella dei semilavorati.

   "Modifica" resta disabilitato come nelle due viste gemelle, ma per un
   motivo diverso da quello dei semilavorati: qui il controller Delphi
   (uControllerMateriePrime.pas) espone gia' un CRUD completo (POST, PUT,
   DELETE oltre a GET), quindi la ragione e' solo "manca il form lato
   frontend", esattamente come per i prodotti finiti - non "manca anche
   l'endpoint" come per i semilavorati. Vedi il title del pulsante piu'
   sotto.
   ===================================================================== */

(function () {
    'use strict';

    const U = App.Utils;

    App.Router.registra('materie-prime', {
        titolo: 'Materie prime',

        async render(rotta) {
            const id = rotta.parametri[0];
            return id ? renderDettaglio(id) : renderLista();
        },

        dopoRender(rotta) {
            const id = rotta.parametri[0];
            if (id) {
                collegaDettaglio(rotta);
            } else {
                collegaRicerca();
                collegaApertura();
            }
        }
    });

    // NB: nessuna App.RegistroViste.registra() qui. Le viste apribili
    // dall'agente tramite il tool apri_vista sono quelle per cui esiste
    // GIA' una registrazione gemella lato backend in TRegistroViste.
    // Registra (uFrmMain.pas) - oggi solo 'prodotto_finito' e
    // 'semilavorato' (vedi i commenti gemelli in view-prodotti-finiti.js
    // e view-semilavorati.js). Aggiungere qui una voce 'materia_prima'
    // senza la corrispondente registrazione Delphi non aprirebbe nulla
    // (App.RegistroViste.risolvi() la ignorerebbe comunque in silenzio,
    // vedi core/registro-viste.js) e romperebbe la simmetria voluta fra
    // i due registri: da aggiungere insieme, se e quando servira'.

    /* ==============================================================
       ELENCO
       ============================================================== */

    async function renderLista() {
        const materiePrime = await App.Api.MateriePrime.getAll();
        return barraRicerca() + tabellaMateriePrime(materiePrime);
    }

    function barraRicerca() {
        return '<div class="mb-3">' +
            '<input type="search" class="form-control form-control-sm" style="max-width:22rem" ' +
            'id="ricercaMateriePrime" placeholder="Cerca per codice o denominazione&hellip;">' +
        '</div>';
    }

    function tabellaMateriePrime(materiePrime) {
        if (!materiePrime.length) {
            return '<div class="card"><div class="card-body text-body-secondary">' +
                'Nessuna materia prima in anagrafica.</div></div>';
        }

        const righe = materiePrime.map((m) => {
            const nomeRicerca = (m.codice + ' ' + m.denominazione).toLowerCase();

            return '<tr class="align-middle" style="cursor:pointer" ' +
                    'data-materia-prima="' + m.id + '" data-ricerca="' + U.esc(nomeRicerca) + '">' +
                '<td><code>' + U.esc(m.codice) + '</code></td>' +
                '<td>' + U.esc(m.denominazione) + '</td>' +
            '</tr>';
        }).join('');

        return '<div class="card">' +
            U.tabella([{ testo: 'Codice' }, { testo: 'Denominazione' }], righe) +
        '</div>';
    }

    function collegaRicerca() {
        const input = U.$('#ricercaMateriePrime');
        if (!input) return;

        input.addEventListener('input', () => {
            const testo = input.value.trim().toLowerCase();
            U.$$('[data-ricerca]').forEach((tr) => {
                tr.classList.toggle('d-none', !(!testo || tr.dataset.ricerca.indexOf(testo) !== -1));
            });
        });
    }

    // Stesso pattern delegato di collegaApertura() in
    // view-prodotti-finiti.js/view-semilavorati.js.
    function collegaApertura() {
        const contenitore = U.$('#content');
        if (!contenitore) return;

        contenitore.addEventListener('click', (e) => {
            const riga = e.target.closest('[data-materia-prima]');
            if (!riga) return;

            App.Router.vaiA(App.Router.url('materie-prime', [riga.dataset.materiaPrima]));
        });
    }

    /* ==============================================================
       SCHEDA ANAGRAFICA (dettaglio)
       ============================================================== */

    async function renderDettaglio(id) {
        let materiaPrima;
        try {
            materiaPrima = await App.Api.MateriePrime.getById(id);
        } catch (errore) {
            if (errore.status === 404) return statoNonTrovato(id);
            throw errore; // errore vero: lo mostra il router (vedi router.js)
        }
        // Ramo App.Config.MOCK = true: getById() non lancia, restituisce
        // null se l'id non esiste fra i dati dimostrativi.
        if (!materiaPrima) return statoNonTrovato(id);

        const allergeni = await App.Api.MateriePrime.getAllergeni(id).catch(() => []);

        return schedaAnagrafica(materiaPrima, allergeni);
    }

    function statoNonTrovato(id) {
        return '<div class="placeholder-view"><div>' +
            U.icona('box', 'ico-grande') +
            '<h2 class="h5 mt-3 mb-1">Materia prima non trovata</h2>' +
            '<p class="mb-3 text-body-secondary" style="max-width:34rem">' +
                'Nessuna materia prima con id ' + U.esc(id) + ' in anagrafica.</p>' +
            '<a class="btn btn-sm btn-outline-secondary" href="' + App.Router.url('materie-prime') + '">' +
                'Torna all&rsquo;elenco</a>' +
        '</div></div>';
    }

    // data-denominazione sulla radice: vedi il commento gemello in
    // view-prodotti-finiti.js - e' cosi' che collegaDettaglio() recupera
    // il nome appena caricato per etichettare la tab (App.Tabs.
    // impostaDettaglio(), vedi core/tabs.js), senza rifare la fetch.
    function schedaAnagrafica(m, allergeni) {
        const badgeAllergeni = allergeni.length
            ? allergeni.map((a) =>
                '<span class="badge-soft badge-soft-grigio me-1" title="' + U.esc(a.codice) + '">' +
                U.esc(a.denominazione) + '</span>').join('')
            : '<span class="text-body-secondary small">Nessun allergene dichiarato.</span>';

        return '<div data-vista-dettaglio data-denominazione="' + U.esc(m.denominazione) + '">' +

            '<a class="small text-body-secondary d-inline-block mb-2" href="' + App.Router.url('materie-prime') + '">' +
                '&larr; Tutte le materie prime</a>' +

            // Intestazione: nome, codice come badge, "Modifica"
            // disabilitato (form non ancora implementato, vedi il
            // commento in cima al file per il perche' del title).
            '<div class="d-flex flex-wrap align-items-center gap-2 mb-3">' +
                U.icona('box') +
                '<h2 class="h5 mb-0">' + U.esc(m.denominazione) + '</h2>' +
                '<span class="badge-soft badge-soft-grigio">' + U.esc(m.codice) + '</span>' +
                '<div class="ms-auto d-flex gap-2">' +
                    '<button type="button" class="btn btn-sm btn-outline-secondary" disabled ' +
                        'title="Form di modifica non ancora implementato (il backend supporta gi&agrave; PUT /api/materie-prime/(id)).">' +
                        'Modifica</button>' +
                '</div>' +
            '</div>' +

            // Griglia a 2 campi soli (nessuna scadenza standard ne'
            // variante padre, che le materie prime non hanno - vedi il
            // commento in cima al file).
            U.card({
                icona: 'box', titolo: 'Anagrafica',
                corpo: '<div class="row g-3">' +
                    campoGriglia('Creato il', U.fmtData(m.creato_il)) +
                    campoGriglia('Aggiornato il', U.fmtData(m.aggiornato_il)) +
                '</div>'
            }) +

            '<div class="mt-3">' +
            U.card({
                icona: 'nc', titolo: 'Allergeni dichiarati (Reg. UE 1169/2011)',
                corpo: badgeAllergeni
            }) +
            '</div>' +
        '</div>';
    }

    // Vedi il commento gemello in view-prodotti-finiti.js.
    function campoGriglia(etichetta, valoreHtml) {
        return '<div class="col-sm-6 col-lg-4">' +
            '<div class="small text-body-secondary mb-1">' + etichetta + '</div>' +
            '<div class="fw-medium">' + valoreHtml + '</div>' +
        '</div>';
    }

    function collegaDettaglio(rotta) {
        const radice = U.$('[data-vista-dettaglio]');
        if (!radice || !radice.dataset.denominazione) return; // stato "non trovato": niente da etichettare

        App.Tabs.impostaDettaglio(App.Tabs.chiave(rotta), radice.dataset.denominazione);
    }
})();
