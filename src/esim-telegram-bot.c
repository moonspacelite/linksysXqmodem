/*
 * esim-telegram-bot - tiny Telegram long-poll bridge for 0xygen eSIM.
 *
 * Runtime dependencies are intentionally limited to BusyBox/OpenWrt tools
 * already present in the firmware: uci, curl, jq, and lpac-esim.
 */
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define APP_NAME "esim-telegram-bot"
#define UCI_PREFIX "lpac-esim.main."
#define OFFSET_FILE "/tmp/lpac-esim/telegram.offset"
#define PENDING_FILE "/tmp/lpac-esim/telegram.pending"
#define STATUS_FILE "/tmp/lpac-esim/telegram.status"
#define BUF_MAX 65536
#define MSG_MAX 3900
#define MAX_PROFILES 32
#define HYFE_CLAIM_BIN "/usr/bin/hyfe-telegram-claim"

struct config {
    char enabled[8];
    char token[160];
    char chat_id[64];
    int reconnect_delay;
    int debug;
};

static void get_uci(const char *option, char *buf, size_t bufsz);

static void log_msg(const char *fmt, ...)
{
    char msg[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(msg, sizeof(msg), fmt, ap);
    va_end(ap);

    fprintf(stderr, "%s: %s\n", APP_NAME, msg);

    pid_t pid = fork();
    if (pid == 0) {
        execlp("logger", "logger", "-t", APP_NAME, msg, (char *)NULL);
        _exit(127);
    }
    if (pid > 0) waitpid(pid, NULL, 0);
}

static void trim(char *s)
{
    size_t n;
    while (*s && isspace((unsigned char)*s)) memmove(s, s + 1, strlen(s));
    n = strlen(s);
    while (n > 0 && isspace((unsigned char)s[n - 1])) s[--n] = '\0';
}

static int valid_token(const char *s)
{
    int has_colon = 0;
    if (!s || !*s) return 0;
    for (; *s; s++) {
        if (*s == ':') has_colon = 1;
        else if (!isalnum((unsigned char)*s) && *s != '_' && *s != '-') return 0;
    }
    return has_colon;
}

static int valid_chat_id(const char *s)
{
    if (!s || !*s) return 0;
    if (*s == '-') s++;
    if (!*s) return 0;
    for (; *s; s++) if (!isdigit((unsigned char)*s)) return 0;
    return 1;
}

static int safe_arg(const char *s)
{
    if (!s || !*s || strlen(s) > 2048) return 0;
    for (; *s; s++) {
        if ((unsigned char)*s < 32 || (unsigned char)*s == 127) return 0;
    }
    return 1;
}


static void json_escape(const char *src, char *dst, size_t dstsz)
{
    size_t di = 0;
    if (!dst || dstsz == 0) return;
    dst[0] = '\0';
    if (!src) return;
    for (; *src && di + 1 < dstsz; src++) {
        unsigned char c = (unsigned char)*src;
        if ((c == '"' || c == '\\') && di + 2 < dstsz) {
            dst[di++] = '\\';
            dst[di++] = (char)c;
        } else if (c == '\n' && di + 2 < dstsz) {
            dst[di++] = '\\'; dst[di++] = 'n';
        } else if (c == '\r' && di + 2 < dstsz) {
            dst[di++] = '\\'; dst[di++] = 'r';
        } else if (c == '\t' && di + 2 < dstsz) {
            dst[di++] = '\\'; dst[di++] = 't';
        } else if (c >= 32 && c != 127) {
            dst[di++] = (char)c;
        }
    }
    dst[di] = '\0';
}

static void html_escape_text(const char *src, char *dst, size_t dstsz)
{
    size_t di = 0;
    if (!dst || dstsz == 0) return;
    dst[0] = '\0';
    if (!src) return;
    for (; *src && di + 1 < dstsz; src++) {
        const char *rep = NULL;
        switch (*src) {
        case '&': rep = "&amp;"; break;
        case '<': rep = "&lt;"; break;
        case '>': rep = "&gt;"; break;
        default: break;
        }
        if (rep) {
            size_t rn = strlen(rep);
            if (di + rn >= dstsz) break;
            memcpy(dst + di, rep, rn);
            di += rn;
        } else {
            dst[di++] = *src;
        }
    }
    dst[di] = '\0';
}

static const char *style_active(int is_active)
{
    return is_active ? "primary" : "danger";
}

static const char *onoff_text(int is_on)
{
    return is_on ? "ON" : "OFF";
}

static int uci_bool(const char *option, int def)
{
    char v[32];
    get_uci(option, v, sizeof(v));
    if (!v[0]) return def;
    return (strcmp(v, "1") == 0 || strcasecmp(v, "true") == 0 || strcasecmp(v, "on") == 0 || strcasecmp(v, "yes") == 0);
}

static void uci_value_or(const char *option, const char *def, char *buf, size_t bufsz)
{
    get_uci(option, buf, bufsz);
    if (!buf[0] && def) snprintf(buf, bufsz, "%s", def);
}

static int run_capture(char *const argv[], char *out, size_t outsz, int timeout_sec)
{
    int pipefd[2];
    pid_t pid;
    time_t deadline;
    size_t used = 0;
    int status = 0;

    if (outsz == 0) return -1;
    out[0] = '\0';
    if (pipe(pipefd) != 0) return -1;

    pid = fork();
    if (pid == 0) {
        int devnull = open("/dev/null", O_WRONLY);
        close(pipefd[0]);
        dup2(pipefd[1], STDOUT_FILENO);
        if (devnull >= 0) dup2(devnull, STDERR_FILENO);
        close(pipefd[1]);
        if (devnull >= 0) close(devnull);
        execvp(argv[0], argv);
        _exit(127);
    }
    close(pipefd[1]);
    if (pid < 0) {
        close(pipefd[0]);
        return -1;
    }

    fcntl(pipefd[0], F_SETFL, fcntl(pipefd[0], F_GETFL, 0) | O_NONBLOCK);
    deadline = time(NULL) + timeout_sec;

    for (;;) {
        fd_set rfds;
        struct timeval tv;
        ssize_t r;
        int w;

        FD_ZERO(&rfds);
        FD_SET(pipefd[0], &rfds);
        tv.tv_sec = 1;
        tv.tv_usec = 0;
        select(pipefd[0] + 1, &rfds, NULL, NULL, &tv);

        while ((r = read(pipefd[0], out + used, outsz - used - 1)) > 0) {
            used += (size_t)r;
            out[used] = '\0';
            if (used >= outsz - 1) break;
        }

        w = waitpid(pid, &status, WNOHANG);
        if (w == pid) break;
        if (time(NULL) >= deadline) {
            kill(pid, SIGTERM);
            sleep(1);
            kill(pid, SIGKILL);
            waitpid(pid, &status, 0);
            close(pipefd[0]);
            return 124;
        }
    }

    while (used < outsz - 1) {
        ssize_t r = read(pipefd[0], out + used, outsz - used - 1);
        if (r <= 0) break;
        used += (size_t)r;
    }
    out[used] = '\0';
    close(pipefd[0]);

    if (WIFEXITED(status)) return WEXITSTATUS(status);
    return -1;
}

static int run_shell(const char *cmd, char *out, size_t outsz, int timeout_sec)
{
    char *argv[] = { "sh", "-c", (char *)cmd, NULL };
    return run_capture(argv, out, outsz, timeout_sec);
}

static void get_uci(const char *option, char *buf, size_t bufsz)
{
    char key[96];
    char *argv[] = { "uci", "-q", "get", key, NULL };
    snprintf(key, sizeof(key), "%s%s", UCI_PREFIX, option);
    if (run_capture(argv, buf, bufsz, 3) != 0) buf[0] = '\0';
    trim(buf);
}

static void load_config(struct config *cfg)
{
    char tmp[32];
    memset(cfg, 0, sizeof(*cfg));
    get_uci("telegram_enabled", cfg->enabled, sizeof(cfg->enabled));
    get_uci("telegram_bot_token", cfg->token, sizeof(cfg->token));
    get_uci("telegram_allowed_chat_id", cfg->chat_id, sizeof(cfg->chat_id));
    get_uci("telegram_poll_interval", tmp, sizeof(tmp));
    cfg->reconnect_delay = atoi(tmp);
    if (cfg->reconnect_delay < 1 || cfg->reconnect_delay > 30) cfg->reconnect_delay = 2;
    get_uci("telegram_debug", tmp, sizeof(tmp));
    cfg->debug = (strcmp(tmp, "1") == 0);
}

/*
 * NOTE: chat IDs and update_ids in the Telegram Bot API are 64-bit signed
 * integers. Linksys EA6350v3 is 32-bit ARM (ipq40xx / Cortex-A7) where the
 * C `long` type is only 32-bit, so parsing those numbers with strtol() or
 * printing them with %ld silently wraps to LONG_MAX for any chat ID above
 * 2_147_483_647 — which is true for the vast majority of modern Telegram
 * users. Symptom: bot polls fine, never replies, no error logged. Always
 * use `long long` / strtoll / %lld for these.
 */

/*
 * Write a small JSON heartbeat to /tmp/lpac-esim/telegram.status every time
 * we successfully poll Telegram, and again on each failure. LuCI reads this
 * file to show the user a real, live status (● Running with "last poll 3s
 * ago" / ● Error: rc=22) instead of just `pidof` which only says whether
 * the process exists, not whether it's actually able to reach Telegram.
 */
static void write_status(const char *state, int last_rc, long long last_update_id)
{
    FILE *f;
    mkdir("/tmp/lpac-esim", 0755);
    f = fopen(STATUS_FILE ".tmp", "w");
    if (!f) return;
    fprintf(f,
            "{\"state\":\"%s\",\"last_poll\":%ld,\"last_rc\":%d,\"last_update_id\":%lld,\"pid\":%ld}\n",
            state, (long)time(NULL), last_rc, last_update_id, (long)getpid());
    fclose(f);
    rename(STATUS_FILE ".tmp", STATUS_FILE);
}

static void save_offset(long long offset)
{
    FILE *f;
    mkdir("/tmp/lpac-esim", 0755);
    f = fopen(OFFSET_FILE, "w");
    if (!f) return;
    fprintf(f, "%lld\n", offset);
    fclose(f);
}

static void pending_path(const char *chat_id, char *path, size_t pathsz)
{
    snprintf(path, pathsz, "%s.%s", PENDING_FILE, valid_chat_id(chat_id) ? chat_id : "0");
}

static void hyfe_numbers_path(const char *chat_id, char *path, size_t pathsz)
{
    snprintf(path, pathsz, "/tmp/lpac-esim/hyfe.numbers.%s", valid_chat_id(chat_id) ? chat_id : "0");
}

static void save_pending(const char *chat_id, const char *action, const char *arg)
{
    char path[96];
    FILE *f;
    mkdir("/tmp/lpac-esim", 0755);
    pending_path(chat_id, path, sizeof(path));
    f = fopen(path, "w");
    if (!f) return;
    fprintf(f, "%s\n%s\n", action ? action : "", arg ? arg : "");
    fclose(f);
}

static int load_pending(const char *chat_id, char *action, size_t actionsz, char *arg, size_t argsz)
{
    char path[96];
    FILE *f;
    pending_path(chat_id, path, sizeof(path));
    f = fopen(path, "r");
    if (!f) return 0;
    if (!fgets(action, actionsz, f)) action[0] = '\0';
    if (!fgets(arg, argsz, f)) arg[0] = '\0';
    fclose(f);
    trim(action);
    trim(arg);
    return action[0] != '\0';
}

static void clear_pending(const char *chat_id)
{
    char path[96];
    pending_path(chat_id, path, sizeof(path));
    unlink(path);
    hyfe_numbers_path(chat_id, path, sizeof(path));
    unlink(path);
}

static int load_hyfe_number_pick(const char *chat_id, int pick_idx, char *msisdn, size_t msisdnsz, char *encrypt, size_t encryptsz)
{
    char path[96], line[1600];
    FILE *f;
    int idx;
    char *a, *b, *c;

    if (msisdn && msisdnsz) msisdn[0] = '\0';
    if (encrypt && encryptsz) encrypt[0] = '\0';
    hyfe_numbers_path(chat_id, path, sizeof(path));
    f = fopen(path, "r");
    if (!f) return 0;
    while (fgets(line, sizeof(line), f)) {
        trim(line);
        if (!line[0]) continue;
        a = line;
        b = strchr(a, '\t'); if (!b) continue; *b++ = '\0';
        c = strchr(b, '\t'); if (!c) continue; *c++ = '\0';
        idx = atoi(a);
        if (idx != pick_idx) continue;
        if (msisdn && msisdnsz) { strncpy(msisdn, b, msisdnsz - 1); msisdn[msisdnsz - 1] = '\0'; }
        if (encrypt && encryptsz) { strncpy(encrypt, c, encryptsz - 1); encrypt[encryptsz - 1] = '\0'; }
        fclose(f);
        return msisdn && msisdn[0] && encrypt && encrypt[0];
    }
    fclose(f);
    return 0;
}

static long long load_offset(void)
{
    FILE *f = fopen(OFFSET_FILE, "r");
    long long offset = 0;
    if (!f) return 0;
    if (fscanf(f, "%lld", &offset) != 1) offset = 0;
    fclose(f);
    return offset;
}

static int telegram_get_updates(const struct config *cfg, long long offset, char *out, size_t outsz)
{
    char url[320];
    char *argv[] = { "curl", "-g", "-fsS", "--max-time", "35", NULL, NULL };
    snprintf(url, sizeof(url),
             "https://api.telegram.org/bot%s/getUpdates?timeout=25&offset=%lld&allowed_updates=[\"message\",\"callback_query\"]",
             cfg->token, offset);
    argv[5] = url;
    return run_capture(argv, out, outsz, 40);
}

static void send_message(const struct config *cfg, const char *chat_id, const char *text)
{
    char url[240];
    char chat_arg[96];
    char msg[MSG_MAX + 1];
    char out[512];
    int rc;
    char *argv[] = {
        "curl", "-fsS", "--max-time", "15", "-X", "POST", url,
        "-d", chat_arg, "--data-urlencode", msg, NULL
    };

    if (!valid_chat_id(chat_id)) return;
    snprintf(url, sizeof(url), "https://api.telegram.org/bot%s/sendMessage", cfg->token);
    snprintf(chat_arg, sizeof(chat_arg), "chat_id=%s", chat_id);
    snprintf(msg, sizeof(msg), "text=%.*s", MSG_MAX - 5, text ? text : "");
    rc = run_capture(argv, out, sizeof(out), 20);
    /* Always log a failed sendMessage. The previous `&& cfg->debug` guard
     * hid the very symptom that masked the 32-bit chat_id parsing bug for
     * months: bot would silently fail to deliver every reply (Telegram
     * returns 400 "chat not found" / curl exit 22), and with debug off
     * nothing ever showed up in syslog. */
    if (rc != 0) log_msg("sendMessage failed rc=%d chat=%s", rc, chat_id);
}

/* Send a message with inline keyboard (callback buttons). keyboard_json is the
 * full JSON value for reply_markup, e.g. {"inline_keyboard":[[...],...]} */
static void send_inline_keyboard(const struct config *cfg, const char *chat_id,
                                 const char *text, const char *keyboard_json)
{
    char url[240];
    char chat_arg[96];
    char msg[MSG_MAX + 1];
    char markup[4096];
    char parse[32];
    char out[512];
    int rc;
    char *argv[] = {
        "curl", "-fsS", "--max-time", "15", "-X", "POST", url,
        "-d", chat_arg, "--data-urlencode", msg,
        "-d", markup, "-d", parse, NULL
    };

    if (!valid_chat_id(chat_id)) return;
    snprintf(url, sizeof(url), "https://api.telegram.org/bot%s/sendMessage", cfg->token);
    snprintf(chat_arg, sizeof(chat_arg), "chat_id=%s", chat_id);
    snprintf(msg, sizeof(msg), "text=%.*s", MSG_MAX - 5, text ? text : "");
    snprintf(markup, sizeof(markup), "reply_markup=%s", keyboard_json ? keyboard_json : "{}");
    snprintf(parse, sizeof(parse), "parse_mode=HTML");
    rc = run_capture(argv, out, sizeof(out), 20);
    if (rc != 0) log_msg("sendMessage inline kb failed rc=%d chat=%s", rc, chat_id);
}

static void url_encode(const char *src, char *dst, size_t dstsz)
{
    static const char hex[] = "0123456789ABCDEF";
    size_t di = 0;
    if (!dst || dstsz == 0) return;
    dst[0] = '\0';
    if (!src) return;
    for (; *src && di + 1 < dstsz; src++) {
        unsigned char c = (unsigned char)*src;
        if (isalnum(c) || c == '-' || c == '_' || c == '.' || c == '~') {
            dst[di++] = (char)c;
        } else if (di + 3 < dstsz) {
            dst[di++] = '%'; dst[di++] = hex[c >> 4]; dst[di++] = hex[c & 15];
        } else break;
    }
    dst[di] = '\0';
}

static void send_photo_url(const struct config *cfg, const char *chat_id, const char *photo_url, const char *caption)
{
    char url[240], chat_arg[96], photo_arg[4096], cap[MSG_MAX + 1], parse[32], out[512];
    int rc;
    char *argv[] = { "curl", "-fsS", "--max-time", "25", "-X", "POST", url,
        "-d", chat_arg, "--data-urlencode", photo_arg, "--data-urlencode", cap, "-d", parse, NULL };
    if (!valid_chat_id(chat_id) || !photo_url || !*photo_url) return;
    snprintf(url, sizeof(url), "https://api.telegram.org/bot%s/sendPhoto", cfg->token);
    snprintf(chat_arg, sizeof(chat_arg), "chat_id=%s", chat_id);
    snprintf(photo_arg, sizeof(photo_arg), "photo=%s", photo_url);
    snprintf(cap, sizeof(cap), "caption=%.*s", MSG_MAX - 9, caption ? caption : "");
    snprintf(parse, sizeof(parse), "parse_mode=HTML");
    rc = run_capture(argv, out, sizeof(out), 30);
    if (rc != 0) log_msg("sendPhoto failed rc=%d chat=%s", rc, chat_id);
}

static int json_get_string(const char *json, const char *key, char *out, size_t outsz)
{
    char pat[64];
    const char *p, *q;
    size_t oi = 0;
    if (!out || outsz == 0) return 0;
    out[0] = '\0';
    snprintf(pat, sizeof(pat), "\"%s\"", key);
    p = strstr(json ? json : "", pat);
    if (!p) return 0;
    p = strchr(p + strlen(pat), ':');
    if (!p) return 0;
    p++;
    while (*p && isspace((unsigned char)*p)) p++;
    if (*p != '"') return 0;
    p++;
    for (q = p; *q && oi + 1 < outsz; q++) {
        if (*q == '\\') {
            q++;
            if (!*q) break;
            if (*q == 'n') out[oi++] = '\n';
            else if (*q == 'r') out[oi++] = '\r';
            else if (*q == 't') out[oi++] = '\t';
            else out[oi++] = *q;
        } else if (*q == '"') {
            break;
        } else {
            out[oi++] = *q;
        }
    }
    out[oi] = '\0';
    return oi > 0;
}


static void hyfe_pack(char *dst, size_t dstsz, const char *name, const char *email, const char *msisdn, const char *eid)
{
    snprintf(dst, dstsz, "%s|%s|%s|%s", name ? name : "", email ? email : "", msisdn ? msisdn : "", eid ? eid : "");
}

static void hyfe_unpack(const char *src, char *name, size_t namesz, char *email, size_t emailsz, char *msisdn, size_t msisdnsz, char *eid, size_t eidsz)
{
    char tmp[1024];
    char *a, *b, *c, *d;
    snprintf(tmp, sizeof(tmp), "%s", src ? src : "");
    a = tmp;
    b = strchr(a, '|'); if (b) *b++ = '\0'; else b = "";
    c = strchr(b, '|'); if (c) *c++ = '\0'; else c = "";
    d = strchr(c, '|'); if (d) *d++ = '\0'; else d = "";
    if (namesz) { strncpy(name, a, namesz - 1); name[namesz - 1] = '\0'; }
    if (emailsz) { strncpy(email, b, emailsz - 1); email[emailsz - 1] = '\0'; }
    if (msisdnsz) { strncpy(msisdn, c, msisdnsz - 1); msisdn[msisdnsz - 1] = '\0'; }
    if (eidsz) { strncpy(eid, d, eidsz - 1); eid[eidsz - 1] = '\0'; }
}

static void hyfe_pack_manual(char *dst, size_t dstsz, const char *name, const char *wa, const char *email, const char *msisdn, const char *eid)
{
    snprintf(dst, dstsz, "%s|%s|%s|%s|%s",
             name ? name : "", wa ? wa : "", email ? email : "", msisdn ? msisdn : "", eid ? eid : "");
}

static void hyfe_unpack_manual(const char *src, char *name, size_t namesz, char *wa, size_t wasz, char *email, size_t emailsz, char *msisdn, size_t msisdnsz, char *eid, size_t eidsz)
{
    char tmp[1024];
    char *a, *b, *c, *d, *e;
    snprintf(tmp, sizeof(tmp), "%s", src ? src : "");
    a = tmp;
    b = strchr(a, '|'); if (b) *b++ = '\0'; else b = "";
    c = strchr(b, '|'); if (c) *c++ = '\0'; else c = "";
    d = strchr(c, '|'); if (d) *d++ = '\0'; else d = "";
    e = strchr(d, '|'); if (e) *e++ = '\0'; else e = "";
    if (namesz) { strncpy(name, a, namesz - 1); name[namesz - 1] = '\0'; }
    if (wasz) { strncpy(wa, b, wasz - 1); wa[wasz - 1] = '\0'; }
    if (emailsz) { strncpy(email, c, emailsz - 1); email[emailsz - 1] = '\0'; }
    if (msisdnsz) { strncpy(msisdn, d, msisdnsz - 1); msisdn[msisdnsz - 1] = '\0'; }
    if (eidsz) { strncpy(eid, e, eidsz - 1); eid[eidsz - 1] = '\0'; }
}

static void hyfe_pack_manual_ext(char *dst, size_t dstsz, const char *name, const char *wa, const char *email, const char *msisdn, const char *eid, const char *encrypt)
{
    snprintf(dst, dstsz, "%s|%s|%s|%s|%s|%s",
             name ? name : "", wa ? wa : "", email ? email : "", msisdn ? msisdn : "", eid ? eid : "", encrypt ? encrypt : "");
}

static void hyfe_unpack_manual_ext(const char *src, char *name, size_t namesz, char *wa, size_t wasz, char *email, size_t emailsz, char *msisdn, size_t msisdnsz, char *eid, size_t eidsz, char *encrypt, size_t encryptsz)
{
    char tmp[2048];
    char *a, *b, *c, *d, *e, *g;
    snprintf(tmp, sizeof(tmp), "%s", src ? src : "");
    a = tmp;
    b = strchr(a, '|'); if (b) *b++ = '\0'; else b = "";
    c = strchr(b, '|'); if (c) *c++ = '\0'; else c = "";
    d = strchr(c, '|'); if (d) *d++ = '\0'; else d = "";
    e = strchr(d, '|'); if (e) *e++ = '\0'; else e = "";
    g = strchr(e, '|'); if (g) *g++ = '\0'; else g = "";
    if (namesz) { strncpy(name, a, namesz - 1); name[namesz - 1] = '\0'; }
    if (wasz) { strncpy(wa, b, wasz - 1); wa[wasz - 1] = '\0'; }
    if (emailsz) { strncpy(email, c, emailsz - 1); email[emailsz - 1] = '\0'; }
    if (msisdnsz) { strncpy(msisdn, d, msisdnsz - 1); msisdn[msisdnsz - 1] = '\0'; }
    if (eidsz) { strncpy(eid, e, eidsz - 1); eid[eidsz - 1] = '\0'; }
    if (encryptsz) { strncpy(encrypt, g, encryptsz - 1); encrypt[encryptsz - 1] = '\0'; }
}

static int valid_email_simple(const char *s)
{
    const char *at, *dot;
    if (!s || strlen(s) < 5 || strlen(s) > 120) return 0;
    if (strchr(s, '|') || strchr(s, ' ') || strchr(s, '\n') || strchr(s, '\r')) return 0;
    at = strchr(s, '@');
    if (!at || at == s) return 0;
    dot = strrchr(at + 1, '.');
    return dot && dot > at + 1 && dot[1];
}

static int valid_eid_simple(const char *s)
{
    int n = 0;
    if (!s) return 0;
    for (; *s; s++) {
        if (!isdigit((unsigned char)*s)) return 0;
        n++;
    }
    return n == 32;
}

static int normalize_wa_c(const char *input, char *dst, size_t dstsz)
{
    char buf[48];
    size_t bi = 0;
    const char *p;

    if (!input || !*input || dstsz < 16) return 0;
    for (p = input; *p && bi < sizeof(buf) - 1; p++) {
        if (isdigit((unsigned char)*p)) buf[bi++] = *p;
        else if (*p == '+' && bi == 0) continue;
        else if (*p == ' ' || *p == '-' || *p == '.' || *p == '(' || *p == ')') continue;
        else return 0;
    }
    buf[bi] = '\0';
    if (strncmp(buf, "62", 2) == 0) memmove(buf, buf + 2, strlen(buf + 2) + 1);
    else if (buf[0] == '0') memmove(buf, buf + 1, strlen(buf));
    bi = strlen(buf);
    if (bi < 8 || bi > 12) return 0;
    for (p = buf; *p; p++) if (!isdigit((unsigned char)*p)) return 0;
    snprintf(dst, dstsz, "%s", buf);
    return 1;
}

static int valid_msisdn_pattern(const char *s)
{
    int n = 0;
    if (!s) return 0;
    if (!*s) return 1;
    for (; *s; s++) {
        if (!isdigit((unsigned char)*s)) return 0;
        n++;
    }
    return n >= 1 && n <= 5;
}

static int valid_captcha_mode(const char *mode)
{
    return mode && (
        strcmp(mode, "manual") == 0 ||
        strcmp(mode, "nextcaptcha") == 0 ||
        strcmp(mode, "2captcha") == 0 ||
        strcmp(mode, "anticaptcha") == 0 ||
        strcmp(mode, "capsolver") == 0);
}

static void send_loading(const struct config *cfg, const char *chat, const char *what)
{
    char msg[256];
    snprintf(msg, sizeof(msg), "⏳ %s\nMohon tunggu, bot sedang memproses...", what ? what : "Memproses");
    send_message(cfg, chat, msg);
}

static int hyfe_start_claim(const char *packed, char *out, size_t outsz)
{
    char name[160], wa[32], email[160], msisdn[64], eid[80], encrypt[1024];
    char *argv[] = { HYFE_CLAIM_BIN, "start-manual", NULL, NULL, NULL, NULL, NULL, NULL, NULL };
    hyfe_unpack_manual_ext(packed, name, sizeof(name), wa, sizeof(wa), email, sizeof(email), msisdn, sizeof(msisdn), eid, sizeof(eid), encrypt, sizeof(encrypt));
    if (!name[0] || !wa[0] || !valid_email_simple(email) || !msisdn[0] || !valid_eid_simple(eid)) {
        snprintf(out, outsz, "Data HYFE belum lengkap/valid.");
        return 2;
    }
    argv[2] = name;
    argv[3] = wa;
    argv[4] = email;
    argv[5] = msisdn;
    argv[6] = eid;
    argv[7] = encrypt[0] ? encrypt : NULL;
    return run_capture(argv, out, outsz, 120);
}

static int hyfe_random_value(const char *what, char *out, size_t outsz)
{
    char *argv[] = { HYFE_CLAIM_BIN, NULL, NULL };
    if (!what || (strcmp(what, "random-name") != 0 && strcmp(what, "random-wa") != 0)) return 2;
    argv[1] = (char *)what;
    return run_capture(argv, out, outsz, 20);
}

static int hyfe_list_numbers(const char *pattern, char *out, size_t outsz)
{
    char patbuf[16];
    char *argv[] = { HYFE_CLAIM_BIN, "list-numbers", NULL, NULL };
    snprintf(patbuf, sizeof(patbuf), "%s", pattern ? pattern : "");
    trim(patbuf);
    if (!valid_msisdn_pattern(patbuf)) {
        snprintf(out, outsz, "Pola harus kosong atau 1-5 digit angka.");
        return 2;
    }
    argv[2] = patbuf;
    return run_capture(argv, out, outsz, 90);
}

static int hyfe_finish_claim(const char *sid, const char *otp, const char *mode, const char *captcha, char *out, size_t outsz)
{
    char otpbuf[768];
    char modebuf[32];
    char capbuf[2048];
    char *argv[] = { HYFE_CLAIM_BIN, "finish", NULL, NULL, NULL, NULL, NULL };
    snprintf(otpbuf, sizeof(otpbuf), "%s", otp ? otp : "");
    snprintf(modebuf, sizeof(modebuf), "%s", mode && *mode ? mode : "manual");
    snprintf(capbuf, sizeof(capbuf), "%s", captcha ? captcha : "");
    trim(otpbuf);
    trim(modebuf);
    trim(capbuf);
    if (!valid_captcha_mode(modebuf)) {
        snprintf(out, outsz, "Mode captcha tidak valid.");
        return 2;
    }
    argv[2] = (char *)(sid ? sid : "");
    argv[3] = otpbuf;
    argv[4] = modebuf;
    argv[5] = capbuf;
    return run_capture(argv, out, outsz, 480);
}

static int hyfe_poll_otp(const char *sid, char *out, size_t outsz)
{
    char sidbuf[128];
    char *argv[] = { HYFE_CLAIM_BIN, "poll-otp", NULL, NULL };
    snprintf(sidbuf, sizeof(sidbuf), "%s", sid ? sid : "");
    trim(sidbuf);
    if (!sidbuf[0]) {
        snprintf(out, outsz, "SID HYFE kosong.");
        return 2;
    }
    argv[2] = sidbuf;
    return run_capture(argv, out, outsz, 210);
}

/* Panggil hyfe-telegram-claim show-captcha dan kembalikan mode aktif ke buf.
 * Return 0 jika berhasil dan mode ter-isi, -1 jika gagal. */
static int hyfe_get_active_captcha_mode(char *buf, size_t bufsz)
{
    char raw[512];
    char *argv[] = { HYFE_CLAIM_BIN, "show-captcha", NULL };
    int rc = run_capture(argv, raw, sizeof(raw), 15);
    if (rc != 0) return -1;
    /* parse: {"ok":true,"mode":"..."} */
    const char *mp = strstr(raw, "\"mode\":\"");
    if (!mp) return -1;
    mp += 8;
    const char *end = strchr(mp, '"');
    if (!end || (size_t)(end - mp) >= bufsz) return -1;
    memcpy(buf, mp, (size_t)(end - mp));
    buf[end - mp] = '\0';
    return 0;
}

static int hyfe_set_captcha(const char *mode, const char *key, char *out, size_t outsz)
{
    char modebuf[32], keybuf[256];
    char *argv[] = { HYFE_CLAIM_BIN, "set-captcha", NULL, NULL, NULL, NULL };
    snprintf(modebuf, sizeof(modebuf), "%s", mode ? mode : "");
    snprintf(keybuf, sizeof(keybuf), "%s", key ? key : "");
    trim(modebuf);
    trim(keybuf);
    if (!valid_captcha_mode(modebuf)) {
        snprintf(out, outsz, "Mode captcha tidak valid.");
        return 2;
    }
    argv[2] = modebuf;
    argv[3] = keybuf;
    argv[4] = "180";
    return run_capture(argv, out, outsz, 30);
}

static int hyfe_set_config_value(const char *key, const char *value, char *out, size_t outsz)
{
    char keybuf[80], valbuf[512];
    char *argv[] = { HYFE_CLAIM_BIN, "set-config", NULL, NULL, NULL };
    snprintf(keybuf, sizeof(keybuf), "%s", key ? key : "");
    snprintf(valbuf, sizeof(valbuf), "%s", value ? value : "");
    trim(keybuf);
    trim(valbuf);
    if (!keybuf[0]) {
        snprintf(out, outsz, "Key config kosong.");
        return 2;
    }
    argv[2] = keybuf;
    argv[3] = valbuf;
    return run_capture(argv, out, outsz, 25);
}

static int hyfe_show_config(char *out, size_t outsz)
{
    char *argv[] = { HYFE_CLAIM_BIN, "show-config", NULL };
    return run_capture(argv, out, outsz, 25);
}

static void send_hyfe_start_prompt(const struct config *cfg, const char *chat)
{
    clear_pending(chat);
    send_inline_keyboard(cfg, chat,
        "<b>Klaim Free eSIM HYFE</b>\n\n"
        "Pilih mode nama seperti di CLI.\n\n"
        "Belum pernah setup? Jalankan Setup Awal dulu.",
        "{\"inline_keyboard\":["
        "[{\"text\":\"Setup Awal\",\"callback_data\":\"hyfe:wizard:start\",\"style\":\"success\"}],"
        "[{\"text\":\"Nama Random\",\"callback_data\":\"hyfe:name:random\",\"style\":\"primary\"},"
        "{\"text\":\"Nama Manual\",\"callback_data\":\"hyfe:name:manual\",\"style\":\"primary\"}],"
        "[{\"text\":\"Batal\",\"callback_data\":\"cancel\",\"style\":\"danger\"}]]}");
}

static void send_hyfe_setup_otp_choice(const struct config *cfg, const char *chat)
{
    clear_pending(chat);
    send_inline_keyboard(cfg, chat,
        "<b>Setup Awal HYFE</b>\n\n"
        "Pilih cara ambil OTP email untuk klaim HYFE.",
        "{\"inline_keyboard\":["
        "[{\"text\":\"OTP Manual\",\"callback_data\":\"hyfewizotp:manual\",\"style\":\"primary\"},"
        "{\"text\":\"OTP IMAP Otomatis\",\"callback_data\":\"hyfewizotp:imap\",\"style\":\"success\"}],"
        "[{\"text\":\"Batal\",\"callback_data\":\"cancel\",\"style\":\"danger\"}]]}");
}

static void send_hyfe_setup_email_prompt(const struct config *cfg, const char *chat, const char *otp_mode)
{
    char msg[768];
    clear_pending(chat);
    save_pending(chat, "hyfe_wizard_email", otp_mode ? otp_mode : "manual");
    snprintf(msg, sizeof(msg),
        "<b>Setup Awal HYFE</b>\n\n"
        "Mode OTP: <code>%s</code>\n\n"
        "Kirim email akun HYFE untuk disimpan sebagai <code>HYFE_EMAIL_1</code>.",
        otp_mode && strcmp(otp_mode, "imap") == 0 ? "imap" : "manual");
    send_inline_keyboard(cfg, chat, msg,
        "{\"inline_keyboard\":[[{\"text\":\"Batal\",\"callback_data\":\"cancel\",\"style\":\"danger\"}]]}");
}

static void send_hyfe_setup_pass_prompt(const struct config *cfg, const char *chat)
{
    send_inline_keyboard(cfg, chat,
        "<b>Setup IMAP HYFE</b>\n\n"
        "Kirim App Password email untuk disimpan sebagai <code>HYFE_IMAP_PASS_1</code>.\n\n"
        "Untuk Gmail gunakan App Password, bukan password login utama.",
        "{\"inline_keyboard\":[[{\"text\":\"Batal\",\"callback_data\":\"cancel\",\"style\":\"danger\"}]]}");
}

static void send_hyfe_setup_captcha_choice(const struct config *cfg, const char *chat)
{
    send_inline_keyboard(cfg, chat,
        "<b>Setup Captcha HYFE</b>\n\n"
        "Pilih mode captcha yang akan dipakai saat klaim.",
        "{\"inline_keyboard\":["
        "[{\"text\":\"Manual\",\"callback_data\":\"hyfewizcap:manual\",\"style\":\"primary\"},"
        "{\"text\":\"nextcaptcha\",\"callback_data\":\"hyfewizcap:nextcaptcha\",\"style\":\"primary\"}],"
        "[{\"text\":\"2captcha\",\"callback_data\":\"hyfewizcap:2captcha\",\"style\":\"primary\"},"
        "{\"text\":\"anticaptcha\",\"callback_data\":\"hyfewizcap:anticaptcha\",\"style\":\"primary\"}],"
        "[{\"text\":\"capsolver\",\"callback_data\":\"hyfewizcap:capsolver\",\"style\":\"primary\"}],"
        "[{\"text\":\"Batal\",\"callback_data\":\"cancel\",\"style\":\"danger\"}]]}");
}

static void send_hyfe_setup_eid_choice(const struct config *cfg, const char *chat)
{
    send_inline_keyboard(cfg, chat,
        "<b>Setup EID HYFE</b>\n\n"
        "Simpan EID default ke <code>HYFE_EID_1</code> agar klaim berikutnya lebih mudah?",
        "{\"inline_keyboard\":["
        "[{\"text\":\"Simpan EID\",\"callback_data\":\"hyfewizeid:save\",\"style\":\"success\"},"
        "{\"text\":\"Lewati\",\"callback_data\":\"hyfewizeid:skip\",\"style\":\"primary\"}],"
        "[{\"text\":\"Batal\",\"callback_data\":\"cancel\",\"style\":\"danger\"}]]}");
}

static void send_hyfe_setup_done(const struct config *cfg, const char *chat)
{
    send_inline_keyboard(cfg, chat,
        "Setup awal HYFE selesai.\n\n"
        "Config sudah disimpan. Sekarang bisa lanjut klaim atau cek ulang setting.",
        "{\"inline_keyboard\":["
        "[{\"text\":\"Mulai Klaim HYFE\",\"callback_data\":\"hyfe:start\",\"style\":\"success\"},"
        "{\"text\":\"HYFE Setting\",\"callback_data\":\"hyfe:settings\",\"style\":\"primary\"}],"
        "[{\"text\":\"Menu\",\"callback_data\":\"menu:main\"}]]}");
}

static void send_hyfe_name_manual_prompt(const struct config *cfg, const char *chat)
{
    save_pending(chat, "hyfe_name_manual", "");
    send_inline_keyboard(cfg, chat,
        "Kirim nama lengkap untuk klaim.\n"
        "Contoh: <code>Ahmad Pratama</code>",
        "{\"inline_keyboard\":[[{\"text\":\"Batal\",\"callback_data\":\"cancel\",\"style\":\"danger\"}]]}");
}

static void send_hyfe_whatsapp_choice(const struct config *cfg, const char *chat, const char *name)
{
    char packed[512], msg[768];
    hyfe_pack_manual(packed, sizeof(packed), name, "", "", "", "");
    save_pending(chat, "hyfe_whatsapp_choice", packed);
    snprintf(msg, sizeof(msg),
        "Nama: <b>%s</b>\n\n"
        "Pilih mode nomor WhatsApp seperti di CLI.", name);
    send_inline_keyboard(cfg, chat, msg,
        "{\"inline_keyboard\":["
        "[{\"text\":\"WA Random\",\"callback_data\":\"hyfe:wa:random\",\"style\":\"primary\"},"
        "{\"text\":\"WA Manual\",\"callback_data\":\"hyfe:wa:manual\",\"style\":\"primary\"}],"
        "[{\"text\":\"Batal\",\"callback_data\":\"cancel\",\"style\":\"danger\"}]]}");
}

static void send_hyfe_whatsapp_manual_prompt(const struct config *cfg, const char *chat, const char *packed)
{
    save_pending(chat, "hyfe_whatsapp", packed);
    send_inline_keyboard(cfg, chat,
        "Kirim nomor WhatsApp untuk data customer HYFE.\n"
        "Boleh format <code>08123456789</code> atau <code>8123456789</code>.",
        "{\"inline_keyboard\":[[{\"text\":\"Batal\",\"callback_data\":\"cancel\",\"style\":\"danger\"}]]}");
}

static void send_hyfe_email_prompt(const struct config *cfg, const char *chat, const char *packed)
{
    save_pending(chat, "hyfe_email", packed);
    send_inline_keyboard(cfg, chat,
        "<b>Email OTP</b>\n\n"
        "Kirim email untuk menerima OTP HYFE.\n"
        "Contoh: <code>email@gmail.com</code>",
        "{\"inline_keyboard\":[[{\"text\":\"Batal\",\"callback_data\":\"cancel\",\"style\":\"danger\"}]]}");
}

static void send_hyfe_pattern_prompt(const struct config *cfg, const char *chat, const char *packed)
{
    save_pending(chat, "hyfe_pattern", packed);
    send_inline_keyboard(cfg, chat,
        "<b>Pilih Nomor Cantik</b>\n\n"
        "Kirim 1-5 kombinasi digit nomor yang ingin dicari.\n"
        "Contoh: <code>123</code>, <code>7777</code>, atau <code>081</code>.\n\n"
        "Atau tekan Random untuk ambil listing acak seperti CLI.",
        "{\"inline_keyboard\":["
        "[{\"text\":\"Random Listing\",\"callback_data\":\"hyfe:pattern:random\",\"style\":\"primary\"}],"
        "[{\"text\":\"Batal\",\"callback_data\":\"cancel\",\"style\":\"danger\"}]]}");
}

static void send_hyfe_number_list(const struct config *cfg, const char *chat, const char *packed, const char *pattern)
{
    char out[BUF_MAX], keyboard[4096], msg[MSG_MAX + 1];
    char lines[1800] = "";
    char *saveptr = NULL, *line;
    char map_path[96];
    FILE *mapf;
    int rc, count = 0;
    size_t ku = 0, lu = 0;

    send_loading(cfg, chat, "Mengambil daftar nomor HYFE");
    rc = hyfe_list_numbers(pattern, out, sizeof(out));
    if (rc != 0) {
        snprintf(msg, sizeof(msg), "Gagal mengambil nomor HYFE:\n<code>%.900s</code>", out);
        send_inline_keyboard(cfg, chat, msg,
            "{\"inline_keyboard\":[[{\"text\":\"Coba Lagi\",\"callback_data\":\"hyfe:start\",\"style\":\"primary\"}]]}");
        return;
    }

    save_pending(chat, "hyfe_pick_number", packed);
    hyfe_numbers_path(chat, map_path, sizeof(map_path));
    mapf = fopen(map_path, "w");
    ku += snprintf(keyboard + ku, sizeof(keyboard) - ku, "{\"inline_keyboard\":[");
    line = strtok_r(out, "\n", &saveptr);
    while (line && count < 12) {
        char *tab = strchr(line, '\t');
        char *enc = "";
        if (tab) { *tab++ = '\0'; enc = tab; }
        trim(line);
        trim(enc);
        if (line[0] && enc[0]) {
            int idx = count + 1;
            if (count > 0) ku += snprintf(keyboard + ku, sizeof(keyboard) - ku, ",");
            ku += snprintf(keyboard + ku, sizeof(keyboard) - ku,
                "[{\"text\":\"%s\",\"callback_data\":\"hyfenum:%d\",\"style\":\"success\"}]", line, idx);
            if (mapf) fprintf(mapf, "%d\t%s\t%s\n", idx, line, enc);
            lu += snprintf(lines + lu, sizeof(lines) - lu, "%d. <code>%s</code>\n", idx, line);
            count++;
        }
        line = strtok_r(NULL, "\n", &saveptr);
    }
    if (mapf) fclose(mapf);
    if (count == 0) {
        send_inline_keyboard(cfg, chat,
            "Tidak ada nomor tersedia untuk pola itu. Coba kombinasi lain.",
            "{\"inline_keyboard\":[[{\"text\":\"Cari Lagi\",\"callback_data\":\"hyfe:pattern:again\",\"style\":\"primary\"}]]}");
        return;
    }
    ku += snprintf(keyboard + ku, sizeof(keyboard) - ku,
        ",[{\"text\":\"Cari Lagi\",\"callback_data\":\"hyfe:pattern:again\",\"style\":\"primary\"},"
        "{\"text\":\"Batal\",\"callback_data\":\"cancel\",\"style\":\"danger\"}]]}");
    snprintf(msg, sizeof(msg),
        "<b>Nomor HYFE tersedia</b>\n\n"
        "Pola: <code>%s</code>\n\n%s\nKlik nomor yang cocok untuk lanjut.",
        pattern && *pattern ? pattern : "random", lines);
    send_inline_keyboard(cfg, chat, msg, keyboard);
}

static void send_hyfe_eid_prompt(const struct config *cfg, const char *chat, const char *packed)
{
    save_pending(chat, "hyfe_eid", packed);
    send_inline_keyboard(cfg, chat,
        "<b>EID Manual</b>\n\n"
        "Kirim EID eUICC/eSIM chip Anda.\n"
        "Contoh: <code>89049032000000000000000000000000</code>",
        "{\"inline_keyboard\":[[{\"text\":\"Batal\",\"callback_data\":\"cancel\",\"style\":\"danger\"}]]}");
}

static void send_hyfe_captcha_mode_prompt(const struct config *cfg, const char *chat, const char *sid, const char *otp)
{
    char packed[320];
    snprintf(packed, sizeof(packed), "%s|%s", sid ? sid : "", otp ? otp : "");
    save_pending(chat, "hyfe_captcha_mode", packed);
    send_inline_keyboard(cfg, chat,
        "<b>Mode Captcha</b>\n\n"
        "Pilih solver captcha seperti di CLI. Mode selain manual memakai API key dari HYFE Setting.",
        "{\"inline_keyboard\":["
        "[{\"text\":\"manual\",\"callback_data\":\"hyfecap:manual\",\"style\":\"primary\"},"
        "{\"text\":\"nextcaptcha\",\"callback_data\":\"hyfecap:nextcaptcha\",\"style\":\"primary\"}],"
        "[{\"text\":\"2captcha\",\"callback_data\":\"hyfecap:2captcha\",\"style\":\"primary\"},"
        "{\"text\":\"anticaptcha\",\"callback_data\":\"hyfecap:anticaptcha\",\"style\":\"primary\"}],"
        "[{\"text\":\"capsolver\",\"callback_data\":\"hyfecap:capsolver\",\"style\":\"primary\"}],"
        "[{\"text\":\"Batal\",\"callback_data\":\"cancel\",\"style\":\"danger\"}]]}");
}

static void send_hyfe_captcha_manual_prompt(const struct config *cfg, const char *chat, const char *sid, const char *otp)
{
    char packed[1024];
    snprintf(packed, sizeof(packed), "%s|%s|manual", sid ? sid : "", otp ? otp : "");
    save_pending(chat, "hyfe_captcha", packed);
    send_inline_keyboard(cfg, chat,
        "<b>Token reCAPTCHA Manual</b>\n\n"
        "Buka halaman HYFE di browser:\n"
        "<code>https://prioritas.xl.co.id/hyfe-apply/esim-trial/input-eid</code>\n\n"
        "Lengkapi sampai halaman Verify Email, centang reCAPTCHA, lalu ambil token dari console:\n"
        "<code>grecaptcha.getResponse()</code>\n\n"
        "Kirim token reCAPTCHA ke chat ini. Token biasanya berlaku singkat.",
        "{\"inline_keyboard\":[[{\"text\":\"Batal\",\"callback_data\":\"cancel\",\"style\":\"danger\"}]]}");
}

static void send_hyfe_captcha_settings(const struct config *cfg, const char *chat)
{
    char active[32] = "manual";  /* default jika show-captcha gagal */
    char kb[1024];
    size_t ku = 0;
    /* Baca mode captcha yang sedang aktif */
    hyfe_get_active_captcha_mode(active, sizeof(active));
    /* Buat keyboard: tombol provider aktif = primary (biru), lainnya = danger (merah) */
    ku = 0;
    ku += snprintf(kb + ku, sizeof(kb) - ku, "{\"inline_keyboard\":[");
    /* Baris 1: manual, nextcaptcha */
    ku += snprintf(kb + ku, sizeof(kb) - ku,
        "[{\"text\":\"%smanual%s\",\"callback_data\":\"hyfesetcap:manual\",\"style\":\"%s\"},"
         "{\"text\":\"%snextcaptcha%s\",\"callback_data\":\"hyfesetcap:nextcaptcha\",\"style\":\"%s\"}],",
        strcmp(active,"manual")==0?"":"", strcmp(active,"manual")==0?" ✓":"",
        strcmp(active,"manual")==0?"primary":"danger",
        strcmp(active,"nextcaptcha")==0?"":"", strcmp(active,"nextcaptcha")==0?" ✓":"",
        strcmp(active,"nextcaptcha")==0?"primary":"danger");
    /* Baris 2: 2captcha, anticaptcha */
    ku += snprintf(kb + ku, sizeof(kb) - ku,
        "[{\"text\":\"%s2captcha%s\",\"callback_data\":\"hyfesetcap:2captcha\",\"style\":\"%s\"},"
         "{\"text\":\"%santicaptcha%s\",\"callback_data\":\"hyfesetcap:anticaptcha\",\"style\":\"%s\"}],",
        strcmp(active,"2captcha")==0?"":"", strcmp(active,"2captcha")==0?" ✓":"",
        strcmp(active,"2captcha")==0?"primary":"danger",
        strcmp(active,"anticaptcha")==0?"":"", strcmp(active,"anticaptcha")==0?" ✓":"",
        strcmp(active,"anticaptcha")==0?"primary":"danger");
    /* Baris 3: capsolver */
    ku += snprintf(kb + ku, sizeof(kb) - ku,
        "[{\"text\":\"%scapsolver%s\",\"callback_data\":\"hyfesetcap:capsolver\",\"style\":\"%s\"}],",
        strcmp(active,"capsolver")==0?"":"", strcmp(active,"capsolver")==0?" ✓":"",
        strcmp(active,"capsolver")==0?"primary":"danger");
    /* Baris 4: Kembali HYFE Setting */
    ku += snprintf(kb + ku, sizeof(kb) - ku,
        "[{\"text\":\"HYFE Setting\",\"callback_data\":\"hyfe:settings\",\"style\":\"primary\"}]]}");
    (void)ku;
    char header[256];
    snprintf(header, sizeof(header),
        "<b>HYFE Captcha</b>\n\n"
        "Mode aktif: <code>%s</code>\n\n"
        "Pilih provider. Untuk provider solver, bot akan meminta API key lalu menyimpannya ke config HYFE.",
        active);
    send_inline_keyboard(cfg, chat, header, kb);
}

static void send_hyfe_settings_menu(const struct config *cfg, const char *chat)
{
    char raw[BUF_MAX], escaped[3000], msg[MSG_MAX + 1];
    int rc = hyfe_show_config(raw, sizeof(raw));
    if (rc == 0) {
        html_escape_text(raw, escaped, sizeof(escaped));
        snprintf(msg, sizeof(msg),
            "<b>HYFE Setting</b>\n\n"
            "<code>%.2500s</code>\n\n"
            "Tujuan menu:\n"
            "- Setup Awal: wizard email, app password, captcha, OTP, dan EID.\n"
            "- Captcha: pilih manual atau solver otomatis untuk submit klaim.\n"
            "- OTP Manual/IMAP: tentukan OTP diketik user atau dibaca dari email.\n"
            "- IMAP URL/Folder/Subject/Timeout: lokasi dan batas tunggu email OTP.\n"
            "- LPA Timeout: batas tunggu bot mencari LPA/QR dari email setelah klaim sukses.\n"
            "- Email/App Password/EID Slot: akun dan EID yang dipakai klaim HYFE.\n\n"
            "Pilih config yang ingin diubah.",
            escaped);
    } else {
        snprintf(msg, sizeof(msg),
            "<b>HYFE Setting</b>\n\n"
            "Config belum terbaca.\n\n"
            "Setup Awal akan memandu email, app password, captcha, OTP, dan EID. "
            "Menu lain dipakai untuk mengubah bagian tertentu saja.");
    }
    send_inline_keyboard(cfg, chat, msg,
        "{\"inline_keyboard\":["
        "[{\"text\":\"Setup Awal\",\"callback_data\":\"hyfe:wizard:start\",\"style\":\"success\"}],"
        "[{\"text\":\"Captcha\",\"callback_data\":\"hyfe:captcha:settings\",\"style\":\"primary\"},"
        "{\"text\":\"OTP Manual\",\"callback_data\":\"hyfesetcfg:HYFE_OTP_MODE:manual\",\"style\":\"primary\"}],"
        "[{\"text\":\"OTP IMAP\",\"callback_data\":\"hyfesetcfg:HYFE_OTP_MODE:imap\",\"style\":\"primary\"},"
        "{\"text\":\"IMAP URL\",\"callback_data\":\"hyfeprompt:HYFE_IMAP_URL\",\"style\":\"primary\"}],"
        "[{\"text\":\"IMAP Folder\",\"callback_data\":\"hyfeprompt:HYFE_IMAP_FOLDER\",\"style\":\"primary\"},"
        "{\"text\":\"IMAP Subject\",\"callback_data\":\"hyfeprompt:HYFE_IMAP_SUBJECT\",\"style\":\"primary\"}],"
        "[{\"text\":\"IMAP Timeout\",\"callback_data\":\"hyfeprompt:HYFE_IMAP_TIMEOUT\",\"style\":\"primary\"},"
        "{\"text\":\"LPA Timeout\",\"callback_data\":\"hyfeprompt:HYFE_LPA_TIMEOUT\",\"style\":\"primary\"}],"
        "[{\"text\":\"Email Slot\",\"callback_data\":\"hyfeemail:slot\",\"style\":\"success\"},"
        "{\"text\":\"App Password Slot\",\"callback_data\":\"hyfepass:slot\",\"style\":\"success\"}],"
        "[{\"text\":\"EID Slot\",\"callback_data\":\"hyfeeid:slot\",\"style\":\"success\"}],"
        "[{\"text\":\"Refresh\",\"callback_data\":\"hyfe:settings\",\"style\":\"primary\"},"
        "{\"text\":\"Menu Utama\",\"callback_data\":\"menu:main\"}]]}");
}

static void answer_callback(const struct config *cfg, const char *callback_query_id)
{
    char url[240];
    char cq_arg[128];
    char out[256];
    char *argv[] = {
        "curl", "-fsS", "--max-time", "10", "-X", "POST", url,
        "-d", cq_arg, NULL
    };
    if (!callback_query_id || !callback_query_id[0]) return;
    snprintf(url, sizeof(url), "https://api.telegram.org/bot%s/answerCallbackQuery", cfg->token);
    snprintf(cq_arg, sizeof(cq_arg), "callback_query_id=%s", callback_query_id);
    run_capture(argv, out, sizeof(out), 12);
}

static void send_keyboard(const struct config *cfg, const char *chat_id, const char *text, const char *keyboard_json)
{
    char url[240];
    char chat_arg[96];
    char msg[MSG_MAX + 1];
    char markup[4096];
    char parse[32];
    char out[512];
    int rc;
    char *argv[] = {
        "curl", "-fsS", "--max-time", "15", "-X", "POST", url,
        "-d", chat_arg, "--data-urlencode", msg, "-d", markup, "-d", parse, NULL
    };

    if (!valid_chat_id(chat_id)) return;
    snprintf(url, sizeof(url), "https://api.telegram.org/bot%s/sendMessage", cfg->token);
    snprintf(chat_arg, sizeof(chat_arg), "chat_id=%s", chat_id);
    snprintf(msg, sizeof(msg), "text=%.*s", MSG_MAX - 5, text ? text : "");
    snprintf(markup, sizeof(markup), "reply_markup=%s", keyboard_json ? keyboard_json : "{}");
    snprintf(parse, sizeof(parse), "parse_mode=HTML");
    rc = run_capture(argv, out, sizeof(out), 20);
    if (rc != 0) log_msg("sendMessage keyboard failed rc=%d chat=%s", rc, chat_id);
}

static void send_main_menu(const struct config *cfg, const char *chat_id)
{
    send_keyboard(cfg, chat_id,
        "0xygen eSIM Bot\n"
        "Pilih menu tombol di bawah.",
        "{\"keyboard\":["
        "[{\"text\":\"Info EID\"}],"
        "[{\"text\":\"Profile List\"},{\"text\":\"Cek Kuota\"}],"
        "[{\"text\":\"Download eSIM\"}],"
        "[{\"text\":\"HYFE Trial\"},{\"text\":\"HYFE Setting\"}],"
        "[{\"text\":\"Settings\"},{\"text\":\"Tools\"}]"
        "],\"resize_keyboard\":true,\"one_time_keyboard\":false}");
}

static void send_back_menu(const struct config *cfg, const char *chat_id, const char *text)
{
    send_keyboard(cfg, chat_id, text,
        "{\"keyboard\":["
        "[{\"text\":\"Menu Utama\"}],"
        "[{\"text\":\"Profile List\"},{\"text\":\"Settings\"}]"
        "],\"resize_keyboard\":true,\"one_time_keyboard\":false}");
}

static char *json_string_after(char *start, const char *key, char *dst, size_t dstsz)
{
    char *p = strstr(start, key);
    size_t i = 0;
    if (!p || dstsz == 0) return NULL;
    p += strlen(key);
    while (*p && isspace((unsigned char)*p)) p++;
    if (*p != '"') return NULL;
    p++;
    while (*p && *p != '"' && i + 1 < dstsz) {
        if (*p == '\\' && p[1]) {
            p++;
            if (*p == 'n') dst[i++] = '\n';
            else if (*p == 'r') dst[i++] = '\r';
            else if (*p == 't') dst[i++] = '\t';
            else dst[i++] = *p;
        } else {
            dst[i++] = *p;
        }
        p++;
    }
    dst[i] = '\0';
    return (*p == '"') ? p + 1 : NULL;
}

static int json_chat_id_after(char *start, char *dst, size_t dstsz)
{
    char *chat = strstr(start, "\"chat\"");
    char *id;
    long long v;
    if (!chat) return 0;
    id = strstr(chat, "\"id\":");
    if (!id) return 0;
    id += 5;
    /* MUST be strtoll/%lld, not strtol/%ld. On 32-bit ARM, strtol() clamps
     * any chat ID above 2_147_483_647 to LONG_MAX, which then never matches
     * the configured allowed_chat_id and the bot silently drops the user's
     * messages. See note above save_offset(). */
    v = strtoll(id, NULL, 10);
    snprintf(dst, dstsz, "%lld", v);
    return valid_chat_id(dst);
}

static int cmd_match(const char *text, const char *cmd)
{
    size_t n = strlen(cmd);
    if (strncmp(text, cmd, n) != 0) return 0;
    return text[n] == '\0' || isspace((unsigned char)text[n]) || text[n] == '@';
}

static const char *cmd_args(const char *text)
{
    const char *p = text;
    while (*p && !isspace((unsigned char)*p)) p++;
    while (*p && isspace((unsigned char)*p)) p++;
    return p;
}

static int lpac_api(char *const extra[], char *out, size_t outsz, int timeout_sec)
{
    char *argv[16];
    int i = 0, j = 0;
    argv[i++] = "/usr/bin/lpac-esim";
    argv[i++] = "--api";
    while (extra[j] && i < 15) argv[i++] = extra[j++];
    argv[i] = NULL;
    return run_capture(argv, out, outsz, timeout_sec);
}

static int normalize_msisdn_c(const char *input, char *dst, size_t dstsz)
{
    char buf[48];
    size_t bi = 0;
    const char *p;

    if (!input || !*input || dstsz < 16) return 0;

    for (p = input; *p && bi < sizeof(buf) - 1; p++) {
        if (isdigit((unsigned char)*p)) buf[bi++] = *p;
        else if (*p == '+' && bi == 0) continue;
        else if (*p == ' ' || *p == '-' || *p == '.' || *p == '(' || *p == ')') continue;
        else return 0;
    }
    buf[bi] = '\0';
    if (bi == 0) return 0;

    if (buf[0] == '0') {
        if (strlen(buf + 1) + 2 >= dstsz) return 0;
        strcpy(dst, "62");
        strcat(dst, buf + 1);
    } else if (buf[0] == '8') {
        if (strlen(buf) + 2 >= dstsz) return 0;
        strcpy(dst, "62");
        strcat(dst, buf);
    } else {
        if (strlen(buf) >= dstsz) return 0;
        strcpy(dst, buf);
    }

    for (p = dst; *p; p++) if (!isdigit((unsigned char)*p)) return 0;
    bi = strlen(dst);
    return (bi >= 10 && bi <= 15);
}

/* Telegram quota checker.
 * Keep the parser in /usr/bin/esim so CLI and bot use one implementation. */
static int esim_quota(const char *msisdn_in, char *out, size_t outsz)
{
    char msisdn[48];
    char *argv[] = { "/usr/bin/esim", "--telegram-quota", msisdn, NULL };

    if (!normalize_msisdn_c(msisdn_in, msisdn, sizeof(msisdn))) {
        snprintf(out, outsz, "Nomor tidak valid.");
        return 1;
    }

    return run_capture(argv, out, outsz, 90);
}

/*
 * extract_msisdn_from_nick:
 *   Parse an XL phone number from a profile nickname/name string.
 *   Looks for patterns starting with +62, 62, 08, or 8 followed by 7-17 digits.
 *   Normalises to 62xxxxxxxxx format (Indonesian E.164 without leading +).
 *   Returns 1 and fills dst on success, 0 on failure.
 */
static int extract_msisdn_from_nick(const char *nick, char *dst, size_t dstsz)
{
    const char *p = nick;
    size_t len;

    if (!nick || !*nick || dstsz < 8) return 0;

    for (; *p; p++) {
        const char *start = NULL;
        char buf[48];
        size_t bi = 0;
        int digits = 0;

        /* Match start patterns: +62, 62, 08, 8 */
        if (p[0] == '+' && p[1] == '6' && p[2] == '2' && isdigit((unsigned char)p[3])) {
            start = p + 1; /* skip '+', keep 62... */
        } else if (p[0] == '6' && p[1] == '2' && isdigit((unsigned char)p[2])) {
            start = p;
        } else if (p[0] == '0' && p[1] == '8' && isdigit((unsigned char)p[2])) {
            start = p;     /* 08x... */
        } else if (p[0] == '8' && isdigit((unsigned char)p[1])) {
            start = p;
        } else {
            continue;
        }

        /* Collect digits (and strip spaces/dots/dashes/parens inline) */
        const char *q = start;
        while (*q && bi < sizeof(buf) - 1) {
            if (isdigit((unsigned char)*q)) {
                buf[bi++] = *q;
                digits++;
            } else if (*q == ' ' || *q == '.' || *q == '-' ||
                       *q == '(' || *q == ')') {
                /* allowed separators – keep scanning */
            } else {
                break;
            }
            q++;
        }
        buf[bi] = '\0';

        if (digits < 9 || digits > 15) continue; /* too short or too long */

        /* Normalise to 62xxxxxxxxx */
        char norm[48];
        if (buf[0] == '0') {
            /* 08x -> 628x */
            if (strlen(buf + 1) + 2 >= sizeof(norm)) continue;
            strcpy(norm, "62");
            strcat(norm, buf + 1);
        } else if (buf[0] == '8') {
            /* 8x -> 628x */
            if (strlen(buf) + 2 >= sizeof(norm)) continue;
            strcpy(norm, "62");
            strcat(norm, buf);
        } else {
            /* already 62x */
            if (strlen(buf) >= sizeof(norm)) continue;
            strcpy(norm, buf);
        }

        len = strlen(norm);
        if (len < 10 || len > 15 || len >= dstsz) continue;

        strcpy(dst, norm);
        return 1;
    }
    return 0;
}

static void compact_result(const char *json, char *dst, size_t dstsz)
{
    char msg[160] = "";
    char detail[512] = "";
    char *copy = strdup(json ? json : "");
    if (!copy) {
        snprintf(dst, dstsz, "No response");
        return;
    }
    json_string_after(copy, "\"message\":", msg, sizeof(msg));
    json_string_after(copy, "\"msg\":", detail, sizeof(detail));
    if (detail[0])
        snprintf(dst, dstsz, "%s: %s", msg[0] ? msg : "result", detail);
    else if (msg[0])
        snprintf(dst, dstsz, "%s", msg);
    else
        snprintf(dst, dstsz, "%.3500s", json ? json : "No response");
    free(copy);
}

static int contains_ci(const char *s, const char *needle)
{
    size_t nlen;
    if (!s || !needle || !*needle) return 0;
    nlen = strlen(needle);
    for (; *s; s++) {
        size_t i;
        for (i = 0; i < nlen; i++) {
            if (!s[i]) return 0;
            if (tolower((unsigned char)s[i]) != tolower((unsigned char)needle[i])) break;
        }
        if (i == nlen) return 1;
    }
    return 0;
}

static int json_key_is_true(const char *json, const char *key)
{
    char pat[64];
    const char *p;
    snprintf(pat, sizeof(pat), "\"%s\"", key ? key : "");
    p = strstr(json ? json : "", pat);
    if (!p) return 0;
    p = strchr(p + strlen(pat), ':');
    if (!p) return 0;
    p++;
    while (*p && isspace((unsigned char)*p)) p++;
    return strncmp(p, "true", 4) == 0;
}

static int lpac_result_is_processing(const char *json, const char *compact)
{
    if (compact && strcmp(compact, "processing") == 0) return 1;
    if (json && strstr(json, "\"message\":\"processing\"")) return 1;
    return 0;
}

static int poll_lpac_lock_result(char *out, size_t outsz, int timeout_sec)
{
    int elapsed = 0;
    int rc = 1;
    char lock_out[BUF_MAX];
    char *args[] = { "lock-status", NULL };

    if (!out || outsz == 0) return 1;
    out[0] = '\0';
    while (elapsed < timeout_sec) {
        sleep(5);
        elapsed += 5;
        rc = lpac_api(args, lock_out, sizeof(lock_out), 10);
        if (rc != 0 || !lock_out[0]) continue;
        snprintf(out, outsz, "%.65000s", lock_out);
        if (!json_key_is_true(lock_out, "locked")) return 0;
    }
    return 124;
}

static void send_download_result(const struct config *cfg, const char *chat, int rc, const char *out)
{
    char compact[1600], escaped[2200], msg[MSG_MAX + 1];
    char lock_out[BUF_MAX], lock_msg[1600], lock_escaped[2200];
    int lock_rc;

    compact_result(out, compact, sizeof(compact));
    if (!compact[0]) snprintf(compact, sizeof(compact), "No response from LPAC.");
    html_escape_text(compact, escaped, sizeof(escaped));

    if (rc != 0) {
        snprintf(msg, sizeof(msg),
            "<b>Download eSIM gagal</b>\n\n"
            "Exit code: <code>%d</code>\n"
            "Output LPAC:\n<code>%.1800s</code>",
            rc, escaped);
        send_inline_keyboard(cfg, chat, msg,
            "{\"inline_keyboard\":[[{\"text\":\"Coba Lagi\",\"callback_data\":\"menu:download\",\"style\":\"primary\"},"
            "{\"text\":\"Menu\",\"callback_data\":\"menu:main\"}]]}");
        return;
    }

    if (!lpac_result_is_processing(out, compact)) {
        const char *title = (contains_ci(compact, "error") || contains_ci(compact, "fail")) ?
            "Download eSIM selesai dengan peringatan" : "Download eSIM selesai";
        snprintf(msg, sizeof(msg),
            "<b>%s</b>\n\n"
            "Output LPAC:\n<code>%.1800s</code>",
            title, escaped);
        send_inline_keyboard(cfg, chat, msg,
            "{\"inline_keyboard\":[[{\"text\":\"Profile List\",\"callback_data\":\"menu:profiles\",\"style\":\"primary\"},"
            "{\"text\":\"Process Notifications\",\"callback_data\":\"menu:notifprocess\",\"style\":\"success\"}],"
            "[{\"text\":\"Menu\",\"callback_data\":\"menu:main\"}]]}");
        return;
    }

    lock_rc = poll_lpac_lock_result(lock_out, sizeof(lock_out), 180);
    if (lock_rc == 0 && lock_out[0]) {
        compact_result(lock_out, lock_msg, sizeof(lock_msg));
        if (!lock_msg[0]) snprintf(lock_msg, sizeof(lock_msg), "%.1200s", lock_out);
        html_escape_text(lock_msg, lock_escaped, sizeof(lock_escaped));
        if (strstr(lock_out, "\"success\":false") || contains_ci(lock_msg, "fail") || contains_ci(lock_msg, "error")) {
            snprintf(msg, sizeof(msg),
                "<b>Download eSIM gagal</b>\n\n"
                "Hasil akhir LPAC:\n<code>%.1800s</code>",
                lock_escaped);
        } else {
            snprintf(msg, sizeof(msg),
                "<b>Download eSIM selesai</b>\n\n"
                "Hasil akhir LPAC:\n<code>%.1800s</code>\n\n"
                "Jika profil belum aktif, jalankan Process Notifications lalu cek Profile List.",
                lock_escaped);
        }
    } else {
        snprintf(msg, sizeof(msg),
            "<b>Download eSIM masih diproses</b>\n\n"
            "LPAC mengembalikan:\n<code>%.1800s</code>\n\n"
            "Bot sudah menunggu 180 detik tetapi backend belum memberi hasil akhir. "
            "Cek Profile List atau Process Notifications untuk melihat status lanjutan.",
            escaped);
    }
    send_inline_keyboard(cfg, chat, msg,
        "{\"inline_keyboard\":[[{\"text\":\"Profile List\",\"callback_data\":\"menu:profiles\",\"style\":\"primary\"},"
        "{\"text\":\"Process Notifications\",\"callback_data\":\"menu:notifprocess\",\"style\":\"success\"}],"
        "[{\"text\":\"Download Lagi\",\"callback_data\":\"menu:download\",\"style\":\"primary\"},"
        "{\"text\":\"Menu\",\"callback_data\":\"menu:main\"}]]}");
}

static const char *profile_label(const char *action)
{
    if (strcmp(action, "switch") == 0) return "Switch / Enable";
    if (strcmp(action, "disable") == 0) return "Disable";
    if (strcmp(action, "delete") == 0) return "Delete";
    return "Action";
}

/* -----------------------------------------------------------------------
 * format_eid_info: parse chip/EID JSON from lpac-esim API chip and
 * produce a human-readable Telegram message.
 *
 * Expected JSON fields (lpac chip output):
 *   eid, freeNvram, usedNvram, freeRam (all optional).
 * ----------------------------------------------------------------------- */
static void format_eid_info(const char *chip_json, const char *profiles_json,
                            char *dst, size_t dstsz)
{
    char eid[64] = "-";
    char free_nvram[32] = "-";
    char used_nvram[32] = "-";
    char free_ram[32] = "-";
    char *copy_chip = strdup(chip_json ? chip_json : "");
    char *copy_prof = strdup(profiles_json ? profiles_json : "");
    int prof_count = 0;
    char *p;
    size_t used = 0;

    if (!copy_chip || !copy_prof) {
        snprintf(dst, dstsz, "No memory");
        free(copy_chip);
        free(copy_prof);
        return;
    }

    /* Parse EID — lpac outputs "eidValue" (from LPA spec), not "eid"/"EID".
     * Fall through to the shorter variants as a safety net in case a future
     * lpac build normalises the name. */
    json_string_after(copy_chip, "\"eidValue\":", eid, sizeof(eid));
    if (!eid[0] || strcmp(eid, "-") == 0)
        json_string_after(copy_chip, "\"eid\":", eid, sizeof(eid));
    if (!eid[0] || strcmp(eid, "-") == 0)
        json_string_after(copy_chip, "\"EID\":", eid, sizeof(eid));

    /* Parse storage */
    json_string_after(copy_chip, "\"freeNvram\":", free_nvram, sizeof(free_nvram));
    json_string_after(copy_chip, "\"usedNvram\":", used_nvram, sizeof(used_nvram));
    json_string_after(copy_chip, "\"freeRam\":", free_ram, sizeof(free_ram));

    /* Count profiles */
    p = copy_prof;
    while ((p = strstr(p, "\"iccid\":"))) { prof_count++; p += 8; }

    used += snprintf(dst + used, dstsz - used,
        "📱 <b>Info eUICC / eSIM Chip</b>\n\n"
        "🔑 <b>EID:</b>\n<code>%s</code>\n\n"
        "📂 <b>Profiles:</b> %d profil tersimpan\n",
        eid[0] ? eid : "(tidak terbaca)",
        prof_count);

    if (free_nvram[0] && strcmp(free_nvram, "-") != 0)
        used += snprintf(dst + used, dstsz - used,
            "💾 <b>Storage:</b>\n"
            "  • Digunakan : %s bytes\n"
            "  • Tersisa   : %s bytes\n",
            used_nvram[0] ? used_nvram : "?",
            free_nvram);

    if (free_ram[0] && strcmp(free_ram, "-") != 0)
        used += snprintf(dst + used, dstsz - used,
            "🧠 <b>RAM Sisa:</b> %s bytes\n",
            free_ram);

    free(copy_chip);
    free(copy_prof);
}

/* -----------------------------------------------------------------------
 * send_profile_menu_inline:
 *   - Fetch profile list from lpac
 *   - Active profile goes FIRST with wide button (full-row) in blue
 *   - Inactive profiles follow in red, 2-per-row when count is odd
 *   - Each button tap triggers "switch" with confirm Y/N
 *   - Bottom row: 🗑 Delete button(s) + 📥 Download button
 * ----------------------------------------------------------------------- */

/* Parse profiles JSON and fill arrays. Returns count (max MAX_PROFILES). */
typedef struct {
    char iccid[40];
    char state[24];   /* "enabled" or "disabled" */
    char provider[48];
    char nick[48];
} profile_t;

static int parse_profiles(const char *json, profile_t *arr, int maxn)
{
    char *copy = strdup(json ? json : "");
    char *p;
    int n = 0;
    if (!copy) return 0;
    p = copy;
    while ((p = strstr(p, "\"iccid\":")) && n < maxn) {
        char *row_start = p;
        char iccid[40] = "", state[24] = "", provider[48] = "", nick[48] = "";
        json_string_after(row_start, "\"iccid\":", iccid, sizeof(iccid));
        json_string_after(row_start, "\"profileState\":", state, sizeof(state));
        json_string_after(row_start, "\"serviceProviderName\":", provider, sizeof(provider));
        json_string_after(row_start, "\"profileNickname\":", nick, sizeof(nick));
        if (iccid[0]) {
            snprintf(arr[n].iccid, sizeof(arr[n].iccid), "%s", iccid);
            snprintf(arr[n].state, sizeof(arr[n].state), "%s", state);
            snprintf(arr[n].provider, sizeof(arr[n].provider), "%s", provider);
            snprintf(arr[n].nick, sizeof(arr[n].nick), "%s", nick);
            n++;
        }
        p += 8;
    }
    free(copy);
    return n;
}

static int profile_is_active_iccid(const char *iccid)
{
    char out[BUF_MAX];
    char *args[] = { "profiles", NULL };
    profile_t profiles[MAX_PROFILES];
    int count, i;
    if (!iccid || !*iccid) return 0;
    if (lpac_api(args, out, sizeof(out), 35) != 0) return 0;
    count = parse_profiles(out, profiles, MAX_PROFILES);
    for (i = 0; i < count; i++) {
        if (strcmp(profiles[i].iccid, iccid) == 0) {
            return strcasecmp(profiles[i].state, "enabled") == 0;
        }
    }
    return 0;
}


/* Build inline keyboard JSON for profile list.
 * Active profile → full-width row (blue via emoji label).
 * Inactive → pairs of 2 per row (red via emoji label).
 * Bottom: [🗑 Del <iccid1>] [🗑 Del <iccid2>] ... then [📥 Download eSIM] */
static void build_profile_keyboard(const profile_t *profiles, int count, char *dst, size_t dstsz)
{
    size_t used = 0;
    int i;
    int active_idx = -1;
    int first_row = 1;

    for (i = 0; i < count; i++) {
        if (strcasecmp(profiles[i].state, "enabled") == 0) { active_idx = i; break; }
    }

    used += snprintf(dst + used, dstsz - used, "{\"inline_keyboard\":[");

    /* Active profile first. Real Telegram button color uses style=primary. */
    if (active_idx >= 0) {
        const profile_t *p = &profiles[active_idx];
        char display[56], label[96], esc[128];
        if (p->nick[0]) snprintf(display, sizeof(display), "%.48s", p->nick);
        else if (p->provider[0]) snprintf(display, sizeof(display), "%.48s", p->provider);
        else snprintf(display, sizeof(display), "%.12s...", p->iccid);
        snprintf(label, sizeof(label), "Aktif • %s", display);
        json_escape(label, esc, sizeof(esc));
        used += snprintf(dst + used, dstsz - used,
            "[{\"text\":\"%s 🔒\",\"callback_data\":\"noop\",\"style\":\"primary\"}]",
            esc);
        first_row = 0;
    }

    /* Inactive profiles: 2 per row, no "Nonaktif" prefix. style=danger. */
    {
        int col = 0;
        for (i = 0; i < count && i < MAX_PROFILES; i++) {
            const profile_t *p = &profiles[i];
            char display[56], esc[128];
            if (i == active_idx) continue;
            if (p->nick[0]) snprintf(display, sizeof(display), "%.48s", p->nick);
            else if (p->provider[0]) snprintf(display, sizeof(display), "%.48s", p->provider);
            else snprintf(display, sizeof(display), "%.12s...", p->iccid);
            json_escape(display, esc, sizeof(esc));
            if (col == 0) {
                if (!first_row) used += snprintf(dst + used, dstsz - used, ",");
                used += snprintf(dst + used, dstsz - used, "[");
                first_row = 0;
            } else {
                used += snprintf(dst + used, dstsz - used, ",");
            }
            used += snprintf(dst + used, dstsz - used,
                "{\"text\":\"%s\",\"callback_data\":\"sw:%.38s\",\"style\":\"danger\"}",
                esc, p->iccid);
            col++;
            if (col == 2) { used += snprintf(dst + used, dstsz - used, "]"); col = 0; }
        }
        if (col != 0) used += snprintf(dst + used, dstsz - used, "]");
    }

    used += snprintf(dst + used, dstsz - used,
        ",[{\"text\":\"⚡ Manage Profile\",\"callback_data\":\"menu:manage\",\"style\":\"primary\"}]"
        ",[{\"text\":\"📥 Download eSIM\",\"callback_data\":\"menu:download\",\"style\":\"success\"}]"
        ",[{\"text\":\"🏠 Menu Utama\",\"callback_data\":\"menu:main\"}]"
        "]}");
}

static void send_profile_menu(const struct config *cfg, const char *chat_id)
{
    char out[BUF_MAX];
    char msg[MSG_MAX + 1];
    char keyboard[4096];
    profile_t profiles[MAX_PROFILES];
    int count = 0;
    int rc;
    char *args[] = { "profiles", NULL };

    rc = lpac_api(args, out, sizeof(out), 35);
    if (rc != 0) {
        snprintf(msg, sizeof(msg), "❌ Gagal membaca profiles (rc=%d).", rc);
        send_keyboard(cfg, chat_id, msg,
            "{\"keyboard\":[[{\"text\":\"Menu Utama\"}]],\"resize_keyboard\":true}");
        return;
    }

    count = parse_profiles(out, profiles, MAX_PROFILES);

    if (count == 0) {
        snprintf(msg, sizeof(msg),
            "📋 <b>Profile List</b>\n\n"
            "Tidak ada eSIM profile tersimpan di eUICC.");
        send_inline_keyboard(cfg, chat_id, msg,
            "{\"inline_keyboard\":["
            "[{\"text\":\"📥 Download eSIM\",\"callback_data\":\"menu:download\"}],"
            "[{\"text\":\"🏠 Menu Utama\",\"callback_data\":\"menu:main\"}]"
            "]}");
        return;
    }

    {
        int i, active_idx = -1;
        size_t used = 0;
        for (i = 0; i < count; i++)
            if (strcasecmp(profiles[i].state, "enabled") == 0) { active_idx = i; break; }

        used += snprintf(msg + used, sizeof(msg) - used,
            "📋 <b>Profile List eSIM</b> (%d profil)\n\n", count);

        /* Legend */
        used += snprintf(msg + used, sizeof(msg) - used,
            "🔵 = Aktif (tap untuk switch)\n"
            "🔴 = Tidak aktif (tap untuk switch/enable)\n"
            "🗑 = Hapus profil\n\n");

        if (active_idx >= 0) {
            const profile_t *ap = &profiles[active_idx];
            used += snprintf(msg + used, sizeof(msg) - used,
                "✅ <b>Profil Aktif:</b> <code>%s</code>",
                ap->iccid);
            if (ap->provider[0])
                used += snprintf(msg + used, sizeof(msg) - used, " (%s)", ap->provider);
            used += snprintf(msg + used, sizeof(msg) - used, "\n");
        }
    }

    build_profile_keyboard(profiles, count, keyboard, sizeof(keyboard));
    send_inline_keyboard(cfg, chat_id, msg, keyboard);
}

static void send_manage_profile_menu(const struct config *cfg, const char *chat_id)
{
    char out[BUF_MAX];
    char msg[MSG_MAX + 1];
    char keyboard[4096];
    profile_t profiles[MAX_PROFILES];
    int count = 0, i, disabled_count = 0;
    size_t used = 0;
    char *args[] = { "profiles", NULL };

    if (lpac_api(args, out, sizeof(out), 35) != 0) {
        send_inline_keyboard(cfg, chat_id, "❌ Gagal membaca profile list.",
            "{\"inline_keyboard\":[[{\"text\":\"🏠 Menu Utama\",\"callback_data\":\"menu:main\"}]]}");
        return;
    }
    count = parse_profiles(out, profiles, MAX_PROFILES);

    used += snprintf(msg + used, sizeof(msg) - used,
        "🗑 <b>Manage Profile</b>\n\n"
        "Pilih profil yang ingin dihapus.\n"
        "⚠️ Profil <b>ACTIVE</b> dikunci dan tidak ditampilkan sebagai tombol hapus.\n\n");

    for (i = 0; i < count && used < sizeof(msg) - 100; i++) {
        int active = (strcasecmp(profiles[i].state, "enabled") == 0);
        const char *dot = active ? "🔵" : "🔴";
        const char *name = profiles[i].nick[0] ? profiles[i].nick
                         : (profiles[i].provider[0] ? profiles[i].provider : profiles[i].iccid);
        used += snprintf(msg + used, sizeof(msg) - used,
            "%s %s%s\n", dot, name, active ? "  🔒" : "");
        if (!active) disabled_count++;
    }

    used = 0;
    used += snprintf(keyboard + used, sizeof(keyboard) - used, "{\"inline_keyboard\":[");

    if (disabled_count == 0) {
        used += snprintf(keyboard + used, sizeof(keyboard) - used,
            "[{\"text\":\"Tidak ada profil disabled\",\"callback_data\":\"noop\"}]");
    } else {
        int col = 0, first_row = 1;
        for (i = 0; i < count && i < MAX_PROFILES; i++) {
            const profile_t *p = &profiles[i];
            char disp[32], label[80], esc[128];
            if (strcasecmp(p->state, "enabled") == 0) continue;
            snprintf(disp, sizeof(disp), "%.28s", p->nick[0] ? p->nick : (p->provider[0] ? p->provider : p->iccid));
            snprintf(label, sizeof(label), "🗑 %s", disp);
            json_escape(label, esc, sizeof(esc));
            if (col == 0) {
                if (!first_row) used += snprintf(keyboard + used, sizeof(keyboard) - used, ",");
                used += snprintf(keyboard + used, sizeof(keyboard) - used, "[");
                first_row = 0;
            } else {
                used += snprintf(keyboard + used, sizeof(keyboard) - used, ",");
            }
            used += snprintf(keyboard + used, sizeof(keyboard) - used,
                "{\"text\":\"%s\",\"callback_data\":\"del:%.38s\",\"style\":\"danger\"}", esc, p->iccid);
            col++;
            if (col == 2) { used += snprintf(keyboard + used, sizeof(keyboard) - used, "]"); col = 0; }
        }
        if (col != 0) used += snprintf(keyboard + used, sizeof(keyboard) - used, "]");
    }

    used += snprintf(keyboard + used, sizeof(keyboard) - used,
        ",[{\"text\":\"📋 Profile List\",\"callback_data\":\"menu:profiles\",\"style\":\"primary\"},"
        "{\"text\":\"🏠 Menu Utama\",\"callback_data\":\"menu:main\"}]"
        "]}");

    send_inline_keyboard(cfg, chat_id, msg, keyboard);
}

/*
 * send_quota_menu:
 *   Show inline keyboard listing all eSIM profiles. Each button shows the
 *   profile name and – if a phone number can be parsed from the nickname –
 *   the masked MSISDN. Tapping a profile immediately triggers quota check
 *   (callback_data: "qc:<iccid>"). A final "Manual" button (qc:manual)
 *   lets the user type any MSISDN. No confirmation step.
 */
static void send_quota_menu(const struct config *cfg, const char *chat_id)
{
    char out[BUF_MAX];
    char msg[MSG_MAX + 1];
    char keyboard[4096];
    profile_t profiles[MAX_PROFILES];
    int count = 0, i, shown = 0;
    size_t km = 0, mm = 0;
    char *args[] = { "profiles", NULL };
    int rc;

    rc = lpac_api(args, out, sizeof(out), 35);
    if (rc != 0) {
        snprintf(msg, sizeof(msg), "\xE2\x9D\x8C Gagal membaca profiles (rc=%d).", rc);
        send_inline_keyboard(cfg, chat_id, msg,
            "{\"inline_keyboard\":["
            "[{\"text\":\"\xF0\x9F\x8F\xA0 Menu Utama\",\"callback_data\":\"menu:main\"}]"
            "]}");
        return;
    }

    count = parse_profiles(out, profiles, MAX_PROFILES);

    /* Build message header */
    mm += snprintf(msg + mm, sizeof(msg) - mm,
        "\xF0\x9F\x93\x8A <b>Cek Kuota XL</b>\n\n"
        "Pilih nomor untuk cek kuota:\n");

    /* Build inline keyboard. Quota menu intentionally shows numbers only. */
    km += snprintf(keyboard + km, sizeof(keyboard) - km, "{\"inline_keyboard\":[");

    {
        int col = 0;

        for (i = 0; i < count && i < MAX_PROFILES; i++) {
            const profile_t *pa = &profiles[i];
            char msisdn_a[32] = "";
            char disp_a[32], label_a[64], esc_a[96];
            const char *name_a = pa->nick[0] ? pa->nick
                               : (pa->provider[0] ? pa->provider : pa->iccid);

            if (!extract_msisdn_from_nick(name_a, msisdn_a, sizeof(msisdn_a)))
                continue;

            if (strncmp(msisdn_a, "62", 2) == 0 && msisdn_a[2]) {
                snprintf(disp_a, sizeof(disp_a), "0%.28s", msisdn_a + 2);
            } else if (msisdn_a[0] == '8') {
                snprintf(disp_a, sizeof(disp_a), "0%.28s", msisdn_a);
            } else {
                snprintf(disp_a, sizeof(disp_a), "%.30s", msisdn_a);
            }
            snprintf(label_a, sizeof(label_a), "\xF0\x9F\x93\xB6 %s", disp_a);
            json_escape(label_a, esc_a, sizeof(esc_a));

            if (col == 0) {
                if (shown > 0) km += snprintf(keyboard + km, sizeof(keyboard) - km, ",");
                km += snprintf(keyboard + km, sizeof(keyboard) - km, "[");
            } else {
                km += snprintf(keyboard + km, sizeof(keyboard) - km, ",");
            }

            km += snprintf(keyboard + km, sizeof(keyboard) - km,
                "{\"text\":\"%.72s\",\"callback_data\":\"qc:%.38s\",\"style\":\"success\"}",
                esc_a, pa->iccid);

            shown++;
            col++;
            if (col == 2) {
                km += snprintf(keyboard + km, sizeof(keyboard) - km, "]");
                col = 0;
            }
        }

        if (col != 0) km += snprintf(keyboard + km, sizeof(keyboard) - km, "]");
    }

    /* Manual button + back */
    km += snprintf(keyboard + km, sizeof(keyboard) - km,
        "%s[{\"text\":\"\xE2\x9C\x8F Manual (nomor lain)\",\"callback_data\":\"qc:manual\"}]"
        ",[{\"text\":\"\xF0\x9F\x8F\xA0 Menu Utama\",\"callback_data\":\"menu:main\"}]"
        "]}",
        shown > 0 ? "," : "");

    send_inline_keyboard(cfg, chat_id, msg, keyboard);
}


static int save_config_value(const char *key, const char *value, char *out, size_t outsz);

static int set_many_config(const char *pairs[][2], int count, char *out, size_t outsz)
{
    int i, rc = 0;
    char tmp[512];
    out[0] = '\0';
    for (i = 0; i < count; i++) {
        rc = save_config_value(pairs[i][0], pairs[i][1], tmp, sizeof(tmp));
        if (rc != 0) {
            snprintf(out, outsz, "Gagal set %s=%s: %.300s", pairs[i][0], pairs[i][1], tmp);
            return rc;
        }
    }
    snprintf(out, outsz, "OK");
    return 0;
}

static int apply_modem_preset(const char *preset, char *out, size_t outsz)
{
    if (strcmp(preset, "l850gl") == 0) {
        const char *pairs[][2] = {
            {"modem_profile", "l850gl"},
            {"apdu_backend", "mbim"},
            {"qmi_device", "/dev/cdc-wdm0"},
            {"qmi_sim_slot", "1"},
            {"sim_slot", "0"},
            {"at_device", "/dev/ttyACM0"},
            {"mbim_device", "/dev/cdc-wdm0"},
            {"mbim_proxy", "1"},
            {"mbim_skip_slot_mapping", "1"},
            {"custom_isd_r_aid", "A0000005591010FFFFFFFF8900000100"},
            {"reboot_method", "script"},
            {"modem_iface", "modem"}
        };
        return set_many_config(pairs, (int)(sizeof(pairs) / sizeof(pairs[0])), out, outsz);
    }

    if (strcmp(preset, "t99w175") == 0) {
        const char *pairs[][2] = {
            {"modem_profile", "t99w175"},
            {"apdu_backend", "mbim"},
            {"qmi_device", "/dev/cdc-wdm0"},
            {"qmi_sim_slot", "1"},
            {"sim_slot", "1"},
            {"at_device", "/dev/ttyUSB2"},
            {"mbim_device", "/dev/cdc-wdm0"},
            {"mbim_proxy", "1"},
            {"mbim_skip_slot_mapping", "0"},
            {"custom_isd_r_aid", "A0000005591010FFFFFFFF8900000100"},
            {"reboot_method", "script"},
            {"modem_iface", "modem"}
        };
        return set_many_config(pairs, (int)(sizeof(pairs) / sizeof(pairs[0])), out, outsz);
    }

    snprintf(out, outsz, "Preset modem tidak dikenal.");
    return 1;
}

static int toggle_config_key(const char *key, char *out, size_t outsz)
{
    int cur;
    if (strcmp(key, "debug") == 0) {
        cur = uci_bool("apdu_debug", 0) || uci_bool("http_debug", 0) || uci_bool("at_debug", 0);
        save_config_value("apdu_debug", cur ? "0" : "1", out, outsz);
        save_config_value("http_debug", cur ? "0" : "1", out, outsz);
        return save_config_value("at_debug", cur ? "0" : "1", out, outsz);
    }
    if (strcmp(key, "mbim_proxy") != 0 && strcmp(key, "mbim_skip_slot_mapping") != 0) {
        snprintf(out, outsz, "Toggle tidak valid.");
        return 1;
    }
    cur = uci_bool(key, 0);
    return save_config_value(key, cur ? "0" : "1", out, outsz);
}

static void send_settings_menu(const struct config *cfg, const char *chat_id)
{
    char msg[MSG_MAX + 1];
    char keyboard[4096];
    char backend[24], qmi_device[64], qmi_slot[8], sim_slot[8], at_device[64];
    char mbim_device[64], aid[80], reboot_method[32], modem_iface[32], modem_profile[32];
    int mbim_proxy, skip_slot, debug_on;
    size_t used = 0;

    (void)cfg;
    uci_value_or("apdu_backend", "mbim", backend, sizeof(backend));
    uci_value_or("qmi_device", "/dev/cdc-wdm0", qmi_device, sizeof(qmi_device));
    uci_value_or("qmi_sim_slot", "1", qmi_slot, sizeof(qmi_slot));
    uci_value_or("sim_slot", "0", sim_slot, sizeof(sim_slot));
    uci_value_or("at_device", "/dev/ttyACM0", at_device, sizeof(at_device));
    uci_value_or("mbim_device", "/dev/cdc-wdm0", mbim_device, sizeof(mbim_device));
    uci_value_or("custom_isd_r_aid", "A0000005591010FFFFFFFF8900000100", aid, sizeof(aid));
    uci_value_or("reboot_method", "script", reboot_method, sizeof(reboot_method));
    uci_value_or("modem_iface", "modem", modem_iface, sizeof(modem_iface));
    uci_value_or("modem_profile", "l850gl", modem_profile, sizeof(modem_profile));
    mbim_proxy = uci_bool("mbim_proxy", 1);
    skip_slot = uci_bool("mbim_skip_slot_mapping", 1);
    debug_on = uci_bool("apdu_debug", 0) || uci_bool("http_debug", 0) || uci_bool("at_debug", 0);

    snprintf(msg, sizeof(msg),
        "⚙️ <b>Settings LPAC saat ini</b>\n\n"
        "<b>Preset modem:</b> <code>%s</code>\n"
        "<b>APDU backend:</b> <code>%s</code>\n"
        "<b>QMI device:</b> <code>%s</code>\n"
        "<b>QMI slot:</b> <code>%s</code>\n"
        "<b>SIM slot:</b> <code>%s</code>\n"
        "<b>AT device:</b> <code>%s</code>\n"
        "<b>MBIM device:</b> <code>%s</code>\n"
        "<b>MBIM proxy:</b> <code>%s</code>\n"
        "<b>Skip slot mapping:</b> <code>%s</code>\n"
        "<b>ISD-R AID:</b> <code>%s</code>\n"
        "<b>Reboot method:</b> <code>%s</code>\n"
        "<b>Modem iface:</b> <code>%s</code>\n"
        "<b>Debug:</b> <code>%s</code>\n\n"
        "Tekan tombol untuk mengubah setting. Tombol biru = aktif/ON, merah = tidak aktif/OFF.",
        modem_profile, backend, qmi_device, qmi_slot, sim_slot, at_device,
        mbim_device, onoff_text(mbim_proxy), onoff_text(skip_slot), aid,
        reboot_method, modem_iface, onoff_text(debug_on));

    used += snprintf(keyboard + used, sizeof(keyboard) - used, "{\"inline_keyboard\":[");
    used += snprintf(keyboard + used, sizeof(keyboard) - used,
        "[{\"text\":\"Backend QMI\",\"callback_data\":\"cfg:backend:qmi\",\"style\":\"%s\"},"
        "{\"text\":\"Backend MBIM\",\"callback_data\":\"cfg:backend:mbim\",\"style\":\"%s\"},"
        "{\"text\":\"Backend AT\",\"callback_data\":\"cfg:backend:at\",\"style\":\"%s\"}]",
        style_active(strcmp(backend, "qmi") == 0), style_active(strcmp(backend, "mbim") == 0), style_active(strcmp(backend, "at") == 0));
    used += snprintf(keyboard + used, sizeof(keyboard) - used,
        ",[{\"text\":\"SIM Slot 0\",\"callback_data\":\"cfg:sim:0\",\"style\":\"%s\"},"
        "{\"text\":\"SIM Slot 1\",\"callback_data\":\"cfg:sim:1\",\"style\":\"%s\"}]",
        style_active(strcmp(sim_slot, "0") == 0), style_active(strcmp(sim_slot, "1") == 0));
    used += snprintf(keyboard + used, sizeof(keyboard) - used,
        ",[{\"text\":\"MBIM Proxy: %s\",\"callback_data\":\"cfg:toggle:mbim_proxy\",\"style\":\"%s\"},"
        "{\"text\":\"Skip Slot Mapping: %s\",\"callback_data\":\"cfg:toggle:mbim_skip_slot_mapping\",\"style\":\"%s\"}]",
        onoff_text(mbim_proxy), style_active(mbim_proxy), onoff_text(skip_slot), style_active(skip_slot));
    used += snprintf(keyboard + used, sizeof(keyboard) - used,
        ",[{\"text\":\"Debug: %s\",\"callback_data\":\"cfg:toggle:debug\",\"style\":\"%s\"},"
        "{\"text\":\"Edit Custom ISD-R AID\",\"callback_data\":\"cfg:aid:edit\",\"style\":\"primary\"}]",
        onoff_text(debug_on), style_active(debug_on));
    used += snprintf(keyboard + used, sizeof(keyboard) - used,
        ",[{\"text\":\"Preset L850GL\",\"callback_data\":\"preset:l850gl\",\"style\":\"%s\"},"
        "{\"text\":\"Preset T99W175 USB\",\"callback_data\":\"preset:t99w175\",\"style\":\"%s\"}]",
        style_active(strcmp(modem_profile, "l850gl") == 0), style_active(strcmp(modem_profile, "t99w175") == 0));
    used += snprintf(keyboard + used, sizeof(keyboard) - used,
        ",[{\"text\":\"Set AID Default\",\"callback_data\":\"cfg:aid:default\",\"style\":\"success\"},"
        "{\"text\":\"Refresh\",\"callback_data\":\"menu:settings\",\"style\":\"primary\"}]"
        ",[{\"text\":\"🏠 Menu Utama\",\"callback_data\":\"menu:main\"}]"
        "]}");

    send_inline_keyboard(cfg, chat_id, msg, keyboard);
}

static void send_tools_menu(const struct config *cfg, const char *chat_id)
{
    send_keyboard(cfg, chat_id,
        "Tools:\n"
        "/status - status modem\n"
        "/notifications - daftar notifikasi\n"
        "/process_notifications - proses notifikasi\n"
        "/lock - status lock backend\n"
        "/help - command manual",
        "{\"keyboard\":["
        "[{\"text\":\"Status Modem\"},{\"text\":\"Notifications\"}],"
        "[{\"text\":\"Process Notifications\"},{\"text\":\"Lock Status\"}],"
        "[{\"text\":\"Menu Utama\"}]"
        "],\"resize_keyboard\":true,\"one_time_keyboard\":false}");
}

static void help_text(char *dst, size_t dstsz)
{
    snprintf(dst, dstsz,
        "0xygen eSIM Telegram bot\n"
        "/menu - tampilkan menu tombol\n"
        "/chatid - tampilkan chat ID\n"
        "/profiles atau /profile - daftar profil eSIM\n"
        "/iccid - daftar ICCID profile\n"
        "/info atau /eid - info EID/eUICC\n"
        "/status - status modem\n"
        "/switch <ICCID|AID> - aktifkan profil\n"
        "/disable <ICCID|AID> - nonaktifkan profil\n"
        "/delete <ICCID|AID> - hapus profil disabled\n"
        "/download <LPA:1$...> - download profil\n"
        "/quota <MSISDN> - cek kuota XL\n"
        "/set_config <option> <value> - ubah setting LPAC\n"
        "/notifications - daftar notifikasi\n"
        "/process_notifications - proses notifikasi\n"
        "/lock - status operasi backend");
}

static int valid_config_key(const char *key)
{
    static const char *keys[] = {
        "apdu_backend", "qmi_device", "qmi_sim_slot", "sim_slot", "at_device",
        "mbim_device", "mbim_proxy", "mbim_skip_slot_mapping", "custom_isd_r_aid",
        "reboot_method", "modem_iface", "apdu_debug", "http_debug", "at_debug", "modem_profile", NULL
    };
    int i;
    for (i = 0; keys[i]; i++) if (strcmp(key, keys[i]) == 0) return 1;
    return 0;
}

static int safe_config_value(const char *s)
{
    size_t len;
    if (!s) return 0;
    len = strlen(s);
    if (len == 0 || len > 160) return 0;
    for (; *s; s++) {
        unsigned char c = (unsigned char)*s;
        if (c < 32 || c == 127 || *s == '\'' || *s == '"' || *s == '`' || *s == '$' || *s == ';' || *s == '&' || *s == '|')
            return 0;
    }
    return 1;
}

static int save_config_value(const char *key, const char *value, char *out, size_t outsz)
{
    char cmd[512];
    if (!valid_config_key(key) || !safe_config_value(value)) {
        snprintf(out, outsz, "Config key/value tidak valid.");
        return 1;
    }
    if (strcmp(key, "apdu_backend") == 0 &&
        strcmp(value, "qmi") != 0 && strcmp(value, "mbim") != 0 && strcmp(value, "at") != 0) {
        snprintf(out, outsz, "apdu_backend harus qmi, mbim, atau at.");
        return 1;
    }
    if ((strstr(key, "debug") || strcmp(key, "mbim_proxy") == 0 || strcmp(key, "mbim_skip_slot_mapping") == 0) &&
        strcmp(value, "0") != 0 && strcmp(value, "1") != 0) {
        snprintf(out, outsz, "%s harus 0 atau 1.", key);
        return 1;
    }
    snprintf(cmd, sizeof(cmd), "uci -q set lpac-esim.main.%s='%s' && uci -q commit lpac-esim", key, value);
    return run_shell(cmd, out, outsz, 5);
}

static void handle_command(const struct config *cfg, const char *chat, const char *text)
{
    char out[BUF_MAX];
    char msg[MSG_MAX + 1];
    char argbuf[2048];
    char pending_action[32];
    char pending_arg[2048];
    const char *arg;
    int rc;

    if (!cfg->chat_id[0]) {
        if (cmd_match(text, "/chatid")) {
            snprintf(msg, sizeof(msg), "Chat ID: %s\nMasukkan ID ini di LuCI/CLI Telegram Bot settings.", chat);
        } else if (cmd_match(text, "/start") || cmd_match(text, "/menu")) {
            snprintf(msg, sizeof(msg), "Chat ID: %s\nBot belum dikunci. Isi Allowed Chat ID ini di settings lalu Save & Restart Bot.", chat);
        } else {
            snprintf(msg, sizeof(msg), "Bot belum dikunci ke chat. Jalankan /chatid lalu isi Allowed Chat ID di settings.");
        }
        send_message(cfg, chat, msg);
        return;
    }

    if (strcmp(chat, cfg->chat_id) != 0) {
        /* Reply to /chatid and /start even when the chat doesn't match the
         * locked allowed_chat_id, so an admin who locked the bot to the
         * wrong ID can still see their own chat ID over Telegram and fix
         * it from LuCI. We deliberately do NOT echo cfg->chat_id back here:
         * doing so would let any Telegram user who finds the bot username
         * harvest the admin's numeric chat ID. Other commands stay silent
         * so the device-control surface remains locked to the configured
         * chat. */
        if (cmd_match(text, "/chatid")) {
            snprintf(msg, sizeof(msg),
                "Chat ID Anda: %s\nBot ini dikunci ke chat lain.\n"
                "Jika ini chat admin yang seharusnya, update Allowed Chat ID di LuCI/CLI lalu Save & Restart Bot.",
                chat);
            send_message(cfg, chat, msg);
        } else if (cmd_match(text, "/start")) {
            snprintf(msg, sizeof(msg),
                "Chat ID Anda: %s\nBot ini dikunci ke chat lain. "
                "Kirim /chatid untuk konfirmasi ID, lalu update Allowed Chat ID di settings.",
                chat);
            send_message(cfg, chat, msg);
        } else if (cfg->debug) {
            send_message(cfg, chat, "Unauthorized chat ID.");
        }
        return;
    }

    if (strcmp(text, "Menu Utama") == 0 || cmd_match(text, "/menu")) {
        clear_pending(chat);
        send_main_menu(cfg, chat);
    } else if (cmd_match(text, "/start")) {
        clear_pending(chat);
        send_main_menu(cfg, chat);
    } else if (cmd_match(text, "/help")) {
        help_text(msg, sizeof(msg));
        send_back_menu(cfg, chat, msg);
    } else if (cmd_match(text, "/chatid")) {
        snprintf(msg, sizeof(msg), "Chat ID: %s", chat);
        send_message(cfg, chat, msg);
    } else if (strcmp(text, "Info EID") == 0) {
        char chip_out[BUF_MAX];
        char prof_out[BUF_MAX];
        char *chip_args[] = { "chip", NULL };
        char *prof_args[] = { "profiles", NULL };
        int rc_chip, rc_prof;
        rc_chip = lpac_api(chip_args, chip_out, sizeof(chip_out), 25);
        rc_prof = lpac_api(prof_args, prof_out, sizeof(prof_out), 25);
        if (rc_chip == 0) {
            format_eid_info(chip_out, rc_prof == 0 ? prof_out : "", msg, sizeof(msg));
        } else {
            snprintf(msg, sizeof(msg), "❌ Gagal membaca chip info (rc=%d).", rc_chip);
        }
        send_inline_keyboard(cfg, chat, msg,
            "{\"inline_keyboard\":["
            "[{\"text\":\"🏠 Menu Utama\",\"callback_data\":\"menu:main\"}]"
            "]}");
    } else if (strcmp(text, "Profile List") == 0) {
        send_profile_menu(cfg, chat);
    } else if (strcmp(text, "Cek Kuota") == 0) {
        send_quota_menu(cfg, chat);
    } else if (strcmp(text, "Download eSIM") == 0) {
        save_pending(chat, "download", "");
        send_back_menu(cfg, chat, "Kirim activation code eSIM format LPA:1$SM-DP+$MATCHING_ID. Atau /cancel.");
    } else if (strcmp(text, "HYFE Trial") == 0 || strcmp(text, "Klaim Free eSIM HYFE") == 0) {
        send_hyfe_start_prompt(cfg, chat);
    } else if (strcmp(text, "HYFE Setting") == 0) {
        send_hyfe_settings_menu(cfg, chat);
    } else if (strcmp(text, "Settings") == 0) {
        send_settings_menu(cfg, chat);
    } else if (strcmp(text, "Tools") == 0) {
        send_tools_menu(cfg, chat);
    } else if (strcmp(text, "Backend QMI") == 0 || strcmp(text, "Backend MBIM") == 0 || strcmp(text, "Backend AT") == 0) {
        const char *backend = (strstr(text, "QMI") ? "qmi" : (strstr(text, "MBIM") ? "mbim" : "at"));
        rc = save_config_value("apdu_backend", backend, out, sizeof(out));
        if (rc == 0) snprintf(msg, sizeof(msg), "Backend LPAC diset ke %s.", backend);
        else snprintf(msg, sizeof(msg), "Gagal set backend: %.500s", out);
        send_settings_menu(cfg, chat);
        send_message(cfg, chat, msg);
    } else if (strcmp(text, "Debug ON") == 0 || strcmp(text, "Debug OFF") == 0) {
        const char *v = strstr(text, "ON") ? "1" : "0";
        save_config_value("apdu_debug", v, out, sizeof(out));
        save_config_value("http_debug", v, out, sizeof(out));
        save_config_value("at_debug", v, out, sizeof(out));
        send_settings_menu(cfg, chat);
    } else if (strcmp(text, "Status Modem") == 0) {
        char *args[] = { "modem-status", NULL };
        rc = lpac_api(args, out, sizeof(out), 25);
        if (rc == 0) compact_result(out, msg, sizeof(msg));
        else snprintf(msg, sizeof(msg), "Gagal membaca modem status (rc=%d).", rc);
        send_back_menu(cfg, chat, msg);
    } else if (strcmp(text, "Notifications") == 0) {
        char *args[] = { "notif-list", NULL };
        rc = lpac_api(args, out, sizeof(out), 25);
        if (rc == 0) compact_result(out, msg, sizeof(msg));
        else snprintf(msg, sizeof(msg), "Gagal membaca notifications (rc=%d).", rc);
        send_back_menu(cfg, chat, msg);
    } else if (strcmp(text, "Process Notifications") == 0) {
        char *args[] = { "notif-process", NULL };
        rc = lpac_api(args, out, sizeof(out), 70);
        compact_result(out, msg, sizeof(msg));
        if (rc != 0 && !msg[0]) snprintf(msg, sizeof(msg), "Gagal memproses notifications (rc=%d).", rc);
        send_back_menu(cfg, chat, msg);
    } else if (strcmp(text, "Lock Status") == 0) {
        char *args[] = { "lock-status", NULL };
        rc = lpac_api(args, out, sizeof(out), 10);
        if (rc == 0) compact_result(out, msg, sizeof(msg));
        else snprintf(msg, sizeof(msg), "Gagal membaca lock status (rc=%d).", rc);
        send_back_menu(cfg, chat, msg);
    } else if (cmd_match(text, "/cancel")) {
        clear_pending(chat);
        send_back_menu(cfg, chat, "Dibatalkan.");
    } else if ((strcmp(text, "YA") == 0 || strcmp(text, "BATAL") == 0) &&
               load_pending(chat, pending_action, sizeof(pending_action), pending_arg, sizeof(pending_arg))) {
        if (strcmp(text, "BATAL") == 0) {
            clear_pending(chat);
            send_back_menu(cfg, chat, "Dibatalkan.");
            return;
        }
        clear_pending(chat);
        if (strcmp(pending_action, "download") == 0) {
            char *args[] = { "download", "--lpa", pending_arg, NULL };
            rc = lpac_api(args, out, sizeof(out), 45);
            send_download_result(cfg, chat, rc, out);
            return;
        } else {
            char *args[] = { pending_action, pending_arg, NULL };
            rc = lpac_api(args, out, sizeof(out), 45);
        }
        compact_result(out, msg, sizeof(msg));
        if (rc != 0 && !msg[0]) snprintf(msg, sizeof(msg), "Command %s gagal (rc=%d).", pending_action, rc);
        send_back_menu(cfg, chat, msg);
    } else if (load_pending(chat, pending_action, sizeof(pending_action), pending_arg, sizeof(pending_arg))) {
        snprintf(argbuf, sizeof(argbuf), "%.1900s", text);
        trim(argbuf);
        if (!safe_arg(argbuf)) {
            send_message(cfg, chat, "Input tidak valid. /cancel untuk batal.");
            return;
        }
        /* Custom ISD-R AID input: save immediately, no confirmation. */
        if (strcmp(pending_action, "set_aid") == 0) {
            clear_pending(chat);
            rc = save_config_value("custom_isd_r_aid", argbuf, out, sizeof(out));
            if (rc == 0)
                snprintf(msg, sizeof(msg), "✅ Custom ISD-R AID disimpan:\n<code>%s</code>", argbuf);
            else
                snprintf(msg, sizeof(msg), "❌ Gagal menyimpan AID: %.500s", out);
            send_inline_keyboard(cfg, chat, msg,
                "{\"inline_keyboard\":["
                "[{\"text\":\"⚙️ Kembali ke Settings\",\"callback_data\":\"menu:settings\",\"style\":\"primary\"},"
                "{\"text\":\"🏠 Menu Utama\",\"callback_data\":\"menu:main\"}]"
                "]}");
            return;
        }

        if (strcmp(pending_action, "hyfe_set_config") == 0) {
            char key[80], val[512];
            int ok = 1;
            snprintf(key, sizeof(key), "%.70s", pending_arg);
            snprintf(val, sizeof(val), "%.500s", argbuf);
            trim(key);
            trim(val);
            if (strncmp(key, "HYFE_EMAIL_", 11) == 0 && !valid_email_simple(val)) {
                send_message(cfg, chat, "Email tidak valid. Contoh: email@gmail.com");
                return;
            }
            if (strncmp(key, "HYFE_EID_", 9) == 0 && !valid_eid_simple(val)) {
                send_message(cfg, chat, "EID tidak valid. Kirim angka EID 32 digit.");
                return;
            }
            if ((strcmp(key, "HYFE_IMAP_TIMEOUT") == 0 || strcmp(key, "HYFE_CAPTCHA_TIMEOUT") == 0) && !valid_msisdn_pattern(val))
                ok = 0;
            if (!ok) {
                send_message(cfg, chat, "Timeout harus angka.");
                return;
            }
            clear_pending(chat);
            rc = hyfe_set_config_value(key, val, out, sizeof(out));
            if (rc == 0) snprintf(msg, sizeof(msg), "Config HYFE disimpan: <code>%s</code>", key);
            else snprintf(msg, sizeof(msg), "Gagal simpan config HYFE:\n<code>%.900s</code>", out);
            send_inline_keyboard(cfg, chat, msg,
                "{\"inline_keyboard\":[[{\"text\":\"HYFE Setting\",\"callback_data\":\"hyfe:settings\",\"style\":\"primary\"},{\"text\":\"Menu\",\"callback_data\":\"menu:main\"}]]}");
            return;
        }

        if (strcmp(pending_action, "hyfe_wizard_email") == 0) {
            char mode[32], email[160];
            snprintf(mode, sizeof(mode), "%.30s", pending_arg);
            snprintf(email, sizeof(email), "%.140s", argbuf);
            trim(mode);
            trim(email);
            if (strcmp(mode, "imap") != 0) snprintf(mode, sizeof(mode), "manual");
            if (!valid_email_simple(email)) {
                send_message(cfg, chat, "Email tidak valid. Contoh: email@gmail.com");
                return;
            }
            rc = hyfe_set_config_value("HYFE_OTP_MODE", mode, out, sizeof(out));
            if (rc == 0) rc = hyfe_set_config_value("HYFE_EMAIL_1", email, out, sizeof(out));
            if (rc != 0) {
                snprintf(msg, sizeof(msg), "Gagal simpan email HYFE:\n<code>%.900s</code>", out);
                send_inline_keyboard(cfg, chat, msg,
                    "{\"inline_keyboard\":[[{\"text\":\"Setup Awal\",\"callback_data\":\"hyfe:wizard:start\",\"style\":\"primary\"},{\"text\":\"Menu\",\"callback_data\":\"menu:main\"}]]}");
                return;
            }
            clear_pending(chat);
            if (strcmp(mode, "imap") == 0) {
                save_pending(chat, "hyfe_wizard_pass", "");
                send_hyfe_setup_pass_prompt(cfg, chat);
            } else {
                send_hyfe_setup_captcha_choice(cfg, chat);
            }
            return;
        }

        if (strcmp(pending_action, "hyfe_wizard_pass") == 0) {
            char pass[512];
            snprintf(pass, sizeof(pass), "%.500s", argbuf);
            trim(pass);
            if (!pass[0]) {
                send_message(cfg, chat, "App Password tidak boleh kosong.");
                return;
            }
            rc = hyfe_set_config_value("HYFE_IMAP_PASS_1", pass, out, sizeof(out));
            if (rc == 0) rc = hyfe_set_config_value("HYFE_IMAP_URL", "imaps://imap.gmail.com:993", out, sizeof(out));
            if (rc == 0) rc = hyfe_set_config_value("HYFE_IMAP_FOLDER", "INBOX", out, sizeof(out));
            if (rc == 0) rc = hyfe_set_config_value("HYFE_IMAP_SUBJECT", "Kode OTP | eSIM Trial HYFE", out, sizeof(out));
            if (rc == 0) rc = hyfe_set_config_value("HYFE_IMAP_TIMEOUT", "180", out, sizeof(out));
            clear_pending(chat);
            if (rc != 0) {
                snprintf(msg, sizeof(msg), "Gagal simpan config IMAP HYFE:\n<code>%.900s</code>", out);
                send_inline_keyboard(cfg, chat, msg,
                    "{\"inline_keyboard\":[[{\"text\":\"Setup Awal\",\"callback_data\":\"hyfe:wizard:start\",\"style\":\"primary\"},{\"text\":\"Menu\",\"callback_data\":\"menu:main\"}]]}");
                return;
            }
            send_hyfe_setup_captcha_choice(cfg, chat);
            return;
        }

        if (strcmp(pending_action, "hyfe_wizard_captcha_key") == 0) {
            char mode[32], key[512];
            snprintf(mode, sizeof(mode), "%.30s", pending_arg);
            snprintf(key, sizeof(key), "%.500s", argbuf);
            trim(mode);
            trim(key);
            if (!valid_captcha_mode(mode) || strcmp(mode, "manual") == 0) {
                clear_pending(chat);
                send_message(cfg, chat, "Mode captcha wizard tidak valid.");
                return;
            }
            if (!key[0]) {
                send_message(cfg, chat, "API key captcha tidak boleh kosong.");
                return;
            }
            clear_pending(chat);
            rc = hyfe_set_captcha(mode, key, out, sizeof(out));
            if (rc != 0) {
                snprintf(msg, sizeof(msg), "Gagal simpan captcha HYFE:\n<code>%.900s</code>", out);
                send_inline_keyboard(cfg, chat, msg,
                    "{\"inline_keyboard\":[[{\"text\":\"Setup Captcha\",\"callback_data\":\"hyfe:wizard:captcha\",\"style\":\"primary\"},{\"text\":\"Menu\",\"callback_data\":\"menu:main\"}]]}");
                return;
            }
            send_hyfe_setup_eid_choice(cfg, chat);
            return;
        }

        if (strcmp(pending_action, "hyfe_wizard_eid") == 0) {
            char eid[80];
            snprintf(eid, sizeof(eid), "%.64s", argbuf);
            trim(eid);
            if (!valid_eid_simple(eid)) {
                send_message(cfg, chat, "EID tidak valid. Kirim angka EID 32 digit.");
                return;
            }
            clear_pending(chat);
            rc = hyfe_set_config_value("HYFE_EID_1", eid, out, sizeof(out));
            if (rc != 0) {
                snprintf(msg, sizeof(msg), "Gagal simpan EID HYFE:\n<code>%.900s</code>", out);
                send_inline_keyboard(cfg, chat, msg,
                    "{\"inline_keyboard\":[[{\"text\":\"HYFE Setting\",\"callback_data\":\"hyfe:settings\",\"style\":\"primary\"},{\"text\":\"Menu\",\"callback_data\":\"menu:main\"}]]}");
                return;
            }
            send_hyfe_setup_done(cfg, chat);
            return;
        }

        /* HYFE wizard: mirrors the interactive CLI flow through Telegram buttons. */
        if (strcmp(pending_action, "hyfe_name_manual") == 0) {
            char name[160];
            snprintf(name, sizeof(name), "%.120s", argbuf);
            if (strchr(name, '|') || strlen(name) < 3) {
                send_message(cfg, chat, "Nama tidak valid. Kirim nama minimal 3 karakter, atau /cancel.");
                return;
            }
            send_hyfe_whatsapp_choice(cfg, chat, name);
            return;
        }

        if (strcmp(pending_action, "hyfe_whatsapp") == 0) {
            char name[160], wa_old[32], email[160], msisdn[64], eid[80], packed[512], wa[32];
            hyfe_unpack_manual(pending_arg, name, sizeof(name), wa_old, sizeof(wa_old), email, sizeof(email), msisdn, sizeof(msisdn), eid, sizeof(eid));
            if (!normalize_wa_c(argbuf, wa, sizeof(wa))) {
                send_message(cfg, chat, "Nomor WhatsApp tidak valid. Contoh: 08123456789");
                return;
            }
            hyfe_pack_manual(packed, sizeof(packed), name, wa, "", "", "");
            send_hyfe_email_prompt(cfg, chat, packed);
            return;
        }

        if (strcmp(pending_action, "hyfe_email") == 0) {
            char name[160], wa[32], email[160], old_msisdn[64], eid[80], packed[512];
            hyfe_unpack_manual(pending_arg, name, sizeof(name), wa, sizeof(wa), email, sizeof(email), old_msisdn, sizeof(old_msisdn), eid, sizeof(eid));
            snprintf(email, sizeof(email), "%.140s", argbuf);
            if (!valid_email_simple(email)) {
                send_message(cfg, chat, "Email tidak valid. Contoh: email@gmail.com");
                return;
            }
            hyfe_pack_manual(packed, sizeof(packed), name, wa, email, "", "");
            send_hyfe_pattern_prompt(cfg, chat, packed);
            return;
        }

        if (strcmp(pending_action, "hyfe_pattern") == 0) {
            char pattern[16];
            snprintf(pattern, sizeof(pattern), "%.10s", argbuf);
            trim(pattern);
            if (!valid_msisdn_pattern(pattern) || pattern[0] == '\0') {
                send_message(cfg, chat, "Pola nomor harus 1-5 digit. Contoh: 123, 7777, atau 081.");
                return;
            }
            send_hyfe_number_list(cfg, chat, pending_arg, pattern);
            return;
        }

        if (strcmp(pending_action, "hyfe_eid") == 0) {
            char name[160], wa[32], email[160], msisdn[64], eid[80], encrypt[1024], packed[1536];
            char sid[128], picked[64], err[512];
            hyfe_unpack_manual_ext(pending_arg, name, sizeof(name), wa, sizeof(wa), email, sizeof(email), msisdn, sizeof(msisdn), eid, sizeof(eid), encrypt, sizeof(encrypt));
            snprintf(eid, sizeof(eid), "%.64s", argbuf);
            trim(eid);
            if (!valid_eid_simple(eid)) {
                send_message(cfg, chat, "EID tidak valid. Kirim angka EID 32 digit.");
                return;
            }
            hyfe_pack_manual_ext(packed, sizeof(packed), name, wa, email, msisdn, eid, encrypt);
            clear_pending(chat);
            send_loading(cfg, chat, "Memulai klaim HYFE: auth, TNC, dan kirim OTP");
            rc = hyfe_start_claim(packed, out, sizeof(out));
            if (rc == 0 && json_get_string(out, "sid", sid, sizeof(sid))) {
                char otp_mode[32], otp[64], otp_out[BUF_MAX], otp_err[512];
                json_get_string(out, "msisdn", picked, sizeof(picked));
                json_get_string(out, "otp_mode", otp_mode, sizeof(otp_mode));
                if (strcmp(otp_mode, "imap") == 0) {
                    send_loading(cfg, chat, "Menunggu OTP HYFE via IMAP");
                    if (hyfe_poll_otp(sid, otp_out, sizeof(otp_out)) == 0 &&
                        json_get_string(otp_out, "otp", otp, sizeof(otp))) {
                        send_hyfe_captcha_mode_prompt(cfg, chat, sid, otp);
                        return;
                    }
                    if (!json_get_string(otp_out, "error", otp_err, sizeof(otp_err))) snprintf(otp_err, sizeof(otp_err), "%.450s", otp_out);
                    save_pending(chat, "hyfe_otp", sid);
                    snprintf(msg, sizeof(msg),
                        "OTP IMAP gagal/timeout:\n<code>%.900s</code>\n\n"
                        "Kirim kode OTP dari email secara manual untuk lanjut.",
                        otp_err);
                    send_inline_keyboard(cfg, chat, msg,
                        "{\"inline_keyboard\":[[{\"text\":\"Batal\",\"callback_data\":\"cancel\",\"style\":\"danger\"}]]}");
                    return;
                }
                save_pending(chat, "hyfe_otp", sid);
                snprintf(msg, sizeof(msg),
                    "OTP HYFE sudah dikirim.\n\n"
                    "Nama: <b>%s</b>\n"
                    "WA: <code>62%s</code>\n"
                    "Email: <code>%s</code>\n"
                    "Nomor HYFE: <code>%s</code>\n\n"
                    "Kirim kode OTP dari email ke chat ini.",
                    name, wa, email, picked[0] ? picked : msisdn);
                send_inline_keyboard(cfg, chat, msg,
                    "{\"inline_keyboard\":[[{\"text\":\"Batal\",\"callback_data\":\"cancel\",\"style\":\"danger\"}]]}");
            } else {
                if (!json_get_string(out, "error", err, sizeof(err))) snprintf(err, sizeof(err), "%.450s", out);
                snprintf(msg, sizeof(msg), "Gagal memulai klaim HYFE:\n<code>%.900s</code>", err);
                send_inline_keyboard(cfg, chat, msg,
                    "{\"inline_keyboard\":[[{\"text\":\"Klaim Lagi\",\"callback_data\":\"hyfe:start\",\"style\":\"primary\"},{\"text\":\"Menu\",\"callback_data\":\"menu:main\"}]]}");
            }
            return;
        }

        if (strcmp(pending_action, "hyfe_otp") == 0) {
            char otpbuf[64];
            snprintf(otpbuf, sizeof(otpbuf), "%.40s", argbuf);
            trim(otpbuf);
            if (strlen(otpbuf) != 6) {
                send_message(cfg, chat, "OTP HYFE harus 6 karakter.");
                return;
            }
            send_hyfe_captcha_mode_prompt(cfg, chat, pending_arg, otpbuf);
            return;
        }

        if (strcmp(pending_action, "hyfe_captcha") == 0) {
            char sid[256], otp[64], mode[32], lpa[1024], msisdn[64], err[512], enc[2048], qrurl[2300];
            char *sep1, *sep2;
            snprintf(sid, sizeof(sid), "%.240s", pending_arg);
            sep1 = strchr(sid, '|');
            if (!sep1) {
                clear_pending(chat);
                send_message(cfg, chat, "Sesi HYFE rusak/expired. Mulai klaim lagi.");
                return;
            }
            *sep1++ = '\0';
            sep2 = strchr(sep1, '|');
            if (sep2) *sep2++ = '\0';
            snprintf(otp, sizeof(otp), "%.40s", sep1);
            snprintf(mode, sizeof(mode), "%.30s", sep2 ? sep2 : "manual");
            clear_pending(chat);
            send_loading(cfg, chat, "Submit klaim HYFE");
            rc = hyfe_finish_claim(sid, otp, mode, argbuf, out, sizeof(out));
            if (rc == 0) {
                json_get_string(out, "lpa", lpa, sizeof(lpa));
                json_get_string(out, "msisdn", msisdn, sizeof(msisdn));
                if (lpa[0]) {
                    snprintf(msg, sizeof(msg),
                        "<b>Klaim HYFE sukses</b>\n\n"
                        "Nomor: <code>%s</code>\n\n"
                        "LPA String:\n<code>%s</code>",
                        msisdn[0] ? msisdn : "-", lpa);
                    send_inline_keyboard(cfg, chat, msg,
                        "{\"inline_keyboard\":[[{\"text\":\"Download ke eSIM\",\"callback_data\":\"menu:download\",\"style\":\"success\"},{\"text\":\"Menu\",\"callback_data\":\"menu:main\"}]]}");
                    url_encode(lpa, enc, sizeof(enc));
                    snprintf(qrurl, sizeof(qrurl), "https://quickchart.io/qr?size=320&text=%s", enc);
                    send_photo_url(cfg, chat, qrurl, "QR eSIM HYFE");
                } else {
                    send_inline_keyboard(cfg, chat,
                        "Klaim HYFE sudah tersubmit, tetapi LPA string belum ditemukan di response maupun email.\n\n"
                        "Pastikan HYFE Setting sudah berisi email + app password IMAP yang benar, lalu cek email HYFE secara manual.",
                        "{\"inline_keyboard\":[[{\"text\":\"HYFE Setting\",\"callback_data\":\"hyfe:settings\",\"style\":\"primary\"},"
                        "{\"text\":\"Menu\",\"callback_data\":\"menu:main\"}]]}");
                }
            } else {
                if (!json_get_string(out, "error", err, sizeof(err))) snprintf(err, sizeof(err), "%.450s", out);
                snprintf(msg, sizeof(msg), "Klaim HYFE gagal:\n<code>%.900s</code>", err);
                send_inline_keyboard(cfg, chat, msg,
                    "{\"inline_keyboard\":[[{\"text\":\"Klaim Lagi\",\"callback_data\":\"hyfe:start\",\"style\":\"primary\"},{\"text\":\"Menu\",\"callback_data\":\"menu:main\"}]]}");
            }
            return;
        }

        if (strcmp(pending_action, "hyfe_set_captcha_key") == 0) {
            if (!valid_captcha_mode(pending_arg) || strcmp(pending_arg, "manual") == 0) {
                clear_pending(chat);
                send_message(cfg, chat, "Mode captcha setting tidak valid.");
                return;
            }
            clear_pending(chat);
            rc = hyfe_set_captcha(pending_arg, argbuf, out, sizeof(out));
            if (rc == 0) snprintf(msg, sizeof(msg), "Captcha HYFE diset ke <code>%s</code> dan API key tersimpan.", pending_arg);
            else snprintf(msg, sizeof(msg), "Gagal simpan captcha config:\n<code>%.900s</code>", out);
            send_inline_keyboard(cfg, chat, msg,
                "{\"inline_keyboard\":[[{\"text\":\"HYFE Setting\",\"callback_data\":\"hyfe:settings\",\"style\":\"primary\"},{\"text\":\"Menu\",\"callback_data\":\"menu:main\"}]]}");
            return;
        }

        /* Quota manual: run immediately, no confirmation */
        if (strcmp(pending_action, "quota") == 0) {
            clear_pending(chat);
            send_loading(cfg, chat, "Mengecek kuota XL");
            rc = esim_quota(argbuf, out, sizeof(out));
            snprintf(msg, sizeof(msg), "%.3900s", out[0] ? out : (rc == 0 ? "Tidak ada output kuota." : "Gagal cek kuota."));
            send_inline_keyboard(cfg, chat, msg,
                "{\"inline_keyboard\":["
                "[{\"text\":\"\xF0\x9F\x93\x8A Cek Kuota Lagi\",\"callback_data\":\"menu:quota\"}"
                ",{\"text\":\"\xF0\x9F\x8F\xA0 Menu Utama\",\"callback_data\":\"menu:main\"}]"
                "]}");
            return;
        }
        if (strcmp(pending_action, "download") == 0 && strncmp(argbuf, "LPA:1$", 6) != 0) {
            send_message(cfg, chat, "Format download harus LPA:1$SM-DP+$MATCHING_ID");
            return;
        }
        if (pending_arg[0] != '\0' && strcmp(pending_action, "download") != 0) {
            send_message(cfg, chat, "Masih menunggu konfirmasi. Tekan YA untuk lanjut atau BATAL untuk membatalkan.");
            return;
        }
        save_pending(chat, pending_action, argbuf);
        snprintf(msg, sizeof(msg), "Konfirmasi %s:\n%s\n\nTekan YA untuk lanjut atau BATAL.", profile_label(pending_action), argbuf);
        send_keyboard(cfg, chat, msg,
            "{\"keyboard\":[[{\"text\":\"YA\"},{\"text\":\"BATAL\"}],[{\"text\":\"Menu Utama\"}]],\"resize_keyboard\":true,\"one_time_keyboard\":true}");
    } else if (cmd_match(text, "/hyfe") || cmd_match(text, "/claim")) {
        send_hyfe_start_prompt(cfg, chat);
    } else if (cmd_match(text, "/profiles") || cmd_match(text, "/profile") || cmd_match(text, "/iccid")) {
        send_profile_menu(cfg, chat);
    } else if (cmd_match(text, "/info") || cmd_match(text, "/eid")) {
        char *args[] = { "chip", NULL };
        rc = lpac_api(args, out, sizeof(out), 25);
        if (rc == 0) compact_result(out, msg, sizeof(msg));
        else snprintf(msg, sizeof(msg), "Gagal membaca chip info (rc=%d).", rc);
        send_message(cfg, chat, msg);
    } else if (cmd_match(text, "/status")) {
        char *args[] = { "modem-status", NULL };
        rc = lpac_api(args, out, sizeof(out), 25);
        if (rc == 0) compact_result(out, msg, sizeof(msg));
        else snprintf(msg, sizeof(msg), "Gagal membaca modem status (rc=%d).", rc);
        send_message(cfg, chat, msg);
    } else if (cmd_match(text, "/lock")) {
        char *args[] = { "lock-status", NULL };
        rc = lpac_api(args, out, sizeof(out), 10);
        if (rc == 0) compact_result(out, msg, sizeof(msg));
        else snprintf(msg, sizeof(msg), "Gagal membaca lock status (rc=%d).", rc);
        send_message(cfg, chat, msg);
    } else if (cmd_match(text, "/notifications")) {
        char *args[] = { "notif-list", NULL };
        rc = lpac_api(args, out, sizeof(out), 25);
        if (rc == 0) compact_result(out, msg, sizeof(msg));
        else snprintf(msg, sizeof(msg), "Gagal membaca notifications (rc=%d).", rc);
        send_message(cfg, chat, msg);
    } else if (cmd_match(text, "/process_notifications")) {
        char *args[] = { "notif-process", NULL };
        rc = lpac_api(args, out, sizeof(out), 70);
        compact_result(out, msg, sizeof(msg));
        if (rc != 0 && !msg[0]) snprintf(msg, sizeof(msg), "Gagal memproses notifications (rc=%d).", rc);
        send_message(cfg, chat, msg);
    } else if (cmd_match(text, "/switch") || cmd_match(text, "/disable") || cmd_match(text, "/delete")) {
        const char *cmd = cmd_match(text, "/switch") ? "switch" : (cmd_match(text, "/disable") ? "disable" : "delete");
        arg = cmd_args(text);
        snprintf(argbuf, sizeof(argbuf), "%.700s", arg);
        trim(argbuf);
        if (!safe_arg(argbuf) || strchr(argbuf, ' ')) {
            send_message(cfg, chat, "Format: /switch <ICCID|AID>, /disable <ICCID|AID>, atau /delete <ICCID|AID>");
            return;
        }
        save_pending(chat, cmd, argbuf);
        snprintf(msg, sizeof(msg), "Konfirmasi %s:\n%s\n\nTekan YA untuk lanjut atau BATAL.", profile_label(cmd), argbuf);
        send_keyboard(cfg, chat, msg,
            "{\"keyboard\":[[{\"text\":\"YA\"},{\"text\":\"BATAL\"}],[{\"text\":\"Menu Utama\"}]],\"resize_keyboard\":true,\"one_time_keyboard\":true}");
    } else if (cmd_match(text, "/quota")) {
        arg = cmd_args(text);
        snprintf(argbuf, sizeof(argbuf), "%.700s", arg);
        trim(argbuf);
        if (!safe_arg(argbuf) || strchr(argbuf, ' ')) {
            send_message(cfg, chat, "Format: /quota <nomor XL>");
            return;
        }
        send_loading(cfg, chat, "Mengecek kuota XL");
        rc = esim_quota(argbuf, out, sizeof(out));
        snprintf(msg, sizeof(msg), "%.3900s", out[0] ? out : (rc == 0 ? "Tidak ada output kuota." : "Gagal cek kuota."));
        send_back_menu(cfg, chat, msg);
    } else if (cmd_match(text, "/download")) {
        arg = cmd_args(text);
        snprintf(argbuf, sizeof(argbuf), "%.700s", arg);
        trim(argbuf);
        if (!safe_arg(argbuf) || strncmp(argbuf, "LPA:1$", 6) != 0) {
            send_message(cfg, chat, "Format: /download LPA:1$SM-DP+$MATCHING_ID");
            return;
        }
        send_loading(cfg, chat, "Download eSIM");
        {
            char *args[] = { "download", "--lpa", argbuf, NULL };
            rc = lpac_api(args, out, sizeof(out), 45);
        }
        send_download_result(cfg, chat, rc, out);
    } else if (cmd_match(text, "/set_config")) {
        char *space;
        arg = cmd_args(text);
        snprintf(argbuf, sizeof(argbuf), "%.700s", arg);
        trim(argbuf);
        space = strchr(argbuf, ' ');
        if (!space) {
            send_message(cfg, chat, "Format: /set_config <option> <value>");
            return;
        }
        *space++ = '\0';
        trim(space);
        rc = save_config_value(argbuf, space, out, sizeof(out));
        if (rc == 0) snprintf(msg, sizeof(msg), "Config %s disimpan: %s", argbuf, space);
        else snprintf(msg, sizeof(msg), "Gagal simpan config %.80s: %.500s", argbuf, out);
        send_back_menu(cfg, chat, msg);
    } else {
        send_main_menu(cfg, chat);
    }
}

static void handle_callback(const struct config *cfg, const char *chat,
                            const char *callback_query_id, const char *data)
{
    char out[BUF_MAX];
    char msg[MSG_MAX + 1];
    char argbuf[80];

    answer_callback(cfg, callback_query_id);

    /* data format: "sw:<iccid>", "del:<iccid>", "menu:main", "menu:download",
     *              "confirm:sw:<iccid>", "confirm:del:<iccid>", "cancel" */

    if (strncmp(data, "sw:", 3) == 0) {
        /* User tapped an inactive profile → ask confirmation */
        snprintf(argbuf, sizeof(argbuf), "%.60s", data + 3);
        save_pending(chat, "switch", argbuf);
        snprintf(msg, sizeof(msg),
            "🔄 <b>Konfirmasi Switch Profile</b>\n\n"
            "ICCID: <code>%s</code>\n\n"
            "Aktifkan profil ini?", argbuf);
        send_inline_keyboard(cfg, chat, msg,
            "{\"inline_keyboard\":["
            "[{\"text\":\"✅ Ya, Switch\",\"callback_data\":\"confirm:sw\"},"
            "{\"text\":\"❌ Batal\",\"callback_data\":\"cancel\"}]"
            "]}");

    } else if (strncmp(data, "del:", 4) == 0) {
        /* User tapped delete → ask confirmation. Active profiles are locked. */
        snprintf(argbuf, sizeof(argbuf), "%.60s", data + 4);
        if (profile_is_active_iccid(argbuf)) {
            send_inline_keyboard(cfg, chat,
                "❌ Profil aktif tidak bisa dihapus. Switch ke profil lain dulu.",
                "{\"inline_keyboard\":[[{\"text\":\"🗑 Manage Profile\",\"callback_data\":\"menu:manage\",\"style\":\"primary\"},{\"text\":\"🏠 Menu Utama\",\"callback_data\":\"menu:main\"}]]}");
            return;
        }
        save_pending(chat, "delete", argbuf);
        snprintf(msg, sizeof(msg),
            "🗑 <b>Konfirmasi Hapus Profile</b>\n\n"
            "ICCID: <code>%s</code>\n\n"
            "⚠️ Profile yang dihapus tidak bisa dikembalikan.\n"
            "Lanjutkan hapus?", argbuf);
        send_inline_keyboard(cfg, chat, msg,
            "{\"inline_keyboard\":["
            "[{\"text\":\"🗑 Ya, Hapus\",\"callback_data\":\"confirm:del\",\"style\":\"danger\"},"
            "{\"text\":\"❌ Batal\",\"callback_data\":\"cancel\",\"style\":\"primary\"}]"
            "]}");

    } else if (strcmp(data, "confirm:sw") == 0) {
        char pending_action[32], pending_arg[80];
        if (load_pending(chat, pending_action, sizeof(pending_action),
                         pending_arg, sizeof(pending_arg))
            && strcmp(pending_action, "switch") == 0 && pending_arg[0]) {
            char *args[] = { "switch", pending_arg, NULL };
            int rc = lpac_api(args, out, sizeof(out), 45);
            clear_pending(chat);
            compact_result(out, msg, sizeof(msg));
            if (rc != 0 && !msg[0])
                snprintf(msg, sizeof(msg), "❌ Switch gagal (rc=%d).", rc);
            else if (rc == 0)
                snprintf(msg, sizeof(msg), "✅ Profil <code>%s</code> berhasil diaktifkan.", pending_arg);
            send_inline_keyboard(cfg, chat, msg,
                "{\"inline_keyboard\":["
                "[{\"text\":\"📋 Profile List\",\"callback_data\":\"menu:profiles\"},"
                "{\"text\":\"🏠 Menu Utama\",\"callback_data\":\"menu:main\"}]"
                "]}");
        } else {
            send_inline_keyboard(cfg, chat, "⚠️ Sesi konfirmasi tidak valid atau kadaluarsa.",
                "{\"inline_keyboard\":["
                "[{\"text\":\"🏠 Menu Utama\",\"callback_data\":\"menu:main\"}]"
                "]}");
        }

    } else if (strcmp(data, "confirm:del") == 0) {
        char pending_action[32], pending_arg[80];
        if (load_pending(chat, pending_action, sizeof(pending_action),
                         pending_arg, sizeof(pending_arg))
            && strcmp(pending_action, "delete") == 0 && pending_arg[0]) {
            char *args[] = { "delete", pending_arg, NULL };
            int rc;
            if (profile_is_active_iccid(pending_arg)) {
                clear_pending(chat);
                send_inline_keyboard(cfg, chat,
                    "❌ Profil aktif tidak boleh dihapus. Nonaktifkan/switch ke profil lain dulu.",
                    "{\"inline_keyboard\":[[{\"text\":\"📋 Profile List\",\"callback_data\":\"menu:profiles\",\"style\":\"primary\"},{\"text\":\"🏠 Menu Utama\",\"callback_data\":\"menu:main\"}]]}");
                return;
            }
            rc = lpac_api(args, out, sizeof(out), 45);
            clear_pending(chat);
            compact_result(out, msg, sizeof(msg));
            if (rc != 0 && !msg[0])
                snprintf(msg, sizeof(msg), "❌ Delete gagal (rc=%d).", rc);
            else if (rc == 0)
                snprintf(msg, sizeof(msg), "🗑 Profil <code>%s</code> berhasil dihapus.", pending_arg);
            send_inline_keyboard(cfg, chat, msg,
                "{\"inline_keyboard\":["
                "[{\"text\":\"📋 Profile List\",\"callback_data\":\"menu:profiles\"},"
                "{\"text\":\"🏠 Menu Utama\",\"callback_data\":\"menu:main\"}]"
                "]}");
        } else {
            send_inline_keyboard(cfg, chat, "⚠️ Sesi konfirmasi tidak valid atau kadaluarsa.",
                "{\"inline_keyboard\":["
                "[{\"text\":\"🏠 Menu Utama\",\"callback_data\":\"menu:main\"}]"
                "]}");
        }

    } else if (strncmp(data, "cfg:backend:", 12) == 0) {
        const char *backend = data + 12;
        if (strcmp(backend, "qmi") == 0 || strcmp(backend, "mbim") == 0 || strcmp(backend, "at") == 0) {
            int rc = save_config_value("apdu_backend", backend, out, sizeof(out));
            if (rc != 0) log_msg("failed to set apdu_backend=%s: %s", backend, out);
        }
        send_settings_menu(cfg, chat);

    } else if (strncmp(data, "cfg:sim:", 8) == 0) {
        const char *slot = data + 8;
        if (strcmp(slot, "0") == 0 || strcmp(slot, "1") == 0) {
            save_config_value("sim_slot", slot, out, sizeof(out));
        }
        send_settings_menu(cfg, chat);

    } else if (strncmp(data, "cfg:toggle:", 11) == 0) {
        toggle_config_key(data + 11, out, sizeof(out));
        send_settings_menu(cfg, chat);

    } else if (strcmp(data, "cfg:aid:edit") == 0) {
        clear_pending(chat);
        save_pending(chat, "set_aid", "");
        send_keyboard(cfg, chat,
            "✏️ <b>Edit Custom ISD-R AID</b>\n\n"
            "Kirim AID baru dalam format hex.\n"
            "Contoh:\n<code>A0000005591010FFFFFFFF8900000100</code>\n\n"
            "Atau /cancel untuk batal.",
            "{\"keyboard\":[[{\"text\":\"Menu Utama\"}]],\"resize_keyboard\":true}");

    } else if (strcmp(data, "cfg:aid:default") == 0) {
        save_config_value("custom_isd_r_aid", "A0000005591010FFFFFFFF8900000100", out, sizeof(out));
        send_settings_menu(cfg, chat);

    } else if (strncmp(data, "preset:", 7) == 0) {
        const char *preset = data + 7;
        if (strcmp(preset, "l850gl") == 0 || strcmp(preset, "t99w175") == 0) {
            save_pending(chat, "preset", preset);
            snprintf(msg, sizeof(msg),
                "⚠️ <b>Konfirmasi Ganti Preset Modem</b>\n\n"
                "Preset baru: <code>%s</code>\n\n"
                "Tindakan ini akan mengubah backend, slot SIM, MBIM proxy, skip slot mapping, AID, dan device path LPAC.\n\n"
                "Lanjutkan?", preset);
            send_inline_keyboard(cfg, chat, msg,
                "{\"inline_keyboard\":["
                "[{\"text\":\"✅ Ya, Terapkan\",\"callback_data\":\"confirm:preset\",\"style\":\"success\"},"
                "{\"text\":\"❌ Batal\",\"callback_data\":\"cancel\",\"style\":\"danger\"}]"
                "]}");
        } else {
            send_settings_menu(cfg, chat);
        }

    } else if (strcmp(data, "confirm:preset") == 0) {
        char pending_action[32], pending_arg[80];
        if (load_pending(chat, pending_action, sizeof(pending_action), pending_arg, sizeof(pending_arg))
            && strcmp(pending_action, "preset") == 0 && pending_arg[0]) {
            int rc = apply_modem_preset(pending_arg, out, sizeof(out));
            clear_pending(chat);
            if (rc == 0)
                snprintf(msg, sizeof(msg), "✅ Preset modem <code>%s</code> berhasil diterapkan.", pending_arg);
            else
                snprintf(msg, sizeof(msg), "❌ Gagal menerapkan preset: %.500s", out);
            send_inline_keyboard(cfg, chat, msg,
                "{\"inline_keyboard\":["
                "[{\"text\":\"⚙️ Lihat Settings\",\"callback_data\":\"menu:settings\",\"style\":\"primary\"},"
                "{\"text\":\"🏠 Menu Utama\",\"callback_data\":\"menu:main\"}]"
                "]}");
        } else {
            send_inline_keyboard(cfg, chat, "⚠️ Sesi konfirmasi preset tidak valid atau kadaluarsa.",
                "{\"inline_keyboard\":[[{\"text\":\"⚙️ Settings\",\"callback_data\":\"menu:settings\",\"style\":\"primary\"}]]}");
        }

    } else if (strcmp(data, "cancel") == 0) {
        clear_pending(chat);
        send_inline_keyboard(cfg, chat, "❌ Dibatalkan.",
            "{\"inline_keyboard\":["
            "[{\"text\":\"📋 Profile List\",\"callback_data\":\"menu:profiles\"},"
            "{\"text\":\"🏠 Menu Utama\",\"callback_data\":\"menu:main\"}]"
            "]}");

    } else if (strcmp(data, "noop") == 0) {
        /* intentionally empty: used for active/locked buttons */
        return;

    } else if (strcmp(data, "hyfe:name:manual") == 0) {
        send_hyfe_name_manual_prompt(cfg, chat);

    } else if (strcmp(data, "hyfe:name:random") == 0) {
        char name[160];
        if (hyfe_random_value("random-name", name, sizeof(name)) != 0) {
            send_message(cfg, chat, "Gagal generate nama random HYFE.");
            return;
        }
        trim(name);
        send_hyfe_whatsapp_choice(cfg, chat, name);

    } else if (strcmp(data, "hyfe:wa:manual") == 0) {
        char pending_action[32], pending_arg[2048];
        if (load_pending(chat, pending_action, sizeof(pending_action), pending_arg, sizeof(pending_arg)) &&
            strcmp(pending_action, "hyfe_whatsapp_choice") == 0) {
            send_hyfe_whatsapp_manual_prompt(cfg, chat, pending_arg);
        } else {
            send_hyfe_start_prompt(cfg, chat);
        }

    } else if (strcmp(data, "hyfe:wa:random") == 0) {
        char pending_action[32], pending_arg[2048];
        char name[160], wa_old[32], email[160], msisdn[64], eid[80], wa[32], packed[512];
        if (!(load_pending(chat, pending_action, sizeof(pending_action), pending_arg, sizeof(pending_arg)) &&
              strcmp(pending_action, "hyfe_whatsapp_choice") == 0)) {
            send_hyfe_start_prompt(cfg, chat);
            return;
        }
        if (hyfe_random_value("random-wa", wa, sizeof(wa)) != 0) {
            send_message(cfg, chat, "Gagal generate WA random HYFE.");
            return;
        }
        trim(wa);
        hyfe_unpack_manual(pending_arg, name, sizeof(name), wa_old, sizeof(wa_old), email, sizeof(email), msisdn, sizeof(msisdn), eid, sizeof(eid));
        hyfe_pack_manual(packed, sizeof(packed), name, wa, "", "", "");
        send_hyfe_email_prompt(cfg, chat, packed);

    } else if (strcmp(data, "hyfe:pattern:random") == 0 || strcmp(data, "hyfe:pattern:again") == 0) {
        char pending_action[32], pending_arg[2048];
        if (load_pending(chat, pending_action, sizeof(pending_action), pending_arg, sizeof(pending_arg)) &&
            (strcmp(pending_action, "hyfe_pattern") == 0 || strcmp(pending_action, "hyfe_pick_number") == 0)) {
            if (strcmp(data, "hyfe:pattern:again") == 0)
                send_hyfe_pattern_prompt(cfg, chat, pending_arg);
            else
                send_hyfe_number_list(cfg, chat, pending_arg, "");
        } else {
            send_hyfe_start_prompt(cfg, chat);
        }

    } else if (strncmp(data, "hyfenum:", 8) == 0) {
        char pending_action[32], pending_arg[2048];
        char name[160], wa[32], email[160], old_msisdn[64], eid[80], packed[1536], norm[48], picked[64], encrypt[1024];
        int pick_idx = atoi(data + 8);
        if (!(load_pending(chat, pending_action, sizeof(pending_action), pending_arg, sizeof(pending_arg)) &&
              strcmp(pending_action, "hyfe_pick_number") == 0)) {
            send_hyfe_start_prompt(cfg, chat);
            return;
        }
        if (pick_idx <= 0 || !load_hyfe_number_pick(chat, pick_idx, picked, sizeof(picked), encrypt, sizeof(encrypt)) ||
            !normalize_msisdn_c(picked, norm, sizeof(norm))) {
            send_message(cfg, chat, "Nomor HYFE dari tombol tidak valid/expired. Coba cari lagi.");
            return;
        }
        hyfe_unpack_manual(pending_arg, name, sizeof(name), wa, sizeof(wa), email, sizeof(email), old_msisdn, sizeof(old_msisdn), eid, sizeof(eid));
        hyfe_pack_manual_ext(packed, sizeof(packed), name, wa, email, norm, "", encrypt);
        send_hyfe_eid_prompt(cfg, chat, packed);

    } else if (strncmp(data, "hyfecap:", 8) == 0) {
        char pending_action[32], pending_arg[2048];
        char sid[256], otp[64], mode[32], lpa[1024], msisdn[64], err[512], enc[2048], qrurl[2300];
        char *sep;
        int rc;
        snprintf(mode, sizeof(mode), "%.30s", data + 8);
        if (!valid_captcha_mode(mode)) {
            send_message(cfg, chat, "Mode captcha tidak valid.");
            return;
        }
        if (!(load_pending(chat, pending_action, sizeof(pending_action), pending_arg, sizeof(pending_arg)) &&
              strcmp(pending_action, "hyfe_captcha_mode") == 0)) {
            send_message(cfg, chat, "Sesi captcha HYFE expired. Mulai klaim lagi.");
            return;
        }
        snprintf(sid, sizeof(sid), "%.240s", pending_arg);
        sep = strchr(sid, '|');
        if (!sep) {
            clear_pending(chat);
            send_message(cfg, chat, "Sesi HYFE rusak/expired. Mulai klaim lagi.");
            return;
        }
        *sep++ = '\0';
        snprintf(otp, sizeof(otp), "%.40s", sep);
        if (strcmp(mode, "manual") == 0) {
            send_hyfe_captcha_manual_prompt(cfg, chat, sid, otp);
            return;
        }
        clear_pending(chat);
        send_loading(cfg, chat, "Submit klaim HYFE dengan solver captcha");
        rc = hyfe_finish_claim(sid, otp, mode, "", out, sizeof(out));
        if (rc == 0) {
            json_get_string(out, "lpa", lpa, sizeof(lpa));
            json_get_string(out, "msisdn", msisdn, sizeof(msisdn));
            if (lpa[0]) {
                snprintf(msg, sizeof(msg),
                    "<b>Klaim HYFE sukses</b>\n\nNomor: <code>%s</code>\n\nLPA String:\n<code>%s</code>",
                    msisdn[0] ? msisdn : "-", lpa);
                send_inline_keyboard(cfg, chat, msg,
                    "{\"inline_keyboard\":[[{\"text\":\"Download ke eSIM\",\"callback_data\":\"menu:download\",\"style\":\"success\"},{\"text\":\"Menu\",\"callback_data\":\"menu:main\"}]]}");
                url_encode(lpa, enc, sizeof(enc));
                snprintf(qrurl, sizeof(qrurl), "https://quickchart.io/qr?size=320&text=%s", enc);
                send_photo_url(cfg, chat, qrurl, "QR eSIM HYFE");
            } else {
                send_inline_keyboard(cfg, chat,
                    "Klaim HYFE sudah tersubmit, tetapi LPA string belum ditemukan di response maupun email.\n\n"
                    "Pastikan HYFE Setting sudah berisi email + app password IMAP yang benar, lalu cek email HYFE secara manual.",
                    "{\"inline_keyboard\":[[{\"text\":\"HYFE Setting\",\"callback_data\":\"hyfe:settings\",\"style\":\"primary\"},"
                    "{\"text\":\"Menu\",\"callback_data\":\"menu:main\"}]]}");
            }
        } else {
            if (!json_get_string(out, "error", err, sizeof(err))) snprintf(err, sizeof(err), "%.450s", out);
            snprintf(msg, sizeof(msg), "Klaim HYFE gagal:\n<code>%.900s</code>", err);
            send_inline_keyboard(cfg, chat, msg,
                "{\"inline_keyboard\":[[{\"text\":\"Klaim Lagi\",\"callback_data\":\"hyfe:start\",\"style\":\"primary\"},{\"text\":\"Menu\",\"callback_data\":\"menu:main\"}]]}");
        }

    } else if (strcmp(data, "hyfe:captcha:settings") == 0) {
        send_hyfe_captcha_settings(cfg, chat);

    } else if (strcmp(data, "hyfe:settings") == 0) {
        send_hyfe_settings_menu(cfg, chat);

    } else if (strcmp(data, "hyfe:wizard:start") == 0) {
        send_hyfe_setup_otp_choice(cfg, chat);

    } else if (strcmp(data, "hyfe:wizard:captcha") == 0) {
        clear_pending(chat);
        send_hyfe_setup_captcha_choice(cfg, chat);

    } else if (strncmp(data, "hyfewizotp:", 11) == 0) {
        const char *mode = data + 11;
        if (strcmp(mode, "manual") != 0 && strcmp(mode, "imap") != 0) {
            send_hyfe_setup_otp_choice(cfg, chat);
            return;
        }
        send_hyfe_setup_email_prompt(cfg, chat, mode);

    } else if (strncmp(data, "hyfewizcap:", 11) == 0) {
        const char *mode = data + 11;
        int rc;
        if (!valid_captcha_mode(mode)) {
            send_hyfe_setup_captcha_choice(cfg, chat);
            return;
        }
        if (strcmp(mode, "manual") == 0) {
            clear_pending(chat);
            rc = hyfe_set_captcha("manual", "", out, sizeof(out));
            if (rc != 0) {
                snprintf(msg, sizeof(msg), "Gagal set captcha manual:\n<code>%.900s</code>", out);
                send_inline_keyboard(cfg, chat, msg,
                    "{\"inline_keyboard\":[[{\"text\":\"Setup Captcha\",\"callback_data\":\"hyfe:wizard:captcha\",\"style\":\"primary\"},{\"text\":\"Menu\",\"callback_data\":\"menu:main\"}]]}");
                return;
            }
            send_hyfe_setup_eid_choice(cfg, chat);
            return;
        }
        clear_pending(chat);
        save_pending(chat, "hyfe_wizard_captcha_key", mode);
        snprintf(msg, sizeof(msg),
            "<b>Setup Captcha HYFE</b>\n\n"
            "Kirim API key untuk provider <code>%s</code>.",
            mode);
        send_inline_keyboard(cfg, chat, msg,
            "{\"inline_keyboard\":[[{\"text\":\"Batal\",\"callback_data\":\"cancel\",\"style\":\"danger\"}]]}");

    } else if (strcmp(data, "hyfewizeid:save") == 0) {
        clear_pending(chat);
        save_pending(chat, "hyfe_wizard_eid", "");
        send_inline_keyboard(cfg, chat,
            "<b>Setup EID HYFE</b>\n\n"
            "Kirim EID 32 digit untuk disimpan sebagai <code>HYFE_EID_1</code>.",
            "{\"inline_keyboard\":[[{\"text\":\"Batal\",\"callback_data\":\"cancel\",\"style\":\"danger\"}]]}");

    } else if (strcmp(data, "hyfewizeid:skip") == 0) {
        clear_pending(chat);
        send_hyfe_setup_done(cfg, chat);

    } else if (strncmp(data, "hyfesetcfg:", 11) == 0) {
        char tmp[160], *key, *value;
        int rc;
        snprintf(tmp, sizeof(tmp), "%.150s", data + 11);
        key = tmp;
        value = strchr(tmp, ':');
        if (!value) {
            send_hyfe_settings_menu(cfg, chat);
            return;
        }
        *value++ = '\0';
        rc = hyfe_set_config_value(key, value, out, sizeof(out));
        snprintf(msg, sizeof(msg), rc == 0 ? "Config HYFE disimpan: <code>%s</code>" : "Gagal simpan config HYFE:\n<code>%.900s</code>",
                 rc == 0 ? key : out);
        send_inline_keyboard(cfg, chat, msg,
            "{\"inline_keyboard\":[[{\"text\":\"HYFE Setting\",\"callback_data\":\"hyfe:settings\",\"style\":\"primary\"},{\"text\":\"Menu\",\"callback_data\":\"menu:main\"}]]}");

    } else if (strncmp(data, "hyfeprompt:", 11) == 0) {
        const char *key = data + 11;
        clear_pending(chat);
        save_pending(chat, "hyfe_set_config", key);
        snprintf(msg, sizeof(msg), "Kirim nilai untuk <code>%s</code>.", key);
        send_inline_keyboard(cfg, chat, msg,
            "{\"inline_keyboard\":[[{\"text\":\"Batal\",\"callback_data\":\"cancel\",\"style\":\"danger\"}]]}");

    } else if (strcmp(data, "hyfeemail:slot") == 0 || strcmp(data, "hyfepass:slot") == 0 || strcmp(data, "hyfeeid:slot") == 0) {
        const char *prefix = (strcmp(data, "hyfeemail:slot") == 0) ? "hyfeemail" :
                             (strcmp(data, "hyfepass:slot") == 0) ? "hyfepass" : "hyfeeid";
        snprintf(msg, sizeof(msg), "Pilih slot 1-5.");
        snprintf(out, sizeof(out),
            "{\"inline_keyboard\":["
            "[{\"text\":\"1\",\"callback_data\":\"%s:1\"},{\"text\":\"2\",\"callback_data\":\"%s:2\"},{\"text\":\"3\",\"callback_data\":\"%s:3\"}],"
            "[{\"text\":\"4\",\"callback_data\":\"%s:4\"},{\"text\":\"5\",\"callback_data\":\"%s:5\"}],"
            "[{\"text\":\"HYFE Setting\",\"callback_data\":\"hyfe:settings\",\"style\":\"primary\"}]]}",
            prefix, prefix, prefix, prefix, prefix);
        send_inline_keyboard(cfg, chat, msg, out);

    } else if (strncmp(data, "hyfeemail:", 10) == 0 || strncmp(data, "hyfepass:", 9) == 0 || strncmp(data, "hyfeeid:", 8) == 0) {
        char key[40];
        int slot = 0;
        if (strncmp(data, "hyfeemail:", 10) == 0) {
            slot = atoi(data + 10);
            snprintf(key, sizeof(key), "HYFE_EMAIL_%d", slot);
        } else if (strncmp(data, "hyfepass:", 9) == 0) {
            slot = atoi(data + 9);
            snprintf(key, sizeof(key), "HYFE_IMAP_PASS_%d", slot);
        } else {
            slot = atoi(data + 8);
            snprintf(key, sizeof(key), "HYFE_EID_%d", slot);
        }
        if (slot < 1 || slot > 5) {
            send_hyfe_settings_menu(cfg, chat);
            return;
        }
        clear_pending(chat);
        save_pending(chat, "hyfe_set_config", key);
        snprintf(msg, sizeof(msg), "Kirim nilai untuk <code>%s</code>.", key);
        send_inline_keyboard(cfg, chat, msg,
            "{\"inline_keyboard\":[[{\"text\":\"Batal\",\"callback_data\":\"cancel\",\"style\":\"danger\"}]]}");

    } else if (strncmp(data, "hyfesetcap:", 11) == 0) {
        const char *mode = data + 11;
        int rc;
        if (!valid_captcha_mode(mode)) {
            send_hyfe_captcha_settings(cfg, chat);
            return;
        }
        if (strcmp(mode, "manual") == 0) {
            rc = hyfe_set_captcha("manual", "", out, sizeof(out));
            snprintf(msg, sizeof(msg), rc == 0 ? "Captcha HYFE diset ke <code>manual</code>." : "Gagal set captcha manual: %.900s", out);
            send_inline_keyboard(cfg, chat, msg,
                "{\"inline_keyboard\":[[{\"text\":\"HYFE Setting\",\"callback_data\":\"hyfe:settings\",\"style\":\"primary\"},{\"text\":\"Menu\",\"callback_data\":\"menu:main\"}]]}");
            return;
        }
        clear_pending(chat);
        save_pending(chat, "hyfe_set_captcha_key", mode);
        snprintf(msg, sizeof(msg), "Kirim API key untuk provider captcha <code>%s</code>.", mode);
        send_inline_keyboard(cfg, chat, msg,
            "{\"inline_keyboard\":[[{\"text\":\"Batal\",\"callback_data\":\"cancel\",\"style\":\"danger\"}]]}");
    } else if (strcmp(data, "menu:settings") == 0) {
        send_settings_menu(cfg, chat);

    } else if (strcmp(data, "menu:main") == 0) {
        clear_pending(chat);
        send_main_menu(cfg, chat);

    } else if (strcmp(data, "menu:profiles") == 0) {
        send_profile_menu(cfg, chat);

    } else if (strcmp(data, "menu:manage") == 0) {
        send_manage_profile_menu(cfg, chat);

    } else if (strcmp(data, "menu:download") == 0) {
        save_pending(chat, "download", "");
        send_keyboard(cfg, chat,
            "📥 <b>Download eSIM</b>\n\n"
            "Kirim activation code format:\n<code>LPA:1$SM-DP+$MATCHING_ID</code>\n\nAtau /cancel.",
            "{\"keyboard\":[[{\"text\":\"Menu Utama\"}]],\"resize_keyboard\":true}");

    } else if (strcmp(data, "menu:notifprocess") == 0) {
        char *args[] = { "notif-process", NULL };
        int rc;
        send_loading(cfg, chat, "Process Notifications");
        rc = lpac_api(args, out, sizeof(out), 70);
        compact_result(out, msg, sizeof(msg));
        if (rc != 0 && !msg[0]) snprintf(msg, sizeof(msg), "Gagal memproses notifications (rc=%d).", rc);
        send_inline_keyboard(cfg, chat, msg[0] ? msg : "Process Notifications selesai.",
            "{\"inline_keyboard\":[[{\"text\":\"Profile List\",\"callback_data\":\"menu:profiles\",\"style\":\"primary\"},"
            "{\"text\":\"Menu\",\"callback_data\":\"menu:main\"}]]}");

    } else if (strcmp(data, "hyfe:start") == 0) {
        send_hyfe_start_prompt(cfg, chat);
    } else if (strcmp(data, "menu:quota") == 0) {
        send_quota_menu(cfg, chat);

    } else if (strncmp(data, "qc:", 3) == 0) {
        const char *qc_arg = data + 3;

        if (strcmp(qc_arg, "manual") == 0) {
            /* User wants to type a number manually – set pending then wait */
            clear_pending(chat);
            save_pending(chat, "quota", "");
            send_keyboard(cfg, chat,
                "\xF0\x9F\x93\x8A <b>Cek Kuota Manual</b>\n\n"
                "Kirim nomor XL/MSISDN:\n"
                "Contoh: <code>08123456789</code>\n\n"
                "Atau /cancel untuk batal.",
                "{\"keyboard\":[[{\"text\":\"Menu Utama\"}]]"
                ",\"resize_keyboard\":true,\"one_time_keyboard\":false}");
        } else {
            /* qc:<iccid> – look up MSISDN from profile nickname then run quota */
            char prof_out[BUF_MAX];
            char *prof_args[] = { "profiles", NULL };
            profile_t profiles[MAX_PROFILES];
            int pcount, pi;
            char msisdn[32] = "";
            char iccid_clean[40];
            int found = 0;

            snprintf(iccid_clean, sizeof(iccid_clean), "%.38s", qc_arg);

            lpac_api(prof_args, prof_out, sizeof(prof_out), 35);
            pcount = parse_profiles(prof_out, profiles, MAX_PROFILES);

            for (pi = 0; pi < pcount; pi++) {
                if (strcmp(profiles[pi].iccid, iccid_clean) == 0) {
                    const char *name = profiles[pi].nick[0] ? profiles[pi].nick
                                     : profiles[pi].provider;
                    found = 1;
                    extract_msisdn_from_nick(name, msisdn, sizeof(msisdn));
                    break;
                }
            }

            if (!found) {
                send_inline_keyboard(cfg, chat,
                    "\xE2\x9A\xA0 Profile tidak ditemukan.",
                    "{\"inline_keyboard\":["
                    "[{\"text\":\"\xF0\x9F\x93\x8A Cek Kuota\",\"callback_data\":\"menu:quota\"}"
                    ",{\"text\":\"\xF0\x9F\x8F\xA0 Menu Utama\",\"callback_data\":\"menu:main\"}]"
                    "]}");
                return;
            }

            if (!msisdn[0]) {
                /* Nickname has no parseable number – ask user to type it */
                clear_pending(chat);
                save_pending(chat, "quota", "");
                snprintf(msg, sizeof(msg),
                    "\xF0\x9F\x93\x8A <b>Cek Kuota</b>\n\n"
                    "\xE2\x9A\xA0 Nomor HP tidak ditemukan di nickname profile.\n\n"
                    "Kirim nomor XL/MSISDN secara manual:\n"
                    "Contoh: <code>08123456789</code>\n\n"
                    "Atau /cancel untuk batal.");
                send_keyboard(cfg, chat, msg,
                    "{\"keyboard\":[[{\"text\":\"Menu Utama\"}]]"
                    ",\"resize_keyboard\":true,\"one_time_keyboard\":false}");
                return;
            }

            /* Got MSISDN from nickname – run quota immediately */
            {
                int qrc;
                send_loading(cfg, chat, "Mengecek kuota XL");
                qrc = esim_quota(msisdn, out, sizeof(out));
                snprintf(msg, sizeof(msg), "%.3900s",
                         out[0] ? out : (qrc == 0 ? "Tidak ada output kuota." : "Gagal cek kuota."));
                send_inline_keyboard(cfg, chat, msg,
                    "{\"inline_keyboard\":["
                    "[{\"text\":\"\xF0\x9F\x93\x8A Cek Kuota Lagi\",\"callback_data\":\"menu:quota\"}"
                    ",{\"text\":\"\xF0\x9F\x8F\xA0 Menu Utama\",\"callback_data\":\"menu:main\"}]"
                    "]}");
            }
        }
    }
}

static void process_updates(const struct config *cfg, char *json, long long *offset)
{
    char *p = json;
    while ((p = strstr(p, "\"update_id\":"))) {
        long long update_id = strtoll(p + 12, NULL, 10);
        char *next = strstr(p + 12, "\"update_id\":");
        char saved = '\0';
        char text[1024] = "";
        char chat[64] = "";
        char cb_id[64] = "";
        char cb_data[128] = "";

        if (next) {
            saved = *next;
            *next = '\0';
        }
        json_chat_id_after(p, chat, sizeof(chat));
        json_string_after(p, "\"text\":", text, sizeof(text));

        /* Check for callback_query */
        if (strstr(p, "\"callback_query\"")) {
            json_string_after(p, "\"id\":", cb_id, sizeof(cb_id));
            json_string_after(p, "\"data\":", cb_data, sizeof(cb_data));
        }

        if (update_id >= *offset) *offset = update_id + 1;

        if (chat[0]) {
            /* Security: enforce allowed chat ID for callbacks too */
            if (cfg->chat_id[0] && strcmp(chat, cfg->chat_id) != 0) {
                /* silently ignore unauthorized */
            } else if (cb_data[0] && cb_id[0]) {
                handle_callback(cfg, chat, cb_id, cb_data);
            } else if (text[0]) {
                handle_command(cfg, chat, text);
            }
        }

        if (next) {
            *next = saved;
            p = next;
        } else {
            break;
        }
    }
}

int main(void)
{
    struct config cfg;
    long long offset = load_offset();
    char updates[BUF_MAX];

    load_config(&cfg);
    if (strcmp(cfg.enabled, "1") != 0) {
        log_msg("disabled by UCI");
        return 0;
    }
    if (!valid_token(cfg.token)) {
        log_msg("missing or invalid telegram_bot_token");
        return 1;
    }
    if (cfg.chat_id[0] && !valid_chat_id(cfg.chat_id)) {
        log_msg("invalid telegram_allowed_chat_id");
        return 1;
    }

    log_msg("started (poll=%ds, debug=%d, chat_locked=%s)",
            cfg.reconnect_delay, cfg.debug,
            cfg.chat_id[0] ? cfg.chat_id : "no");
    write_status("starting", 0, offset);
    {
        int consecutive_fail = 0;
        time_t last_fail_log = 0;
        for (;;) {
            int rc = telegram_get_updates(&cfg, offset, updates, sizeof(updates));
            if (rc == 0) {
                process_updates(&cfg, updates, &offset);
                save_offset(offset);
                consecutive_fail = 0;
                write_status("ok", 0, offset);
            } else {
                consecutive_fail++;
                /* Rate-limited error logging so a persistent failure (bad
                 * token, no DNS, no internet) leaves a visible trail in
                 * syslog without spamming it. Log every failure when debug
                 * is on; otherwise log at most once a minute and always log
                 * the first failure of a new outage. */
                time_t now = time(NULL);
                int should_log = cfg.debug || consecutive_fail == 1 ||
                                 (now - last_fail_log) >= 60;
                if (should_log) {
                    log_msg("getUpdates failed rc=%d (consecutive=%d)",
                            rc, consecutive_fail);
                    last_fail_log = now;
                }
                write_status("error", rc, offset);
                /* Back off harder on repeated failures (max ~30s) so we
                 * don't hammer api.telegram.org during outages. */
                int backoff = consecutive_fail > 5 ? 30 : 10;
                sleep((unsigned int)backoff);
            }
            sleep((unsigned int)cfg.reconnect_delay);
        }
    }
}
