# shellcheck shell=sh
# common.sh - shared helpers for hyfetrial
#
# Required globals (set by main script):
#   HYFE_VERBOSE   - "1" to enable verbose log
#   HYFE_DEBUG     - "1" to enable debug log (includes HTTP bodies)
#   HYFE_BASE      - upstream API base URL
#   HYFE_ORIGIN    - Origin/Referer URL for requests
#   HYFE_UA        - User-Agent string
#   HYFE_COOKIES   - path to cookie jar
#   HYFE_TOKEN     - bearer token (set after auth)
#   HYFE_CSRF      - csrf token (set after session)

: "${HYFE_VERBOSE:=0}"
: "${HYFE_DEBUG:=0}"
: "${HYFE_BASE:=https://jupiter-ms-webprio-v2.ext.dp.xl.co.id}"
: "${HYFE_AUTH_URL:=https://prioritas.xl.co.id/hyfe-apply/api/auth}"
: "${HYFE_ORIGIN:=https://prioritas.xl.co.id}"
: "${HYFE_REFERER:=https://prioritas.xl.co.id/hyfe-apply/esim-trial}"
: "${HYFE_UA:=Mozilla/5.0 (Linux; OpenWrt) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36}"
: "${HYFE_RECAPTCHA_SITEKEY:=6Lf-vXwiAAAAABOLVRxiP3pWHhgs8g7KFJUXhb6i}"
: "${HYFE_RECAPTCHA_PAGE_URL:=https://prioritas.xl.co.id/hyfe-apply/esim-trial/input-eid}"
: "${HYFE_TNC_CHANNEL_ID:=7c93208a-6a17-462d-933b-73492818ce01}"

log_info() {
    printf '[hyfetrial] %s\n' "$*" >&2
}

log_warn() {
    printf '[hyfetrial][warn] %s\n' "$*" >&2
}

log_error() {
    printf '[hyfetrial][error] %s\n' "$*" >&2
}

log_verbose() {
    [ "$HYFE_VERBOSE" = "1" ] || [ "$HYFE_DEBUG" = "1" ] || return 0
    printf '[hyfetrial][verbose] %s\n' "$*" >&2
}

log_debug() {
    [ "$HYFE_DEBUG" = "1" ] || return 0
    printf '[hyfetrial][debug] %s\n' "$*" >&2
}

die() {
    log_error "$@"
    exit 1
}

# Require external commands
require_cmd() {
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || die "command not found: $cmd"
    done
}

# Generate a UUID-v4 like string (for requestid header).
# Uses /proc/sys/kernel/random/uuid if available (Linux),
# otherwise falls back to /dev/urandom + awk.
gen_uuid() {
    if [ -r /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
        return
    fi
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen
        return
    fi
    # POSIX fallback
    od -An -N16 -tx1 /dev/urandom 2>/dev/null \
        | tr -d ' \n' \
        | awk '{
            printf "%s-%s-4%s-%s%s-%s\n",
                substr($0,1,8), substr($0,9,4),
                substr($0,14,3),
                substr(substr($0,17,1),1,1)~/[89ab]/?substr($0,17,1):"a",
                substr($0,18,3), substr($0,21,12)
        }'
}

