/*
 * vpnshim.cpp  —  Microsoft Azure VPN headless shim (C++ versie)
 *
 * Bevindingen uit binary-analyse:
 *   1. `connectionManager` is een geëxporteerd BSS-symbool: de global singleton ptr
 *   2. `connectAadProfile(C-fn)` neemt 3 args: (profileName, username, token)
 *      en vergelijkt arg1 via strcmp met ConnectionManager::getProfileName()
 *   3. `setXmlProfileData` is een C++ methode op de singleton (std::string arg)
 *
 * Call-volgorde:
 *   initConnection(logCb, statusCb, disconnectCb, NULL)
 *     → vult `connectionManager` BSS-slot met de C++ singleton pointer
 *   setPlatformInfo("0.1", "AzMac", "x64", "")
 *     → zet IV_PLAT=AzMac in OpenVPN peer-info
 *   [ConnectionManager*].setXmlProfileData(xml)
 *     → laadt gateway FQDN + AAD-config in de singleton
 *   connectAadProfile("<profile-name>", "AzureAD", token)
 *     → OpenVPN verbinding + AAD-authenticatie
 */

#define _GNU_SOURCE
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <dlfcn.h>
#include <unistd.h>
#include <csignal>
#include <string>
#include <pthread.h>
#include <dirent.h>

/* Achtergrond-thread die de cert-path global continu forceert naar het gewenste
 * pad. connectAadProfile reset de global (uit het profiel, leeg) vlak voor de
 * worker-thread loadCerts draait; deze thread wint die race. */
static volatile char *g_cert_global = nullptr;
static char g_cert_path[64] = "/dr.pem";
static void *repatch_thread(void *) {
    while (true) {
        char *g = (char*)g_cert_global;
        if (g) {
            size_t n = strlen(g_cert_path);
            if (n <= 15) {
                char *inl = g + 16;
                memcpy(inl, g_cert_path, n + 1);
                *(size_t*)(g + 8) = n;
                *(char**)(g + 0) = inl;
            }
        }
        usleep(150);  /* 0.15 ms */
    }
    return nullptr;
}

#define LIBPATH  "/opt/microsoft/lib/libLinuxCore.so"

#define TENANT_DEFAULT   ""
#define CLIENT_DEFAULT   "41b23e61-6c1e-4545-b367-cd054e0ed4b4"
#define GATEWAY_DEFAULT  ""
#define PROFILE_DEFAULT  ""

/* Fallback XML wordt alleen gebruikt als PROFILE_XML niet gezet is — per profiel ingebouwde waarden. */
static std::string build_fallback_xml(const char *profile_name, const char *gateway,
                                      const char *client,  const char *tenant,
                                      const char *authority) {
    std::string s;
    s += "<AzureVpnProfile>";
    s += "<clientconfig><dnsservers/><dnssuffixes/></clientconfig>";
    s += "<serverlist><ServerEntry>";
    s += "<displayname>"; s += profile_name; s += "</displayname>";
    s += "<fqdn>"; s += gateway; s += "</fqdn>";
    s += "</ServerEntry></serverlist>";
    s += "<protoconfig><protocol>TCP</protocol></protoconfig>";
    s += "<clientauth><type>AAD</type><aad>";
    s += "<audience>"; s += client; s += "</audience>";
    s += "<issuer>https://sts.windows.net/"; s += tenant; s += "/</issuer>";
    s += "<tenant>"; s += authority; s += "/</tenant>";
    s += "</aad></clientauth>";
    s += "</AzureVpnProfile>";
    return s;
}

/* ── Stub callbacks ─────────────────────────────────────────────────────── */

extern "C" {
    static void log_cb(int level, const char *msg) {
        fprintf(stderr, "[lib log %d] %s\n", level, msg ? msg : "(null)");
    }
    static void status_cb(int status, const char *msg) {
        fprintf(stderr, "[lib status %d] %s\n", status, msg ? msg : "(null)");
    }
    static void disconnect_cb(int reason) {
        fprintf(stderr, "[lib disconnect reason=%d]\n", reason);
    }
}

/* ── CGo return types ───────────────────────────────────────────────────── */

/* Go string: 16 bytes → returned in rax:rdx (two registers, ≤16 bytes) */
typedef struct { const char *ptr; size_t len; } GoString;

