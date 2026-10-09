unit GlobalU;
interface
type
  TTokenValidationResult = (tvrValid, tvrMissing, tvrExpired,
                            tvrInvalid, tvrDecodedInvalid, tvrError);
const
  // Origin autorizzati dal middleware CORS (uWebModule.pas). '*' perche' il frontend si
  // apre anche da altri dispositivi, con un origin che cambia a ogni rete. Solo
  // sviluppo/demo: in produzione usare un elenco esplicito.
  GUrl: String = '*';
  COOKIE_ADMIN_SESSION = 'cluster_affinity';
  SESSION_TTL_SHORT  = 8 * 3600;
  SESSION_TTL_LONG   = 30 * 86400;


implementation

end.
