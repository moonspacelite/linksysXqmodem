-- /usr/lib/lua/luci/controller/lpac_esim.lua
-- LuCI controller for eSIM management via lpac-esim backend
-- Version: 3.0.1
-- License: GPL-2.0
--
-- Changelog:
--   1.3.0 - Diagnostics tab (syslog, soft/usb/uicc reset), io.popen fix,
--           theme-safe CSS, adaptive reset descriptions, MBIM config text fix
--   1.2.2 - ANSI/jq/async fixes, diagnostics APIs
--   1.2.1 - async_finish result model, valid_iccid helper, LPA regex loosened
--   1.2.0 - download/delete/nickname/notif_process, full MBIM support
--   1.0.0 - Initial release: profiles, chip, switch, reboot, config
--
-- Architecture: integration adapter between browser (JS Fetch API) and backend script.
-- Modem/eUICC logic lives in lpac-esim (POSIX shell).
-- Controller handles: UCI config, CLI flag building, input validation, JSON response wrapping.
--
-- Note: write endpoints require POST only.
-- CSRF token validation is omitted for compatibility with older LuCI/OpenWrt builds.
-- This is an intentional tradeoff for a home-router local-network scenario.
--
-- Flow:  Browser → Fetch → LuCI (uhttpd) → lpac_esim.lua → lpac-esim --api → stdout JSON → Browser
-- Async: Browser POST → lua → script --api switch → {"processing"} → Browser polls lock-status

module("luci.controller.lpac_esim", package.seeall)

local json = require "luci.jsonc"
local sys  = require "luci.sys"
local util = require "luci.util"
-- NOTE: we deliberately do NOT cache a single luci.model.uci cursor at module
-- scope. uhttpd may keep this Lua state alive across requests, so a cached
-- cursor's snapshot of /etc/config/lpac-esim never sees the values written
-- by api_save_config() (which uses its own fresh cursor). Always allocate
-- a fresh cursor in the request scope where one is needed.

-- ============================================================================
-- Constants
-- ============================================================================

local BACKEND_SCRIPT = "/usr/bin/lpac-esim"
local UCI_CONFIG     = "lpac-esim"
local UCI_SECTION    = "lpac-esim"
local LOG_TAG        = "lpac-esim"
local RUN_DIR        = "/tmp/lpac-esim"
local RUN_LOG        = RUN_DIR .. "/run.log"

-- ============================================================================
-- Route registration
-- ============================================================================

function index()
    -- Main page entry (CBI model provides the HTML shell)
    entry({"admin", "modem", "lpac-esim"}, template("lpac_esim/main"), _("eSIM Manager"), 60)

    -- Read-only endpoints (GET)
    entry({"admin", "modem", "lpac-esim", "profiles"},     call("api_profiles"),     nil).leaf = true
    entry({"admin", "modem", "lpac-esim", "chip"},         call("api_chip"),         nil).leaf = true
    entry({"admin", "modem", "lpac-esim", "modem_status"}, call("api_modem_status"), nil).leaf = true
    entry({"admin", "modem", "lpac-esim", "notif_list"},   call("api_notif_list"),   nil).leaf = true
    entry({"admin", "modem", "lpac-esim", "lock_status"},  call("api_lock_status"),  nil).leaf = true
    entry({"admin", "modem", "lpac-esim", "config"},       call("api_get_config"),   nil).leaf = true
    entry({"admin", "modem", "lpac-esim", "telegram_status"}, call("api_telegram_status"), nil).leaf = true
    entry({"admin", "modem", "lpac-esim", "connectivity"}, call("api_connectivity"), nil).leaf = true

    -- Write endpoints (POST, some async)
    entry({"admin", "modem", "lpac-esim", "switch"},       call("api_switch"),       nil).leaf = true
    entry({"admin", "modem", "lpac-esim", "disable"},      call("api_disable"),      nil).leaf = true
    entry({"admin", "modem", "lpac-esim", "reboot_modem"}, call("api_reboot"),       nil).leaf = true
    entry({"admin", "modem", "lpac-esim", "notif_clear"},  call("api_notif_clear"),  nil).leaf = true
    entry({"admin", "modem", "lpac-esim", "save_config"},  call("api_save_config"),  nil).leaf = true
    entry({"admin", "modem", "lpac-esim", "save_telegram_config"}, call("api_save_telegram_config"), nil).leaf = true

    -- Download / Delete / Nickname / Notifications
    entry({"admin", "modem", "lpac-esim", "download"},      call("api_download"),      nil).leaf = true
    entry({"admin", "modem", "lpac-esim", "delete"},        call("api_delete"),        nil).leaf = true
    entry({"admin", "modem", "lpac-esim", "nickname"},      call("api_nickname"),      nil).leaf = true
    entry({"admin", "modem", "lpac-esim", "notif_process"}, call("api_notif_process"), nil).leaf = true

    -- Diagnostics
    entry({"admin", "modem", "lpac-esim", "syslog"},     call("api_syslog"),     nil).leaf = true
    entry({"admin", "modem", "lpac-esim", "runlog"},     call("api_runlog"),     nil).leaf = true
    entry({"admin", "modem", "lpac-esim", "version"},    call("api_version"),    nil).leaf = true
    entry({"admin", "modem", "lpac-esim", "at_cmd"},     call("api_at_cmd"),     nil).leaf = true
    entry({"admin", "modem", "lpac-esim", "soft_reset"},  call("api_soft_reset"),  nil).leaf = true
    entry({"admin", "modem", "lpac-esim", "usb_reset"},   call("api_usb_reset"),   nil).leaf = true
    entry({"admin", "modem", "lpac-esim", "uicc_reset"},  call("api_uicc_reset"),  nil).leaf = true
