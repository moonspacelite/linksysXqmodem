/* lpac-esim-profiles.js — v3.0.1 */
'use strict';

function loadProfiles() {
    var loading = document.getElementById('profiles-loading');
    var content = document.getElementById('profiles-content');
    var errDiv  = document.getElementById('profiles-error');
    var noProf  = document.getElementById('no-profiles');
    if (loading) loading.style.display = 'block';
    if (content) content.style.display = 'none';
    if (errDiv)  errDiv.style.display  = 'none';

    apiGet('profiles')
        .then(function(data) {
            if (loading) loading.style.display = 'none';
            if (data && data.payload && data.payload.code === 0) {
                var profiles = data.payload.data;
                renderProfiles(profiles);
                if (content) content.style.display = '';
            } else {
                showProfilesError(data);
            }
        })
        .catch(function(e) {
            if (loading) loading.style.display = 'none';
            showProfilesErrorMsg(e.message || 'Network error');
        });
}

function renderProfiles(profiles) {
    var tbody  = document.getElementById('profiles-tbody');
    var noProf = document.getElementById('no-profiles');
    if (!tbody) return;

    tbody.innerHTML = '';

    if (!profiles || !Array.isArray(profiles) || profiles.length === 0) {
        if (noProf) noProf.style.display = 'block';
        return;
    }
    if (noProf) noProf.style.display = 'none';

    profiles.forEach(function(p) {
        var tr = document.createElement('tr');
        tr.className = 'cbi-section-table-row';

        // Profile Name
        var tdName = document.createElement('td');
        tdName.className = 'cbi-section-table-cell';
        tdName.setAttribute('data-label', 'Name');
        var nameSpan = document.createElement('span');
        nameSpan.className = 'esim-profile-name';
        nameSpan.textContent = p.profileName || p.serviceProviderName || '-';
        tdName.appendChild(nameSpan);
        if (p.profileNickname) {
            var nickSpan = document.createElement('span');
            nickSpan.className = 'esim-profile-nickname';
            nickSpan.textContent = ' (' + p.profileNickname + ')';
            tdName.appendChild(nickSpan);
        }
        tr.appendChild(tdName);

        // ICCID (masked for display)
        var tdIccid = document.createElement('td');
        tdIccid.className = 'cbi-section-table-cell';
        tdIccid.setAttribute('data-label', 'ICCID');
        tdIccid.textContent = maskIccid(p.iccid);
        tdIccid.title = p.iccid; // full ICCID on hover
        tdIccid.style.cursor = 'help';
        tr.appendChild(tdIccid);

        // Provider
        var tdProvider = document.createElement('td');
        tdProvider.className = 'cbi-section-table-cell';
        tdProvider.setAttribute('data-label', 'Provider');
        tdProvider.textContent = p.serviceProviderName || '-';
        tr.appendChild(tdProvider);

        // Status
        var tdStatus = document.createElement('td');
        tdStatus.className = 'cbi-section-table-cell';
        tdStatus.setAttribute('data-label', 'Status');
        tdStatus.style.textAlign = 'center';
        var badge = document.createElement('span');
        badge.className = 'esim-badge esim-badge-' + (p.profileState === 'enabled' ? 'enabled' : 'disabled');
        badge.textContent = p.profileState === 'enabled' ? 'Enabled' : 'Disabled';
        tdStatus.appendChild(badge);
        tr.appendChild(tdStatus);

        // Actions
        var tdActions = document.createElement('td');
        tdActions.className = 'cbi-section-table-cell';
        tdActions.setAttribute('data-label', 'Actions');
        tdActions.style.textAlign = 'center';

        if (p.profileState !== 'enabled') {
            var switchBtn = document.createElement('button');
            switchBtn.type = 'button';
            switchBtn.className = 'cbi-button cbi-button-apply';
            switchBtn.textContent = 'Switch';
            switchBtn.style.marginRight = '5px';
            switchBtn.onclick = (function(iccid, name) {
                return function() { switchProfile(iccid, name); };
            })(p.iccid, p.profileName || p.serviceProviderName);
            tdActions.appendChild(switchBtn);

            var delBtn = document.createElement('button');
            delBtn.type = 'button';
            delBtn.className = 'cbi-button cbi-button-remove';
            delBtn.textContent = 'Delete';
            delBtn.style.marginRight = '5px';
            delBtn.onclick = (function(iccid, name) {
                return function() { deleteProfile(iccid, name); };
            })(p.iccid, p.profileName || p.serviceProviderName);
            tdActions.appendChild(delBtn);
        } else {
            var disableBtn = document.createElement('button');
            disableBtn.type = 'button';
            disableBtn.className = 'cbi-button cbi-button-apply';
            disableBtn.textContent = 'Disable';
            disableBtn.style.marginRight = '5px';
            disableBtn.onclick = (function(iccid, name) {
                return function() { disableProfile(iccid, name); };
            })(p.iccid, p.profileName || p.serviceProviderName);
            tdActions.appendChild(disableBtn);

            // Placeholder to keep column width consistent with disabled rows
            var placeholder = document.createElement('button');
            placeholder.type = 'button';
            placeholder.className = 'cbi-button';
            placeholder.style.marginRight = '5px';
            placeholder.style.visibility = 'hidden';
            placeholder.textContent = 'Delete';
            tdActions.appendChild(placeholder);
        }

        var renBtn = document.createElement('button');
        renBtn.type = 'button';
        renBtn.className = 'cbi-button';
        renBtn.textContent = 'Rename';
        renBtn.onclick = (function(iccid, nick) {
            return function() { renameProfile(iccid, nick); };
        })(p.iccid, p.profileNickname || p.profileName || '');
        tdActions.appendChild(renBtn);

        tr.appendChild(tdActions);
        tbody.appendChild(tr);
    });
}

