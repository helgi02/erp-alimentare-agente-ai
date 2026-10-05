# erp-alimentare-agente-ai

Integrazione di un agente AI in un gestionale per l'industria alimentare, prendendo come riferimento il Model Context Protocol (MCP) per la definizione dei tool. Tirocinio triennale, A.A. 2026/2027.

Questo repository contiene quanto serve per **provare** il sistema: frontend, database di test, configurazione di esempio e documentazione. Il server (eseguibile Windows a 64 bit) si scarica dalla sezione **Releases**.

## Come funziona

L'utente scrive in chat nel frontend. Il server (Delphi, DMVCFramework, PostgreSQL) invia la richiesta e le definizioni dei tool a un modello linguistico **locale** tramite un'API compatibile OpenAI. Il modello sceglie quali tool usare, il server li esegue sul database e restituisce i risultati al modello, che scrive la risposta in linguaggio naturale. Il modello non accede mai direttamente al database e nessun dato aziendale lascia l'infrastruttura locale. Gli schemi in `docs/` mostrano il flusso.

Scenari implementati: (1) ritiro/richiamo di prodotti non conformi con generazione dei documenti di compliance, (2) interrogazione ad hoc dei dati di vendita, (3) adattamento di ricette su richiesta del cliente con calcolo economico.

## Requisiti

- Windows 64 bit
- PostgreSQL 17 con l'estensione **pgvector** installata (il dump contiene `CREATE EXTENSION vector`)
- Un server di inferenza con API compatibile OpenAI, per esempio Unsloth o LM Studio, con un modello di chat che supporti la chiamata di tool, caricato con almeno circa 16000 token di contesto
- Un modello di embedding: `text-embedding-multilingual-e5-large-instruct` (dimensione 1024). L'indice dei tool nel database è stato costruito con questo modello, quindi un modello diverso darebbe una selezione dei tool sbagliata
- Node.js, solo per servire il frontend con `frontend/avvia-frontend.bat` (in alternativa qualunque server web statico con fallback su `index.html`)

## Installazione

**1. Database.** Dalla cartella del repository:

```
psql -U postgres -c "CREATE DATABASE azienda_alimentare_erp"
pg_restore -U postgres -d azienda_alimentare_erp --no-owner --no-privileges database/azienda_alimentare_erp.dump
```

Il file `.dump` è in formato custom di `pg_dump` (PostgreSQL 17): va aperto con `pg_restore` di versione 17 o superiore, non con `psql`. Contiene solo dati di test.

**2. Server.** Scarica da Releases lo zip `AziendaAlimentareERP-win64` e scompattalo in una cartella. Copia `config/AziendaAlimentareERP.ini.example` accanto all'eseguibile, rinominalo `AziendaAlimentareERP.ini` e compila:

- `[Database]`: password dell'utente PostgreSQL
- `[LLM]`: `ChatEndpoint` (indirizzo del server di inferenza) e `ChatModel` (id del modello come compare in `<ChatEndpoint>/models`)
- `[Embedding]`: endpoint e modello di embedding (vedi sopra)
- `[SMTP]`: lasciare `Simula=1`. Con questa impostazione nessuna email parte davvero: ogni invio viene scritto in `logs\email_simulate.jsonl`

**3. Avvio.** Esegui `AziendaAlimentareERP.exe` (di default ascolta sulla porta 8080). Windows potrebbe mostrare l'avviso SmartScreen perché l'eseguibile non è firmato: *Ulteriori informazioni → Esegui comunque*.

**4. Frontend.** Esegui `frontend/avvia-frontend.bat` e apri <http://localhost:83>. Il frontend chiama il server su `http://<host>:8080`.

## Come provare

Nella chat del frontend, per esempio (le domande sono solo spunti):

- *Vendite:* "Mostrami le vendite di febbraio 2026" oppure "Quanto abbiamo venduto di torta caprese a marzo?"
- *Ritiro/richiamo:* segnala un lotto di materia prima non conforme (ad esempio positivo alla Salmonella) e chiedi quali lotti di prodotto finito e quali clienti sono coinvolti; l'agente propone i documenti e le email e chiede conferma prima di scrivere
- *Ricette:* chiedi di adattare una ricetta (sostituendo o aggiungendo un ingrediente) e di calcolarne il costo

Le azioni che modificano i dati chiedono sempre una conferma esplicita. Le email non vengono inviate finché `Simula=1`.

## Contenuto del repository

```
config/      AziendaAlimentareERP.ini.example   configurazione di esempio
database/    azienda_alimentare_erp.dump        database di test (pg_dump, formato custom)
frontend/    sito statico + avvia-frontend.bat
docs/        schemi di flusso e documento di riferimento sul richiamo
```
