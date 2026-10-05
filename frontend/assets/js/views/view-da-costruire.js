/* =====================================================================
   views/view-da-costruire.js — segnaposto delle viste non ancora fatte.

   Registrate fin d'ora perche' la navigazione funzioni per intero:
   meglio una pagina che dichiara cosa conterra' di un link che non fa
   niente. Ogni volta che una vista viene realizzata davvero, si crea il
   suo file views/view-<nome>.js e si toglie la riga corrispondente da
   qui: la registrazione nel router e' la stessa, cambia solo chi la fa.
   ===================================================================== */

(function () {
    'use strict';

    const DA_COSTRUIRE = [
        {
            rotta: 'non-conformita',
            titolo: 'Non conformit&agrave;',
            descrizione:
                'Elenco delle NC con stato, lotti coinvolti e documenti di compliance generati (Scheda di Notifica ' +
                'OSA, Modello di Richiamo al Consumatore), scaricabili dalla cartella <code>/export</code> servita ' +
                'dal backend.'
        },
        // Sezioni presenti in un gestionale alimentare reale ma fuori dal
        // perimetro del tirocinio. Nella sidebar hanno lo stesso aspetto
        // di tutte le altre: distinguerle graficamente non aggiungeva
        // nulla e rendeva il menu meno credibile come prodotto. Il
        // confine dello scope resta dichiarato, ma qui dentro.
        { rotta: 'ordini-fornitori', titolo: 'Ordini fornitori',    descrizione: 'Ordini di acquisto verso i fornitori e relative righe.' },
        { rotta: 'ddt',              titolo: 'DDT entrata / uscita', descrizione: 'Documenti di trasporto in ingresso e in uscita: sono l\'origine dei lotti di materia prima e il collegamento fra ordini di vendita e clienti raggiunti.' },
        { rotta: 'produzione',       titolo: 'Produzione',           descrizione: 'Registrazione delle produzioni e dei consumi di lotto, cio&egrave; le catene che la tracciabilit&agrave; risale a ritroso.' },
        { rotta: 'fatturazione',     titolo: 'Fatturazione',         descrizione: 'Emissione e gestione delle fatture di vendita.' },
        { rotta: 'utenti',           titolo: 'Utenti e permessi',    descrizione: 'Gestione degli utenti del gestionale e dei relativi permessi.' },

        { rotta: 'clienti',         titolo: 'Clienti',         descrizione: 'Anagrafica clienti. Endpoint REST gi&agrave; disponibile: <code>GET /api/clienti</code>.' }
    ];

    DA_COSTRUIRE.forEach((v) => {
        App.Router.registra(v.rotta, {
            titolo: v.titolo,
            async render() {
                return '<div class="card"><div class="card-body">' +
                        '<span class="badge text-bg-warning mb-2">In costruzione</span>' +
                        '<p class="mb-0" style="max-width:46rem">' + v.descrizione + '</p>' +
                    '</div></div>';
            }
        });
    });
})();
