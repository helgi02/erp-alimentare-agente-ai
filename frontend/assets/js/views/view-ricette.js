/* =====================================================================
   views/view-ricette.js — ricette e distinte base.

   DUE MODALITA' SULLA STESSA ROTTA
   /ricette                          elenco sintetico di tutte le ricette
                                      CORRENTI (prodotti finiti + semilavorati)
   /ricette/prodotti-finiti/(id)     dettaglio: componenti, dosi, costo
   /ricette/semilavorati/(id)        idem, per un semilavorato

   Stesso principio di /vendite/(id) in view-vendite.js: un solo file
   registra una sola rotta, e legge rotta.parametri per decidere cosa
   disegnare — non due rotte separate, perche' "apri la ricetta di X" e
   "sfoglia tutte le ricette" sono la stessa schermata a due livelli di
   zoom, non due schermate diverse.

   IL 404 "NESSUNA RICETTA" NON E' UN ERRORE
   Un prodotto o un semilavorato senza ancora una ricetta e' uno stato
   normale (es. appena creato), non un guasto: App.Http ora allega
   errore.status alla Error lanciata (vedi common.js), cosi' questa vista
   lo intercetta e mostra una card informativa invece di far scattare
   l'alert rosso generico del router (core/router.js, catch in naviga()).

   COLLEGAMENTO CON IL BOTTONE "Vai alla ricetta"
   view-prodotti-finiti.js e view-semilavorati.js linkano qui passando
   tipo+id nel path — vedi urlDettaglio() sotto, unico punto che costruisce
   quell'URL, cosi' le altre due viste non devono conoscerne la forma.
   ===================================================================== */

