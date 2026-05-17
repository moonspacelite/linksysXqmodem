/* lpac-esim-config.js — v3.0.0 */
'use strict';

function loadConfig() {
    var loading = document.getElementById('config-loading');
    var content = document.getElementById('config-content');
    var errDiv  = document.getElementById('config-error');
    var sucDiv  = document.getElementById('config-success');
    if (loading) loading.style.display = 'block';
    if (content) content.style.display = 'none';
    if (errDiv)  errDiv.style.display  = 'none';
    if (sucDiv)  sucDiv.style.display  = 'none';

    apiGet('config')
        .then(function(data) {
            if (loading) loading.style.display = 'none';
            if (data && data.success && data.config) {
                populateConfig(data.config);
                if (content) content.style.display = '';
                onBackendChange();
            } else {
                showConfigError('Failed to load configuration');
            }
        })
        .catch(function(e) {
            if (loading) loading.style.display = 'none';
            showConfigError(e.message || 'Network error');
        });
}

function populateConfig(cfg) {
    setVal('cfg-apdu-backend',  cfg.apdu_backend  || 'mbim');
    setVal('cfg-qmi-device',    cfg.qmi_device    || '/dev/cdc-wdm0');
    setVal('cfg-sim-slot',      cfg.sim_slot      || '1');
    setVal('cfg-at-device',     cfg.at_device     || '/dev/ttyUSB2');
    setVal('cfg-mbim-device',   cfg.mbim_device   || '/dev/cdc-wdm0');
    setVal('cfg-mbim-proxy',    cfg.mbim_proxy    || '1');
    setVal('cfg-mbim-skip-slot', cfg.mbim_skip_slot_mapping || '1');
    setVal('cfg-custom-isd-r-aid', cfg.custom_isd_r_aid || 'A0000005591010FFFFFFFF8900000100');
    setVal('cfg-reboot-method', cfg.reboot_method || 'script');
    setVal('cfg-modem-iface',   cfg.modem_iface   || '1_1');
    setVal('cfg-apdu-debug',    cfg.apdu_debug    || '0');
    setVal('cfg-http-debug',    cfg.http_debug    || '0');
    setVal('cfg-at-debug',      cfg.at_debug      || '0');
}

function setVal(id, val) {
    var el = document.getElementById(id);
    if (el) el.value = val;
}

function getVal(id) {
    var el = document.getElementById(id);
    return el ? el.value : '';
}

function onBackendChange() {
    var backend = getVal('cfg-apdu-backend');

    // Show/hide device rows based on backend
    var qmiRows  = ['cfg-qmi-device-row'];
    var mbimRows = ['cfg-mbim-device-row', 'cfg-mbim-proxy-row', 'cfg-mbim-skip-slot-row'];

    qmiRows.forEach(function(id) {
        var el = document.getElementById(id);
        if (el) el.style.display = (backend === 'qmi') ? '' : 'none';
    });
    mbimRows.forEach(function(id) {
        var el = document.getElementById(id);
        if (el) el.style.display = (backend === 'mbim') ? '' : 'none';
    });
    // AT device always visible — used as fallback for reboot in all modes
}

function saveConfig() {
    var errDiv = document.getElementById('config-error');
    var sucDiv = document.getElementById('config-success');
    if (errDiv) errDiv.style.display = 'none';
    if (sucDiv) sucDiv.style.display = 'none';

    var cfg = {
        apdu_backend:  getVal('cfg-apdu-backend'),
        qmi_device:    getVal('cfg-qmi-device'),
        sim_slot:      getVal('cfg-sim-slot'),
        at_device:     getVal('cfg-at-device'),
        mbim_device:   getVal('cfg-mbim-device'),
        mbim_proxy:    getVal('cfg-mbim-proxy'),
        mbim_skip_slot_mapping: getVal('cfg-mbim-skip-slot'),
        custom_isd_r_aid: getVal('cfg-custom-isd-r-aid'),
        reboot_method: getVal('cfg-reboot-method'),
        modem_iface:   getVal('cfg-modem-iface'),
        apdu_debug:    getVal('cfg-apdu-debug'),
        http_debug:    getVal('cfg-http-debug'),
        at_debug:      getVal('cfg-at-debug')
    };

    // Only send qmi_sim_slot if the field exists in the form
    var qmiSlotEl = document.getElementById('cfg-qmi-slot');
    if (qmiSlotEl && qmiSlotEl.value !== '') {
        cfg.qmi_sim_slot = qmiSlotEl.value;
    }

    apiPost('save_config', { config: JSON.stringify(cfg) })
        .then(function(data) {
            if (data && data.success) {
                showConfigSuccess(data.message || 'Configuration saved');
            } else if (data && data.error) {
                showConfigError(data.error);
            } else if (data && data.payload && data.payload.data && data.payload.data.msg) {
                showConfigError(data.payload.data.msg);
            } else if (data && data.payload && data.payload.message) {
                showConfigError(data.payload.message);
            } else {
                showConfigError('Save failed');
            }
        })
        .catch(function(e) {
            showConfigError(e.message || 'Network error');
        });
}

function showConfigError(msg) {
    var errDiv = document.getElementById('config-error');
    var span   = document.getElementById('config-error-message');
    if (span) span.textContent = msg;
    if (errDiv) errDiv.style.display = 'block';
}

function showConfigSuccess(msg) {
    var sucDiv = document.getElementById('config-success');
    var span   = document.getElementById('config-success-message');
    if (span) span.textContent = msg;
    if (sucDiv) sucDiv.style.display = 'block';
}

// Loaded by showTab() on first tab activation
