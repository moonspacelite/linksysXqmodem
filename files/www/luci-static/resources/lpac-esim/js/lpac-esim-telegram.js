/* lpac-esim-telegram.js — v3.2.0 */
'use strict';

/* Auto-refresh handle for the live status badge. The status panel polls every
 * 5s while the page is visible so the user sees "Running" go red the moment
 * the bot stops or starts failing — instead of having to click Check Bot
 * Status manually.
 *
 * telegramStatusInFlight guards against a previous request still being in
 * flight when the next 5s tick fires. Without this, a slow getMe call to
 * api.telegram.org (the backend allows up to 8s) could pile up multiple
 * concurrent uhttpd workers and lock the rest of LuCI. The Lua controller
 * caches the getMe result with a 30s TTL, so the steady-state cost of
 * auto-refresh is one cheap pidof/heartbeat read every 5s. */
var telegramStatusTimer = null;
var telegramStatusInFlight = false;
/* When a forced (cache-bypassing) call arrives while a non-forced auto-
 * refresh is still in flight, we cannot just drop it — that would silently
 * lose the user's "Save & Restart Bot" or "Check Bot Status" intent and
 * leave the badge showing stale cached data. Instead we set this flag and
 * fire a fresh forced call as soon as the in-flight one resolves. */
var telegramStatusPendingForce = false;

function loadTelegramConfig() {
    var loading = document.getElementById('telegram-loading');
    var content = document.getElementById('telegram-content');
    var errDiv  = document.getElementById('telegram-error');
    var sucDiv  = document.getElementById('telegram-success');
    if (loading) loading.style.display = 'block';
    if (content) content.style.display = 'none';
    if (errDiv)  errDiv.style.display  = 'none';
    if (sucDiv)  sucDiv.style.display  = 'none';

    apiGet('config')
        .then(function(data) {
            if (loading) loading.style.display = 'none';
            if (data && data.success && data.config) {
                populateTelegramConfig(data.config);
                if (content) content.style.display = '';
                /* Kick off live status polling as soon as the page is
                 * visible so the badge reflects the actual bot state
                 * within seconds of the form loading. */
                startTelegramStatusAutoRefresh();
            } else {
                showTelegramError('Failed to load Telegram settings');
            }
        })
        .catch(function(e) {
            if (loading) loading.style.display = 'none';
            showTelegramError(e.message || 'Network error');
        });
}

function populateTelegramConfig(cfg) {
    setVal('cfg-telegram-enabled', cfg.telegram_enabled || '0');
    setVal('cfg-telegram-bot-token', cfg.telegram_bot_token || '');
    setVal('cfg-telegram-allowed-chat-id', cfg.telegram_allowed_chat_id || '');
    setVal('cfg-telegram-poll-interval', cfg.telegram_poll_interval || '2');
    setVal('cfg-telegram-debug', cfg.telegram_debug || '0');
}

function saveTelegramConfig() {
    var errDiv = document.getElementById('telegram-error');
    var sucDiv = document.getElementById('telegram-success');
    if (errDiv) errDiv.style.display = 'none';
    if (sucDiv) sucDiv.style.display = 'none';

    var cfg = {
        telegram_enabled: getVal('cfg-telegram-enabled'),
        telegram_bot_token: getVal('cfg-telegram-bot-token'),
        telegram_allowed_chat_id: getVal('cfg-telegram-allowed-chat-id'),
        telegram_poll_interval: getVal('cfg-telegram-poll-interval'),
        telegram_debug: getVal('cfg-telegram-debug')
    };

    apiPost('save_telegram_config', { config: JSON.stringify(cfg) })
        .then(function(data) {
            if (data && data.success) {
                showTelegramSuccess(data.message || 'Telegram settings saved');
                /* Force a fresh getMe — the token may have just changed,
                 * so the cached result is now stale. */
                checkTelegramStatus(true);
            } else if (data && data.error) {
                /* When the backend saved config but the bot failed to start,
                 * also refresh the diagnostics panel so the user immediately
                 * sees the syslog hint (binary missing / invalid token / ...). */
                showTelegramError(data.error);
                if (data.saved) checkTelegramStatus(true);
            } else if (data && data.payload && data.payload.data && data.payload.data.msg) {
                showTelegramError(data.payload.data.msg);
            } else {
                showTelegramError('Save failed');
            }
        })
        .catch(function(e) {
            showTelegramError(e.message || 'Network error');
        });
}

