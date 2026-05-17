# shellcheck shell=sh
# hyfe.sh - klaim eSIM Trial HYFE (XL Prioritas) - library bagian dari `esim`.
#
# Modul ini menyediakan claim flow + wizard config interaktif. Di-source oleh
# `esim` dan diakses lewat menu utama "Klaim eSIM Trial HYFE (XL Prioritas)".
#
# PUBLIC ENTRY POINTS:
#   hyfe_menu                - render submenu Klaim HYFE (10 opsi)
#   hyfe_claim_now           - klaim interaktif penuh (wizard semua field)
#   hyfe_quick_setup         - wizard preferences buat klaim cepat
#   hyfe_quick_claim         - klaim cepat (auto-resolve dari HYFE_QUICK_*)
#   hyfe_list_numbers_menu   - fetch + tampilkan daftar MSISDN
#   hyfe_setup_config        - wizard_new_config (full setup)
#   hyfe_edit_captcha_config - wizard_captcha_config
#   hyfe_edit_imap_config    - wizard_imap_config
#   hyfe_edit_email_config   - wizard_email_config
#   hyfe_show_config         - print isi config (password ter-mask)
#
# DEPENDENSI YANG HARUS SUDAH DI-SOURCE OLEH HOST (esim):
#   src/lib/common.sh   - log_info/die/random_*/json_escape/...
#   src/lib/config.sh   - config_*/wizard_*
#   src/lib/api.sh      - api_auth/api_session/api_find_msisdn/...
#   src/lib/captcha.sh  - captcha_solve/captcha_resolve_key
#   src/lib/otp.sh      - otp_get/otp_capture_baseline/...
#
# UI HELPER YANG DIPAKAI (di-define oleh `esim`):
#   section_header, kv_row, box_top, box_bottom, box_sep, box_text,
#   box_center, box_item, box_menu_item, box_menu_sep, box_line_thin,
#   repeat_char, pause, trim_text, pad_right, clear_screen
#   warna: BCYAN BGREEN BRED BYELLOW BMAGENTA BBLUE WHITE DIM BOLD RESET
#   konstanta: BOX_WIDTH

# Versi independent dari esim/lpac.
HYFE_VERSION="0.2.0"

# ---------- claim flow state ----------
#
# Globals untuk satu siklus claim. Di-reset di awal setiap entry point yg
# memulai claim baru (hyfe_claim_now / hyfe_quick_claim) supaya state lama
# nggak nyangkut antar-call dalam menu loop.
NAME=""
WHATSAPP=""
EMAIL=""
EID=""
PATTERN=""
PICK_MSISDN=""
LIST_ONLY=0
PAGES=1
DRY_RUN=0
ASSUME_YES=0
INTERACTIVE=0
EMAIL_MANUAL=0
SELECTED_MSISDN=""
SELECTED_ENCRYPT=""
CONFIG_FILE=""

# Reset claim-cycle state. Dipanggil di awal hyfe_claim_now / hyfe_quick_claim.
#
# Catatan: HYFE_IMAP_USER & HYFE_IMAP_PASS juga di-reset disini supaya tidak
# bocor antar-slot. Tanpa reset, user yg sebelumnya pakai slot Y (HYFE_IMAP_PASS_Y
# ter-export ke HYFE_IMAP_PASS) lalu pindah ke slot X tanpa pass akan ngedapetin
# kredensial Y - polling IMAP-nya jadi mantau mailbox Y, padahal OTP dikirim ke
# email X. _hyfe_ensure_config nanti load ulang dari CONFIG_FILE (kalau ada
# HYFE_IMAP_USER global di config), claim-now/quick-claim juga akan set ulang
# dari email-slot yang user pilih.
_hyfe_reset_state() {
    NAME=""; WHATSAPP=""; EMAIL=""; EID=""; PATTERN=""
    PICK_MSISDN=""; SELECTED_MSISDN=""; SELECTED_ENCRYPT=""
    LIST_ONLY=0; PAGES=1; DRY_RUN=0; ASSUME_YES=0
    INTERACTIVE=0; EMAIL_MANUAL=0
    HYFE_IMAP_USER=""; HYFE_IMAP_PASS=""
    export HYFE_IMAP_USER HYFE_IMAP_PASS
}

# Auto-load config file jika belum di-load oleh host. `esim` biasanya udah
# load via _hyfe_ensure_config sebelum masuk submenu, tapi guard ini bikin
# fungsi-fungsi di sini aman dipanggil standalone (mis. dari pengetesan).
_hyfe_ensure_config() {
    if [ -z "${CONFIG_FILE:-}" ] && [ -r "$(config_default_path)" ]; then
        CONFIG_FILE=$(config_default_path)
    fi
    if [ -n "${CONFIG_FILE:-}" ] && [ -r "$CONFIG_FILE" ]; then
        # shellcheck disable=SC1090
        if ! ( . "$CONFIG_FILE" ) >/dev/null 2>&1; then
            log_warn "config $CONFIG_FILE tidak valid (syntax error?), di-skip"
            return 0
        fi
        # shellcheck disable=SC1090
        . "$CONFIG_FILE"
    fi
    # Resolve per-provider captcha key into HYFE_CAPTCHA_KEY (which is what
    # captcha_solve in lib/captcha.sh actually reads). The old standalone
    # hyfetrial CLI did this right after sourcing the config; preserve the
    # same behavior here so non-manual modes work without extra prompts.
    if [ -z "${HYFE_CAPTCHA_KEY:-}" ] && [ -n "${HYFE_CAPTCHA_MODE:-}" ]; then
        HYFE_CAPTCHA_KEY=$(captcha_resolve_key "$HYFE_CAPTCHA_MODE" 2>/dev/null || true)
        [ -n "$HYFE_CAPTCHA_KEY" ] && export HYFE_CAPTCHA_KEY
    fi
}

# Cookie jar lifecycle - claim flow butuh cookie jar khusus. Setiap entry
# point claim bikin baru + cleanup di akhir. Pakai EXIT trap di subshell
# (lihat hyfe_claim_now) supaya bersih meskipun esim crash mid-flow.
_hyfe_init_cookies() {
    HYFE_COOKIES="${HYFE_COOKIES:-${TMPDIR:-/tmp}/hyfe-cookies.$$}"
    export HYFE_COOKIES
    : > "$HYFE_COOKIES"
}

_hyfe_cleanup_cookies() {
    [ -n "${HYFE_COOKIES:-}" ] && rm -f "$HYFE_COOKIES" 2>/dev/null
}

# ---------- input validation ----------

validate_inputs() {
    err=0
    if [ -z "$NAME" ];     then log_error "missing --name";     err=1; fi
    if [ -z "$WHATSAPP" ]; then log_error "missing --whatsapp"; err=1; fi
    if [ -z "$EMAIL" ];    then log_error "missing --email";    err=1; fi
    if [ -z "$EID" ];      then log_error "missing --eid";      err=1; fi
    [ "$err" = 0 ] || return 1

    # Whatsapp: digits only, no leading 0/+62
    case "$WHATSAPP" in
        +62*) WHATSAPP=${WHATSAPP#+62} ;;
        62*)  WHATSAPP=${WHATSAPP#62} ;;
        0*)   WHATSAPP=${WHATSAPP#0} ;;
    esac
    if ! printf '%s' "$WHATSAPP" | grep -Eq '^[0-9]{8,12}$'; then
        die "invalid --whatsapp: $WHATSAPP (expected 8-12 digits, no +62/0 prefix)"
    fi

    # Email: minimal sanity
    case "$EMAIL" in
        *@*.*) ;;
        *) die "invalid --email: $EMAIL" ;;
    esac

    # EID: 32 digits, allow user to paste with separators
    eid_clean=$(printf '%s' "$EID" | tr -d ' :-')
    if ! printf '%s' "$eid_clean" | grep -Eq '^[0-9]{32}$'; then
        die "invalid --eid: expected 32 digits, got '$EID'"
    fi
    EID="$eid_clean"

    # Pattern: digits only, up to 5
    if [ -n "$PATTERN" ] && ! printf '%s' "$PATTERN" | grep -Eq '^[0-9]{1,5}$'; then
        die "invalid --pattern: $PATTERN (1-5 digits)"
    fi
}

# Pick a random page (mirrors the web app's "Math.floor(496*random)+5" trick
# which spreads requests across the inventory).
random_page() {
    if command -v od >/dev/null 2>&1; then
        n=$(od -An -N4 -tu4 /dev/urandom 2>/dev/null | tr -d ' ')
        [ -n "$n" ] || n=$(date +%s)
    else
        n=$(date +%s)
    fi
    echo $(( (n % 496) + 5 ))
}

# Decide what URL `?page=` and body `pageNo` to use for a given URL pagination
# index. Mirrors the web app:
#   - if --pattern set: pageNo=1
#   - else:             pageNo=random(5..500), URL page iterates 1..N
_msisdn_body_page() {
    if [ -n "$PATTERN" ]; then
        echo 1
    else
        random_page
    fi
}

# ---------- list-numbers mode ----------

list_numbers_mode() {
    api_auth
    api_session
    url_page=1
    pages_left="$PAGES"
    while [ "$pages_left" -gt 0 ]; do
        body_page=$(_msisdn_body_page)
        body=$(api_find_msisdn "$url_page" "$body_page" "$PATTERN") || return 1
        count=$(printf '%s' "$body" | jq -r '.result.data.noMsisdn | length')
        total=$(printf '%s' "$body" | jq -r '.result.data.totalPageMsisdn // 0')
        log_verbose "url_page=$url_page count=$count total_pages=$total"
        printf '%s' "$body" | jq -r '
            .result.data.noMsisdn[]
            | "\(.msisdn)\t\(.encrypt)"
        '
        pages_left=$((pages_left - 1))
        url_page=$((url_page + 1))
        # Stop when we exceed totalPageMsisdn to avoid empty pages.
        if [ "$total" -gt 0 ] && [ "$url_page" -gt "$total" ]; then
            break
        fi
    done
}

# Pick an available MSISDN; if --pick-msisdn was given, find that one in the
# listing and use its encrypt blob. In interactive mode, show a numbered menu
# of the available numbers so the user can choose one explicitly.
pick_msisdn() {
    api_auth
    api_session
    url_page=1
    body_page=$(_msisdn_body_page)
    body=$(api_find_msisdn "$url_page" "$body_page" "$PATTERN") || return 1
    lines=$(printf '%s' "$body" | jq -r '
        .result.data.noMsisdn[]
        | "\(.msisdn)\t\(.encrypt)"
    ')
    if [ -n "$PICK_MSISDN" ]; then
        target="$PICK_MSISDN"
        # tolerate both 0817-... and raw digits
        target_clean=$(printf '%s' "$target" | tr -d ' -')
        line=$(printf '%s\n' "$lines" \
            | awk -F '\t' -v t="$target_clean" '$1 == t { print; exit }' \
            | head -n1)
        if [ -z "$line" ]; then
            die "pick-msisdn: $target not found on page $url_page (try --list-numbers --pattern ...)"
        fi
    elif [ "${INTERACTIVE:-0}" = 1 ]; then
        if _prompt_msisdn_choice "$lines" "$url_page" "$body_page"; then
            line="${MSISDN_CHOICE_LINE:-}"
        else
            line=""
        fi
    else
        # Guard with `if length == 0 then empty` so an empty array yields ""
        # instead of jq's default "null\tnull" output (which would otherwise
        # slip past the `[ "$line" = "null" ]` check below).
        line=$(printf '%s\n' "$lines" | awk 'NF { print; exit }')
    fi
    # Defense-in-depth: also reject "null" or "null\tnull" if jq behaviour
    # changes upstream.
    case "$line" in
        ""|null|null*null) line="" ;;
    esac
    if [ -z "$line" ]; then
        die "no MSISDN available (url_page=$url_page body_pageNo=$body_page)"
    fi
    SELECTED_MSISDN=$(printf '%s' "$line" | cut -f1)
    SELECTED_ENCRYPT=$(printf '%s' "$line" | cut -f2)
    log_info "selected MSISDN: $SELECTED_MSISDN"
}