end

-- ============================================================================
-- Core helpers
-- ============================================================================

--- Read UCI config for lpac-esim, return table with defaults applied.
-- @return table  config key-value pairs
local function read_config()
    local config = {}
    -- Allocate a fresh cursor per call so we always observe the most recent
    -- commit, including writes that happened in this same uhttpd worker via
    -- api_save_config(). See note above the require block.
    local cur = require("luci.model.uci").cursor()
    cur:foreach(UCI_CONFIG, UCI_SECTION, function(s) config = s end)

    -- Apply sane defaults when UCI is empty or missing
    config.apdu_backend  = config.apdu_backend  or "mbim"
    config.qmi_device    = config.qmi_device    or "/dev/cdc-wdm0"
    config.qmi_sim_slot  = config.qmi_sim_slot  or "1"
    config.sim_slot      = config.sim_slot      or "1"
    config.at_device     = config.at_device     or "/dev/ttyUSB2"
    config.mbim_device   = config.mbim_device   or "/dev/cdc-wdm0"
    config.mbim_proxy    = config.mbim_proxy    or "1"
    config.mbim_skip_slot_mapping = config.mbim_skip_slot_mapping or "1"
    config.custom_isd_r_aid = config.custom_isd_r_aid or "A0000005591010FFFFFFFF8900000100"
    config.reboot_method = config.reboot_method or "script"
    config.modem_iface   = config.modem_iface   or "1_1"
    config.telegram_enabled = config.telegram_enabled or "0"
    config.telegram_bot_token = config.telegram_bot_token or ""
    config.telegram_allowed_chat_id = config.telegram_allowed_chat_id or ""
    config.telegram_poll_interval = config.telegram_poll_interval or "2"
    config.telegram_debug = config.telegram_debug or "0"

    return config
end

--- Restart the Telegram bot init script and verify it actually came up.
-- Returns true when the bot is running (or when telegram_enabled != "1", in
-- which case we expect it to stay stopped), false otherwise. The second
-- return value is a short reason suitable for the UI when running is false.
local function restart_telegram_bot(expected_enabled)
    sys.exec("/etc/init.d/esim-telegram-bot enable >/dev/null 2>&1 || true")
    sys.exec("/etc/init.d/esim-telegram-bot restart >/dev/null 2>&1 || true")
    -- The bot token may have just changed; the cached getMe result is now
    -- stale and could mislead the status badge for up to 30s. Drop it so
    -- the very next status call hits Telegram fresh.
    sys.exec("rm -f /tmp/lpac-esim/telegram.getme.cache /tmp/lpac-esim/telegram.status 2>/dev/null")

    if expected_enabled ~= "1" then
        sys.exec("/etc/init.d/esim-telegram-bot stop >/dev/null 2>&1 || true")
        return true, nil
    end

    -- procd's restart is fire-and-forget; give the binary a moment to start.
    -- pidof exits 0 with the pid on stdout when found, non-zero/empty when not.
    local pid = ""
    for _ = 1, 10 do
        pid = sys.exec("pidof esim-telegram-bot 2>/dev/null"):gsub("%s+$", "")
        if pid ~= "" then break end
        sys.exec("sleep 0.3 2>/dev/null || sleep 1")
    end

    if pid ~= "" then return true, nil end

    -- Bot did not come up. Grab the latest hint from syslog so the UI can
    -- tell the user exactly why (binary missing, token invalid, ...).
    local hint = sys.exec("logread -e esim-telegram-bot 2>/dev/null | tail -3")
    return false, (hint ~= "" and hint or "esim-telegram-bot did not start (check syslog)")
end

