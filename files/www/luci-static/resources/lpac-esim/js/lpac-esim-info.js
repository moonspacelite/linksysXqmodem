/* lpac-esim-info.js — v3.0.0 */
'use strict';

function loadESIMInfo() {
    var loading = document.getElementById('esim-info-loading');
    var content = document.getElementById('esim-info-content');
    var errDiv  = document.getElementById('esim-info-error');
    if (loading) loading.style.display = 'block';
    if (content) content.style.display = 'none';
    if (errDiv)  errDiv.style.display  = 'none';

    apiGet('chip')
        .then(function(data) {
            if (loading) loading.style.display = 'none';
            if (data && data.payload && data.payload.code === 0) {
                var d = data.payload.data;
                setText('esim-eid', d.eidValue || '-');
                if (d.EUICCInfo2) {
                    setText('esim-profile-version', d.EUICCInfo2.profileVersion || '-');
                    setText('esim-svn', d.EUICCInfo2.svn || '-');
                    setText('esim-firmware', d.EUICCInfo2.euiccFirmwareVer || '-');
                    if (d.EUICCInfo2.extCardResource) {
                        setText('esim-nv-memory', formatBytes(d.EUICCInfo2.extCardResource.freeNonVolatileMemory));
                        setText('esim-v-memory', formatBytes(d.EUICCInfo2.extCardResource.freeVolatileMemory));
                        setText('esim-apps', d.EUICCInfo2.extCardResource.installedApplication);
                    }
                }
                if (d.EuiccConfiguredAddresses) {
                    setText('esim-smdp', d.EuiccConfiguredAddresses.defaultDpAddress || 'Not set');
                    setText('esim-smds', d.EuiccConfiguredAddresses.rootDsAddress || '-');
                }
                if (content) content.style.display = '';
            } else {
                showError(errDiv, data);
            }
        })
        .catch(function(e) {
            if (loading) loading.style.display = 'none';
            showErrorMsg(errDiv, e.message || 'Network error');
        });

    // Also fetch modem status
    apiGet('modem_status')
        .then(function(data) {
            if (data && data.payload && data.payload.code === 0 && data.payload.data) {
                var m = data.payload.data;
                if (m.available === false) {
                    setText('modem-operator',   '-');
                    setText('modem-technology',  '-');
                    setText('modem-signal',      '-');
                    setText('modem-state',       'Not detected');
                    setText('modem-model',       '-');
                } else {
                    setText('modem-operator',    m.operator       || '-');
                    setText('modem-technology',  m.access_tech    || '-');
                    setText('modem-signal',      m.signal_quality || '-');
                    setText('modem-state',       m.state          || '-');
                    setText('modem-model',       m.model          || '-');
                }
            }
        })
        .catch(function() { /* modem status is optional */ });
}

function setText(id, val) {
    var el = document.getElementById(id);
    if (el) el.textContent = (val !== null && val !== undefined) ? String(val) : '-';
}

function formatBytes(bytes) {
    if (bytes === null || bytes === undefined) return '-';
    if (bytes < 1024) return bytes + ' B';
    return (bytes / 1024).toFixed(1) + ' KB';
}

function showError(errDiv, data) {
    if (!errDiv) return;
    var msg = 'Unknown error';
    if (data && data.payload) {
        msg = data.payload.message || msg;
        if (data.payload.data && data.payload.data.msg) msg += ': ' + data.payload.data.msg;
    }
    showErrorMsg(errDiv, msg);
}

function showErrorMsg(errDiv, msg) {
    if (!errDiv) return;
    var span = document.getElementById('esim-error-message');
    if (span) span.textContent = msg;
    errDiv.style.display = 'block';
}

// Loaded by showTab() on first tab activation — no DOMContentLoaded here