function switchProfile(iccid, name) {
    if (!confirm('Switch to profile "' + (name || iccid) + '"?\n\nThis will briefly disconnect the network interface during switching.')) {
        return;
    }

    clearProfileStatus();
    showProfileSuccess('Switching to profile... Please wait.');

    apiPost('switch', { iccid: iccid })
        .then(function(data) {
            if (data && data.payload) {
                if (data.payload.message === 'processing') {
                    showProfileSuccess('Profile switch initiated. Waiting for SIM refresh...');
                    startLockPolling(function(result) {
                        if (result && result.success) {
                            showProfileSuccess(result.message || 'Profile switch complete!');
                        } else if (result && !result.success) {
                            showProfileError(result.message || 'Profile switch failed');
                        } else {
                            showProfileSuccess('Operation completed. Refreshing...');
                        }
                        setTimeout(loadProfiles, 2000);
                    });
                } else if (data.payload.code === 0) {
                    showProfileSuccess('Profile switched successfully.');
                    setTimeout(loadProfiles, 2000);
                } else {
                    showProfileError(data.payload.message + (data.payload.data && data.payload.data.msg ? ': ' + data.payload.data.msg : ''));
                }
            }
        })
        .catch(function(e) {
            showProfileError(e.message || 'Failed to switch profile');
        });
}

function rebootModem() {
    if (!confirm('Reboot the modem?\n\nThis will temporarily disconnect mobile data.')) {
        return;
    }

    clearProfileStatus();
    showProfileSuccess('Rebooting modem...');

    apiPost('reboot_modem', {})
        .then(function(data) {
            if (data && data.payload && data.payload.message === 'processing') {
                showProfileSuccess('Modem reboot initiated. Waiting for recovery...');
                startLockPolling(function(result) {
                    if (result && result.success) {
                        showProfileSuccess(result.message || 'Modem reboot complete!');
                    } else if (result && !result.success) {
                        showProfileError(result.message || 'Modem reboot failed');
                    } else {
                        showProfileSuccess('Reboot completed.');
                    }
                    setTimeout(loadProfiles, 3000);
                });
            } else if (data && data.payload && data.payload.code === 0) {
                showProfileSuccess('Modem reboot initiated.');
            } else {
                showProfileError('Reboot failed: ' + (data && data.payload ? data.payload.message : 'Unknown error'));
            }
        })
        .catch(function(e) {
            showProfileError(e.message || 'Failed to reboot modem');
        });
}