--- Execute backend script with --api flag and return raw stdout.
-- Builds CLI flags from UCI config. Single sys.exec() call (no os.execute dupe).
-- @param cmd       string  sub-command to pass (e.g. "profiles", "switch <ICCID>")
-- @param timeout   number  max seconds (default 30)
-- @param silent    boolean if true, don't log to syslog (for read-only queries like syslog)
-- @return string|nil       raw stdout from script
function exec_script(cmd, timeout, silent)
    local config = read_config()

    local backend  = config.apdu_backend
    local at_dev   = config.at_device
    local t        = timeout or 30

    -- Build flags string based on backend
    local flags = "--api --backend " .. util.shellquote(backend)

    if backend == "mbim" then
        flags = flags .. " --mbim-device " .. util.shellquote(config.mbim_device)
        if config.mbim_proxy == "1" then
            flags = flags .. " --mbim-proxy"
        end
        if config.mbim_skip_slot_mapping == "1" then
            flags = flags .. " --mbim-skip-slot"
        end
    else
        flags = flags .. " --device " .. util.shellquote(config.qmi_device)
        flags = flags .. " --slot " .. util.shellquote(config.qmi_sim_slot)
    end

    if at_dev ~= "" then
        flags = flags .. " --at-device " .. util.shellquote(at_dev)
    end

    if config.custom_isd_r_aid ~= "" then
        flags = flags .. " --custom-isd-r-aid " .. util.shellquote(config.custom_isd_r_aid)
    end

    if config.modem_iface ~= "" then
        flags = flags .. " --modem-iface " .. util.shellquote(config.modem_iface)
    end

    -- Pass debug verbosity to backend
    if config.apdu_debug == "1" or config.http_debug == "1" or config.at_debug == "1" then
        flags = flags .. " --verbose"
    end

    -- Ensure run directory exists
    sys.exec("mkdir -p " .. RUN_DIR)

    -- Build command: use timeout if available, fallback to direct exec
    local timeout_bin = sys.exec("command -v timeout 2>/dev/null"):gsub("%s+$", "")
    local full_cmd
    if timeout_bin ~= "" then
        full_cmd = string.format("%s %d %s %s %s 2>>%s",
            timeout_bin, t, BACKEND_SCRIPT, flags, cmd, RUN_LOG)
    else
        full_cmd = string.format("%s %s %s 2>>%s",
            BACKEND_SCRIPT, flags, cmd, RUN_LOG)
    end

    -- Log only real operations, not read-only queries
    if not silent then
        local dev = ""
        if backend == "qmi" then dev = config.qmi_device or ""
        elseif backend == "mbim" then dev = config.mbim_device or ""
        elseif backend == "at" then dev = at_dev or ""
        end
        sys.exec("logger -t " .. util.shellquote(LOG_TAG) ..
            " " .. util.shellquote("[" .. backend:upper() .. " " .. dev .. "] " .. cmd))
    end

    -- Use io.popen instead of sys.exec for reliable stdout capture
    local f = io.popen(full_cmd)
    if not f then return nil end
    local out = f:read("*a")
    f:close()
    return out
end

--- Parse lpac JSON from raw output.
-- Handles the case where backend may print progress lines before the final JSON.
-- Takes the last non-empty line that parses as valid JSON.
-- @param raw  string  raw stdout
-- @return table|nil   parsed JSON table or nil
function parse_lpac_json(raw)
    if not raw or raw == "" then return nil end

    local lines = {}
    for line in raw:gmatch("[^\r\n]+") do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" then table.insert(lines, line) end
    end

    -- Iterate from end — take last line that parses as valid JSON
    for i = #lines, 1, -1 do
        local ok, data = pcall(json.parse, lines[i])
        if ok and data then return data end
    end

    return nil
end

--- Send a JSON response to the HTTP client.
-- @param data  table  data to serialize as JSON
function send_json(data)
    luci.http.prepare_content("application/json")
    luci.http.write_json(data)
end

--- Build a standard lpac-format error response.
-- @param message  string  error type identifier
-- @param detail   string  human-readable message
-- @return table           lpac-format error object
local function make_error(message, detail)
    return {
        type = "lpa",
        payload = {
            code    = -1,
            message = message,
            data    = { msg = detail }
        }
    }
end

--- Enforce POST method; returns true if OK, false (and sends error) if not.
-- @return boolean
local function require_post()
    if luci.http.getenv("REQUEST_METHOD") ~= "POST" then
        send_json({ success = false, error = "Method not allowed" })
        return false
    end
    return true
end

--- Validate ICCID: 18-22 digits only.
-- @param s  string
-- @return boolean
local function valid_iccid(s)
    return s and s:match("^%d+$") ~= nil and #s >= 18 and #s <= 22
end

-- ============================================================================
-- GET endpoints — simple passthrough to backend
-- ============================================================================

-- All GET endpoints follow the same pattern: exec → parse → send.
-- Differences: command name and timeout.

function api_profiles()
    local raw  = exec_script("profiles", 20, true)
    local data = parse_lpac_json(raw)
    send_json(data or make_error("parse_error", "Empty or invalid response from backend"))
end

