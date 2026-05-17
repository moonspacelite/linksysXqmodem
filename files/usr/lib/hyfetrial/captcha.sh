# shellcheck shell=sh
# captcha.sh - solve / obtain a reCAPTCHA Enterprise token.
#
# Modes:
#   manual        - print the page URL and prompt for a token (default)
#   2captcha      - https://2captcha.com/        (requires HYFE_CAPTCHA_KEY)
#   anticaptcha   - https://anti-captcha.com/    (requires HYFE_CAPTCHA_KEY)
#   capsolver     - https://capsolver.com/       (requires HYFE_CAPTCHA_KEY)
#   nextcaptcha   - https://nextcaptcha.com/     (requires HYFE_CAPTCHA_KEY)
#                   * supports a free trial via Telegram bot @nextcaptcha_bot
#                   * cheapest paid tier ($0.6/1000 reCAPTCHA v2 Enterprise)
#
# Usage:
#   token=$(captcha_solve) || exit 1

: "${HYFE_CAPTCHA_MODE:=manual}"
: "${HYFE_CAPTCHA_KEY:=}"
: "${HYFE_CAPTCHA_TIMEOUT:=180}"

captcha_solve() {
    case "$HYFE_CAPTCHA_MODE" in
        manual)        _captcha_manual ;;
        2captcha)      _captcha_2captcha ;;
        anticaptcha)   _captcha_anticaptcha ;;
        capsolver)     _captcha_capsolver ;;
        nextcaptcha)   _captcha_nextcaptcha ;;
        *)
            log_error "unknown captcha mode: $HYFE_CAPTCHA_MODE"
            return 1
            ;;
    esac
}

_captcha_manual() {
    {
        printf '\n'
        printf '  reCAPTCHA Enterprise required.\n'
        printf '\n'
        printf '  Steps:\n'
        printf '    1. Open this URL in any browser (PC/HP):\n'
        printf '         %s\n' "$HYFE_RECAPTCHA_PAGE_URL"
        printf '    2. Lengkapi langkah 1 (Pilih nomor) sampai 3 (input EID),\n'
        printf '       lalu di halaman "Verify Email" centang reCAPTCHA.\n'
        printf '    3. Buka DevTools console (F12), jalankan:\n'
        printf '         grecaptcha.getResponse()\n'
        printf '       Salin string token (panjang ~400 karakter) yang muncul.\n'
        printf '\n'
        printf '  Catatan: token reCAPTCHA berlaku 2 menit setelah dicentang.\n'
        printf '\n'
        printf '  Tempel token, lalu Enter:\n'
    } >&2
    printf '> ' >&2
    IFS= read -r token
    token=$(trim "$token")
    [ -n "$token" ] || { log_error "no token entered"; return 1; }
    printf '%s' "$token"
}

# 2captcha API: https://2captcha.com/api-docs/recaptcha-enterprise
_captcha_2captcha() {
    [ -n "$HYFE_CAPTCHA_KEY" ] || { log_error "2captcha: HYFE_CAPTCHA_KEY required"; return 1; }
    log_info "2captcha: submitting recaptcha enterprise task"
    submit=$(curl -s --max-time 30 \
        --data-urlencode "key=$HYFE_CAPTCHA_KEY" \
        --data-urlencode "method=userrecaptcha" \
        --data-urlencode "googlekey=$HYFE_RECAPTCHA_SITEKEY" \
        --data-urlencode "pageurl=$HYFE_RECAPTCHA_PAGE_URL" \
        --data-urlencode "enterprise=1" \
        --data-urlencode "json=1" \
        "https://2captcha.com/in.php")
    log_debug "2captcha submit: $submit"
    cap_id=$(printf '%s' "$submit" | jq -r '.request // empty')
    [ -n "$cap_id" ] || { log_error "2captcha: submit failed: $submit"; return 1; }
    status=$(printf '%s' "$submit" | jq -r '.status // 0')
    if [ "$status" != "1" ]; then
        log_error "2captcha: $cap_id"
        return 1
    fi
    log_info "2captcha: task id=$cap_id, polling..."
    elapsed=0
    while [ "$elapsed" -lt "$HYFE_CAPTCHA_TIMEOUT" ]; do
        sleep 5
        elapsed=$((elapsed + 5))
        poll=$(curl -s --max-time 15 \
            --data-urlencode "key=$HYFE_CAPTCHA_KEY" \
            --data-urlencode "action=get" \
            --data-urlencode "id=$cap_id" \
            --data-urlencode "json=1" \
            "https://2captcha.com/res.php")
        status=$(printf '%s' "$poll" | jq -r '.status // 0')
        if [ "$status" = "1" ]; then
            printf '%s' "$poll" | jq -r '.request'
            return 0
        fi
        req=$(printf '%s' "$poll" | jq -r '.request // empty')
        if [ "$req" != "CAPCHA_NOT_READY" ] && [ -n "$req" ] && [ "$status" = "0" ]; then
            log_error "2captcha: $req"
            return 1
        fi
    done
    log_error "2captcha: timeout after ${HYFE_CAPTCHA_TIMEOUT}s"
    return 1
}

