# shellcheck shell=sh
# api.sh - upstream HTTP wrappers for the HYFE eSIM Trial flow.
#
# All requests use the cookie jar at $HYFE_COOKIES and include the headers
# expected by the prioritas.xl.co.id frontend (Origin/Referer/User-Agent
# plus Authorization/X-CSRF-Token where applicable).

# Build common header arguments shared by every request.
_api_headers_common() {
    printf -- '-H\nUser-Agent: %s\n' "$HYFE_UA"
    printf -- '-H\nOrigin: %s\n' "$HYFE_ORIGIN"
    printf -- '-H\nReferer: %s\n' "$HYFE_REFERER"
    printf -- '-H\nAccept: application/json, text/plain, */*\n'
    printf -- '-H\nAccept-Language: en-US,en;q=0.9\n'
}

# Internal: do an HTTP request with curl. Reads array-style headers from
# stdin (separated by lf, two lines per header: "-H" then "Header: value").
# Args: <method> <url> [body]
_api_request() {
    method="$1"
    url="$2"
    body="${3:-}"

    # Build a curl command via positional args (POSIX sh doesn't have arrays).
    set -- \
        --silent --show-error \
        --connect-timeout 15 \
        --max-time 60 \
        --cookie-jar "$HYFE_COOKIES" \
        --cookie "$HYFE_COOKIES" \
        -X "$method" \
        "$url"

    # Append headers from stdin (pairs of lines: "-H" then header).
    while IFS= read -r flag && IFS= read -r value; do
        [ -n "$flag" ] || continue
        set -- "$@" "$flag" "$value"
    done

    if [ -n "$body" ]; then
        set -- "$@" --data-raw "$body"
    fi

    log_debug "curl $method $url"
    [ -n "$body" ] && log_debug "  body: $body"

    out=$(curl "$@" 2>&1)
    rc=$?
    if [ $rc -ne 0 ]; then
        log_error "curl failed (exit=$rc) for $method $url"
        log_error "$out"
        return $rc
    fi
    printf '%s' "$out"
}

# POST /hyfe-apply/api/auth on prioritas.xl.co.id - sets the "token" cookie.
api_auth() {
    log_verbose "auth: requesting token cookie"
    body=$(
        {
            _api_headers_common
            printf -- '-H\nContent-Type: application/json\n'
            printf -- '-H\nCache-Control: no-store\n'
            printf -- '-H\nPragma: no-cache\n'
        } | _api_request POST "$HYFE_AUTH_URL" '{}'
    ) || return 1
    log_debug "auth response: $body"
    HYFE_TOKEN=$(cookie_get token)
    [ -n "$HYFE_TOKEN" ] || die "auth: token cookie not set"
    export HYFE_TOKEN
    log_verbose "auth: token acquired (${#HYFE_TOKEN} bytes)"
}

# GET /hyfe/v1/session - returns CSRF token.
api_session() {
    log_verbose "session: fetching csrfToken"
    body=$(
        {
            _api_headers_common
            printf -- '-H\nAuthorization: Bearer %s\n' "$HYFE_TOKEN"
            printf -- '-H\nCache-Control: no-store, no-cache, must-revalidate\n'
            printf -- '-H\nPragma: no-cache\n'
            printf -- '-H\nExpires: 0\n'
        } | _api_request GET "$HYFE_BASE/hyfe/v1/session"
    ) || return 1
    assert_status_ok "session" "$body" || return 1
    HYFE_CSRF=$(printf '%s' "$body" | jq -r '.result.csrfToken // empty')
    [ -n "$HYFE_CSRF" ] || die "session: csrfToken missing"
    export HYFE_CSRF
    log_verbose "session: csrfToken acquired"
}

# POST /hyfe/v1/msisdn/findResources?page=<url_page>
# The upstream uses TWO different page parameters:
#   - url query  ?page=...   pagination index (1..totalPageMsisdn)
#   - body field "pageNo"    inventory bucket seed (5..500)
# Args: <url_page> <body_page_no> [pattern]
# Echoes JSON body.
api_find_msisdn() {
    url_page="$1"
    body_page="$2"
    pattern="${3:-}"
    rid=$(gen_uuid)
    payload=$(jq -nc \
        --arg pat "$pattern" \
        --argjson page "$body_page" \
        '{
            prefixNiceNumber:"6281",
            pattern:$pat,
            minPrice:"0",
            maxPrice:"0",
            count:"1",
            channel:"webprio",
            otp:"",
            operatorId:"webuser-thread01",
            pageNo:$page,
            pageSize:40,
            suggestion:false
        }')
    log_verbose "msisdn: searching url_page=$url_page body_pageNo=$body_page pattern='$pattern'"
    body=$(
        {
            _api_headers_common
            printf -- '-H\nAuthorization: Bearer %s\n' "$HYFE_TOKEN"
            printf -- '-H\nX-CSRF-Token: %s\n' "$HYFE_CSRF"
            printf -- '-H\nContent-Type: application/json\n'
            printf -- '-H\nrequestid: %s\n' "$rid"
        } | _api_request POST "$HYFE_BASE/hyfe/v1/msisdn/findResources?page=$url_page" "$payload"
    ) || return 1
    sc=$(printf '%s' "$body" | jq -r '.statusCode // empty' 2>/dev/null)
    err=$(printf '%s' "$body" | jq -r '.result.errorCode // empty' 2>/dev/null)
    # 404 + errorCode 10 = "Data Not Found" - return a synthesised empty body
    # so callers can treat it like a regular zero-result response.
    if [ "$sc" = "404" ] && [ "$err" = "10" ]; then
        log_verbose "findResources: no match for pattern='$pattern'"
        printf '{"statusCode":200,"result":{"errorCode":"00","data":{"noMsisdn":[],"totalmsisdn":0,"totalPageMsisdn":0}}}'
        return 0
    fi
    assert_status_ok "findResources" "$body" || return 1
    printf '%s' "$body"
}

