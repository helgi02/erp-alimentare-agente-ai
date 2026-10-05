/* =====================================================================
   api/api-ricette.js — ricette correnti di prodotti finiti e semilavorati.

   Copre i tre endpoint di controllers/uControllerRicette.pas:
     GET /api/ricette                          elenco sintetico (lista, senza costo)
     GET /api/ricette/prodotti-finiti/(id)      ricetta corrente completa
     GET /api/ricette/semilavorati/(id)         idem, per un semilavorato

   Sola lettura: la scrittura di una ricetta resta riservata allo
   scenario 3 in chat (adattamento ricetta), non a questa vista - vedi il
   commento in testa al controller Delphi.
   ===================================================================== */

window.App = window.App || {};
App.Api = App.Api || {};

App.Api.Ricette = {

    // Vista "Ricette e distinte": una riga per ogni ricetta CORRENTE,
    // di qualunque tipo di entita'.
    async elencoCorrenti() {
        if (App.Config.MOCK) {
            await App.Http.attendi(App.Config.MOCK_DELAY);
            return App.MockData.ricetteCorrenti.slice();
        }
        return App.Http.get('/api/ricette');
    },

    // Ricetta corrente completa (componenti + costo) di un prodotto
    // finito. Se il prodotto non ha ancora una ricetta, il backend
    // risponde 404: non e' un errore da mostrare in rosso, e' uno stato
    // normale (vedi la gestione in view-ricette.js, che controlla
    // errore.status).
    async prodottoFinito(id) {
        if (App.Config.MOCK) {
            await App.Http.attendi(App.Config.MOCK_DELAY);
            const dettaglio = App.MockData.ricetteDettaglio['prodotto-finito-' + id];
            if (!dettaglio) {
                const errore = new Error('Nessuna ricetta corrente per questo prodotto finito.');
                errore.status = 404;
                throw errore;
            }
            return dettaglio;
        }
        return App.Http.get('/api/ricette/prodotti-finiti/' + encodeURIComponent(id));
    },

    // Gemello del precedente per un semilavorato.
    async semilavorato(id) {
        if (App.Config.MOCK) {
            await App.Http.attendi(App.Config.MOCK_DELAY);
            const dettaglio = App.MockData.ricetteDettaglio['semilavorato-' + id];
            if (!dettaglio) {
                const errore = new Error('Nessuna ricetta corrente per questo semilavorato.');
                errore.status = 404;
                throw errore;
            }
            return dettaglio;
        }
        return App.Http.get('/api/ricette/semilavorati/' + encodeURIComponent(id));
    }
};