_prompt_msisdn_choice() {
    _lines=$1
    _url_page=$2
    _body_page=$3
    MSISDN_CHOICE_LINE=""
    _count=$(printf '%s\n' "$_lines" | awk 'NF { n++ } END { print n + 0 }')
    if [ "$_count" -le 0 ]; then
        return 1
    fi

    while :; do
        {
            printf '\nNomor tersedia'
            [ -n "$PATTERN" ] && printf ' untuk pola %s' "$PATTERN"
            printf ' (url_page=%s body_pageNo=%s):\n' "$_url_page" "$_body_page"
            printf '%s\n' "$_lines" | awk -F '\t' 'NF { printf "  %d) %s\n", ++n, $1 }'
        } >&2
        _prompt _ans "Pilih nomor" "1"
        case "$_ans" in
            ''|*[!0-9]*)
                _target=$(printf '%s' "$_ans" | tr -d ' -')
                _line=$(printf '%s\n' "$_lines" \
                    | awk -F '\t' -v t="$_target" '$1 == t { print; exit }')
                ;;
            *)
                if [ "$_ans" -ge 1 ] && [ "$_ans" -le "$_count" ]; then
                    _line=$(printf '%s\n' "$_lines" \
                        | awk -F '\t' -v idx="$_ans" 'NF { n++ } n == idx { print; exit }')
                else
                    _target=$(printf '%s' "$_ans" | tr -d ' -')
                    _line=$(printf '%s\n' "$_lines" \
                        | awk -F '\t' -v t="$_target" '$1 == t { print; exit }')
                fi
                ;;
        esac
        if [ -n "$_line" ]; then
            MSISDN_CHOICE_LINE="$_line"
            return 0
        fi
        printf '  pilihan tidak valid (1..%d atau ketik nomor lengkap)\n' "$_count" >&2
    done
}

# _prompt_choice VARNAME "Label"
# Ask the user to pick mode 1 (random) or 2 (manual).
# Pressing Enter accepts the default (1=random). The result is assigned to
# VARNAME with the literal string "random" or "manual". Returns rc=130 with
# a clear message on EOF instead of silently exiting under `set -eu`.
# _prompt_email - render a numbered menu of HYFE_EMAIL_N accounts loaded from
# the config (if any), plus a "ketik manual" entry. When the user picks an
# account that has a matching HYFE_IMAP_PASS_N, that password is also
# loaded into HYFE_IMAP_PASS so the IMAP polling step can run unattended.
_prompt_email() {
    # Discover how many email slots are configured.
    _ec=0
    _i=1
    while :; do
        eval "_v=\${HYFE_EMAIL_$_i:-}"
        [ -n "$_v" ] || break
        _ec=$_i
        _i=$((_i + 1))
    done
    if [ "$_ec" = 0 ]; then
        _prompt EMAIL "Email (yang akan menerima OTP)"
        EMAIL_MANUAL=1
        return 0
    fi
    while :; do
        {
            printf 'Email:\n'
            _i=1
            while [ "$_i" -le "$_ec" ]; do
                eval "_label=\$HYFE_EMAIL_$_i"
                printf '  %d) %s\n' "$_i" "$_label"
                _i=$((_i + 1))
            done
            _manual_idx=$((_ec + 1))
            printf '  %d) ketik manual\n' "$_manual_idx"
            printf 'Pilih [1]: '
        } >&2
        if ! IFS= read -r _ans; then
            printf '\nhyfetrial: input dibatalkan (EOF)\n' >&2
            exit 130
        fi
        [ -z "$_ans" ] && _ans=1
        case "$_ans" in
            ''|*[!0-9]*)
                printf '  pilihan tidak valid\n' >&2
                continue
                ;;
        esac
        if [ "$_ans" -ge 1 ] && [ "$_ans" -le "$_ec" ]; then
            eval "EMAIL=\$HYFE_EMAIL_$_ans"
            EMAIL_MANUAL=0
            # IMAP login = email address; pair the matching App Password
            # so the IMAP polling step can run unattended.
            HYFE_IMAP_USER="$EMAIL"
            export HYFE_IMAP_USER
            eval "_pass_val=\${HYFE_IMAP_PASS_$_ans:-}"
            if [ -n "$_pass_val" ]; then
                HYFE_IMAP_PASS="$_pass_val"
                export HYFE_IMAP_PASS
                log_verbose "imap: password loaded from HYFE_IMAP_PASS_$_ans"
            else
                HYFE_IMAP_PASS=""
                export HYFE_IMAP_PASS
                # Slot exists but App Password is missing. Don't fail here
                # because OTP_MODE might be `manual`, but if the user later
                # switches to imap they'll get a confusing error. Warn now.
                log_warn "HYFE_IMAP_PASS_$_ans belum di-set untuk $EMAIL"
                log_warn "kalau pakai OTP IMAP, tambahkan via menu Klaim HYFE -> opsi 8 (Edit email config)"
            fi
            return 0
        elif [ "$_ans" = "$_manual_idx" ]; then
            _prompt EMAIL "Email (yang akan menerima OTP)"
            EMAIL_MANUAL=1
            return 0
        else
            printf '  pilihan tidak valid (1..%d)\n' "$_manual_idx" >&2
        fi
    done
}

_email_matches_imap_account() {
    _slot_pass=""
    [ -n "$EMAIL" ] || return 1
    if [ -n "${HYFE_IMAP_USER:-}" ] && [ "$EMAIL" = "$HYFE_IMAP_USER" ]; then
        return 0
    fi

    _i=1
    while :; do
        eval "_slot_email=\${HYFE_EMAIL_$_i:-}"
        [ -n "$_slot_email" ] || break
        if [ "$EMAIL" = "$_slot_email" ]; then
            HYFE_IMAP_USER="$EMAIL"
            export HYFE_IMAP_USER
            eval "_slot_pass=\${HYFE_IMAP_PASS_$_i:-}"
            HYFE_IMAP_PASS="$_slot_pass"
            export HYFE_IMAP_PASS
            return 0
        fi
        _i=$((_i + 1))
    done
    return 1
}

_prompt_choice() {
    _vname="$1"; _label="$2"
    while :; do
        {
            printf '%s\n' "$_label"
            printf '  1) random\n'
            printf '  2) ketik manual\n'
            printf 'Pilih [1]: '
        } >&2
        if ! IFS= read -r _ans; then
            printf '\nhyfetrial: input dibatalkan (EOF)\n' >&2
            exit 130
        fi
        [ -z "$_ans" ] && _ans=1
        case "$_ans" in
            1|random|r|R)  eval "$_vname=random";  return 0 ;;
            2|manual|m|M)  eval "$_vname=manual";  return 0 ;;
            *) printf '  (pilihan tidak valid; ketik 1 atau 2)\n' >&2 ;;
        esac
    done
}

_prompt() {
    # _prompt VARNAME "Question text" "default" [hidden=0|1] [allow_empty=0|1]
    #
    # Notes about robustness under `set -eu`:
    #   * `stty -echo` may fail on minimal busybox setups or when stdin/tty
    #     is in an unusual state; we wrap with `|| :` so a stty failure
    #     does not silently abort the whole CLI.
    #   * `read` returns non-zero on EOF (Ctrl+D, terminal disconnect, or
    #     stdin closed). Without explicit handling that non-zero status
    #     would trigger `set -e` and exit silently mid-prompt. Instead we
    #     detect the EOF, restore echo, and exit with a clear message and
    #     SIGINT-equivalent rc=130 so the user sees what happened.
    _vname="$1"; _q="$2"; _def="${3:-}"; _hidden="${4:-0}"; _allow_empty="${5:-0}"
    while :; do
        if [ -n "$_def" ]; then
            printf '%s [%s]: ' "$_q" "$_def" >&2
        else
            printf '%s: ' "$_q" >&2
        fi
        if [ "$_hidden" = 1 ]; then
            stty -echo 2>/dev/null || :
            if ! IFS= read -r _ans; then
                stty echo 2>/dev/null || :
                printf '\nhyfetrial: input dibatalkan (EOF)\n' >&2
                exit 130
            fi
            stty echo 2>/dev/null || :
            printf '\n' >&2
        else
            if ! IFS= read -r _ans; then
                printf '\nhyfetrial: input dibatalkan (EOF)\n' >&2
                exit 130
            fi
        fi
        [ -z "$_ans" ] && _ans="$_def"
        if [ -z "$_ans" ] && [ "$_allow_empty" != 1 ]; then
            printf '  (wajib diisi)\n' >&2
            continue
        fi
        eval "$_vname=\$_ans"
        return 0
    done
}

_prompt_captcha_mode() {
    while :; do
        {
            printf 'Mode captcha:\n'
            printf '  1. manual\n'
            printf '  2. nextcaptcha\n'
            printf '  3. 2captcha\n'
            printf '  4. anticaptcha\n'
            printf '  5. capsolver\n'
        } >&2
        _prompt _ans "Pilih mode captcha" "manual"
        case "$_ans" in
            1|manual)      HYFE_CAPTCHA_MODE=manual ;;
            2|nextcaptcha) HYFE_CAPTCHA_MODE=nextcaptcha ;;
            3|2captcha)    HYFE_CAPTCHA_MODE=2captcha ;;
            4|anticaptcha) HYFE_CAPTCHA_MODE=anticaptcha ;;
            5|capsolver)   HYFE_CAPTCHA_MODE=capsolver ;;
            *)
                printf '  pilihan tidak valid: %s\n' "$_ans" >&2
                continue
                ;;
        esac
        return 0
    done
}

_prompt_otp_mode() {
    while :; do
        {
            printf 'Mau pakai OTP via IMAP atau manual?\n'
            printf '  1. imap\n'
            printf '  2. manual\n'
        } >&2
        _prompt _ans "Pilih mode OTP" "manual"
        case "$_ans" in
            1|imap)    HYFE_OTP_MODE=imap ;;
            2|manual)  HYFE_OTP_MODE=manual ;;
            *)
                printf '  pilihan tidak valid: %s\n' "$_ans" >&2
                continue
                ;;
        esac
        return 0
    done
}

