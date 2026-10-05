/* =====================================================================
   components/chat.js — drawer di conversazione con l'agente MCP.

   E' il componente centrale del progetto, e si distingue da una chat
   qualunque per l'ISPETTORE: sopra ogni risposta compaiono i riquadri
   delle tool call effettivamente eseguite (nome del tool, argomenti,
   JSON restituito, durata). Serve a due cose:

     - in sede di discussione, a mostrare che la risposta nasce da una
       chiamata MCP su dati reali e non da un'improvvisazione del
       modello: senza questa finestra il sistema resta una scatola nera
       e l'integrazione non e' dimostrabile;
     - in sviluppo, a capire quale tool e' stato scelto e con quali
       argomenti, che e' l'informazione che serve quando il modello
       sbaglia parametri.

   Lo si puo' nascondere con lo switch "Dettagli tecnici (tool)" in
   fondo al pannello, per la demo "utente finale".

   INDICE (nell'ordine in cui compaiono qui sotto):
     - STATO E CONFIGURAZIONE       conversationId, testi fissi, suggerimenti
     - AVVIO E INPUT                 inizializza, _riorganizzaFooter,
                                      adattaAltezzaInput, nuova
     - SUGGERIMENTI INIZIALI         mostraSuggerimenti, nascondiSuggerimenti
     - APERTURA DRAWER               apri
     - RENDERING MESSAGGI            aggiungiMessaggio, aggiungiTraccia,
                                      scorriInFondo
     - DISAMBIGUAZIONE               aggiungiScelteDisambiguazione
     - NAVIGAZIONE AUTOMATICA        aggiungiAperturaVista
     - FORM SCENARIO 3 (RICETTE)     _etichettaTipoComponente,
                                      aggiungiFormSostituzioneIngredienti,
                                      aggiungiFormConfermaAdattamento
     - INDICATORE DI ATTESA           _renderIndicatoreAttesa,
                                      _avviaIndicatoreAttesa, _fermaIndicatoreAttesa
     - INVIO                         invia

   NB: e' un solo file, non diviso in piu' moduli come app.css/sections/:
   per il CSS lo split ha funzionato perche' app.css puo' importare i
   file con @import senza toccare index.html. Il JS non ha un
   equivalente altrettanto semplice con gli script classici usati qui
   (non-module, caricati con <script defer> elencati uno per uno in
   index.html) - e servirebbe aggiungere nuovi <script src> in
   index.html, che pero' e' generato da Bootstrap Studio: vedi il
   commento in app.js su cosa succede gia' oggi quando BS riesporta la
   pagina (rischio di lista <script> duplicata). Per restare coerenti
   con quella scelta, qui la "struttura" e' solo nell'organizzazione
   interna (le sezioni sotto), non in piu' file.
   ===================================================================== */

window.App = window.App || {};

