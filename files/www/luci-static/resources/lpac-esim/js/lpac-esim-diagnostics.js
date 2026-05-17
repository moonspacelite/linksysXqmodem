/* lpac-esim-diagnostics.js — v3.0.0 */
'use strict';

function loadRunlog() {
    var el = document.getElementById('diag-log');
    if (!el) return;
    el.textContent = 'Loading system check...';
    var btn = document.getElementById('btn-runlog');
    apiGet('runlog')
        .then(function(data) {
            if (data && data.payload && data.payload.code === 0 && data.payload.data) {
                el.textContent = data.payload.data.log || '(empty — run lpac-esim once to generate)';
            } else {
                el.textContent = 'Failed to load system check.';
            }
            if (btn) btn.value = '\u21bb System Check';
        })
        .catch(function(e) { el.textContent = 'Error: ' + (e.message || 'network'); });
}

function loadSyslog() {
    var logDiv = document.getElementById('diag-log');
    if (!logDiv) return;
    logDiv.textContent = 'Loading...';
    var btn = document.getElementById('btn-syslog');

    apiGet('syslog')
        .then(function(data) {
            if (data && data.payload && data.payload.code === 0 && data.payload.data) {
                var log = data.payload.data.log || '(empty log)';
                logDiv.textContent = log;
                logDiv.scrollTop = logDiv.scrollHeight;
            } else {
                logDiv.textContent = 'Failed to load log.';
            }
            if (btn) btn.value = '\u21bb System Log';
        })
        .catch(function(e) {
            logDiv.textContent = 'Error: ' + (e.message || 'network error');
        });
}

function copyLog() {
    var logDiv = document.getElementById('diag-log');
    if (!logDiv) return;
    var text = logDiv.textContent || '';
    if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(function() {
            showDiagResult('success', 'Log copied to clipboard.');
        }).catch(function() {
            fallbackCopy(text);
        });
    } else {
        fallbackCopy(text);
    }
}

function fallbackCopy(text) {
    var ta = document.createElement('textarea');
    ta.value = text;
    ta.style.position = 'fixed';
    ta.style.left = '-9999px';
    document.body.appendChild(ta);
    ta.select();
    try {
        document.execCommand('copy');
        showDiagResult('success', 'Log copied to clipboard.');
    } catch (e) {
        showDiagResult('error', 'Copy failed. Select log text manually.');
    }
    document.body.removeChild(ta);
}

function diagAction(endpoint, label) {
    if (!confirm('Execute ' + label + '?\n\nThis will affect modem connectivity.')) return;

    showDiagResult('info', label + ' in progress...');
    appendToLog('[' + new Date().toLocaleTimeString() + '] >>> ' + label + ' requested');

    var promise;
    if (endpoint === 'reboot_modem') {
        promise = apiPost(endpoint, {});
    } else {
        promise = apiPost(endpoint, {});
    }

    promise.then(function(data) {
        if (data && data.payload) {
            if (data.payload.code === 0) {
                var method = '';
                if (data.payload.data && data.payload.data.method) {
                    method = ' (via ' + data.payload.data.method + ')';
                }
                if (data.payload.message === 'processing') {
                    showDiagResult('info', label + ' initiated. Modem is rebooting...');
                    appendToLog('[' + new Date().toLocaleTimeString() + '] ' + label + ' launched in background');
                    startLockPolling(function(result) {
                        if (result && result.success) {
                            showDiagResult('success', result.message || label + ' completed.');
                        } else if (result && !result.success) {
                            showDiagResult('error', result.message || label + ' failed.');
                        } else {
                            showDiagResult('success', label + ' completed.');
                        }
                        appendToLog('[' + new Date().toLocaleTimeString() + '] ' + label + ' finished');
                        setTimeout(loadSyslog, 2000);
                    });
                } else {
                    showDiagResult('success', label + ' completed' + method + '.');
                    appendToLog('[' + new Date().toLocaleTimeString() + '] ' + label + ' OK' + method);
                    setTimeout(loadSyslog, 2000);
                }
            } else {
                var msg = data.payload.message || 'failed';
                if (data.payload.data && data.payload.data.msg) msg += ': ' + data.payload.data.msg;
                showDiagResult('error', label + ' failed: ' + msg);
                appendToLog('[' + new Date().toLocaleTimeString() + '] ' + label + ' FAILED: ' + msg);
            }
        }
    })
    .catch(function(e) {
        showDiagResult('error', label + ' error: ' + (e.message || 'network error'));
        appendToLog('[' + new Date().toLocaleTimeString() + '] ' + label + ' ERROR: ' + (e.message || 'network'));
    });
}

