/* =====================================================================
   mock-data.js — dati dimostrativi.

   Tenuti separati dal layer API per un motivo pratico: quando gli
   endpoint Delphi saranno pronti questo file si toglie dall'index e
   basta, senza rimettere le mani su api/*.js.

   I dati NON sono inventati liberamente: rispettano nomi e vincoli
   dello schema reale del progetto, cosi' che il passaggio ai dati veri
   non richieda di riscrivere le viste.

     non_conformita              codice_nc, motivo, stato_nc
                                 ('aperta'|'in_gestione'|'chiusa'), data_apertura
     lotti_materie_prime         codice_lotto, data_scadenza,
                                 quantita_disponibile NUMERIC(10,4)
     ordini_vendita              numero_ordine, data_ordine, cliente_id, stato
                                 ('confermato'|'spedito'|'consegnato'|'annullato')
     anagrafiche_prodotti_finiti codice, denominazione, giorni_scadenza_standard
   ===================================================================== */

window.App = window.App || {};

// Spedizioni del lotto di prodotto finito 342 (Sugo al basilico 320g,
// LPF-2026-0342): referenziato da tre punti diversi di tracciabilitaEstesa
// qui sotto (le due catene a monte via materia prima 844/871 e l'albero
// "prodotto finito" diretto) - una funzione condivisa invece di copiare
// lo stesso array tre volte, cosi' i tre punti di vista non possono
// disallinearsi. Stessa forma di Spedizioni() lato backend
// (services/uServiziTracciabilita.pas): un ordine confermato ma non
// spedito ha spedito:false e i tre campi di spedizione a null, non a
// stringa vuota o zero.
function SPEDIZIONI_LOTTO_342() {
    return [
        { numero_ordine: 'OV-2026-1902', data_ordine: '2026-08-11', stato_ordine: 'confermato', cliente: 'Supermercati Delta S.p.A.', quantita_ordinata: 4800, unita_misura: 'pz', spedito: false, numero_ddt: null, data_spedizione: null, quantita_spedita: null },
        { numero_ordine: 'OV-2026-1899', data_ordine: '2026-08-10', stato_ordine: 'spedito', cliente: 'Ho.Re.Ca. Distribuzione Sud', quantita_ordinata: 7200, unita_misura: 'pz', spedito: true, numero_ddt: 'DDT-2026-0755', data_spedizione: '2026-08-12', quantita_spedita: 7200 }
    ];
}