/* 24-byte return struct → hidden ptr in rdi (first arg), args shift to rsi/rdx/rcx */
typedef struct {
    GoString token;   /* 16 bytes */
    int64_t  errcode; /*  8 bytes */
} AcquireResult;

/* ── Functie-pointers ───────────────────────────────────────────────────── */

static void  (*fn_initAAD)(const char*, const char*, const char*);
/* initConnection: neemt strings, geen callbacks (bevestigd via disassembly)
 * Meest waarschijnlijke signature op basis van strlen-calls en ConnectionManager
 * constructor: (profileName, gatewayFQDN, authority, int)                   */
static void  (*fn_initConnection)(const char*, const char*, const char*, int);
static void  (*fn_setPlatformInfo)(const char*, const char*, const char*, const char*);

/* connectAadProfile: 3 args: (profileName, cacheJSON, username) */
static char *(*fn_connectAadProfile)(const char*, const char*, const char*);

/* C++ member: setXmlProfileData(std::string) — called on ConnectionManager* */
static void  (*fn_setXmlProfileData)(void*, const std::string&);

/* C++ member: loadCerts(std::string path) — laadt trusted CA-certs uit een bestand.
 * RETOURNEERT een 24-byte object (vector<CertificateData>) → hidden return-ptr in rdi,
 * dus ABI = (rdi=&ret, rsi=this, rdx=&path). Declareer als struct-return zodat de
 * compiler de hidden pointer regelt. Zonder loadCerts: "no certificates were passed". */
struct CertVec24 { char _[24]; };
static CertVec24 (*fn_loadCerts)(void* thisptr, const std::string& path);

static void  (*fn_getConnectionStatus)(char*);
static char *(*fn_getFailureMessage)(void);
static void  (*fn_disconnectProfile)(void);
/* startDataPath: 0 args; start de data-path pump-thread zodra status==6 (Connected) */
static void  (*fn_startDataPath)(void);

/* ConnectionManager::isTunConnected() — leest een bool-vlag op de singleton.
 * getStatus() roept disconnectVpnProfile() aan als status==6 & !isTunConnected → no-op startDataPath. */
static bool  (*fn_isTunConnected)(void*);
/* ConnectionManager::getStatus(char*) — let op: side-effect (disconnect) als tun niet connected! */
static int   (*fn_getStatus)(void*, char*);

/* getCache: 0 args, returns GoString (16 bytes, rax:rdx) */
static GoString (*fn_getCache)(void);

/* acquireTokenSilently: 3 C-string args, returns AcquireResult via hidden ptr */
static AcquireResult (*fn_acquireTokenSilently)(const char*, const char*, const char*);

/* acquireTokenInteratively (library typo!): 2 C-string args */
static AcquireResult (*fn_acquireTokenInteratively)(const char*, const char*);

/* ── Hulpfuncties ───────────────────────────────────────────────────────── */

static void *resolve(void *lib, const char *name) {
    dlerror();
    void *sym = dlsym(lib, name);
    const char *err = dlerror();
    if (err)
        fprintf(stderr, "[shim] '%s': niet gevonden\n", name);
    else
        fprintf(stderr, "[shim] '%s': %p OK\n", name, sym);
    return sym;
}

static void dump_cache(const char *label) {
    if (!fn_getCache) return;
    GoString gs = fn_getCache();
    if (!gs.ptr) {
        fprintf(stderr, "[cache:%s] (leeg)\n", label);
        return;
    }
    /* getCache geeft een null-terminated char* terug; gs.len is onbetrouwbaar
     * (cgo-export geeft *C.char, niet echt een Go-string). Gebruik strlen. */
    size_t len = strnlen(gs.ptr, 1u << 20);   /* cap 1 MB */
    if (len == 0) {
        fprintf(stderr, "[cache:%s] (leeg)\n", label);
        return;
    }
    fprintf(stderr, "[cache:%s] len=%zu (eerste 200): %.200s\n", label, len, gs.ptr);
    /* Volledige cache naar bestand schrijven indien CACHE_OUT gezet */
    const char *out = getenv("CACHE_OUT");
    if (out && *out) {
        FILE *f = fopen(out, "wb");
        if (f) {
            fwrite(gs.ptr, 1, len, f);
            fclose(f);
            fprintf(stderr, "[cache:%s] -> %s (%zu bytes geschreven)\n", label, out, len);
        } else {
            fprintf(stderr, "[cache:%s] kan %s niet schrijven\n", label, out);
        }
    }
}