App.Chat = {

    /* =================================================================
       STATO E CONFIGURAZIONE
       ================================================================= */

    conversationId: null,
    inCorso: false,

    // Risultato ({esito, prodotto_finito_id, componenti, ...}) dell'ultima
    // get_ricetta_prodotto_finito riuscita in QUALSIASI turno di questa
    // conversazione, non solo quello in corso - vedi il commento dentro
    // aggiungiFormSostituzioneIngredienti per il perche'. Aggiornato in
    // invia(), azzerato in nuova().
    ultimaRicettaVista: null,

    // Tetto di crescita dell'input in px: deve combaciare con il
    // max-height di .chat-input-wrapper textarea in app.css. Oltre
    // questa altezza la textarea smette di allargare il pannello e
    // mostra il proprio scroll interno.
    ALTEZZA_INPUT_MAX: 160,

    // Messaggio di apertura, alla primissima visita del drawer: piu'
    // disteso di un elenco di funzioni, spiega in una frase sola cosa
    // puo' fare l'assistente (consultare dati, generare documenti) e
    // invita a partire da un esempio o scrivere liberamente. Si presenta
    // per nome (Pepper) solo qui, alla primissima battuta: dopo un
    // reset (MESSAGGIO_NUOVA) risulterebbe ridondante ripresentarsi.
    MESSAGGIO_BENVENUTO:
        'Ciao, sono Pepper! Sono qui per aiutarti a consultare i dati del gestionale — vendite, lotti, ' +
        'ricette, non conformità — e a generare i documenti che ti servono. Raccontami di cosa hai ' +
        'bisogno, oppure parti da uno degli esempi qui sotto.',

    // Messaggio dopo un reset (vedi nuova()): niente da rispiegare, chi
    // lo legge ha gia' visto il benvenuto completo pochi istanti prima.
    MESSAGGIO_NUOVA: 'Nuova conversazione. Da dove iniziamo?',

    // Fase REALE del turno mostrata nell'indicatore di attesa.
    // Prima era solo scenografia (frasi che cambiavano col tempo, perche'
    // il backend rispondeva in un colpo solo a fine giro). Con il
    // protocollo a passi ogni risposta del server porta il campo "fase",
    // una frase gia' pronta che descrive il passo successivo ("Il modello
    // sta leggendo i dati"): la chat la mostra senza interpretare nulla.
    // Aggiornata da _impostaFaseAttesa(), letta da _renderIndicatoreAttesa().
    _faseAttesa: '',
    _inizioFase: 0,

    // Sotto questa soglia (in secondi) il contatore non compare accanto
    // alla frase: su una risposta rapida vedere "· 1s" per un istante e
    // poi sparire e' solo rumore visivo, non un'informazione utile.
    SOGLIA_CONTATORE_SECONDI: 5,

    // I tre scenari del progetto resi cliccabili: la demo non deve
    // dipendere da cosa ci si ricorda di digitare sul momento.
    suggerimenti: [
        'Il lotto di uova LMP-MP005-002 è risultato non conforme per contaminazione da Salmonella. Apri la non conformità e dimmi quali lotti di prodotto finito, ordini e clienti sono coinvolti.',
        'Quali sono stati i 5 prodotti più venduti nel 2026 in quantità, quanto hanno fatturato, e qual è il cliente che ha comprato di più?',
        'Simula l\'adattamento della ricetta della Torta Caprese 800g sostituendo il burro con la margarina vegetale, e dimmi di quanto cambia il costo di produzione e quali allergeni restano.'
    ],

    /* =================================================================
       AVVIO E INPUT
       ================================================================= */

    inizializza() {
        const U = App.Utils;

        this.elencoMessaggi = U.$('#chatMessages');
        this.form = U.$('#chatForm');
        this.input = U.$('#chatInput');

        this.mostraSuggerimenti();
        this.aggiungiMessaggio('agent', this.MESSAGGIO_BENVENUTO);
        this.adattaAltezzaInput();

        this.form.addEventListener('submit', (e) => {
            e.preventDefault();
            this.invia(this.input.value);
        });

        // Invio con Enter, a capo con Shift+Enter
        this.input.addEventListener('keydown', (e) => {
            if (e.key === 'Enter' && !e.shiftKey) {
                e.preventDefault();
                this.form.requestSubmit();
            }
        });

        // Auto-resize: un comando lungo (o incollato) deve restare
        // leggibile per intero mentre lo si scrive, non scorrere dentro
        // una riga fissa. Vedi adattaAltezzaInput().
        this.input.addEventListener('input', () => this.adattaAltezzaInput());

        U.$('#btnChatNuova').addEventListener('click', () => this.nuova());

        this._aggiungiPulsanteImpostazioni();
        this._aggiornaInfoModello();
    },

    /* =================================================================
       IMPOSTAZIONI DEL MODELLO
       Il modello e' UNO, configurato nell'ini del server ([LLM]
       ChatEndpoint/ChatModel/...), ed e' il server a chiamarlo. Da qui lo
       si puo' cambiare, ma la chat non decide e non verifica nulla da
       sola: legge la configurazione dal server, gli manda i valori del
       form e mostra cio' che risponde. E' il server a:
         - controllare i valori (indirizzo solo locale o di rete interna,
           limiti di temperatura e timeout...);
         - interrogare il motore per l'elenco dei modelli ("Verifica");
         - riscrivere l'ini, cosi' la scelta vale anche dopo un riavvio.
       Il pannello e' costruito da JavaScript invece che in index.html: il
       markup e' gestito da Bootstrap Studio e un'esportazione lo
       sovrascriverebbe.
       ================================================================= */

    // Tooltip del badge "Attivo" con il modello in uso, letto dal server.
    // Solo informativo: se la lettura fallisce il badge resta com'e'.
    async _aggiornaInfoModello() {
        const badge = App.Utils.$('#chatStatoModello');
        if (!badge) return;
        try {
            const c = await App.Api.ConfigLLM.leggi();
            badge.title = 'Modello: ' + (c.modello || 'quello caricato nel motore') + ' (' + c.endpoint + ')';
        } catch (e) {
            badge.title = '';
        }
    },

    _aggiungiPulsanteImpostazioni() {
        const nuova = App.Utils.$('#btnChatNuova');
        if (!nuova || App.Utils.$('#btnChatImpostazioniLLM')) return;
        const btn = document.createElement('button');
        btn.type = 'button';
        btn.id = 'btnChatImpostazioniLLM';
        btn.className = 'btn btn-light btn-sm';
        btn.title = 'Impostazioni del modello';
        // Icona ingranaggio (Bootstrap Icons "gear"), inline per non
        // toccare lo sprite SVG di index.html.
        btn.innerHTML = '<svg class="ico" viewBox="0 0 16 16" fill="currentColor"><path d="M8 4.754a3.246 3.246 0 1 0 0 6.492 3.246 3.246 0 0 0 0-6.492M5.754 8a2.246 2.246 0 1 1 4.492 0 2.246 2.246 0 0 1-4.492 0"/><path d="M9.796 1.343c-.527-1.79-3.065-1.79-3.592 0l-.094.319a.873.873 0 0 1-1.255.52l-.292-.16c-1.64-.892-3.433.902-2.54 2.541l.159.292a.873.873 0 0 1-.52 1.255l-.319.094c-1.79.527-1.79 3.065 0 3.592l.319.094a.873.873 0 0 1 .52 1.255l-.16.292c-.892 1.64.901 3.434 2.541 2.54l.292-.159a.873.873 0 0 1 1.255.52l.094.319c.527 1.79 3.065 1.79 3.592 0l.094-.319a.873.873 0 0 1 1.255-.52l.292.16c1.64.893 3.434-.902 2.54-2.541l-.159-.292a.873.873 0 0 1 .52-1.255l.319-.094c1.79-.527 1.79-3.065 0-3.592l-.319-.094a.873.873 0 0 1-.52-1.255l.16-.292c.893-1.64-.902-3.433-2.541-2.54l-.292.159a.873.873 0 0 1-1.255-.52zm-2.633.283c.246-.835 1.428-.835 1.674 0l.094.319a1.873 1.873 0 0 0 2.693 1.115l.291-.16c.764-.415 1.6.42 1.184 1.185l-.159.292a1.873 1.873 0 0 0 1.116 2.692l.318.094c.835.246.835 1.428 0 1.674l-.319.094a1.873 1.873 0 0 0-1.115 2.693l.16.291c.415.764-.42 1.6-1.185 1.184l-.291-.159a1.873 1.873 0 0 0-2.693 1.116l-.094.318c-.246.835-1.428.835-1.674 0l-.094-.319a1.873 1.873 0 0 0-2.692-1.115l-.292.16c-.764.415-1.6-.42-1.184-1.185l.159-.291A1.873 1.873 0 0 0 1.945 8.93l-.319-.094c-.835-.246-.835-1.428 0-1.674l.319-.094A1.873 1.873 0 0 0 3.06 4.377l-.16-.292c-.415-.764.42-1.6 1.185-1.184l.292.159a1.873 1.873 0 0 0 2.692-1.115z"/></svg>';
        btn.addEventListener('click', () => this.apriImpostazioniLLM());
        nuova.parentNode.insertBefore(btn, nuova);
    },

    // Apre (o chiude, al secondo clic) il pannello con la configurazione
    // ATTUALE del server.
    async apriImpostazioniLLM() {
        const U = App.Utils;
        if (this.inCorso) return;
        const esistente = U.$('#pannelloImpostazioniLLM');
        if (esistente) {
            esistente.remove();
            return;
        }

        let c;
        try {
            c = await App.Api.ConfigLLM.leggi();
        } catch (e) {
            this.mostraErroreTurno(e);
            return;
        }

        const campo = (id, etichetta, valore, tipo, aiuto, extra) =>
            '<div class="mb-2"><label class="form-label small mb-0" for="' + id + '">' + etichetta + '</label>' +
            '<input class="form-control form-control-sm" id="' + id + '" type="' + (tipo || 'text') + '"' +
            ' value="' + U.esc(valore === null || valore === undefined ? '' : String(valore)) + '"' +
            ' autocomplete="off"' + (extra || '') + '>' +
            (aiuto ? '<div class="form-text small">' + aiuto + '</div>' : '') + '</div>';

        const pannello = document.createElement('div');
        pannello.id = 'pannelloImpostazioniLLM';
        pannello.className = 'chat-impostazioni-llm';
        pannello.innerHTML =
            '<div class="d-flex justify-content-between align-items-center mb-2">' +
                '<strong class="small">Modello usato dal server</strong>' +
                '<button type="button" class="btn-close btn-sm" data-azione="chiudi" aria-label="Chiudi"></button>' +
            '</div>' +
            campo('llmEndpoint', 'Indirizzo del motore (URL di base)', c.endpoint, 'url',
                'Lo contatta il server, non questo browser: solo indirizzi della macchina del server o della rete interna.') +
            campo('llmModello', 'Modello', c.modello, 'text',
                'Vuoto = il modello gi&agrave; caricato nel motore. "Verifica" propone quelli disponibili.',
                ' list="llmModelliDisponibili"') +
            '<datalist id="llmModelliDisponibili"></datalist>' +
            '<div class="row g-2">' +
                '<div class="col">' + campo('llmTemperatura', 'Temperatura', c.temperatura, 'text',
                    'Vuota = default del motore', ' inputmode="decimal"') + '</div>' +
                '<div class="col">' + campo('llmMaxToken', 'Max token', c.max_token, 'number',
                    '0 = nessun limite', ' min="0"') + '</div>' +
                '<div class="col">' + campo('llmTimeout', 'Timeout (s)', Math.round((c.timeout_ms || 180000) / 1000),
                    'number', '', ' min="5"') + '</div>' +
            '</div>' +
            '<div class="small mb-2" id="llmEsito" aria-live="polite"></div>' +
            '<div class="d-flex flex-wrap gap-2">' +
                '<button type="button" class="btn btn-outline-secondary btn-sm" data-azione="verifica">Verifica connessione</button>' +
                '<button type="button" class="btn btn-primary btn-sm" data-azione="salva">Salva sul server</button>' +
            '</div>';

        const header = U.$('#chatPanel .chat-header');
        header.parentNode.insertBefore(pannello, header.nextSibling);

        // Valori del form COSI' COME SONO: conversioni e controlli li fa il
        // server (unico punto di verita'), qui si trasforma solo il timeout
        // da secondi (piu' comodi da leggere) a millisecondi.
        const leggi = () => ({
            endpoint: U.$('#llmEndpoint').value.trim(),
            modello: U.$('#llmModello').value.trim(),
            temperatura: U.$('#llmTemperatura').value.trim(),
            max_token: U.$('#llmMaxToken').value.trim() || '0',
            timeout_ms: String((Number(U.$('#llmTimeout').value) || 0) * 1000)
        });
        const esito = (classe, testo) => {
            const el = U.$('#llmEsito');
            el.className = 'small mb-2 ' + classe;
            el.textContent = testo;
        };

        pannello.addEventListener('click', async (e) => {
            const azione = e.target.dataset && e.target.dataset.azione;
            if (!azione) return;

            if (azione === 'chiudi') {
                pannello.remove();
            } else if (azione === 'verifica') {
                esito('text-body-secondary', 'Il server sta contattando il motore...');
                try {
                    const r = await App.Api.ConfigLLM.elencaModelli(leggi().endpoint);
                    U.$('#llmModelliDisponibili').innerHTML = (r.modelli || [])
                        .map((m) => '<option value="' + U.esc(m) + '">').join('');
                    esito('text-success', 'Connessione riuscita. ' + (r.modelli && r.modelli.length
                        ? 'Modelli disponibili: ' + r.modelli.join(', ')
                        : 'Nessun modello di chat caricato.'));
                } catch (err) {
                    esito('text-danger', err.dettaglio || err.message);
                }
            } else if (azione === 'salva') {
                esito('text-body-secondary', 'Salvataggio...');
                try {
                    const salvata = await App.Api.ConfigLLM.salva(leggi());
                    pannello.remove();
                    this._aggiornaInfoModello();
                    this.aggiungiMessaggio('agent', 'Impostazioni salvate sul server: da ora risponde **' +
                        (salvata.modello || 'il modello caricato') + '** (' + salvata.endpoint + ').');
                } catch (err) {
                    esito('text-danger', err.dettaglio || err.message);
                }
            }
        });
    },

    // Ricalcola l'altezza di #chatInput sul contenuto effettivo: si
    // azzera a 'auto' per lasciar restringere la textarea quando si
    // cancella testo (altrimenti scrollHeight resterebbe quello
    // massimo raggiunto), poi si porta a scrollHeight fino al tetto
    // ALTEZZA_INPUT_MAX, oltre il quale scorre invece di continuare a
    // spingere in basso il resto del pannello.
    adattaAltezzaInput() {
        const el = this.input;
        el.style.height = 'auto';
        el.style.height = Math.min(el.scrollHeight, this.ALTEZZA_INPUT_MAX) + 'px';
    },

    // Nuova conversazione: azzera lo stato lato client (conversation_id,
    // cronologia visibile, input) cosi' il turno successivo riparte da
    // zero. NON serve avvisare il backend con una chiamata dedicata:
    // TArchivioConversazioni (services/uServiziAgente.pas) e' un
    // archivio in memoria indicizzato per conversation_id, con scadenza
    // automatica dopo un'ora di inattivita' (TTL_CONVERSAZIONE_MINUTI).
    // Smettendo semplicemente di riusare l'id, la vecchia conversazione
    // non e' piu' referenziata da nessuno e si spegne da sola per
    // scadenza — la stessa politica per cui riavviare il server la fa
    // comunque perdere. Il prossimo POST con conversation_id assente ne
    // ricevera' uno nuovo da TArchivioConversazioni.NuovoID.
    nuova() {
        if (this.inCorso) return;   // non si azzera una risposta a meta'

        this.conversationId = null;
        this.ultimaRicettaVista = null;
        this.elencoMessaggi.innerHTML = '';
        this.input.value = '';
        this.adattaAltezzaInput();

        this.mostraSuggerimenti();
        this.aggiungiMessaggio('agent', this.MESSAGGIO_NUOVA);

        this.input.focus();
    },

    // Lista verticale (vedi .chat-suggestions in app.css): niente piu'
    // troncamento a metà frase — con una card per riga, a tutta
    // larghezza del pannello, il testo va semplicemente a capo
    // (white-space:normal in CSS) invece di tagliarsi con "…", che
    // nascondeva proprio la parte che rendeva utile il suggerimento
    // (es. "senza frutta a guscio?" tagliato via).
    /* =================================================================
       SUGGERIMENTI INIZIALI
       ================================================================= */

    mostraSuggerimenti() {
        const U = App.Utils;
        U.$('#chatSuggestions').innerHTML = this.suggerimenti.map((s) =>
            '<button type="button" class="btn-suggestion" data-chiedi="' + U.esc(s) + '">' +
            U.esc(s) + '</button>'
        ).join('');
    },

    // Toglie i suggerimenti iniziali non appena parte una conversazione:
    // #chatSuggestions e' un contenitore FISSO fuori da #chatMessages
    // (fra l'area messaggi scrollabile e l'input, vedi index.html), non
    // un turno della chat - senza svuotarlo qui restava visibile per
    // sempre sotto lo storico, anche dopo decine di scambi, rubando
    // spazio fisso sopra l'input. Richiamato ad ogni invio: idempotente,
    // e se il pannello e' gia' vuoto (svuotato da un invio precedente)
    // non fa nulla. mostraSuggerimenti() lo ripopola dopo un reset
    // (vedi nuova()).
    nascondiSuggerimenti() {
        App.Utils.$('#chatSuggestions').innerHTML = '';
    },

    // Apre il drawer, eventualmente con una domanda gia' scritta.
    // Non invia da sola: chi conduce la demo deve poter leggere la
    // domanda, modificarla e premere invio quando vuole.
    /* =================================================================
       APERTURA DRAWER
       ================================================================= */

    apri(domanda) {
        App.UI.set('chatAperta', true);
        if (domanda) {
            this.input.value = domanda;
            this.adattaAltezzaInput();
            this.input.focus();
        }
    },

    /* =================================================================
       RENDERING MESSAGGI
       ================================================================= */

    aggiungiMessaggio(ruolo, testo) {
        const div = document.createElement('div');

        // ---------------------------------------------------------
        // MESSAGGIO UTENTE
        // ---------------------------------------------------------
        if (ruolo === 'user') {
            div.className = 'msg msg-user';

            // Il testo dell'utente deve essere sempre escapato.
            div.innerHTML = App.Utils.esc(testo).replace(/\n/g, '<br>');

            this.elencoMessaggi.appendChild(div);
            this.scorriInFondo();
            return div;
        }

        // ---------------------------------------------------------
        // MESSAGGIO AGENTE
        // ---------------------------------------------------------
        if (ruolo === 'agent') {
            div.className = 'msg-row-agent';

            const contenitore = document.createElement('div');
            contenitore.className = 'msg-agent';

            const contenuto = document.createElement('div');
            contenuto.className = 'msg-agent-content';
            contenuto.innerHTML = App.Markdown.toHtml(testo || '');
            contenitore.appendChild(contenuto);
            div.appendChild(contenitore);

            this.elencoMessaggi.appendChild(div);
            return div;
        }
        // ---------------------------------------------------------
        // FALLBACK
        // ---------------------------------------------------------
        div.className = 'msg';

        div.innerHTML = App.Utils.esc(testo || '').replace(/\n/g, '<br>');

        this.elencoMessaggi.appendChild(div);
        //this.scorriInFondo();

        return div;
    },

    /* =================================================================
       DESCRIZIONE LEGGIBILE DEI TOOL
       Frase in italiano per un tool e i suoi argomenti ("Recupero le
       vendite di marzo"), usata in due momenti:
         - mentre il server lo esegue (indicatore di attesa), letta dalla
           tool_call che il modello ha appena chiesto;
         - nella riga dell'ispettore che resta nella conversazione.
       Sta nel frontend perche' e' presentazione: il server manda nome e
       argomenti, qui si decide come raccontarli. Un tool nuovo senza voce
       nel dizionario ricade su "Eseguo <nome_tool>": funziona comunque.
       ================================================================= */

    MESI: ['gennaio', 'febbraio', 'marzo', 'aprile', 'maggio', 'giugno', 'luglio',
        'agosto', 'settembre', 'ottobre', 'novembre', 'dicembre'],

    // " di marzo" se il periodo sta dentro un solo mese, " dal 01/03 al
    // 15/04" altrimenti, "" se le date mancano. L'anno si aggiunge solo se
    // non e' quello in corso.
    _descriviPeriodo(inizio, fine) {
        const d1 = inizio ? new Date(inizio) : null;
        const d2 = fine ? new Date(fine) : null;
        const valida = (d) => d && !isNaN(d.getTime());
        if (!valida(d1) && !valida(d2)) return '';
        const anno = (d) => d.getFullYear() !== new Date().getFullYear() ? ' ' + d.getFullYear() : '';
        const gm = (d) => String(d.getDate()).padStart(2, '0') + '/' + String(d.getMonth() + 1).padStart(2, '0');
        if (valida(d1) && valida(d2) && d1.getMonth() === d2.getMonth() && d1.getFullYear() === d2.getFullYear()) {
            return ' di ' + this.MESI[d1.getMonth()] + anno(d1);
        }
        if (valida(d1) && valida(d2)) return ' dal ' + gm(d1) + ' al ' + gm(d2) + anno(d2);
        return valida(d1) ? ' dal ' + gm(d1) + anno(d1) : ' fino al ' + gm(d2) + anno(d2);
    },

    descriviTool(nome, argomenti) {
        let a = argomenti || {};
        if (typeof a === 'string') { try { a = JSON.parse(a); } catch (e) { a = {}; } }

        switch (nome) {
            case 'get_list_vendite': {
                const chi = a.ragione_sociale_cliente ? ' a ' + a.ragione_sociale_cliente : '';
                const cosa = a.nome_prodotto ? ' di ' + a.nome_prodotto : '';
                return 'Recupero le vendite' + cosa + chi + this._descriviPeriodo(a.data_inizio, a.data_fine);
            }
            case 'get_cliente':   return 'Leggo l\'anagrafica del cliente';
            case 'invia_email':   return 'Invio l\'email';
            case 'anteprima_email_da_modello': return 'Preparo l\'anteprima delle email';
            case 'invia_email_da_modello':     return 'Invio le email ai clienti';
            case 'generate_csv':  return 'Elaboro il CSV';
            case 'generate_pdf':  return 'Genero il PDF';
            case 'get_ricetta_prodotto_finito':   return 'Leggo la ricetta';
            case 'cerca_componenti_ricetta':      return 'Cerco gli ingredienti nella ricetta';
            case 'simula_adattamento_ricetta':    return 'Calcolo il costo della ricetta adattata';
            case 'applica_adattamento_ricetta':   return 'Salvo la ricetta adattata';
            case 'trova_ordini_spedizioni_lotto_prodotto_finito':
                return 'Cerco ordini e spedizioni del lotto';
            case 'apri_non_conformita_materia_prima':
                return 'Registro la non conformita\'';
            case 'apri_vista':    return 'Preparo il collegamento alla pagina';
            default:              return 'Eseguo ' + nome;
        }
    },

    // Riquadro dell'ispettore per una singola tool call. La testata mostra
    // la frase leggibile; nome del tool, argomenti e risultato restano a
    // un clic (servono a dimostrare che il dato viene dal DB).
    aggiungiTraccia(chiamata) {
        const U = App.Utils;
        const div = document.createElement('div');
        div.className = 'tool-trace';
        const durata = chiamata.duration_ms != null ? chiamata.duration_ms + ' ms' : '';

        div.innerHTML =
            '<div class="tool-trace-head">' +
                '<span class="dot' + (chiamata.ok === false ? ' err' : '') + '"></span>' +
                '<span class="fw-semibold">' + U.esc(this.descriviTool(chiamata.tool, chiamata.arguments)) + '</span>' +
                '<span class="text-body-secondary small ms-2 text-nowrap">' + U.esc(chiamata.tool) + '</span>' +
                '<span class="ms-auto ps-2 text-body-secondary text-nowrap">' + U.esc(durata) + '</span>' +
            '</div>' +
            '<pre>' + U.esc(JSON.stringify(
                { arguments: chiamata.arguments, result: chiamata.result }, null, 2)) + '</pre>';

        // La testata fa da toggle sul dettaglio: chiuso di default per
        // non allagare la conversazione di JSON.
        const pre = div.querySelector('pre');
        pre.style.display = 'none';
        div.querySelector('.tool-trace-head').addEventListener('click', () => {
            pre.style.display = pre.style.display === 'none' ? 'block' : 'none';
        });

        // Durante il turno le tracce arrivano mentre l'indicatore di attesa
        // e' ancora visibile: vanno SOPRA di lui, cosi' l'indicatore resta
        // sempre l'ultima riga ("sto facendo questo adesso").
        if (this._rigaAttesa && this._rigaAttesa.parentNode === this.elencoMessaggi) {
            this.elencoMessaggi.insertBefore(div, this._rigaAttesa);
        } else {
            this.elencoMessaggi.appendChild(div);
        }
        this.scorriInFondo();
    },

    scorriInFondo() {
        this.elencoMessaggi.scrollTop = this.elencoMessaggi.scrollHeight;
    },

    // Riquadro dei candidati per una disambiguazione (esito
    // "richiede_disambiguazione" restituito da un tool come
    // get_list_vendite - vedi uVenditeToolProvider.pas). Un pulsante per
    // candidato: a differenza dei suggerimenti iniziali (che riempiono
    // solo l'input, vedi mostraSuggerimenti/data-chiedi in
    // core/shell.js), qui il click invia SUBITO il messaggio, perche' e'
    // la risposta a una domanda che il modello ha appena fatto, non un
    // punto di partenza da rivedere.
    //
    // Il messaggio inviato riporta l'id del candidato in chiaro (es.
    // "Ho scelto l'id 2 (Dolci Distribuzione S.r.l.).") perche' il
    // prompt di sistema (MessaggioSistema in uServiziAgente.pas) istruisce
    // il modello a riconoscere un id esplicito nel messaggio e a passarlo
    // nel parametro cliente_id/prodotto_id del tool invece di ripetere la
    // ricerca testuale: e' quel parametro, non il pulsante in se', a
    // garantire che la scelta sia univoca anche nel raro caso di due
    // anagrafiche con la stessa ragione sociale/denominazione (vedi
    // commento su TServizioVendite.InterrogaVendite).
    /* =================================================================
       DISAMBIGUAZIONE
       ================================================================= */

    // Modulo con le bozze restituite da anteprima_email_da_modello: una
    // scheda per email, con oggetto e testo MODIFICABILI e una spunta per
    // escluderla dall'invio. Il destinatario non si modifica: lo ha deciso
    // il gestionale (e' il cliente coinvolto), non l'utente.
    //
    // "Invia" NON passa dall'agente: chiama App.Api.Agente.inviaEmail, che
    // spedisce esattamente il testo che l'utente ha sotto gli occhi. Se
    // ripassasse dal tool invia_email_da_modello le email verrebbero
    // ricomposte dal modello di testo e le correzioni andrebbero perse.
    // Il clic e' la conferma dell'utente.
    //
    // Una scheda gia' inviata viene bloccata e non riparte piu': dopo un
    // invio riuscito a meta' si possono correggere e ritentare solo le altre.
    aggiungiAnteprimeEmail(bozze) {
        const U = App.Utils;
        const div = document.createElement('div');
        div.className = 'chat-form';
        div.innerHTML =
            '<div class="chat-form-title">Email pronte: controlla e, se serve, correggi oggetto e testo</div>' +
            bozze.map((b) =>
                '<div class="border rounded p-2 mb-2 bg-white" data-bozza data-email="' + U.esc(b.email || '') + '">' +
                    '<label class="d-block">' +
                        '<input type="checkbox" class="form-check-input me-1" data-includi checked> ' +
                        '<strong>' + U.esc(b.email || '') + '</strong> ' +
                        '<span class="badge bg-secondary">' + U.esc(b.categoria || '') + '</span> ' +
                        '<span class="small" data-esito></span>' +
                    '</label>' +
                    '<input type="text" class="form-control form-control-sm mt-2" data-oggetto ' +
                        'aria-label="Oggetto" value="' + U.esc(b.oggetto || '') + '">' +
                    '<textarea class="form-control form-control-sm mt-2" rows="10" data-corpo ' +
                        'aria-label="Testo">' + U.esc(b.corpo || '') + '</textarea>' +
                '</div>'
            ).join('') +
            '<div class="chat-form-hint text-body-secondary" data-stato></div>' +
            '<div class="chat-form-actions">' +
                '<button type="button" class="btn btn-primary btn-sm" data-btn-invia>Invia le email selezionate</button>' +
            '</div>';

        const btn = div.querySelector('[data-btn-invia]');
        const stato = div.querySelector('[data-stato]');

        btn.addEventListener('click', async () => {
            // Solo le schede spuntate e non ancora inviate.
            const schede = Array.from(div.querySelectorAll('[data-bozza]')).filter((s) =>
                !s.dataset.inviata && s.querySelector('[data-includi]').checked);
            if (!schede.length) {
                stato.textContent = 'Nessuna email selezionata.';
                return;
            }

            const messaggi = schede.map((s) => ({
                email: s.dataset.email,
                oggetto: s.querySelector('[data-oggetto]').value,
                corpo: s.querySelector('[data-corpo]').value
            }));

            btn.disabled = true;
            stato.textContent = 'Invio in corso...';
            try {
                const risposta = await App.Api.Agente.inviaEmail(messaggi);
                // "dettaglio" e' nello stesso ordine di "messaggi", quindi di "schede".
                (risposta.dettaglio || []).forEach((riga, i) => {
                    const scheda = schede[i];
                    if (!scheda) return;
                    const esito = scheda.querySelector('[data-esito]');
                    if (riga.inviata) {
                        scheda.dataset.inviata = '1';
                        esito.className = 'small text-success';
                        esito.textContent = 'Inviata';
                        scheda.querySelectorAll('input, textarea').forEach((c) => { c.disabled = true; });
                    } else {
                        esito.className = 'small text-danger';
                        esito.textContent = 'Non inviata: ' + (riga.errore || 'errore sconosciuto');
                    }
                });
                stato.textContent = risposta.non_inviate
                    ? risposta.inviate + ' inviate, ' + risposta.non_inviate + ' non inviate: puoi riprovare.'
                    : 'Email inviate: ' + risposta.inviate + '.';
            } catch (errore) {
                // Validazione o configurazione: non e' partita nessuna email.
                stato.textContent = 'Invio non riuscito: ' + (errore.dettaglio || errore.message || '');
            } finally {
                // Il pulsante resta spento solo se non c'e' piu' nulla da inviare.
                btn.disabled = !div.querySelector('[data-bozza]:not([data-inviata])');
            }
        });

        this.elencoMessaggi.appendChild(div);
    },

    aggiungiScelteDisambiguazione(problemi) {
        const div = document.createElement('div');
        // NB: non piu' "msg msg-agent" - .msg-agent oggi e' lo stile
        // editoriale del testo di Pepper (sfondo trasparente, pensato
        // per la prosa), non un contenitore per pulsanti. .chat-choices
        // ha il proprio allineamento sotto l'avatar (vedi chat.css,
        // --agent-indent).
        div.className = 'chat-choices';

        problemi.forEach((problema) => {
            const isCliente = problema.campo === 'ragione_sociale_cliente';
            const gruppo = document.createElement('div');
            gruppo.className = 'chat-choice-group';

            (problema.candidati || []).forEach((c) => {
                const btn = document.createElement('button');
                btn.type = 'button';
                btn.className = 'btn btn-outline-primary btn-sm chat-choice-btn';

                if (isCliente) {
                    btn.textContent = c.ragione_sociale +
                        (c.partita_iva ? ' — P.IVA ' + c.partita_iva : '');
                    btn.dataset.messaggio = 'Ho scelto l\'id ' + c.id + ' (' + c.ragione_sociale + ').';
                } else {
                    btn.textContent = c.denominazione + (c.codice ? ' — ' + c.codice : '');
                    btn.dataset.messaggio = 'Ho scelto l\'id ' + c.id + ' (' + c.denominazione + ').';
                }

                btn.addEventListener('click', () => {
                    if (this.inCorso) return;
                    div.classList.add('disabled');
                    this.invia(btn.dataset.messaggio);
                });

                gruppo.appendChild(btn);
            });

            div.appendChild(gruppo);
        });

        this.elencoMessaggi.appendChild(div);
        this.scorriInFondo();
    },

    // Apertura DIRETTA della vista per una chiamata riuscita al tool
    // apri_vista (tools/uNavigazioneToolProvider.pas): il tool lato
    // server valida solo che la vista esista e i parametri richiesti
    // siano presenti (esito "ok"), la navigazione VERA la fa il
    // frontend qui, traducendo {vista, parametri} in un URL tramite
    // App.RegistroViste (core/registro-viste.js) - stesso principio
    // "registro popolato da ogni vista, letto da un solo punto
    // generico" gia' seguito lato Delphi fra TRicetteToolProvider e
    // TNavigazioneToolProvider.
    //
    // Navigazione IMMEDIATA (App.Router.vaiA), non piu' un pulsante da
    // cliccare: la prima versione lasciava la scelta all'utente per non
    // ridisegnare la vista sotto "a sua insaputa", ma nell'uso reale
    // l'utente vuole vedere subito il risultato, non un altro passaggio
    // da compiere. La nota testuale che segue (chat-note, non
    // interattiva) resta solo per lasciare traccia in conversazione di
    // COSA si e' aperto - utile a chi rilegge la chat dopo, o se
    // l'utente non stava guardando lo schermo in quel momento.
    /* =================================================================
       NAVIGAZIONE AUTOMATICA
       ================================================================= */

    aggiungiAperturaVista(risultatoApriVista) {
        const risolta = App.RegistroViste.risolvi(risultatoApriVista.vista, risultatoApriVista.parametri);
        if (!risolta) return;   // vista sconosciuta a questo frontend: nessuna azione, nessun crash

        // "modalita":"pulsante" (deciso dal tool lato server): la vista e'
        // un approfondimento, non il risultato principale del turno (es.
        // l'elenco vendite filtrato dopo una risposta gia' completa in
        // chat). Si offre un pulsante e la scelta resta all'utente.
        // "riferimento" distingue i pulsanti quando sono piu' d'uno (es.
        // una tracciabilita' per ogni non conformita' aperta).
        if (risultatoApriVista.modalita === 'pulsante') {
            const div = document.createElement('div');
            div.className = 'chat-choices';
            const gruppo = document.createElement('div');
            gruppo.className = 'chat-choice-group';
            const btn = document.createElement('button');
            btn.type = 'button';
            btn.className = 'btn btn-outline-primary btn-sm chat-choice-btn';
            btn.textContent = risolta.etichetta +
                (risultatoApriVista.riferimento ? ' (' + risultatoApriVista.riferimento + ')' : '');
            btn.addEventListener('click', () => App.Router.vaiA(risolta.url));
            gruppo.appendChild(btn);
            div.appendChild(gruppo);
            this.elencoMessaggi.appendChild(div);
            this.scorriInFondo();
            return;
        }

        // A vista disegnata, il segnale visivo che l'ha aperta l'agente
        // (App.Router.evidenzia): anche quando la vista era gia' quella
        // corrente, cosi' si capisce comunque a cosa si riferisce Pepper.
        Promise.resolve(App.Router.vaiA(risolta.url)).then(() => App.Router.evidenzia());

        const nota = document.createElement('div');
        nota.className = 'chat-note';
        nota.textContent = 'Vista aperta: ' + risolta.etichetta;
        this.elencoMessaggi.appendChild(nota);
        this.scorriInFondo();
    },

    /* =================================================================
       CONFERMA DI UNA SCRITTURA (motore "pianificatore")
       ================================================================= */

    // Il turno si e' chiuso con stato_turno "in_attesa_conferma": il
    // server ha una scrittura pronta e aspetta la risposta dell'utente.
    // Con i pulsanti la risposta parte gia' classificata (campo
    // "conferma" della richiesta, vedi api/api-agente.js): il server non
    // deve chiedere al modello di interpretarla, quindi una chiamata LLM
    // in meno e nessuna ambiguita'. Scrivere a mano "si', procedi"
    // continua a funzionare come prima.
    aggiungiPulsantiConferma() {
        const div = document.createElement('div');
        div.className = 'chat-choices chat-confirm';
        const gruppo = document.createElement('div');
        gruppo.className = 'chat-choice-group';

        [
            { testo: 'Conferma', classe: 'btn-primary', messaggio: 'Confermo.', scelta: 'conferma' },
            { testo: 'Annulla', classe: 'btn-outline-secondary', messaggio: 'Annulla.', scelta: 'annulla' }
        ].forEach((voce) => {
            const btn = document.createElement('button');
            btn.type = 'button';
            btn.className = 'btn btn-sm chat-choice-btn ' + voce.classe;
            btn.textContent = voce.testo;
            btn.addEventListener('click', () => {
                if (this.inCorso) return;
                this.invia(voce.messaggio, { conferma: voce.scelta });
            });
            gruppo.appendChild(btn);
        });

        div.appendChild(gruppo);
        this.elencoMessaggi.appendChild(div);
        this.scorriInFondo();
    },

    // I pulsanti valgono solo per la richiesta appena fatta: appena parte
    // un altro messaggio (dal pulsante o scritto a mano) si spengono,
    // cosi' non si puo' confermare una proposta ormai superata.
    _disattivaPulsantiConferma() {
        this.elencoMessaggi.querySelectorAll('.chat-confirm').forEach((div) => {
            div.classList.add('disabled');
            div.querySelectorAll('button').forEach((b) => { b.disabled = true; });
        });
    },

    // 'materia_prima' -> 'materia prima', per le etichette del form sotto
    // - stessa differenza gia' resa con badgeTipoComponente in
    // view-ricette.js, qui solo testo semplice (il form vive in chat, non
    // in una tabella con badge colorati).
    /* =================================================================
       FORM SCENARIO 3 (ADATTAMENTO RICETTE)
       ================================================================= */

    _etichettaTipoComponente(tipo) {
        return tipo === 'materia_prima' ? 'materia prima' : 'semilavorato';
    },

    // Form "con cosa sostituisco?" — mostrato dopo che l'agente ha
    // chiamato cerca_componenti_ricetta con esito "ok" (scenario 3,
    // adattamento ricette).
    //
    // TERZA VERSIONE, dopo due scartate in revisione con l'utente:
    //  1. due <select> per riga ("quale componente sostituisco" + "con
    //     cosa"), righe libere aggiungibili - troppi tap e troppo testo da
    //     leggere per la scelta tipica (aprire due tendine, leggerle,
    //     scegliere in ciascuna);
    //  2. la seconda tendina sostituita da chip orizzontali - scartata a
    //     sua volta: scomode da toccare/scorrere in un pannello stretto
    //     (400px, vedi --chat-w in app.css), visivamente dense con piu' di
    //     un paio di candidati.
    // Questa versione torna a un <select> nativo - familiare su desktop e
    // mobile, nessun CSS/JS su misura per il controllo in se' - ma UNO
    // SOLO per riga, non piu' due: ogni riga e' GIA' un componente preciso
    // (uno per ciascun componente non conforme, elencate in automatico, +
    // le eventuali righe di aggiunta pura create a mano), quindi resta solo
    // da scegliere "con cosa" sostituirlo o cosa aggiungere. Quantita' e
    // unita' restano due campi SEMPRE visibili e modificabili, mai un
    // default nascosto: precompilati con il valore ATTUALE del componente
    // per velocita' quando e' una sostituzione, ma la scelta finale (tenerli
    // cosi' o cambiarli) resta comunque dell'utente, che li conferma o li
    // modifica lui.
    //
    // Sostituire un componente CONFORME (per costo o altro motivo, non per
    // allergeni) resta possibile scrivendolo in chat: casistica rara, non
    // vale la complessita' di una riga libera "quale componente?" in questo
    // form - discusso con l'utente, e' una rinuncia deliberata allo scope
    // originale (righe libere per qualunque componente) in cambio di un
    // form molto piu' immediato per il caso comune.
    //
    // INCROCIO FRA DUE TOOL_RESULT DELLO STESSO TURNO, non una nuova
    // chiamata al backend: i componenti "non conformi" sono quelli di
    // get_ricetta_prodotto_finito il cui campo "allergeni" contiene il
    // codice escludi_allergene_codice passato a cerca_componenti_ricetta
    // (letto dagli "arguments" della traccia) - lo stesso collegamento che
    // il modello ha gia' fatto da solo per orientarsi (vedi il commento in
    // testa a uRicetteToolProvider.pas su get_ricetta_prodotto_finito), qui
    // riletto lato client per costruire l'interfaccia invece che per
    // scrivere prosa.
    //
    // ATracceTurno e' risposta.tool_calls del turno CORRENTE: basta,
    // perche' nello scenario 3 osservato in pratica il modello chiama
    // get_ricetta_prodotto_finito e cerca_componenti_ricetta nello stesso
    // giro, prima di fermarsi a mostrare i candidati (vedi il commento in
    // testa a uRicetteToolProvider.pas sui quattro tool "in ordine d'uso
    // tipico"). Se un giorno non fosse piu' cosi' (turni separati), il
    // form semplicemente non compare quel turno - nessun errore, solo
    // un'occasione di comodita' in meno, l'utente puo' comunque scrivere
    // in prosa come prima.
    aggiungiFormSostituzioneIngredienti(tracceTurno) {
        const U = App.Utils;

        // this.ultimaRicettaVista (non piu' tracceTurno) e' la fonte
        // della ricetta: aggiornato in invia() ogni volta che
        // get_ricetta_prodotto_finito riesce, in QUALSIASI turno - non
        // solo quello corrente. Prima la funzione richiedeva che il
        // modello richiamasse get_ricetta_prodotto_finito nello STESSO
        // giro di cerca_componenti_ricetta: ipotesi vera per lo
        // scenario "ritiro/richiamo" (i due tool arrivano insieme, vedi
        // il commento piu' sopra) ma falsa per una richiesta fatta DOPO
        // aver gia' aperto la ricetta in un turno precedente (es.
        // "aggiungi la cioccolata" quando la ricetta e' gia' in
        // conversazione) - il modello, giustamente, non la rilegge, e
        // senza un riferimento persistente il form non compariva mai in
        // quel caso.
        // Limite accettato: se l'utente passasse a un'altra ricetta
        // senza mai riaprirla esplicitamente, questo riferimento
        // resterebbe quello vecchio - la conversazione e' pensata a
        // fuoco su un prodotto alla volta, stesso compromesso gia'
        // preso sopra per il legame FRA i due tool, qui solo esteso nel
        // tempo anziche' ristretto al turno.
        const risultatoRicetta = this.ultimaRicettaVista;
        const tracceRicerca = tracceTurno.filter((c) =>
            c.tool === 'cerca_componenti_ricetta' && c.result && c.result.esito === 'ok');
        if (!risultatoRicetta || !tracceRicerca.length) return;

        // Se nello STESSO turno la simulazione e' gia' riuscita, l'utente
        // aveva indicato da se' cosa sostituire e con cosa (es. "sostituisci
        // il burro con la margarina"): il form "con cosa sostituisco?" non
        // serve piu' e, peggio, e' fuorviante. I suoi candidati vengono da
        // cerca_componenti_ricetta, che il modello ha ristretto a quanto
        // chiesto (qui solo la margarina): la stessa lista finirebbe offerta
        // anche per gli altri componenti con l'allergene (es. il cioccolato
        // fondente), come se la margarina fosse un sostituto valido per
        // tutto. Resta il form di conferma (aggiungiFormConfermaAdattamento).
        const simulazioneRiuscita = tracceTurno.some((c) =>
            c.tool === 'simula_adattamento_ricetta' && c.result && c.result.esito === 'ok');
        if (simulazioneRiuscita) return;

        const componenti = risultatoRicetta.componenti || [];

        // Unione dei candidati di TUTTE le chiamate a cerca_componenti_ricetta
        // di questo turno (il modello puo' averne fatte piu' d'una, es. una
        // per tipo_componente) e dei codici allergene che ciascuna escludeva.
        const candidati = [];
        const codiciAllergeneEsclusi = new Set();
        tracceRicerca.forEach((c) => {
            (c.result.candidati || []).forEach((cand) => {
                // Stesso candidato da piu' ricerche dello stesso turno: una sola volta.
                if (!candidati.some((x) => x.id === cand.id && x.tipo === cand.tipo))
                    candidati.push(cand);
            });
            const codice = c.arguments && c.arguments.escludi_allergene_codice;
            if (codice) codiciAllergeneEsclusi.add(codice);
        });
        if (!candidati.length) return;

        // Componenti che portano ANCORA uno degli allergeni esclusi: sono
        // quelli per cui vale la pena mostrare gia' una riga di
        // SOSTITUZIONE pronta. Puo' non essercene nessuno - non e' piu'
        // un motivo per rinunciare al form: e' il caso normale di una
        // ricerca "libera", senza escludi_allergene_codice (es. "cerca
        // cioccolato" per AGGIUNGERLO, non per sostituire nulla) - vedi
        // piu' sotto, quando nonConformi e' vuoto si parte comunque con
        // una riga di aggiunta gia' pronta.
        const nonConformi = componenti.filter((comp) =>
            (comp.allergeni || []).some((a) => codiciAllergeneEsclusi.has(a.codice)));

        const prodottoFinitoId = risultatoRicetta.prodotto_finito_id;

        const div = document.createElement('div');
        // NB: non piu' "msg msg-agent" - vedi il commento in
        // aggiungiScelteDisambiguazione qui sopra. .chat-form e' una
        // card a se' stante (bordo + sfondo tinto, vedi chat.css) cosi'
        // il form si distingue dal testo libero della risposta.
        div.className = 'chat-form';

        const titolo = document.createElement('div');
        titolo.className = 'chat-form-title';
        // Titolo diverso a seconda che ci sia almeno un componente da
        // sostituire o solo ingredienti da aggiungere - la struttura del
        // form e' identica in entrambi i casi (vedi creaRiga sotto),
        // cambia solo l'intestazione per non promettere una
        // "sostituzione" quando non c'e' nulla da sostituire.
        titolo.textContent = nonConformi.length ? 'Con cosa sostituisco?' : 'Aggiungi ingrediente';
        div.appendChild(titolo);

        const righeContainer = document.createElement('div');
        righeContainer.className = 'chat-form-righe';
        div.appendChild(righeContainer);

        // Opzioni del <select> "con cosa?", condivise da tutte le righe:
        // stessa lista di candidati ovunque, costruita una sola volta come
        // stringa HTML invece che ricalcolata riga per riga.
        const opzioniCandidati = '<option value="">&mdash; con cosa? &mdash;</option>' +
            candidati.map((cand, i) => '<option value="' + i + '">' + U.esc(cand.denominazione) +
                ' (' + this._etichettaTipoComponente(cand.tipo) + ')</option>').join('');

        // Una riga: intestazione (nome + eventuali badge allergene per una
        // sostituzione, "Nuovo ingrediente" per un'aggiunta), il <select>
        // "con cosa?", quantita' e unita'. AVecchio e' il componente da
        // sostituire, gia' letto da get_ricetta_prodotto_finito - null per
        // una riga di AGGIUNTA (creata da "+ Aggiungi ingrediente" sotto):
        // e' l'unica differenza fra le due modalita', la struttura della
        // riga e' identica.
        const creaRiga = (AVecchio) => {
            const riga = document.createElement('div');
            riga.className = 'chat-form-riga-sost';
            riga.dataset.riga = '';

            const intestazione = document.createElement('div');
            intestazione.className = 'chat-form-riga-titolo';
            if (AVecchio) {
                const codiciComponente = (AVecchio.allergeni || [])
                    .filter((a) => codiciAllergeneEsclusi.has(a.codice))
                    .map((a) => a.codice);
                intestazione.innerHTML = U.esc(AVecchio.denominazione) + ' ' +
                    codiciComponente.map((cod) => '<span class="chat-badge-allergene">' + U.esc(cod) + '</span>').join(' ');
                riga.dataset.vecchioId = AVecchio.id;
                riga.dataset.vecchioTipo = AVecchio.tipo;
                riga.dataset.vecchioNome = AVecchio.denominazione;
            } else {
                intestazione.textContent = 'Nuovo ingrediente';
            }
            riga.appendChild(intestazione);

            const selectNuovo = document.createElement('select');
            selectNuovo.className = 'form-select form-select-sm';
            selectNuovo.dataset.selectNuovo = '';
            selectNuovo.innerHTML = opzioniCandidati;
            riga.appendChild(selectNuovo);

            const rigaQuantita = document.createElement('div');
            rigaQuantita.className = 'chat-form-riga-quantita';

            const inputQuantita = document.createElement('input');
            inputQuantita.type = 'number';
            inputQuantita.step = '0.001';
            inputQuantita.min = '0';
            inputQuantita.className = 'form-control form-control-sm chat-form-quantita';
            inputQuantita.placeholder = 'quantità';
            inputQuantita.dataset.inputQuantita = '';
            if (AVecchio && AVecchio.quantita_standard != null) inputQuantita.value = AVecchio.quantita_standard;

            const inputUnita = document.createElement('input');
            inputUnita.type = 'text';
            inputUnita.className = 'form-control form-control-sm chat-form-unita';
            inputUnita.placeholder = 'unità';
            inputUnita.dataset.inputUnita = '';
            if (AVecchio) inputUnita.value = AVecchio.unita_misura_dose || '';

            rigaQuantita.append(inputQuantita, inputUnita);

            // Solo le righe di AGGIUNTA sono rimovibili: sono state create
            // a piacere dall'utente col pulsante "+" sotto. Una riga di
            // sostituzione rappresenta invece un componente VERO della
            // ricetta di partenza - non ha senso "rimuoverla", l'utente la
            // lascia semplicemente sul placeholder se non vuole toccarla.
            if (!AVecchio) {
                const btnRimuovi = document.createElement('button');
                btnRimuovi.type = 'button';
                btnRimuovi.className = 'btn btn-outline-secondary btn-sm chat-form-remove';
                btnRimuovi.textContent = '×';
                btnRimuovi.title = 'Rimuovi questa riga';
                btnRimuovi.addEventListener('click', () => riga.remove());
                rigaQuantita.appendChild(btnRimuovi);
            }

            riga.appendChild(rigaQuantita);
            return riga;
        };

        nonConformi.forEach((comp) => righeContainer.appendChild(creaRiga(comp)));
        // Nessun componente non conforme da proporre: e' una ricerca
        // "libera" per una AGGIUNTA pura (vedi il commento su
        // nonConformi qui sopra) - si parte gia' con una riga vuota
        // pronta invece di lasciare il form senza righe da compilare.
        if (!nonConformi.length) righeContainer.appendChild(creaRiga(null));

        const btnAggiungi = document.createElement('button');
        btnAggiungi.type = 'button';
        btnAggiungi.className = 'chat-form-link';
        btnAggiungi.textContent = '+ Aggiungi ingrediente';
        btnAggiungi.addEventListener('click', () => {
            righeContainer.appendChild(creaRiga(null));
            this.scorriInFondo();
        });
        div.appendChild(btnAggiungi);

        const btnSimula = document.createElement('button');
        btnSimula.type = 'button';
        btnSimula.className = 'btn btn-primary btn-sm chat-form-btn-simula';
        btnSimula.textContent = 'Simula';
        div.appendChild(btnSimula);

        this.elencoMessaggi.appendChild(div);

        btnSimula.addEventListener('click', () => {
            if (this.inCorso) return;

            const frasi = [];
            let nonValido = false;

            righeContainer.querySelectorAll('[data-riga]').forEach((riga) => {
                riga.classList.remove('chat-form-row-invalid');

                const iNuovo = riga.querySelector('[data-select-nuovo]').value;
                const eSostituzione = riga.dataset.vecchioId != null;

                if (iNuovo === '') {
                    // Riga di sostituzione lasciata sul placeholder: va
                    // bene, l'utente ha scelto di non toccare quel
                    // componente. Una riga di AGGIUNTA senza scelta invece
                    // non ha motivo di esistere - e' un errore, non un
                    // "salta pure".
                    if (!eSostituzione) {
                        riga.classList.add('chat-form-row-invalid');
                        nonValido = true;
                    }
                    return;
                }

                const nuovo = candidati[Number(iNuovo)];
                const quantita = riga.querySelector('[data-input-quantita]').value.trim();
                const unita = riga.querySelector('[data-input-unita]').value.trim();

                if (!quantita || !unita) {
                    riga.classList.add('chat-form-row-invalid');
                    nonValido = true;
                    return;
                }

                if (eSostituzione) {
                    frasi.push('sostituisci il componente ' + this._etichettaTipoComponente(riga.dataset.vecchioTipo) +
                        ' id ' + riga.dataset.vecchioId + ' (' + riga.dataset.vecchioNome + ') con il componente ' +
                        this._etichettaTipoComponente(nuovo.tipo) + ' id ' + nuovo.id + ' (' + nuovo.denominazione +
                        '), quantità ' + quantita + ' ' + unita);
                } else {
                    frasi.push('aggiungi il componente ' + this._etichettaTipoComponente(nuovo.tipo) +
                        ' id ' + nuovo.id + ' (' + nuovo.denominazione + '), quantità ' + quantita + ' ' + unita);
                }
            });

            if (nonValido) {
                this.scorriInFondo();   // le righe evidenziate in rosso potrebbero essere sotto lo scroll
                return;
            }
            if (!frasi.length) return;   // nessuna riga compilata: niente da inviare

            div.classList.add('chat-form-disabled');
            this.invia('Per il prodotto finito id ' + prodottoFinitoId + ', ' + frasi.join('; ') +
                '. Simula il risultato e mostrami il nuovo costo e gli allergeni.');
        });

        this.scorriInFondo();
    },

    // Form di conferma dopo una simulazione riuscita (Turno 1 dello
    // scenario 3, simula_adattamento_ricetta): chiede all'UTENTE il
    // codice e la denominazione del nuovo prodotto, cosi' non e' il
    // modello a doverli indovinare quando non esiste gia' una variante
    // compatibile (vedi la description di applica_adattamento_ricetta in
    // uRicetteToolProvider.pas: senza questo form il modello proponeva da
    // solo un codice "plausibile", tipo suffisso "-SG" - funzionava, ma
    // il nome commerciale di un prodotto e' una decisione dell'utente/
    // ufficio commerciale, non dell'agente).
    //
    // I due campi sono facoltativi lato utente: se la sostituzione
    // riusa una variante gia' esistente (variante_gia_esistente), il
    // backend li ignora comunque (vedi applica_adattamento_ricetta) -
    // qui non si puo' saperlo in anticipo senza applicare davvero, quindi
    // si mostrano sempre, con un avviso.
    aggiungiFormConfermaAdattamento(tracciaSimulazione) {
        const U = App.Utils;
        const risultato = tracciaSimulazione.result;

        const div = document.createElement('div');
        // NB: non piu' "msg msg-agent" - vedi il commento in
        // aggiungiScelteDisambiguazione qui sopra.
        div.className = 'chat-form';
        div.innerHTML =
            '<div class="chat-form-title">Confermi? Scegli il nuovo prodotto</div>' +
            '<div class="chat-form-row">' +
                '<input type="text" class="form-control form-control-sm" ' +
                    'placeholder="Codice nuovo prodotto (es. PAN001-SG)" data-input-codice>' +
                '<input type="text" class="form-control form-control-sm" ' +
                    'placeholder="Denominazione nuovo prodotto" data-input-denominazione>' +
            '</div>' +
            '<div class="chat-form-hint text-body-secondary">Servono solo se non esiste gi&agrave; una ' +
                'variante compatibile: se esiste, il gestionale la riusa e questi campi vengono ignorati.</div>' +
            '<div class="chat-form-actions">' +
                '<button type="button" class="btn btn-primary btn-sm" data-btn-conferma>Conferma e crea</button>' +
            '</div>';

        this.elencoMessaggi.appendChild(div);

        div.querySelector('[data-btn-conferma]').addEventListener('click', () => {
            if (this.inCorso) return;

            const codice = div.querySelector('[data-input-codice]').value.trim();
            const denominazione = div.querySelector('[data-input-denominazione]').value.trim();
            // Nome di chi conferma, per il parametro "creato_da" (tracciabilita'
            // di chi ha autorizzato la scrittura) - preso dal badge utente gia'
            // in pagina (index.html, .user-name) invece di aggiungere un campo
            // in piu' da compilare per un dato che l'app conosce gia'.
            const badgeUtente = U.$('.user-name');
            const utente = badgeUtente ? badgeUtente.textContent.trim() : 'Utente gestionale';

            let messaggio = 'Confermo l\'adattamento appena simulato per il prodotto finito id ' +
                risultato.prodotto_finito_id + ': applicalo davvero, con creato_da "' + utente + '"';
            if (codice) messaggio += ', codice_nuovo_prodotto "' + codice + '"';
            if (denominazione) messaggio += ', denominazione_nuovo_prodotto "' + denominazione + '"';
            messaggio += '.';

            div.classList.add('chat-form-disabled');
            this.invia(messaggio);
        });

        this.scorriInFondo();
    },

    /* =================================================================
       INDICATORE DI ATTESA ("Pepper sta scrivendo...")

       Tre metodi che si occupano solo di TENERE VIVO l'indicatore
       (.chat-thinking, vedi chat.css) mentre invia() aspetta la
       risposta: quale fase mostrare in base al tempo trascorso, il
       contatore dei secondi, l'aggiornamento a intervalli. La chiamata
       HTTP vera resta tutta in invia() - qui non si parla mai col
       backend.
       ================================================================= */

    // Disegna la fase corrente (this._faseAttesa) con il contatore dei
    // secondi trascorsi nella fase.
    _renderIndicatoreAttesa(elemento, secondi) {
        const contatore = secondi >= this.SOGLIA_CONTATORE_SECONDI ? ' · ' + secondi + 's' : '';

        elemento.innerHTML =
            '<div class="chat-thinking">' +
                '<span class="chat-thinking-dots"><span></span><span></span><span></span></span>' +
                '<span>' + App.Utils.esc(this._faseAttesa) + '&hellip;' + contatore + '</span>' +
            '</div>';
    },

    // Avvia il timer: un primo rendering immediato (secondi=0, niente
    // da aspettare per vedere qualcosa), poi un tick al secondo.
    // this._timerAttesa e' un solo id per volta per costruzione: invia()
    // ritorna subito se this.inCorso e' gia' true (vedi piu' sotto),
    // quindi non puo' partire un secondo turno mentre uno e' in corso.
    _avviaIndicatoreAttesa(elemento) {
        this._elementoAttesa = elemento;
        this._impostaFaseAttesa('Sto leggendo la richiesta');

        this._timerAttesa = setInterval(() => {
            const secondi = Math.floor((Date.now() - this._inizioFase) / 1000);
            this._renderIndicatoreAttesa(elemento, secondi);
        }, 1000);
    },

    // Cambia la fase mostrata e AZZERA il contatore: i secondi si
    // riferiscono alla fase corrente (es. quanto sta impiegando il
    // modello in questo passo), che e' l'informazione utile quando
    // un 9B su CPU impiega un minuto per una sola risposta.
    _impostaFaseAttesa(testo) {
        this._faseAttesa = testo;
        this._inizioFase = Date.now();
        if (this._elementoAttesa) this._renderIndicatoreAttesa(this._elementoAttesa, 0);
    },

    // Ferma il timer. Chiamata solo dal blocco finally di invia(): gira
    // sia dopo una risposta arrivata sia dopo un errore, quindi e'
    // l'unico punto che deve davvero fermarlo. Idempotente (un secondo
    // clearInterval su un id gia' fermato non fa nulla) cosi' resta
    // sicura da richiamare anche se un giorno invia() cambiasse forma.
    _fermaIndicatoreAttesa() {
        if (this._timerAttesa) {
            clearInterval(this._timerAttesa);
            this._timerAttesa = null;
        }
    },


    /* =================================================================
       CICLO DEL TURNO (protocollo a passi, vedi api/api-agente.js)

       Tutta la logica sta nel server, che a ogni passo chiama il modello
       ed esegue i tool. La chat si limita a:
         avvia  -> [ passo ]*  -> concluso
       mostrando fra un passo e l'altro la "fase" e le tracce dei tool che
       il server le manda. A ogni giro si rimandano gli identificativi
       ricevuti nell'ULTIMA risposta (conversation_id, turno_id,
       numero_turno, passo): il client non tiene contatori propri, cosi'
       non puo' andare fuori sincronia con il server.

       Restituisce la risposta "concluso", che ha la stessa forma della
       vecchia agent-chat (agent_response, tool_calls, diagnostica):
       tutto il rendering a valle in invia() resta identico.
       In caso di errore annulla il turno sul server (best effort) e
       rilancia, cosi' la gestione dell'errore resta in un punto solo.
       ================================================================= */

    async _eseguiTurno(messaggio, opzioni) {
        let turno = await App.Api.Agente.avvia(messaggio, this.conversationId, opzioni);
        // Salvato SUBITO, non a fine turno: se il turno fallisce a meta'
        // la domanda successiva deve comunque proseguire la stessa
        // conversazione (lo storico dei turni conclusi e' sul server).
        this.conversationId = turno.conversation_id;
        this._turnoInCorso = turno;

        try {
            while (turno.stato === 'in_corso') {
                // Frase decisa dal server per il passo che sta per iniziare.
                this._impostaFaseAttesa(turno.fase || 'Sto elaborando');

                turno = await App.Api.Agente.passo(turno);
                this._turnoInCorso = turno;

                // Tracce dei tool appena eseguiti dal server: compaiono
                // subito, una riga per tool, sopra l'indicatore di attesa.
                (turno.tool_calls_passo || []).forEach((c) => this.aggiungiTraccia(c));
            }
            return turno;
        } catch (errore) {
            // 404/409: il server il turno l'ha gia' chiuso o non lo
            // riconosce; 500/502: il server lo scarta da solo. Annullarlo
            // serve solo se l'errore e' di rete (nessuno status): il
            // server potrebbe averlo ancora aperto.
            if (!errore.status) {
                App.Api.Agente.annulla(this._turnoInCorso);
            }
            throw errore;
        } finally {
            this._turnoInCorso = null;
        }
    },

    // Messaggio d'errore nella chat. Il testo lo decide il server (campo
    // "message" della risposta d'errore): la chat distingue solo fra un
    // errore del turno (il server ha risposto, con uno status HTTP) e il
    // server irraggiungibile.
    mostraErroreTurno(errore) {
        const U = App.Utils;
        let titolo, dettaglio;

        if (errore && errore.status) {
            titolo = 'Il turno si e\' interrotto.';
            dettaglio = errore.dettaglio || errore.message;
        } else {
            titolo = 'Errore di comunicazione col backend.';
            dettaglio = errore.message;
        }

        const div = this.aggiungiMessaggio('agent', '');
        div.innerHTML = '<div class="text-danger small"><strong>' + U.esc(titolo) + '</strong><br>' +
            U.esc(dettaglio) + '</div>';
    },

    /* =================================================================
       INVIO
       ================================================================= */

    // opzioni (facoltativo): { conferma: 'conferma' | 'annulla' } quando il
    // messaggio parte dai pulsanti di aggiungiPulsantiConferma.
    async invia(testo, opzioni) {
        const U = App.Utils;
        const messaggio = (testo || '').trim();
        if (!messaggio || this.inCorso) return;

        this.nascondiSuggerimenti();
        this._disattivaPulsantiConferma();
        this.aggiungiMessaggio('user', messaggio);
        this.input.value = '';
        this.adattaAltezzaInput();
        this.inCorso = true;
        U.$('#btnChatSend').disabled = true;
        U.$('#btnChatNuova').disabled = true;

        // Indicatore d'attesa esplicito: con Qwen 9B in locale una
        // risposta puo' richiedere decine di secondi, e va detto invece
        // che lasciare l'interfaccia ferma. Le fasi mostrate ora riflettono lo stato reale del turno (vedi _faseAttesa e
        // _eseguiTurno).
        //
        // Si scrive SOLO dentro .msg-agent-content (non si sovrascrive
        // piu' l'innerHTML dell'intera riga .msg-row-agent restituita da
        // aggiungiMessaggio): l'avatar e l'etichetta "Pepper" restano
        // visibili, invece di sparire durante l'attesa per poi
        // ricomparire di colpo con la risposta vera.
        const attesa = this.aggiungiMessaggio('agent', '');
        this._rigaAttesa = attesa;      // le tracce del turno vanno sopra di lei
        this._avviaIndicatoreAttesa(attesa.querySelector('.msg-agent-content'));

        try {
            const risposta = await this._eseguiTurno(messaggio, opzioni);
            attesa.remove();

            // Le tracce sono gia' comparse man mano durante il turno
            // (tool_calls_passo in _eseguiTurno). risposta.tool_calls, che
            // le contiene tutte, serve ancora sotto per disambiguazione,
            // "apri vista" e i form dello scenario 3.

            this.aggiungiMessaggio('agent',
                risposta.agent_response || risposta.error || '(risposta vuota)');

            // Se una delle tool call di questo turno ha risposto con
            // "richiede_disambiguazione", il testo del modello la
            // riporta gia' in prosa (il prompt di sistema lo istruisce a
            // farlo), ma senza questo passaggio l'utente dovrebbe
            // ridigitare a mano il nome scelto. I "problemi" (uno per
            // campo ambiguo: puo' essercene piu' di uno, es. cliente E
            // prodotto insieme) portano gia' l'elenco dei candidati con
            // id — e' dato strutturato del tool_result, non testo del
            // modello da interpretare.
            const problemi = (risposta.tool_calls || [])
                .map((c) => c.result)
                .filter((r) => r && r.esito === 'richiede_disambiguazione')
                .reduce((acc, r) => acc.concat(r.problemi || []), []);

            if (problemi.length) {
                this.aggiungiScelteDisambiguazione(problemi);
            }

            // Le tre "azioni pronte" dello scenario 3 (adattamento ricette)
            // e della navigazione generica, nell'ordine in cui possono
            // davvero capitare in un turno: prima il pulsante per aprire
            // una vista, poi il form di scelta ingredienti (dopo
            // cerca_componenti_ricetta) e quello di conferma nome prodotto
            // (dopo simula_adattamento_ricetta). Non sono alternativi fra
            // loro: un turno "chiacchierone" potrebbe in teoria innescarne
            // piu' di uno, ed e' innocuo mostrarli entrambi - vedi i
            // singoli commenti su ciascun metodo per il perche' di ognuno.
            //
            // Il pulsante "apri vista" compare in DUE casi distinti, non
            // uno solo:
            //  1) una vera chiamata al tool apri_vista, esito "ok" - il
            //     modello ha deciso lui, a runtime, di aprire una vista;
            //  2) un campo "apertura_vista" incorporato nel result di UN
            //     QUALUNQUE ALTRO tool (es. get_ricetta_prodotto_finito,
            //     vedi il commento li' in uRicetteToolProvider.pas): un
            //     canale DETERMINISTICO, che non dipende dal modello. Serve
            //     per le azioni che devono comparire OGNI volta - affidarsi
            //     a un LLM locale da 9B perche' incateni volontariamente
            //     una seconda tool_use nello stesso turno si e' rivelato
            //     inaffidabile in pratica, anche con un'istruzione esplicita
            //     "SEMPRE" nella description del tool.
            // Stessa forma {"vista","parametri"} in entrambi i casi, quindi
            // stessa funzione di rendering (aggiungiAperturaVista) per tutti
            // e due - il pulsante non rivela all'utente da quale dei due e'
            // arrivato, ne' avrebbe senso che lo facesse.
            (risposta.tool_calls || []).forEach((c) => {
                if (!c.result) return;
                if (c.tool === 'apri_vista' && c.result.esito === 'ok') {
                    this.aggiungiAperturaVista(c.result);
                } else if (c.result.apertura_vista) {
                    this.aggiungiAperturaVista(c.result.apertura_vista);
                }
                // Stesso canale, piu' viste in un solo risultato (es. una
                // tracciabilita' per ogni non conformita' aperta).
                // Anteprima delle email a testo fisso: il testo completo lo
                // mostra il codice (una scheda per email), non il modello,
                // cosi' l'utente legge ESATTAMENTE cio' che partirebbe.
                if (c.tool === 'anteprima_email_da_modello' && Array.isArray(c.result.bozze)) {
                    this.aggiungiAnteprimeEmail(c.result.bozze);
                }
                if (Array.isArray(c.result.aperture_vista)) {
                    c.result.aperture_vista.forEach((v) => this.aggiungiAperturaVista(v));
                }
            });

            // Aggiorna il riferimento alla ricetta corrente PRIMA di
            // valutare il form: se get_ricetta_prodotto_finito e' stata
            // richiamata in QUESTO turno il dato e' il piu' fresco
            // possibile, altrimenti this.ultimaRicettaVista resta quello
            // di un turno precedente (vedi il commento su
            // ultimaRicettaVista in STATO E CONFIGURAZIONE e quello
            // dentro aggiungiFormSostituzioneIngredienti).
            const tracciaRicettaTurno = (risposta.tool_calls || [])
                .find((c) => c.tool === 'get_ricetta_prodotto_finito' && c.result && c.result.esito === 'ok');
            if (tracciaRicettaTurno) this.ultimaRicettaVista = tracciaRicettaTurno.result;

            this.aggiungiFormSostituzioneIngredienti(risposta.tool_calls || []);

            const tracciaSimulazione = (risposta.tool_calls || [])
                .filter((c) => c.tool === 'simula_adattamento_ricetta' && c.result && c.result.esito === 'ok')
                .pop();   // l'ultima, se il modello ne ha rifatta una dopo un aggiustamento nello stesso turno
            if (tracciaSimulazione) {
                this.aggiungiFormConfermaAdattamento(tracciaSimulazione);
            }

            // Scrittura in attesa di conferma (solo motore "pianificatore",
            // che e' l'unico a mandare stato_turno).
            if (risposta.stato_turno === 'in_attesa_conferma') {
                this.aggiungiPulsantiConferma();
            }

        } catch (errore) {
            attesa.remove();
            this.mostraErroreTurno(errore);
        } finally {
            // Sempre, sia dopo una risposta arrivata sia dopo un errore:
            // se non si ferma qui il timer continuerebbe a girare (e a
            // scrivere su un nodo ormai rimosso dal DOM) fino al turno
            // successivo.
            this._fermaIndicatoreAttesa();
            this._rigaAttesa = null;
            this.inCorso = false;
            U.$('#btnChatSend').disabled = false;
            U.$('#btnChatNuova').disabled = false;
        }
    }
};