App.MockData = {

    /* ---------------------------------------------------------- DASHBOARD */
    dashboard: {
        // ATTENZIONE: questa struttura deve restare identica a quella
        // prodotta da TServizioDashboard.Riepilogo
        // (services/uServiziDashboard.pas). Se le due divergono, il sito
        // funziona con MOCK a true e si rompe con MOCK a false — che e'
        // esattamente il tipo di guasto che si scopre nel momento
        // peggiore.
        kpi: {
            ncAperte: 3,
            lottiInScadenza: 12,
            ordiniDaSpedire: 27,
            fatturatoPeriodo: 486250.40,
            // Le soglie arrivano dal backend insieme ai numeri, cosi' le
            // etichette ("entro 30 giorni") non sono cablate due volte.
            giorniScadenza: 30,
            giorniFatturato: 30
        },

        // Mese in formato 'YYYY-MM': ordinabile e indipendente dal
        // locale del server. L'etichetta leggibile la compone la vista.
        venditeMensili: [
            { mese: '2025-09', importo: 372100 }, { mese: '2025-10', importo: 401340 },
            { mese: '2025-11', importo: 438900 }, { mese: '2025-12', importo: 512470 },
            { mese: '2026-01', importo: 349800 }, { mese: '2026-02', importo: 366250 },
            { mese: '2026-03', importo: 421080 }, { mese: '2026-04', importo: 447630 },
            { mese: '2026-05', importo: 459220 }, { mese: '2026-06', importo: 478900 },
            { mese: '2026-07', importo: 495110 }, { mese: '2026-08', importo: 486250 }
        ]
    },

    /* --------------------------------------------------- NON CONFORMITA' */
    nonConformita: [
        { id: 41, codice_nc: 'NC-2026-014', motivo: 'Corpo estraneo metallico rilevato su semilavorato',            stato_nc: 'aperta',      data_apertura: '2026-08-10', lotto: 'LMP-2026-0871', lotto_tipo: 'materia prima' },
        { id: 40, codice_nc: 'NC-2026-013', motivo: 'Superamento limiti microbiologici (Listeria) su prodotto finito', stato_nc: 'in_gestione', data_apertura: '2026-08-06', lotto: 'LPF-2026-0342', lotto_tipo: 'prodotto finito' },
        { id: 39, codice_nc: 'NC-2026-012', motivo: 'Allergene non dichiarato in etichetta (frutta a guscio)',       stato_nc: 'in_gestione', data_apertura: '2026-08-01', lotto: 'LPF-2026-0329', lotto_tipo: 'prodotto finito' },
        { id: 38, codice_nc: 'NC-2026-011', motivo: 'Rottura catena del freddo durante trasporto in ingresso',       stato_nc: 'chiusa',      data_apertura: '2026-07-24', lotto: 'LMP-2026-0804', lotto_tipo: 'materia prima' }
    ],

    /* ---------------------------------------------------------- LOTTI MP */
    lottiInScadenza: [
        { id: 871, codice_lotto: 'LMP-2026-0871', materia_prima: 'Passata di pomodoro bio',    data_scadenza: '2026-08-19', giorni:  7, quantita_disponibile:  480.0000, um: 'kg' },
        { id: 866, codice_lotto: 'LMP-2026-0866', materia_prima: 'Farina di grano tenero 00',  data_scadenza: '2026-08-23', giorni: 11, quantita_disponibile: 1250.0000, um: 'kg' },
        { id: 858, codice_lotto: 'LMP-2026-0858', materia_prima: 'Olio extravergine di oliva', data_scadenza: '2026-08-28', giorni: 16, quantita_disponibile:  320.5000, um: 'l'  },
        { id: 851, codice_lotto: 'LMP-2026-0851', materia_prima: 'Mozzarella fiordilatte',     data_scadenza: '2026-09-02', giorni: 21, quantita_disponibile:   96.2500, um: 'kg' },
        { id: 844, codice_lotto: 'LMP-2026-0844', materia_prima: 'Basilico fresco',            data_scadenza: '2026-09-05', giorni: 24, quantita_disponibile:   18.0000, um: 'kg' }
    ],

    /* ---------------------------------------------------------- CLIENTI */
    clienti: [
        { id: 1, ragione_sociale: 'Supermercati Delta S.p.A.',   partita_iva: '01234567890', citta: 'Bologna' },
        { id: 2, ragione_sociale: 'Gastronomia Bianchi S.r.l.',  partita_iva: '09876543210', citta: 'Modena'  },
        { id: 3, ragione_sociale: 'Ho.Re.Ca. Distribuzione Sud', partita_iva: '05566778899', citta: 'Napoli'  },
        { id: 4, ragione_sociale: 'Panificio Aurora S.n.c.',     partita_iva: '04455667788', citta: 'Parma'   }
    ],

    /* -------------------------------------------------- PRODOTTI FINITI */
    // anagrafiche_prodotti_finiti: codice, denominazione,
    // giorni_scadenza_standard (shelf life usata per calcolare la
    // data_scadenza dei lotti prodotti).
    prodottiFiniti: [
        { id: 12, codice: 'PF-0012', denominazione: 'Sugo al basilico 320g',     giorni_scadenza_standard: 540 },
        { id: 31, codice: 'PF-0031', denominazione: 'Pasta fresca ripiena 500g', giorni_scadenza_standard:  45 },
        { id:  7, codice: 'PF-0007', denominazione: 'Pesto genovese 190g',       giorni_scadenza_standard: 365 },
        { id: 44, codice: 'PF-0044', denominazione: 'Focaccia surgelata 400g',   giorni_scadenza_standard: 270 }
    ],

    /* ------------------------------------------------------------ SEMILAVORATI
       anagrafiche_semilavorati: codice, denominazione. Id volutamente
       fuori dal range dei prodotti finiti/materie prime, per non far
       sembrare per sbaglio due entita' diverse la stessa cosa quando
       compaiono insieme (es. nei componenti di una ricetta).            */
    semilavorati: [
        { id: 101, codice: 'SL-0101', denominazione: 'Impasto per pasta fresca' },
        { id: 102, codice: 'SL-0102', denominazione: 'Pesto base' },
        { id: 103, codice: 'SL-0103', denominazione: 'Base ricotta e spinaci' }
    ],

    /* -------------------------------------------------------- MATERIE PRIME
       anagrafiche_materie_prime: codice, denominazione, creato_il,
       aggiornato_il (vedi uModelMateriaPrima.pas, TMateriaPrima.
       ToJSONObject). Nessuna colonna di prezzo/fornitore/scorta qui: chi
       la materia prima la fornisce e a quanto sta in ordini_fornitore/
       ordini_fornitore_righe, non in anagrafica - stessa logica gia'
       seguita per prodotti finiti e semilavorati (vedi i commenti in
       cima a view-prodotti-finiti.js e view-semilavorati.js).
       Id scelti apposta uguali a quelli gia' usati nei componenti di
       ricetta di ricetteDettaglio piu' sotto e in lottiInScadenza, cosi'
       le stesse materie prime restano riconoscibili in ogni vista che le
       cita, invece di sembrare per sbaglio entita' diverse.             */
    materiePrime: [
        { id:  1, codice: 'MP-0001', denominazione: 'Passata di pomodoro bio',    creato_il: '2025-01-15T09:00:00', aggiornato_il: '2025-01-15T09:00:00' },
        { id:  2, codice: 'MP-0002', denominazione: 'Farina di grano tenero 00',  creato_il: '2025-01-15T09:00:00', aggiornato_il: '2025-01-15T09:00:00' },
        { id:  3, codice: 'MP-0003', denominazione: 'Olio extravergine di oliva', creato_il: '2025-01-15T09:00:00', aggiornato_il: '2025-01-15T09:00:00' },
        { id:  4, codice: 'MP-0004', denominazione: 'Mozzarella fiordilatte',     creato_il: '2025-01-15T09:00:00', aggiornato_il: '2025-01-15T09:00:00' },
        { id:  5, codice: 'MP-0005', denominazione: 'Ricotta fresca',             creato_il: '2025-01-15T09:00:00', aggiornato_il: '2025-01-15T09:00:00' },
        { id:  6, codice: 'MP-0006', denominazione: 'Spinaci freschi',            creato_il: '2025-01-15T09:00:00', aggiornato_il: '2025-01-15T09:00:00' },
        { id:  7, codice: 'MP-0007', denominazione: 'Basilico fresco',            creato_il: '2025-01-15T09:00:00', aggiornato_il: '2025-01-15T09:00:00' },
        { id:  8, codice: 'MP-0008', denominazione: 'Pinoli',                     creato_il: '2025-01-15T09:00:00', aggiornato_il: '2025-01-15T09:00:00' },
        { id:  9, codice: 'MP-0009', denominazione: 'Grana Padano DOP grattugiato', creato_il: '2025-01-15T09:00:00', aggiornato_il: '2025-01-15T09:00:00' },
        { id: 10, codice: 'MP-0010', denominazione: 'Uova fresche categoria A',   creato_il: '2025-01-15T09:00:00', aggiornato_il: '2025-01-15T09:00:00' }
    ],

    /* ------------------------------------------------------------ LOTTI
       Stessa forma restituita da GET /api/lotti-materie-prime, GET
       /api/lotti-semilavorati e GET /api/lotti-prodotti-finiti (vedi
       services/uServiziLotti.pas: tre endpoint separati, non un unico
       /api/lotti - la SQL_ELENCO di ciascuno gia' risolve entita_codice/
       entita_denominazione via JOIN sulla rispettiva anagrafica, quindi
       anche qui il mock porta gia' quei due campi invece di un id nudo).
       Le materie prime riprendono gli stessi 5 lotti gia' usati da
       dashboard.lottiInScadenza (stessi id/codice_lotto) piu' un lotto
       sano per ciascuna delle materie prime restanti, cosi' il filtro
       "tutte" della vista Lotti mostra qualcosa anche per chi non e'
       vicino a scadere. I lotti di prodotto finito riusano gli stessi
       codice_lotto gia' citati nelle righe di ordiniVendita piu' sotto
       (LPF-2026-0342 e' lo stesso lotto sia li' sia qui): sono la stessa
       entita' di magazzino vista da due schermate diverse, non due dati
       scollegati.                                                       */
    lottiMateriePrime: [
        { id: 871, materia_prima_id: 1, entita_codice: 'MP-0001', entita_denominazione: 'Passata di pomodoro bio',    codice_lotto: 'LMP-2026-0871', data_scadenza: '2026-08-19', quantita: 600.0000,  quantita_disponibile: 480.0000, unita_misura: 'kg', ddt_entrata_riga_id: 1871, creato_il: '2026-02-10T08:30:00', aggiornato_il: '2026-08-01T10:00:00' },
        { id: 866, materia_prima_id: 2, entita_codice: 'MP-0002', entita_denominazione: 'Farina di grano tenero 00',  codice_lotto: 'LMP-2026-0866', data_scadenza: '2026-08-23', quantita: 1500.0000, quantita_disponibile: 1250.0000, unita_misura: 'kg', ddt_entrata_riga_id: 1866, creato_il: '2026-02-15T08:30:00', aggiornato_il: '2026-08-05T10:00:00' },
        { id: 858, materia_prima_id: 3, entita_codice: 'MP-0003', entita_denominazione: 'Olio extravergine di oliva', codice_lotto: 'LMP-2026-0858', data_scadenza: '2026-08-28', quantita: 400.0000,  quantita_disponibile: 320.5000, unita_misura: 'l',  ddt_entrata_riga_id: 1858, creato_il: '2026-03-01T08:30:00', aggiornato_il: '2026-08-10T10:00:00' },
        { id: 851, materia_prima_id: 4, entita_codice: 'MP-0004', entita_denominazione: 'Mozzarella fiordilatte',     codice_lotto: 'LMP-2026-0851', data_scadenza: '2026-09-02', quantita: 150.0000,  quantita_disponibile: 96.2500,  unita_misura: 'kg', ddt_entrata_riga_id: 1851, creato_il: '2026-08-15T08:30:00', aggiornato_il: '2026-08-20T10:00:00' },
        { id: 844, materia_prima_id: 7, entita_codice: 'MP-0007', entita_denominazione: 'Basilico fresco',            codice_lotto: 'LMP-2026-0844', data_scadenza: '2026-09-05', quantita: 24.0000,   quantita_disponibile: 18.0000,   unita_misura: 'kg', ddt_entrata_riga_id: 1844, creato_il: '2026-08-25T08:30:00', aggiornato_il: '2026-08-28T10:00:00' },
        { id: 880, materia_prima_id: 5, entita_codice: 'MP-0005', entita_denominazione: 'Ricotta fresca',             codice_lotto: 'LMP-2026-0880', data_scadenza: '2026-09-20', quantita: 200.0000,  quantita_disponibile: 175.0000,  unita_misura: 'kg', ddt_entrata_riga_id: 1880, creato_il: '2026-08-28T08:30:00', aggiornato_il: '2026-08-28T08:30:00' },
        { id: 881, materia_prima_id: 6, entita_codice: 'MP-0006', entita_denominazione: 'Spinaci freschi',            codice_lotto: 'LMP-2026-0881', data_scadenza: '2026-09-12', quantita: 80.0000,   quantita_disponibile: 62.0000,   unita_misura: 'kg', ddt_entrata_riga_id: 1881, creato_il: '2026-08-27T08:30:00', aggiornato_il: '2026-08-27T08:30:00' },
        { id: 882, materia_prima_id: 8, entita_codice: 'MP-0008', entita_denominazione: 'Pinoli',                     codice_lotto: 'LMP-2026-0882', data_scadenza: '2027-04-15', quantita: 60.0000,   quantita_disponibile: 45.0000,   unita_misura: 'kg', ddt_entrata_riga_id: 1882, creato_il: '2026-06-10T08:30:00', aggiornato_il: '2026-06-10T08:30:00' },
        { id: 883, materia_prima_id: 9, entita_codice: 'MP-0009', entita_denominazione: 'Grana Padano DOP grattugiato', codice_lotto: 'LMP-2026-0883', data_scadenza: '2027-01-20', quantita: 100.0000, quantita_disponibile: 88.0000,  unita_misura: 'kg', ddt_entrata_riga_id: 1883, creato_il: '2026-07-05T08:30:00', aggiornato_il: '2026-07-05T08:30:00' },
        { id: 884, materia_prima_id: 10, entita_codice: 'MP-0010', entita_denominazione: 'Uova fresche categoria A',  codice_lotto: 'LMP-2026-0884', data_scadenza: '2026-09-25', quantita: 90.0000,   quantita_disponibile: 70.0000,   unita_misura: 'kg', ddt_entrata_riga_id: 1884, creato_il: '2026-08-29T08:30:00', aggiornato_il: '2026-08-29T08:30:00' }
    ],

    /* I lotti di semilavorato non hanno data_scadenza (vedi il commento in
       uModelLottoSemilavorato.pas: il DDL non la prevede) - solo
       data_produzione. ricetta_id punta a ricetteDettaglio piu' sotto
       (stessa versione usata per produrre QUEL lotto). */
    lottiSemilavorati: [
        { id: 601, semilavorato_id: 101, entita_codice: 'SL-0101', entita_denominazione: 'Impasto per pasta fresca', codice_lotto: 'LSL-2026-0601', data_produzione: '2026-08-30', quantita: 320.0000, quantita_disponibile: 210.0000, unita_misura: 'kg', ricetta_id: 601, stabilimento_id: 1, creato_il: '2026-08-30T06:00:00', aggiornato_il: '2026-08-30T06:00:00' },
        { id: 602, semilavorato_id: 102, entita_codice: 'SL-0102', entita_denominazione: 'Pesto base',              codice_lotto: 'LSL-2026-0602', data_produzione: '2026-08-27', quantita: 90.0000,  quantita_disponibile: 54.0000,  unita_misura: 'kg', ricetta_id: 602, stabilimento_id: 1, creato_il: '2026-08-27T06:00:00', aggiornato_il: '2026-08-27T06:00:00' },
        { id: 603, semilavorato_id: 103, entita_codice: 'SL-0103', entita_denominazione: 'Base ricotta e spinaci',   codice_lotto: 'LSL-2026-0603', data_produzione: '2026-08-25', quantita: 150.0000, quantita_disponibile: 60.0000,  unita_misura: 'kg', ricetta_id: 603, stabilimento_id: 1, creato_il: '2026-08-25T06:00:00', aggiornato_il: '2026-08-25T06:00:00' }
    ],

    // codice_lotto qui appare anche nelle righe di ordiniVendita.righe[].lotto
    // piu' sotto: stesso lotto fisico, due schermate diverse.
    lottiProdottiFiniti: [
        { id: 342, prodotto_finito_id: 12, entita_codice: 'PF-0012', entita_denominazione: 'Sugo al basilico 320g',     codice_lotto: 'LPF-2026-0342', data_produzione: '2026-02-20', data_scadenza: '2027-08-13', quantita: 12000.0000, quantita_disponibile: 3600.0000, unita_misura: 'pz', ricetta_id: 501, stabilimento_id: 1, creato_il: '2026-02-20T07:00:00', aggiornato_il: '2026-08-11T07:00:00' },
        { id: 329, prodotto_finito_id: 12, entita_codice: 'PF-0012', entita_denominazione: 'Sugo al basilico 320g',     codice_lotto: 'LPF-2026-0329', data_produzione: '2026-01-10', data_scadenza: '2027-07-04', quantita: 15000.0000, quantita_disponibile: 1500.0000, unita_misura: 'pz', ricetta_id: 501, stabilimento_id: 1, creato_il: '2026-01-10T07:00:00', aggiornato_il: '2026-08-09T07:00:00' },
        { id: 322, prodotto_finito_id: 12, entita_codice: 'PF-0012', entita_denominazione: 'Sugo al basilico 320g',     codice_lotto: 'LPF-2026-0322', data_produzione: '2025-12-01', data_scadenza: '2027-05-25', quantita: 18000.0000, quantita_disponibile: 900.0000,  unita_misura: 'pz', ricetta_id: 501, stabilimento_id: 1, creato_il: '2025-12-01T07:00:00', aggiornato_il: '2026-07-30T07:00:00' },
        { id: 351, prodotto_finito_id: 31, entita_codice: 'PF-0031', entita_denominazione: 'Pasta fresca ripiena 500g', codice_lotto: 'LPF-2026-0351', data_produzione: '2026-08-20', data_scadenza: '2026-10-04', quantita: 2500.0000,  quantita_disponibile: 580.0000,  unita_misura: 'pz', ricetta_id: 502, stabilimento_id: 1, creato_il: '2026-08-20T07:00:00', aggiornato_il: '2026-08-11T07:00:00' },
        { id: 344, prodotto_finito_id: 31, entita_codice: 'PF-0031', entita_denominazione: 'Pasta fresca ripiena 500g', codice_lotto: 'LPF-2026-0344', data_produzione: '2026-08-05', data_scadenza: '2026-09-19', quantita: 2100.0000,  quantita_disponibile: 300.0000,  unita_misura: 'pz', ricetta_id: 502, stabilimento_id: 1, creato_il: '2026-08-05T07:00:00', aggiornato_il: '2026-08-08T07:00:00' },
        { id: 338, prodotto_finito_id:  7, entita_codice: 'PF-0007', entita_denominazione: 'Pesto genovese 190g',       codice_lotto: 'LPF-2026-0338', data_produzione: '2026-03-01', data_scadenza: '2027-03-01', quantita: 5200.0000,  quantita_disponibile: 1400.0000, unita_misura: 'pz', ricetta_id: 503, stabilimento_id: 1, creato_il: '2026-03-01T07:00:00', aggiornato_il: '2026-08-11T07:00:00' },
        { id: 331, prodotto_finito_id:  7, entita_codice: 'PF-0007', entita_denominazione: 'Pesto genovese 190g',       codice_lotto: 'LPF-2026-0331', data_produzione: '2026-02-01', data_scadenza: '2027-02-01', quantita: 6000.0000,  quantita_disponibile: 700.0000,  unita_misura: 'pz', ricetta_id: 503, stabilimento_id: 1, creato_il: '2026-02-01T07:00:00', aggiornato_il: '2026-08-06T07:00:00' },
        { id: 347, prodotto_finito_id: 44, entita_codice: 'PF-0044', entita_denominazione: 'Focaccia surgelata 400g',   codice_lotto: 'LPF-2026-0347', data_produzione: '2026-06-01', data_scadenza: '2027-02-26', quantita: 4200.0000,  quantita_disponibile: 1100.0000, unita_misura: 'pz', ricetta_id: 0,   stabilimento_id: 1, creato_il: '2026-06-01T07:00:00', aggiornato_il: '2026-08-10T07:00:00' },
        { id: 340, prodotto_finito_id: 44, entita_codice: 'PF-0044', entita_denominazione: 'Focaccia surgelata 400g',   codice_lotto: 'LPF-2026-0340', data_produzione: '2026-05-01', data_scadenza: '2027-01-26', quantita: 3800.0000,  quantita_disponibile: 900.0000,  unita_misura: 'pz', ricetta_id: 0,   stabilimento_id: 1, creato_il: '2026-05-01T07:00:00', aggiornato_il: '2026-08-09T07:00:00' },
        { id: 335, prodotto_finito_id: 44, entita_codice: 'PF-0044', entita_denominazione: 'Focaccia surgelata 400g',   codice_lotto: 'LPF-2026-0335', data_produzione: '2026-04-10', data_scadenza: '2027-01-05', quantita: 4500.0000,  quantita_disponibile: 4100.0000, unita_misura: 'pz', ricetta_id: 0,   stabilimento_id: 1, creato_il: '2026-04-10T07:00:00', aggiornato_il: '2026-07-22T07:00:00' }
    ],

    /* ------------------------------------------------------ TRACCIABILITA'
       Alberi di propagazione pre-calcolati per un sottoinsieme di lotti
       (gli stessi gia' citati sopra in lottiMateriePrime/Semilavorati/
       ProdottiFiniti e in ordiniVendita piu' sotto - stessi lotti fisici,
       vista diversa), nella stessa forma restituita da GET
       /api/tracciabilita/<tipo>/(id) - vedi services/uServiziTracciabilita.pas.
       Chiave: '<tipo>-<id>', stessa convenzione di ricetteDettaglio.

       Non serve un albero per OGNI lotto demo: un lotto senza voce qui
       (ma comunque esistente in lottiMateriePrime/Semilavorati/
       ProdottiFiniti) si comporta come un lotto reale senza ancora
       nessuna propagazione - vedi alberoTracciabilita() piu' in basso,
       che restituisce semilavorati_coinvolti/prodotti_finiti_raggiunti
       vuoti invece di inventare un albero.

       Due catene dimostrative:
       - materia prima 844 (Basilico fresco) -> semilavorato 602 (Pesto
         base, consumo diretto) -> prodotto finito 342 (Sugo al basilico,
         raggiunto attraverso il semilavorato: consumato_direttamente
         false) -> spedizioni miste (un ordine spedito, uno solo
         confermato) sullo stesso lotto 342, cosi' la vista mostra
         entrambi gli stati "spedito"/"non spedito" fianco a fianco.
       - materia prima 871 (Passata di pomodoro) -> prodotto finito 342
         DIRETTAMENTE (nessun semilavorato intermedio): stesso lotto di
         arrivo della prima catena, ma con consumato_direttamente true,
         per mostrare la differenza fra le due vie di risalita previste
         da TServizioTracciabilita.AlberoMateriaPrima.                    */
    tracciabilitaEstesa: {
        'materia_prima-844': {
            semilavorati_coinvolti: [
                Object.assign({ consumato_direttamente: true, quantita_consumata: 9.6000 },
                    { id: 602, semilavorato_id: 102, entita_codice: 'SL-0102', entita_denominazione: 'Pesto base', codice_lotto: 'LSL-2026-0602', data_produzione: '2026-08-27', quantita: 90.0000, quantita_disponibile: 54.0000, unita_misura: 'kg', ricetta_id: 602, stabilimento_id: 1, creato_il: '2026-08-27T06:00:00', aggiornato_il: '2026-08-27T06:00:00' })
            ],
            prodotti_finiti_raggiunti: [
                Object.assign({ consumato_direttamente: false, quantita_consumata: 108.0000, spedizioni: SPEDIZIONI_LOTTO_342() },
                    { id: 342, prodotto_finito_id: 12, entita_codice: 'PF-0012', entita_denominazione: 'Sugo al basilico 320g', codice_lotto: 'LPF-2026-0342', data_produzione: '2026-02-20', data_scadenza: '2027-08-13', quantita: 12000.0000, quantita_disponibile: 3600.0000, unita_misura: 'pz', ricetta_id: 501, stabilimento_id: 1, creato_il: '2026-02-20T07:00:00', aggiornato_il: '2026-08-11T07:00:00' })
            ]
        },
        'materia_prima-871': {
            semilavorati_coinvolti: [],
            prodotti_finiti_raggiunti: [
                Object.assign({ consumato_direttamente: true, quantita_consumata: 792.0000, spedizioni: SPEDIZIONI_LOTTO_342() },
                    { id: 342, prodotto_finito_id: 12, entita_codice: 'PF-0012', entita_denominazione: 'Sugo al basilico 320g', codice_lotto: 'LPF-2026-0342', data_produzione: '2026-02-20', data_scadenza: '2027-08-13', quantita: 12000.0000, quantita_disponibile: 3600.0000, unita_misura: 'pz', ricetta_id: 501, stabilimento_id: 1, creato_il: '2026-02-20T07:00:00', aggiornato_il: '2026-08-11T07:00:00' })
            ]
        },
        'semilavorato-602': {
            semilavorati_coinvolti: [],
            prodotti_finiti_raggiunti: [
                Object.assign({ consumato_direttamente: true, quantita_consumata: 108.0000, spedizioni: SPEDIZIONI_LOTTO_342() },
                    { id: 342, prodotto_finito_id: 12, entita_codice: 'PF-0012', entita_denominazione: 'Sugo al basilico 320g', codice_lotto: 'LPF-2026-0342', data_produzione: '2026-02-20', data_scadenza: '2027-08-13', quantita: 12000.0000, quantita_disponibile: 3600.0000, unita_misura: 'pz', ricetta_id: 501, stabilimento_id: 1, creato_il: '2026-02-20T07:00:00', aggiornato_il: '2026-08-11T07:00:00' })
            ]
        },
        'prodotto_finito-342': { spedizioni: SPEDIZIONI_LOTTO_342() },
        'prodotto_finito-351': { spedizioni: [
            { numero_ordine: 'OV-2026-1901', data_ordine: '2026-08-11', stato_ordine: 'confermato', cliente: 'Gastronomia Bianchi S.r.l.', quantita_ordinata: 470, unita_misura: 'pz', spedito: false, numero_ddt: null, data_spedizione: null, quantita_spedita: null },
            { numero_ordine: 'OV-2026-1896', data_ordine: '2026-08-09', stato_ordine: 'consegnato', cliente: 'Supermercati Delta S.p.A.', quantita_ordinata: 1450, unita_misura: 'pz', spedito: true, numero_ddt: 'DDT-2026-0741', data_spedizione: '2026-08-10', quantita_spedita: 1450 }
        ] }
    },

    /* -------------------------------------------------------- ALLERGENI
       Catalogo minimo (sottoinsieme dei 14 codici del Reg. UE 1169/2011
       gia' usati da uRicetteToolProvider.pas), piu' due mappe entita' ->
       elenco codici. Non e' l'intera tabella allergeni del DB: solo cio'
       che serve a mostrare qualcosa di plausibile nella riga espansa
       delle viste Prodotti finiti e Semilavorati.                       */
    allergeni: {
        GLUT: 'Glutine', LAT: 'Latte e derivati', UOV: 'Uova',
        FRSC: 'Frutta a guscio', SOLF: 'Anidride solforosa e solfiti'
    },
    allergeniProdottiFiniti: {
        12: ['SOLF'], 31: ['GLUT', 'UOV', 'LAT'], 7: ['FRSC', 'LAT'], 44: ['GLUT']
    },
    allergeniSemilavorati: {
        101: ['GLUT', 'UOV'], 102: ['FRSC', 'LAT'], 103: ['LAT']
    },
    allergeniMateriePrime: {
        2: ['GLUT'], 4: ['LAT'], 5: ['LAT'], 9: ['LAT'], 10: ['UOV']
    },

    /* ------------------------------------------------------------ RICETTE
       Stessa forma restituita da GET /api/ricette (elenco) e da GET
       /api/ricette/prodotti-finiti|semilavorati/(id) (dettaglio) - vedi
       controllers/uControllerRicette.pas. Il prodotto finito 44
       (Focaccia surgelata) resta SENZA ricetta di proposito: e' cosi'
       che si vede, anche in MOCK, lo stato "nessuna ricetta ancora"
       gestito da view-ricette.js via errore.status === 404.             */
    ricetteCorrenti: [
        { tipo: 'prodotto_finito', entita_id: 12, codice: 'PF-0012', denominazione: 'Sugo al basilico 320g',
          ricetta_id: 501, versione: 2, valida_dal: '2026-03-01', creato_da: 'M. Rossi', note: '', numero_componenti: 3 },
        { tipo: 'prodotto_finito', entita_id: 31, codice: 'PF-0031', denominazione: 'Pasta fresca ripiena 500g',
          ricetta_id: 502, versione: 1, valida_dal: '2025-11-15', creato_da: 'M. Rossi', note: '', numero_componenti: 2 },
        { tipo: 'prodotto_finito', entita_id: 7, codice: 'PF-0007', denominazione: 'Pesto genovese 190g',
          ricetta_id: 503, versione: 3, valida_dal: '2026-05-10', creato_da: 'L. Verdi',
          note: 'Ricetta rivista dopo audit HACCP', numero_componenti: 4 },
        { tipo: 'semilavorato', entita_id: 101, codice: 'SL-0101', denominazione: 'Impasto per pasta fresca',
          ricetta_id: 601, versione: 1, valida_dal: '2025-10-01', creato_da: 'M. Rossi', note: '', numero_componenti: 2 },
        { tipo: 'semilavorato', entita_id: 102, codice: 'SL-0102', denominazione: 'Pesto base',
          ricetta_id: 602, versione: 2, valida_dal: '2026-04-20', creato_da: 'L. Verdi', note: '', numero_componenti: 3 },
        { tipo: 'semilavorato', entita_id: 103, codice: 'SL-0103', denominazione: 'Base ricotta e spinaci',
          ricetta_id: 603, versione: 1, valida_dal: '2025-10-05', creato_da: 'M. Rossi', note: '', numero_componenti: 2 }
    ],

    // Chiave: 'prodotto-finito-<id>' o 'semilavorato-<id>' — stessa
    // convenzione usata da App.Api.Ricette per leggere questa mappa.
    ricetteDettaglio: {
        'prodotto-finito-12': {
            prodotto_finito_id: 12, ricetta_id: 501, versione: 2, costo_totale: 0.4997, componenti: [
                { tipo: 'materia_prima', id: 1, denominazione: 'Passata di pomodoro bio', quantita_standard: 0.220, unita_misura_dose: 'kg', costo_unitario: 1.35, costo_totale: 0.297 },
                { tipo: 'semilavorato', id: 102, denominazione: 'Pesto base', quantita_standard: 0.03, unita_misura_dose: 'kg', costo_unitario: 1.59, costo_totale: 0.0477 },
                { tipo: 'materia_prima', id: 3, denominazione: 'Olio extravergine di oliva', quantita_standard: 0.025, unita_misura_dose: 'l', costo_unitario: 6.20, costo_totale: 0.155 }
            ]
        },
        'prodotto-finito-31': {
            prodotto_finito_id: 31, ricetta_id: 502, versione: 1, costo_totale: 0.746, componenti: [
                { tipo: 'semilavorato', id: 101, denominazione: 'Impasto per pasta fresca', quantita_standard: 0.320, unita_misura_dose: 'kg', costo_unitario: 1.15, costo_totale: 0.368 },
                { tipo: 'semilavorato', id: 103, denominazione: 'Base ricotta e spinaci', quantita_standard: 0.150, unita_misura_dose: 'kg', costo_unitario: 2.52, costo_totale: 0.378 }
            ]
        },
        'prodotto-finito-7': {
            prodotto_finito_id: 7, ricetta_id: 503, versione: 3, costo_totale: 2.942, componenti: [
                { tipo: 'materia_prima', id: 7, denominazione: 'Basilico fresco', quantita_standard: 0.120, unita_misura_dose: 'kg', costo_unitario: 9.50, costo_totale: 1.14 },
                { tipo: 'materia_prima', id: 8, denominazione: 'Pinoli', quantita_standard: 0.040, unita_misura_dose: 'kg', costo_unitario: 22.00, costo_totale: 0.88 },
                { tipo: 'materia_prima', id: 3, denominazione: 'Olio extravergine di oliva', quantita_standard: 0.060, unita_misura_dose: 'l', costo_unitario: 6.20, costo_totale: 0.372 },
                { tipo: 'materia_prima', id: 9, denominazione: 'Grana Padano DOP grattugiato', quantita_standard: 0.050, unita_misura_dose: 'kg', costo_unitario: 11.00, costo_totale: 0.55 }
            ]
        },
        'semilavorato-101': {
            semilavorato_id: 101, ricetta_id: 601, versione: 1, costo_totale: 1.15, componenti: [
                { tipo: 'materia_prima', id: 2, denominazione: 'Farina di grano tenero 00', quantita_standard: 0.600, unita_misura_dose: 'kg', costo_unitario: 0.85, costo_totale: 0.51 },
                { tipo: 'materia_prima', id: 10, denominazione: 'Uova fresche categoria A', quantita_standard: 0.200, unita_misura_dose: 'kg', costo_unitario: 3.20, costo_totale: 0.64 }
            ]
        },
        'semilavorato-102': {
            semilavorato_id: 102, ricetta_id: 602, versione: 2, costo_totale: 1.59, componenti: [
                { tipo: 'materia_prima', id: 7, denominazione: 'Basilico fresco', quantita_standard: 0.100, unita_misura_dose: 'kg', costo_unitario: 9.50, costo_totale: 0.95 },
                { tipo: 'materia_prima', id: 3, denominazione: 'Olio extravergine di oliva', quantita_standard: 0.050, unita_misura_dose: 'l', costo_unitario: 6.20, costo_totale: 0.31 },
                { tipo: 'materia_prima', id: 9, denominazione: 'Grana Padano DOP grattugiato', quantita_standard: 0.030, unita_misura_dose: 'kg', costo_unitario: 11.00, costo_totale: 0.33 }
            ]
        },
        'semilavorato-103': {
            semilavorato_id: 103, ricetta_id: 603, versione: 1, costo_totale: 2.52, componenti: [
                { tipo: 'materia_prima', id: 5, denominazione: 'Ricotta fresca', quantita_standard: 0.400, unita_misura_dose: 'kg', costo_unitario: 4.80, costo_totale: 1.92 },
                { tipo: 'materia_prima', id: 6, denominazione: 'Spinaci freschi', quantita_standard: 0.300, unita_misura_dose: 'kg', costo_unitario: 2.00, costo_totale: 0.60 }
            ]
        }
    },

    /* ------------------------------------------------------------ VENDITE
       Ordini di vendita con le relative righe, nella stessa forma
       restituita da GET /api/ordini-vendita/(id). Il totale di testata
       NON e' un campo del database (ordini_vendita non ha una colonna
       totale): si calcola come somma di quantita * prezzo_unitario sulle
       righe. Qui e' scritto esplicitamente solo per comodita' di
       lettura, ma le viste lo ricalcolano dalle righe quando ci sono,
       cosi' un'incoerenza nei dati dimostrativi salta all'occhio invece
       di restare nascosta.                                              */
    ordiniVendita: [
        { id: 1902, numero_ordine: 'OV-2026-1902', data_ordine: '2026-08-11', cliente_id: 1, cliente: 'Supermercati Delta S.p.A.',   stato: 'confermato', note: '', righe: [
            { id: 1, prodotto_id: 12, prodotto: 'Sugo al basilico 320g',     lotto: 'LPF-2026-0342', quantita: 4800, unita_misura: 'pz', prezzo_unitario: 2.15 },
            { id: 2, prodotto_id:  7, prodotto: 'Pesto genovese 190g',       lotto: 'LPF-2026-0338', quantita: 2400, unita_misura: 'pz', prezzo_unitario: 3.40 }
        ]},
        { id: 1901, numero_ordine: 'OV-2026-1901', data_ordine: '2026-08-11', cliente_id: 2, cliente: 'Gastronomia Bianchi S.r.l.',  stato: 'confermato', note: 'Consegna entro venerdì', righe: [
            { id: 3, prodotto_id: 31, prodotto: 'Pasta fresca ripiena 500g', lotto: 'LPF-2026-0351', quantita:  470, unita_misura: 'pz', prezzo_unitario: 6.90 }
        ]},
        { id: 1899, numero_ordine: 'OV-2026-1899', data_ordine: '2026-08-10', cliente_id: 3, cliente: 'Ho.Re.Ca. Distribuzione Sud', stato: 'spedito', note: '', righe: [
            { id: 4, prodotto_id: 12, prodotto: 'Sugo al basilico 320g',     lotto: 'LPF-2026-0342', quantita: 7200, unita_misura: 'pz', prezzo_unitario: 2.05 },
            { id: 5, prodotto_id: 44, prodotto: 'Focaccia surgelata 400g',   lotto: 'LPF-2026-0347', quantita: 3100, unita_misura: 'pz', prezzo_unitario: 4.25 }
        ]},
        { id: 1897, numero_ordine: 'OV-2026-1897', data_ordine: '2026-08-09', cliente_id: 2, cliente: 'Gastronomia Bianchi S.r.l.',  stato: 'spedito', note: '', righe: [
            { id: 6, prodotto_id:  7, prodotto: 'Pesto genovese 190g',       lotto: 'LPF-2026-0338', quantita:  860, unita_misura: 'pz', prezzo_unitario: 3.55 }
        ]},
        { id: 1896, numero_ordine: 'OV-2026-1896', data_ordine: '2026-08-09', cliente_id: 1, cliente: 'Supermercati Delta S.p.A.',   stato: 'consegnato', note: '', righe: [
            { id: 7, prodotto_id: 12, prodotto: 'Sugo al basilico 320g',     lotto: 'LPF-2026-0329', quantita: 9600, unita_misura: 'pz', prezzo_unitario: 2.15 },
            { id: 8, prodotto_id: 31, prodotto: 'Pasta fresca ripiena 500g', lotto: 'LPF-2026-0351', quantita: 1450, unita_misura: 'pz', prezzo_unitario: 6.75 },
            { id: 9, prodotto_id: 44, prodotto: 'Focaccia surgelata 400g',   lotto: 'LPF-2026-0347', quantita: 2300, unita_misura: 'pz', prezzo_unitario: 4.10 }
        ]},
        { id: 1894, numero_ordine: 'OV-2026-1894', data_ordine: '2026-08-08', cliente_id: 4, cliente: 'Panificio Aurora S.n.c.',     stato: 'consegnato', note: '', righe: [
            { id: 10, prodotto_id: 44, prodotto: 'Focaccia surgelata 400g',  lotto: 'LPF-2026-0340', quantita:  520, unita_misura: 'pz', prezzo_unitario: 4.10 }
        ]},
        { id: 1891, numero_ordine: 'OV-2026-1891', data_ordine: '2026-08-06', cliente_id: 1, cliente: 'Supermercati Delta S.p.A.',   stato: 'consegnato', note: '', righe: [
            { id: 11, prodotto_id:  7, prodotto: 'Pesto genovese 190g',      lotto: 'LPF-2026-0331', quantita: 5400, unita_misura: 'pz', prezzo_unitario: 3.30 }
        ]},
        { id: 1888, numero_ordine: 'OV-2026-1888', data_ordine: '2026-08-04', cliente_id: 3, cliente: 'Ho.Re.Ca. Distribuzione Sud', stato: 'consegnato', note: '', righe: [
            { id: 12, prodotto_id: 31, prodotto: 'Pasta fresca ripiena 500g', lotto: 'LPF-2026-0344', quantita: 2100, unita_misura: 'pz', prezzo_unitario: 6.60 },
            { id: 13, prodotto_id: 12, prodotto: 'Sugo al basilico 320g',     lotto: 'LPF-2026-0329', quantita: 3300, unita_misura: 'pz', prezzo_unitario: 2.05 }
        ]},
        { id: 1885, numero_ordine: 'OV-2026-1885', data_ordine: '2026-08-01', cliente_id: 2, cliente: 'Gastronomia Bianchi S.r.l.',  stato: 'consegnato', note: '', righe: [
            { id: 14, prodotto_id: 44, prodotto: 'Focaccia surgelata 400g',  lotto: 'LPF-2026-0340', quantita:  380, unita_misura: 'pz', prezzo_unitario: 4.30 }
        ]},
        { id: 1882, numero_ordine: 'OV-2026-1882', data_ordine: '2026-07-30', cliente_id: 1, cliente: 'Supermercati Delta S.p.A.',   stato: 'consegnato', note: '', righe: [
            { id: 15, prodotto_id: 12, prodotto: 'Sugo al basilico 320g',    lotto: 'LPF-2026-0322', quantita: 8700, unita_misura: 'pz', prezzo_unitario: 2.10 },
            { id: 16, prodotto_id:  7, prodotto: 'Pesto genovese 190g',      lotto: 'LPF-2026-0331', quantita: 3900, unita_misura: 'pz', prezzo_unitario: 3.30 }
        ]},
        { id: 1879, numero_ordine: 'OV-2026-1879', data_ordine: '2026-07-28', cliente_id: 4, cliente: 'Panificio Aurora S.n.c.',     stato: 'annullato', note: 'Annullato su richiesta del cliente', righe: [
            { id: 17, prodotto_id: 44, prodotto: 'Focaccia surgelata 400g',  lotto: '', quantita: 600, unita_misura: 'pz', prezzo_unitario: 4.10 }
        ]},
        { id: 1876, numero_ordine: 'OV-2026-1876', data_ordine: '2026-07-25', cliente_id: 3, cliente: 'Ho.Re.Ca. Distribuzione Sud', stato: 'consegnato', note: '', righe: [
            { id: 18, prodotto_id: 31, prodotto: 'Pasta fresca ripiena 500g', lotto: 'LPF-2026-0344', quantita: 1800, unita_misura: 'pz', prezzo_unitario: 6.60 }
        ]},
        { id: 1873, numero_ordine: 'OV-2026-1873', data_ordine: '2026-07-22', cliente_id: 1, cliente: 'Supermercati Delta S.p.A.',   stato: 'consegnato', note: '', righe: [
            { id: 19, prodotto_id: 44, prodotto: 'Focaccia surgelata 400g',  lotto: 'LPF-2026-0335', quantita: 4100, unita_misura: 'pz', prezzo_unitario: 4.15 }
        ]},
        { id: 1870, numero_ordine: 'OV-2026-1870', data_ordine: '2026-07-18', cliente_id: 2, cliente: 'Gastronomia Bianchi S.r.l.',  stato: 'consegnato', note: '', righe: [
            { id: 20, prodotto_id: 12, prodotto: 'Sugo al basilico 320g',    lotto: 'LPF-2026-0322', quantita:  940, unita_misura: 'pz', prezzo_unitario: 2.25 }
        ]}
    ]
};

