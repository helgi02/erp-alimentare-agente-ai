/* =====================================================================
   components/markdown.js — traduzione markdown -> HTML per i messaggi
   dell'agente.

   PERCHE' SERVE
   LM Studio/Qwen scrive le risposte in Markdown (grassetto, elenchi,
   tabelle): senza questo passaggio arrivano in chat con gli asterischi
   e le barre verticali visibili, come testo grezzo invece che
   formattato — esattamente il problema segnalato.

   ORDINE DI SICUREZZA (non invertire)
   1. Il testo del modello viene escapato con App.Utils.esc PRIMA di
      qualunque interpretazione markdown. Il testo generato da Qwen non
      e' contenuto fidato: se si applicasse markdown a testo non
      escapato, una risposta del modello potrebbe iniettare tag HTML
      arbitrari nella pagina.
   2. Le sole entita' HTML che compaiono nel risultato finale sono
      quelle scritte QUI (<strong>, <table>, <a> con href validato,
      ecc.): il contenuto testuale al loro interno resta sempre quello
      gia' escapato al passo 1.

   COPERTURA
   Non e' un parser Markdown completo (non gestisce heading, blocchi di
   codice multilinea, liste annidate): copre il sottoinsieme che LM
   Studio produce davvero in questo progetto — grassetto, corsivo,
   codice inline, elenchi puntati/numerati a un livello, tabelle GFM,
   link, paragrafi. Va esteso se in pratica emergono altri costrutti.

   Nessuna libreria esterna: stessa scelta fatta per il resto del sito,
   per non dipendere da una CDN irraggiungibile durante la demo.
   ===================================================================== */

window.App = window.App || {};

