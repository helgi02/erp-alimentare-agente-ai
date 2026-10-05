/* =====================================================================
   views/view-semilavorati.js — anagrafica semilavorati.

   Gemella di view-prodotti-finiti.js: stessa struttura (elenco con
   ricerca client-side, scheda anagrafica dedicata aperta in una tab
   propria, CTA "Vai alla ricetta"), senza le due cose che i semilavorati
   non hanno - giorni di scadenza standard e varianti dietetiche
   (prodotto_finito_padre_id esiste solo su anagrafiche_prodotti_finiti,
   vedi uModelSemilavorato.pas: nessun campo equivalente).

   Il controller Delphi (uControllerSemilavorati.pas) e' di sola lettura
   per ora: questa vista quindi non ha ne' un form di creazione ne'
   un'azione di modifica funzionante. Il pulsante "Modifica" nella scheda
   resta percio' disabilitato con un motivo diverso da quello di
   view-prodotti-finiti.js (li' manca solo il form, qui manca anche
   l'endpoint PUT lato backend) - vedi schedaAnagrafica() piu' sotto.

   Vedi il commento "DUE MODALITA' SULLA STESSA ROTTA" e il commento
   "CAMPI VOLUTAMENTE FUORI DA QUESTA SCHEDA" in cima a
   view-prodotti-finiti.js: stessi principi qui, /semilavorati per
   l'elenco e /semilavorati/(id) per la scheda del singolo semilavorato,
   con la tab etichettata a runtime col nome (App.Tabs.impostaDettaglio(),
   vedi core/tabs.js) invece che col solo id, e senza prezzo/categoria/
   peso netto/giacenza per la stessa ragione (nessuna colonna in
   anagrafiche_semilavorati, decisione rimandata).
   ===================================================================== */

