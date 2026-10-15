# erp-alimentare-agente-ai

Integrazione di un agente AI in un gestionale per l'industria alimentare, prendendo come riferimento il Model Context Protocol (MCP) per la definizione dei tool. Tirocinio triennale, A.A. 2026/2027.

Questo repository contiene quanto serve per **provare** il sistema: server (eseguibile Windows a 64 bit con le DLL necessarie, cartella `server/`), frontend, database di test e configurazione di esempio. I sorgenti Delphi del server sono in `codice-server/`.

## Come funziona

L'utente scrive in chat nel frontend. Il server (Delphi, DMVCFramework, PostgreSQL) invia la richiesta e le definizioni dei tool a un modello linguistico **locale** tramite un'API compatibile OpenAI. Il modello sceglie quali tool usare, il server li esegue sul database e restituisce i risultati al modello, che scrive la risposta in linguaggio naturale. Il modello non accede mai direttamente al database e nessun dato aziendale lascia l'infrastruttura locale.

Scenari implementati: (1) ritiro/richiamo di prodotti non conformi con generazione dei documenti di compliance, (2) interrogazione ad hoc dei dati di vendita, (3) adattamento di ricette su richiesta del cliente con calcolo economico.

## Requisiti

- Windows 64 bit
- PostgreSQL 17 con l'estensione **pgvector** disponibile (il dump contiene `CREATE EXTENSION vector`). Per verificarlo, da pgAdmin (Query Tool): `SELECT * FROM pg_available_extensions WHERE name = 'vector';`. Se non restituisce righe, pgvector va installato: su Windows con Application Stack Builder (installato insieme a PostgreSQL) oppure con i pacchetti precompilati indicati su GitHub (pgvector)
- Un server di inferenza con API compatibile OpenAI, per esempio Unsloth o LM Studio, con un modello di chat che supporti la chiamata di tool, caricato con almeno 16384 token di contesto
- Un modello di embedding: `text-embedding-multilingual-e5-large-instruct` (dimensione 1024). L'indice dei tool nel database è stato costruito con questo modello, quindi un modello diverso darebbe una selezione dei tool sbagliata (vedi "Modelli usati nei test")
- Node.js, solo per servire il frontend con `frontend/avvia-frontend.bat` (in alternativa qualunque server web statico con fallback su `index.html`)

## Installazione

**1. Database.** Dalla cartella del repository:

```
psql -U postgres -c "CREATE DATABASE azienda_alimentare_erp"
pg_restore -U postgres -d azienda_alimentare_erp --no-owner --no-privileges database/azienda_alimentare_erp.dump
```

Il file `.dump` è in formato custom di `pg_dump` (PostgreSQL 17): va aperto con `pg_restore` di versione 17 o superiore, non con `psql`. Contiene solo dati di test. Il ripristino crea anche l'estensione `vector` e la tabella `mcp_tool_indice` con l'indice dei tool già calcolato.

In alternativa, da pgAdmin: creare il database `azienda_alimentare_erp` vuoto, poi clic destro sul database → *Restore…*, formato *Custom or tar*, selezionare `database/azienda_alimentare_erp.dump` e, nelle opzioni, attivare *Do not save: Owner* e *Privileges*.

**2. Server.** Nella cartella `server/` copia `AziendaAlimentareERP.ini.example` come `AziendaAlimentareERP.ini` (accanto all'eseguibile) e compila:

- `[Database]`: password dell'utente PostgreSQL
- `[LLM]`: `ChatEndpoint` (indirizzo del server di inferenza) e `ChatModel` (id del modello come compare in `<ChatEndpoint>/models`)
- `[Embedding]`: endpoint e modello di embedding (vedi sopra)
- `[SMTP]`: lasciare `Simula=1`. Con questa impostazione nessuna email parte davvero: ogni invio viene scritto in `logs\email_simulate.jsonl`

**3. Avvio.** Esegui `server/AziendaAlimentareERP.exe` (di default ascolta sulla porta 8080). Windows potrebbe mostrare l'avviso SmartScreen perché l'eseguibile non è firmato: *Ulteriori informazioni → Esegui comunque*.

**4. Frontend.** Esegui `frontend/avvia-frontend.bat` e apri <http://localhost:83>. Il frontend chiama il server su `http://<host>:8080`. In alternativa si può servire la cartella `frontend/` con IIS: serve il modulo URL Rewrite 2.1, la cui regola di fallback è già in `web.config`.

Il frontend è un'applicazione a pagina singola: un solo `index.html` contiene la cornice fissa (sidebar, area centrale a schede, pannello della chat con l'agente). Le schermate sono *viste*: ciascuna è un file in `assets/js/views/` che si registra presso il router (`assets/js/core/router.js`). Il router usa la History API, quindi ogni schermata ha un URL vero (`/vendite`, `/lotti/871`) e cambiando URL viene disegnata la vista corrispondente senza ricaricare la pagina; i dati arrivano dal server tramite i moduli in `assets/js/api/`. Per questo il server web deve rispondere con `index.html` a ogni percorso che non è un file reale; grazie agli URL veri l'agente può inserire in chat link diretti alle schermate del gestionale.