App.Markdown = (function () {
    'use strict';

    // Una riga fatta solo di trattini/due punti/pipe/spazi, tipo
    // "|---|:---:|---|" o "--- | ---": e' la riga di separazione che
    // GFM richiede subito sotto l'intestazione di una tabella.
    function eSepatatoreTabella(riga) {
        return /^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$/.test(riga);
    }

    // "| a | b |" oppure "a | b" -> ["a", "b"]. Toglie il pipe iniziale
    // e finale se presenti, poi divide su quelli rimasti.
    function celleRiga(riga) {
        let r = riga.trim();
        if (r.startsWith('|')) r = r.slice(1);
        if (r.endsWith('|')) r = r.slice(0, -1);
        return r.split('|').map((c) => c.trim());
    }

    function eRigaTabella(riga) {
        return riga.indexOf('|') !== -1;
    }

    function eElencoPuntato(riga) {
        return /^\s*[-*+]\s+/.test(riga);
    }

    function eElencoNumerato(riga) {
        return /^\s*\d+[.)]\s+/.test(riga);
    }

    function contenutoElenco(riga, regex) {
        return riga.replace(regex, '');
    }

    /* ==================================================================
       FORMATTAZIONE INLINE
       Applicata dopo l'escape: il testo qui dentro e' gia' sicuro, si
       tratta solo di riconoscere la sintassi markdown e avvolgerla nei
       tag corrispondenti.
       ================================================================== */
    function inline(testo) {
        // Il codice inline va ESTRATTO prima di ogni altra trasformazione,
        // non semplicemente convertito per primo: il contenuto fra
        // backtick e' spessissimo un identificatore snake_case (nomi di
        // tool come get_list_vendite, di colonne, di file), e la regex
        // del corsivo (_..._) non ha modo di sapere che quel testo e'
        // gia' protetto: lo tratterebbe come sintassi corsiva e lo
        // spezzerebbe (es. "get_list_vendite" diventerebbe "get<em>list
        // </em>vendite").
        //
        // STESSO PROBLEMA, FORMA PIU' GRAVE: un URL di download generato
        // dal server contiene quasi sempre underscore (il nome file lo
        // costruisce CostruisciNomeFileUnico in
        // tools/uFilesToolsProvider.pas con un prefisso data/ora unito da
        // "_"). Se il modello scrive quell'URL in chiaro nel testo, SENZA
        // la sintassi Markdown [testo](url), la stessa regex del corsivo
        // lo spezzava allo stesso modo - e stavolta il danno usciva dal
        // browser: il link cliccabile risultante conteneva "<em>"/"</em>"
        // dentro l'attributo href. Il file sul server ha sempre un nome
        // innocuo (il sanitizzatore Delphi ammette solo lettere, cifre,
        // underscore e trattino: non puo' MAI scrivere "<" o ">" su
        // disco), ma cliccare quel link mandava al server una richiesta
        // con "<"/">" dentro il percorso - caratteri non ammessi in un
        // path di Windows, da cui l'eccezione EInOutArgumentException
        // osservata.
        //
        // La protezione e' quindi la stessa idea applicata a TRE casi:
        // codice, link Markdown espliciti, URL nudi nel testo (questi
        // ultimi vengono anche resi cliccabili automaticamente, un
        // beneficio secondario utile visto che i modelli locali non
        // sempre usano la sintassi [testo](url)). Ogni frammento protetto
        // diventa un segnaposto testuale, le trasformazioni di
        // grassetto/corsivo lavorano solo sul resto, e i segnaposti
        // vengono rimessi al loro posto per ultimi, intatti.
        //
        // Il segnaposto usa un prefisso improbabile in una risposta
        // normale (nessun carattere di controllo: un byte NUL letterale
        // in un file .js e' pessima idea, alcuni strumenti lo trattano
        // da li' in poi come file binario invece che testo).
        const PREFISSO = 'CODEMD';
        const protetti = [];
        function proteggi(html) {
            protetti.push(html);
            return PREFISSO + (protetti.length - 1) + PREFISSO;
        }

        // Href validato: solo http(s) o un percorso interno assoluto
        // (/vendite, /lotti/871...). Qualunque altro schema (es.
        // javascript:) viene scartato: il contenuto e' generato dal
        // modello, non va fidato ciecamente nemmeno per un attributo
        // href. Un singolo "/" iniziale e' un percorso relativo a
        // questo sito (App.Router.url produce esattamente questa
        // forma); "//" o "/\" invece sono URL protocol-relative che il
        // browser risolve verso un host ESTERNO (es. "//evil.com") -
        // proprio la stessa svista da evitare, quindi vanno esclusi
        // esplicitamente e non solo lasciati fuori dal match positivo.
        function schemaAmmesso(url) {
            return /^(https?:\/\/|\/(?![\/\\]))/i.test(url.replace(/&amp;/g, '&'));
        }

        let r = testo;

        // 1. Codice inline: `...` - protetto per primo, cosi' un URL o
        // un identificatore scritto dentro non viene toccato da nessuna
        // regola successiva.
        r = r.replace(/`([^`]+?)`/g, (intero, contenuto) =>
            proteggi('<code>' + contenuto + '</code>'));

        // 2. Link Markdown espliciti: [testo](url).
        r = r.replace(/\[([^\]]+)\]\(([^)]+)\)/g, (intero, testoLink, url) => {
            if (schemaAmmesso(url)) {
                return proteggi('<a href="' + url + '" target="_blank" rel="noopener noreferrer">' + testoLink + '</a>');
            }
            return proteggi(testoLink);
        });

        // 3. URL nudi nel testo, senza sintassi Markdown: il caso che ha
        // causato il guasto. Punteggiatura finale comune (punto, virgola,
        // parentesi di chiusura) viene staccata dall'URL prima di
        // costruire il link, cosi' un URL a fine frase non si porta
        // dietro il punto fermo.
        r = r.replace(/\bhttps?:\/\/[^\s<>{}"']+/g, (url) => {
            let pulito = url;
            let coda = '';
            while (pulito.length > 0 && /[.,;:!?)]$/.test(pulito)) {
                coda = pulito.slice(-1) + coda;
                pulito = pulito.slice(0, -1);
            }
            return proteggi('<a href="' + pulito + '" target="_blank" rel="noopener noreferrer">' + pulito + '</a>') + coda;
        });

        // Grassetto: **...** oppure __...__
        r = r.replace(/\*\*([^*]+?)\*\*/g, '<strong>$1</strong>');
        r = r.replace(/__([^_]+?)__/g, '<strong>$1</strong>');

        // Corsivo: *...* oppure _..._ (dopo il grassetto, cosi' i singoli
        // asterischi/underscore rimasti sono davvero corsivo). A questo
        // punto codice, link e URL nudi sono gia' diventati segnaposti
        // innocui: questa regola non puo' piu' raggiungerli.
        r = r.replace(/\*([^*]+?)\*/g, '<em>$1</em>');
        r = r.replace(/_([^_]+?)_/g, '<em>$1</em>');

        // Ripristino, per ultimo: il contenuto protetto non e' mai
        // passato da nessuna delle sostituzioni sopra.
        if (protetti.length) {
            const regexRipristino = new RegExp(PREFISSO + '(\\d+)' + PREFISSO, 'g');
            r = r.replace(regexRipristino, (intero, indice) => protetti[Number(indice)]);
        }

        return r;
    }

    /* ==================================================================
       PARSER A BLOCCHI
       Scorre le righe e riconosce tabelle, elenchi e paragrafi. Ogni
       blocco produce un pezzo di HTML; i blocchi vengono poi uniti.
       ================================================================== */
    function analizzaBlocchi(righe) {
        const blocchi = [];
        let i = 0;

        while (i < righe.length) {
            const riga = righe[i];

            if (riga.trim() === '') {
                i++;
                continue;
            }

            // --- Tabella: riga con pipe seguita da riga di separazione
            if (eRigaTabella(riga) && i + 1 < righe.length && eSepatatoreTabella(righe[i + 1])) {
                const intestazioni = celleRiga(riga).map(inline);
                i += 2;
                const corpo = [];
                while (i < righe.length && righe[i].trim() !== '' && eRigaTabella(righe[i])) {
                    corpo.push(celleRiga(righe[i]).map(inline));
                    i++;
                }

                let html = '<table class="table table-sm table-bordered align-middle mb-2">';
                html += '<thead><tr>' + intestazioni.map((c) => '<th>' + c + '</th>').join('') + '</tr></thead>';
                html += '<tbody>' + corpo.map((riga2) =>
                    '<tr>' + riga2.map((c) => '<td>' + c + '</td>').join('') + '</tr>'
                ).join('') + '</tbody></table>';
                blocchi.push(html);
                continue;
            }

            // --- Elenco puntato
            if (eElencoPuntato(riga)) {
                const voci = [];
                while (i < righe.length && eElencoPuntato(righe[i])) {
                    voci.push(inline(contenutoElenco(righe[i], /^\s*[-*+]\s+/)));
                    i++;
                }
                blocchi.push('<ul class="mb-2 ps-3">' + voci.map((v) => '<li>' + v + '</li>').join('') + '</ul>');
                continue;
            }

            // --- Elenco numerato
            if (eElencoNumerato(riga)) {
                const voci = [];
                while (i < righe.length && eElencoNumerato(righe[i])) {
                    voci.push(inline(contenutoElenco(righe[i], /^\s*\d+[.)]\s+/)));
                    i++;
                }
                blocchi.push('<ol class="mb-2 ps-3">' + voci.map((v) => '<li>' + v + '</li>').join('') + '</ol>');
                continue;
            }

            // --- Paragrafo: righe consecutive non vuote e non
            // riconosciute come altro, unite con <br> fra loro (a capo
            // singolo dentro allo stesso paragrafo, come nella chat di
            // un modello che va a capo spesso senza voler separare
            // davvero il discorso in paragrafi diversi).
            const righeParagrafo = [];
            while (i < righe.length && righe[i].trim() !== '' &&
                   !eElencoPuntato(righe[i]) && !eElencoNumerato(righe[i]) &&
                   !(eRigaTabella(righe[i]) && i + 1 < righe.length && eSepatatoreTabella(righe[i + 1]))) {
                righeParagrafo.push(inline(righe[i]));
                i++;
            }
            blocchi.push('<p class="mb-2">' + righeParagrafo.join('<br>') + '</p>');
        }

        return blocchi;
    }

    return {
        // Punto di ingresso: testo grezzo del modello -> HTML sicuro da
        // assegnare a innerHTML.
        toHtml(testoGrezzo) {
            const testo = App.Utils.esc(testoGrezzo == null ? '' : testoGrezzo);
            const righe = testo.replace(/\r\n/g, '\n').split('\n');
            const blocchi = analizzaBlocchi(righe);
            return blocchi.join('') || '<p class="mb-0"></p>';
        }
    };
})();