(function () {
    'use strict';

    const U = App.Utils;

    App.Router.registra('semilavorati', {
        titolo: 'Semilavorati',

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

    // Vista apribile dall'agente tramite il tool apri_vista, con lo STESSO
    // nome 'semilavorato' registrato lato backend in TRegistroViste.Registra
    // (uFrmMain.pas) - vedi il commento gemello in view-prodotti-finiti.js e
    // core/registro-viste.js per il perche' di questo secondo registro,
    // gemello di quello Delphi.
    App.RegistroViste.registra('semilavorato', 'Vai all\'anagrafica',
        (parametri) => App.Router.url('semilavorati', [parametri.semilavorato_id]));

    /* ==============================================================
       ELENCO
       ============================================================== */

    async function renderLista() {
        const semilavorati = await App.Api.Semilavorati.getAll();
        return barraRicerca() + tabellaSemilavorati(semilavorati);
    }

    function barraRicerca() {
        return '<div class="mb-3">' +
            '<input type="search" class="form-control form-control-sm" style="max-width:22rem" ' +
            'id="ricercaSemilavorati" placeholder="Cerca per codice o denominazione&hellip;">' +
        '</div>';
    }

    function tabellaSemilavorati(semilavorati) {
        if (!semilavorati.length) {
            return '<div class="card"><div class="card-body text-body-secondary">' +
                'Nessun semilavorato in anagrafica.</div></div>';
        }

        const righe = semilavorati.map((s) => {
            const nomeRicerca = (s.codice + ' ' + s.denominazione).toLowerCase();

            return '<tr class="align-middle" style="cursor:pointer" ' +
                    'data-semilavorato="' + s.id + '" data-ricerca="' + U.esc(nomeRicerca) + '">' +
                '<td><code>' + U.esc(s.codice) + '</code></td>' +
                '<td>' + U.esc(s.denominazione) + '</td>' +
            '</tr>';
        }).join('');

        return '<div class="card">' +
            U.tabella([{ testo: 'Codice' }, { testo: 'Denominazione' }], righe) +
        '</div>';
    }

    function collegaRicerca() {
        const input = U.$('#ricercaSemilavorati');
        if (!input) return;

        input.addEventListener('input', () => {
            const testo = input.value.trim().toLowerCase();
            U.$$('[data-ricerca]').forEach((tr) => {
                tr.classList.toggle('d-none', !(!testo || tr.dataset.ricerca.indexOf(testo) !== -1));
            });
        });
    }

    // Stesso pattern di collegaApertura() in view-prodotti-finiti.js: un
    // solo listener delegato, il click su una riga naviga verso
    // /semilavorati/(id) invece di espandere un accordion in riga.
    function collegaApertura() {
        const contenitore = U.$('#content');
        if (!contenitore) return;

        contenitore.addEventListener('click', (e) => {
            const riga = e.target.closest('[data-semilavorato]');
            if (!riga) return;

            App.Router.vaiA(App.Router.url('semilavorati', [riga.dataset.semilavorato]));
        });
    }

    /* ==============================================================
       SCHEDA ANAGRAFICA (dettaglio)
       ============================================================== */

    async function renderDettaglio(id) {
        let semilavorato;
        try {
            semilavorato = await App.Api.Semilavorati.getById(id);
        } catch (errore) {
            if (errore.status === 404) return statoNonTrovato(id);
            throw errore; // errore vero: lo mostra il router (vedi router.js)
        }
        // Ramo App.Config.MOCK = true: getById() non lancia, restituisce
        // null se l'id non esiste fra i dati dimostrativi.
        if (!semilavorato) return statoNonTrovato(id);

        // Allergeni e ricetta corrente (per il solo costo totale) sono
        // richieste indipendenti, lanciate insieme: vedi il commento
        // gemello in view-prodotti-finiti.js sul perche' un 404 sulla
        // ricetta non e' trattato come errore qui.
        const [esitoAllergeni, esitoRicetta] = await Promise.allSettled([
            App.Api.Semilavorati.getAllergeni(id),
            App.Api.Ricette.semilavorato(id)
        ]);
        const allergeni = esitoAllergeni.status === 'fulfilled' ? esitoAllergeni.value : [];
        const ricetta = esitoRicetta.status === 'fulfilled' ? esitoRicetta.value : null;

        return schedaAnagrafica(semilavorato, allergeni, ricetta);
    }

    function statoNonTrovato(id) {
        return '<div class="placeholder-view"><div>' +
            U.icona('box', 'ico-grande') +
            '<h2 class="h5 mt-3 mb-1">Semilavorato non trovato</h2>' +
            '<p class="mb-3 text-body-secondary" style="max-width:34rem">' +
                'Nessun semilavorato con id ' + U.esc(id) + ' in anagrafica.</p>' +
            '<a class="btn btn-sm btn-outline-secondary" href="' + App.Router.url('semilavorati') + '">' +
                'Torna all&rsquo;elenco</a>' +
        '</div></div>';
    }

    // data-denominazione sulla radice: vedi il commento gemello in
    // view-prodotti-finiti.js — e' cosi' che collegaDettaglio() recupera
    // il nome appena caricato per etichettare la tab (App.Tabs.
    // impostaDettaglio(), vedi core/tabs.js), senza rifare la fetch.
    function schedaAnagrafica(s, allergeni, ricetta) {
        // Pillole allergeni in stile neutro: vedi il commento esteso
        // gemello in view-prodotti-finiti.js (stessa classe badge-soft-
        // grigio di U.badgeStato('annullato'), niente icone di categoria
        // per ora - lo sprite SVG non le ha e aggiungerle tocca un file
        // rigenerato da Bootstrap Studio).
        const badgeAllergeni = allergeni.length
            ? allergeni.map((a) =>
                '<span class="badge-soft badge-soft-grigio me-1" title="' + U.esc(a.codice) + '">' +
                U.esc(a.denominazione) + '</span>').join('')
            : '<span class="text-body-secondary small">Nessun allergene dichiarato.</span>';

        // Stesso ragionamento di tabellaComponenti() in view-ricette.js:
        // costo_totale a 2 decimali (non l'euro intero di U.fmtEuro di
        // default, che su questi importi - spesso sotto 1 euro -
        // arrotonderebbe quasi tutto a "0 EUR") e avviso quando
        // costo_completo e' false (la ricetta contiene almeno un
        // semilavorato, il cui costo non e' calcolabile: vedi il
        // commento su TCostoRicetta.CostoCompleto in uServiziRicette.pas
        // lato backend).
        const costoRicettaHtml = ricetta
            ? U.fmtEuro(ricetta.costo_totale, 2) +
                (ricetta.costo_completo === false
                    ? ' <span class="badge-soft badge-soft-ambra" title="Uno o pi&ugrave; componenti sono semilavorati: il loro costo non &egrave; calcolabile (manca la resa di produzione), quindi questo &egrave; un costo parziale.">parziale</span>'
                    : '') +
                ' <span class="text-body-secondary small">(v' + U.esc(ricetta.versione) + ')</span>'
            : '<span class="text-body-secondary">Nessuna ricetta corrente</span>';

        return '<div data-vista-dettaglio data-denominazione="' + U.esc(s.denominazione) + '">' +

            '<a class="small text-body-secondary d-inline-block mb-2" href="' + App.Router.url('semilavorati') + '">' +
                '&larr; Tutti i semilavorati</a>' +

            // Intestazione: nome, codice come badge, "Modifica"
            // disabilitato (qui per un motivo in piu' rispetto ai
            // prodotti finiti: TControllerSemilavorati non ha nemmeno
            // l'endpoint PUT, e' di sola lettura per scelta di progetto -
            // vedi il commento in testa a quel file) e la CTA primaria
            // verso la ricetta corrente.
            '<div class="d-flex flex-wrap align-items-center gap-2 mb-3">' +
                U.icona('box') +
                '<h2 class="h5 mb-0">' + U.esc(s.denominazione) + '</h2>' +
                '<span class="badge-soft badge-soft-grigio">' + U.esc(s.codice) + '</span>' +
                '<div class="ms-auto d-flex gap-2">' +
                    '<button type="button" class="btn btn-sm btn-outline-secondary" disabled ' +
                        'title="Anagrafica di sola lettura: il controller Delphi non espone ancora un endpoint di aggiornamento.">' +
                        'Modifica</button>' +
                    '<a class="btn btn-sm btn-primary" href="' + App.Router.url('ricette', ['semilavorati', s.id]) + '">' +
                        U.icona('ricette') + ' Vai alla ricetta</a>' +
                '</div>' +
            '</div>' +

            // Griglia (vedi campoGriglia() e il commento gemello in
            // view-prodotti-finiti.js): qui solo 3 campi (nessuna
            // scadenza standard ne' variante padre, che i semilavorati
            // non hanno), comunque piu' leggibili affiancati che in una
            // tabella verticale a piena larghezza.
            U.card({
                icona: 'box', titolo: 'Anagrafica',
                corpo: '<div class="row g-3">' +
                    campoGriglia('Costo ricetta corrente', costoRicettaHtml) +
                    campoGriglia('Creato il', U.fmtData(s.creato_il)) +
                    campoGriglia('Aggiornato il', U.fmtData(s.aggiornato_il)) +
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
