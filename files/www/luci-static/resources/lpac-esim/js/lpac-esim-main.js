/* lpac-esim-main.js — v3.0.1 (0xygen-Linksys patched: client-side fetch timeouts) */
'use strict';

var BASE_URL = L.env.scriptname + '/admin/modem/lpac-esim/';

/* ===== Timeout helper =====
 * Wrap fetch with an AbortController so the UI never hangs forever when the
 * server-side handler (or the router itself) is slow / dead. The default
 * timeout is generous enough for the slowest backend call we make.
 */
function fetchWithTimeout(url, opts, timeoutMs) {
    opts = opts || {};
    var ctrl = (typeof AbortController !== 'undefined') ? new AbortController() : null;
    if (ctrl) opts.signal = ctrl.signal;
    var t = setTimeout(function() {
        if (ctrl) {
            try { ctrl.abort(); } catch (e) {}
        }
    }, timeoutMs || 15000);
    return fetch(url, opts).then(function(r) {
        clearTimeout(t);
        if (!r.ok) {
            var err = new Error('HTTP ' + r.status);
            err.status = r.status;
            throw err;
        }
        return r;
    }, function(err) {
        clearTimeout(t);
        throw err;
    });
}

/* ===== Lazy load tracking ===== */
var tabLoaded = {};

/* ===== Tab switching with lazy load ===== */
function showTab(tabId, el) {
    var tabs = document.querySelectorAll('.cbi-tabcontent');
    for (var i = 0; i < tabs.length; i++) {
        tabs[i].style.display = 'none';
        tabs[i].classList.remove('cbi-tabcontent-active');
    }
    var links = document.querySelectorAll('.cbi-tabmenu li');
    for (var j = 0; j < links.length; j++) {
        links[j].classList.remove('cbi-tab-active');
    }
    var target = document.getElementById(tabId);
    if (target) {
        target.style.display = '';
        target.classList.add('cbi-tabcontent-active');
    }
    if (el && el.parentNode) {
        el.parentNode.classList.add('cbi-tab-active');
    }

    /* Lazy load: fetch data only on first tab activation */
    if (!tabLoaded[tabId]) {
        tabLoaded[tabId] = true;
        switch (tabId) {
            case 'info-tab':          if (typeof loadESIMInfo === 'function') loadESIMInfo(); break;
            case 'profiles-tab':      if (typeof loadProfiles === 'function') loadProfiles(); break;
            case 'notifications-tab': if (typeof loadNotifications === 'function') loadNotifications(); break;
            case 'config-tab':        if (typeof loadConfig === 'function') loadConfig(); break;
            case 'telegram-tab':      if (typeof loadTelegramConfig === 'function') loadTelegramConfig(); break;
            case 'diag-tab':          if (typeof loadSyslog === 'function') loadSyslog(); break;
        }
    }
    return false;
}

/* Force reload of a tab (for Refresh buttons) */
function reloadTab(tabId) {
    tabLoaded[tabId] = false;
    var links = document.querySelectorAll('.cbi-tabmenu a');
    var active = null;
    for (var i = 0; i < links.length; i++) {
        var onclick = links[i].getAttribute('onclick') || '';
        if (onclick.indexOf("'" + tabId + "'") !== -1) {
            active = links[i];
            break;
        }
    }
    showTab(tabId, active);
}

/* ===== Connectivity check ===== */
function checkConnectivity() {
    var checking = document.getElementById('connectivity-checking');
    var online   = document.getElementById('connectivity-online');
    var offline  = document.getElementById('connectivity-offline');
    if (checking) checking.style.display = 'block';
    if (online)   online.style.display   = 'none';
    if (offline)  offline.style.display  = 'none';

    /* 5s client-side timeout; if the controller / router never replies we
     * show the offline banner instead of leaving the user staring at
     * "Checking internet connection..." forever. */
    fetchWithTimeout(BASE_URL + 'connectivity', { credentials: 'same-origin' }, 5000)
        .then(function(r) { return r.json(); })
        .then(function(data) {
            if (checking) checking.style.display = 'none';
            if (data && data.connected) {
                if (online) online.style.display = 'block';
            } else {
                if (offline) offline.style.display = 'block';
            }
        })
        .catch(function() {
            if (checking) checking.style.display = 'none';
            if (offline) offline.style.display = 'block';
        });
}