function yesNo(v) {
    return v ? 'yes' : 'no';
}

/* Translate the structured status payload from api_telegram_status into one
 * of four user-facing states: running / stopped / api_error / misconfigured.
 * Each maps to a colour and a one-line summary that goes into the badge. */
function deriveTelegramBadge(data) {
    var hb = data.heartbeat;
    var now = (typeof data.now === 'number') ? data.now : Math.floor(Date.now() / 1000);
    var ageSec = (hb && typeof hb.last_poll === 'number') ? (now - hb.last_poll) : null;

    if (!data.enabled) {
        return { color: '#888', label: '● Disabled',
                 detail: 'Enable the bot below, then Save & Restart.' };
    }
    if (!data.token_ok || !data.token_set) {
        return { color: '#c0392b', label: '● Misconfigured',
                 detail: 'Bot Token is missing or has an invalid format.' };
    }
    if (!data.running) {
        return { color: '#c0392b', label: '● Stopped',
                 detail: 'esim-telegram-bot is not running. Click Save & Restart Bot.' };
    }
    if (!data.api_ok) {
        return { color: '#c0392b', label: '● API unreachable',
                 detail: data.api_error
                     ? ('Telegram API: ' + String(data.api_error).slice(0, 120))
                     : 'Bot is running but cannot reach api.telegram.org.' };
    }
    if (hb && hb.state === 'error') {
        return { color: '#c0392b', label: '● Polling error',
                 detail: 'Last poll failed (curl rc=' + hb.last_rc + '). Check token / DNS.' };
    }
    if (ageSec !== null && ageSec > 120) {
        /* Heartbeat is stale — the binary is alive (pidof matched) but the
         * polling loop hasn't ticked in over 2 minutes. Almost always means
         * curl is stuck on a hung TCP connection. */
        return { color: '#e67e22', label: '● Stale',
                 detail: 'Bot process is up but last successful poll was '
                         + ageSec + 's ago.' };
    }
    var detail = 'Replying to messages';
    if (data.bot_username) detail += ' as @' + data.bot_username;
    if (ageSec !== null)   detail += ' · last poll ' + ageSec + 's ago';
    if (data.pid)          detail += ' · PID ' + data.pid;
    return { color: '#27ae60', label: '● Running', detail: detail };
}

function renderTelegramBadge(data) {
    var badge  = document.getElementById('telegram-badge');
    var detail = document.getElementById('telegram-badge-detail');
    if (!badge && !detail) return;
    if (!data || !data.success) {
        if (badge)  { badge.style.background = '#888'; badge.textContent = '● Unknown'; }
        if (detail) { detail.textContent = 'Could not read bot status'; }
        return;
    }
    var b = deriveTelegramBadge(data);
    if (badge)  { badge.style.background = b.color; badge.textContent = b.label; }
    if (detail) { detail.textContent = b.detail; }
}

/* force=true is used by the "Check Bot Status" button and bypasses the
 * server-side getMe cache so the user gets an immediately fresh reading.
 * The auto-refresh loop calls without force, so its actual rate of hitting
 * api.telegram.org is bounded by the server TTL (30s). */
