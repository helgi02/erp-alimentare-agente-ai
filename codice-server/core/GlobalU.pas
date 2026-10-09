unit GlobalU;
interface
type
  TTokenValidationResult = (tvrValid, tvrMissing, tvrExpired,
                            tvrInvalid, tvrDecodedInvalid, tvrError);
const
  // Origin autorizzati dal middleware CORS (uWebModule.pas).
  // '*' dal 29/09/2026: il frontend viene aperto anche da telefono via
  // hotspot, con un origin del tipo http://<IP del portatile>:83 che
  // cambia a ogni rete. SOLO PER SVILUPPO/DEMO: in produzione tornare a
  // un elenco esplicito (vedi sviluppi-futuri_autenticazione-sicurezza).
  // Valore precedente: 'http://localhost:83'
  GUrl: String = '*';
  COOKIE_ADMIN_SESSION = 'cluster_affinity';
  SESSION_TTL_SHORT  = 8 * 3600;
  SESSION_TTL_LONG   = 30 * 86400;


implementation

end.