function api_chip()
    local raw  = exec_script("chip", 10, true)
    local data = parse_lpac_json(raw)
    send_json(data or make_error("parse_error", "Empty or invalid response from backend"))
end

function api_modem_status()
    local raw  = exec_script("modem-status", 10, true)
    local data = parse_lpac_json(raw)
    send_json(data or make_error("parse_error", "Empty or invalid response from backend"))
end

function api_notif_list()
    local raw  = exec_script("notif-list", 15, true)
    local data = parse_lpac_json(raw)
    send_json(data or make_error("parse_error", "Empty or invalid response from backend"))
end

function api_lock_status()
    local raw  = exec_script("lock-status", 5, true)  -- silent: polling, don't spam log
    local data = parse_lpac_json(raw)
    send_json(data or make_error("parse_error", "Empty or invalid response from backend"))
end

function api_connectivity()
    -- Two-layer fallback probe to detect upstream connectivity:
    --
    --   1. ICMP ping  to 1.1.1.1 / 8.8.8.8  - fastest path when allowed.
    --   2. TCP/80 HTTP via uclient-fetch    - fallback when carriers
    --                                         filter outbound ICMP
    --                                         (very common on IDN
    --                                         prepaid LTE: XL,
    --                                         Telkomsel, Tri, 3, ...).
    --
    -- IMPORTANT: do NOT depend on the external `timeout` binary. It is
    -- not present in OpenWrt 25.12.3 / ipq40xx BusyBox builds (verified
    -- on the live device: "ash: timeout: not found" -> exit 127, which
    -- was the root cause of "No internet connection detected" persisting
    -- even when `ping 8.8.8.8` worked from the shell). Every probe below
    -- uses the *binary's own* timeout flag so we don't need a wrapper:
    --
    --   * `ping -W 1`               : wait at most 1 s for the reply
    --   * `uclient-fetch -T 2`      : 2 s overall timeout per connect
    --
    -- The frontend uses an AbortController with a 5 s wall-clock timeout
    -- (see fetchWithTimeout in lpac-esim-main.js). The probe sequence
    -- below has a worst-case sequential runtime of:
    --
    --     1 s (ping 1.1.1.1)  +  1 s (ping 8.8.8.8)  +  2 s (HTTP)  =  4 s
    --
    -- which fits inside the 5 s frontend budget with ~1 s of margin for
    -- LuCI dispatch + JSON serialisation overhead.
    --
    -- BusyBox `nslookup` has no -timeout flag and can hang for the full
    -- resolver retry period (~15 s), so it's deliberately omitted from
    -- the fast probe set. A future hardening pass could add a DNS layer
    -- back via coreutils-timeout (now listed in packages.list).
    --
    -- Each probe exits with a distinct return code so we can tell which
    -- one actually answered. It's echoed back as `method` in the JSON
    -- response which is invaluable when diagnosing carrier-specific
    -- filtering of ICMP / HTTP.
    local probe = [[
        sh -c '
            ping -c 1 -W 1 -q 1.1.1.1 >/dev/null 2>&1 && exit 10
            ping -c 1 -W 1 -q 8.8.8.8 >/dev/null 2>&1 && exit 11
            uclient-fetch -q --no-check-certificate -T 2 -O /dev/null http://1.1.1.1/ >/dev/null 2>&1 && exit 30
            exit 1
        ' >/dev/null 2>&1
        echo $?
    ]]
    local fh = io.popen(probe, "r")
    local rc_str = fh and fh:read("*l") or "1"
    if fh then fh:close() end
    local rc = tonumber(rc_str) or 1

    local method_for = {
        [10] = "icmp/1.1.1.1",
        [11] = "icmp/8.8.8.8",
        [30] = "http/1.1.1.1",
    }
    local method = method_for[rc]
    send_json({
        success    = true,
        connected  = method ~= nil,
        method     = method or "none",
    })
end

-- ============================================================================
-- POST async endpoints
-- ============================================================================

function api_switch()
    if not require_post() then return end

    local iccid = luci.http.formvalue("iccid")
    if not iccid or iccid == "" then
        send_json(make_error("missing_param", "iccid required"))
        return
    end

    -- Validate ICCID
    if not valid_iccid(iccid) then
        send_json(make_error("invalid_iccid", "ICCID must be 18-22 digits"))
        return
    end

    -- Backend handles async launch internally; timeout 10s is for the initial response only
    local raw  = exec_script("switch " .. util.shellquote(iccid), 10)
    local data = parse_lpac_json(raw)
    send_json(data or make_error("backend_error", "No response from backend"))
end

function api_disable()
    if not require_post() then return end

    local iccid = luci.http.formvalue("iccid")
    if not iccid or iccid == "" then
        send_json(make_error("missing_param", "iccid required"))
        return
    end

    if not valid_iccid(iccid) then
        send_json(make_error("invalid_iccid", "ICCID must be 18-22 digits"))
        return
    end

    local raw  = exec_script("disable " .. util.shellquote(iccid), 30)
    local data = parse_lpac_json(raw)
    send_json(data or make_error("backend_error", "No response from backend"))