## Modelli usati nei test

| Ruolo | Modello (LM Studio) | File / quantizzazione | Note |
|---|---|---|---|
| Chat | `qwen/qwen3.5-9b` | `Qwen3.5-9B-Q4_K_M.gguf`, Q4_K_M | contesto 16384 |
| Embedding | `Ralriki/multilingual-e5-large-instruct-GGUF` | `multilingual-e5-large-instruct-q8_0.gguf`, Q8_0 | 1024 dimensioni; in LM Studio compare come `text-embedding-multilingual-e5-large-instruct` |

Valori usati in `[LLM]`: `Temperatura=0.2`, `MaxToken=2048`, `PresencePenalty=1.0`, `Pensiero=0`; in `[Orchestratore]`: `Motore=pianificatore`.

**Configurazione di LM Studio.** Per ogni modello con modalità di ragionamento (es. Qwen3.5), disattivare *Enable Thinking* nelle impostazioni del modello prima dell'uso. Con l'opzione attiva il modello consuma i token nel ragionamento e può restituire una risposta vuota: in quel caso l'assistente risponde che non riesce a costruire un piano valido.

I vettori dell'indice dei tool nel dump sono stati calcolati con il modello di embedding indicato. A ogni avvio il server sincronizza l'indice riusando i vettori già presenti, riconosciuti dall'hash del testo e dal *nome* del modello, che però non distingue publisher e quantizzazione. Usando un'altra versione di multilingual-e5-large-instruct, eseguire prima del primo avvio `TRUNCATE mcp_tool_indice;`: il server ricalcolerà l'indice con il modello configurato.

## Come provare

Nella chat del frontend, per esempio (le domande sono solo spunti):

- *Vendite:* "Mostrami le vendite di febbraio 2026" oppure "Quanto abbiamo venduto di torta caprese a marzo?"
- *Ritiro/richiamo:* segnala un lotto di materia prima non conforme (ad esempio positivo alla Salmonella) e chiedi quali lotti di prodotto finito e quali clienti sono coinvolti; l'agente propone i documenti e le email e chiede conferma prima di scrivere
- *Ricette:* chiedi di adattare una ricetta (sostituendo o aggiungendo un ingrediente) e di calcolarne il costo

Le azioni che modificano i dati chiedono sempre una conferma esplicita. Le email non vengono inviate finché `Simula=1`.

## Contenuto del repository

```
server/         AziendaAlimentareERP.exe, DLL, AziendaAlimentareERP.ini.example, SHA256SUMS.txt
database/       azienda_alimentare_erp.dump   database di test (pg_dump, formato custom)
frontend/       sito statico + avvia-frontend.bat
codice-server/  sorgenti Delphi del server (facoltativo)
```

## Codice sorgente del server (facoltativo)

La cartella `codice-server/` contiene il progetto Delphi (VCL, DMVCFramework, FireDAC con PostgreSQL) da cui è stato compilato l'eseguibile in `server/`. Serve solo per leggere o ricompilare il codice.

```
codice-server/
  AziendaAlimentareERP.dpr / .dproj    progetto (piattaforma Win64)
  uFrmMain, uWebModule                 finestra principale e modulo web
  agente_ai/                           agente: 1_turno, 2_piano, 3_scelta_tool, 4_controlli,
                                       5_esecuzione, 6_risposta, modello, tool (tool MCP)
  controllers/                         endpoint REST e controller dell'agente
  services/                            logica di business
  models/                              classi ActiveRecord, una per tabella
  common/, core/                       configurazione, log, accesso al database
  librerie/                            librerie di terze parti, solo sorgenti, con le loro licenze
```

Librerie incluse, ciascuna con la propria licenza: DMVCFramework con dmustache, LoggerPro e SwagDoc (Apache 2.0), mcp-server-delphi, SynPDF (MPL/GPL/LGPL). I percorsi di ricerca nel `.dproj` sono relativi alla cartella `librerie/`.

Per ricompilare: apri `AziendaAlimentareERP.dproj` in Delphi (ProjectVersion 20.5 nel file), scegli la piattaforma **Win64** e compila. L'IDE rigenera da solo il file `.res`. Per eseguire il risultato servono accanto all'eseguibile le DLL presenti in `server/` (in particolare `libpq.dll`) e il file `.ini` descritto sopra. Il codice è commentato in italiano.

