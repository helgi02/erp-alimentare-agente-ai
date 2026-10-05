/* =====================================================================
   api/api-anagrafiche.js — clienti, prodotti finiti, materie prime.

   Sono le uniche risorse i cui endpoint REST esistono gia' nel backend
   (controllers/uControllerClienti.pas, uControllerMateriePrime.pas,
   uControllerFornitori.pas), tutti con lo stesso schema di rotte:
     GET    /api/<risorsa>
     GET    /api/<risorsa>/(id)
     POST   /api/<risorsa>
     PUT    /api/<risorsa>/(id)
     DELETE /api/<risorsa>/(id)
   ===================================================================== */

window.App = window.App || {};
App.Api = App.Api || {};

App.Api.Clienti = {

    async getAll() {
        if (App.Config.MOCK) {
            await App.Http.attendi(App.Config.MOCK_DELAY);
            return App.MockData.clienti.slice();
        }
        return App.Http.get('/api/clienti');
    },

    async getById(id) {
        if (App.Config.MOCK) {
            await App.Http.attendi(App.Config.MOCK_DELAY);
            return App.MockData.clienti.find((c) => c.id === Number(id)) || null;
        }
        return App.Http.get('/api/clienti/' + encodeURIComponent(id));
    }
};

// Anagrafica prodotti finiti (controllers/uControllerProdottiFiniti.pas).
// getAll serve anche alla tendina "prodotto" del filtro vendite, che deve
// lavorare per ID e non per testo — la risoluzione nome -> ID e' un
// problema del tool MCP, non della vista.
App.Api.ProdottiFiniti = {

    async getAll() {
        if (App.Config.MOCK) {
            await App.Http.attendi(App.Config.MOCK_DELAY);
            return App.MockData.prodottiFiniti.slice();
        }
        return App.Http.get('/api/prodotti-finiti');
    },

    async getById(id) {
        if (App.Config.MOCK) {
            await App.Http.attendi(App.Config.MOCK_DELAY);
            return App.MockData.prodottiFiniti.find((p) => p.id === Number(id)) || null;
        }
        return App.Http.get('/api/prodotti-finiti/' + encodeURIComponent(id));
    },

    // Allergeni dichiarati (Reg. UE 1169/2011) — mostrati nella riga
    // espansa della vista Prodotti finiti, caricati una sola volta al
    // primo click (stesso pattern di caricamento-a-domanda gia' usato
    // per il dettaglio ordine in view-vendite.js).
    async getAllergeni(id) {
        if (App.Config.MOCK) {
            await App.Http.attendi(App.Config.MOCK_DELAY);
            const codici = App.MockData.allergeniProdottiFiniti[Number(id)] || [];
            return codici.map((c) => ({ codice: c, denominazione: App.MockData.allergeni[c] || c }));
        }
        return App.Http.get('/api/prodotti-finiti/' + encodeURIComponent(id) + '/allergeni');
    }
};

// Anagrafica semilavorati (controllers/uControllerSemilavorati.pas): solo
// lettura, coerente col controller Delphi che espone solo GET per ora
// (vedi il commento in testa a quel file sul perche').
App.Api.Semilavorati = {

    async getAll() {
        if (App.Config.MOCK) {
            await App.Http.attendi(App.Config.MOCK_DELAY);
            return App.MockData.semilavorati.slice();
        }
        return App.Http.get('/api/semilavorati');
    },

    async getById(id) {
        if (App.Config.MOCK) {
            await App.Http.attendi(App.Config.MOCK_DELAY);
            return App.MockData.semilavorati.find((s) => s.id === Number(id)) || null;
        }
        return App.Http.get('/api/semilavorati/' + encodeURIComponent(id));
    },

    async getAllergeni(id) {
        if (App.Config.MOCK) {
            await App.Http.attendi(App.Config.MOCK_DELAY);
            const codici = App.MockData.allergeniSemilavorati[Number(id)] || [];
            return codici.map((c) => ({ codice: c, denominazione: App.MockData.allergeni[c] || c }));
        }
        return App.Http.get('/api/semilavorati/' + encodeURIComponent(id) + '/allergeni');
    }
};

// Anagrafica materie prime (controllers/uControllerMateriePrime.pas): a
// differenza di prodotti finiti e semilavorati il controller Delphi ha
// gia' CRUD completo (GET/POST/PUT/DELETE, vedi quel file), ma la vista
// view-materie-prime.js resta di sola lettura per ora, coerente con le
// altre due anagrafiche - nessun form di creazione/modifica lato
// frontend ancora. getAll() prima ricavava le materie prime dai lotti
// dimostrativi (nessuna vista dedicata ne aveva bisogno); ora che
// view-materie-prime.js esiste, i dati mock vengono da un'anagrafica
// vera e propria (App.MockData.materiePrime), nella stessa forma
// restituita da GET /api/materie-prime.
App.Api.MateriePrime = {

    async getAll() {
        if (App.Config.MOCK) {
            await App.Http.attendi(App.Config.MOCK_DELAY);
            return App.MockData.materiePrime.slice();
        }
        return App.Http.get('/api/materie-prime');
    },

    async getById(id) {
        if (App.Config.MOCK) {
            await App.Http.attendi(App.Config.MOCK_DELAY);
            return App.MockData.materiePrime.find((m) => m.id === Number(id)) || null;
        }
        return App.Http.get('/api/materie-prime/' + encodeURIComponent(id));
    },

    async getAllergeni(id) {
        if (App.Config.MOCK) {
            await App.Http.attendi(App.Config.MOCK_DELAY);
            const codici = App.MockData.allergeniMateriePrime[Number(id)] || [];
            return codici.map((c) => ({ codice: c, denominazione: App.MockData.allergeni[c] || c }));
        }
        return App.Http.get('/api/materie-prime/' + encodeURIComponent(id) + '/allergeni');
    }
};
