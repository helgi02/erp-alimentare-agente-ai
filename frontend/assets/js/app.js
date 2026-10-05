/* =====================================================================
   app.js — punto di ingresso.

   Volutamente cortissimo: qui non c'e' logica, solo l'ordine di avvio.
   Tutto il resto vive nei file dedicati (vedi l'elenco degli script in
   fondo a index.html).

   L'ordine conta:
     1. lo stato UI va ripristinato PRIMA di disegnare qualsiasi cosa,
        altrimenti si vede la sidebar aprirsi e richiudersi al caricamento;
     2. la shell aggancia i comandi fissi;
     3. la chat prepara il drawer (le viste possono gia' contenere
        pulsanti che la richiamano);
     4. le tab creano la propria barra (subito dopo la topbar, vedi
        core/tabs.js) e ricaricano l'elenco salvato, PRIMA che il router
        cominci a navigare: la prima chiamata a naviga() deve gia'
        trovare la barra pronta a registrare la rotta iniziale;
     5. il router per ultimo: e' l'unico che disegna contenuto, e a quel
        punto trova tutto pronto.
   ===================================================================== */

(function () {
    'use strict';

    function avvia() {
        // Protezione contro il doppio avvio.
        // Bootstrap Studio, quando riesporta index.html, riaggiunge la
        // propria lista di <script> in fondo alla pagina: se resta anche
        // quella gia' presente, ogni file viene eseguito due volte e
        // ogni addEventListener finisce registrato due volte. L'effetto
        // e' subdolo — il pulsante "Assistente" apre e richiude il
        // drawer nello stesso clic, perche' due handler applicano il
        // toggle uno dopo l'altro. Questo flag rende innocuo il caso.
        if (App.avviata) {
            console.warn('app.js eseguito due volte: controlla che in index.html ' +
                         'non ci sia una lista di <script> duplicata.');
            return;
        }
        App.avviata = true;

        App.UI.carica();
        App.Shell.inizializza();
        App.Chat.inizializza();
        App.Tabs.inizializza();
        App.Router.avvia();
    }

    document.addEventListener('DOMContentLoaded', avvia);
})();
