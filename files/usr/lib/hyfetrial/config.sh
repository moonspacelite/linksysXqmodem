# shellcheck shell=sh
# config.sh - hyfetrial config-file management helpers and wizards.
#
# Provides:
#   config_default_path       - default config file location
#   sh_quote VALUE            - escape VALUE for safe shell sourcing
#   config_set FILE KEY VALUE - update or append `KEY=...` line in FILE
#   config_unset FILE KEY     - remove `KEY=...` lines from FILE
#   config_show FILE          - print FILE with passwords masked
#   wizard_captcha_config FILE
#   wizard_imap_config FILE
#   wizard_email_config FILE
#   wizard_new_config FILE
#
# Shared assumptions:
#   - common.sh is sourced first (provides log_info, _prompt, etc.)
#   - hyfetrial top-level provides _prompt, _prompt_choice
#   - All wizards prompt interactively and require a TTY.

config_default_path() {
    printf '%s' "${HYFE_DEFAULT_CONFIG:-/etc/hyfetrial/config}"
}

# sh_quote VALUE - wrap VALUE in double quotes, escaping characters that
# would otherwise be interpreted by the shell when the file is sourced
# (`"`, `\`, `$`, backtick). Output is always double-quoted.
sh_quote() {
    _v=$1
    # shellcheck disable=SC2016 # all sed expressions are intentionally literal
    _v=$(printf '%s' "$_v" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\$/\\$/g' -e 's/`/\\`/g')
    printf '"%s"' "$_v"
}

# config_ensure FILE - make sure the parent directory exists and the file
# is writable; create an empty file if needed.
config_ensure() {
    _f=$1
    _d=$(dirname -- "$_f")
    if [ ! -d "$_d" ]; then
        mkdir -p "$_d" 2>/dev/null \
            || { log_error "config: cannot mkdir $_d"; return 1; }
    fi
    if [ ! -e "$_f" ]; then
        : > "$_f" 2>/dev/null \
            || { log_error "config: cannot create $_f"; return 1; }
        chmod 600 "$_f" 2>/dev/null || :
    fi
    [ -w "$_f" ] || { log_error "config: $_f not writable"; return 1; }
    return 0
}

# config_set FILE KEY VALUE - replace or append a `KEY="VALUE"` assignment
# in FILE. The value is always double-quoted via sh_quote so that values
# with spaces / specials roundtrip correctly when the file is sourced.
config_set() {
    _f=$1; _k=$2; _v=$3
    config_ensure "$_f" || return 1
    _quoted=$(sh_quote "$_v")
    if grep -q "^${_k}=" "$_f" 2>/dev/null; then
        _tmp="${_f}.tmp.$$"
        # Pass the already-shell-quoted value via the environment instead of
        # `awk -v`. `-v` applies C-style escape processing (\" -> ", \\ -> \,
        # \n -> newline) which would undo sh_quote's escaping and produce
        # an unsourceable config. ENVIRON[] returns the raw bytes.
        _CONFIG_SET_VALUE="$_quoted" \
        awk -v k="$_k" '
            BEGIN { v=ENVIRON["_CONFIG_SET_VALUE"]; pat="^"k"=" }
            $0 ~ pat && !replaced { print k"="v; replaced=1; next }
            { print }
            END { if (!replaced) print k"="v }
        ' "$_f" > "$_tmp" && mv -- "$_tmp" "$_f"
        unset _CONFIG_SET_VALUE
    else
        # Make sure file ends with a newline before appending.
        if [ -s "$_f" ]; then
            _last=$(tail -c1 "$_f" 2>/dev/null | od -An -c 2>/dev/null | tr -d ' ')
            case "$_last" in
                '\n'|'\\n'|'') ;;
                *) printf '\n' >> "$_f" ;;
            esac
        fi
        printf '%s=%s\n' "$_k" "$_quoted" >> "$_f"
    fi
}

# config_unset FILE KEY - remove all lines matching `KEY=` from FILE.
config_unset() {
    _f=$1; _k=$2
    [ -f "$_f" ] || return 0
    _tmp="${_f}.tmp.$$"
    awk -v k="$_k" 'BEGIN{pat="^"k"="} $0 !~ pat {print}' "$_f" > "$_tmp" \
        && mv -- "$_tmp" "$_f"
}

