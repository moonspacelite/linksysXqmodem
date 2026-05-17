# shellcheck shell=sh
# otp.sh - obtain the OTP code emailed by HYFE.
#
# Modes:
#   manual  - prompt the user to type the code (default)
#   imap    - poll an IMAP mailbox via curl, scrape the OTP code from
#             the most recent matching message.
#
# Required env for IMAP mode:
#   HYFE_IMAP_URL   - e.g. imaps://imap.gmail.com:993
#   HYFE_IMAP_USER  - mailbox login
#   HYFE_IMAP_PASS  - mailbox password / app password
#   HYFE_IMAP_FOLDER (optional, default INBOX)
#   HYFE_IMAP_SUBJECT (optional, default "Kode OTP | eSIM Trial HYFE")
#   HYFE_IMAP_TIMEOUT (optional, default 120)
#
# Usage:
#   otp_capture_baseline >/dev/null 2>&1 || true   # optional, IMAP only
#   code=$(otp_get) || exit 1

: "${HYFE_OTP_MODE:=manual}"
: "${HYFE_IMAP_FOLDER:=INBOX}"
: "${HYFE_IMAP_SUBJECT:=Kode OTP | eSIM Trial HYFE}"
: "${HYFE_IMAP_TIMEOUT:=180}"

otp_get() {
    case "$HYFE_OTP_MODE" in
        manual) _otp_manual ;;
        imap)   _otp_imap ;;
        *)      log_error "unknown otp mode: $HYFE_OTP_MODE"; return 1 ;;
    esac
}

otp_capture_baseline() {
    case "$HYFE_OTP_MODE" in
        imap) _otp_imap_capture_baseline ;;
        *)    return 0 ;;
    esac
}

_otp_manual() {
    {
        printf '\n'
        printf '  Cek email Anda untuk kode OTP dari HYFE.\n'
        printf '  Subject: "%s"\n' "$HYFE_IMAP_SUBJECT"
        printf '\n'
        printf '  Masukkan kode OTP, lalu Enter:\n'
    } >&2
    printf '> ' >&2
    IFS= read -r code
    code=$(trim "$code")
    [ -n "$code" ] || { log_error "no OTP entered"; return 1; }
    printf '%s' "$code"
}

# Poll an IMAP mailbox via curl. The OTP email currently contains a 6-char
# code (historically digits-only, now alphanumeric like UWHQZT). We grep the
# first likely token from the latest matching message.
_otp_imap_common_prep() {
    [ -n "${HYFE_IMAP_URL:-}" ]  || { log_error "imap: HYFE_IMAP_URL required"; return 1; }
    [ -n "${HYFE_IMAP_USER:-}" ] || { log_error "imap: HYFE_IMAP_USER required"; return 1; }
    [ -n "${HYFE_IMAP_PASS:-}" ] || { log_error "imap: HYFE_IMAP_PASS required"; return 1; }
    imap_proto=${HYFE_IMAP_URL%%://*}
    case "$imap_proto" in
        imap|imaps) ;;
        *) log_error "imap: HYFE_IMAP_URL must start with imap:// or imaps://"; return 1 ;;
    esac
    curl_protocols=$(curl -V 2>/dev/null | awk '/^Protocols:/{sub(/^Protocols:[[:space:]]*/, ""); print}')
    case " $curl_protocols " in
        *" $imap_proto "*) ;;
        *) log_error "imap: installed curl does not support $imap_proto (OpenWrt: build curl/libcurl with CONFIG_LIBCURL_IMAP=y)"; return 1 ;;
    esac

    base="$HYFE_IMAP_URL"
    folder=$(printf '%s' "$HYFE_IMAP_FOLDER" | sed 's/ /%20/g')
    auth_user="$HYFE_IMAP_USER"
    auth_pass="$HYFE_IMAP_PASS"
}

_otp_imap_err_line() {
    err_file="$1"
    if [ -s "$err_file" ]; then
        tr '\n' ' ' <"$err_file" | sed 's/[[:space:]]*$//'
    fi
}

_otp_imap_search_all_uids() {
    err_file="${TMPDIR:-/tmp}/hyfetrial-imap-search-err.$$"
    if search_resp=$(curl -sS --max-time 30 \
            --user "$auth_user:$auth_pass" \
            --request "UID SEARCH ALL" \
            "$base/$folder" 2>"$err_file"); then
        rm -f "$err_file"
        printf '%s' "$search_resp"
        return 0
    else
        rc=$?
        err=$(_otp_imap_err_line "$err_file")
        rm -f "$err_file"
        if [ -n "$err" ]; then
            log_warn "imap: UID SEARCH failed (curl exit $rc): $err"
        else
            log_warn "imap: UID SEARCH failed (curl exit $rc)"
        fi
        return 1
    fi
}

_otp_imap_latest_uid() {
    search_resp=$(_otp_imap_search_all_uids) || return 1
    printf '%s' "$search_resp" \
        | awk '/\* SEARCH/{for (i=3;i<=NF;i++) { gsub(/[^0-9]/, "", $i); if ($i != "") last=$i }} END{print last+0}'
}

_otp_imap_fetch_uid() {
    uid="$1"
    err_file="${TMPDIR:-/tmp}/hyfetrial-imap-fetch-err.$$"
    if body=$(curl -sS --max-time 30 \
            --user "$auth_user:$auth_pass" \
            --url "$base/$folder;UID=$uid" 2>"$err_file"); then
        rm -f "$err_file"
        printf '%s' "$body"
        return 0
    else
        rc=$?
        err=$(_otp_imap_err_line "$err_file")
        rm -f "$err_file"
        if [ -n "$err" ]; then
            log_warn "imap: UID FETCH $uid failed (curl exit $rc): $err"
        else
            log_warn "imap: UID FETCH $uid failed (curl exit $rc)"
        fi
        return 1
    fi
}