# _prompt_eid - render an interactive EID prompt that knows about saved
# slots in the active config (HYFE_EID_1, HYFE_EID_2, ...).
#
# Behavior:
#   - No saved EIDs: prompt for one full EID, then offer to save it as
#     HYFE_EID_1 in the active config file.
#   - One or more saved EIDs:
#       1) ... N)  pick a saved EID directly
#       N+1)       edit the last 3 digits of a chosen saved EID
#       N+2)       edit the last 4 digits of a chosen saved EID
#       N+3)       type a brand-new full EID (with optional save)
#
# Why "last 3/4 digits"? EIDs are usually sequential within a single device
# batch, so users testing multiple eSIMs on the same phone often only need
# to vary the trailing few digits.
_prompt_eid() {
    # Discover how many EID slots are configured.
    _ec=0
    _i=1
    while :; do
        eval "_v=\${HYFE_EID_$_i:-}"
        [ -n "$_v" ] || break
        _ec=$_i
        _i=$((_i + 1))
    done

    if [ "$_ec" = 0 ]; then
        {
            printf '\nEID HARUS dari device yang akan dipakai untuk eSIM ini.\n'
            printf '  - Cek di iPhone:  Settings > General > About > EID\n'
            printf '  - Cek di Android: Settings > About phone > SIM status > EID\n'
            printf '  - Random/EID milik device lain = QR eSIM tidak bisa diaktifkan.\n\n'
        } >&2
        _prompt EID "EID eSIM (32 digit)"
        _eid_offer_save 1
        return 0
    fi

    while :; do
        {
            printf 'EID:\n'
            _i=1
            while [ "$_i" -le "$_ec" ]; do
                eval "_label=\$HYFE_EID_$_i"
                printf '  %d) %s\n' "$_i" "$_label"
                _i=$((_i + 1))
            done
            _edit3_idx=$((_ec + 1))
            _edit4_idx=$((_ec + 2))
            _manual_idx=$((_ec + 3))
            printf '  %d) edit 3 digit terakhir\n' "$_edit3_idx"
            printf '  %d) edit 4 digit terakhir\n' "$_edit4_idx"
            printf '  %d) ketik manual EID baru\n' "$_manual_idx"
            printf 'Pilih [1]: '
        } >&2
        if ! IFS= read -r _ans; then
            printf '\nhyfetrial: input dibatalkan (EOF)\n' >&2
            exit 130
        fi
        [ -z "$_ans" ] && _ans=1
        case "$_ans" in
            ''|*[!0-9]*)
                printf '  pilihan tidak valid\n' >&2
                continue
                ;;
        esac
        if [ "$_ans" -ge 1 ] && [ "$_ans" -le "$_ec" ]; then
            eval "EID=\$HYFE_EID_$_ans"
            return 0
        elif [ "$_ans" = "$_edit3_idx" ] || [ "$_ans" = "$_edit4_idx" ]; then
            if [ "$_ans" = "$_edit3_idx" ]; then
                _ndigits=3
            else
                _ndigits=4
            fi
            _slot=1
            if [ "$_ec" -gt 1 ]; then
                while :; do
                    _slot=""
                    _prompt _slot "Edit slot mana (1..$_ec)" "1" 0 0
                    case "$_slot" in
                        ''|*[!0-9]*) printf '  bukan angka\n' >&2; continue ;;
                    esac
                    if [ "$_slot" -ge 1 ] && [ "$_slot" -le "$_ec" ]; then
                        break
                    fi
                    printf '  di luar range\n' >&2
                done
            fi
            _base_eid=""
            eval "_base_eid=\$HYFE_EID_$_slot"
            _blen=${#_base_eid}
            _base_pref=$(printf '%s' "$_base_eid" | cut -c 1-$((_blen - _ndigits)))
            _base_tail=$(printf '%s' "$_base_eid" | cut -c $((_blen - _ndigits + 1))-)
            log_info "prefix tetap: $_base_pref"
            while :; do
                _new_tail=""
                _prompt _new_tail "$_ndigits digit terakhir baru" "$_base_tail"
                if [ "${#_new_tail}" -eq "$_ndigits" ] && \
                   ! printf '%s' "$_new_tail" | grep -q '[^0-9]'; then
                    break
                fi
                printf '  harus tepat %d digit angka\n' "$_ndigits" >&2
            done
            EID="${_base_pref}${_new_tail}"
            log_info "EID hasil edit: $EID"
            _new_idx=$((_ec + 1))
            _eid_offer_save "$_new_idx"
            return 0
        elif [ "$_ans" = "$_manual_idx" ]; then
            {
                printf '\nEID HARUS dari device yang akan dipakai untuk eSIM ini.\n'
                printf '  - Cek di iPhone:  Settings > General > About > EID\n'
                printf '  - Cek di Android: Settings > About phone > SIM status > EID\n'
                printf '  - Random/EID milik device lain = QR eSIM tidak bisa diaktifkan.\n\n'
            } >&2
            _prompt EID "EID eSIM (32 digit)"
            _new_idx=$((_ec + 1))
            _eid_offer_save "$_new_idx"
            return 0
        else
            printf '  pilihan tidak valid (1..%d)\n' "$_manual_idx" >&2
        fi
    done
}

# _eid_offer_save SLOT - if a config file is active and EID looks valid,
# ask the user whether to persist this EID into HYFE_EID_<SLOT>. Stays
# silent (no save, no error) when there's no config file backing the run
# (e.g. --config not set and /etc/hyfetrial/config absent).
_eid_offer_save() {
    _slot=$1
    [ -n "${CONFIG_FILE:-}" ] || return 0
    [ -f "$CONFIG_FILE" ] || return 0
    _eid_clean=$(printf '%s' "$EID" | tr -d ' :-')
    if ! printf '%s' "$_eid_clean" | grep -Eq '^[0-9]{32}$'; then
        return 0
    fi
    # Skip if this exact EID is already saved in any slot.
    _i=1
    while :; do
        eval "_v=\${HYFE_EID_$_i:-}"
        [ -n "$_v" ] || break
        if [ "$_v" = "$_eid_clean" ]; then
            return 0
        fi
        _i=$((_i + 1))
    done
    _save=""
    _prompt _save "Simpan EID ini sebagai HYFE_EID_$_slot di config? [Y/n]" "Y" 0 1
    case "$_save" in
        ''|y|Y|yes|YES)
            config_set "$CONFIG_FILE" "HYFE_EID_$_slot" "$_eid_clean"
            eval "HYFE_EID_$_slot=\$_eid_clean"
            export "HYFE_EID_$_slot"
            log_info "EID disimpan sebagai HYFE_EID_$_slot di $CONFIG_FILE"
            ;;
        *)
            log_info "EID tidak disimpan (cuma dipakai untuk run ini)"
            ;;
    esac
}

# _bootstrap_config_if_missing - first-run UX. If no config file is in
# play (neither --config FILE nor /etc/hyfetrial/config exists), offer to
# create the default config and walk the user through wizard_new_config.
# Yes -> CONFIG_FILE is set to the new path so subsequent helpers like
# _eid_offer_save can persist values into it.
# No  -> stays nil; the run still works but nothing is persisted.
_bootstrap_config_if_missing() {
    [ -z "${CONFIG_FILE:-}" ] || return 0
    _path=$(config_default_path)
    [ -f "$_path" ] && return 0
    if command -v lbox_top >/dev/null 2>&1; then
        {
            printf '\n'
            lbox_top "$SEC_ORANGE"
            lbox_text "SETUP PERTAMA" "$BOLD$WHITE" "$SEC_ORANGE"
            lbox_sep "$SEC_ORANGE"
            lbox_item "Belum ada config di:" "$WHITE" "$SEC_ORANGE"
            lbox_item "  $_path" "$BOLD$WHITE" "$SEC_ORANGE"
            lbox_item "Tanpa config, setting captcha/IMAP/email" "$DIM$WHITE" "$SEC_ORANGE"
            lbox_item "akan diminta tiap run." "$DIM$WHITE" "$SEC_ORANGE"
            lbox_bottom "$SEC_ORANGE"
        } >&2
    else
        {
            printf '=== setup pertama ===\n'
            printf 'Belum ada config di %s.\n' "$_path"
            printf 'Tanpa config, setting captcha/IMAP/email akan diminta tiap run.\n\n'
        } >&2
    fi
    _ans=""
    _prompt _ans "Buat config dan jalankan wizard setup sekarang? [Y/n]" "Y" 0 1
    case "$_ans" in
        ''|y|Y|yes|YES)
            wizard_new_config "$_path" || return 0
            CONFIG_FILE=$_path
            # Re-source the freshly written config so any values entered in
            # the wizard (captcha mode/key, imap settings, email slots) are
            # available for the rest of this run without re-asking.
            # shellcheck disable=SC1090
            . "$_path" 2>/dev/null || true
            # Re-resolve captcha key from per-provider slot now that config
            # has been (re)loaded.
            if [ -z "${HYFE_CAPTCHA_KEY:-}" ] && [ -n "${HYFE_CAPTCHA_MODE:-}" ]; then
                HYFE_CAPTCHA_KEY=$(captcha_resolve_key "$HYFE_CAPTCHA_MODE")
                export HYFE_CAPTCHA_KEY
            fi
            ;;
        *)
            log_info "lanjut tanpa menyimpan config (cuma run ini saja)"
            ;;
    esac
}

# Interactive wizard: prompts for any required input that wasn't supplied via
# CLI flag / config file. Triggered by --interactive or by absence of any
# required flag.
interactive_prompt() {
    if [ ! -t 0 ]; then
        die "interactive mode butuh terminal (stdin bukan TTY)"
    fi
    INTERACTIVE=1
    if command -v lbox_top >/dev/null 2>&1; then
        {
            printf '\n'
            lbox_top "$XL_GOLD"
            lbox_text "MODE INTERAKTIF" "$BOLD$WHITE" "$XL_GOLD"
            lbox_sep "$XL_GOLD"
            lbox_item "Tekan Enter untuk pakai nilai default" "$DIM$WHITE" "$XL_GOLD"
            lbox_item "(kalau ada)" "$DIM$WHITE" "$XL_GOLD"
            lbox_bottom "$XL_GOLD"
        } >&2
    else
        {
            printf '\n=== hyfetrial: mode interaktif ===\n'
            printf '(tekan Enter untuk pakai nilai default kalau ada)\n\n'
        } >&2
    fi
    _bootstrap_config_if_missing
    # _name_mode / _wa_mode are populated by _prompt_choice via `eval`; declare
    # them up-front so shellcheck (SC2154) recognises them as locally assigned.
    _name_mode=""
    _wa_mode=""
    if [ -z "$NAME" ]; then
        _prompt_choice _name_mode "Nama lengkap"
        if [ "$_name_mode" = "random" ]; then
            NAME=$(random_indo_name)
            log_info "nama random: $NAME"
        else
            _prompt NAME "Nama lengkap"
        fi
    fi
    if [ -z "$WHATSAPP" ]; then
        _prompt_choice _wa_mode "Nomor WhatsApp"
        if [ "$_wa_mode" = "random" ]; then
            WHATSAPP=$(random_wa_local)
            log_warn "WA random: 0$WHATSAPP - nomor ini tidak akan menerima pesan/OTP WA"
        else
            _prompt WHATSAPP "Nomor WhatsApp (tanpa +62/0)"
        fi
    fi
    if [ -z "$EMAIL" ]; then
        _prompt_email
    elif _email_matches_imap_account; then
        EMAIL_MANUAL=0
    else
        EMAIL_MANUAL=1
    fi
    [ -z "$EID" ]      && _prompt_eid
    if [ -z "$PATTERN" ] && [ -z "$PICK_MSISDN" ]; then
        _prompt PATTERN "Pola digit nomor cantik (kosongkan untuk random)" "" 0 1
    fi
    if [ "$HYFE_CAPTCHA_MODE" = "manual" ] || [ -z "${HYFE_CAPTCHA_MODE:-}" ]; then
        _prompt_captcha_mode
        case "$HYFE_CAPTCHA_MODE" in
            2captcha|anticaptcha|capsolver|nextcaptcha)
                # Re-resolve from the per-provider slot in case the user just
                # switched the active mode and a saved HYFE_CAPTCHA_KEY_<MODE>
                # is already in the environment from the loaded config.
                if [ -z "${HYFE_CAPTCHA_KEY:-}" ]; then
                    HYFE_CAPTCHA_KEY=$(captcha_resolve_key "$HYFE_CAPTCHA_MODE")
                fi
                if [ -z "${HYFE_CAPTCHA_KEY:-}" ]; then
                    _prompt HYFE_CAPTCHA_KEY "API key untuk $HYFE_CAPTCHA_MODE" "" 1
                fi
                ;;
        esac
        export HYFE_CAPTCHA_MODE HYFE_CAPTCHA_KEY
    fi
    if [ "${EMAIL_MANUAL:-0}" = 1 ]; then
        if [ "${HYFE_OTP_MODE:-manual}" = "imap" ]; then
            log_warn "email diketik manual; OTP diubah ke manual (bukan IMAP akun lama)"
        fi
        HYFE_OTP_MODE=manual
        export HYFE_OTP_MODE
    elif [ "${HYFE_OTP_MODE:-manual}" = "manual" ]; then
        _prompt_otp_mode
        if [ "$HYFE_OTP_MODE" = "imap" ]; then
            : "${HYFE_IMAP_URL:=imaps://imap.gmail.com:993}"
            _prompt HYFE_IMAP_URL  "IMAP URL"  "$HYFE_IMAP_URL"
            _prompt HYFE_IMAP_USER "IMAP user" "${HYFE_IMAP_USER:-$EMAIL}"
            [ -z "${HYFE_IMAP_PASS:-}" ] && _prompt HYFE_IMAP_PASS "IMAP pass (App Password)" "" 1
        fi
        export HYFE_OTP_MODE HYFE_IMAP_URL HYFE_IMAP_USER HYFE_IMAP_PASS
    fi
    printf '\n' >&2
}