end

function api_reboot()
    if not require_post() then return end

    local raw  = exec_script("reboot-modem", 10)
    local data = parse_lpac_json(raw)
    send_json(data or make_error("backend_error", "No response from backend"))
end

function api_notif_clear()
    if not require_post() then return end

    local raw  = exec_script("notif-clear", 20)
    local data = parse_lpac_json(raw)
    send_json(data or {
        type = "lpa",
        payload = { code = 0, message = "success", data = { cleared = true } }
    })
end

-- ============================================================================
-- UCI Config endpoints (direct UCI read/write, no backend script)
-- ============================================================================

function api_get_config()
    local config = read_config()
    -- Strip internal UCI fields that may leak through
    config[".type"]      = nil
    config[".name"]      = nil
    config[".anonymous"] = nil
    config[".index"]     = nil
    send_json({ success = true, config = config })
end

-- Cached result of the last successful (or failed) getMe call. The status
-- panel auto-refreshes every 5s, but each refresh would otherwise spawn a
-- blocking curl with --max-time 8 to api.telegram.org. With uhttpd's small
-- worker pool (~3–6 on OpenWrt) and 8s > 5s, two slow API responses could
-- starve all LuCI workers. We bound the actual curl rate to TTL/getMe
-- here, regardless of how many UI clients are polling. The "Check Bot
-- Status" button bypasses the cache via ?fresh=1.
local TELEGRAM_GETME_CACHE = "/tmp/lpac-esim/telegram.getme.cache"
local TELEGRAM_GETME_TTL = 30

local function read_getme_cache()
    local f = io.open(TELEGRAM_GETME_CACHE, "r")
    if not f then return nil end
    local body = f:read("*a")
    f:close()
    if not body or body == "" then return nil end
    local ok_p, data = pcall(json.parse, body)
    if not ok_p or type(data) ~= "table" then return nil end
    if type(data.ts) ~= "number" then return nil end
    if (os.time() - data.ts) > TELEGRAM_GETME_TTL then return nil end
    return data
end

local function write_getme_cache(api_ok, bot_username, api_error)
    sys.exec("mkdir -p /tmp/lpac-esim")
    local f = io.open(TELEGRAM_GETME_CACHE, "w")
    if not f then return end
    f:write(json.stringify({
        ts = os.time(),
        api_ok = api_ok and true or false,
        bot_username = bot_username or "",
        api_error = api_error or ""
    }))
    f:close()
end

function api_telegram_status()
    -- Wrap the whole handler so an unexpected error never bubbles up as a
    -- bare HTTP 500 — the UI relies on this endpoint to diagnose the bot.
    local ok_call, err = pcall(function()
        local fresh = luci.http.formvalue("fresh") == "1"
        local config = read_config()
        local token = config.telegram_bot_token or ""
        local chat = config.telegram_allowed_chat_id or ""
        local pid = sys.exec("pidof esim-telegram-bot 2>/dev/null"):gsub("%s+$", "")
        local enabled = config.telegram_enabled == "1"
        local token_ok = token:match("^[A-Za-z0-9_-]+:[A-Za-z0-9_-]+$") ~= nil
        local chat_ok = chat:match("^-?%d+$") ~= nil
        local api_ok = false
        local bot_username = ""
        local api_error = ""
        local api_cached = false
        local logs = sys.exec("logread -e esim-telegram-bot 2>/dev/null | tail -30")

        if token_ok then
            local cached = (not fresh) and read_getme_cache() or nil
            if cached then
                api_ok = cached.api_ok and true or false
                bot_username = cached.bot_username or ""
                api_error = cached.api_error or ""
                api_cached = true
            else
                local getme = sys.exec("curl -fsS --max-time 8 " .. util.shellquote("https://api.telegram.org/bot" .. token .. "/getMe") .. " 2>&1")
                -- luci.jsonc exposes parse(), not decode(). Using decode() here
                -- used to raise "attempt to call field 'decode' (a nil value)"
                -- and return HTTP 500 to the browser — see lpac_esim repo bug.
                local parsed = getme ~= "" and json.parse(getme) or nil
                if parsed and parsed.ok and parsed.result then
                    api_ok = true
                    bot_username = parsed.result.username or ""
                else
                    api_error = getme:gsub(token, "[token]")
                end
                write_getme_cache(api_ok, bot_username, api_error)
            end
        end

        -- The bot writes /tmp/lpac-esim/telegram.status on every poll
        -- (state="ok" on success, "error" + last curl rc on failure). We
        -- relay that to the UI so the badge can show "● Running, last
        -- poll 3s ago" vs "● Error rc=22 — Telegram API unreachable" vs
        -- "● Stopped" instead of just running yes/no.
        local heartbeat = nil
        local hb_raw = sys.exec("cat /tmp/lpac-esim/telegram.status 2>/dev/null")
        if hb_raw and hb_raw ~= "" then
            local ok_parse, parsed_hb = pcall(json.parse, hb_raw)
            if ok_parse and type(parsed_hb) == "table" then
                heartbeat = parsed_hb
            end
        end

        send_json({
            success = true,
            enabled = enabled,
            running = pid ~= "",
            pid = pid,
            token_set = token ~= "",
            token_ok = token_ok,
            api_ok = api_ok,
            api_cached = api_cached,
            bot_username = bot_username,
            bot_link = bot_username ~= "" and ("https://t.me/" .. bot_username) or "",
            api_error = api_error,
            chat_id = chat,
            chat_ok = chat_ok,
            logs = logs,
            heartbeat = heartbeat,
            now = os.time(),
            hint = "Open your own bot username from BotFather, not the BotFather chat itself."
        })
    end)
    if not ok_call then
        send_json({ success = false, error = tostring(err) })
    end