# JSON-escape a string (for embedding in JSON payloads when jq is not desired).
json_escape() {
    # Read from $1 (or stdin if missing)
    if [ $# -gt 0 ]; then
        printf '%s' "$1" | jq -Rs .
    else
        jq -Rs .
    fi
}

# Pretty-print JSON to stderr if debug is on
debug_json() {
    [ "$HYFE_DEBUG" = "1" ] || return 0
    label="$1"
    shift
    printf '[hyfetrial][debug] %s:\n' "$label" >&2
    if [ $# -gt 0 ]; then
        printf '%s\n' "$1" | jq . >&2 2>/dev/null \
            || printf '%s\n' "$1" >&2
    else
        jq . >&2 2>/dev/null
    fi
}

# Validate that a JSON response from the upstream succeeded.
# Usage: assert_status_ok "<context>" "<json_body>"
assert_status_ok() {
    ctx="$1"
    body="$2"
    sc=$(printf '%s' "$body" | jq -r '.statusCode // empty' 2>/dev/null)
    if [ -z "$sc" ]; then
        log_error "$ctx: no statusCode in response"
        log_error "body: $body"
        return 1
    fi
    if [ "$sc" != "200" ] && [ "$sc" != "201" ]; then
        msg=$(printf '%s' "$body" | jq -r '.statusMessage // .message // .result.errorMessage // "unknown"' 2>/dev/null)
        log_error "$ctx: statusCode=$sc message=$msg"
        log_error "body: $body"
        return 1
    fi
    return 0
}

# Read cookie value from cookie jar.
# Usage: cookie_get <name>
#
# curl writes Netscape-format cookies. Comment lines start with `# `.
# HttpOnly cookies are written as `#HttpOnly_<domain>\t...` (no space, leading
# `#` is significant). We must include those - the auth `token` cookie set by
# /hyfe-apply/api/auth is HttpOnly - while still excluding real `# Netscape...`
# header/comment lines.
cookie_get() {
    name="$1"
    [ -f "$HYFE_COOKIES" ] || return 1
    awk -v n="$name" '
        # skip blank lines and comments that are NOT "#HttpOnly_..."
        /^[[:space:]]*$/ { next }
        /^#/ && $0 !~ /^#HttpOnly_/ { next }
        # for HttpOnly lines the domain field still has the "#HttpOnly_" prefix,
        # but field positions are unchanged, so $6 is still the cookie name.
        $6 == n { print $7; exit }
    ' "$HYFE_COOKIES"
}

# Helper: trim leading/trailing whitespace
trim() {
    printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# Print a positive integer in [1..max] using /dev/urandom when available.
# Falls back to date+PID mixing so it still works on minimal busybox where
# /dev/urandom is missing or od is unavailable.
#
# Each call mixes:
#   - 4 fresh bytes from /dev/urandom (32-bit)
#   - epoch seconds
#   - $$ (shell PID)
#   - a per-process counter (_HYFE_RAND_CTR) so consecutive calls within
#     the same process never collide on a degraded entropy source
# Result is reduced modulo _max with a deflated bias.
random_int() {
    _max="$1"
    _max=${_max:-1}
    [ "$_max" -gt 0 ] 2>/dev/null || _max=1
    _n=""
    if [ -r /dev/urandom ] && command -v od >/dev/null 2>&1; then
        _n=$(od -An -N4 -tu4 /dev/urandom 2>/dev/null | tr -d ' ')
    fi
    if [ -z "$_n" ] && command -v hexdump >/dev/null 2>&1 && [ -r /dev/urandom ]; then
        _n=$(hexdump -n 4 -e '"%u"' /dev/urandom 2>/dev/null)
    fi
    [ -n "$_n" ] || _n=0
    _ts=$(date +%s%N 2>/dev/null)
    case "$_ts" in
        ''|*N*) _ts=$(date +%s 2>/dev/null) ;;
    esac
    [ -n "$_ts" ] || _ts=1
    _HYFE_RAND_CTR=$(( ${_HYFE_RAND_CTR:-0} + 1 ))
    # Avoid arithmetic overflow on 32-bit shells: reduce each component
    # modulo a 16-bit prime before combining.
    _a=$(( _n  % 65521 ))
    _b=$(( _ts % 65521 ))
    _c=$(( $$  % 65521 ))
    _d=$(( _HYFE_RAND_CTR % 65521 ))
    _mix=$(( (_a * 1103515245 + _b * 12345 + _c * 2654435761 + _d) & 0x7fffffff ))
    echo $(( (_mix % _max) + 1 ))
}

# Random Indonesian-style two-word name (e.g. "Andi Pratama").
# Used by the interactive prompt when the user picks "random".
random_indo_name() {
    _firsts="Andi Budi Citra Dewi Eka Fajar Gita Hadi Ika Joko Kiki Lina Mira Nina Oki Putri Rizki Sari Tono Umar Vina Wahyu Yuli Zaki Adi Bayu Cahya Dian Endah Faisal Galih Hana Indah Jaya Krisna Lukman Maya Nadia Ovi Purnama Reza Rama Sinta Tirta"
    _lasts="Pratama Saputra Wijaya Hartono Santoso Permata Anggraini Lestari Susanti Utami Kusuma Wibowo Setiawan Nugroho Hidayat Maulana Firmansyah Ramadhan Pangestu Anggara Cahyono Darmawan Kurnia Mahendra Pradipta Aditya Iskandar Sudirman"
    _f_count=$(printf '%s' "$_firsts" | awk '{print NF}')
    _l_count=$(printf '%s' "$_lasts"  | awk '{print NF}')
    _r1=$(random_int "$_f_count")
    _r2=$(random_int "$_l_count")
    _f=$(printf '%s' "$_firsts" | awk -v i="$_r1" '{print $i}')
    _l=$(printf '%s' "$_lasts"  | awk -v i="$_r2" '{print $i}')
    printf '%s %s' "$_f" "$_l"
}

# Indonesian mobile operator prefix list (3 digits, no leading zero).
# Covers Telkomsel, Indosat, XL, Smartfren, Tri, Axis. Used by
# random_wa_local so generated numbers look like real-world MSISDNs
# instead of repeating-digit garbage like "0888888...".
_HYFE_WA_PREFIXES="811 812 813 821 822 823 851 852 853 \
814 815 816 855 856 857 858 \
817 818 819 859 877 878 \
881 882 883 884 885 886 887 888 889 \
895 896 897 898 899 \
831 832 833 838"

# Random Indonesian mobile MSISDN local part (without leading 0 / +62).
#
# Format: 11 digits total = 3-digit operator prefix + 8 random digits. The
# CLI strips leading 0/+62 and validates 8..12 digits, so 11 digits is in
# range and matches the upstream form's "08XXXXXXXXX" expectation.
#
# Picking the first 3 digits from a real operator prefix list (instead of
# always "8" + 10 random digits) gives much better surface variety, so the
# random output looks like an actual Indonesian mobile number rather than
# something obviously synthetic. The remaining 8 digits are independent
# random_int(10) draws.
random_wa_local() {
    _pcount=$(printf '%s' "$_HYFE_WA_PREFIXES" | awk '{print NF}')
    _pidx=$(random_int "$_pcount")
    _pref=$(printf '%s' "$_HYFE_WA_PREFIXES" | awk -v i="$_pidx" '{print $i}')
    _out="$_pref"
    _i=1
    while [ "$_i" -le 8 ]; do
        _r=$(random_int 10)
        _d=$((_r - 1))
        _out="${_out}${_d}"
        _i=$((_i + 1))
    done
    printf '%s' "$_out"
}