# Auto-trigger interactive when nothing was given (and not in list/dry-help mode).
auto_interactive() {
    [ "$LIST_ONLY" = 1 ] && return 1
    [ "$INTERACTIVE" = 1 ] && return 0
    if [ -z "$NAME" ] && [ -z "$WHATSAPP" ] && [ -z "$EMAIL" ] && [ -z "$EID" ] && [ -z "$PICK_MSISDN" ]; then
        return 0
    fi
    return 1
}

confirm() {
    [ "$ASSUME_YES" = 1 ] && return 0
    # Render confirmation summary inside an L-box on stderr so it stays
    # consistent with the rest of the submenu (everything-in-boxes).
    if command -v lbox_top >/dev/null 2>&1; then
        {
            printf '\n'
            lbox_top "$XL_GOLD"
            lbox_text "KONFIRMASI - akan submit data berikut" "$BOLD$WHITE" "$XL_GOLD"
            lbox_sep "$XL_GOLD"
            lbox_kv "nama"   "$NAME"            "$XL_GOLD" "$WHITE" "$XL_GOLD"
            lbox_kv "wa"     "62$WHATSAPP"      "$XL_GOLD" "$WHITE" "$XL_GOLD"
            lbox_kv "email"  "$EMAIL"           "$XL_GOLD" "$WHITE" "$XL_GOLD"
            lbox_kv "msisdn" "$SELECTED_MSISDN" "$XL_GOLD" "$WHITE" "$XL_GOLD"
            lbox_kv "eid"    "$EID"             "$XL_GOLD" "$WHITE" "$XL_GOLD"
            lbox_bottom "$XL_GOLD"
            printf '  %b➤  Lanjut? [y/N]:%b ' "$BOLD$XL_GOLD" "$RESET"
        } >&2
    else
        {
            printf '\n'
            printf '  Akan submit data berikut:\n'
            printf '    nama   : %s\n' "$NAME"
            printf '    wa     : 62%s\n' "$WHATSAPP"
            printf '    email  : %s\n' "$EMAIL"
            printf '    msisdn : %s\n' "$SELECTED_MSISDN"
            printf '    eid    : %s\n' "$EID"
            printf '\n'
            printf '  Lanjut? [y/N] '
        } >&2
    fi
    IFS= read -r ans
    case "$ans" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

# ---------- main flow ----------

# precheck_config - sanity-check that the loaded config has all the
# pieces we need for the chosen modes. Emits warnings (not errors) so
# the user can see what's missing before the actual claim attempt makes
# them wait through OTP timeouts or captcha errors.
precheck_config() {
    if [ "${HYFE_CAPTCHA_MODE:-manual}" != "manual" ] \
       && [ -z "${HYFE_CAPTCHA_KEY:-}" ]; then
        _key_uc=$(printf '%s' "$HYFE_CAPTCHA_MODE" | tr '[:lower:]' '[:upper:]')
        log_warn "HYFE_CAPTCHA_MODE=$HYFE_CAPTCHA_MODE tapi HYFE_CAPTCHA_KEY_$_key_uc kosong"
        log_warn "captcha pasti gagal - jalankan menu Klaim HYFE -> opsi 6 (Edit captcha config)"
    fi
    if [ "${HYFE_OTP_MODE:-manual}" = "imap" ]; then
        if [ -z "${HYFE_IMAP_URL:-}" ]; then
            log_warn "HYFE_OTP_MODE=imap tapi HYFE_IMAP_URL kosong"
            log_warn "jalankan menu Klaim HYFE -> opsi 7 (Edit IMAP config) untuk isi setting IMAP"
        fi
        if [ -z "${HYFE_IMAP_USER:-}" ] && [ -z "${HYFE_EMAIL_1:-}" ]; then
            log_warn "HYFE_OTP_MODE=imap tapi belum ada email akun (HYFE_EMAIL_N kosong)"
            log_warn "jalankan menu Klaim HYFE -> opsi 8 (Edit email config) untuk daftarkan email"
        fi
        if [ -n "${HYFE_IMAP_USER:-}" ] && [ -z "${HYFE_IMAP_PASS:-}" ]; then
            log_warn "HYFE_IMAP_USER=$HYFE_IMAP_USER tapi HYFE_IMAP_PASS kosong"
            log_warn "OTP IMAP butuh App Password Gmail untuk login"
        fi
    fi
}

claim_flow() {
    validate_inputs

    precheck_config

    pick_msisdn

    confirm || die "aborted"

    log_info "step 1/3: requesting tnc opt-in"
    access_token=$(api_tnc_token) || die "tncToken failed"
    [ -n "$access_token" ] || die "tncToken returned empty"
    optin_body=$(api_tnc_optin "$EMAIL" "$access_token") || die "optIn failed"
    consent_id=$(printf '%s' "$optin_body" | jq -r '.result.data.consentId // empty')
    [ -n "$consent_id" ] || die "optIn: consentId missing"
    # The "tokentnc" header on validateAndSubmit is the Keycloak access_token
    # we obtained from /tnc/tncToken (not a field in the optIn response).
    tnc_token="$access_token"
    log_verbose "consentId=$consent_id"

    otp_capture_baseline || die "imap baseline failed"

    log_info "step 2/3: sending OTP email to $EMAIL"
    api_send_otp "$EMAIL" "$NAME" >/dev/null || die "send-otp failed"

    otp_code=$(otp_get) || die "otp not provided"
    log_verbose "otp=$otp_code"

    log_info "step 3/3: solving captcha (mode=$HYFE_CAPTCHA_MODE)"
    recap=$(captcha_solve) || die "captcha failed"
    [ -n "$recap" ] || die "captcha returned empty"

    if [ "$DRY_RUN" = 1 ]; then
        log_info "dry-run: would call validateAndSubmit"
        printf 'msisdn=%s eid=%s otp=%s recap=%.20s...\n' \
            "$SELECTED_MSISDN" "$EID" "$otp_code" "$recap"
        return 0
    fi

    log_info "submitting validateAndSubmit"
    resp=$(api_validate_submit \
        "$recap" "$otp_code" "$consent_id" \
        "$SELECTED_ENCRYPT" "$EID" \
        "$NAME" "$WHATSAPP" "$EMAIL" \
        "$tnc_token") || die "validateAndSubmit failed"
    sc=$(printf '%s' "$resp" | jq -r '.statusCode // empty')
    if [ "$sc" = "200" ]; then
        log_info "SUCCESS: eSIM trial submitted for $SELECTED_MSISDN"
        printf '%s\n' "$resp" | jq .
        return 0
    fi
    rc=$(printf '%s' "$resp" | jq -r '.result.data.result.resultCode // empty')
    rm=$(printf '%s' "$resp" | jq -r '.result.data.result.resultDesc // .statusMessage // empty')
    log_error "submit failed: statusCode=$sc resultCode=$rc resultDesc=$rm"
    printf '%s\n' "$resp" | jq . >&2 2>/dev/null || printf '%s\n' "$resp" >&2
    return 1
}

# ============================================================================
#                        BOX-STYLE UI HELPERS (esim theme)
# ============================================================================
#
# Wrapper-wrapper kecil yang bungkus output claim_flow & wizard pakai
# helper box dari esim (section_header, box_top, kv_row, dst). Dengan
# begini kita gak perlu rewrite semua log_info di api.sh / claim_flow,
# cukup panggil _hyfe_step / _hyfe_ok / _hyfe_fail di titik yg high-signal.

_hyfe_step() {
    section_header "$1" "${2:-$BCYAN}"
}

# L-mixed status / info boxes — semua output HYFE submenu lewat helper ini
# supaya konsisten box-everywhere principle (tidak ada raw printf di luar
# kotak). Border default mengikuti theme XL_GOLD untuk submenu Prioritas.

# Section header L-mixed: ╔══╗  ║ TITLE ║  ╰──╯
_hyfe_section() {
    title="$1"; color="${2:-$XL_GOLD}"
    printf '\n'
    lbox_top "$color"
    lbox_text "$title" "$BOLD$WHITE" "$color"
    lbox_bottom "$color"
}

_hyfe_ok() {
    printf '\n'
    lbox_top "$BGREEN"
    lbox_text "$1" "$BOLD$BGREEN" "$BGREEN"
    lbox_bottom "$BGREEN"
}

_hyfe_fail() {
    printf '\n'
    lbox_top "$BRED"
    lbox_text "$1" "$BOLD$BRED" "$BRED"
    lbox_bottom "$BRED"
}

_hyfe_warn() {
    printf '\n'
    lbox_top "$BYELLOW"
    lbox_text "$1" "$BOLD$BYELLOW" "$BYELLOW"
    lbox_bottom "$BYELLOW"
}

# Render multi-line message inside an L-box. Each remaining argument is one
# line (left-aligned, trimmed to box width).
_hyfe_msg_box() {
    color="$1"; title="$2"; shift 2
    printf '\n'
    lbox_top "$color"
    lbox_text "$title" "$BOLD$WHITE" "$color"
    lbox_sep "$color"
    for _line in "$@"; do
        lbox_item "$_line" "$WHITE" "$color"
    done
    lbox_bottom "$color"
}

# Key-value summary box. Args: TITLE COLOR KEY1 VAL1 KEY2 VAL2 ...
_hyfe_info_box() {
    title="$1"; shift
    color="${HYFE_INFO_COLOR:-$XL_GOLD}"
    printf '\n'
    lbox_top "$color"
    lbox_text "$title" "$BOLD$WHITE" "$color"
    lbox_sep "$color"
    while [ "$#" -ge 2 ]; do
        lbox_kv "$1" "$2" "$XL_GOLD" "$WHITE" "$color"
        shift 2
    done
    lbox_bottom "$color"
}

# Banner pembuka submenu Klaim HYFE — XL Prioritas gold + bg hitam.
_hyfe_banner() {
    if command -v hyfe_main_banner >/dev/null 2>&1; then
        hyfe_main_banner
    else
        # Fallback for standalone use without esim wrapper.
        printf '\n'
        lbox_top "$XL_GOLD"
        lbox_text "KLAIM eSIM TRIAL HYFE" "$BOLD$XL_GOLD" "$XL_GOLD"
        lbox_text "(XL Prioritas)" "$DIM$WHITE" "$XL_GOLD"
        lbox_bottom "$XL_GOLD"
    fi
}

# Banner pembuka per-action di dalam submenu.
_hyfe_action_header() {
    _hyfe_section "$1" "${2:-$XL_GOLD}"
}

# ============================================================================
#                          CONFIG-MANAGEMENT WRAPPERS
# ============================================================================

hyfe_show_config() {
    _hyfe_action_header "LIHAT CONFIG AKTIF"
    _path="${CONFIG_FILE:-$(config_default_path)}"
    if [ ! -f "$_path" ]; then
        _hyfe_fail "Config $_path belum ada"
        _hyfe_msg_box "$DIM$BCYAN" "Hint" \
            "Gunakan opsi 5 (Setup config) untuk bikin config baru." \
            "Atau opsi 6/7/8 untuk edit field tertentu."
        return 0
    fi
    _hyfe_msg_box "$DIM$BCYAN" "Source File" "$_path"
    _hyfe_show_config_sections "$_path"
}

# Render per-context section boxes for the active config. Each section uses
# a different accent color to make scanning easier:
#   • CAPTCHA   → SEC_PINK    (api keys per provider)
#   • OTP/IMAP  → SEC_SKY     (mailbox setup)
#   • EMAIL     → SEC_LIME    (multi-akun slots)
#   • EID       → SEC_LAVENDER (multi-EID slots)
#   • QUICK     → XL_GOLD     (klaim cepat preferences)
_hyfe_show_config_sections() {
    _f="$1"
    # Snapshot current shell vars before sourcing config so we don't leak
    # mutations beyond this function. We re-source the config here to read
    # raw values (config_show masks too aggressively for KEY display vs the
    # 4...4 fingerprint we want).
    _saved_mode="${HYFE_CAPTCHA_MODE:-}"
    _saved_otp="${HYFE_OTP_MODE:-}"
    # shellcheck disable=SC1090
    . "$_f" 2>/dev/null || true

    # ─── CAPTCHA section ───
    _mode="${HYFE_CAPTCHA_MODE:-(unset)}"
    _hyfe_msg_box "$SEC_PINK" "CAPTCHA" \
        "Mode aktif      : $_mode" \
        "Timeout solver  : ${HYFE_CAPTCHA_TIMEOUT:-180}s"
    # Per-provider key list, masked.
    lbox_top "$SEC_PINK"
    lbox_text "API Keys per Provider" "$BOLD$WHITE" "$SEC_PINK"
    lbox_sep "$SEC_PINK"
    for _prov in nextcaptcha 2captcha anticaptcha capsolver; do
        _kvar="HYFE_CAPTCHA_KEY_$(printf '%s' "$_prov" | tr '[:lower:]' '[:upper:]')"
        _kval=$(eval "printf '%s' \"\${$_kvar:-}\"")
        _kdisp=$(_hyfe_mask_key "$_kval")
        # Highlight active mode in green; others dim.
        if [ "$_prov" = "$_mode" ]; then
            lbox_kv "$_prov *" "$_kdisp" "$BGREEN" "$WHITE" "$SEC_PINK"
        else
            lbox_kv "$_prov" "$_kdisp" "$DIM$WHITE" "$DIM$WHITE" "$SEC_PINK"
        fi
    done
    lbox_bottom "$SEC_PINK"

    # ─── OTP / IMAP section ───
    _otp="${HYFE_OTP_MODE:-(unset)}"
    _hyfe_msg_box "$SEC_SKY" "OTP / IMAP" \
        "Mode OTP        : $_otp"
    if [ "$_otp" = "imap" ] || [ -n "${HYFE_IMAP_URL:-}" ]; then
        _ipass=$(_hyfe_mask_pass "${HYFE_IMAP_PASS:-}")
        lbox_top "$SEC_SKY"
        lbox_text "IMAP Settings" "$BOLD$WHITE" "$SEC_SKY"
        lbox_sep "$SEC_SKY"
        lbox_kv "URL"     "${HYFE_IMAP_URL:-(unset)}"     "$SEC_SKY" "$WHITE" "$SEC_SKY"
        lbox_kv "User"    "${HYFE_IMAP_USER:-(unset)}"    "$SEC_SKY" "$WHITE" "$SEC_SKY"
        lbox_kv "Pass"    "$_ipass"                       "$SEC_SKY" "$WHITE" "$SEC_SKY"
        lbox_kv "Folder"  "${HYFE_IMAP_FOLDER:-INBOX}"    "$SEC_SKY" "$WHITE" "$SEC_SKY"
        lbox_kv "Subject" "${HYFE_IMAP_SUBJECT:-(default)}" "$SEC_SKY" "$WHITE" "$SEC_SKY"
        lbox_kv "Timeout" "${HYFE_IMAP_TIMEOUT:-60}s"     "$SEC_SKY" "$WHITE" "$SEC_SKY"
        lbox_bottom "$SEC_SKY"
    fi

    # ─── EMAIL slots section ───
    _ec=$(_config_email_count "$_f")
    [ -n "$_ec" ] || _ec=0
    lbox_top "$SEC_LIME"
    lbox_text "EMAIL SLOTS ($_ec akun)" "$BOLD$WHITE" "$SEC_LIME"
    lbox_sep "$SEC_LIME"
    if [ "$_ec" -le 0 ]; then
        lbox_item "(belum ada akun email tersimpan)" "$DIM$WHITE" "$SEC_LIME"
    else
        _i=1
        while [ "$_i" -le "$_ec" ]; do
            _e=$(eval "printf '%s' \"\${HYFE_EMAIL_$_i:-}\"")
            _p=$(eval "printf '%s' \"\${HYFE_IMAP_PASS_$_i:-}\"")
            _pmask=$(_hyfe_mask_pass "$_p")
            lbox_kv "slot $_i" "$_e" "$SEC_LIME" "$WHITE" "$SEC_LIME"
            lbox_kv "  | pass" "$_pmask" "$DIM$SEC_LIME" "$DIM$WHITE" "$SEC_LIME"
            _i=$((_i + 1))
        done
    fi
    lbox_bottom "$SEC_LIME"

    # ─── EID slots section ───
    _eid_count=$(_hyfe_count_eid_slots)
    [ -n "$_eid_count" ] || _eid_count=0
    lbox_top "$SEC_LAVENDER"
    lbox_text "EID SLOTS ($_eid_count slot)" "$BOLD$WHITE" "$SEC_LAVENDER"
    lbox_sep "$SEC_LAVENDER"
    if [ "$_eid_count" -le 0 ]; then
        lbox_item "(belum ada EID tersimpan)" "$DIM$WHITE" "$SEC_LAVENDER"
    else
        _i=1
        while [ "$_i" -le "$_eid_count" ]; do
            _v=$(eval "printf '%s' \"\${HYFE_EID_$_i:-}\"")
            lbox_kv "slot $_i" "$(_hyfe_eid_mask "$_v")" "$SEC_LAVENDER" "$WHITE" "$SEC_LAVENDER"
            _i=$((_i + 1))
        done
    fi
    lbox_bottom "$SEC_LAVENDER"

    # ─── QUICK SETTINGS section ───
    if [ -n "${HYFE_QUICK_EMAIL_SLOT:-}${HYFE_QUICK_EID:-}${HYFE_QUICK_CAPTCHA_MODE:-}" ]; then
        _qslot="${HYFE_QUICK_EMAIL_SLOT:-(unset)}"
        _qemail=""
        if [ "$_qslot" != "(unset)" ]; then
            _qemail=$(eval "printf '%s' \"\${HYFE_EMAIL_$_qslot:-}\"")
        fi
        _qauto="${HYFE_QUICK_AUTO_PICK:-0}"
        if [ "$_qauto" = "1" ]; then _qauto_d="ya"; else _qauto_d="tidak"; fi
        lbox_top "$XL_GOLD"
        lbox_text "QUICK SETTINGS (Klaim Cepat)" "$BOLD$WHITE" "$XL_GOLD"
        lbox_sep "$XL_GOLD"
        lbox_kv "Email slot"   "$_qslot ${_qemail:+($_qemail)}" "$XL_GOLD" "$WHITE" "$XL_GOLD"
        lbox_kv "EID"          "$(_hyfe_eid_mask "${HYFE_QUICK_EID:-}")" "$XL_GOLD" "$WHITE" "$XL_GOLD"
        lbox_kv "Captcha mode" "${HYFE_QUICK_CAPTCHA_MODE:-(unset)}" "$XL_GOLD" "$WHITE" "$XL_GOLD"
        lbox_kv "OTP mode"     "${HYFE_QUICK_OTP_MODE:-(unset)}"     "$XL_GOLD" "$WHITE" "$XL_GOLD"
        lbox_kv "Pattern"      "${HYFE_QUICK_PATTERN:-(random)}"     "$XL_GOLD" "$WHITE" "$XL_GOLD"
        lbox_kv "Auto-pick"    "$_qauto_d"                            "$XL_GOLD" "$WHITE" "$XL_GOLD"
        lbox_bottom "$XL_GOLD"
    else
        _hyfe_msg_box "$DIM$XL_GOLD" "QUICK SETTINGS (Klaim Cepat)" \
            "(belum di-setup — jalankan opsi 3 dulu)"
    fi

    # Restore caller's mode so subsequent operations don't see config values.
    HYFE_CAPTCHA_MODE="$_saved_mode"
    HYFE_OTP_MODE="$_saved_otp"
}

# Mask helper: print first 4 + ... + last 4 of input. Empty / short strings
# are returned as-is (or "(unset)" for empty).
_hyfe_mask_key() {
    _k="$1"
    if [ -z "$_k" ]; then printf '(unset)'; return; fi
    _kl=${#_k}
    if [ "$_kl" -le 8 ]; then
        printf '%s' "$(repeat_char '*' "$_kl")"
        return
    fi
    _kh=$(printf '%s' "$_k" | cut -c 1-4)
    _kt=$(printf '%s' "$_k" | cut -c $((_kl - 3))-)
    printf '%s...%s' "$_kh" "$_kt"
}

_hyfe_mask_pass() {
    if [ -z "$1" ]; then printf '(unset)'; return; fi
    printf '********'
}

hyfe_setup_config() {
    _hyfe_action_header "SETUP CONFIG (WIZARD AWAL)"
    if [ ! -t 0 ]; then
        _hyfe_fail "Wizard butuh terminal interaktif"
        return 1
    fi
    _path="${CONFIG_FILE:-$(config_default_path)}"
    # Wrap wizard in a subshell so an EOF (Ctrl-D) inside _prompt's
    # `exit 130` only terminates the subshell, not the entire esim CLI.
    ( wizard_new_config "$_path" )
    _rc=$?
    if [ "$_rc" -ne 0 ]; then
        _hyfe_fail "Wizard dibatalkan (rc=$_rc)"
        return $_rc
    fi
    CONFIG_FILE="$_path"
    _hyfe_ensure_config
    _hyfe_ok "Config disimpan di $_path"
}

hyfe_edit_captcha_config() {
    _hyfe_action_header "EDIT CAPTCHA CONFIG"
    if [ ! -t 0 ]; then
        _hyfe_fail "Wizard butuh terminal interaktif"
        return 1
    fi
    _path="${CONFIG_FILE:-$(config_default_path)}"
    ( wizard_captcha_config "$_path" )
    _rc=$?
    if [ "$_rc" -ne 0 ]; then
        _hyfe_fail "Wizard dibatalkan (rc=$_rc)"
        return $_rc
    fi
    CONFIG_FILE="$_path"
    _hyfe_ensure_config
}

hyfe_edit_imap_config() {
    _hyfe_action_header "EDIT IMAP CONFIG"
    if [ ! -t 0 ]; then
        _hyfe_fail "Wizard butuh terminal interaktif"
        return 1
    fi
    _path="${CONFIG_FILE:-$(config_default_path)}"
    ( wizard_imap_config "$_path" )
    _rc=$?
    if [ "$_rc" -ne 0 ]; then
        _hyfe_fail "Wizard dibatalkan (rc=$_rc)"
        return $_rc
    fi
    CONFIG_FILE="$_path"
    _hyfe_ensure_config
}

hyfe_edit_email_config() {
    _hyfe_action_header "EDIT EMAIL CONFIG (MULTI-AKUN)"
    if [ ! -t 0 ]; then
        _hyfe_fail "Wizard butuh terminal interaktif"
        return 1
    fi
    _path="${CONFIG_FILE:-$(config_default_path)}"
    ( wizard_email_config "$_path" )
    _rc=$?
    if [ "$_rc" -ne 0 ]; then
        _hyfe_fail "Wizard dibatalkan (rc=$_rc)"
        return $_rc
    fi
    CONFIG_FILE="$_path"
    _hyfe_ensure_config
}

# ============================================================================
#                             LIST MSISDN MODE
# ============================================================================

hyfe_list_numbers_menu() {
    _hyfe_action_header "DAFTAR MSISDN TERSEDIA"
    if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
        _hyfe_fail "Butuh curl + jq buat fetch list dari upstream"
        return 1
    fi
    _hyfe_ensure_config
    PATTERN=""
    if [ -t 0 ]; then
        # Render the prompt inside its own L-box so even input lives inside
        # a kotak (sesuai box-everywhere principle).
        printf '\n'
        lbox_top "$SEC_TEAL"
        lbox_text "Pola Digit (filter MSISDN)" "$BOLD$WHITE" "$SEC_TEAL"
        lbox_sep "$SEC_TEAL"
        lbox_item "Kosongkan untuk random page." "$DIM$WHITE" "$SEC_TEAL"
        lbox_item "Atau ketik 1-5 digit (mis. 1122 / 55330)." "$DIM$WHITE" "$SEC_TEAL"
        lbox_bottom "$SEC_TEAL"
        while :; do
            printf '  %b➤  Pola digit:%b ' "$BOLD$SEC_TEAL" "$RESET"
            if ! IFS= read -r _patin; then
                printf '\n'
                return 0
            fi
            _patin=$(trim "$_patin" 2>/dev/null || printf '%s' "$_patin")
            case "$_patin" in
                "") PATTERN=""; break ;;
                *[!0-9]*)
                    _hyfe_warn "Pola harus digit angka saja."
                    continue
                    ;;
                *)
                    if [ "${#_patin}" -gt 5 ]; then
                        _hyfe_warn "Maksimal 5 digit (input: ${#_patin})"
                        continue
                    fi
                    PATTERN="$_patin"
                    break
                    ;;
            esac
        done
    fi
    # api_auth / api_session call die() (exit 1) on failure; wrap in a
    # subshell so a failed listing doesn't kill the entire esim CLI. Stderr
    # goes to a separate tempfile so we can surface upstream errors on
    # failure (PR#3 fix).
    _tmp="${TMPDIR:-/tmp}/hyfe_msisdn.$$.$(date +%s 2>/dev/null || printf '0')"
    _err="${_tmp}.err"
    : > "$_tmp" 2>/dev/null || _tmp="${TMPDIR:-/tmp}/hyfe_msisdn.$$"
    : > "$_err" 2>/dev/null || _err="${TMPDIR:-/tmp}/hyfe_msisdn.$$.err"
    (
        set -eu
        _hyfe_init_cookies
        trap '_hyfe_cleanup_cookies' EXIT INT TERM
        list_numbers_mode
    ) >"$_tmp" 2>"$_err"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        if [ -s "$_err" ]; then
            # Surface upstream error inside a fail box (instead of /dev/null).
            _hyfe_fail "Gagal ambil daftar MSISDN (rc=$rc)"
            lbox_top "$BRED"
            lbox_text "Upstream stderr" "$BOLD$WHITE" "$BRED"
            lbox_sep "$BRED"
            while IFS= read -r _eline; do
                [ -n "$_eline" ] && lbox_item "$_eline" "$WHITE" "$BRED"
            done <"$_err"
            lbox_bottom "$BRED"
        else
            _hyfe_fail "Gagal ambil daftar MSISDN (rc=$rc)"
        fi
        rm -f "$_tmp" "$_err" 2>/dev/null
        return $rc
    fi
    rm -f "$_err" 2>/dev/null
    _count=$(awk 'NF { n++ } END { print n + 0 }' "$_tmp" 2>/dev/null || printf '0')
    [ -n "$_count" ] || _count=0
    if [ "$_count" -le 0 ]; then
        rm -f "$_tmp" 2>/dev/null
        if [ -n "$PATTERN" ]; then
            _hyfe_warn "Tidak ada MSISDN tersedia (pola: $PATTERN)"
        else
            _hyfe_warn "Tidak ada MSISDN tersedia"
        fi
        return 0
    fi
    # ─── Render 2-column symmetric MSISDN box ───
    # Layout (BOX_WIDTH=65, cell width 31):
    #   ╔═════════════════════════════════════════════════════════════╗   (full top)
    #   ║         MSISDN TERSEDIA (10 nomor) - random page            ║   (title)
    #   ╠══════════════════════════════╦══════════════════════════════╣   (split-down)
    #   ║   1  0819-3255-3301          ║   2  0819-3255-3303          ║
    #   ║   3  0819-3255-3304          ║   4  0819-3255-3305          ║
    #   ╚══════════════════════════════╩══════════════════════════════╝   (split-up)
    if [ -n "$PATTERN" ]; then
        _title="MSISDN TERSEDIA ($_count nomor) - pola: $PATTERN"
    else
        _title="MSISDN TERSEDIA ($_count nomor) - random page"
    fi
    printf '\n'
    mbox_full_top "$BCYAN"
    mbox_title "$_title" "$BOLD$WHITE" "$BCYAN"
    mbox_title_sep "$BCYAN"
    # Read all MSISDN into positional list (POSIX sh has no arrays).
    _i=0
    _l_idx=""; _l_val=""
    while IFS= read -r _line; do
        [ -n "$_line" ] || continue
        _msisdn=$(printf '%s' "$_line" | cut -f1)
        _msisdn=$(_hyfe_normalize_msisdn "$_msisdn")
        [ -n "$_msisdn" ] || continue
        _fmt=$(_hyfe_format_msisdn "$_msisdn")
        _i=$((_i + 1))
        if [ -z "$_l_idx" ]; then
            # Buffer left cell; flush when we get the right cell.
            _l_idx="$_i"
            _l_val="$_fmt"
        else
            mbox_row "$_l_idx" "$_l_val" "$_i" "$_fmt" "$BCYAN"
            _l_idx=""; _l_val=""
        fi
    done <"$_tmp"
    # Flush trailing odd cell (right cell empty).
    if [ -n "$_l_idx" ]; then
        mbox_row "$_l_idx" "$_l_val" "" "" "$BCYAN"
    fi
    mbox_bottom "$BCYAN"
    rm -f "$_tmp" 2>/dev/null
    return 0
}