# config_get FILE KEY - print the unquoted value of KEY, or empty if unset.
# Uses a subshell so the file is sourced without polluting the caller env.
config_get() {
    _f=$1; _k=$2
    [ -f "$_f" ] || return 0
    (
        # shellcheck disable=SC1090
        . "$_f" 2>/dev/null || true
        eval "_v=\${$_k:-}"
        printf '%s' "$_v"
    )
}

# config_show FILE - print FILE to stdout with sensitive values masked.
# Lines matching *PASS* are fully masked; *KEY* values keep first/last 4
# characters so the user can sanity-check which key is in place.
config_show() {
    _f=$1
    if [ ! -f "$_f" ]; then
        printf 'hyfetrial: config %s tidak ada\n' "$_f" >&2
        return 1
    fi
    printf '# Source: %s\n' "$_f"
    awk '
        function strip_quotes(s,    r) {
            r=s
            sub(/^"/, "", r); sub(/"$/, "", r)
            sub(/^'\''/, "", r); sub(/'\''$/, "", r)
            return r
        }
        /^[[:space:]]*#/ { print; next }
        /^[[:space:]]*$/ { print; next }
        {
            n=index($0, "=")
            if (n == 0) { print; next }
            k=substr($0, 1, n-1)
            v=substr($0, n+1)
            if (k ~ /PASS/) {
                print k "=********"
                next
            }
            if (k ~ /KEY/) {
                raw=strip_quotes(v)
                L=length(raw)
                if (L > 8) {
                    masked=substr(raw,1,4) "..." substr(raw,L-3,4)
                } else if (L > 0) {
                    masked="********"
                } else {
                    masked=""
                }
                print k "=" masked
                next
            }
            print
        }
    ' "$_f"
}

# _config_email_count FILE - print the highest contiguous N for which
# HYFE_EMAIL_N is set in FILE. Stops at the first gap.
_config_email_count() {
    _f=$1
    [ -f "$_f" ] || { printf '0'; return 0; }
    _i=1
    _n=0
    while :; do
        _v=$(config_get "$_f" "HYFE_EMAIL_$_i")
        [ -n "$_v" ] || break
        _n=$_i
        _i=$((_i + 1))
    done
    printf '%s' "$_n"
}

# _captcha_mode_uc MODE - print MODE in uppercase (e.g. nextcaptcha -> NEXTCAPTCHA).
# Used to derive HYFE_CAPTCHA_KEY_<MODE> variable names.
_captcha_mode_uc() {
    printf '%s' "$1" | tr '[:lower:]' '[:upper:]'
}

# captcha_resolve_key MODE - print the per-provider key for MODE, falling back
# to the legacy HYFE_CAPTCHA_KEY if the per-provider slot is empty. Reads from
# the current shell environment (which has typically been seeded by sourcing
# the config file). Returns empty string if no key is configured.
captcha_resolve_key() {
    _mode=$1
    if [ -z "$_mode" ] || [ "$_mode" = "manual" ]; then
        printf ''
        return 0
    fi
    _uc=$(_captcha_mode_uc "$_mode")
    eval "_v=\${HYFE_CAPTCHA_KEY_$_uc:-}"
    if [ -z "$_v" ]; then
        # Fallback to legacy single-slot key for back-compat with old configs.
        _v=${HYFE_CAPTCHA_KEY:-}
    fi
    printf '%s' "$_v"
}

