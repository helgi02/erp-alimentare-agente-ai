/* =====================================================================
   views/view-prodotti-finiti.js — anagrafica prodotti finiti.

   RUOLO NEL PROGETTO
   Sostituisce il segnaposto "in costruzione" registrato da
   view-da-costruire.js. E' il punto da cui si apre la ricetta CORRENTE
   di un prodotto (CTA "Vai alla ricetta" nell'header della scheda,
   verso /ricette/prodotti-finiti/(id) — vedi view-ricette.js): la
   decisione di NON fondere anagrafica e ricetta in un'unica vista, ma
   di collegarle con un link, e' quella presa insieme a Helena (le due
   hanno cicli di vita diversi - un'anagrafica si modifica in place, una
   ricetta e' versionata).

   Nessun filtro server-side: TControllerProdottiFiniti.GetAll non ne
   accetta (l'anagrafica e' piccola, a differenza degli ordini di
   vendita). Il campo di ricerca qui e' quindi un filtro DOM sulle righe
   gia' caricate, non una nuova richiesta HTTP a ogni carattere digitato.

   DUE MODALITA' SULLA STESSA ROTTA (stesso principio di /ricette e di
   /vendite/(id) in view-ricette.js/view-vendite.js)
   /prodotti-finiti          elenco con ricerca
   /prodotti-finiti/(id)     scheda anagrafica del singolo prodotto,
                             aperta in una TAB dedicata (vedi core/tabs.js)
                             che clic dopo clic mostra il NOME del
                             prodotto, non l'id — vedi collegaDettaglio()
                             piu' sotto e il commento su
                             App.Tabs.impostaDettaglio() in tabs.js.
   Cliccare una riga dell'elenco naviga verso la seconda, esattamente
   come cliccare un <a>: non e' piu' un accordion che si apre in riga,
   perche' un accordion non da' al prodotto una URL propria ne' una tab
   propria — due cose che la vista deve invece avere, per essere
   linkabile dall'agente e riconoscibile fra piu' schede aperte.

   CAMPI VOLUTAMENTE FUORI DA QUESTA SCHEDA (decisione presa con Helena
   il 15/08/2026, vedi la conversazione del progetto)
   Prezzo/costo di vendita, categoria prodotto e peso netto NON hanno una
   colonna in anagrafiche_prodotti_finiti (vedi uModelProdottoFinito.pas):
   aggiungerli qui avrebbe richiesto una migrazione DB decisa "di
   striscio" durante un restyling, invece che a mente fredda. Il "costo"
   che SI vede in scheda e' quello della ricetta corrente (tabella
   ricette_prodotti_finiti, gia' esposta da /api/ricette/prodotti-finiti/
   (id)) — un concetto diverso e gia' disponibile senza toccare lo
   schema. La giacenza di magazzino e' rimasta fuori allo stesso modo:
   il servizio che la calcola esiste gia' (TServizioGiacenza.
   GiacenzaDisponibileProdottoFinito) ma non e' ancora chiaro SE debba
   comparire qui o altrove nel gestionale — da riprendere.
   ===================================================================== */