# Normalize an MSISDN to canonical leading-0 + 11-12 digit form. Strips
# the country prefix 62 if present, prepends 0 when missing.
#   "8123..."   -> "08123..."
#   "62812..."  -> "0812..."
#   "0812..."   -> "0812..."
_hyfe_normalize_msisdn() {
    _m="$1"
    case "$_m" in
        62*) _m="0${_m#62}" ;;
        0*) ;;
        8*) _m="0$_m" ;;
        *) ;;
    esac
    printf '%s' "$_m"
}

# Format a normalized MSISDN as 0xxx-xxxx-xxxx (or 0xxx-xxxx-xxx for 11-digit).
# Uses 4-4-rest grouping for symmetry; 11/12/13 digit numbers all align cleanly.
_hyfe_format_msisdn() {
    _m="$1"
    _l=${#_m}
    # Always group as first-4 / next-4 / rest. For 12-digit: 4-4-4. For
    # 11-digit: 4-4-3. For 13-digit: 4-4-5. Padded width below in mbox_row
    # handles the variable rest-length.
    if [ "$_l" -le 8 ]; then
        printf '%s' "$_m"
        return
    fi
    _a=$(printf '%s' "$_m" | cut -c 1-4)
    _b=$(printf '%s' "$_m" | cut -c 5-8)
    _c=$(printf '%s' "$_m" | cut -c 9-)
    printf '%s-%s-%s' "$_a" "$_b" "$_c"
}

# ============================================================================
#                         CLAIM-NOW (interactive full)
# ============================================================================

hyfe_claim_now() {
    _hyfe_banner
    _hyfe_action_header "KLAIM SEKARANG (INTERAKTIF)"
    if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
        _hyfe_fail "Butuh curl + jq terinstall"
        return 1
    fi
    _hyfe_reset_state
    _hyfe_ensure_config
    INTERACTIVE=1
    # Subshell + set -eu - claim_flow & helper-helpernya pakai die() yg
    # exit 1 saat error. Bungkus di subshell biar yg keluar cuma subshell-nya,
    # bukan esim itu sendiri.
    (
        set -eu
        _hyfe_init_cookies
        trap '_hyfe_cleanup_cookies' EXIT INT TERM
        _bootstrap_config_if_missing
        if auto_interactive; then
            interactive_prompt
        fi
        claim_flow
    )
    rc=$?
    if [ "$rc" -eq 0 ]; then
        _hyfe_ok "KLAIM SUKSES"
    else
        _hyfe_fail "KLAIM GAGAL (rc=$rc)"
    fi
    return $rc
}

# ============================================================================
#                         QUICK-SETUP wizard
# ============================================================================

# Helper: mask middle of an EID, leaving first 8 + last 4 visible.
_hyfe_eid_mask() {
    _e="$1"
    _len=${#_e}
    if [ "$_len" -lt 12 ]; then
        printf '%s' "$_e"
        return
    fi
    _head=$(printf '%s' "$_e" | cut -c 1-8)
    _tail=$(printf '%s' "$_e" | cut -c $((_len - 3))-)
    _mid=$(repeat_char '*' $((_len - 12)))
    printf '%s%s%s' "$_head" "$_mid" "$_tail"
}

# Helper: list saved EID slots and return count via stdout.
_hyfe_list_eid_slots() {
    _i=1
    while :; do
        _v=$(eval "printf '%s' \"\${HYFE_EID_$_i:-}\"")
        [ -n "$_v" ] || break
        printf '  %b%d)%b %s %b(slot %d)%b\n' \
            "$BOLD$BYELLOW" "$_i" "$RESET" \
            "$(_hyfe_eid_mask "$_v")" \
            "$DIM" "$_i" "$RESET"
        _i=$((_i + 1))
    done
    return $((_i - 1))
}

_hyfe_count_eid_slots() {
    _c=0
    _i=1
    while :; do
        _v=$(eval "printf '%s' \"\${HYFE_EID_$_i:-}\"")
        [ -n "$_v" ] || break
        _c=$((_c + 1))
        _i=$((_i + 1))
    done
    printf '%d' "$_c"
}

_hyfe_count_email_slots() {
    _f="${CONFIG_FILE:-$(config_default_path)}"
    if [ ! -f "$_f" ]; then
        printf '0'
        return 0
    fi
    _config_email_count "$_f"
}

# Edit last N digits of a saved EID (slot index). N must be 3 or 4.
# Echoes the resulting full EID on stdout.
_hyfe_edit_eid_tail() {
    _slot="$1"; _ndigits="$2"
    _orig=$(eval "printf '%s' \"\${HYFE_EID_$_slot:-}\"")
    if [ -z "$_orig" ]; then
        log_error "slot $_slot kosong"
        return 1
    fi
    _olen=${#_orig}
    if [ "$_olen" -lt "$((_ndigits + 4))" ]; then
        log_error "EID slot $_slot terlalu pendek ($_olen char) buat edit $_ndigits digit"
        return 1
    fi
    _prefix=$(printf '%s' "$_orig" | cut -c 1-$((_olen - _ndigits)))
    # All UI output goes to stderr - this function is consumed via
    # command substitution `$(_hyfe_edit_eid_tail ...)` so anything on
    # stdout becomes part of the captured EID value. Only the final
    # `printf '%s%s'` at the bottom is intentionally stdout.
    printf '\n  %bPrefix tetap:%b  %s%b%s%b\n' \
        "$BOLD$BCYAN" "$RESET" "$_prefix" "$DIM" \
        "$(repeat_char 'X' "$_ndigits")" "$RESET" >&2
    while :; do
        printf '  %b%d digit terakhir baru:%b ' \
            "$BOLD$BYELLOW" "$_ndigits" "$RESET" >&2
        read -r _tail
        _tail=$(trim "$_tail" 2>/dev/null || printf '%s' "$_tail")
        case "$_tail" in
            *[!0-9]*|"")
                printf '  %b! Harus tepat %d digit angka.%b\n' \
                    "$BRED" "$_ndigits" "$RESET" >&2
                continue
                ;;
        esac
        if [ "${#_tail}" -ne "$_ndigits" ]; then
            printf '  %b! Panjang harus tepat %d digit (input: %d).%b\n' \
                "$BRED" "$_ndigits" "${#_tail}" "$RESET" >&2
            continue
        fi
        break
    done
    printf '%s%s' "$_prefix" "$_tail"
}

hyfe_quick_setup() {
    _hyfe_banner
    _hyfe_action_header "SETUP KLAIM CEPAT"
    if [ ! -t 0 ]; then
        _hyfe_fail "Wizard butuh terminal interaktif"
        return 1
    fi
    _hyfe_ensure_config
    _path="${CONFIG_FILE:-$(config_default_path)}"
    config_ensure "$_path"

    # ---- Step 1: pilih email default (SEC_LIME) ----
    _hyfe_section "Email default" "$SEC_LIME"
    _ec=$(_hyfe_count_email_slots)
    if [ "$_ec" -lt 1 ]; then
        _hyfe_fail "Belum ada email tersimpan. Jalankan opsi 8 (Edit email) dulu."
        return 1
    fi
    lbox_top "$SEC_LIME"
    lbox_text "Pilih slot email" "$BOLD$WHITE" "$SEC_LIME"
    lbox_sep "$SEC_LIME"
    _i=1
    while [ "$_i" -le "$_ec" ]; do
        _e=$(eval "printf '%s' \"\${HYFE_EMAIL_$_i:-}\"")
        lbox_kv "$_i)" "$_e (slot $_i)" "$BOLD$XL_GOLD_LIGHT" "$WHITE" "$SEC_LIME"
        _i=$((_i + 1))
    done
    lbox_bottom "$SEC_LIME"
    _q_email_slot=""
    while :; do
        printf '  %b➤  Pilih slot email [1-%d]:%b ' \
            "$BOLD$SEC_LIME" "$_ec" "$RESET"
        if ! IFS= read -r _ans; then
            _hyfe_fail "Input dibatalkan (EOF). Setup Klaim Cepat dibatalkan."
            return 1
        fi
        case "$_ans" in
            ''|*[!0-9]*) _hyfe_warn "Pilih angka 1-$_ec"; continue ;;
        esac
        if [ "$_ans" -ge 1 ] && [ "$_ans" -le "$_ec" ]; then
            _q_email_slot="$_ans"
            break
        fi
        _hyfe_warn "Slot di luar rentang. Pilih 1-$_ec"
    done

    # ---- Step 2: pilih EID default (SEC_LAVENDER, with edit-tail option) ----
    _hyfe_section "EID default" "$SEC_LAVENDER"
    _ec_eid=$(_hyfe_count_eid_slots)
    if [ "$_ec_eid" -lt 1 ]; then
        _hyfe_fail "Belum ada EID tersimpan. Jalankan opsi 5 (Setup config) dulu."
        return 1
    fi
    _opt3=$((_ec_eid + 1))
    _opt4=$((_ec_eid + 2))
    _q_eid=""
    while [ -z "$_q_eid" ]; do
        # Redraw the EID menu every iteration so the user always sees the
        # available options (e.g. after declining to save an edited EID).
        lbox_top "$SEC_LAVENDER"
        lbox_text "Pilih EID" "$BOLD$WHITE" "$SEC_LAVENDER"
        lbox_sep "$SEC_LAVENDER"
        _i=1
        while [ "$_i" -le "$_ec_eid" ]; do
            _v=$(eval "printf '%s' \"\${HYFE_EID_$_i:-}\"")
            lbox_kv "$_i)" "$(_hyfe_eid_mask "$_v") (slot $_i)" \
                "$BOLD$XL_GOLD_LIGHT" "$WHITE" "$SEC_LAVENDER"
            _i=$((_i + 1))
        done
        lbox_kv "$_opt3)" "edit 3 digit terakhir slot tertentu" \
            "$BOLD$XL_GOLD_LIGHT" "$DIM$WHITE" "$SEC_LAVENDER"
        lbox_kv "$_opt4)" "edit 4 digit terakhir slot tertentu" \
            "$BOLD$XL_GOLD_LIGHT" "$DIM$WHITE" "$SEC_LAVENDER"
        lbox_bottom "$SEC_LAVENDER"
        printf '  %b➤  Pilih:%b ' "$BOLD$SEC_LAVENDER" "$RESET"
        if ! IFS= read -r _ans; then
            _hyfe_fail "Input dibatalkan (EOF). Setup Klaim Cepat dibatalkan."
            return 1
        fi
        case "$_ans" in
            ''|*[!0-9]*) _hyfe_warn "Pilih angka 1-$_opt4"; continue ;;
        esac
        if [ "$_ans" -ge 1 ] && [ "$_ans" -le "$_ec_eid" ]; then
            _q_eid=$(eval "printf '%s' \"\${HYFE_EID_$_ans:-}\"")
            continue
        fi
        if [ "$_ans" -eq "$_opt3" ] || [ "$_ans" -eq "$_opt4" ]; then
            if [ "$_ans" -eq "$_opt3" ]; then _ndig=3; else _ndig=4; fi
            _slot=""
            while [ -z "$_slot" ]; do
                printf '  %b➤  Edit dari slot mana? [1-%d]:%b ' \
                    "$BOLD$SEC_LAVENDER" "$_ec_eid" "$RESET"
                if ! IFS= read -r _sa; then
                    _hyfe_fail "Input dibatalkan (EOF)."
                    return 1
                fi
                case "$_sa" in ''|*[!0-9]*) continue ;; esac
                if [ "$_sa" -ge 1 ] && [ "$_sa" -le "$_ec_eid" ]; then
                    _slot="$_sa"
                fi
            done
            _new=$(_hyfe_edit_eid_tail "$_slot" "$_ndig") || { printf '\n'; continue; }
            _hyfe_msg_box "$BGREEN" "EID Hasil Edit" \
                "$(_hyfe_eid_mask "$_new")"
            printf '  %b➤  Simpan ke HYFE_QUICK_EID? [Y/n]:%b ' \
                "$BOLD$BGREEN" "$RESET"
            if ! IFS= read -r _yn; then
                _hyfe_fail "Input dibatalkan (EOF)."
                return 1
            fi
            case "$_yn" in
                [nN]*) printf '\n' ;;
                *) _q_eid="$_new" ;;
            esac
            continue
        fi
        _hyfe_warn "Pilihan tidak dikenal: $_ans"
    done

    # ---- Step 3: captcha mode (SEC_PINK) ----
    _hyfe_section "Mode captcha" "$SEC_PINK"
    lbox_top "$SEC_PINK"
    lbox_text "Pilih provider captcha" "$BOLD$WHITE" "$SEC_PINK"
    lbox_sep "$SEC_PINK"
    lbox_kv "1)" "manual"      "$BOLD$XL_GOLD_LIGHT" "$WHITE" "$SEC_PINK"
    lbox_kv "2)" "nextcaptcha" "$BOLD$XL_GOLD_LIGHT" "$WHITE" "$SEC_PINK"
    lbox_kv "3)" "2captcha"    "$BOLD$XL_GOLD_LIGHT" "$WHITE" "$SEC_PINK"
    lbox_kv "4)" "anticaptcha" "$BOLD$XL_GOLD_LIGHT" "$WHITE" "$SEC_PINK"
    lbox_kv "5)" "capsolver"   "$BOLD$XL_GOLD_LIGHT" "$WHITE" "$SEC_PINK"
    lbox_bottom "$SEC_PINK"
    _q_cap=""
    while :; do
        printf '  %b➤  Pilih [1-5]:%b ' "$BOLD$SEC_PINK" "$RESET"
        if ! IFS= read -r _ans; then
            _hyfe_fail "Input dibatalkan (EOF). Setup Klaim Cepat dibatalkan."
            return 1
        fi
        case "$_ans" in
            1) _q_cap="manual"; break ;;
            2) _q_cap="nextcaptcha"; break ;;
            3) _q_cap="2captcha"; break ;;
            4) _q_cap="anticaptcha"; break ;;
            5) _q_cap="capsolver"; break ;;
            *) _hyfe_warn "Pilih angka 1-5" ;;
        esac
    done

    # ---- Step 4: OTP mode (SEC_SKY) ----
    _hyfe_section "Mode OTP" "$SEC_SKY"
    lbox_top "$SEC_SKY"
    lbox_text "Pilih cara baca OTP" "$BOLD$WHITE" "$SEC_SKY"
    lbox_sep "$SEC_SKY"
    lbox_kv "1)" "imap (otomatis baca dari mailbox)" \
        "$BOLD$XL_GOLD_LIGHT" "$WHITE" "$SEC_SKY"
    lbox_kv "2)" "manual (paste OTP saat diminta)" \
        "$BOLD$XL_GOLD_LIGHT" "$WHITE" "$SEC_SKY"
    lbox_bottom "$SEC_SKY"
    _q_otp=""
    while :; do
        printf '  %b➤  Pilih [1-2]:%b ' "$BOLD$SEC_SKY" "$RESET"
        if ! IFS= read -r _ans; then
            _hyfe_fail "Input dibatalkan (EOF). Setup Klaim Cepat dibatalkan."
            return 1
        fi
        case "$_ans" in
            1) _q_otp="imap"; break ;;
            2) _q_otp="manual"; break ;;
            *) _hyfe_warn "Pilih 1 atau 2" ;;
        esac
    done

    # ---- Step 5: pattern (SEC_TEAL) ----
    _hyfe_section "Pola digit MSISDN" "$SEC_TEAL"
    lbox_top "$SEC_TEAL"
    lbox_text "Pola Digit (opsional)" "$BOLD$WHITE" "$SEC_TEAL"
    lbox_sep "$SEC_TEAL"
    lbox_item "Kosongkan untuk random page." "$DIM$WHITE" "$SEC_TEAL"
    lbox_item "Atau ketik 1-5 digit (mis. 1122)." "$DIM$WHITE" "$SEC_TEAL"
    lbox_bottom "$SEC_TEAL"
    _q_pat=""
    while :; do
        printf '  %b➤  Pola digit:%b ' "$BOLD$SEC_TEAL" "$RESET"
        if ! IFS= read -r _q_pat; then
            _hyfe_fail "Input dibatalkan (EOF). Setup Klaim Cepat dibatalkan."
            return 1
        fi
        _q_pat=$(trim "$_q_pat" 2>/dev/null || printf '%s' "$_q_pat")
        case "$_q_pat" in
            "") break ;;
            *[!0-9]*) _hyfe_warn "Pola harus digit angka saja"; continue ;;
            *)
                if [ "${#_q_pat}" -gt 5 ]; then
                    _hyfe_warn "Maksimal 5 digit (input: ${#_q_pat})"
                    continue
                fi
                break
                ;;
        esac
    done

    # ---- Step 6: auto-pick MSISDN (SEC_PURPLE) ----
    _hyfe_section "Auto-pick MSISDN?" "$SEC_PURPLE"
    lbox_top "$SEC_PURPLE"
    lbox_text "Pilih perilaku auto-pick" "$BOLD$WHITE" "$SEC_PURPLE"
    lbox_sep "$SEC_PURPLE"
    lbox_kv "1)" "ya (truly unattended)" \
        "$BOLD$XL_GOLD_LIGHT" "$WHITE" "$SEC_PURPLE"
    lbox_kv "2)" "tidak (tetap pilih dari list)" \
        "$BOLD$XL_GOLD_LIGHT" "$WHITE" "$SEC_PURPLE"
    lbox_bottom "$SEC_PURPLE"
    _q_auto=""
    while :; do
        printf '  %b➤  Pilih [1-2]:%b ' "$BOLD$SEC_PURPLE" "$RESET"
        if ! IFS= read -r _ans; then
            _hyfe_fail "Input dibatalkan (EOF). Setup Klaim Cepat dibatalkan."
            return 1
        fi
        case "$_ans" in
            1) _q_auto="1"; break ;;
            2) _q_auto="0"; break ;;
            *) _hyfe_warn "Pilih 1 atau 2" ;;
        esac
    done

    # ---- Persist to config ----
    config_set "$_path" HYFE_QUICK_EMAIL_SLOT "$_q_email_slot"
    config_set "$_path" HYFE_QUICK_EID         "$_q_eid"
    config_set "$_path" HYFE_QUICK_CAPTCHA_MODE "$_q_cap"
    config_set "$_path" HYFE_QUICK_OTP_MODE     "$_q_otp"
    config_set "$_path" HYFE_QUICK_PATTERN      "$_q_pat"
    config_set "$_path" HYFE_QUICK_AUTO_PICK    "$_q_auto"

    _q_email=$(eval "printf '%s' \"\${HYFE_EMAIL_$_q_email_slot:-}\"")

    # ---- Show summary box ----
    _hyfe_info_box "SETUP KLAIM CEPAT TERSIMPAN" \
        "Email"     "$_q_email (slot $_q_email_slot)" \
        "EID"       "$(_hyfe_eid_mask "$_q_eid")" \
        "Captcha"   "$_q_cap" \
        "OTP"       "$_q_otp" \
        "Pattern"   "${_q_pat:-(random)}" \
        "Auto-pick" "$([ "$_q_auto" = "1" ] && echo "ya" || echo "tidak")"
    _hyfe_ok "Pengaturan disimpan ke $_path"
}