# wizard_captcha_config FILE - update HYFE_CAPTCHA_MODE + per-provider
# HYFE_CAPTCHA_KEY_<MODE> + HYFE_CAPTCHA_TIMEOUT in FILE.
# Pressing Enter at any prompt keeps the current value.
#
# Each captcha provider (nextcaptcha, 2captcha, anticaptcha, capsolver) has
# its own key slot, so switching providers does not erase keys for the
# others. A legacy `HYFE_CAPTCHA_KEY=...` (without suffix) is auto-migrated
# into the slot for the currently-selected provider on first edit.
wizard_captcha_config() {
    _f=$1
    config_ensure "$_f" || return 1
    {
        printf '\n=== hyfetrial: captcha config (%s) ===\n' "$_f"
        printf '(Enter = pertahankan nilai sekarang)\n\n'
    } >&2

    _cur_mode=$(config_get "$_f" HYFE_CAPTCHA_MODE)
    [ -n "$_cur_mode" ] || _cur_mode=manual
    while :; do
        {
            printf 'Mode captcha:\n'
            printf '  1. manual\n'
            printf '  2. nextcaptcha\n'
            printf '  3. 2captcha\n'
            printf '  4. anticaptcha\n'
            printf '  5. capsolver\n'
        } >&2
        _ans=""
        _prompt _ans "Pilih mode captcha" "$_cur_mode"
        case "$_ans" in
            1|manual)      _new_mode=manual ;;
            2|nextcaptcha) _new_mode=nextcaptcha ;;
            3|2captcha)    _new_mode=2captcha ;;
            4|anticaptcha) _new_mode=anticaptcha ;;
            5|capsolver)   _new_mode=capsolver ;;
            *)
                printf '  pilihan tidak valid: %s\n' "$_ans" >&2
                continue
                ;;
        esac
        break
    done
    config_set "$_f" HYFE_CAPTCHA_MODE "$_new_mode"

    if [ "$_new_mode" != "manual" ]; then
        _uc=$(_captcha_mode_uc "$_new_mode")
        _key_var="HYFE_CAPTCHA_KEY_$_uc"
        _cur_key=$(config_get "$_f" "$_key_var")
        # Legacy migration: if no per-mode key but a bare HYFE_CAPTCHA_KEY
        # exists, assume it belonged to whatever provider the user had
        # active and auto-migrate it into the per-mode slot.
        if [ -z "$_cur_key" ]; then
            _legacy_key=$(config_get "$_f" HYFE_CAPTCHA_KEY)
            if [ -n "$_legacy_key" ]; then
                log_info "migrasi key lama HYFE_CAPTCHA_KEY -> $_key_var"
                config_set "$_f" "$_key_var" "$_legacy_key"
                config_unset "$_f" HYFE_CAPTCHA_KEY
                _cur_key=$_legacy_key
            fi
        fi
        if [ -n "$_cur_key" ]; then
            _key_pref=$(printf '%s' "$_cur_key" | awk '{print substr($0,1,4)}')
            _key_suf=$(printf '%s'  "$_cur_key" | awk '{print substr($0,length($0)-3,4)}')
            log_info "API key $_new_mode sekarang: ${_key_pref}...${_key_suf}"
            _prompt _new_key "API key baru untuk $_new_mode (Enter = tidak diubah)" "" 1 1
        else
            _prompt _new_key "API key untuk $_new_mode" "" 1
        fi
        if [ -n "$_new_key" ]; then
            config_set "$_f" "$_key_var" "$_new_key"
        fi
        _check_key=$(config_get "$_f" "$_key_var")
        if [ -z "$_check_key" ]; then
            log_warn "$_key_var belum diisi - mode '$_new_mode' butuh API key"
            log_warn "jalankan menu Klaim HYFE -> opsi 6 (Edit captcha config) lagi untuk isi API key"
        fi
    fi
    # Switching back to manual: leave per-provider keys intact so the user
    # can switch back later without re-pasting.

    _cur_to=$(config_get "$_f" HYFE_CAPTCHA_TIMEOUT)
    [ -n "$_cur_to" ] || _cur_to=180
    _prompt _new_to "Captcha timeout (detik)" "$_cur_to" 0 1
    if [ -n "$_new_to" ]; then
        config_set "$_f" HYFE_CAPTCHA_TIMEOUT "$_new_to"
    fi

    log_info "captcha config tersimpan di $_f"
}