# Anti-captcha API: https://anti-captcha.com/apidoc
_captcha_anticaptcha() {
    [ -n "$HYFE_CAPTCHA_KEY" ] || { log_error "anticaptcha: HYFE_CAPTCHA_KEY required"; return 1; }
    log_info "anticaptcha: creating RecaptchaV2EnterpriseTaskProxyless"
    create=$(curl -s --max-time 30 \
        -H 'Content-Type: application/json' \
        --data "$(jq -nc \
            --arg key "$HYFE_CAPTCHA_KEY" \
            --arg sitekey "$HYFE_RECAPTCHA_SITEKEY" \
            --arg url "$HYFE_RECAPTCHA_PAGE_URL" \
            '{
                clientKey:$key,
                task:{
                    type:"RecaptchaV2EnterpriseTaskProxyless",
                    websiteURL:$url,
                    websiteKey:$sitekey
                }
            }')" \
        "https://api.anti-captcha.com/createTask")
    log_debug "anticaptcha create: $create"
    err=$(printf '%s' "$create" | jq -r '.errorId // 0')
    if [ "$err" != "0" ]; then
        log_error "anticaptcha: $(printf '%s' "$create" | jq -r '.errorDescription // empty')"
        return 1
    fi
    task_id=$(printf '%s' "$create" | jq -r '.taskId // empty')
    [ -n "$task_id" ] || { log_error "anticaptcha: no taskId"; return 1; }
    log_info "anticaptcha: task id=$task_id, polling..."
    elapsed=0
    while [ "$elapsed" -lt "$HYFE_CAPTCHA_TIMEOUT" ]; do
        sleep 5
        elapsed=$((elapsed + 5))
        poll=$(curl -s --max-time 15 \
            -H 'Content-Type: application/json' \
            --data "$(jq -nc \
                --arg key "$HYFE_CAPTCHA_KEY" \
                --argjson tid "$task_id" \
                '{clientKey:$key, taskId:$tid}')" \
            "https://api.anti-captcha.com/getTaskResult")
        status=$(printf '%s' "$poll" | jq -r '.status // empty')
        case "$status" in
            ready)
                printf '%s' "$poll" | jq -r '.solution.gRecaptchaResponse'
                return 0
                ;;
            processing) ;;
            *)
                err=$(printf '%s' "$poll" | jq -r '.errorDescription // empty')
                if [ -n "$err" ]; then
                    log_error "anticaptcha: $err"
                    return 1
                fi
                ;;
        esac
    done
    log_error "anticaptcha: timeout after ${HYFE_CAPTCHA_TIMEOUT}s"
    return 1
}

# Capsolver API: https://docs.capsolver.com/
_captcha_capsolver() {
    [ -n "$HYFE_CAPTCHA_KEY" ] || { log_error "capsolver: HYFE_CAPTCHA_KEY required"; return 1; }
    log_info "capsolver: creating ReCaptchaV2EnterpriseTaskProxyLess"
    create=$(curl -s --max-time 30 \
        -H 'Content-Type: application/json' \
        --data "$(jq -nc \
            --arg key "$HYFE_CAPTCHA_KEY" \
            --arg sitekey "$HYFE_RECAPTCHA_SITEKEY" \
            --arg url "$HYFE_RECAPTCHA_PAGE_URL" \
            '{
                clientKey:$key,
                task:{
                    type:"ReCaptchaV2EnterpriseTaskProxyLess",
                    websiteURL:$url,
                    websiteKey:$sitekey
                }
            }')" \
        "https://api.capsolver.com/createTask")
    log_debug "capsolver create: $create"
    task_id=$(printf '%s' "$create" | jq -r '.taskId // empty')
    [ -n "$task_id" ] || { log_error "capsolver: no taskId: $create"; return 1; }
    log_info "capsolver: task id=$task_id, polling..."
    elapsed=0
    while [ "$elapsed" -lt "$HYFE_CAPTCHA_TIMEOUT" ]; do
        sleep 5
        elapsed=$((elapsed + 5))
        poll=$(curl -s --max-time 15 \
            -H 'Content-Type: application/json' \
            --data "$(jq -nc \
                --arg key "$HYFE_CAPTCHA_KEY" \
                --arg tid "$task_id" \
                '{clientKey:$key, taskId:$tid}')" \
            "https://api.capsolver.com/getTaskResult")
        status=$(printf '%s' "$poll" | jq -r '.status // empty')
        case "$status" in
            ready)
                printf '%s' "$poll" | jq -r '.solution.gRecaptchaResponse'
                return 0
                ;;
            processing) ;;
            *)
                err=$(printf '%s' "$poll" | jq -r '.errorDescription // empty')
                if [ -n "$err" ]; then
                    log_error "capsolver: $err"
                    return 1
                fi
                ;;
        esac
    done
    log_error "capsolver: timeout after ${HYFE_CAPTCHA_TIMEOUT}s"
    return 1
}

