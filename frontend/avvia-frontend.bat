@echo off
rem =====================================================================
rem  avvia-frontend.bat - serve il frontend su http://localhost:83
rem
rem  Il frontend e' un sito statico (index.html + assets/). Basta un
rem  server web che:
rem    1) serva i file di questa cartella sulla porta 83;
rem    2) per ogni percorso che NON e' un file reale (es. /vendite)
rem       risponda con index.html, cosi' il router JS lato client
rem       disegna la vista giusta. E' lo stesso compito della regola
rem       "SPA fallback" in web.config, che pero' vale solo su IIS.
rem
rem  Requisito: Node.js. Alla prima esecuzione npx scarica il pacchetto
rem  "serve"; l'opzione -s attiva la modalita' single-page (fallback).
rem  Il server (AziendaAlimentareERP.exe) va avviato a parte: il
rem  frontend lo chiama su http://<host>:8080.
rem =====================================================================
cd /d "%~dp0"
echo Frontend in avvio su http://localhost:83  (CTRL+C per fermare)
npx --yes serve -s -l 83 .
pause
