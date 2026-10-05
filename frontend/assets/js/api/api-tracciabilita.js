/* =====================================================================
   api/api-tracciabilita.js — albero di propagazione di un lotto.

   Tre funzioni, una per tipo di lotto di origine (stessa tripartizione
   gia' vista in api-lotti.js e nel backend, vedi il commento di classe
   in services/uServiziTracciabilita.pas per il perche'):

     GET /api/tracciabilita/materie-prime/(id)
     GET /api/tracciabilita/semilavorati/(id)
     GET /api/tracciabilita/prodotti-finiti/(id)

   A differenza di api-lotti.js non c'e' un getAll(): non ha senso
   "tutti gli alberi di tracciabilita'" - questa vista si apre sempre
   per UN lotto preciso (arrivandoci da un link "Traccia" nella vista
   Lotti, o inserendo tipo+id a mano).

   Ogni funzione restituisce null se il lotto di origine non esiste
   (stesso esito del 404 lato server, tradotto qui nello stesso
   convenzione "null = non trovato" gia' usata da App.Api.LottiX.getById
   e da App.Api.MateriePrime.getById): la vista tratta un albero non
   trovato come stato normale, non come un errore di rete.
   ===================================================================== */

window.App = window.App || {};
App.Api = App.Api || {};

App.Api.Tracciabilita = {

    async alberoMateriaPrima(id) {
        if (App.Config.MOCK) {
            await App.Http.attendi(App.Config.MOCK_DELAY);
            return App.MockData.alberoTracciabilita('materia_prima', Number(id));
        }
        try {
            return await App.Http.get('/api/tracciabilita/materie-prime/' + encodeURIComponent(id));
        } catch (errore) {
            if (errore.status === 404) return null;
            throw errore;
        }
    },

    async alberoSemilavorato(id) {
        if (App.Config.MOCK) {
            await App.Http.attendi(App.Config.MOCK_DELAY);
            return App.MockData.alberoTracciabilita('semilavorato', Number(id));
        }
        try {
            return await App.Http.get('/api/tracciabilita/semilavorati/' + encodeURIComponent(id));
        } catch (errore) {
            if (errore.status === 404) return null;
            throw errore;
        }
    },

    async alberoProdottoFinito(id) {
        if (App.Config.MOCK) {
            await App.Http.attendi(App.Config.MOCK_DELAY);
            return App.MockData.alberoTracciabilita('prodotto_finito', Number(id));
        }
        try {
            return await App.Http.get('/api/tracciabilita/prodotti-finiti/' + encodeURIComponent(id));
        } catch (errore) {
            if (errore.status === 404) return null;
            throw errore;
        }
    }
};