# wizard_imap_config FILE - update IMAP fields in FILE. Sets HYFE_OTP_MODE=imap.
wizard_imap_config() {
    _f=$1
    config_ensure "$_f" || return 1
    {
        printf '\n=== hyfetrial: imap config (%s) ===\n' "$_f"
        printf '(Enter = pertahankan nilai sekarang)\n\n'
    } >&2

    config_set "$_f" HYFE_OTP_MODE imap

    _new_url=""
    _new_folder=""
    _new_subj=""
    _cur_url=$(config_get "$_f" HYFE_IMAP_URL)
    [ -n "$_cur_url" ] || _cur_url="imaps://imap.gmail.com:993"
    _prompt _new_url "IMAP URL" "$_cur_url"
    config_set "$_f" HYFE_IMAP_URL "$_new_url"

    _cur_folder=$(config_get "$_f" HYFE_IMAP_FOLDER)
    [ -n "$_cur_folder" ] || _cur_folder="INBOX"
    _prompt _new_folder "IMAP folder" "$_cur_folder"
    config_set "$_f" HYFE_IMAP_FOLDER "$_new_folder"

    _cur_subj=$(config_get "$_f" HYFE_IMAP_SUBJECT)
    [ -n "$_cur_subj" ] || _cur_subj="Kode OTP | eSIM Trial HYFE"
    _prompt _new_subj "IMAP subject filter" "$_cur_subj"
    config_set "$_f" HYFE_IMAP_SUBJECT "$_new_subj"

    _cur_to=$(config_get "$_f" HYFE_IMAP_TIMEOUT)
    [ -n "$_cur_to" ] || _cur_to="180"
    _prompt _new_to "IMAP polling timeout (detik)" "$_cur_to" 0 1
    if [ -n "$_new_to" ]; then
        config_set "$_f" HYFE_IMAP_TIMEOUT "$_new_to"
    fi

    log_info "imap config tersimpan di $_f"

    # Pakai IMAP tanpa email akun = nanti gagal di OTP polling. Warn jelas.
    _emails_n=$(_config_email_count "$_f")
    _has_legacy_user=$(config_get "$_f" HYFE_IMAP_USER)
    if [ "$_emails_n" = 0 ] && [ -z "$_has_legacy_user" ]; then
        log_warn "belum ada email akun terdaftar (HYFE_EMAIL_N kosong)"
        log_warn "OTP IMAP butuh login Gmail - jalankan menu Klaim HYFE -> opsi 8 (Edit email config)"
    else
        log_info "tip: menu Klaim HYFE -> opsi 8 (Edit email config) untuk tambah email + App Password"
    fi
}

