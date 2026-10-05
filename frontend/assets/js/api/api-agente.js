/* =====================================================================
   api/api-agente.js - dialogo con l'agente MCP, protocollo a passi.

   Il client e' volutamente "ignorante": tutta la logica dell'agente
   (prompt, selezione dei tool, chiamata al modello, esecuzione dei tool,
   storico) sta nel server Delphi, che usa l'unico modello configurato nel
   proprio ini. Questo modulo non sa quale modello risponde ne' dove gira:
   chiede al server di far avanzare il turno e gli rimanda gli
   identificativi che ha ricevuto. Dettagli e motivazioni in
   backend/docs/protocollo_turni_client_llm.md e in
   controllers/AIAgentControllerU.pas.

   ENDPOINT
     POST /api/ai/turni          { message, conversation_id? }
     POST /api/ai/turni/passo    { conversation_id, turno_id, numero_turno, passo }
     POST /api/ai/turni/annulla  { conversation_id, turno_id }

   RISPOSTA DI avvia() E passo()
     comune:     { stato, conversation_id, turno_id, numero_turno, passo,
                   tool_calls_passo }
     stato = 'in_corso'   -> + fase (frase da mostrare all'utente mentre si
                               attende il passo successivo)
     stato = 'concluso'   -> + agent_response, tool_calls, diagnostica,
                               limite_iterazioni?   (come la vecchia
                               agent-chat, cosi' il rendering non cambia)
     tool_calls_passo      tracce dei tool eseguiti in QUESTO passo: la chat
                           le mostra man mano

   ERRORI: il campo "message" della risposta (errore.dettaglio, vedi
   App.Http in common.js) e' gia' il testo da mostrare all'utente.

   Questo modulo si limita al trasporto: il CICLO (avvia -> passo -> ... ->
   concluso) lo guida la chat (components/chat.js), perche' e' li' che si
   mostra l'avanzamento all'utente.

   STATO DI CONVERSAZIONE: invariato. Il server tiene lo storico per
   conversation_id (TArchivioConversazioni) con scadenza dopo un'ora;
   "nuova conversazione" = smettere di mandare il vecchio id.
   ===================================================================== */

window.App = window.App || {};
App.Api = App.Api || {};

App.Api.Agente = {

    // --- avvio del turno ------------------------------------------------
    // opzioni.conferma ('conferma' | 'annulla'): risposta data con i
    // pulsanti della chat a una richiesta di conferma. Il server la usa
    // al posto di una chiamata al modello (vedi AIAgentControllerU.pas,
    // campo "conferma"); "message" resta il testo mostrato in chat.
    async avvia(messaggio, conversationId, opzioni) {
        if (App.Config.MOCK) return App.Api.AgenteMock.avvia(messaggio, conversationId);

        const corpo = {
            message: messaggio,
            conversation_id: conversationId || null
        };
        if (opzioni && opzioni.conferma) corpo.conferma = opzioni.conferma;
        return App.Http.post('/api/ai/turni', corpo);
    },

    // --- un passo: il server chiama il modello ed esegue i tool ---------
    // turno: l'ultima risposta ricevuta dal server. Se ne rimandano gli
    // identificativi COSI' COME SONO (soprattutto passo, che il server
    // confronta con quello atteso per scartare doppi invii).
    async passo(turno) {
        if (App.Config.MOCK) return App.Api.AgenteMock.passo(turno);

        return App.Http.post('/api/ai/turni/passo', {
            conversation_id: turno.conversation_id,
            turno_id: turno.turno_id,
            numero_turno: turno.numero_turno,
            passo: turno.passo
        });
    },

    // --- rinuncia al turno ----------------------------------------------
    // Il server scarta subito il turno invece di aspettarne la scadenza
    // (15 minuti). E' "best effort": se fallisce anche questa chiamata il
    // turno scadra' da solo, quindi l'errore viene ignorato e non si
    // sovrappone a quello vero.
    async annulla(turno) {
        if (App.Config.MOCK || !turno) return;
        try {
            await App.Http.post('/api/ai/turni/annulla', {
                conversation_id: turno.conversation_id,
                turno_id: turno.turno_id
            });
        } catch (e) {
            /* ignorato di proposito */
        }
    },

    // --- invio delle email dell'anteprima --------------------------------
    // NON passa dall'agente: sono le email dell'anteprima, eventualmente
    // corrette a mano dall'utente nel modulo della chat, e devono partire
    // esattamente cosi'. Il server (controllers/uControllerEmail.pas) le
    // invia una per destinatario e risponde
    //   { inviate, non_inviate, dettaglio: [{ email, oggetto, inviata, errore }] }
    // con "dettaglio" nello stesso ordine di "messaggi".
    async inviaEmail(messaggi) {
        if (App.Config.MOCK) {
            return {
                inviate: messaggi.length, non_inviate: 0,
                dettaglio: messaggi.map((m) => ({ email: m.email, oggetto: m.oggetto, inviata: true, errore: '' }))
            };
        }
        return App.Http.post('/api/email/invio', { messaggi: messaggi });
    }
};

/* =====================================================================
   Configurazione del modello (pannello impostazioni della chat).

   Il client puo' vedere e cambiare QUALE modello usa il server, ma la
   configurazione vive nell'ini del server: e' il server a validarla, a
   scriverla e a usarla. Qui si passano solo i valori del form.
     GET  /api/ai/configurazione-llm           -> { endpoint, modello,
                                                   temperatura|null,
                                                   max_token, timeout_ms }
     PUT  /api/ai/configurazione-llm           stesso formato -> salvata
     POST /api/ai/configurazione-llm/modelli   { endpoint } -> { modelli }
   Gli errori (400 indirizzo non ammesso, 502 motore spento...) portano
   gia' il testo da mostrare in errore.dettaglio.
   ===================================================================== */