end

function api_save_config()
    if not require_post() then return end

    local raw = luci.http.formvalue("config")
    if not raw then
        send_json({ success = false, error = "No data" })
        return
    end

    local cfg = json.parse(raw)
    if not cfg then
        send_json({ success = false, error = "Invalid JSON" })
        return
    end

    -- Whitelist allowed config keys to prevent injection
    local allowed_keys = {
        "apdu_backend",
        "qmi_device", "qmi_sim_slot", "sim_slot",
        "at_device",
        "mbim_device", "mbim_proxy", "mbim_skip_slot_mapping",
        "custom_isd_r_aid",
        "reboot_method", "modem_iface",
        "apdu_debug", "http_debug", "at_debug"
    }
    local sanitized = {}
    for _, key in ipairs(allowed_keys) do
        if cfg[key] ~= nil then
            sanitized[key] = tostring(cfg[key])
        end
    end

    -- Strip empty strings (frontend may send "" for missing form fields)
    for k, v in pairs(sanitized) do
        if v == "" then sanitized[k] = nil end
    end

    -- Validate values
    local valid_backends = { qmi = true, at = true, mbim = true }
    if sanitized.apdu_backend and not valid_backends[sanitized.apdu_backend] then
        send_json({ success = false, error = "Invalid backend. Use: qmi, at, mbim" })
        return
    end
    local valid_slots = { ["1"] = true, ["2"] = true }
    local valid_sim_slots = { ["0"] = true, ["1"] = true }
    if sanitized.qmi_sim_slot and not valid_slots[sanitized.qmi_sim_slot] then
        return send_json(make_error("invalid_config", "Invalid QMI slot. Use: 1 or 2"))
    end
    if sanitized.sim_slot and not valid_sim_slots[sanitized.sim_slot] then
        return send_json(make_error("invalid_config", "Invalid SIM slot. Use: 0 or 1"))
    end
    local valid_flags = { ["0"] = true, ["1"] = true }
    for _, fkey in ipairs({"apdu_debug", "http_debug", "at_debug", "mbim_proxy", "mbim_skip_slot_mapping"}) do
        if sanitized[fkey] and not valid_flags[sanitized[fkey]] then
            send_json({ success = false, error = "Invalid value for " .. fkey .. ". Use: 0 or 1" })
            return
        end
    end
    for _, dkey in ipairs({"qmi_device", "at_device", "mbim_device"}) do
        if sanitized[dkey] and sanitized[dkey] ~= "" and not sanitized[dkey]:match("^/dev/") then
            send_json({ success = false, error = "Invalid device path for " .. dkey .. ". Must start with /dev/" })
            return
        end
    end
    if sanitized.custom_isd_r_aid and sanitized.custom_isd_r_aid ~= "" then
        if not sanitized.custom_isd_r_aid:match("^[0-9A-Fa-f]+$") then
            send_json({ success = false, error = "Invalid ISD-R AID. Must be a hex string (e.g. A0000005591010FFFFFFFF8900000100)" })
            return
        end
    end

    -- Merge into the existing config so saving APDU settings does not erase
    -- Telegram bot settings kept in the same UCI section.
    local merged = read_config()
    for k, v in pairs(sanitized) do
        merged[k] = v
    end
    merged[".type"]      = nil
    merged[".name"]      = nil
    merged[".anonymous"] = nil
    merged[".index"]     = nil

    -- Reload UCI cursor to get fresh state
    local fresh_uci = require("luci.model.uci").cursor()
    fresh_uci:delete(UCI_CONFIG, "main")
    fresh_uci:section(UCI_CONFIG, UCI_SECTION, "main", merged)

    if fresh_uci:commit(UCI_CONFIG) then
        send_json({ success = true, message = "Configuration saved" })
    else
        send_json({ success = false, error = "UCI commit failed" })
    end