/* ===== Lock status polling ===== */
var lockPollTimer = null;
var lockPollStartedAt = 0;
var LOCK_POLL_MAX_MS = 180000;

function checkLockStatus(callback) {
    fetchWithTimeout(BASE_URL + 'lock_status', { credentials: 'same-origin' }, 5000)
        .then(function(r) { return r.json(); })
        .then(function(data) {
            var banner = document.getElementById('esim-lock-banner');
            if (data && data.payload && data.payload.data && data.payload.data.locked) {
                if (banner) banner.style.display = 'block';
            } else {
                if (banner) banner.style.display = 'none';
                if (callback) callback();
            }
        })
        .catch(function() {
            var banner = document.getElementById('esim-lock-banner');
            if (banner) banner.style.display = 'none';
        });
}

function startLockPolling(onUnlocked) {
    if (lockPollTimer) clearInterval(lockPollTimer);
    var settled = false;
    function finish(result) {
        if (settled) return;
        settled = true;
        if (onUnlocked) onUnlocked(result);
    }
    lockPollStartedAt = Date.now();
    lockPollTimer = setInterval(function() {
        if (Date.now() - lockPollStartedAt > LOCK_POLL_MAX_MS) {
            clearInterval(lockPollTimer);
            lockPollTimer = null;
            var banner = document.getElementById('esim-lock-banner');
            var bannerText = document.getElementById('esim-lock-text');
            if (banner) banner.style.display = 'block';
            if (bannerText) bannerText.textContent = 'Operation timed out. Refresh status before retrying.';
            finish({ success: false, message: 'Operation timed out. Refresh status before retrying.' });
            return;
        }
        fetchWithTimeout(BASE_URL + 'lock_status', { credentials: 'same-origin' }, 5000)
            .then(function(r) { return r.json(); })
            .then(function(data) {
                var banner = document.getElementById('esim-lock-banner');
                var bannerText = document.getElementById('esim-lock-text');
                var d = data && data.payload && data.payload.data;
                if (d && d.locked) {
                    if (banner) banner.style.display = 'block';
                    if (bannerText) bannerText.textContent = 'Operation in progress... Please wait.';
                } else {
                    if (banner) banner.style.display = 'none';
                    clearInterval(lockPollTimer);
                    lockPollTimer = null;
                    var result = (d && d.last_result) ? d.last_result : null;
                    finish(result);
                }
            })
            .catch(function() {
                // Network lost (modem rebooting, interface down)
                var banner = document.getElementById('esim-lock-banner');
                var bannerText = document.getElementById('esim-lock-text');
                if (banner) banner.style.display = 'block';
                if (bannerText) bannerText.textContent = 'Connection lost — modem may be rebooting. Waiting for recovery...';
                // Don't clear interval — keep retrying
            });
    }, 5000);
}

/* ===== Helper: POST ===== */
function apiPost(endpoint, params) {
    var body = new URLSearchParams();
    if (params) {
        Object.keys(params).forEach(function(k) {
            body.append(k, params[k]);
        });
    }
    return fetchWithTimeout(BASE_URL + endpoint, {
        method: 'POST',
        credentials: 'same-origin',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: body.toString()
    }, 60000).then(function(r) { return r.json(); });
}

/* ===== Helper: GET ===== */
function apiGet(endpoint) {
    return fetchWithTimeout(BASE_URL + endpoint, { credentials: 'same-origin' }, 30000)
        .then(function(r) { return r.json(); });
}

/* ===== Init ===== */
document.addEventListener('DOMContentLoaded', function() {
    checkConnectivity();
    /* Fetch and display version */
    apiGet('version').then(function(data) {
        if (data && data.payload && data.payload.data) {
            var v = data.payload.data;
            var el = document.getElementById('esim-app-version');
            if (el) el.textContent = 'v' + (v.script_version || '?') + ' / lpac ' + (v.lpac_version || '?') + ' / ' + (v.backend || '?').toUpperCase();
        }
    }).catch(function() {});
    /* Activate first tab — triggers lazy load for Info only */
    var firstTab = document.querySelector('.cbi-tabmenu li a');
    if (firstTab) firstTab.click();
});
