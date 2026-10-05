/* =====================================================================
   api/api-vendite.js — ordini di vendita.

   CONTRATTO REST (da implementare lato Delphi come TControllerOrdiniVendita,
   stessa convenzione di uControllerClienti / uControllerMateriePrime):

     GET /api/ordini-vendita
         ?cliente_id=   &prodotto_id=
         &data_inizio=  &data_fine=      (YYYY-MM-DD)
         &stato=        &pagina=  &per_pagina=
     ->  { pagina, per_pagina, totale_ordini, totale_fatturato,
           ordini: [ { id, numero_ordine, data_ordine, cliente_id, cliente,
                       stato, numero_righe, totale } ] }

     GET /api/ordini-vendita/(id)
     ->  { id, numero_ordine, data_ordine, cliente_id, cliente, stato, note,
           righe: [ { id, prodotto_id, prodotto, lotto, quantita,
                      unita_misura, prezzo_unitario, importo } ],
           totale }

   PERCHE' L'ELENCO NON E' UN "GetAll" COME NELLE ANAGRAFICHE
   TCliente.GetAll restituisce l'intera tabella e va benissimo: i clienti
   sono qualche centinaio. Gli ordini di vendita crescono senza limite,
   quindi filtro e paginazione devono stare NELL'endpoint, non nel
   browser. E' la stessa scelta gia' fatta per i tool MCP — filtri
   opzionali e componibili su un endpoint solo, invece di un endpoint per
   ogni combinazione — applicata qui al livello REST.

   PERCHE' NON SI RIUSA IL TOOL get_list_vendite COME API DELLA VISTA
   Il tool e' tarato su un interlocutore diverso, il modello, e ha
   comportamenti che in una schermata sarebbero sbagliati:
     - taglia il dettaglio a 100 righe (per la vista serve paginazione);
     - se il periodo manca applica un default implicito "ultimo mese"
       (nella vista il periodo deve essere visibile nei campi);
     - restituisce i candidati quando un nome e' ambiguo (nella vista
       l'ambiguita' non esiste: si sceglie da un elenco);
     - esclude sempre gli ordini annullati (nella vista sono un filtro).
   Le due strade condividono i dati e la logica di dominio, non
   l'interfaccia.

   SOLA LETTURA: nessuno dei tre scenari del tirocinio crea o modifica
   ordini di vendita, quindi POST/PUT/DELETE non servono e il controller
   corrispondente resta la meta' del lavoro.
   ===================================================================== */

window.App = window.App || {};
App.Api = App.Api || {};

App.Api.Vendite = {

    PER_PAGINA: 10,

    async elenco(filtri) {
        const f = filtri || {};

        if (App.Config.MOCK) {
            await App.Http.attendi(App.Config.MOCK_DELAY);
            return elencoMock(f);
        }

        // I filtri vuoti non finiscono nella query string: un
        // "cliente_id=" senza valore obblighera' il controller a
        // distinguere fra "assente" e "vuoto", distinzione inutile.
        const qs = new URLSearchParams();
        ['cliente_id', 'prodotto_id', 'data_inizio', 'data_fine', 'stato'].forEach((k) => {
            if (f[k]) qs.set(k, f[k]);
        });
        qs.set('pagina', f.pagina || 1);
        qs.set('per_pagina', f.per_pagina || this.PER_PAGINA);

        return App.Http.get('/api/ordini-vendita?' + qs.toString());
    },

    async dettaglio(id) {
        if (App.Config.MOCK) {
            await App.Http.attendi(App.Config.MOCK_DELAY);
            const o = App.MockData.ordiniVendita.find((x) => x.id === Number(id));
            return o ? conTotali(o) : null;
        }
        return App.Http.get('/api/ordini-vendita/' + encodeURIComponent(id));
    }
};

/* ==================================================================
   Implementazione del ramo dimostrativo.
   Riproduce in JavaScript quello che fara' la query SQL: filtro,
   ordinamento per data discendente, conteggio e taglio della pagina.
   Serve a poter costruire e provare la vista prima che il controller
   Delphi esista, senza che la vista se ne accorga.
   ================================================================== */

// Aggiunge alle righe l'importo e all'ordine il totale.
// L'importo non e' una colonna del database: e'
// quantita * prezzo_unitario, e viene calcolato una volta sola qui
// invece che in ogni punto della vista che deve mostrarlo.
function conTotali(ordine) {
    const righe = (ordine.righe || []).map((r) =>
        Object.assign({}, r, { importo: r.quantita * r.prezzo_unitario }));

    return Object.assign({}, ordine, {
        righe: righe,
        numero_righe: righe.length,
        totale: righe.reduce((s, r) => s + r.importo, 0)
    });
}

function elencoMock(f) {
    let ordini = App.MockData.ordiniVendita.map(conTotali);

    if (f.cliente_id) {
        ordini = ordini.filter((o) => o.cliente_id === Number(f.cliente_id));
    }
    if (f.prodotto_id) {
        // Un ordine entra nel risultato se ALMENO UNA delle sue righe
        // contiene il prodotto: e' l'equivalente del JOIN su
        // ordini_vendita_righe nella query reale.
        ordini = ordini.filter((o) =>
            o.righe.some((r) => r.prodotto_id === Number(f.prodotto_id)));
    }
    if (f.stato) {
        ordini = ordini.filter((o) => o.stato === f.stato);
    }
    if (f.data_inizio) {
        ordini = ordini.filter((o) => o.data_ordine >= f.data_inizio);
    }
    if (f.data_fine) {
        ordini = ordini.filter((o) => o.data_ordine <= f.data_fine);
    }

    ordini.sort((a, b) => (a.data_ordine < b.data_ordine ? 1 : -1));

    // I totali si calcolano PRIMA di tagliare la pagina.
    // E' lo stesso errore che va corretto lato Delphi in
    // TServizioVendite.EseguiQuery, dove i totali vengono accumulati
    // dentro il ciclo su una query gia' limitata a 100 righe: cosi' il
    // fatturato restituito e' quello delle prime 100 righe, non del
    // periodo richiesto.
    const totaleFatturato = ordini.reduce((s, o) => s + o.totale, 0);
    const totaleOrdini = ordini.length;

    const perPagina = Number(f.per_pagina) || App.Api.Vendite.PER_PAGINA;
    const pagina = Math.max(1, Number(f.pagina) || 1);
    const da = (pagina - 1) * perPagina;

    return {
        pagina: pagina,
        per_pagina: perPagina,
        totale_ordini: totaleOrdini,
        totale_fatturato: totaleFatturato,
        ordini: ordini.slice(da, da + perPagina)
    };
}