function deleteProfile(iccid, name) {
    if (!confirm('DELETE profile "' + (name || iccid) + '"?\n\nThis action is IRREVERSIBLE!\nThe profile must be disabled before deletion.')) {
        return;
    }
    if (!confirm('Are you ABSOLUTELY SURE?\n\nICCID: ' + iccid + '\n\nThis cannot be undone.')) {
        return;
    }

    clearProfileStatus();
    showProfileSuccess('Deleting profile...');

    apiPost('delete', { iccid: iccid })
        .then(function(data) {
            if (data && data.payload && data.payload.code === 0) {
                showProfileSuccess('Profile deleted successfully.');
                setTimeout(loadProfiles, 1500);
            } else {
                var msg = 'Delete failed';
                if (data && data.payload) {
                    msg = data.payload.message || msg;
                    if (data.payload.data && data.payload.data.msg) msg += ': ' + data.payload.data.msg;
                }
                showProfileError(msg);
            }
        })
        .catch(function(e) {
            showProfileError(e.message || 'Failed to delete profile');
        });
}

function renameProfile(iccid, currentName) {
    var newName = prompt('Enter new nickname for profile:', currentName || '');
    if (newName === null) return; // cancelled
    newName = newName.trim();
    if (!newName) {
        alert('Nickname cannot be empty.');
        return;
    }
    if (newName.length > 64) {
        alert('Nickname too long (max 64 characters).');
        return;
    }

    clearProfileStatus();

    apiPost('nickname', { iccid: iccid, nickname: newName })
        .then(function(data) {
            if (data && data.payload && data.payload.code === 0) {
                showProfileSuccess('Profile renamed to "' + newName + '"');
                setTimeout(loadProfiles, 1000);
            } else {
                var msg = 'Rename failed';
                if (data && data.payload) {
                    msg = data.payload.message || msg;
                    if (data.payload.data && data.payload.data.msg) msg += ': ' + data.payload.data.msg;
                }
                showProfileError(msg);
            }
        })
        .catch(function(e) {
            showProfileError(e.message || 'Failed to rename profile');
        });
}

/* ===== ICCID masking ===== */
function maskIccid(iccid) {
    if (!iccid || iccid.length < 8) return iccid || '-';
    return iccid.substring(0, 6) + '****' + iccid.substring(iccid.length - 4);
}

/* ===== Status messages ===== */
function clearProfileStatus() {
    var s = document.getElementById('profile-notifications-success');
    var e = document.getElementById('profile-notifications-error');
    if (s) s.style.display = 'none';
    if (e) e.style.display = 'none';
}

function showProfileSuccess(msg) {
    var el = document.getElementById('profile-notifications-success');
    var span = document.getElementById('profile-notifications-success-message');
    if (span) span.textContent = msg;
    if (el) el.style.display = 'block';
}

function showProfileError(msg) {
    var el = document.getElementById('profile-notifications-error');
    var span = document.getElementById('profile-notifications-error-message');
    if (span) span.textContent = msg;
    if (el) el.style.display = 'block';
}

function showProfilesError(data) {
    var msg = 'Unknown error';
    if (data && data.payload) {
        msg = data.payload.message || msg;
        if (data.payload.data && data.payload.data.msg) msg += ': ' + data.payload.data.msg;
    }
    showProfilesErrorMsg(msg);
}

function showProfilesErrorMsg(msg) {
    var errDiv = document.getElementById('profiles-error');
    var span = document.getElementById('profiles-error-message');
    if (span) span.textContent = msg;
    if (errDiv) errDiv.style.display = 'block';
}

// Loaded by showTab() on first tab activation

function disableProfile(iccid, name) {
    if (!confirm('Disable profile "' + (name || iccid) + '"?\n\nWarning: The modem will lose network connection until another profile is enabled or switched.')) {
        return;
    }
    clearProfileStatus();
    showProfileSuccess('Disabling profile...');

    apiPost('disable', { iccid: iccid })
        .then(function(data) {
            if (data && data.payload && data.payload.code === 0) {
                if (data.payload.message === 'already_disabled') {
                    showProfileSuccess('Profile is already disabled.');
                } else {
                    showProfileSuccess('Profile disabled successfully.');
                }
                setTimeout(loadProfiles, 2000);
            } else if (data && data.payload) {
                var msg = data.payload.message || 'Unknown';
                if (data.payload.data && data.payload.data.msg) msg += ': ' + data.payload.data.msg;
                showProfileError('Disable failed: ' + msg);
            }
        })
        .catch(function(e) {
            showProfileError(e.message || 'Failed to disable profile');
        });
}