static void try_acquire_silent(const char *label, const char *a, const char *b, const char *c) {
    if (!fn_acquireTokenSilently) return;
    fprintf(stderr, "[silent:%s] acquireTokenSilently('%s','%s','%s')...\n", label, a, b, c);
    AcquireResult ar = fn_acquireTokenSilently(a, b, c);
    fprintf(stderr, "[silent:%s] token.len=%zu, errcode=%ld\n", label, ar.token.len, (long)ar.errcode);
    if (ar.token.len > 0 && ar.token.ptr) {
        int show = (int)ar.token.len < 200 ? (int)ar.token.len : 200;
        fprintf(stderr, "[silent:%s] token: %.*s%s\n", label, show, ar.token.ptr,
                ar.token.len > 200 ? "..." : "");
    }
}

/* ── Signaalafhandeling ─────────────────────────────────────────────────── */

static volatile int g_running = 1;
static void on_signal(int sig) {
    fprintf(stderr, "\n[shim] signaal %d, verbreken...\n", sig);
    g_running = 0;
}

/* ── main ───────────────────────────────────────────────────────────────── */

int main(void) {
    const char *token = getenv("VPN_TOKEN");
    if (!token || !*token) {
        fprintf(stderr, "[shim] FOUT: VPN_TOKEN niet gezet\n");
        return 1;
    }
    fprintf(stderr, "[shim] token lengte=%zu\n", strlen(token));

    /* Profielwaarden: env vars > compile-time defaults */
    const char *env_profile = getenv("VPN_PROFILE");
    const char *env_gateway = getenv("VPN_GATEWAY");
    const char *env_tenant  = getenv("VPN_TENANT");
    const char *env_client  = getenv("VPN_CLIENT");
    const char *active_profile = (env_profile && *env_profile) ? env_profile : PROFILE_DEFAULT;
    const char *active_gateway = (env_gateway && *env_gateway) ? env_gateway : GATEWAY_DEFAULT;
    const char *active_tenant  = (env_tenant  && *env_tenant)  ? env_tenant  : TENANT_DEFAULT;
    const char *active_client  = (env_client  && *env_client)  ? env_client  : CLIENT_DEFAULT;
    char authority_buf[256];
    snprintf(authority_buf, sizeof(authority_buf),
             "https://login.microsoftonline.com/%s", active_tenant);
    const char *active_authority = authority_buf;
    fprintf(stderr, "[shim] profiel='%s' gateway='%s' tenant='%s' client='%s'\n",
            active_profile, active_gateway, active_tenant, active_client);

    /* Laad bibliotheek */
    void *lib = dlopen(LIBPATH, RTLD_LAZY | RTLD_GLOBAL);
    if (!lib) {
        fprintf(stderr, "[shim] dlopen mislukt: %s\n", dlerror());
        return 1;
    }
    fprintf(stderr, "[shim] dlopen OK\n\n");

    /* ── Cert-prefix global patchen ─────────────────────────────────────────
     * loadCerts() bouwt het pad als global("/etc/ssl/certs/") + filename. Voor
     * AAD is de filename leeg → opent de directory → "no certificates passed".
     * We overschrijven de global-std::string (s_PLATFORM+0x700) naar een
     * volledig pad naar de DigiCert-root, zodat de interne loadCerts (lege
     * filename) dat bestand opent. SSO: pad moet ≤15 chars zijn. */
    {
        /* base berekenen via een export met bekende file-vaddr (connectAadProfile @ 0xb1d00),
         * dan de cert-path global op file-vaddr 0x779fc0 patchen. */
        void *anchor = dlsym(lib, "connectAadProfile");   /* file vaddr 0xb1d00 */
        const char *newpath = getenv("CERT_PREFIX");   /* alleen patchen als expliciet gezet */
        size_t n = newpath ? strlen(newpath) : 0;
        if (anchor && newpath && *newpath && n <= 15) {
            uintptr_t base = (uintptr_t)anchor - 0xb1d00;
            char *g = (char*)(base + 0x779fc0);   /* cert-path global std::string */
            fprintf(stderr, "[shim] base=%#lx, global@%p, oud='%.20s' (len=%zu)\n",
                    (unsigned long)base, (void*)g, *(char**)(g), *(size_t*)(g+8));
            char *inl = g + 16;                    /* _M_local_buf (SSO) */
            memcpy(inl, newpath, n + 1);
            *(size_t*)(g + 8) = n;                 /* _M_string_length */
            *(char**)(g + 0) = inl;                /* _M_p → inline (SSO) */
            fprintf(stderr, "[shim] cert-prefix global gepatcht -> '%s'\n", newpath);
            /* start re-patch thread die de global blijft forceren (race vs connectAadProfile) */
            strncpy(g_cert_path, newpath, sizeof(g_cert_path)-1);
            g_cert_global = g;
            pthread_t th;
            pthread_create(&th, nullptr, repatch_thread, nullptr);
            fprintf(stderr, "[shim] re-patch thread gestart\n");
        } else {
            fprintf(stderr, "[shim] cert-prefix NIET gepatcht (anchor=%p len=%zu)\n", anchor, n);
        }
    }

    /* Symbolen */
    fn_initAAD            = (void(*)(const char*,const char*,const char*))
                             resolve(lib, "initAAD");
    fn_initConnection     = (void(*)(const char*,const char*,const char*,int))
                             resolve(lib, "initConnection");
    fn_setPlatformInfo    = (void(*)(const char*,const char*,const char*,const char*))
                             resolve(lib, "setPlatformInfo");
    fn_connectAadProfile  = (char*(*)(const char*,const char*,const char*))
                             resolve(lib, "connectAadProfile");
    fn_setXmlProfileData  = (void(*)(void*,const std::string&))
                             resolve(lib,
                               "_ZN17ConnectionManager17setXmlProfileDataENSt7__cxx11"
                               "12basic_stringIcSt11char_traitsIcESaIcEEE");
    fn_loadCerts          = (CertVec24(*)(void*,const std::string&))
                             resolve(lib,
                               "_ZN17ConnectionManager9loadCertsENSt7__cxx11"
                               "12basic_stringIcSt11char_traitsIcESaIcEEE");
    fn_getConnectionStatus= (void(*)(char*))
                             resolve(lib, "getConnectionStatus");
    fn_getFailureMessage  = (char*(*)(void))
                             resolve(lib, "getFailureMessage");
    fn_disconnectProfile  = (void(*)(void))
                             resolve(lib, "disconnectProfile");
    fn_startDataPath      = (void(*)(void))
                             resolve(lib, "startDataPath");
    fn_isTunConnected     = (bool(*)(void*))
                             resolve(lib, "_ZN17ConnectionManager14isTunConnectedEv");
    fn_getStatus          = (int(*)(void*,char*))
                             resolve(lib, "_ZN17ConnectionManager9getStatusEPc");
    fn_getCache           = (GoString(*)(void))
                             resolve(lib, "getCache");
    fn_acquireTokenSilently = (AcquireResult(*)(const char*,const char*,const char*))
                             resolve(lib, "acquireTokenSilently");
    fn_acquireTokenInteratively = (AcquireResult(*)(const char*,const char*))
                             resolve(lib, "acquireTokenInteratively");
    fprintf(stderr, "\n");

    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);

    /* ── 1. ConnectionManager init ────────────────────────────────────── */
    /* initAAD moet NA initConnection zodat initAAD de AadConfig kan zetten
     * op de al-bestaande ConnectionManager. Als ConnectionManager+0x10 NULL
     * is bij connectAadProfile → direct "Authorization failed."            */
    fprintf(stderr, "[shim] initConnection(\"%s\", \"%s\", \"%s\", 0)...\n",
            active_profile, active_gateway, active_authority);
    if (fn_initConnection)
        fn_initConnection(active_profile, active_gateway, active_authority, 0);
    sleep(1);  /* geef Go runtime tijd om ConnectionManager te initialiseren */

    /* ── 2. AAD/MSAL init (NA initConnection!) ─────────────────────────── */
    if (fn_initAAD) {
        fprintf(stderr, "[shim] initAAD...\n");
        fn_initAAD(active_client, active_authority, active_client);
    }
    dump_cache("na-initAAD");

    /* ── 3. Singleton ophalen + XML-profiel laden ───────────────────────── */
    /* connectionManager is een geëxporteerd BSS-symbool: dlsym geeft het
     * adres van de pointer-variabele zelf. Na initConnection is *slot != NULL. */
    void **conn_mgr_slot = (void**)dlsym(lib, "connectionManager");
    fprintf(stderr, "[shim] connectionManager slot: %p\n", (void*)conn_mgr_slot);
    if (conn_mgr_slot) {
        void *mgr = *conn_mgr_slot;
        fprintf(stderr, "[shim] ConnectionManager*: %p\n", mgr);
        /* Optionele expliciete loadCerts (alleen als CA_CERTS gezet). Normaliter
         * regelt de global-patch + interne loadCerts dit. */
        const char *capath = getenv("CA_CERTS");
        if (mgr && fn_loadCerts && capath && *capath) {
            std::string cp(capath);
            fprintf(stderr, "[shim] loadCerts(\"%s\")...\n", capath);
            CertVec24 r = fn_loadCerts(mgr, cp);
            (void)r;
            fprintf(stderr, "[shim] loadCerts klaar\n");
        }
        if (mgr && fn_setXmlProfileData) {
            /* Echt profiel via env PROFILE_XML (anders dynamische fallback op basis van active_* vars) */
            const char *envxml = getenv("PROFILE_XML");
            std::string xml(envxml && *envxml
                ? envxml
                : build_fallback_xml(active_profile, active_gateway,
                                     active_client, active_tenant, active_authority));
            fprintf(stderr, "[shim] setXmlProfileData(xml, %zu bytes, bron=%s)...\n",
                    xml.size(), (envxml && *envxml) ? "PROFILE_XML" : "ingebouwd");
            fn_setXmlProfileData(mgr, xml);
            fprintf(stderr, "[shim] setXmlProfileData klaar\n");
        } else {
            fprintf(stderr, "[shim] WAARSCHUWING: mgr=%p fn=%p\n",
                    mgr, (void*)fn_setXmlProfileData);
        }
    }

    /* ── 4. Platform-info (IV_PLAT=AzMac) ──────────────────────────────── */
    if (fn_setPlatformInfo) {
        fprintf(stderr, "[shim] setPlatformInfo...\n");
        fn_setPlatformInfo("0.1", "AzMac", "x64", "");
    }

    /* ── Diagnose: inspecteer ConnectionManager velden (SHIM_DIAG=1) ──────── */
    if (getenv("SHIM_DIAG") && conn_mgr_slot && *conn_mgr_slot) {
        uintptr_t *cm = (uintptr_t*)*conn_mgr_slot;
        fprintf(stderr, "[shim] CM+0x00 (vtable?): %p\n", (void*)cm[0]);
        fprintf(stderr, "[shim] CM+0x08:            %p\n", (void*)cm[1]);
        fprintf(stderr, "[shim] CM+0x10:            %p\n", (void*)cm[2]);
        fprintf(stderr, "[shim] CM+0x18:            %p\n", (void*)cm[3]);
        fprintf(stderr, "[shim] CM+0x20:            %p\n", (void*)cm[4]);
    }

    /* ── 5. Verbinden ──────────────────────────────────────────────────── */
    /* Noot: acquireTokenSilently direct aanroepen crasht (nil logrus logger).
     * Die fn is alleen veilig vanuit connectAadProfile-context.              */
    /* 3e param: account-identifier voor de silent acquire. Standaard "AzureAD",
     * maar via AAD_USERNAME kan het echte account (bv. UPN) worden meegegeven. */
    const char *aad_user = getenv("AAD_USERNAME");
    if (!aad_user || !*aad_user) aad_user = "AzureAD";
    fprintf(stderr, "\n[shim] connectAadProfile(\"%s\", <cacheJSON/token>, \"%s\")...\n",
            active_profile, aad_user);
    fprintf(stderr, "[shim] VPN_TOKEN (eerste 120 bytes): %.120s\n", token);
    if (!fn_connectAadProfile) {
        fprintf(stderr, "[shim] FOUT: connectAadProfile niet gevonden\n");
        dlclose(lib);
        return 1;
    }
    char *result = fn_connectAadProfile(active_profile, token, aad_user);
    if (result && *result)
        fprintf(stderr, "[shim] terugkeer: %s\n", result);
    else
        fprintf(stderr, "[shim] terugkeer: (leeg — async verbinding gestart)\n");
    dump_cache("na-connectAadProfile");

    /* ── 6. Data-path starten VOOR status-poll ──────────────────────────────
     * KRITIEK: getConnectionStatus verbreekt de VPN als status==6 (OpenVPN
     * connected) maar de tun nog niet verbonden is ("Tun is disconnected but
     * OpenVPN is connected. Disconnecting OpenVPN"). Dus eerst startDataPath
     * (verbindt de tun via de pump-thread), DAN pas status pollen. */
    fprintf(stderr, "\n[shim] wachten op rawStatus==6 (OpenVPN connected)...\n");

    /* Poll rawStatus direct (zonder getStatus(), die heeft een disconnect-side-effect).
     * status==6 = OpenVPN connected. Zodra bereikt, pump direct starten. SHIM_DIAG=1
     * voor uitgebreide per-seconde diag-output. */
    {
        void *mgr = conn_mgr_slot ? *conn_mgr_slot : nullptr;
        bool status6 = false;
        for (int i = 0; i < 30 && g_running; i++) {
            int raw = mgr ? *(volatile int*)mgr : -1;
            if (getenv("SHIM_DIAG")) {
                int tun = (mgr && fn_isTunConnected) ? (fn_isTunConnected(mgr) ? 1 : 0) : -1;
                fprintf(stderr, "[diag %02ds] rawStatus=%d isTunConnected=%d\n", i, raw, tun);
            }
            if (raw == 6) { status6 = true; break; }
            sleep(1);
        }
        if (status6)
            fprintf(stderr, "[shim] rawStatus==6 bereikt, pump starten\n");
        else
            fprintf(stderr, "[shim] WAARSCHUWING: rawStatus==6 niet bereikt binnen 30s\n");
    }

    auto count_threads = []() -> int {
        int n = 0; DIR *d = opendir("/proc/self/task");
        if (d) { struct dirent *e; while ((e = readdir(d))) if (e->d_name[0] != '.') n++; closedir(d); }
        return n;
    };

    /* startDataPath no-opt headless: gate (interne string::compare mismatch) faalt altijd.
     * Pump-thread-body FUN_001b0ec0 (file-vaddr 0xb0ec0) direct in pthread draaien —
     * exact wat startDataPath's std::thread doet. Adres via connectAadProfile (0xb1d00). */
    static void (*pump_body)(void) = nullptr;
    if (fn_connectAadProfile) {
        uintptr_t pbase = (uintptr_t)fn_connectAadProfile - 0xb1d00;
        pump_body = (void(*)(void))(pbase + 0xb0ec0);
        int before = count_threads();
        fprintf(stderr, "[shim] pump FUN_001b0ec0 @ %p (threads voor=%d)\n",
                (void*)pump_body, before);
        pthread_t pth;
        pthread_create(&pth, nullptr, [](void*) -> void* {
            fprintf(stderr, "[pump] thread gestart\n");
            pump_body();
            fprintf(stderr, "[pump] FUN_001b0ec0 keerde terug (datapath gestopt)\n");
            return nullptr;
        }, nullptr);
        usleep(300000);
        fprintf(stderr, "[shim] pump gestart (threads na=%d)\n", count_threads());
    }
    sleep(2);  /* geef de data-path tijd om de tun te verbinden */

    const char *poll_env = getenv("POLL_SECS");
    int poll_secs = (poll_env && *poll_env) ? atoi(poll_env) : 85;
    fprintf(stderr, "\n[shim] status pollen (%ds)...\n", poll_secs);
    char statusbuf[512] = {};
    const char *prev_fail = "";
    for (int i = 0; i < poll_secs && g_running; i++) {
        sleep(1);
        if (fn_getConnectionStatus) {
            memset(statusbuf, 0, sizeof(statusbuf));
            fn_getConnectionStatus(statusbuf);
            if (statusbuf[0])
                fprintf(stderr, "[shim] status[%ds]: %s\n", i+1, statusbuf);
        }
        if (fn_getFailureMessage) {
            char *fail = fn_getFailureMessage();
            if (fail && *fail && strcmp(fail, prev_fail) != 0) {
                fprintf(stderr, "[shim] failure[%ds]: %s\n", i+1, fail);
                prev_fail = fail;
            }
        }
    }

    /* ── 7. Opruimen ────────────────────────────────────────────────────── */
    fprintf(stderr, "\n[shim] disconnectProfile...\n");
    if (fn_disconnectProfile) fn_disconnectProfile();
    dlclose(lib);
    fprintf(stderr, "[shim] klaar\n");
    return 0;
}