App.Api.ConfigLLM = {

    async leggi() {
        if (App.Config.MOCK) return App.Api.ConfigLLMMock.leggi();
        return App.Http.get('/api/ai/configurazione-llm');
    },

    async salva(configurazione) {
        if (App.Config.MOCK) return App.Api.ConfigLLMMock.salva(configurazione);
        return App.Http.put('/api/ai/configurazione-llm', configurazione);
    },

    // Chiede al SERVER quali modelli espone il motore a quell'indirizzo:
    // e' il server a contattarlo, non il browser.
    async elencaModelli(endpoint) {
        if (App.Config.MOCK) return App.Api.ConfigLLMMock.elencaModelli(endpoint);
        return App.Http.post('/api/ai/configurazione-llm/modelli', { endpoint: endpoint });
    }
};

// Mock del server per la configurazione (solo in memoria).
App.Api.ConfigLLMMock = {
    _cfg: { endpoint: 'http://localhost:1234/v1', modello: 'google/gemma-4-12b-qat',
            temperatura: 0.2, max_token: 0, timeout_ms: 180000 },

    async leggi() {
        await App.Http.attendi(150);
        return Object.assign({}, this._cfg);
    },

    async salva(c) {
        await App.Http.attendi(200);
        if (!/^https?:\/\/(localhost|127\.|10\.|192\.168\.)/i.test(c.endpoint || '')) {
            throw Object.assign(new Error('HTTP 400'), { status: 400,
                dettaglio: 'Configurazione non valida: l\'indirizzo non e\' di questa macchina ne\' della rete interna.' });
        }
        Object.assign(this._cfg, c, {
            temperatura: c.temperatura === '' || c.temperatura === null ? null : Number(c.temperatura),
            max_token: Number(c.max_token), timeout_ms: Number(c.timeout_ms)
        });
        return Object.assign({}, this._cfg);
    },

    async elencaModelli(endpoint) {
        await App.Http.attendi(300);
        if (!/:1234\b/.test(endpoint || '')) {
            throw Object.assign(new Error('HTTP 502'), { status: 502,
                dettaglio: 'Nessuna risposta da ' + endpoint + '/models. Il motore di inferenza e\' avviato?' });
        }
        return { endpoint: endpoint, modelli: ['google/gemma-4-12b-qat', 'qwen/qwen3.5-9b'] };
    }
};

/* ---------------------------------------------------------------------
   Mock del SERVER (App.Config.MOCK = true): imita il protocollo a passi
   per provare la chat senza backend. Come il server vero, e' lui a
   "chiamare il modello": un copione di tre passi come una richiesta di
   CSV (vendite -> csv -> risposta a parole).
   --------------------------------------------------------------------- */
App.Api.AgenteMock = {

    _turni: {},

    // Cosa "chiede il modello" a ogni passo del copione.
    _copione: [
        { tool: 'get_list_vendite', arguments: { data_inizio: '2026-03-01', data_fine: '2026-03-31' },
          result: { totale_ordini: 14, totale_importo: 118420.5 } },
        { tool: 'generate_csv', arguments: { nome_file: 'vendite_marzo' },
          result: { esito: 'ok', url: '/export/vendite_marzo.csv' } }
    ],

    async avvia(messaggio, conversationId) {
        await App.Http.attendi(200);
        const turno = {
            conversation_id: conversationId || 'mock-conv-1',
            turno_id: 'mock-' + Date.now(),
            numero_turno: 1,
            passo: 1,
            tracce: []
        };
        this._turni[turno.turno_id] = turno;
        return this._rispostaInCorso(turno, []);
    },

    async passo(t) {
        await App.Http.attendi(900);        // il "modello" che pensa
        const turno = this._turni[t.turno_id];
        if (!turno) throw Object.assign(new Error('HTTP 404'), { status: 404,
            dettaglio: 'Il turno e\' scaduto o il server e\' stato riavviato. Ripeti la domanda.' });
        if (turno.passo !== t.passo) throw Object.assign(new Error('HTTP 409'), { status: 409,
            dettaglio: 'Passo non atteso (richiesta duplicata o fuori ordine). Ripeti la domanda.' });

        const voce = this._copione[turno.passo - 1];
        if (voce) {
            const traccia = { tool: voce.tool, arguments: voce.arguments, result: voce.result,
                duration_ms: 412, ok: true };
            turno.tracce.push(traccia);
            turno.passo += 1;
            return this._rispostaInCorso(turno, [traccia]);
        }

        delete this._turni[turno.turno_id];
        return {
            stato: 'concluso',
            conversation_id: turno.conversation_id,
            turno_id: turno.turno_id,
            numero_turno: turno.numero_turno,
            passo: turno.passo,
            agent_response: 'Risposta dimostrativa: ecco il CSV delle vendite di marzo ' +
                '(App.Config.MOCK = true, nessun backend collegato).',
            tool_calls: turno.tracce,
            tool_calls_passo: [],
            diagnostica: {}
        };
    },

    _rispostaInCorso(turno, tracceDelPasso) {
        return {
            stato: 'in_corso',
            conversation_id: turno.conversation_id,
            turno_id: turno.turno_id,
            numero_turno: turno.numero_turno,
            passo: turno.passo,
            fase: turno.passo === 1
                ? 'Il modello sta pensando'
                : 'Il modello sta leggendo i dati (passo ' + turno.passo + ')',
            tool_calls_passo: tracceDelPasso
        };
    }
};