(function () {
    'use strict';

    const U = App.Utils;

    App.Router.registra('prodotti-finiti', {
        titolo: 'Prodotti finiti',

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
    // nome 'prodotto_finito' registrato lato backend in TRegistroViste.
    // Registra (uFrmMain.pas) - vedi core/registro-viste.js per il perche'
    // di questo secondo registro, gemello di quello Delphi. A differenza
    // di 'ricetta_prodotto_finito' (che apre la ricetta CORRENTE), questa
    // apre la scheda ANAGRAFICA: utile ad esempio dopo che l'agente ha
    // creato o modificato un'anagrafica in un futuro scenario di
    // ritiro/richiamo, quando l'utente deve vedere il record risultante
    // piu' che una ricetta.
    App.RegistroViste.registra('prodotto_finito', 'Vai all\'anagrafica',
        (parametri) => App.Router.url('prodotti-finiti', [parametri.prodotto_finito_id]));

    /* ==============================================================
       ELENCO
       ============================================================== */

    async function renderLista() {
        const prodotti = await App.Api.ProdottiFiniti.getAll();
        return barraRicerca() + tabellaProdotti(prodotti);
    }

    function barraRicerca() {
        return '<div class="mb-3">' +
            '<input type="search" class="form-control form-control-sm" style="max-width:22rem" ' +
            'id="ricercaProdottiFiniti" placeholder="Cerca per codice o denominazione&hellip;">' +
        '</div>';
    }

    function tabellaProdotti(prodotti) {
        if (!prodotti.length) {
            return '<div class="card"><div class="card-body text-body-secondary">' +
                'Nessun prodotto finito in anagrafica.</div></div>';
        }

        const righe = prodotti.map((p) => {
            const nomeRicerca = (p.codice + ' ' + p.denominazione).toLowerCase();

            return '<tr class="align-middle" style="cursor:pointer" ' +
                    'data-prodotto="' + p.id + '" data-ricerca="' + U.esc(nomeRicerca) + '">' +
                '<td><code>' + U.esc(p.codice) + '</code></td>' +
                '<td>' + U.esc(p.denominazione) +
                    (p.prodotto_finito_padre_id ? ' <span class="badge-soft badge-soft-ambra ms-1">variante</span>' : '') + '</td>' +
                '<td class="text-end small text-body-secondary">' +
                    U.fmtNum(p.giorni_scadenza_standard) + ' gg</td>' +
            '</tr>';
        }).join('');

        return '<div class="card">' +
            U.tabella([
                { testo: 'Codice' }, { testo: 'Denominazione' },
                { testo: 'Scadenza standard', allineaDx: true }
            ], righe) +
        '</div>';
    }

    function collegaRicerca() {
        const input = U.$('#ricercaProdottiFiniti');
        if (!input) return;

        input.addEventListener('input', () => {
            const testo = input.value.trim().toLowerCase();
            U.$$('[data-ricerca]').forEach((tr) => {
                tr.classList.toggle('d-none', !(!testo || tr.dataset.ricerca.indexOf(testo) !== -1));
            });
        });
    }

    // Un solo listener delegato sul contenitore (stesso pattern usato
    // altrove nell'app per non riagganciare un handler per riga): il
    // click su una riga naviga verso /prodotti-finiti/(id), che il
    // router (core/router.js) trasforma in un pushState + ridisegno -
    // e apre/mette a fuoco la relativa tab (core/tabs.js) esattamente
    // come un <a href> vero.
    function collegaApertura() {
        const contenitore = U.$('#content');
        if (!contenitore) return;

        contenitore.addEventListener('click', (e) => {
            const riga = e.target.closest('[data-prodotto]');
            if (!riga) return;

            App.Router.vaiA(App.Router.url('prodotti-finiti', [riga.dataset.prodotto]));
        });
    }

    /* ==============================================================
       SCHEDA ANAGRAFICA (dettaglio)
       ============================================================== */

    async function renderDettaglio(id) {
        let prodotto;
        try {
            prodotto = await App.Api.ProdottiFiniti.getById(id);
        } catch (errore) {
            if (errore.status === 404) return statoNonTrovato(id);
            throw errore; // errore vero: lo mostra il router (vedi router.js)
        }
        // Ramo App.Config.MOCK = true: getById() non lancia, restituisce
        // null se l'id non esiste fra i dati dimostrativi (vedi
        // api-anagrafiche.js) - stesso esito del 404 sopra, altra via.
        if (!prodotto) return statoNonTrovato(id);

        // Tre richieste indipendenti dalla scheda principale, lanciate
        // insieme: allergeni, prodotto padre (solo se questo prodotto e'
        // una variante) e la ricetta corrente (solo per leggerne il
        // costo totale - il resto della ricetta si vede cliccando la
        // CTA). Con allSettled il fallimento di una non fa sparire il
        // resto della pagina (stesso motivo di Promise.allSettled in
        // view-vendite.js). Per la ricetta, poi, un fallimento e' quasi
        // sempre un 404 "nessuna ricetta ancora" - uno stato normale,
        // non un errore da segnalare qui: la card mostra semplicemente
        // "nessuna ricetta corrente", i dettagli del perche' (404 vero o
        // guasto di rete) restano dietro la CTA se l'utente ci clicca.
        const [esitoAllergeni, esitoPadre, esitoRicetta] = await Promise.allSettled([
            App.Api.ProdottiFiniti.getAllergeni(id),
            prodotto.prodotto_finito_padre_id
                ? App.Api.ProdottiFiniti.getById(prodotto.prodotto_finito_padre_id)
                : Promise.resolve(null),
            App.Api.Ricette.prodottoFinito(id)
        ]);
        const allergeni = esitoAllergeni.status === 'fulfilled' ? esitoAllergeni.value : [];
        const padre = esitoPadre.status === 'fulfilled' ? esitoPadre.value : null;
        const ricetta = esitoRicetta.status === 'fulfilled' ? esitoRicetta.value : null;

        return schedaAnagrafica(prodotto, allergeni, padre, ricetta);
    }

    function statoNonTrovato(id) {
        return '<div class="placeholder-view"><div>' +
            U.icona('box', 'ico-grande') +
            '<h2 class="h5 mt-3 mb-1">Prodotto non trovato</h2>' +
            '<p class="mb-3 text-body-secondary" style="max-width:34rem">' +
                'Nessun prodotto finito con id ' + U.esc(id) + ' in anagrafica.</p>' +
            '<a class="btn btn-sm btn-outline-secondary" href="' + App.Router.url('prodotti-finiti') + '">' +
                'Torna all&rsquo;elenco</a>' +
        '</div></div>';
    }

    // data-denominazione sulla radice: e' cosi' che collegaDettaglio()
    // (dopoRender) recupera il nome appena caricato per etichettare la
    // tab, senza dover rifare la fetch ne' tenere uno stato di modulo -
    // vedi il commento su App.Tabs.impostaDettaglio() in core/tabs.js.
    function schedaAnagrafica(p, allergeni, padre, ricetta) {
        const badgeVariante = padre
            ? ' <a class="badge-soft badge-soft-ambra" href="' +
                App.Router.url('prodotti-finiti', [padre.id]) + '">variante di ' + U.esc(padre.denominazione) + '</a>'
            : '';

        // Pillole allergeni in stile NEUTRO (badge-soft-grigio, la stessa
        // classe gia' usata da U.badgeStato() per "annullato" - vedi
        // app.css): il rosa/rosso di prima leggeva come un avviso di
        // pericolo su ogni riga, mentre qui e' un dato anagrafico
        // costante, non un'eccezione da segnalare con urgenza. Nessuna
        // icona di categoria per ora: lo sprite SVG in index.html (vedi
        // il set #ico-* definito li') non ne ha una per allergene, e
        // aggiungerne di nuove tocca un file che Bootstrap Studio
        // rigenera a ogni export (stessa cautela gia' documentata per
        // #tabBar in core/tabs.js) - da valutare a parte, non come
        // effetto collaterale di questo restyling.
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

        return '<div data-vista-dettaglio data-denominazione="' + U.esc(p.denominazione) + '">' +

            '<a class="small text-body-secondary d-inline-block mb-2" href="' + App.Router.url('prodotti-finiti') + '">' +
                '&larr; Tutti i prodotti finiti</a>' +

            // Intestazione: nome, codice (come badge, non piu' semplice
            // <code>: e' un identificativo alla pari della denominazione,
            // non un dettaglio tecnico secondario) e le due azioni
            // principali sulla destra. "Vai alla ricetta" e' una CTA
            // primaria (btn-primary) perche', per come e' nato questo
            // gestionale, e' il punto in cui l'anagrafica si aggancia al
            // resto del flusso produttivo — non un link accessorio in
            // fondo alla riga. "Modifica" resta visivo/disabilitato:
            // manca ancora il form (nessuna UI di scrittura per ora),
            // anche se il backend supporta gia' PUT /api/prodotti-finiti/
            // (id) - vedi uControllerProdottiFiniti.pas.
            '<div class="d-flex flex-wrap align-items-center gap-2 mb-3">' +
                U.icona('box') +
                '<h2 class="h5 mb-0">' + U.esc(p.denominazione) + '</h2>' +
                '<span class="badge-soft badge-soft-grigio">' + U.esc(p.codice) + '</span>' +
                badgeVariante +
                '<div class="ms-auto d-flex gap-2">' +
                    '<button type="button" class="btn btn-sm btn-outline-secondary" disabled ' +
                        'title="Form di modifica non ancora implementato (il backend supporta gi&agrave; PUT /api/prodotti-finiti/(id)).">' +
                        'Modifica</button>' +
                    '<a class="btn btn-sm btn-primary" href="' + App.Router.url('ricette', ['prodotti-finiti', p.id]) + '">' +
                        U.icona('ricette') + ' Vai alla ricetta</a>' +
                '</div>' +
            '</div>' +

            // Griglia a 3 colonne (2 sotto lg): tutti i campi memorizzati
            // in anagrafiche_prodotti_finiti (vedi uModelProdottoFinito.
            // pas, TProdottoFinito.ToJSONObject) tranne id/codice/
            // denominazione, gia' nell'intestazione sopra. Sostituisce la
            // vecchia tabella a piena larghezza, una riga per campo: con
            // 5 campi appena diventava tutta altezza vuota e scroll,
            // mentre in griglia stanno comodi in una sola schermata.
            U.card({
                icona: 'box', titolo: 'Anagrafica',
                corpo: '<div class="row g-3">' +
                    campoGriglia('Scadenza standard', U.fmtNum(p.giorni_scadenza_standard) + ' giorni') +
                    campoGriglia('Prodotto padre', padre
                        ? '<a href="' + App.Router.url('prodotti-finiti', [padre.id]) + '">' + U.esc(padre.denominazione) + '</a>'
                        : '<span class="text-body-secondary">&mdash; prodotto radice</span>') +
                    campoGriglia('Costo ricetta corrente', costoRicettaHtml) +
                    campoGriglia('Creato il', U.fmtData(p.creato_il)) +
                    campoGriglia('Aggiornato il', U.fmtData(p.aggiornato_il)) +
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

    // Cella di griglia per un campo dell'anagrafica: etichetta piccola e
    // muta sopra, valore in evidenza sotto - stesso principio delle
    // "stat" di riepilogo() in view-vendite.js, applicato a campi
    // testuali invece che a numeri di sintesi. col-lg-4: 3 per riga sugli
    // schermi larghi, col-sm-6: 2 per riga sui medi, una sola colonna
    // sotto i 576px (il breakpoint "griglia a 2 o 3 colonne" richiesto).
    function campoGriglia(etichetta, valoreHtml) {
        return '<div class="col-sm-6 col-lg-4">' +
            '<div class="small text-body-secondary mb-1">' + etichetta + '</div>' +
            '<div class="fw-medium">' + valoreHtml + '</div>' +
        '</div>';
    }

    // Legge il nome caricato da schedaAnagrafica() (attributo
    // data-denominazione sulla radice della vista) e lo passa alla tab
    // corrente: e' l'unico punto in cui il nome del prodotto finisce
    // nell'etichetta della tab, invece del semplice "#id" che il router
    // conosce gia' al momento in cui la tab viene creata (vedi il
    // commento su App.Tabs.impostaDettaglio() in core/tabs.js).
    function collegaDettaglio(rotta) {
        const radice = U.$('[data-vista-dettaglio]');
        if (!radice || !radice.dataset.denominazione) return; // stato "non trovato": niente da etichettare

        App.Tabs.impostaDettaglio(App.Tabs.chiave(rotta), radice.dataset.denominazione);
    }
})();
