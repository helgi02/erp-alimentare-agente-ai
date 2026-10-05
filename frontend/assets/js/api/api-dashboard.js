/* =====================================================================
   api/api-dashboard.js — dati aggregati della home.

   Ogni file di questa cartella espone UNA entita'/area del gestionale e
   ha sempre la stessa forma: un ramo mock e un ramo REST. La vista non
   sa quale dei due e' attivo.
   ===================================================================== */

window.App = window.App || {};
App.Api = App.Api || {};

App.Api.Dashboard = {

    /*
      Endpoint reale: GET /api/dashboard
        controllers/uControllerDashboard.pas -> TControllerDashboard
        services/uServiziDashboard.pas       -> TServizioDashboard.Riepilogo

      Restituisce in un colpo solo kpi, venditeMensili, nonConformita,
      lottiInScadenza e ordiniRecenti. Un endpoint aggregato e non
      cinque chiamate separate perche' la home e' la prima schermata che
      si apre: cinque round trip e cinque prelievi dal pool di
      connessioni per disegnare una pagina sola sarebbero spreco. Le
      singole risorse restano comunque interrogabili dai rispettivi
      controller CRUD per le altre viste.
    */
    async get() {
        if (App.Config.MOCK) {
            await App.Http.attendi(App.Config.MOCK_DELAY);
            const d = App.MockData;
            // Copia profonda: evita che una vista modificando il
            // risultato sporchi i dati mock per le chiamate successive.
            // Passa comunque dal controllo di forma, cosi' una modifica
            // ai dati mock che rompesse la struttura viene segnalata
            // subito e non solo il giorno in cui si passa ai dati veri.
            return normalizzaDashboard(JSON.parse(JSON.stringify({
                kpi: d.dashboard.kpi,
                venditeMensili: d.dashboard.venditeMensili,
                nonConformita: d.nonConformita,
                lottiInScadenza: d.lottiInScadenza,
                // Gli ordini dimostrativi sono gli stessi usati dalla
                // vista Vendite: qui servono solo i piu' recenti, col
                // totale calcolato dalle righe (ordini_vendita non ha
                // una colonna totale).
                ordiniRecenti: d.ordiniVendita.slice(0, 5).map((o) => ({
                    id: o.id,
                    numero_ordine: o.numero_ordine,
                    data_ordine: o.data_ordine,
                    cliente: o.cliente,
                    stato: o.stato,
                    totale: o.righe.reduce((s, r) => s + r.quantita * r.prezzo_unitario, 0)
                }))
            })));
        }
        return normalizzaDashboard(await App.Http.get('/api/dashboard'));
    }
};

/*
  Controllo di forma sulla risposta del backend.

  Senza questo passaggio, una chiave mancante nel JSON non si manifesta
  qui ma molto piu' avanti, dentro la vista, come "Cannot read
  properties of undefined (reading 'map')": un messaggio che non dice
  ne' quale campo manca ne' chi doveva produrlo. Verificare la forma nel
  punto in cui i dati entrano nell'applicazione costa poche righe e
  trasforma quell'errore in un'indicazione precisa.
*/
function normalizzaDashboard(risposta) {
    const attesi = ['kpi', 'venditeMensili', 'nonConformita', 'lottiInScadenza', 'ordiniRecenti'];
    const mancanti = attesi.filter((k) => risposta == null || risposta[k] === undefined);

    if (mancanti.length) {
        throw new Error(
            'La risposta di GET /api/dashboard non ha la forma attesa. ' +
            'Campi mancanti: ' + mancanti.join(', ') + '. ' +
            'Campi ricevuti: ' + (risposta ? Object.keys(risposta).join(', ') || '(nessuno)' : '(risposta vuota)') + '. ' +
            'Confronta con TServizioDashboard.Riepilogo in services/uServiziDashboard.pas.');
    }

    // Gli elenchi vuoti sono legittimi (un database senza non
    // conformita' e' una buona notizia, non un errore): si normalizzano
    // ad array vuoto perche' le viste possano ciclarci sopra sempre.
    ['venditeMensili', 'nonConformita', 'lottiInScadenza', 'ordiniRecenti'].forEach((k) => {
        if (!Array.isArray(risposta[k])) risposta[k] = [];
    });

    return risposta;
}
