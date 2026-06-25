/* LD_PRELOAD interceptor: leidt open()/fopen() met een LEEG pad om naar de
 * DigiCert-root (/dr.pem). De connect-tijd loadCerts() in libLinuxCore.so bouwt
 * een leeg cert-pad (per-connectie config is leeg voor AAD) en faalt met
 * "Failed to open file: " + "no certificates were passed". Door het lege pad
 * naar /dr.pem te redirecten laadt loadCerts de trusted root → server-cert
 * validatie kan slagen. Pad instelbaar via env CERT_REDIRECT. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <string.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>

static const char *redir_target(void) {
    const char *e = getenv("CERT_REDIRECT");
    return (e && *e) ? e : "/dr.pem";
}
static int is_empty(const char *p) { return (p == NULL) || (p[0] == '\0'); }

__attribute__((constructor)) static void redir_init(void) {
    fprintf(stderr, "[redir] LD_PRELOAD certredirect ACTIEF (target=%s)\n", redir_target());
}
/* loadCerts() bouwt pad = prefix + authority-URL (bv. "/dr.pemhttps://login...").
 * Zo'n pad bevat "://" of de authority-host → redirect naar het echte cert. */
static int should_redirect(const char *p) {
    if (is_empty(p)) return 1;
    if (strstr(p, "://")) return 1;
    if (strstr(p, "login.microsoftonline.com")) return 1;
    return 0;
}
static const char *fix(const char *p) {
    if (should_redirect(p)) { const char *r = redir_target(); fprintf(stderr, "[redir] '%s' -> %s\n", p ? p : "(null)", r); return r; }
    return p;
}

int openat(int dirfd, const char *path, int flags, ...) {
    static int (*real)(int, const char *, int, ...) = NULL;
    if (!real) real = (int(*)(int,const char*,int,...))dlsym(RTLD_NEXT, "openat");
    mode_t mode = 0;
    if (flags & (O_CREAT | O_TMPFILE)) { va_list ap; va_start(ap, flags); mode = va_arg(ap, mode_t); va_end(ap); }
    return real(dirfd, fix(path), flags, mode);
}
int open(const char *path, int flags, ...) {
    static int (*real)(const char *, int, ...) = NULL;
    if (!real) real = (int(*)(const char*,int,...))dlsym(RTLD_NEXT, "open");
    mode_t mode = 0;
    if (flags & (O_CREAT | O_TMPFILE)) { va_list ap; va_start(ap, flags); mode = va_arg(ap, mode_t); va_end(ap); }
    return real(fix(path), flags, mode);
}
FILE *fopen(const char *path, const char *mode) {
    static FILE *(*real)(const char *, const char *) = NULL;
    if (!real) real = (FILE*(*)(const char*,const char*))dlsym(RTLD_NEXT, "fopen");
    return real(fix(path), mode);
}
FILE *fopen64(const char *path, const char *mode) {
    static FILE *(*real)(const char *, const char *) = NULL;
    if (!real) real = (FILE*(*)(const char*,const char*))dlsym(RTLD_NEXT, "fopen64");
    return real(fix(path), mode);
}

/* ── sd_bus stubs ───────────────────────────────────────────────────────────
 * De library zet na "Connected" de DNS via systemd-resolved over sd_bus. Zonder
 * dbus/resolved in de container faalt dat (ENOENT) → tunnel-teardown. We stubben
 * de sd_bus-calls naar "succes" zodat de DNS-stap slaagt en de tunnel blijft. */
static char g_fake_bus[256];
static char g_fake_msg[256];

int sd_bus_open_system_with_description(void **ret, const char *desc) {
    (void)desc; if (ret) *ret = g_fake_bus;
    fprintf(stderr, "[sdbus-stub] open_system -> fake bus\n");
    return 0;
}
int sd_bus_message_new_method_call(void *bus, void **m, const char *dst,
                                   const char *path, const char *iface, const char *member) {
    (void)bus;(void)dst;(void)path;(void)iface;(void)member; if (m) *m = g_fake_msg; return 0;
}
int sd_bus_message_append(void *m, const char *types, ...) { (void)m;(void)types; return 0; }
int sd_bus_message_append_array(void *m, char t, const void *p, size_t s) { (void)m;(void)t;(void)p;(void)s; return 0; }
int sd_bus_message_open_container(void *m, char t, const char *c) { (void)m;(void)t;(void)c; return 0; }
int sd_bus_message_close_container(void *m) { (void)m; return 0; }
int sd_bus_call(void *bus, void *m, unsigned long usec, void *err, void **reply) {
    (void)bus;(void)m;(void)usec;(void)err; if (reply) *reply = g_fake_msg;
    fprintf(stderr, "[sdbus-stub] call -> OK\n");
    return 0;
}
int sd_bus_error_is_set(const void *e) { (void)e; return 0; }
int sd_bus_error_get_errno(const void *e) { (void)e; return 0; }
void sd_bus_error_free(void *e) { (void)e; }
void *sd_bus_message_unref(void *m) { (void)m; return NULL; }
void *sd_bus_unref(void *bus) { (void)bus; return NULL; }