_otp_message_matches() {
    raw="$1"
    printf '%s' "$raw" | awk -v subj="$HYFE_IMAP_SUBJECT" '
        BEGIN { needle=tolower(subj) }
        { if (index(tolower($0), needle) > 0) { found=1; exit } }
        END { exit(found ? 0 : 1) }
    '
}

_otp_imap_capture_baseline() {
    _otp_imap_common_prep || return 1
    HYFE_IMAP_BASELINE_UID=$(_otp_imap_latest_uid) || return 1
    [ -n "$HYFE_IMAP_BASELINE_UID" ] || HYFE_IMAP_BASELINE_UID=0
    export HYFE_IMAP_BASELINE_UID
    log_verbose "imap: baseline max uid=$HYFE_IMAP_BASELINE_UID"
}

_otp_imap() {
    _otp_imap_common_prep || return 1

    log_info "imap: polling $HYFE_IMAP_URL/$HYFE_IMAP_FOLDER for OTP (timeout ${HYFE_IMAP_TIMEOUT}s)"
    elapsed=0

    baseline_max_uid=${HYFE_IMAP_BASELINE_UID:-}
    if [ -z "$baseline_max_uid" ]; then
        baseline_max_uid=$(_otp_imap_latest_uid)
        [ -n "$baseline_max_uid" ] || baseline_max_uid=0
        log_verbose "imap: baseline max uid=$baseline_max_uid (captured at poll start)"
    else
        log_verbose "imap: baseline max uid=$baseline_max_uid"
    fi

    while [ "$elapsed" -lt "$HYFE_IMAP_TIMEOUT" ]; do
        # Curl fetches `;UID=...` with UID FETCH, so the search must also
        # return UIDs rather than mailbox sequence numbers.
        if ! search_resp=$(_otp_imap_search_all_uids); then
            sleep 5
            elapsed=$((elapsed + 5))
            continue
        fi
        ids=$(printf '%s' "$search_resp" \
            | awk -v min_uid="$baseline_max_uid" '/\* SEARCH/{for (i=3;i<=NF;i++) { gsub(/[^0-9]/, "", $i); if (($i+0) > min_uid) print $i+0 }}')
        if [ -n "$ids" ]; then
            recent_ids=$(printf '%s\n' "$ids" \
                | tail -n 15 \
                | awk '{a[NR]=$0} END{for (i=NR;i>=1;i--) print a[i]}')
            for uid in $recent_ids; do
                log_verbose "imap: candidate uid=$uid"
                body=$(_otp_imap_fetch_uid "$uid") || continue
                if [ -n "$body" ]; then
                    if ! _otp_message_matches "$body"; then
                        log_verbose "imap: uid=$uid skipped (subject mismatch)"
                        continue
                    fi
                    code=$(_otp_extract "$body")
                    if [ -n "$code" ]; then
                        log_info "imap: extracted OTP code"
                        printf '%s' "$code"
                        return 0
                    fi
                    log_verbose "imap: uid=$uid fetched but OTP token not matched"
                fi
            done
        else
            log_verbose "imap: no new mailbox UIDs yet"
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    log_error "imap: timeout, no new matching email with subject '$HYFE_IMAP_SUBJECT'"
    return 1
}

# Extract a HYFE OTP from raw RFC822 message text. Keep this parser portable:
# BusyBox grep on OpenWrt is much pickier than GNU grep, so avoid regex tokens
# like \b and case-folded negated classes that behave differently across impls.
# We prefer candidates that appear shortly after OTP-related keywords, then fall
# back to any standalone 6-char uppercase/digit token.
_otp_extract() {
    if [ "$#" -gt 0 ]; then
        raw="$1"
    else
        raw=$(cat)
    fi
    # Drop headers before decoding body content; MIME encoded headers can look
    # like quoted-printable soft line breaks.
    text=$(printf '%s' "$raw" \
        | tr -d '\r' \
        | awk 'body { print } /^$/ { body=1 }' \
        | awk '{ if (substr($0, length($0), 1) == "=") printf "%s", substr($0, 1, length($0) - 1); else print }' \
        | sed -e 's/=0D//g' -e 's/=0A/\n/g' -e 's/=3D/=/g' -e 's/=20/ /g' -e 's/=2E/./g' -e 's/=C2=A0/ /g' -e 's/<[^>]*>/ /g')

    code=$(printf '%s' "$text" | awk '
        function is_candidate(tok) {
            if (length(tok) != 6) return 0
            if (tok !~ /^[[:alnum:]][[:alnum:]][[:alnum:]][[:alnum:]][[:alnum:]][[:alnum:]]$/) return 0
            if (tok ~ /[0-9]/) return tok == toupper(tok)
            return tok == toupper(tok)
        }
        {
            gsub(/[^[:alnum:]]+/, " ")
            for (i = 1; i <= NF; i++) {
                raw_tok = $i
                stream[++n] = toupper(raw_tok)
                raw_stream[n] = raw_tok
                if (fallback == "" && is_candidate(raw_tok)) fallback = toupper(raw_tok)
            }
        }
        END {
            for (i = 1; i <= n; i++) {
                if (stream[i] == "OTP" || stream[i] == "KODE" || stream[i] == "CODE") {
                    for (j = i + 1; j <= n && j <= i + 60; j++) {
                        if (is_candidate(raw_stream[j])) {
                            print stream[j]
                            exit
                        }
                    }
                }
            }
            if (fallback != "") print fallback
        }
    ')
    [ -n "$code" ] && { printf '%s' "$code"; return 0; }

    return 1
}