# ============================================================================
#                         QUICK-CLAIM runner
# ============================================================================

hyfe_quick_claim() {
    _hyfe_banner
    _hyfe_action_header "KLAIM CEPAT"
    if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
        _hyfe_fail "Butuh curl + jq terinstall"
        return 1
    fi
    _hyfe_reset_state
    _hyfe_ensure_config

    # ---- Validate quick-setup keys ----
    _miss=""
    [ -n "${HYFE_QUICK_EMAIL_SLOT:-}" ] || _miss="$_miss HYFE_QUICK_EMAIL_SLOT"
    [ -n "${HYFE_QUICK_EID:-}" ]         || _miss="$_miss HYFE_QUICK_EID"
    [ -n "${HYFE_QUICK_CAPTCHA_MODE:-}" ] || _miss="$_miss HYFE_QUICK_CAPTCHA_MODE"
    [ -n "${HYFE_QUICK_OTP_MODE:-}" ]     || _miss="$_miss HYFE_QUICK_OTP_MODE"
    if [ -n "$_miss" ]; then
        _hyfe_fail "Setup Klaim Cepat belum lengkap"
        _hyfe_msg_box "$BRED" "Field belum di-set" \
            "Missing:$_miss" \
            "Jalankan opsi 3 (Setup Klaim Cepat) dulu."
        return 1
    fi

    # ---- Auto-resolve from config ----
    _slot="$HYFE_QUICK_EMAIL_SLOT"
    EMAIL=$(eval "printf '%s' \"\${HYFE_EMAIL_$_slot:-}\"")
    EID="$HYFE_QUICK_EID"
    PATTERN="${HYFE_QUICK_PATTERN:-}"
    NAME=$(random_indo_name)
    WHATSAPP=$(random_wa_local)
    # Override-mode handling: HYFE_CAPTCHA_KEY and HYFE_IMAP_USER/PASS sudah
    # di-reset oleh _hyfe_reset_state, tapi _hyfe_ensure_config mungkin sudah
    # me-resolve key untuk mode lama (HYFE_CAPTCHA_MODE dari config). Karena
    # HYFE_QUICK_CAPTCHA_MODE bisa beda dari HYFE_CAPTCHA_MODE config, paksa
    # re-resolve dengan kosongkan HYFE_CAPTCHA_KEY supaya pre-check di bawah
    # benar-benar mengambil key dari mode baru.
    HYFE_CAPTCHA_MODE="$HYFE_QUICK_CAPTCHA_MODE"
    HYFE_OTP_MODE="$HYFE_QUICK_OTP_MODE"
    HYFE_CAPTCHA_KEY=""
    export HYFE_CAPTCHA_KEY
    # Resolve IMAP creds dari slot kalau OTP_MODE=imap
    if [ "$HYFE_OTP_MODE" = "imap" ]; then
        _ipass=$(eval "printf '%s' \"\${HYFE_IMAP_PASS_$_slot:-}\"")
        if [ -n "$_ipass" ]; then
            HYFE_IMAP_USER="$EMAIL"
            HYFE_IMAP_PASS="$_ipass"
            export HYFE_IMAP_USER HYFE_IMAP_PASS
        fi
    fi
    ASSUME_YES=1
    # Honor HYFE_QUICK_AUTO_PICK: when 0, user wants to manually pick the
    # MSISDN from the list (everything else still auto-resolved). When 1,
    # claim_flow goes fully unattended and pick_msisdn picks the first
    # available number via its non-interactive else branch.
    if [ "${HYFE_QUICK_AUTO_PICK:-0}" = "1" ]; then
        INTERACTIVE=0
    else
        INTERACTIVE=1
    fi

    # ---- Pre-check captcha key for non-manual modes ----
    if [ "$HYFE_CAPTCHA_MODE" != "manual" ]; then
        if [ -z "${HYFE_CAPTCHA_KEY:-}" ]; then
            HYFE_CAPTCHA_KEY=$(captcha_resolve_key "$HYFE_CAPTCHA_MODE" 2>/dev/null || true)
            [ -n "$HYFE_CAPTCHA_KEY" ] && export HYFE_CAPTCHA_KEY
        fi
        if [ -z "${HYFE_CAPTCHA_KEY:-}" ]; then
            _hyfe_fail "API key captcha untuk mode '$HYFE_CAPTCHA_MODE' kosong"
            _hyfe_msg_box "$BRED" "Hint" \
                "Jalankan opsi 6 (Edit captcha config) untuk set key."
            return 1
        fi
    fi
    # ---- Pre-check IMAP for imap mode ----
    if [ "$HYFE_OTP_MODE" = "imap" ]; then
        if [ -z "${HYFE_IMAP_USER:-}" ] || [ -z "${HYFE_IMAP_PASS:-}" ]; then
            _hyfe_fail "IMAP user/password belum di-set buat slot $_slot"
            _hyfe_msg_box "$BRED" "Hint" \
                "Jalankan opsi 8 (Edit email config) untuk set App Password."
            return 1
        fi
    fi

    # ---- Show pre-flight summary ----
    _hyfe_info_box "KLAIM CEPAT — PRE-FLIGHT" \
        "Nama"     "$NAME (random)" \
        "WA"       "0$WHATSAPP (random)" \
        "Email"    "$EMAIL (slot $_slot)" \
        "EID"      "$(_hyfe_eid_mask "$EID")" \
        "Captcha"  "$HYFE_CAPTCHA_MODE" \
        "OTP"      "$HYFE_OTP_MODE" \
        "Pattern"  "${PATTERN:-(random)}" \
        "Auto-pick" "$([ "${HYFE_QUICK_AUTO_PICK:-0}" = "1" ] && echo "ya" || echo "tidak")"

    # ---- Run claim flow in subshell ----
    # AUTO_PICK=1 -> INTERACTIVE=0 -> pick_msisdn falls into the else branch
    # (lib/hyfe.sh:214) which auto-picks the first available number.
    # AUTO_PICK=0 -> INTERACTIVE=1 -> pick_msisdn calls _prompt_msisdn_choice
    # for an explicit picker prompt.
    (
        set -eu
        _hyfe_init_cookies
        trap '_hyfe_cleanup_cookies' EXIT INT TERM
        claim_flow
    )
    rc=$?
    if [ "$rc" -eq 0 ]; then
        _hyfe_ok "KLAIM CEPAT SUKSES"
    else
        _hyfe_fail "KLAIM CEPAT GAGAL (rc=$rc)"
    fi
    return $rc
}