(function () {
    'use strict';

    const U = App.Utils;

    App.Router.registra('ricette', {
        titolo: 'Ricette e distinte',

        async render(rotta) {
            const [segmento, id] = rotta.parametri;

            if (segmento === 'prodotti-finiti' && id) return renderDettaglio('prodotto_finito', id);
            if (segmento === 'semilavorati' && id) return renderDettaglio('semilavorato', id);
            return renderLista();
        },

        dopoRender(rotta) {
            collegaRicerca();
        }
    });

    // Vista apribile dall'agente tramite il tool apri_vista, con lo
    // STESSO nome 'ricetta_prodotto_finito' registrato lato backend in
    // TRegistroViste.Registra (uFrmMain.pas) - vedi core/registro-viste.js
    // per il perche' di questo secondo registro, gemello di quello Delphi.
    // urlDettaglio() e' la stessa funzione usata dai link "Vai alla
    // ricetta" della lista qui sotto: un solo punto costruisce quell'URL,
    // che arrivi da un click dell'utente o da una richiesta dell'agente.
    App.RegistroViste.registra('ricetta_prodotto_finito', 'Vai alla ricetta',
        (parametri) => urlDettaglio('prodotto_finito', parametri.prodotto_finito_id));

    // 'prodotto_finito' -> segmento URL 'prodotti-finiti' (e viceversa
    // per 'semilavorato'/'semilavorati'): stessa differenza singolare/
    // plurale gia' fra il nome del tipo nei JSON del backend (vedi
    // uControllerRicette.pas, campo "tipo") e il nome della risorsa REST/
    // vista anagrafica corrispondente.
    function urlDettaglio(tipo, id) {
        return App.Router.url('ricette', [tipo === 'prodotto_finito' ? 'prodotti-finiti' : 'semilavorati', id]);
    }

    function urlAnagrafica(tipo, id) {
        return App.Router.url(tipo === 'prodotto_finito' ? 'prodotti-finiti' : 'semilavorati', [id]);
    }

    function badgeTipo(tipo) {
        return tipo === 'prodotto_finito'
            ? '<span class="badge-soft badge-soft-blu">prodotto finito</span>'
            : '<span class="badge-soft badge-soft-ciano">semilavorato</span>';
    }

    /* ==============================================================
       LISTA
       ============================================================== */

    async function renderLista() {
        const ricette = await App.Api.Ricette.elencoCorrenti();
        return barraRicerca() + tabellaLista(ricette);
    }

    function barraRicerca() {
        return '<div class="mb-3">' +
            '<input type="search" class="form-control form-control-sm" style="max-width:22rem" ' +
            'id="ricercaRicette" placeholder="Cerca per codice o denominazione&hellip;">' +
        '</div>';
    }

    function tabellaLista(ricette) {
        if (!ricette.length) {
            return '<div class="card"><div class="card-body text-body-secondary">' +
                'Nessuna ricetta corrente in archivio.</div></div>';
        }

        const righe = ricette.map((r) => {
            const nomeRicerca = (r.codice + ' ' + r.denominazione).toLowerCase();
            return '<tr class="align-middle" data-ricerca="' + U.esc(nomeRicerca) + '">' +
                '<td>' + badgeTipo(r.tipo) + '</td>' +
                '<td><code>' + U.esc(r.codice) + '</code></td>' +
                '<td><a href="' + urlDettaglio(r.tipo, r.entita_id) + '">' + U.esc(r.denominazione) + '</a></td>' +
                '<td class="text-end small">v' + U.esc(r.versione) + '</td>' +
                '<td class="text-nowrap small">' + U.fmtData(r.valida_dal) + '</td>' +
                '<td class="text-end small text-body-secondary">' + U.fmtNum(r.numero_componenti) + '</td>' +
            '</tr>';
        }).join('');

        return '<div class="card">' +
            U.tabella([
                { testo: 'Tipo' }, { testo: 'Codice' }, { testo: 'Denominazione' },
                { testo: 'Versione', allineaDx: true }, { testo: 'Valida dal' },
                { testo: 'Componenti', allineaDx: true }
            ], righe) +
        '</div>';
    }

    function collegaRicerca() {
        const input = U.$('#ricercaRicette');
        if (!input) return;

        input.addEventListener('input', () => {
            const testo = input.value.trim().toLowerCase();
            U.$$('[data-ricerca]').forEach((tr) => {
                tr.classList.toggle('d-none', !(!testo || tr.dataset.ricerca.indexOf(testo) !== -1));
            });
        });
    }

    /* ==============================================================
       DETTAGLIO
       ============================================================== */

    async function renderDettaglio(tipo, id) {
        let dati;
        try {
            dati = tipo === 'prodotto_finito'
                ? await App.Api.Ricette.prodottoFinito(id)
                : await App.Api.Ricette.semilavorato(id);
        } catch (errore) {
            if (errore.status === 404) return statoNessunaRicetta(tipo, id);
            throw errore;   // errore vero: lo mostra il router (vedi router.js)
        }

        return intestazioneDettaglio(tipo, id, dati) + tabellaComponenti(dati.componenti, dati.costo_totale, dati.costo_completo);
    }

    function statoNessunaRicetta(tipo, id) {
        return '<div class="placeholder-view"><div>' +
            U.icona('ricette', 'ico-grande') +
            '<h2 class="h5 mt-3 mb-1">Nessuna ricetta corrente</h2>' +
            '<p class="mb-3 text-body-secondary" style="max-width:34rem">' +
                'Questo elemento non ha ancora una ricetta registrata, oppure l&rsquo;id indicato non esiste.</p>' +
            '<div class="d-flex gap-2 justify-content-center">' +
                '<a class="btn btn-sm btn-outline-secondary" href="' + urlAnagrafica(tipo, id) + '">' +
                    'Torna all&rsquo;anagrafica</a>' +
                '<a class="btn btn-sm btn-outline-secondary" href="' + App.Router.url('ricette') + '">' +
                    'Tutte le ricette</a>' +
            '</div>' +
        '</div></div>';
    }

    function intestazioneDettaglio(tipo, id, dati) {
        return '<div class="d-flex flex-wrap align-items-center gap-2 mb-3">' +
            badgeTipo(tipo) +
            '<span class="fw-medium">Ricetta corrente &mdash; versione ' + U.esc(dati.versione) + '</span>' +
            '<a class="small ms-auto" href="' + urlAnagrafica(tipo, id) + '">Vai all&rsquo;anagrafica</a>' +
            '<a class="small" href="' + App.Router.url('ricette') + '">Tutte le ricette</a>' +
        '</div>';
    }

    function tabellaComponenti(componenti, costoTotale, costoCompleto) {
        if (!componenti.length) {
            return '<div class="card"><div class="card-body text-body-secondary">' +
                'La ricetta non ha componenti registrati.</div></div>';
        }

        const righe = componenti.map((c) => {
            // Un componente che e' a sua volta un semilavorato apre la
            // SUA ricetta con lo stesso link urlDettaglio() della lista:
            // e' cosi' che una distinta base multi-livello si sfoglia,
            // un passo alla volta, senza una vista "albero" dedicata.
            const nome = c.tipo === 'semilavorato'
                ? '<a href="' + urlDettaglio('semilavorato', c.id) + '">' + U.esc(c.denominazione) + '</a>'
                : U.esc(c.denominazione);

            // costo_disponibile = false SOLO per componenti semilavorato
            // (vedi il commento su TCostoComponenteRicetta.CostoDisponibile
            // in uServiziRicette.pas): lo schema non censisce la resa di
            // produzione del semilavorato, quindi il backend non calcola
            // affatto un costo per quella riga - costo_unitario/costo_
            // totale sono 0 per costruzione, non un dato "che vale zero".
            // Vanno mostrati come non disponibili, mai come 0,00 EUR:
            // presentarli come importo farebbe credere che il componente
            // non abbia impatto sul costo della ricetta, quando invece
            // semplicemente non e' stato possibile calcolarlo.
            const cellaCostoUnitario = c.costo_disponibile
                ? U.fmtNum(c.costo_unitario, 2) + ' &euro;'
                : '<span class="text-body-secondary" title="Costo non disponibile: manca la resa di produzione del semilavorato">n/d</span>';
            const cellaCostoTotale = c.costo_disponibile
                ? U.fmtEuro(c.costo_totale, 2)
                : '<span class="text-body-secondary" title="Costo non disponibile: manca la resa di produzione del semilavorato">n/d</span>';

            return '<tr class="align-middle">' +
                '<td>' + badgeTipoComponente(c.tipo) + '</td>' +
                '<td>' + nome + '</td>' +
                '<td class="text-end small text-nowrap">' + U.fmtNum(c.quantita_standard, 3) + ' ' + U.esc(c.unita_misura_dose) + '</td>' +
                '<td class="text-end small text-nowrap">' + cellaCostoUnitario + '</td>' +
                '<td class="text-end small fw-medium text-nowrap">' + cellaCostoTotale + '</td>' +
            '</tr>';
        }).join('');

        // costo_completo = false quando almeno un componente e' un
        // semilavorato (vedi TCostoRicetta.CostoCompleto lato backend):
        // costoTotale in quel caso e' la somma delle SOLE righe con
        // costo_disponibile, quindi un costo PARZIALE. Va segnalato
        // esplicitamente qui invece di presentarlo come il costo reale
        // della ricetta - e' lo stesso avvertimento lasciato dal backend
        // nel commento a ComponentiToJSONArray/uControllerRicette.pas.
        // Niente icona qui: lo sprite SVG in index.html (vedi U.icona())
        // non ha un simbolo di avviso, e aggiungerne uno nuovo tocca un
        // file che Bootstrap Studio rigenera a ogni export (stessa
        // cautela gia' documentata per #tabBar in core/tabs.js e per i
        // badge allergeni in view-prodotti-finiti.js) - riuso invece
        // badge-soft, gia' definito in app.css.
        const avvisoParziale = costoCompleto === false
            ? '<span class="badge-soft badge-soft-ambra ms-2" title="Uno o pi&ugrave; componenti sono semilavorati: il loro costo non &egrave; calcolabile (manca la resa di produzione), quindi questo totale include solo le materie prime dirette.">parziale</span>'
            : '';

        return '<div class="card">' +
            U.tabella([
                { testo: 'Tipo' }, { testo: 'Componente' },
                { testo: 'Quantit&agrave;', allineaDx: true },
                { testo: 'Costo unitario', allineaDx: true },
                { testo: 'Costo', allineaDx: true }
            ], righe) +
            '<div class="card-footer d-flex justify-content-end align-items-center">' +
                '<span class="text-body-secondary small me-2">Costo totale ricetta</span>' +
                '<span class="fw-semibold">' + U.fmtEuro(costoTotale, 2) + '</span>' +
                avvisoParziale +
            '</div>' +
        '</div>';
    }

    function badgeTipoComponente(tipo) {
        return tipo === 'materia_prima'
            ? '<span class="badge-soft badge-soft-verde">materia prima</span>'
            : '<span class="badge-soft badge-soft-ciano">semilavorato</span>';
    }
})();