function appendToLog(line) {
    var logDiv = document.getElementById('diag-log');
    if (!logDiv) return;
    logDiv.textContent += '\n' + line;
    logDiv.scrollTop = logDiv.scrollHeight;
}

function showDiagResult(type, msg) {
    var el = document.getElementById('diag-result');
    if (!el) return;
    el.style.display = 'block';
    el.textContent = msg;
    if (type === 'success') {
        el.style.background = '#d4edda'; el.style.color = '#155724'; el.style.borderColor = '#c3e6cb';
    } else if (type === 'error') {
        el.style.background = '#f8d7da'; el.style.color = '#721c24'; el.style.borderColor = '#f5c6cb';
    } else {
        el.style.background = '#d1ecf1'; el.style.color = '#0c5460'; el.style.borderColor = '#bee5eb';
    }
    el.style.border = '1px solid';
}

// Loaded by showTab() on first tab activation

/* ===== AT Terminal ===== */
var atHistory = [];

function toggleAtTerminal() {
    var section = document.getElementById('at-terminal-section');
    var arrow = document.getElementById('at-toggle-arrow');
    if (!section) return;
    if (section.style.display === 'none') {
        section.style.display = '';
        if (arrow) arrow.innerHTML = '&#9660;';
    } else {
        section.style.display = 'none';
        if (arrow) arrow.innerHTML = '&#9654;';
    }
}

function sendAtCmd() {
    var input = document.getElementById('at-cmd-input');
    var term = document.getElementById('at-terminal');
    if (!input || !term) return;

    var cmd = input.value.trim();
    if (!cmd) cmd = 'ATI';

    // Show sending state
    atHistory.push('> ' + cmd);
    atHistory.push('  (sending...)');
    term.textContent = atHistory.join('\n');
    term.scrollTop = term.scrollHeight;

    apiPost('at_cmd', { cmd: cmd })
        .then(function(data) {
            // Remove "(sending...)"
            atHistory.pop();
            if (data && data.payload && data.payload.code === 0 && data.payload.data) {
                var resp = data.payload.data.response || '(no response)';
                var port = data.payload.data.port || '?';
                atHistory.push(resp);
                atHistory.push('  [' + port + ']');
            } else {
                var errMsg = (data && data.payload) ? data.payload.message : 'unknown error';
                if (data && data.payload && data.payload.data && data.payload.data.msg) {
                    errMsg += ': ' + data.payload.data.msg;
                }
                atHistory.push('  ERROR: ' + errMsg);
            }
            term.textContent = atHistory.join('\n');
            term.scrollTop = term.scrollHeight;
        })
        .catch(function(e) {
            atHistory.pop();
            atHistory.push('  ERROR: ' + (e.message || 'network'));
            term.textContent = atHistory.join('\n');
            term.scrollTop = term.scrollHeight;
        });

    // Clear input for next command
    input.value = '';
    input.focus();
}

function sendAtPreset(cmd) {
    var input = document.getElementById('at-cmd-input');
    if (input) input.value = cmd;
    sendAtCmd();
}

function clearAtTerminal() {
    atHistory = [];
    var term = document.getElementById('at-terminal');
    if (term) term.textContent = 'Ready. Type an AT command or click Send.';
}
