/* =====================================================================
   api/api-lotti.js — lotti di materia prima, semilavorato, prodotto
   finito.

   Tre risorse REST distinte, non una sola (vedi il commento di classe
   in services/uServiziLotti.pas lato backend per il perche' di questa
   scelta architetturale): le tre tabelle hanno colonne diverse (i lotti
   di semilavorato non hanno data_scadenza, quelli di materia prima non
   hanno ricetta_id/stabilimento_id...), quindi tre endpoint fedeli alla
   forma reale di ciascuna tabella battono un unico endpoint con un
   JSON "annacquato" per forza a un minimo comune.

     GET /api/lotti-materie-prime      [?materia_prima_id=]
     GET /api/lotti-materie-prime/(id)
     GET /api/lotti-semilavorati       [?semilavorato_id=]
     GET /api/lotti-semilavorati/(id)
     GET /api/lotti-prodotti-finiti    [?prodotto_finito_id=]
     GET /api/lotti-prodotti-finiti/(id)

   Sola lettura: nessuno dei tre scenari del tirocinio crea/modifica un
   lotto da qui (nasce da un DDT di entrata o da una produzione,
   entrambi fuori dal perimetro - vedi le voci disabilitate in
   view-da-costruire.js).

   Ogni riga porta gia' entita_codice/entita_denominazione risolti
   lato backend (JOIN sulla rispettiva anagrafica): la vista Lotti che
   unisce le tre risorse in un'unica tabella (view-lotti.js) non deve
   fare una seconda chiamata per sapere il nome della materia prima/
   semilavorato/prodotto finito di ogni lotto.
   ===================================================================== */

window.App = window.App || {};
App.Api = App.Api || {};

App.Api.LottiMateriePrime = {

    async getAll() {
        if (App.Config.MOCK) {
            await App.Http.attendi(App.Config.MOCK_DELAY);
            return App.MockData.lottiMateriePrime.slice();
        }
        return App.Http.get('/api/lotti-materie-prime');
    },

    async getById(id) {
        if (App.Config.MOCK) {
            await App.Http.attendi(App.Config.MOCK_DELAY);
            return App.MockData.lottiMateriePrime.find((l) => l.id === Number(id)) || null;
        }
        return App.Http.get('/api/lotti-materie-prime/' + encodeURIComponent(id));
    }
};

App.Api.LottiSemilavorati = {

    async getAll() {
        if (App.Config.MOCK) {
            await App.Http.attendi(App.Config.MOCK_DELAY);
            return App.MockData.lottiSemilavorati.slice();
        }
        return App.Http.get('/api/lotti-semilavorati');
    },

    async getById(id) {
        if (App.Config.MOCK) {
            await App.Http.attendi(App.Config.MOCK_DELAY);
            return App.MockData.lottiSemilavorati.find((l) => l.id === Number(id)) || null;
        }
        return App.Http.get('/api/lotti-semilavorati/' + encodeURIComponent(id));
    }
};

App.Api.LottiProdottiFiniti = {

    async getAll() {
        if (App.Config.MOCK) {
            await App.Http.attendi(App.Config.MOCK_DELAY);
            return App.MockData.lottiProdottiFiniti.slice();
        }
        return App.Http.get('/api/lotti-prodotti-finiti');
    },

    async getById(id) {
        if (App.Config.MOCK) {
            await App.Http.attendi(App.Config.MOCK_DELAY);
            return App.MockData.lottiProdottiFiniti.find((l) => l.id === Number(id)) || null;
        }
        return App.Http.get('/api/lotti-prodotti-finiti/' + encodeURIComponent(id));
    }
};