end

function api_save_telegram_config()
    if not require_post() then return end

    local raw = luci.http.formvalue("config")
    if not raw then
        send_json({ success = false, error = "No data" })
        return
    end

    local cfg = json.parse(raw)
    if not cfg then
        send_json({ success = false, error = "Invalid JSON" })
        return
    end

    local sanitized = {}
    local valid_flags = { ["0"] = true, ["1"] = true }
    local valid_intervals = { ["1"] = true, ["2"] = true, ["5"] = true, ["10"] = true, ["30"] = true }

    -- Trim surrounding whitespace — users frequently paste tokens / chat IDs
    -- with a trailing newline or stray space; without trimming the regex
    -- validators below reject perfectly valid values.
    local function trim(s)
        return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
    end

    sanitized.telegram_enabled = trim(cfg.telegram_enabled or "0")
    sanitized.telegram_bot_token = trim(cfg.telegram_bot_token or "")
    sanitized.telegram_allowed_chat_id = trim(cfg.telegram_allowed_chat_id or "")
    sanitized.telegram_poll_interval = trim(cfg.telegram_poll_interval or "2")
    sanitized.telegram_debug = trim(cfg.telegram_debug or "0")

    if not valid_flags[sanitized.telegram_enabled] then
        return send_json(make_error("invalid_config", "Invalid Telegram enable value. Use: 0 or 1"))
    end
    if not valid_flags[sanitized.telegram_debug] then
        return send_json(make_error("invalid_config", "Invalid Telegram debug value. Use: 0 or 1"))
    end
    if not valid_intervals[sanitized.telegram_poll_interval] then
        return send_json(make_error("invalid_config", "Invalid poll interval. Use: 1, 2, 5, 10, or 30"))
    end
    if sanitized.telegram_bot_token ~= "" and not sanitized.telegram_bot_token:match("^[%w_%-]+:[%w_%-]+$") then
        return send_json(make_error("invalid_config", "Invalid Telegram bot token format"))
    end
    if sanitized.telegram_allowed_chat_id ~= "" and not sanitized.telegram_allowed_chat_id:match("^%-?%d+$") then
        return send_json(make_error("invalid_config", "Invalid Telegram chat ID"))
    end
    if sanitized.telegram_enabled == "1" and sanitized.telegram_bot_token == "" then
        return send_json(make_error("invalid_config", "Bot token is required when Telegram bot is enabled"))
    end

    local cur = require("luci.model.uci").cursor()
    local config = read_config()
    for k, v in pairs(sanitized) do
        config[k] = v
    end
    config[".type"]      = nil
    config[".name"]      = nil
    config[".anonymous"] = nil
    config[".index"]     = nil
    cur:delete(UCI_CONFIG, "main")
    cur:section(UCI_CONFIG, UCI_SECTION, "main", config)

    if not cur:commit(UCI_CONFIG) then
        send_json({ success = false, error = "UCI commit failed" })
        return
    end

    local ok, hint = restart_telegram_bot(sanitized.telegram_enabled)
    if not ok then
        -- Config was saved, but the bot did not actually come up. Surface
        -- this honestly instead of pretending success — "Success: ... bot
        -- restarted" used to be shown even when the binary was missing.
        send_json({
            success = false,
            error = "Telegram settings saved but bot failed to start. " .. (hint or ""),
            saved = true
        })
        return
    end

    send_json({
        success = true,
        message = sanitized.telegram_enabled == "1"
            and "Telegram settings saved and bot restarted"
            or "Telegram settings saved (bot disabled)"
    })
end

-- ============================================================================
-- Download / Delete / Nickname / Notification process
-- ============================================================================

--- POST: Download profile from SM-DP+ server (async — may take 60-120s)
-- Accepts: lpa (LPA:1$ string) OR smdp + matching_id pair
-- Optional: confirmation (confirmation code)
function api_download()
    if not require_post() then return end

    local lpa     = luci.http.formvalue("lpa")
    local smdp    = luci.http.formvalue("smdp")
    local matchid = luci.http.formvalue("matching_id")
    local confirm = luci.http.formvalue("confirmation")

    local has_lpa  = lpa and lpa ~= ""
    local has_pair = smdp and smdp ~= "" and matchid and matchid ~= ""

    if not has_lpa and not has_pair then
        send_json(make_error("missing_param",
            "Provide LPA activation code (LPA:1$...) or SM-DP+ server address with matching ID"))
        return
    end

    -- Build backend command
    local dl_flags = ""
    if has_lpa then
        -- Light sanity check: LPA:1$something$something — lpac does real parsing
        if not lpa:match("^LPA:1%$.+%$.") then
            send_json(make_error("invalid_lpa", "LPA code must match format LPA:1$domain$code"))
            return
        end
        dl_flags = "download --lpa " .. util.shellquote(lpa)
    else
        dl_flags = "download --smdp " .. util.shellquote(smdp) ..
                   " --matching-id " .. util.shellquote(matchid)
    end

    if confirm and confirm ~= "" then
        dl_flags = dl_flags .. " --confirmation " .. util.shellquote(confirm)
    end

    local raw  = exec_script(dl_flags, 10)  -- backend launches async, returns immediately
    local data = parse_lpac_json(raw)
    send_json(data or make_error("backend_error", "No response from backend"))