# wizard_email_config FILE - manage HYFE_EMAIL_N + HYFE_IMAP_PASS_N entries.
wizard_email_config() {
    _f=$1
    config_ensure "$_f" || return 1
    while :; do
        {
            printf '\n=== hyfetrial: email accounts (%s) ===\n' "$_f"
        } >&2
        _n=$(_config_email_count "$_f")
        if [ "$_n" -gt 0 ]; then
            _i=1
            while [ "$_i" -le "$_n" ]; do
                _e=$(config_get "$_f" "HYFE_EMAIL_$_i")
                _p=$(config_get "$_f" "HYFE_IMAP_PASS_$_i")
                if [ -n "$_p" ]; then
                    _p_disp="********"
                else
                    _p_disp="(belum di-set)"
                fi
                printf '  %d) %s   pass: %s\n' "$_i" "$_e" "$_p_disp" >&2
                _i=$((_i + 1))
            done
        else
            printf '  (belum ada akun email terdaftar)\n' >&2
        fi
        {
            printf '\nAksi:\n'
            printf '  a) tambah email baru\n'
            printf '  e) edit email N\n'
            printf '  d) hapus email N\n'
            printf '  q) selesai\n'
        } >&2
        _act=""
        _prompt _act "Pilih aksi" "q"
        case "$_act" in
            a|A)
                _new_idx=$((_n + 1))
                _e=""
                _p=""
                _prompt _e "Email akun ke-$_new_idx (mis. saya@gmail.com)"
                # App Password optional so user dapat menyimpan akun dulu
                # dan mengisi password belakangan via 'e/edit' (kita warn
                # eksplisit di bawah kalau dilewat).
                _prompt _p "App Password Gmail untuk $_e (kosongkan = isi nanti)" "" 1 1
                config_set "$_f" "HYFE_EMAIL_$_new_idx" "$_e"
                if [ -n "$_p" ]; then
                    config_set "$_f" "HYFE_IMAP_PASS_$_new_idx" "$_p"
                else
                    log_warn "App Password kosong - akun ini tidak bisa dipakai untuk OTP IMAP otomatis"
                    log_warn "isi nanti via menu Klaim HYFE -> opsi 8 (Edit email config) -> e) edit"
                fi
                log_info "email $_e disimpan sebagai HYFE_EMAIL_$_new_idx"
                ;;
            e|E)
                [ "$_n" -gt 0 ] || { printf '  belum ada email\n' >&2; continue; }
                _idx=""
                _e=""
                _p=""
                _prompt _idx "Index email yang mau diedit (1..$_n)"
                if ! printf '%s' "$_idx" | grep -Eq '^[0-9]+$' \
                   || [ "$_idx" -lt 1 ] || [ "$_idx" -gt "$_n" ]; then
                    printf '  index tidak valid\n' >&2
                    continue
                fi
                _cur_e=$(config_get "$_f" "HYFE_EMAIL_$_idx")
                _prompt _e "Email" "$_cur_e"
                _prompt _p "App Password baru (kosongkan = tidak diubah)" "" 1 1
                config_set "$_f" "HYFE_EMAIL_$_idx" "$_e"
                if [ -n "$_p" ]; then
                    config_set "$_f" "HYFE_IMAP_PASS_$_idx" "$_p"
                fi
                _check_p=$(config_get "$_f" "HYFE_IMAP_PASS_$_idx")
                if [ -z "$_check_p" ]; then
                    log_warn "App Password untuk akun $_idx masih kosong"
                fi
                log_info "email index $_idx diperbarui"
                ;;
            d|D)
                [ "$_n" -gt 0 ] || { printf '  belum ada email\n' >&2; continue; }
                _idx=""
                _prompt _idx "Index email yang mau dihapus (1..$_n)"
                if ! printf '%s' "$_idx" | grep -Eq '^[0-9]+$' \
                   || [ "$_idx" -lt 1 ] || [ "$_idx" -gt "$_n" ]; then
                    printf '  index tidak valid\n' >&2
                    continue
                fi
                # Shift later entries down so the list stays contiguous.
                _i="$_idx"
                while [ "$_i" -lt "$_n" ]; do
                    _next=$((_i + 1))
                    _ne=$(config_get "$_f" "HYFE_EMAIL_$_next")
                    _np=$(config_get "$_f" "HYFE_IMAP_PASS_$_next")
                    config_set "$_f" "HYFE_EMAIL_$_i" "$_ne"
                    if [ -n "$_np" ]; then
                        config_set "$_f" "HYFE_IMAP_PASS_$_i" "$_np"
                    else
                        config_unset "$_f" "HYFE_IMAP_PASS_$_i"
                    fi
                    _i=$_next
                done
                config_unset "$_f" "HYFE_EMAIL_$_n"
                config_unset "$_f" "HYFE_IMAP_PASS_$_n"
                log_info "email index $_idx dihapus"
                ;;
            q|Q|"")
                return 0
                ;;
            *)
                printf '  aksi tidak valid: %s\n' "$_act" >&2
                ;;
        esac
    done
}

# wizard_new_config FILE - first-time setup. Walks through captcha, imap, and
# email wizards in sequence so the user has one flow to set up everything.
wizard_new_config() {
    _f=$1
    {
        printf '\n=== hyfetrial: new config wizard (%s) ===\n' "$_f"
        printf 'Akan membuat / memperbarui config secara bertahap.\n'
        printf 'Tekan Enter di tiap prompt untuk pertahankan nilai sekarang.\n'
    } >&2
    wizard_captcha_config "$_f" || return 1
    wizard_imap_config "$_f" || return 1
    wizard_email_config "$_f" || return 1
    log_info "config selesai disimpan di $_f"
    log_info "verifikasi: menu Klaim HYFE -> opsi 9 (Lihat config aktif)"
}
