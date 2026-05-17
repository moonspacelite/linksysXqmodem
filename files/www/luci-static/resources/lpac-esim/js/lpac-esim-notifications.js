/* lpac-esim-notifications.js — v3.0.1 */
'use strict';

function loadNotifications() {
    var loading = document.getElementById('notifications-loading');
    var content = document.getElementById('notifications-content');
    var errDiv  = document.getElementById('notifications-error');
    var noNotif = document.getElementById('no-notifications');
    if (loading) loading.style.display = 'block';
    if (content) content.style.display = 'none';
    if (errDiv)  errDiv.style.display  = 'none';

    apiGet('notif_list')
        .then(function(data) {
            if (loading) loading.style.display = 'none';
            if (data && data.payload && data.payload.code === 0) {
                var notifs = data.payload.data;
                renderNotifications(notifs);
                if (content) content.style.display = '';
            } else {
                showNotifErrorFromData(data);
            }
        })
        .catch(function(e) {
            if (loading) loading.style.display = 'none';
            showNotifError(e.message || 'Network error');
        });
}

function renderNotifications(notifs) {
    var tbody  = document.getElementById('notifications-tbody');
    var noDiv  = document.getElementById('no-notifications');
    if (!tbody) return;

    tbody.innerHTML = '';

    if (!notifs || !Array.isArray(notifs) || notifs.length === 0) {
        if (noDiv) noDiv.style.display = 'block';
        return;
    }
    if (noDiv) noDiv.style.display = 'none';

    notifs.forEach(function(n) {
        var tr = document.createElement('tr');
        tr.className = 'cbi-section-table-row';

        var tdSeq = document.createElement('td');
        tdSeq.className = 'cbi-section-table-cell';
        tdSeq.setAttribute('data-label', 'Sequence');
        tdSeq.textContent = n.seqNumber || '-';
        tr.appendChild(tdSeq);

        var tdIccid = document.createElement('td');
        tdIccid.className = 'cbi-section-table-cell';
        tdIccid.setAttribute('data-label', 'ICCID');
        tdIccid.textContent = n.iccid || '-';
        tr.appendChild(tdIccid);

        var tdOp = document.createElement('td');
        tdOp.className = 'cbi-section-table-cell';
        tdOp.setAttribute('data-label', 'Operation');
        tdOp.textContent = n.profileManagementOperation || '-';
        tr.appendChild(tdOp);

        var tdAddr = document.createElement('td');
        tdAddr.className = 'cbi-section-table-cell';
        tdAddr.setAttribute('data-label', 'Server');
        tdAddr.textContent = n.notificationAddress || '-';
        tr.appendChild(tdAddr);

        tbody.appendChild(tr);
    });
}

function clearNotifications() {
    if (!confirm('Clear all pending notifications on the eUICC card?\n(Offline operation — does not contact operators)')) return;

    hideNotifStatus();

    apiPost('notif_clear', {})
        .then(function(data) {
            if (data && data.payload && data.payload.code === 0) {
                showNotifSuccess('Notification queue cleared.');
                setTimeout(loadNotifications, 1000);
            } else {
                showNotifErrorFromData(data);
            }
        })
        .catch(function(e) {
            showNotifError(e.message || 'Failed to clear notifications');
        });
}

function processAllNotifications() {
    if (!confirm('Send all pending notifications to operators and remove them?\n\nThis requires an active internet connection.')) return;

    hideNotifStatus();
    showNotifSuccess('Processing notifications... This may take a minute.');

    apiPost('notif_process', {})
        .then(function(data) {
            if (data && data.payload) {
                if (data.payload.message === 'processing') {
                    showNotifSuccess('Sending notifications to operators...');
                    startLockPolling(function(result) {
                        if (result && result.success) {
                            showNotifSuccess(result.message || 'All notifications processed and removed.');
                        } else if (result && !result.success) {
                            showNotifError(result.message || 'Notification processing failed');
                        } else {
                            showNotifSuccess('Operation completed.');
                        }
                        setTimeout(loadNotifications, 1500);
                    });
                } else if (data.payload.code === 0) {
                    showNotifSuccess('Notifications processed.');
                    setTimeout(loadNotifications, 1500);
                } else {
                    showNotifErrorFromData(data);
                }
            }
        })
        .catch(function(e) {
            showNotifError(e.message || 'Failed to process notifications');
        });
}

/* ===== Status helpers ===== */
function hideNotifStatus() {
    var s = document.getElementById('notifications-success');
    var e = document.getElementById('notifications-error');
    if (s) s.style.display = 'none';
    if (e) e.style.display = 'none';
}

function showNotifSuccess(msg) {
    var el = document.getElementById('notifications-success');
    var span = document.getElementById('notifications-success-message');
    if (span) span.textContent = msg;
    if (el) el.style.display = 'block';
}

function showNotifError(msg) {
    var errDiv = document.getElementById('notifications-error');
    var span = document.getElementById('notifications-error-message');
    if (span) span.textContent = msg;
    if (errDiv) errDiv.style.display = 'block';
}

function showNotifErrorFromData(data) {
    var msg = 'Unknown error';
    if (data && data.payload) {
        msg = data.payload.message || msg;
        if (data.payload.data && data.payload.data.msg) msg += ': ' + data.payload.data.msg;
    }
    showNotifError(msg);
}

// Loaded by showTab() on first tab activation