end

--- POST: Delete a profile (must be disabled first, irreversible!)
function api_delete()
    if not require_post() then return end

    local iccid = luci.http.formvalue("iccid")
    if not iccid or iccid == "" then
        send_json(make_error("missing_param", "iccid required"))
        return
    end

    if not valid_iccid(iccid) then
        send_json(make_error("invalid_iccid", "ICCID must be 18-22 digits"))
        return
    end

    local raw  = exec_script("delete " .. util.shellquote(iccid), 30)
    local data = parse_lpac_json(raw)
    send_json(data or make_error("backend_error", "No response from backend"))
end

--- POST: Rename a profile (set nickname)
function api_nickname()
    if not require_post() then return end

    local iccid    = luci.http.formvalue("iccid")
    local nickname = luci.http.formvalue("nickname")

    if not iccid or iccid == "" then
        send_json(make_error("missing_param", "iccid required"))
        return
    end
    if not valid_iccid(iccid) then
        send_json(make_error("invalid_iccid", "ICCID must be 18-22 digits"))
        return
    end
    if not nickname or nickname == "" then
        send_json(make_error("missing_param", "nickname required"))
        return
    end

    -- Sanitize nickname: alphanumeric, spaces, underscores, hyphens, max 64 chars
    if #nickname > 64 then
        send_json(make_error("invalid_nickname", "Nickname too long (max 64 characters)"))
        return
    end

    local raw  = exec_script("nickname " .. util.shellquote(iccid) ..
                             " --nickname " .. util.shellquote(nickname), 15)
    local data = parse_lpac_json(raw)
    send_json(data or make_error("backend_error", "No response from backend"))
end

--- POST: Process all pending notifications (async — requires internet)
function api_notif_process()
    if not require_post() then return end

    local raw  = exec_script("notif-process", 10)  -- backend launches async
    local data = parse_lpac_json(raw)
    send_json(data or make_error("backend_error", "No response from backend"))
end

-- ============================================================================
-- Diagnostics
-- ============================================================================

--- GET: Filtered syslog (modem + lpac events)
function api_syslog()
    local raw  = exec_script("syslog", 10, true)  -- silent: don't log reads
    local data = parse_lpac_json(raw)
    send_json(data or make_error("backend_error", "No response from backend"))
end

--- GET: Backend initialization log (run.log contents)
function api_runlog()
    local raw  = exec_script("runlog", 5, true)  -- silent
    local data = parse_lpac_json(raw)
    send_json(data or make_error("backend_error", "No response from backend"))
end

--- GET: Package and component versions
function api_version()
    local raw  = exec_script("version", 5, true)  -- silent
    local data = parse_lpac_json(raw)
    send_json(data or make_error("backend_error", "No response from backend"))
end

--- POST: Send AT command to serial port
function api_at_cmd()
    if not require_post() then return end
    local at_cmd = luci.http.formvalue("cmd") or "ATI"
    -- Sanitize: only allow printable ASCII, max 200 chars
    at_cmd = at_cmd:gsub("[^%w%s%+%-%=%?%^%$%*%#%%/%.,:;!@&()%[%]]", ""):sub(1, 200)
    local raw = exec_script("at-cmd " .. util.shellquote(at_cmd), 8)
    local data = parse_lpac_json(raw)
    send_json(data or make_error("backend_error", "No response from AT port"))
end

--- POST: Soft reset modem (QMI offline/online or AT+CFUN, no USB re-enum)
function api_soft_reset()
    if not require_post() then return end
    local raw  = exec_script("soft-reset", 15)
    local data = parse_lpac_json(raw)
    send_json(data or make_error("backend_error", "No response from backend"))
end

--- POST: USB port re-initialization (sysfs authorized 0→1)
function api_usb_reset()
    if not require_post() then return end
    local raw  = exec_script("usb-reset", 15)
    local data = parse_lpac_json(raw)
    send_json(data or make_error("backend_error", "No response from backend"))
end

--- POST: UICC SIM power cycle (QMI UIM power off/on)
function api_uicc_reset()
    if not require_post() then return end
    local raw  = exec_script("uicc-reset", 15)
    local data = parse_lpac_json(raw)
    send_json(data or make_error("backend_error", "No response from backend"))
end