# ============================================================================
#                          MENU DISPATCHER (entry point)
# ============================================================================

# Render the Klaim HYFE submenu (10 opsi) and dispatch to the chosen action.
# Loops until user picks "0" (Kembali ke main menu).
hyfe_menu() {
    while :; do
        clear_screen
        _hyfe_banner
        # ─── Menu box (L-mixed gold border + section group separators) ───
        lbox_top "$XL_GOLD"
        # Group 1: Klaim
        lbox_text "── Klaim ──" "$BOLD$XL_GOLD_LIGHT" "$XL_GOLD"
        _hyfe_menu_item "1" "Klaim sekarang (interaktif penuh)" "$XL_GOLD"
        _hyfe_menu_item "2" "Lihat daftar MSISDN"               "$XL_GOLD"
        lbox_sep "$XL_GOLD"
        # Group 2: Klaim Cepat
        lbox_text "── Klaim Cepat ──" "$BOLD$SEC_TEAL" "$XL_GOLD"
        _hyfe_menu_item "3" "Setup Klaim Cepat"                 "$XL_GOLD" "$SEC_TEAL"
        _hyfe_menu_item "4" "Klaim Cepat (pakai setup di atas)" "$XL_GOLD" "$SEC_TEAL"
        lbox_sep "$XL_GOLD"
        # Group 3: Config
        lbox_text "── Config ──" "$BOLD$SEC_LAVENDER" "$XL_GOLD"
        _hyfe_menu_item "5" "Setup config (wizard awal full)"    "$XL_GOLD" "$SEC_LAVENDER"
        _hyfe_menu_item "6" "Edit captcha config"                "$XL_GOLD" "$SEC_PINK"
        _hyfe_menu_item "7" "Edit IMAP config"                   "$XL_GOLD" "$SEC_SKY"
        _hyfe_menu_item "8" "Edit email config (multi-akun)"     "$XL_GOLD" "$SEC_LIME"
        _hyfe_menu_item "9" "Lihat config aktif"                 "$XL_GOLD" "$WHITE"
        lbox_sep "$XL_GOLD"
        _hyfe_menu_item "0" "Kembali ke main menu" "$XL_GOLD" "$DIM$BRED"
        lbox_bottom "$XL_GOLD"

        printf '\n  %b➤  Pilih opsi:%b ' "$BOLD$XL_GOLD" "$RESET"
        if ! IFS= read -r _opt; then
            # EOF (Ctrl-D) - return to esim main menu instead of spinning.
            printf '\n'
            return 0
        fi
        case "$_opt" in
            1) hyfe_claim_now           ; pause ;;
            2) hyfe_list_numbers_menu   ; pause ;;
            3) hyfe_quick_setup         ; pause ;;
            4) hyfe_quick_claim         ; pause ;;
            5) hyfe_setup_config        ; pause ;;
            6) hyfe_edit_captcha_config ; pause ;;
            7) hyfe_edit_imap_config    ; pause ;;
            8) hyfe_edit_email_config   ; pause ;;
            9) hyfe_show_config         ; pause ;;
            0) return 0 ;;
            *) _hyfe_warn "Pilihan tidak dikenal: $_opt"; pause ;;
        esac
    done
}

# Render a single menu item row inside the gold L-box: ║  N)  Label  ║
# Args: NUM LABEL [BORDER_COLOR] [LABEL_COLOR]
# Visible width = 65 chars (matches BOX_WIDTH):
#   ║(1) + 2sp + N(1) + )(1) + 2sp + LABEL(55) + 2sp + ║(1) = 65
_hyfe_menu_item() {
    _n="$1"; _l="$2"
    _bc="${3:-$XL_GOLD}"
    _lc="${4:-$WHITE}"
    _l="$(trim_text "$_l" 55)"
    printf '%b║%b  %b%s)%b  %b%-55s%b  %b║%b\n' \
        "$_bc" "$RESET" \
        "$BOLD$XL_GOLD_LIGHT" "$_n" "$RESET" \
        "$_lc" "$_l" "$RESET" \
        "$_bc" "$RESET"
}