// ---------------------------------------------------------------------
// alberoTracciabilita(tipo, id) — equivalente in mock di una chiamata a
// GET /api/tracciabilita/<tipo>/(id): usata dai tre metodi di
// App.Api.Tracciabilita (assets/js/api/api-tracciabilita.js) quando
// App.Config.MOCK e' true.
//
// tipo: 'materia_prima' | 'semilavorato' | 'prodotto_finito'.
//
// Restituisce null se il lotto di origine non esiste in anagrafica
// (stesso "nil = non trovato" del servizio Delphi), altrimenti l'albero
// completo: lotto_origine preso dal rispettivo elenco lottiX (cosi'
// resta identico a quello che la vista Lotti mostra per lo stesso lotto,
// niente doppioni), arricchito con la propagazione precalcolata in
// tracciabilitaEstesa quando c'e' - vuota altrimenti, che e' lo stato
// reale per un lotto non ancora coinvolto in nessuna produzione a valle.
App.MockData.alberoTracciabilita = function (tipo, id) {
    const MAPPA_ELENCO = {
        materia_prima: this.lottiMateriePrime,
        semilavorato: this.lottiSemilavorati,
        prodotto_finito: this.lottiProdottiFiniti
    };

    const elenco = MAPPA_ELENCO[tipo];
    const origine = elenco && elenco.find((l) => l.id === id);
    if (!origine) return null;

    const chiave = tipo + '-' + id;
    const estesa = this.tracciabilitaEstesa[chiave];

    if (tipo === 'prodotto_finito') {
        return {
            lotto_origine: origine,
            spedizioni: (estesa && estesa.spedizioni) || []
        };
    }

    return {
        lotto_origine: origine,
        semilavorati_coinvolti: (estesa && estesa.semilavorati_coinvolti) || [],
        prodotti_finiti_raggiunti: (estesa && estesa.prodotti_finiti_raggiunti) || []
    };
};