# NextCaptcha API: https://nextcaptcha.com/en/apidocs/recaptcha-v2-enterprise
#
# Wire-compatible with the Anti-Captcha-style createTask/getTaskResult flow:
# the request body, the `RecaptchaV2EnterpriseTaskProxyless` task type, and
# the response shape (`status`, `solution.gRecaptchaResponse`,
# `errorDescription`) are all identical. Only the host differs, so this is
# essentially a clone of `_captcha_anticaptcha` pointed at
# api.nextcaptcha.com.
_captcha_nextcaptcha() {
    [ -n "$HYFE_CAPTCHA_KEY" ] || { log_error "nextcaptcha: HYFE_CAPTCHA_KEY required"; return 1; }
    log_info "nextcaptcha: creating RecaptchaV2EnterpriseTaskProxyless"
    create=$(curl -s --max-time 30 \
        -H 'Content-Type: application/json' \
        --data "$(jq -nc \
            --arg key "$HYFE_CAPTCHA_KEY" \
            --arg sitekey "$HYFE_RECAPTCHA_SITEKEY" \
            --arg url "$HYFE_RECAPTCHA_PAGE_URL" \
            '{
                clientKey:$key,
                task:{
                    type:"RecaptchaV2EnterpriseTaskProxyless",
                    websiteURL:$url,
                    websiteKey:$sitekey
                }
            }')" \
        "https://api.nextcaptcha.com/createTask")
    log_debug "nextcaptcha create: $create"
    err=$(printf '%s' "$create" | jq -r '.errorId // 0')
    if [ "$err" != "0" ]; then
        log_error "nextcaptcha: $(printf '%s' "$create" | jq -r '.errorDescription // empty')"
        return 1
    fi
    task_id=$(printf '%s' "$create" | jq -r '.taskId // empty')
    [ -n "$task_id" ] || { log_error "nextcaptcha: no taskId: $create"; return 1; }
    log_info "nextcaptcha: task id=$task_id, polling..."
    elapsed=0
    while [ "$elapsed" -lt "$HYFE_CAPTCHA_TIMEOUT" ]; do
        sleep 5
        elapsed=$((elapsed + 5))
        case "$task_id" in
            *[!0-9]*)
                poll_body=$(jq -nc \
                    --arg key "$HYFE_CAPTCHA_KEY" \
                    --arg tid "$task_id" \
                    '{clientKey:$key, taskId:$tid}')
                ;;
            *)
                poll_body=$(jq -nc \
                    --arg key "$HYFE_CAPTCHA_KEY" \
                    --argjson tid "$task_id" \
                    '{clientKey:$key, taskId:$tid}')
                ;;
        esac
        poll=$(curl -s --max-time 15 \
            -H 'Content-Type: application/json' \
            --data "$poll_body" \
            "https://api.nextcaptcha.com/getTaskResult")
        status=$(printf '%s' "$poll" | jq -r '.status // empty')
        case "$status" in
            ready)
                printf '%s' "$poll" | jq -r '.solution.gRecaptchaResponse'
                return 0
                ;;
            processing) ;;
            *)
                err=$(printf '%s' "$poll" | jq -r '.errorDescription // empty')
                if [ -n "$err" ]; then
                    log_error "nextcaptcha: $err"
                    return 1
                fi
                ;;
        esac
    done
    log_error "nextcaptcha: timeout after ${HYFE_CAPTCHA_TIMEOUT}s"
    return 1
}