# POST /comet/v1/tnc/tncToken - returns Keycloak access_token.
api_tnc_token() {
    rid=$(gen_uuid)
    log_verbose "tnc: requesting access_token"
    body=$(
        {
            _api_headers_common
            printf -- '-H\nAuthorization: Bearer %s\n' "$HYFE_TOKEN"
            printf -- '-H\nX-CSRF-Token: %s\n' "$HYFE_CSRF"
            printf -- '-H\nContent-Type: application/json\n'
            printf -- '-H\nrequestid: %s\n' "$rid"
        } | _api_request POST "$HYFE_BASE/comet/v1/tnc/tncToken" ''
    ) || return 1
    assert_status_ok "tncToken" "$body" || return 1
    printf '%s' "$body" | jq -r '.result.data.access_token // empty'
}

# POST /comet/v1/tnc/optIn - returns body with consentId.
# Note: the Keycloak access_token is sent as a *raw* Authorization header
# (no "Bearer " prefix) - matching what the upstream web app does. Sending
# it with the Bearer prefix triggers a server-side 500.
# Args: <email> <access_token>
api_tnc_optin() {
    email="$1"
    access_token="$2"
    rid=$(gen_uuid)
    payload=$(jq -nc \
        --arg email "$email" \
        --arg ch "$HYFE_TNC_CHANNEL_ID" \
        '{type:"email", channelId:$ch, msisdn:$email, status:2}')
    log_verbose "tnc: opt-in for $email"
    body=$(
        {
            _api_headers_common
            printf -- '-H\nAuthorization: %s\n' "$access_token"
            printf -- '-H\nX-CSRF-Token: %s\n' "$HYFE_CSRF"
            printf -- '-H\nContent-Type: application/json\n'
            printf -- '-H\nrequestid: %s\n' "$rid"
        } | _api_request POST "$HYFE_BASE/comet/v1/tnc/optIn" "$payload"
    ) || return 1
    assert_status_ok "optIn" "$body" || return 1
    printf '%s' "$body"
}

# POST /hyfe/v1/esim/freeTrial/send-otp - email a 6-digit OTP.
# Args: <email> <full-name>
api_send_otp() {
    email="$1"
    name="$2"
    rid=$(gen_uuid)
    payload=$(jq -nc \
        --arg email "$email" \
        --arg name "$name" \
        '{email:$email, name:$name, title:"Kode OTP | eSIM Trial HYFE"}')
    log_verbose "send-otp: $email"
    body=$(
        {
            _api_headers_common
            printf -- '-H\nAuthorization: Bearer %s\n' "$HYFE_TOKEN"
            printf -- '-H\nX-CSRF-Token: %s\n' "$HYFE_CSRF"
            printf -- '-H\nContent-Type: application/json\n'
            printf -- '-H\nrequestid: %s\n' "$rid"
        } | _api_request POST "$HYFE_BASE/hyfe/v1/esim/freeTrial/send-otp" "$payload"
    ) || return 1
    assert_status_ok "send-otp" "$body" || return 1
    printf '%s' "$body"
}

# POST /hyfe/v1/esim/freeTrial/validateAndSubmit
# Args:
#   1: recaptcha token
#   2: otp code (6 chars)
#   3: consent id
#   4: msisdn encrypt
#   5: eid (32 digits)
#   6: full name
#   7: whatsapp (without country code, e.g. 81234567890)
#   8: email
#   9: tnc token (header tokentnc)
api_validate_submit() {
    rid=$(gen_uuid)
    payload=$(jq -nc \
        --arg token "$1" \
        --arg otp "$2" \
        --arg cid "$3" \
        --arg ms "$4" \
        --arg eid "$5" \
        --arg fn "$6" \
        --arg wa "$7" \
        --arg em "$8" \
        '{
            token:$token,
            otpCode:($otp | ascii_upcase),
            consentId:$cid,
            msisdn:$ms,
            eid:$eid,
            channel:"EVENT",
            customerInfo: {
                title:"Sdr.",
                firstName:$fn,
                middleName:"",
                lastName:"",
                contactNumber:("62" + $wa),
                email:$em
            }
        }')
    log_verbose "validateAndSubmit"
    log_debug "payload: $payload"
    body=$(
        {
            _api_headers_common
            printf -- '-H\nAuthorization: Bearer %s\n' "$HYFE_TOKEN"
            printf -- '-H\nX-CSRF-Token: %s\n' "$HYFE_CSRF"
            printf -- '-H\nContent-Type: application/json\n'
            printf -- '-H\nrequestid: %s\n' "$rid"
            printf -- '-H\ntokentnc: %s\n' "$9"
        } | _api_request POST "$HYFE_BASE/hyfe/v1/esim/freeTrial/validateAndSubmit" "$payload"
    ) || return 1
    log_debug "submit response: $body"
    printf '%s' "$body"
}