function checkTelegramStatus(force) {
    if (telegramStatusInFlight) {
        /* A request is already running. Drop non-forced calls (the next
         * auto-refresh tick will catch up), but remember forced ones so we
         * can re-issue them when the current request resolves — forced
         * calls carry user intent (saved a new token, clicked the manual
         * check button) and must eventually reach the backend with
         * ?fresh=1. */
        if (force) telegramStatusPendingForce = true;
        return Promise.resolve(null);
    }
    telegramStatusInFlight = true;
    var endpoint = 'telegram_status' + (force ? '?fresh=1' : '');
    var box = document.getElementById('telegram-status');
    if (box) box.textContent = 'Checking...';

    var clearInFlight = function() { telegramStatusInFlight = false; };
    return apiGet(endpoint)
        .then(function(data) {
            renderTelegramBadge(data);
            if (!box) return data;
            if (!data || !data.success) {
                box.textContent = 'Failed to read Telegram bot status';
                return data;
            }
            var hb = data.heartbeat;
            var ageSec = (hb && typeof hb.last_poll === 'number' && typeof data.now === 'number')
                ? (data.now - hb.last_poll) : null;
            /* Note: hb.last_poll is written by the bot on BOTH success and
             * error paths (write_status("ok"/"error", ...)) so this is
             * "last poll attempt", not strictly "last successful poll".
             * The hb.state field below tells you whether that attempt was
             * ok or error. */
            var lines = [
                'Enabled: ' + yesNo(data.enabled),
                'Running: ' + yesNo(data.running) + (data.pid ? ' (PID ' + data.pid + ')' : ''),
                'Last poll: ' + (ageSec !== null ? (ageSec + 's ago')
                                            : '(no heartbeat yet)'),
                'Last poll state: ' + (hb ? hb.state : '-') +
                    (hb && hb.last_rc ? ' (rc=' + hb.last_rc + ')' : ''),
                'Token set: ' + yesNo(data.token_set),
                'Token format OK: ' + yesNo(data.token_ok),
                'Telegram API OK: ' + yesNo(data.api_ok) +
                    (data.api_cached ? ' (cached)' : ''),
                'Bot username: ' + (data.bot_username ? '@' + data.bot_username : '-'),
                'Bot link: ' + (data.bot_link || '-'),
                'Allowed Chat ID: ' + (data.chat_id || 'empty'),
                'Chat ID format OK: ' + yesNo(data.chat_ok),
                '',
                'Important: open your own bot username from BotFather, not the BotFather chat itself.',
                data.bot_link ? 'Open this link, press Start, then send /start: ' + data.bot_link : '',
                'If Running is no, click Save & Restart Bot or run /etc/init.d/esim-telegram-bot restart.',
                'If Chat ID is empty, send /chatid to your own bot first, then fill it here.',
                data.api_error ? 'Telegram API error: ' + data.api_error : '',
                '',
                'Recent log:',
                data.logs || '(empty)'
            ].filter(function(line) { return line !== ''; });
            box.textContent = lines.join('\n');
            return data;
        })
        .catch(function(e) {
            renderTelegramBadge(null);
            if (box) box.textContent = e.message || 'Network error';
        })
        .then(function(v) { clearInFlight(); flushPendingForce(); return v; },
              function(e) { clearInFlight(); flushPendingForce(); throw e; });
}

function flushPendingForce() {
    if (!telegramStatusPendingForce) return;
    telegramStatusPendingForce = false;
    /* Defer one tick so the just-cleared in-flight flag is observed by the
     * recursive call, and we don't re-enter the guard. */
    setTimeout(function() { checkTelegramStatus(true); }, 0);
}

/* Poll the status endpoint every 5s while the Telegram tab is visible.
 * Each call reads /tmp/lpac-esim/telegram.status (cheap) and may run a
 * curl to api.telegram.org/getMe — but the Lua controller caches that
 * curl result for 30s, so the typical poll is just pidof + file read.
 * Plus the in-flight guard above prevents concurrent requests. The auto-
 * refresh pauses while the tab is hidden via the Page Visibility API. */
function startTelegramStatusAutoRefresh() {
    stopTelegramStatusAutoRefresh();
    checkTelegramStatus();
    telegramStatusTimer = setInterval(function() {
        if (!document.hidden) checkTelegramStatus();
    }, 5000);
}

function stopTelegramStatusAutoRefresh() {
    if (telegramStatusTimer) {
        clearInterval(telegramStatusTimer);
        telegramStatusTimer = null;
    }
}

window.checkTelegramStatus = checkTelegramStatus;
window.startTelegramStatusAutoRefresh = startTelegramStatusAutoRefresh;
window.stopTelegramStatusAutoRefresh = stopTelegramStatusAutoRefresh;

function showTelegramError(msg) {
    var errDiv = document.getElementById('telegram-error');
    var span   = document.getElementById('telegram-error-message');
    if (span) span.textContent = msg;
    if (errDiv) errDiv.style.display = 'block';
}

function showTelegramSuccess(msg) {
    var sucDiv = document.getElementById('telegram-success');
    var span   = document.getElementById('telegram-success-message');
    if (span) span.textContent = msg;
    if (sucDiv) sucDiv.style.display = 'block';
}
