local mp = require 'mp'
local msg = require 'mp.msg'
local utils = require 'mp.utils'
local input   = require "mp.input"
local SELF    = mp.get_script_name()

if mp.get_property_native("user-data/nexus/loaded") then
    msg.warn("nexus.lua already loaded by another instance, skipping")
    return
end
mp.set_property_native("user-data/nexus/loaded", true)

local CONFIG_FILENAME = "nexus-config.json"
local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("(.*/)")
local srt_parser = dofile(utils.join_path(script_dir, "srt-parser.lua"))
local nexus_utils = dofile(utils.join_path(script_dir, "nexus-utils.lua"))
local platform = dofile(utils.join_path(script_dir, "platform.lua"))
local Language = dofile(utils.join_path(script_dir, "language.lua"))
local update_nexus = dofile(utils.join_path(script_dir, "update-nexus.lua"))

local cfg = nexus_utils.init_cfg()

local pid = mp.get_property_native('pid')

local is_windows = package.config:sub(1, 1) == "\\"
local is_macos = not is_windows and (os.getenv("HOME") and utils.file_info("/System/Library/CoreServices/Finder.app"))

local function normalize_path(path)
    if not path then return nil end
    local commands = mp.get_property_native("command-list", {})
    for _, command in ipairs(commands) do
        if command.name == "normalize-path" then
            return mp.command_native({"normalize-path", path})
        end
    end
    if is_windows then return path:gsub("/", "\\") else return path:gsub("\\", "/") end
end

local video_path = nil
local file_duration = nil
local file_hash_map = {}
local file_hash_sha256_map = {}
local transcription_active = false

local current_subtitle_id = nil
local current_download_link = nil
local current_etag = nil
local current_phase = nil         -- "extracting", "uploading", "processing"
local current_progress = 0
local last_logged_progress = 0
local current_upload_size_mb = 0
local current_upload_pct = 0
local current_extraction_pct = 0
local current_last_error = nil
local user_plan = nil             -- User's subscription plan (e.g., "free", "premium")
local user_name = nil
local api_key_valid = nil
local pending_device_code = nil
local api_healthy = nil

local s3_poll_timer = nil
local backend_poll_timer = nil
local has_file_poll_timer = nil

local log_buffer = {}
local LOG_BUFFER_MAX = 500

local update_main_menu
local sync_runtime_state

local PLAN_FREE_NAME = "free"
local DEFAULT_MESSAGE_DISPLAY_TIME_S = 2
local ERROR_MESSAGE_DISPLAY_TIME_S = 4
local LONG_MESSAGE_DISPLAY_TIME_S = 10
local BROWSER_OPEN_DELAY_S = 5
local STATE_FILENAME = "state.json"
local HAS_FILE_POLL_INTERVAL = 10.0
local S3_POLL_INTERVAL = 10.0
local BACKEND_POLL_INTERVAL = 60.0
local INITIAL_POLL_DELAY = 30.0
local PROGRESS_LOG_THRESHOLD = 3
local HEALTH_ENDPOINT = "/v1/health/"
local get_audio_format
local function get_audio_content_type(work_dir)
    local types = { mp3 = "audio/mpeg", wav = "audio/wav" }
    return types[get_audio_format(work_dir)] or "audio/mpeg"
end

local MPV_CONFIG_DIR = normalize_path(mp.command_native({"expand-path", "~~/"}))
local VERSION_FILE = normalize_path(utils.join_path(MPV_CONFIG_DIR, "VERSION"))
local STAGING_DIR = normalize_path(utils.join_path(MPV_CONFIG_DIR, "nexus-update-staging"))
local PENDING_VERSION_FILE = normalize_path(utils.join_path(STAGING_DIR, "VERSION"))
local SKIP_AUTO_UPDATE = false
local update_check_in_progress = false
local log_file_handle = nil
local log_file_path = nil

local SUPPORTED_AUDIO_LANGUAGES = {
    Language.ENGLISH,
    Language.JAPANESE,
}

local SUPPORTED_SUBTITLE_LANGUAGES = {
    Language.ENGLISH,
}


local function is_protocol(path)
    return type(path) == 'string' and (path:find('^%a[%w.+-]-://') ~= nil or path:find('^%a[%w.+-]-:%?') ~= nil)
end

local function file_exists(path)
    if path then
        local meta = utils.file_info(path)
        return meta and meta.is_file
    end
    return false
end

local function get_file_size(path)
    local info = utils.file_info(path)
    return info and info.size or 0
end

local function strip_extension(filename)
    return filename:match("(.+)%.[^.]+$") or filename
end

local function set_phase(phase)
    current_phase = phase
    if phase then msg.warn("Phase: " .. phase) end
end

local function extract_uuid(subtitle_id)
    return subtitle_id:match("subtitle_request:([^:]+)") or subtitle_id
end

local function make_curl_args(extra)
    local args = {"curl"}
    for _, a in ipairs(platform.current.curl_args) do args[#args+1] = a end
    for _, a in ipairs(extra) do args[#args+1] = a end
    return args
end

local function report_error(error_name, error_message, context)
    msg.error("report_error: " .. error_name .. " - " .. error_message ..
        " context=" .. utils.format_json(context or {}))
    local endpoint = "https://" .. cfg.domain .. "/v1/report-error/"
    local payload = utils.format_json({
        name = error_name,
        message = error_message,
        context = context,
        client_name = "nexus-mpv",
    })
    mp.command_native_async({
        name = "subprocess",
        capture_stdout = true,
        capture_stderr = true,
        args = make_curl_args({"-s", "-X", "POST", "-H", "X-API-KEY: " .. cfg.api_key,
            "-H", "Content-Type: application/json", "-d", payload, endpoint})
    }, function(success, res)
        if not success or (res and res.status ~= 0) then
            msg.warn("Failed to report error: " .. (res and res.stderr or "unknown"))
        end
    end)
end

local function validate_ffmpeg(path)
    local res = mp.command_native({
        name = "subprocess",
        capture_stdout = true,
        capture_stderr = true,
        args = { path, "-version" }
    })

    if res and res.status == 0 then
        msg.warn("Validated FFmpeg path: " .. path)
        return true
    else
        msg.error("FFmpeg validation failed for: " .. path)
        if res and res.stderr then
            msg.error("stderr: " .. res.stderr)
        end
        return false
    end
end

local function get_ffmpeg_path()
    local ffmpeg_candidates = {}

    if is_windows then
        local userLocalAppData = os.getenv("LOCALAPPDATA")
        if userLocalAppData then
            table.insert(ffmpeg_candidates, userLocalAppData .. "\\Programs\\mpv\\ffmpeg\\bin\\ffmpeg.exe")
        end
        local mpv_dir = mp.command_native({"expand-path", "~~exe_dir/"})
        if mpv_dir then
            table.insert(ffmpeg_candidates, mpv_dir .. "\\ffmpeg\\bin\\ffmpeg.exe")
        end
    elseif is_macos then
        ffmpeg_candidates = {
            "/Applications/Nexus MPV.app/Contents/Resources/ffmpeg/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/opt/homebrew/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        }
    end

    msg.warn("Checking known FFmpeg paths...")
    for _, path in ipairs(ffmpeg_candidates) do
        if file_exists(path) and validate_ffmpeg(path) then
            msg.warn("Using FFmpeg at: " .. path)
            return path
        end
    end
    msg.warn("Trying to find FFmpeg in system PATH...")
    local test_cmd = is_windows and "where" or "which"
    local res = mp.command_native({
        name = "subprocess",
        capture_stdout = true,
        capture_stderr = true,
        args = { test_cmd, "ffmpeg" }
    })

    if res and res.status == 0 and res.stdout then
        local path = res.stdout:gsub("%s+$", "")
        if validate_ffmpeg(path) then
            return path
        end
    end

    local error_msg = "Subtitles unavailable: FFmpeg not found"
    current_last_error = error_msg
    sync_runtime_state()
    mp.osd_message(error_msg, ERROR_MESSAGE_DISPLAY_TIME_S)
    report_error("ffmpeg_not_found", error_msg, {
        is_windows = is_windows,
        is_macos = is_macos,
        filename = video_path,
    })
    error(error_msg)
end

local function get_or_compute_file_hash(file_path)
    if file_hash_map[file_path] then
        return file_hash_map[file_path]
    end

    local hash = nexus_utils.get_file_hash(file_path)
    if hash then
        file_hash_map[file_path] = hash
        msg.warn("Computed file hash for " .. file_path .. ": " .. hash)
    else
        msg.error("Failed to compute file hash for " .. file_path)
        report_error("file_hash_failed", "Failed to compute file hash", { filename = file_path })
    end
    return hash
end

local function get_or_compute_file_hash_sha256(file_path)
    if file_hash_sha256_map[file_path] then
        return file_hash_sha256_map[file_path]
    end

    local hash = nexus_utils.get_file_hash_sha256(file_path, mp, platform.current)
    if hash then
        file_hash_sha256_map[file_path] = hash
        msg.warn("Computed SHA256 file hash for " .. file_path .. ": " .. hash)
    else
        msg.error("Failed to compute SHA256 file hash for " .. file_path)
        report_error("file_hash_sha256_failed", "Failed to compute SHA256 hash", { filename = file_path })
    end
    return hash
end

local function check_sub_track_exists(sub_file)
    local tracks = mp.get_property_native("track-list")
    local _, sub_title = utils.split_path(sub_file)

    for _, track in ipairs(tracks) do
        local external_filename = track["external-filename"]
        local track_title = track["title"]

        if external_filename then
            _, track_title = utils.split_path(external_filename)
        end

        if track["type"] == "sub" and track_title == sub_title then
            return true, track["id"]
        end
    end
    return false, nil
end

local function load_subtitle_file_into_mpv(sub_file)
    local sub, id = check_sub_track_exists(sub_file)
    if not sub then
        msg.warn("Loading new subtitle: " .. sub_file)
        mp.commandv('sub-add', sub_file)
    else
        msg.warn("Reloading subtitle track " .. id .. ": " .. sub_file)
        mp.commandv('sub-reload', id)
    end
end

local function get_work_dir()
    local path = mp.get_property("path")
    local subdir = ""
    if path and path ~= "" then
        local hash = get_or_compute_file_hash_sha256(path)
        if hash then
            subdir = hash .. "/"
        end
    end

    local result
    if cfg.base_dir and cfg.base_dir ~= "" then
        local base = cfg.base_dir
        if not base:match("/$") then
            base = base .. "/"
        end
        result = base .. subdir
    else
        local data_dir = mp.command_native({ "expand-path", "~~/data/" })
        result = data_dir .. subdir
    end
    return normalize_path(result)
end

local function get_request_key()
    return cfg.model .. ":" .. cfg.subtitle_language_code
end

local function get_state(work_dir)
    local state_path = utils.join_path(work_dir, STATE_FILENAME)
    local all_state = nexus_utils.read_json(state_path) or {}
    return (all_state.requests or {})[get_request_key()] or {}
end

local function get_audio_language(work_dir)
    local state_path = utils.join_path(work_dir, STATE_FILENAME)
    local all_state = nexus_utils.read_json(state_path) or {}
    return all_state.audio_language or cfg.default_audio_language_code
end

local function set_audio_language(work_dir, lang_code)
    platform.current.create_directory(work_dir)
    local state_path = utils.join_path(work_dir, STATE_FILENAME)
    local all_state = nexus_utils.read_json(state_path) or {}
    all_state.audio_language = lang_code
    nexus_utils.write_json(state_path, all_state)
    sync_runtime_state()
end

get_audio_format = function(work_dir)
    local fmt = cfg.audio_format or "auto"
    return fmt == "auto" and "wav" or fmt
end

local function sync_config()
    mp.set_property_native("user-data/nexus/config", {
        api_key = cfg.api_key,
        domain = cfg.domain,
        subtitle_language_code = cfg.subtitle_language_code,
        model = cfg.model,
        auto_transcribe_new_files = cfg.auto_transcribe_new_files,
        auto_purchase_past_daily_limit = cfg.auto_purchase_past_daily_limit,
        ignore_community_subs = cfg.ignore_community_subs,
        audio_format = cfg.audio_format
    })
end

local function get_config_path()
    local path
    if cfg.base_dir and cfg.base_dir ~= "" then
        path = utils.join_path(cfg.base_dir, CONFIG_FILENAME)
    else
        path = utils.join_path(mp.command_native({ "expand-path", "~~/script-opts" }), CONFIG_FILENAME)
    end
    return normalize_path(path)
end

local function get_logs_dir()
    if cfg.base_dir and cfg.base_dir ~= "" then
        return normalize_path(utils.join_path(cfg.base_dir, "logs"))
    end
    return normalize_path(mp.command_native({ "expand-path", "~~/logs" }))
end

local function cleanup_old_logs()
    local logs_dir = get_logs_dir()
    local files = utils.readdir(logs_dir) or {}
    local cutoff = os.time() - (7 * 24 * 60 * 60)
    for _, file in ipairs(files) do
        if file:match("^%d%d%d%d%-%d%d%-%d%d_.+%.log$") then
            local path = utils.join_path(logs_dir, file)
            local info = utils.file_info(path)
            if info and info.mtime and info.mtime < cutoff then os.remove(path) end
        end
    end
end

local function get_log_file()
    if log_file_handle then return log_file_handle end
    local logs_dir = get_logs_dir()
    platform.current.create_directory(logs_dir)
    log_file_path = normalize_path(utils.join_path(logs_dir, os.date("%Y-%m-%d_%H-%M-%S") .. ".log"))
    log_file_handle = io.open(log_file_path, "a")
    return log_file_handle
end


local function load_config_from_file()
    local config_path = get_config_path()
    local data = nexus_utils.read_json(config_path)
    if data then
        if data.api_key then cfg.api_key = data.api_key end
        if data.domain then cfg.domain = data.domain end
        if data.domain_web then cfg.domain_web = data.domain_web end
        if data.subtitle_language_code then cfg.subtitle_language_code = data.subtitle_language_code end
        if data.model then cfg.model = data.model end
        if data.auto_transcribe_new_files ~= nil then cfg.auto_transcribe_new_files = data.auto_transcribe_new_files end
        if data.auto_purchase_past_daily_limit ~= nil then
            cfg.auto_purchase_past_daily_limit = data.auto_purchase_past_daily_limit
        end
        if data.ignore_community_subs ~= nil then cfg.ignore_community_subs = data.ignore_community_subs end
        if data.audio_format then cfg.audio_format = data.audio_format end
        if data.volume then cfg.volume = data.volume end
        if data.application_id then cfg.application_id = data.application_id end
    end
    if not cfg.application_id or cfg.application_id == "" then
        cfg.application_id = nexus_utils.generate_uuid()
    end
    cfg.application_type = nexus_utils.is_iina() and "iina-nexus-plugin" or "nexus-mpv"
    msg.warn("Config loaded: model=" .. cfg.model .. " lang=" .. cfg.subtitle_language_code ..
        " auto_transcribe=" .. tostring(cfg.auto_transcribe_new_files) .. " app_type=" .. cfg.application_type)
end

load_config_from_file()

local function save_config_to_file()
    local config_path = get_config_path()
    local config_dir = (cfg.base_dir and cfg.base_dir ~= "") and cfg.base_dir
        or mp.command_native({ "expand-path", "~~/script-opts" })
    platform.current.create_directory(config_dir)
    nexus_utils.write_json(config_path, {
        api_key = cfg.api_key,
        domain = cfg.domain,
        domain_web = cfg.domain_web,
        subtitle_language_code = cfg.subtitle_language_code,
        model = cfg.model,
        auto_transcribe_new_files = cfg.auto_transcribe_new_files,
        auto_purchase_past_daily_limit = cfg.auto_purchase_past_daily_limit,
        ignore_community_subs = cfg.ignore_community_subs,
        audio_format = cfg.audio_format,
        volume = cfg.volume,
        application_id = cfg.application_id
    })
    sync_config()
end

local function save_config_key(config_key, new_value)
    local log_display_value = config_key == "api_key" and "(redacted)" or tostring(new_value)
    msg.warn("Config changed: " .. config_key .. "=" .. log_display_value)
    cfg[config_key] = new_value
    save_config_to_file()
    return true
end

sync_runtime_state = function()
    local work_dir = get_work_dir()
    local state = get_state(work_dir)
    local runtime_state = {}
    for k, v in pairs(state) do runtime_state[k] = v end
    runtime_state.audio_language = get_audio_language(work_dir)
    runtime_state.phase = current_phase
    runtime_state.progress = current_progress
    runtime_state.upload_size_mb = current_upload_size_mb
    runtime_state.upload_pct = current_upload_pct
    runtime_state.extraction_pct = current_extraction_pct
    runtime_state.is_active = transcription_active
    runtime_state.last_error = current_last_error
    runtime_state.user_plan = user_plan
    runtime_state.user_name = user_name
    runtime_state.api_key_valid = api_key_valid
    runtime_state.pending_device_code = pending_device_code
    runtime_state.logs = log_buffer
    mp.set_property_native("user-data/nexus/state", runtime_state)
end

local function set_state(work_dir, state)
    msg.warn("=== SET_STATE CALLED ===")
    platform.current.create_directory(work_dir)
    local state_path = utils.join_path(work_dir, STATE_FILENAME)
    local all_state = nexus_utils.read_json(state_path) or {}
    if not all_state.requests then all_state.requests = {} end
    all_state.requests[get_request_key()] = state
    nexus_utils.write_json(state_path, all_state)
    sync_runtime_state()
end


local function extract_full_audio(input_path, output_path, callback)
    local current_audio_id = mp.get_property_number("current-tracks/audio/id")
    local audio_stream_index = (current_audio_id and current_audio_id > 0) and (current_audio_id - 1) or 0

    if platform.current.is_network_path(input_path) then
        mp.osd_message("Network file detected - audio processing may be slow.", LONG_MESSAGE_DISPLAY_TIME_S)
        msg.warn("Network path detected: " .. input_path)
    end

    local duration_sec = file_duration or mp.get_property_number("duration") or 0
    local fmt = output_path:match("%.([^%.]+)$") or "wav"
    local expected_sizes = {
        wav = duration_sec * 16000 * 2,
        mp3 = duration_sec * 32000 / 8
    }
    local expected_size = expected_sizes[fmt] or expected_sizes.mp3

    local ffmpeg_args = {
        get_ffmpeg_path(),
        "-hide_banner",
        "-nostdin",
        "-y",
        "-loglevel", "error",
        "-i", input_path,
        "-map", "0:a:" .. audio_stream_index,
        "-vn",
        "-sn",
        "-ac", "1",
        "-ar", "16000",
    }
    if fmt == "wav" then
        table.insert(ffmpeg_args, "-c:a"); table.insert(ffmpeg_args, "pcm_s16le")
    else
        table.insert(ffmpeg_args, "-c:a"); table.insert(ffmpeg_args, "libmp3lame")
        table.insert(ffmpeg_args, "-b:a"); table.insert(ffmpeg_args, "32k")
    end
    table.insert(ffmpeg_args, output_path)

    msg.warn("Extracting full audio to: " .. output_path)
    msg.warn("FFmpeg command: " .. table.concat(ffmpeg_args, " "))
    local start_time = mp.get_time()

    current_extraction_pct = 0
    sync_runtime_state()
    update_main_menu()

    local progress_timer = mp.add_periodic_timer(0.5, function()
        local info = utils.file_info(output_path)
        if info and info.size and expected_size > 0 then
            current_extraction_pct = math.min(99, math.floor(info.size / expected_size * 100))
            mp.osd_message(string.format("Extracting audio: %d%%", current_extraction_pct), 1)
            sync_runtime_state()
            update_main_menu()
        end
    end)

    mp.command_native_async({
        name = "subprocess",
        capture_stdout = true,
        capture_stderr = true,
        args = ffmpeg_args
    }, function(success, res)
        progress_timer:kill()
        current_extraction_pct = 0
        local elapsed = mp.get_time() - start_time
        if not success or (res and res.status ~= 0) then
            msg.error("FFmpeg failed: " .. (res and res.stderr or "unknown"))
            msg.error("Command: " .. table.concat(ffmpeg_args, " "))
            report_error("audio_extraction_failed", "FFmpeg audio extraction failed", {
                filename = video_path,
                stderr = res and res.stderr,
            })
            callback(false)
            return
        end
        msg.warn(string.format("Audio extraction complete (%.1fs)", elapsed))
        callback(true)
    end)
end


local function api_call(method, endpoint, body, callback, silent, skip_auth)
    if api_healthy == false and endpoint ~= HEALTH_ENDPOINT then
        callback(nil, "api_unhealthy")
        return
    end

    if not skip_auth and (cfg.api_key == "" or cfg.api_key == "NOT_SET") then
        if not silent then
            mp.osd_message("Please login first", ERROR_MESSAGE_DISPLAY_TIME_S)
        end
        callback(nil, "no_auth")
        return
    end

    local url = "https://" .. cfg.domain .. endpoint
    local args = make_curl_args({"-s", "-X", method, "-w", "\n%{http_code}", "--max-time", "30"})
    if not skip_auth then
        table.insert(args, "-H")
        table.insert(args, "X-API-Key: " .. cfg.api_key)
    end
    if body then
        table.insert(args, "-H")
        table.insert(args, "Content-Type: application/json")
        table.insert(args, "-d")
        table.insert(args, utils.format_json(body))
    end
    table.insert(args, url)

    msg.warn("API call: " .. method .. " " .. url)

    mp.command_native_async({
        name = "subprocess",
        capture_stdout = true,
        capture_stderr = true,
        playback_only = false,
        args = args
    }, function(success, res)
        if not success or not res or res.status ~= 0 then
            msg.error("API network error: " .. method .. " " .. endpoint)
            msg.error("  curl exit code: " .. tostring(res and res.status) ..
                " stderr: " .. tostring(res and res.stderr):sub(1, 200))
            if not silent then
                local err = "Network error, check connection"
                current_last_error = err
                sync_runtime_state()
                mp.osd_message(err, ERROR_MESSAGE_DISPLAY_TIME_S)
            end
            callback(nil, "network_error")
            return
        end

        local stdout = res.stdout or ""
        local last_newline = stdout:match(".*\n()")
        local body_str = last_newline and stdout:sub(1, last_newline - 2) or stdout
        local http_code = last_newline and tonumber(stdout:sub(last_newline)) or nil

        msg.warn("API response: HTTP " .. tostring(http_code))

        if http_code and http_code >= 200 and http_code < 300 then
            local data = utils.parse_json(body_str)
            current_last_error = nil
            callback(data, nil)
        else
            msg.error("API error: HTTP " .. tostring(http_code) .. " - " .. body_str)
            local error_msg = utils.parse_json(body_str)
            local detail = error_msg and (error_msg.message or error_msg.detail)
            if http_code == 401 then
                detail = "Bad API Key. Try logging in again."
            elseif type(detail) == "table" then
                detail = detail[1] and detail[1].msg or "Validation error"
            elseif not detail then
                detail = "HTTP " .. tostring(http_code)
            end
            if not silent then
                current_last_error = detail
                sync_runtime_state()
                mp.osd_message("Error: " .. detail, ERROR_MESSAGE_DISPLAY_TIME_S)
            end
            callback(nil, "http_" .. tostring(http_code))
        end
    end)
end


local health_check_timer = nil
local HEALTH_RETRY_INTERVAL = 30.0

local function check_api_health(callback, silent)
    api_call("GET", HEALTH_ENDPOINT, nil, function(data, err)
        if err then
            msg.warn("Health check failed: " .. tostring(err))
            local was_healthy = api_healthy ~= false
            api_healthy = false
            if was_healthy and not silent then
                mp.osd_message("Nexus API unavailable. Check subtitlenexus.com.", LONG_MESSAGE_DISPLAY_TIME_S)
            end
            if not health_check_timer then
                health_check_timer = mp.add_periodic_timer(HEALTH_RETRY_INTERVAL, function()
                    check_api_health(nil, true)
                end)
            end
            if callback then callback(false) end
        else
            msg.warn("Health check passed")
            api_healthy = true
            if health_check_timer then
                health_check_timer:kill()
                health_check_timer = nil
            end
            if callback then callback(true) end
        end
    end, true, true)
end


local function parse_version(v)
    local out = {}
    for n in v:gmatch("%d+") do table.insert(out, tonumber(n)) end
    return out
end

local function is_newer_version(current, latest)
    local a, b = parse_version(current), parse_version(latest)
    for i = 1, math.max(#a, #b) do
        if (b[i] or 0) > (a[i] or 0) then return true end
        if (b[i] or 0) < (a[i] or 0) then return false end
    end
    return false
end

local function needs_full_update(current, latest)
    local cur, lat = parse_version(current), parse_version(latest)
    return (lat[1] or 0) > (cur[1] or 0)
end

local function is_valid_version(version_str)
    if not version_str or type(version_str) ~= "string" then return false end
    version_str = version_str:match("^%s*(.-)%s*$")
    return version_str:match("^%d+%.%d+%.%d+$") ~= nil
end

local function read_version_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*line")
    f:close()
    if not content then return nil end
    local version = content:match("^%s*(.-)%s*$")
    return is_valid_version(version) and version or nil
end

local function has_staged_update(version)
    local f = io.open(PENDING_VERSION_FILE, "r")
    if not f then return false end
    local staged = f:read("*line")
    f:close()
    return staged == version
end

local function install_staged_update()
    local f = io.open(PENDING_VERSION_FILE, "r")
    if not f then return false end
    local staged_version = f:read("*line")
    f:close()
    if not staged_version then return false end

    msg.warn("[update] Found staged update: v" .. staged_version)
    local staged_scripts_dir = utils.join_path(STAGING_DIR, "scripts")
    local files = utils.readdir(staged_scripts_dir) or {}
    local success = true

    for _, file in ipairs(files) do
        if file:match("%.lua$") then
            local src = utils.join_path(staged_scripts_dir, file)
            local dst = utils.join_path(script_dir, file)
            local sf = io.open(src, "rb")
            local df = io.open(dst, "wb")
            if sf and df then
                df:write(sf:read("*a"))
                sf:close()
                df:close()
            else
                if sf then sf:close() end
                if df then df:close() end
                msg.error("[update] Failed to copy: " .. file)
                success = false
            end
        end
    end
    local staged_version_file = utils.join_path(STAGING_DIR, "VERSION")
    local vf = io.open(staged_version_file, "r")
    if vf then
        local new_version = vf:read("*line")
        vf:close()
        local dst_vf = io.open(VERSION_FILE, "w")
        if dst_vf then
            dst_vf:write(new_version)
            dst_vf:close()
        end
    end
    local staged_uosc = utils.join_path(STAGING_DIR, "script-opts/uosc.conf")
    local script_opts_dir = utils.join_path(MPV_CONFIG_DIR, "script-opts")
    local uosc_dest = utils.join_path(script_opts_dir, "uosc.conf")
    if utils.file_info(staged_uosc) then
        platform.current.create_directory(script_opts_dir)
        if utils.file_info(uosc_dest) then
            os.rename(uosc_dest, uosc_dest .. ".bak")
        end
        local sf = io.open(staged_uosc, "rb")
        local df = io.open(uosc_dest, "wb")
        if sf and df then
            df:write(sf:read("*a"))
            sf:close()
            df:close()
        end
    end

    platform.current.cleanup_directory(STAGING_DIR)
    if success then
        mp.osd_message("Updated to v" .. staged_version, DEFAULT_MESSAGE_DISPLAY_TIME_S)
        msg.warn("[update] Installed update v" .. staged_version)
    end
    return success
end

local function stage_scripts_update(scripts_url, version)
    msg.warn("[update] Staging scripts update v" .. version)
    platform.current.create_directory(STAGING_DIR)
    local zip_path = utils.join_path(STAGING_DIR, "scripts.zip")

    mp.osd_message("Downloading update v" .. version .. "...", 2)
    local result = mp.command_native({
        name = "subprocess",
        args = make_curl_args({"-fsSL", "-o", zip_path, scripts_url}),
        capture_stdout = true
    })

    if not result or result.status ~= 0 then
        msg.error("[update] Failed to download scripts")
        platform.current.cleanup_directory(STAGING_DIR)
        return false
    end

    if not platform.current.extract_zip(zip_path, STAGING_DIR) then
        msg.error("[update] Failed to extract scripts")
        platform.current.cleanup_directory(STAGING_DIR)
        return false
    end

    os.remove(zip_path)
    local pf = io.open(PENDING_VERSION_FILE, "w")
    if pf then
        pf:write(version)
        pf:close()
    end

    mp.osd_message("Update v" .. version .. " ready, will install on relaunch", DEFAULT_MESSAGE_DISPLAY_TIME_S)
    return true
end

local function check_for_update(silent)
    msg.warn("[update] Checking for updates...")
    local cur = read_version_file(VERSION_FILE) or "0.0.0"
    msg.warn("[update] Current version: " .. cur)

    local check_url = string.format("/v1/dist/update/check-latest/?application_type=%s", cfg.application_type)
    api_call("GET", check_url, nil, function(data, err)
        if err or not data or not data.application_version then
            msg.warn("[update] Failed to check version")
            return
        end

        local latest = data.application_version
        local dist_type = needs_full_update(cur, latest) and "full" or "patch"
        msg.warn("[update] Latest: " .. latest .. " (dist_type: " .. dist_type .. ")")

        if not is_newer_version(cur, latest) then
            if not silent then
                mp.osd_message("You are up to date! v" .. cur, DEFAULT_MESSAGE_DISPLAY_TIME_S)
            end
            return
        end

        if has_staged_update(latest) then
            if not silent then
                mp.osd_message("Update v" .. latest .. " ready, will install on relaunch",
                    DEFAULT_MESSAGE_DISPLAY_TIME_S)
            end
            return
        end

        local dl_url = string.format("/v1/dist/update/download/?application_type=%s&platform=%s&dist_type=%s",
            cfg.application_type, platform.current.name, dist_type)
        api_call("GET", dl_url, nil, function(dl_data, dl_err)
            if dl_err or not dl_data or not dl_data.download_url then
                mp.osd_message("Update v" .. latest .. " available - download at subtitlenexus.com",
                    DEFAULT_MESSAGE_DISPLAY_TIME_S * 2)
                return
            end

            if dist_type == "full" then
                update_nexus.show_update_prompt(latest, dl_data.download_url)
            else
                stage_scripts_update(dl_data.download_url, latest)
            end
        end, true, true)
    end, true, true)
end

local function on_startup_update_check()
    install_staged_update()
    if update_check_in_progress then return end
    update_check_in_progress = true
    mp.add_timeout(1, function()
        check_for_update(true)
        update_check_in_progress = false
    end)
end


local function upload_start(file_name, file_size, duration_seconds, audio_language, work_dir, callback)
    api_call("POST", "/v1/async-upload/av/start/", {
        file_name = file_name,
        content_type = get_audio_content_type(work_dir),
        file_size = file_size,
        duration_seconds = math.floor(duration_seconds),
        upload_type = "simple",
        audio_language = audio_language
    }, callback)
end

local function upload_to_s3(presigned_url, file_path, work_dir, callback)
    mp.osd_message("Uploading audio...", DEFAULT_MESSAGE_DISPLAY_TIME_S)
    local file_size = get_file_size(file_path)
    msg.warn(string.format("Uploading to S3: %s (%.1f MB)", file_path, nexus_utils.bytes_to_mb(file_size)))
    local start_time = mp.get_time()

    current_upload_pct = 0
    sync_runtime_state()
    update_main_menu()

    local curl_args
    local progress_file = nil
    local progress_timer = nil

    if is_windows then
        curl_args = make_curl_args({"-s", "-X", "PUT", "--data-binary", "@" .. file_path,
            "-H", "Content-Type: " .. get_audio_content_type(work_dir), "-w", "\n%{http_code}", presigned_url})
    else
        progress_file = platform.current.temp_dir .. "/nexus_upload_" .. os.time()
        local curl_cmd = string.format(
            'curl --progress-bar -X PUT --data-binary "@%s" -H "Content-Type: %s" -w "\\n%%{http_code}" "%s" 2>"%s"',
            file_path, get_audio_content_type(work_dir), presigned_url, progress_file
        )
        curl_args = platform.current.shell_args(curl_cmd)

        progress_timer = mp.add_periodic_timer(0.3, function()
            local f = io.open(progress_file, "r")
            if f then
                local content = f:read("*all")
                f:close()
                local pct = content:match("(%d+)%.?%d*%%[%s]*$")
                if pct then
                    current_upload_pct = math.min(99, tonumber(pct))
                    mp.osd_message(string.format("Uploading: %d%%", current_upload_pct), 1)
                    sync_runtime_state()
                    update_main_menu()
                end
            end
        end)
    end

    mp.command_native_async({
        name = "subprocess",
        capture_stdout = true,
        args = curl_args
    }, function(success, res)
        if progress_timer then progress_timer:kill() end
        if progress_file then os.remove(progress_file) end
        current_upload_pct = 0
        local elapsed = mp.get_time() - start_time
        if not success or not res then
            msg.error("S3 upload failed: curl error")
            report_error("s3_upload_network_error", "S3 upload failed (curl)", { stderr = res and res.stderr })
            callback(false)
            return
        end
        local http_code = tonumber(res.stdout:match("(%d+)%s*$"))
        if http_code and http_code >= 200 and http_code < 300 then
            local size_mb = nexus_utils.bytes_to_mb(file_size)
            msg.warn(string.format("S3 upload complete: HTTP %d (%.1f MB in %.1fs)", http_code, size_mb, elapsed))
            callback(true)
        else
            msg.error("S3 upload failed: HTTP " .. tostring(http_code))
            report_error("s3_upload_http_error", "S3 upload failed", { http_code = http_code })
            callback(false)
        end
    end)
end

local function upload_finish(upload_id, callback)
    api_call("POST", "/v1/async-upload/av/finish/", {
        upload_id = upload_id,
        upload_type = "simple"
    }, callback)
end


local function submit_subtitle_request(upload_id, audio_language, callback)
    local file_hash = get_or_compute_file_hash(video_path)
    local file_hash_sha256 = get_or_compute_file_hash_sha256(video_path)

    api_call("POST", "/v1/ai/subtitle-request/", {
        upload_id = upload_id,
        file_hash = file_hash,
        file_hash_sha256 = file_hash_sha256,
        audio_language = audio_language,
        subtitle_language = cfg.subtitle_language_code,
        version = cfg.model,
        pipeline_version = 2,
        application_type = cfg.application_type
    }, callback)
end

local function purchase_subtitle(subtitle_id, callback)
    api_call("POST", "/v1/subtitle/purchase/", {
        subtitle_id = subtitle_id
    }, callback)
end


local function stop_all_timers()
    msg.warn("Stopping all polling timers")
    if has_file_poll_timer then has_file_poll_timer:kill(); has_file_poll_timer = nil end
    if s3_poll_timer then s3_poll_timer:kill(); s3_poll_timer = nil end
    if backend_poll_timer then backend_poll_timer:kill(); backend_poll_timer = nil end
end

local function clear_failed_state()
    local work_dir = get_work_dir()
    local state = get_state(work_dir)
    state.subtitle_id = nil
    state.subtitle_status = nil
    set_state(work_dir, state)
end

local function mark_completed()
    local work_dir = get_work_dir()
    local state = get_state(work_dir)
    state.subtitle_status = "COMPLETED"
    set_state(work_dir, state)
end

local function handle_poll_failure(error_type)
    msg.error("Transcription failed: " .. tostring(error_type))
    local err = "Subtitle generation failed"
    current_last_error = err
    sync_runtime_state()
    mp.osd_message(err, ERROR_MESSAGE_DISPLAY_TIME_S)
    stop_all_timers()
    clear_failed_state()
    transcription_active = false
end

local function poll_subtitle_status(callback)
    api_call("GET", "/v1/ai/subtitle-request/", { subtitle_id = current_subtitle_id }, callback)
end

local function get_download_link(subtitle_id, callback)
    local endpoint = "/v1/subtitle/download/?subtitle_id=" .. subtitle_id .. "&expiration_s=3600"
    api_call("GET", endpoint, nil, callback)
end

local function search_existing_subtitles(file_hash, callback)
    local endpoint = string.format("/v1/subtitle/search/?file_hash=%s&version=%s&language=%s",
        file_hash, cfg.model, cfg.subtitle_language_code)
    api_call("GET", endpoint, nil, callback)
end

local function fetch_user_info()
    api_call("GET", "/v1/user/info/", nil, function(data, err)
        if data then
            if data.plan then user_plan = data.plan:lower() end
            if data.username then user_name = data.username end
            msg.warn("User: " .. tostring(user_name) .. ", plan: " .. tostring(user_plan))
            update_main_menu()
        end
    end, true)
end

local function validate_api_key()
    if cfg.api_key == "" or cfg.api_key == "NOT_SET" then
        msg.warn("API key not set, skipping validation")
        api_key_valid = false
        update_main_menu()
        return
    end
    api_call("GET", "/v1/user/validate/", nil, function(data, err)
        if err == "http_401" then
            msg.warn("API key validation failed: invalid key")
            api_key_valid = false
        elseif data and data.valid then
            msg.warn("API key validated successfully")
            api_key_valid = true
            fetch_user_info()
        end
        update_main_menu()
    end, true)
end

local function download_subtitles(download_url, output_path, callback)
    msg.warn("Downloading subtitles to: " .. output_path)
    mp.command_native_async({
        name = "subprocess",
        capture_stdout = true,
        capture_stderr = true,
        args = make_curl_args({"-s", "--max-time", "30", "-o", output_path, download_url})
    }, function(success, res)
        local ok = success and res and res.status == 0
        if not ok then
            report_error("subtitle_download_failed", "Failed to download subtitles", {
                exit_code = res and res.status,
                stderr = res and res.stderr,
            })
            local err = "Subtitle download failed"
            current_last_error = err
            sync_runtime_state()
            mp.osd_message(err, ERROR_MESSAGE_DISPLAY_TIME_S)
        else
            msg.warn("Subtitle download complete: " .. output_path)
        end
        callback(ok)
    end)
end

local function check_s3_etag(download_url, callback)
    if not download_url then
        callback(nil)
        return
    end
    mp.command_native_async({
        name = "subprocess",
        capture_stdout = true,
        capture_stderr = true,
        args = make_curl_args({"-s", "--max-time", "15", "-D", "-",
            "-o", platform.current.null_device, "-r", "0-0", download_url})
    }, function(success, res)
        if not success or not res or res.status ~= 0 then
            callback(nil)
            return
        end
        local etag = res.stdout:match('[Ee][Tt][Aa][Gg]:%s*"?([^"\r\n]+)"?')
        callback(etag)
    end)
end

local subtitles_file = nil

local function start_s3_polling()
    if not current_download_link then return end
    msg.warn("Starting S3 polling (interval: " .. S3_POLL_INTERVAL .. "s)")

    s3_poll_timer = mp.add_periodic_timer(S3_POLL_INTERVAL, function()
        if not transcription_active then
            stop_all_timers()
            return
        end

        check_s3_etag(current_download_link, function(etag)
            if not etag or etag == current_etag then return end
            msg.warn("S3 ETag changed, downloading update")
            current_etag = etag
            download_subtitles(current_download_link, subtitles_file, function(success)
                if success and file_exists(subtitles_file) then
                    load_subtitle_file_into_mpv(subtitles_file)
                    msg.warn("Subtitles updated (ETag changed)")
                end
            end)
        end)
    end)
end

local function start_backend_polling()
    msg.warn("Starting backend polling (interval: " .. BACKEND_POLL_INTERVAL .. "s)")
    backend_poll_timer = mp.add_periodic_timer(BACKEND_POLL_INTERVAL, function()
        if not transcription_active then
            stop_all_timers()
            return
        end

        poll_subtitle_status(function(data, err)
            if err == "http_429" then
                msg.error("Rate limited, stopping polling")
                stop_all_timers()
                return
            end
            if err then
                msg.warn("Backend poll error: " .. tostring(err))
                return
            end

            if data then
                local new_progress = data.progress or 0
                if new_progress - last_logged_progress >= PROGRESS_LOG_THRESHOLD then
                    msg.warn("Backend poll: progress=" .. tostring(new_progress) .. "%")
                    last_logged_progress = new_progress
                end
                current_progress = new_progress
                update_main_menu()
            end

            if data and data.status == "COMPLETED" then
                msg.warn("Transcription completed")
                mp.osd_message("Subtitles ready!", DEFAULT_MESSAGE_DISPLAY_TIME_S)
                stop_all_timers()
                mark_completed()
                check_s3_etag(current_download_link, function(etag)
                    msg.warn("Final ETag check: current=" .. tostring(current_etag) .. ", new=" .. tostring(etag))
                    if etag and etag ~= current_etag then
                        msg.warn("ETag changed, downloading final subtitles...")
                        download_subtitles(current_download_link, subtitles_file, function(success)
                            if success then
                                msg.warn("Final subtitles downloaded")
                                load_subtitle_file_into_mpv(subtitles_file)
                            end
                        end)
                    end
                end)
                transcription_active = false
            elseif data and data.status == "FAILED" then
                handle_poll_failure(data.error_type)
            end
        end)
    end)
end

local function start_has_file_polling()
    msg.warn("Starting has_file polling (interval: " .. HAS_FILE_POLL_INTERVAL .. "s)")
    has_file_poll_timer = mp.add_periodic_timer(HAS_FILE_POLL_INTERVAL, function()
        if not transcription_active then
            stop_all_timers()
            return
        end

        poll_subtitle_status(function(data, err)
            if err == "http_429" then
                msg.error("Rate limited, stopping polling")
                stop_all_timers()
                return
            end
            if err then
                msg.warn("File poll error: " .. tostring(err))
                return
            end
            if data then
                local new_progress = data.progress or 0
                if new_progress - last_logged_progress >= PROGRESS_LOG_THRESHOLD then
                    msg.warn("Poll: progress=" .. tostring(new_progress) .. "%")
                    last_logged_progress = new_progress
                end
                current_progress = new_progress
                update_main_menu()
            end

            if data and data.status == "FAILED" then
                handle_poll_failure(data.error_type)
                return
            end

            if data and data.has_file then
                msg.warn("File available, getting download link...")
                if has_file_poll_timer then
                    has_file_poll_timer:kill()
                    has_file_poll_timer = nil
                end

                get_download_link(current_subtitle_id, function(link_data, link_err)
                    if link_err or not link_data or not link_data.download_link then
                        msg.error("Failed to get download link")
                        return
                    end

                    current_download_link = link_data.download_link
                    msg.warn("Download link: " .. current_download_link:sub(1, 80) .. "...")

                    check_s3_etag(current_download_link, function(etag)
                        current_etag = etag
                        msg.warn("Initial ETag: " .. tostring(etag))

                        download_subtitles(current_download_link, subtitles_file, function(success)
                            if success and file_exists(subtitles_file) then
                                msg.warn("Initial subtitles downloaded")
                                load_subtitle_file_into_mpv(subtitles_file)
                            end
                        end)

                        start_s3_polling()
                        start_backend_polling()
                    end)
                end)
            end
        end)
    end)
end


local function start_ai_transcription()
    if transcription_active then
        msg.warn("Transcription already active, ignoring start request")
        return
    end

    local path = mp.get_property("path")
    if not path or path == "" then return end
    if is_protocol(path) then
        msg.error("Cannot transcribe streams or invalid paths")
        local err = "Cannot transcribe streams"
        current_last_error = err
        sync_runtime_state()
        mp.osd_message(err, ERROR_MESSAGE_DISPLAY_TIME_S)
        return
    end

    video_path = path
    file_duration = mp.get_property_number('duration')
    transcription_active = true
    current_last_error = nil
    last_logged_progress = 0
    msg.warn("start_ai_transcription: path=" .. path .. " duration=" .. tostring(file_duration) .. "s")

    local work_dir = get_work_dir()
    local fmt = get_audio_format(work_dir)
    local file_hash_sha256 = get_or_compute_file_hash_sha256(path)
    platform.current.create_directory(work_dir)

    subtitles_file = utils.join_path(work_dir, cfg.model .. "-" .. cfg.subtitle_language_code .. ".srt")

    local state = get_state(work_dir)

    if state.subtitle_status == "COMPLETED" and file_exists(subtitles_file) then
        msg.warn("Subtitles already complete, loading: " .. subtitles_file)
        load_subtitle_file_into_mpv(subtitles_file)
        transcription_active = false
        return
    end

    local demo_file = utils.join_path(work_dir, cfg.model .. "-" .. cfg.subtitle_language_code .. "-demo.srt")
    if state.is_demo and file_exists(demo_file) then
        msg.warn("Loading existing demo while checking for upgrade: " .. demo_file)
        load_subtitle_file_into_mpv(demo_file)
    end

    if state.subtitle_id and state.subtitle_status ~= "COMPLETED" then
        msg.warn("Resuming from saved subtitle_id: " .. state.subtitle_id)
        current_subtitle_id = state.subtitle_id
        if file_exists(subtitles_file) then
            load_subtitle_file_into_mpv(subtitles_file)
        end
        mp.osd_message("Resuming subtitle request...", DEFAULT_MESSAGE_DISPLAY_TIME_S)
        start_has_file_polling()
        return
    end

    local _, fname = utils.split_path(path)
    state = get_state(work_dir)
    state.original_filename = fname
    set_state(work_dir, state)

    local fname_base = strip_extension(fname)
    local audio_name = "nexus_" .. (file_hash_sha256 or fname_base) .. "." .. fmt
    local audio_file = utils.join_path(platform.current.temp_dir, audio_name)

    local function proceed_with_upload()
        local file_size = get_file_size(audio_file)
        current_upload_size_mb = nexus_utils.bytes_to_mb(file_size)
        update_main_menu()
        msg.warn("Audio ready: " .. file_size .. " bytes")
        local audio_lang = get_audio_language(work_dir)
        local audio_filename = fname_base .. "." .. fmt

        upload_start(audio_filename, file_size, file_duration, audio_lang, work_dir, function(start_data, start_err)
            if start_err or not start_data then
                msg.warn("upload_start failed: " .. tostring(start_err))
                transcription_active = false
                return
            end

            local upload_id = start_data.upload_id
            msg.warn("upload_start success: upload_id=" .. upload_id)
            local presigned_url = start_data.presigned_url

            upload_to_s3(presigned_url, audio_file, work_dir, function(s3_success)
                if not s3_success then
                    local err = "Upload to S3 failed"
                    current_last_error = err
                    sync_runtime_state()
                    mp.osd_message(err, ERROR_MESSAGE_DISPLAY_TIME_S)
                    transcription_active = false
                    return
                end

                upload_finish(upload_id, function(finish_data, finish_err)
                    if finish_err then
                        msg.warn("upload_finish failed: " .. tostring(finish_err))
                        transcription_active = false
                        return
                    end

                    msg.warn("Upload complete: " .. upload_id)
                    submit_subtitle_request(upload_id, audio_lang, function(sr_data, sr_err)
                        if sr_err or not sr_data then
                            msg.warn("submit_subtitle_request failed: " .. tostring(sr_err))
                            transcription_active = false
                            return
                        end

                        current_subtitle_id = sr_data.subtitle_id
                        msg.warn("Subtitle request submitted: " .. current_subtitle_id)

                        state.subtitle_id = current_subtitle_id
                        set_state(work_dir, state)

                        set_phase("processing")
                        msg.warn("subtitle_id=" .. current_subtitle_id)
                        current_progress = sr_data.progress or 0
                        update_main_menu()
                        mp.osd_message("Processing...", DEFAULT_MESSAGE_DISPLAY_TIME_S)

                        msg.warn("Waiting " .. INITIAL_POLL_DELAY .. "s before starting has_file polling...")
                        mp.add_timeout(INITIAL_POLL_DELAY, function()
                            if transcription_active then
                                start_has_file_polling()
                            end
                        end)
                    end)
                end)
            end)
        end)
    end

    local function proceed_with_transcription()
        mp.osd_message("Starting subtitles...", DEFAULT_MESSAGE_DISPLAY_TIME_S)
        if file_exists(audio_file) then
            msg.warn("Using cached audio: " .. audio_file)
            set_phase("uploading")
            proceed_with_upload()
        else
            local temp_audio = audio_file:gsub("%." .. fmt .. "$", ".tmp." .. fmt)
            msg.warn("Extracting audio to: " .. temp_audio)
            set_phase("extracting")
            update_main_menu()
            extract_full_audio(video_path, temp_audio, function(extract_success)
                if not extract_success or not file_exists(temp_audio) then
                    local err = "Audio extraction failed"
                    current_last_error = err
                    sync_runtime_state()
                    mp.osd_message(err, ERROR_MESSAGE_DISPLAY_TIME_S)
                    os.remove(temp_audio)
                    transcription_active = false
                    return
                end
                os.rename(temp_audio, audio_file)
                set_phase("uploading")
                proceed_with_upload()
            end)
        end
    end

    set_phase("checking_existing")
    if cfg.ignore_community_subs then
        msg.warn("Ignoring community subs, proceeding with transcription")
        proceed_with_transcription()
        return
    end
    mp.osd_message("Checking for existing subtitles...", DEFAULT_MESSAGE_DISPLAY_TIME_S)
    local file_hash = nexus_utils.get_file_hash(video_path)
    if not file_hash then
        msg.warn("Could not compute file hash, proceeding with transcription")
        proceed_with_transcription()
        return
    end

    msg.warn("Searching for existing subtitles: hash=" .. file_hash ..
        " model=" .. cfg.model .. " lang=" .. cfg.subtitle_language_code)
    search_existing_subtitles(file_hash, function(search_data, search_err)
        if search_err then
            msg.warn("Cache search error: " .. tostring(search_err) .. ", proceeding with transcription")
            proceed_with_transcription()
            return
        end
        msg.warn("Cache search result: " .. utils.format_json(search_data or {}))
        if not search_data or not search_data.subtitle_ids or not search_data.subtitle_ids[1] then
            msg.warn("No cached subtitles found, proceeding with transcription")
            proceed_with_transcription()
            return
        end

        local cached_id = search_data.subtitle_ids[1]
        msg.warn("Found cached subtitle: " .. cached_id)

        local function download_existing_subtitles()
            get_download_link(cached_id, function(dl_data, dl_err)
                if dl_err == "http_402" then
                    if cfg.auto_purchase_past_daily_limit then
                        msg.warn("Download limit reached, purchasing subtitle...")
                        mp.osd_message("Purchasing subtitle...", DEFAULT_MESSAGE_DISPLAY_TIME_S)
                        purchase_subtitle(cached_id, function(_, purchase_err)
                            if purchase_err then
                                proceed_with_transcription()
                                return
                            end
                            msg.warn("Purchase successful, retrying download...")
                            download_existing_subtitles()
                        end)
                    else
                        msg.warn("Download limit reached, auto-purchase disabled")
                        proceed_with_transcription()
                    end
                    return
                end

                if not dl_data or not dl_data.download_link then
                    proceed_with_transcription()
                    return
                end

                local is_demo = dl_data.is_demo or false
                local suffix = is_demo and "-demo" or ""
                local srt_path = utils.join_path(work_dir,
                    cfg.model .. "-" .. cfg.subtitle_language_code .. suffix .. ".srt")

                download_subtitles(dl_data.download_link, srt_path, function(success)
                    if not success then
                        msg.warn("Failed to download existing subtitles. Proceeding with transcription...")
                        proceed_with_transcription()
                        return
                    end

                    load_subtitle_file_into_mpv(srt_path)
                    state.subtitle_id = cached_id
                    state.subtitle_status = "COMPLETED"
                    state.is_demo = is_demo
                    set_state(work_dir, state)
                    transcription_active = false
                    set_phase(nil)
                    update_main_menu()

                    if is_demo then
                        mp.osd_message("Demo subtitle loaded (10 min preview)", ERROR_MESSAGE_DISPLAY_TIME_S)
                    else
                        mp.osd_message("Loaded existing user subtitles", DEFAULT_MESSAGE_DISPLAY_TIME_S)
                    end
                end)
            end)
        end

        download_existing_subtitles()
    end)
end

local function stop_ai_transcription()
    if not transcription_active then
        msg.warn("Transcription not active, ignoring stop request")
        return
    end

    msg.warn("Stopping transcription...")
    stop_all_timers()
    transcription_active = false
    set_phase(nil)
    current_progress = 0
    last_logged_progress = 0
    sync_runtime_state()

    msg.warn("AI transcription stopped")
    mp.osd_message("Live subtitles disabled", DEFAULT_MESSAGE_DISPLAY_TIME_S)
end


local function update_config(api_key, domain, language, model, base_dir)
    msg.warn("=== UPDATING CONFIG ===")
    msg.warn("API Key: " .. tostring(api_key))
    msg.warn("Domain: " .. tostring(domain))
    msg.warn("Language: " .. tostring(language))
    msg.warn("Model: " .. tostring(model))
    msg.warn("Base Dir: " .. tostring(base_dir))

    cfg.api_key = api_key
    cfg.domain = domain
    cfg.subtitle_language_code = language
    cfg.model = model
    cfg.base_dir = base_dir
end

local function init_state(base_dir)
    msg.warn("=== INIT_STATE CALLED ===")
    msg.warn("Base dir: " .. tostring(base_dir))

    if base_dir and base_dir ~= "" then
        cfg.base_dir = base_dir
        if log_file_handle then log_file_handle:close() end
        log_file_handle, log_file_path = nil, nil
    end

    load_config_from_file()
    sync_config()
    validate_api_key()
    if not nexus_utils.is_iina() then
        mp.set_property_number("volume", cfg.volume)
    end

    local work_dir = get_work_dir()
    msg.warn("Full work dir: " .. tostring(work_dir))
    local state = get_state(work_dir)
    msg.warn("State from file: " .. utils.format_json(state))
    sync_runtime_state()
    msg.warn("Property user-data/nexus/state set")

    local path = mp.get_property("path")
    if not path or path == "" or is_protocol(path) then
        msg.warn("init_state: no valid path yet, skipping auto-start")
        return
    end

    if state.subtitle_status == "COMPLETED" then
        local srt_file = utils.join_path(work_dir, cfg.model .. "-" .. cfg.subtitle_language_code .. ".srt")
        if file_exists(srt_file) then
            msg.warn("Loading completed subtitles: " .. srt_file)
            load_subtitle_file_into_mpv(srt_file)
        end
        return
    end

    local is_processing = state.subtitle_id and state.subtitle_status ~= "COMPLETED"
    local should_auto_start = cfg.auto_transcribe_new_files and not state.subtitle_id
    msg.warn("init_state decision: is_processing=" .. tostring(is_processing) ..
        " should_auto_start=" .. tostring(should_auto_start) .. " path=" .. path)

    if is_processing or should_auto_start then
        start_ai_transcription()
    end
end

local function start_ai_transcription_with_config(api_key, domain, language, model, base_dir)
    msg.warn("=== START_TRANSCRIPTION_WITH_CONFIG CALLED ===")
    update_config(api_key, domain, language, model, base_dir)
    start_ai_transcription()
end

local function reset_state()
    local work_dir = get_work_dir()
    platform.current.cleanup_directory(work_dir)
    stop_all_timers()
    transcription_active = false
    current_subtitle_id = nil
    current_download_link = nil
    current_etag = nil
    set_phase(nil)
    current_progress = 0
    last_logged_progress = 0
    sync_runtime_state()
    mp.osd_message("State reset", DEFAULT_MESSAGE_DISPLAY_TIME_S)
    msg.warn("State reset (deleted dir): " .. work_dir)
end



local function open_subtitle_url()
    local state = get_state(get_work_dir())
    if state.subtitle_id then
        local uuid = extract_uuid(state.subtitle_id)
        local url = "https://" .. cfg.domain_web .. "/ai/sr/" .. uuid .. "/"
        msg.warn("Opening subtitle URL: " .. url)
        platform.current.open(url)
    else
        msg.warn("No subtitle_id found in state")
    end
end

local function open_work_dir()
    platform.current.open(get_work_dir())
end

local function open_config_file()
    msg.warn("Opening config file: " .. get_config_path())
    platform.current.open(get_config_path())
end

local function open_logs_dir()
    platform.current.open(get_logs_dir())
end

local function open_logs_file()
    if log_file_path then platform.current.open(log_file_path) end
end

local SUPPORTED_MODELS = {
    { code = "vega-preview", name = "vega-preview" },
    { code = "lulu-2504", name = "lulu-2504" },
}

local function get_language_name(code)
    for _, lang in pairs(SUPPORTED_SUBTITLE_LANGUAGES) do
        if type(lang) == "table" and lang.code == code then return lang.name end
    end
    for _, lang in pairs(SUPPORTED_AUDIO_LANGUAGES) do
        if type(lang) == "table" and lang.code == code then return lang.name end
    end
    return code
end

local function cmd(name, ...)
    local args = { "script-message-to", SELF, name }
    for _, v in ipairs({...}) do table.insert(args, v) end
    return args
end

local function build_logs_submenu()
    local items = {}
    local recent = {}
    for i = math.max(1, #log_buffer - 9), #log_buffer do
        if log_buffer[i] then table.insert(recent, log_buffer[i]) end
    end
    if #recent == 0 then
        table.insert(items, { title = "(no logs)", muted = true, selectable = false })
    else
        for _, line in ipairs(recent) do
            table.insert(items, { title = line:sub(1, 80), muted = true, selectable = false })
        end
    end
    table.insert(items, { separator = true, selectable = false })
    table.insert(items, { title = "Open Logs File", icon = "description", value = cmd("open-logs-file") })
    table.insert(items, { title = "Open Logs Dir", icon = "folder", value = cmd("open-logs-dir") })
    return { title = "Recent Logs", icon = "article", items = items }
end

local function build_advanced_submenu()
    local pur_icon = cfg.auto_purchase_past_daily_limit and "check_box" or "check_box_outline_blank"
    local pur_val = cfg.auto_purchase_past_daily_limit and "false" or "true"
    local ign_icon = cfg.ignore_community_subs and "check_box" or "check_box_outline_blank"
    local ign_val = cfg.ignore_community_subs and "false" or "true"
    local adv_items = {
        { title = "Buy Existing Subs if Past Daily Limit", icon = pur_icon,
            value = cmd("set-config-auto-purchase", pur_val) },
        { title = "Ignore Community Subs", icon = ign_icon,
            value = cmd("set-config-ignore-community", ign_val) },
        { title = "Audio Format: " .. (cfg.audio_format or "auto"):upper(), icon = "audio_file",
            value = cmd("toggle-audio-format"), keep_open = true },
        { separator = true, selectable = false },
        { title = "Open Work Dir", icon = "folder_open", value = cmd("open-work-dir") },
        { title = "Open Config File", icon = "description", value = cmd("open-config-file") },
        { title = "Reset File State", icon = "refresh", value = cmd("reset-state") },
    }
    table.insert(adv_items, build_logs_submenu())
    table.insert(adv_items, { separator = true, selectable = false })
    local ver = read_version_file(VERSION_FILE) or "unknown"
    table.insert(adv_items, { title = "Version: " .. ver, icon = "info",
        muted = true, selectable = false })
    return { title = "Advanced", icon = "settings", items = adv_items }
end

local function build_main_menu_items()
    local items = {}

    if api_key_valid ~= true then
        table.insert(items, { title = "Login", icon = "login", value = cmd("start-device-login") })
        table.insert(items, { separator = true, selectable = false })
        table.insert(items, { title = "Check for Updates", icon = "update",
            value = cmd("check-for-updates") })
        table.insert(items, build_advanced_submenu())
        return items
    end

    local state = get_state(get_work_dir())
    local is_processing = state.subtitle_id and state.subtitle_status ~= "COMPLETED"

    if transcription_active and current_phase == "extracting" then
        local hint = current_extraction_pct > 0 and string.format("%d%%", current_extraction_pct) or nil
        table.insert(items, { title = "Extracting Audio...", icon = "hourglass_top",
            hint = hint, selectable = false })
    elseif transcription_active and current_phase == "uploading" then
        local title = string.format("Uploading (%.1f MB)...", current_upload_size_mb)
        local hint = current_upload_pct > 0 and string.format("%d%%", current_upload_pct) or nil
        table.insert(items, { title = title, icon = "cloud_upload", hint = hint, selectable = false })
    elseif is_processing then
        local pct = current_progress or 0
        local hint = pct > 0 and string.format("%d%%", pct) or nil
        table.insert(items, { title = "View Subtitles", icon = "open_in_new",
            hint = hint, value = cmd("open-subtitle-url") })
    elseif state.subtitle_status == "COMPLETED" then
        table.insert(items, { title = "View Subtitles", icon = "open_in_new",
            value = cmd("open-subtitle-url") })
    else
        table.insert(items, { title = "Start Live Subtitles", icon = "subtitles",
            value = cmd("start-ai-transcription") })
        table.insert(items, { title = "Streams as you watch · ~60s for first line",
            muted = true, selectable = false, italic = true })
    end

    table.insert(items, { separator = true, selectable = false })

    if current_last_error then
        table.insert(items, { title = "Last Error: " .. current_last_error, icon = "error",
            muted = true, selectable = false })
    end

    local audio_lang_hint = get_language_name(get_audio_language(get_work_dir()))
    table.insert(items, { title = "Audio Language", icon = "record_voice_over",
        hint = audio_lang_hint, value = cmd("open-audio-language-menu") })
    local lang_hint = get_language_name(cfg.subtitle_language_code)
    table.insert(items, { title = "Subtitle Language", icon = "language",
        hint = lang_hint, value = cmd("open-subtitle-language-menu") })
    table.insert(items, { title = "Model", icon = "smart_toy",
        hint = cfg.model, value = cmd("open-model-menu") })
    local api_hint = cfg.api_key:sub(1, 8) .. "..."
    table.insert(items, { title = "API Key", icon = "key",
        hint = api_hint, value = cmd("show-api-menu") })
    table.insert(items, { title = "Logout", icon = "logout",
        hint = user_name, value = cmd("logout") })

    table.insert(items, { separator = true, selectable = false })

    local auto_icon = cfg.auto_transcribe_new_files and "check_box" or "check_box_outline_blank"
    local auto_val = cfg.auto_transcribe_new_files and "false" or "true"
    table.insert(items, { title = "Auto Transcribe New Files", icon = auto_icon,
        value = cmd("set-config-auto-transcribe", auto_val) })

    table.insert(items, { separator = true, selectable = false })

    table.insert(items, { title = "Check for Updates", icon = "update",
        value = cmd("check-for-updates") })

    if user_plan == PLAN_FREE_NAME then
        table.insert(items, { title = "Get Premium", icon = "star", bold = true,
            value = cmd("open-premium-page") })
    elseif user_plan then
        table.insert(items, { title = "Premium", icon = "verified", muted = true, selectable = false })
    end

    table.insert(items, build_advanced_submenu())

    return items
end

local function show_main_menu()
    local menu = {
        type  = "menu",
        title = "Nexus Main Menu",
        id    = "nexus-main",
        items = build_main_menu_items(),
    }
    mp.commandv("script-message-to", "uosc", "open-menu", utils.format_json(menu))
end

update_main_menu = function()
    sync_runtime_state()
    local menu = {
        type  = "menu",
        title = "Nexus Main Menu",
        id    = "nexus-main",
        items = build_main_menu_items(),
    }
    mp.commandv("script-message-to", "uosc", "update-menu", utils.format_json(menu))
end

local function menu_with_back(title, id, items)
    table.insert(items, 1, { separator = true, selectable = false })
    table.insert(items, 1, { title = "Back", icon = "arrow_back", value = cmd("open-menu") })
    mp.commandv("script-message-to", "uosc", "open-menu", utils.format_json({
        type = "menu", title = title, id = id, items = items
    }))
end

local function show_language_select_menu()
    local current = cfg.subtitle_language_code
    local items = {}
    for _, lang in pairs(SUPPORTED_SUBTITLE_LANGUAGES) do
        if type(lang) == "table" and lang.code and lang.name then
            table.insert(items, {
                title = lang.name,
                icon = lang.code == current and "check" or nil,
                active = lang.code == current,
                value = { "script-message-to", SELF, "select-subtitle-language", lang.code }
            })
        end
    end
    menu_with_back("Subtitle Language", "subtitle-language-select", items)
end

local function show_audio_language_menu()
    local current = get_audio_language(get_work_dir())
    local items = {}
    for _, lang in pairs(SUPPORTED_AUDIO_LANGUAGES) do
        if type(lang) == "table" and lang.code and lang.name then
            table.insert(items, {
                title = lang.name,
                icon = lang.code == current and "check" or nil,
                active = lang.code == current,
                value = { "script-message-to", SELF, "select-audio-language", lang.code }
            })
        end
    end
    menu_with_back("Audio Language", "audio-language-select", items)
end

local function show_model_select_menu()
    local current = cfg.model
    local items = {}
    for _, m in ipairs(SUPPORTED_MODELS) do
        table.insert(items, {
            title = m.name,
            icon = m.code == current and "check" or nil,
            active = m.code == current,
            value = { "script-message-to", SELF, "select-model", m.code }
        })
    end
    menu_with_back("Model", "model-select", items)
end

local function show_api_key_menu()
    menu_with_back("API Key Settings", "api-key-settings", {
        { title = "Set API Key",  value = { "script-message-to", SELF, "set-api-key" } },
        { title = "Show API Key", value = { "script-message-to", SELF, "show-api-key" } },
    })
end

local function set_api_key()
    input.get({
        prompt = "Enter your API key:",
        submit = function(user_input)
            local trimmed_input = user_input and user_input:match("^%s*(.-)%s*$") or ""

            if trimmed_input == "" then
                mp.osd_message("API key cannot be empty.", DEFAULT_MESSAGE_DISPLAY_TIME_S)
                input.terminate()
                return
            end

            cfg.api_key = trimmed_input
            save_config_key("api_key", cfg.api_key)
            mp.osd_message("API key saved", DEFAULT_MESSAGE_DISPLAY_TIME_S)
            input.terminate()
        end,
    })
end

local function show_api_key()
    mp.osd_message("API key: " .. cfg.api_key:sub(1, 8), DEFAULT_MESSAGE_DISPLAY_TIME_S)
end


local device_auth_timer = nil

local function start_device_login()
    msg.warn("Starting device login flow")
    mp.osd_message("Starting login...", DEFAULT_MESSAGE_DISPLAY_TIME_S)
    api_call("POST", "/v1/device/authorize/", {
        application_type = cfg.application_type,
        application_id = cfg.application_id
    }, function(data, err)
        if err or not data or not data.user_code then
            msg.warn("Device login failed to get user code")
            return
        end
        msg.warn("Device login: got user_code=" .. data.user_code)
        pending_device_code = data.user_code
        sync_runtime_state()
        mp.osd_message("Opening browser in " .. BROWSER_OPEN_DELAY_S .. "s...\n\nEnter code: " .. data.user_code, 999)
        mp.add_timeout(BROWSER_OPEN_DELAY_S, function()
            platform.current.open(data.verification_url)
        end)
        local device_code = data.device_code
        local poll_interval = data.interval or 5
        local expires_at = os.time() + (data.expires_in or 900)
        device_auth_timer = mp.add_periodic_timer(poll_interval, function()
            if os.time() > expires_at then
                msg.warn("Device login expired")
                device_auth_timer:kill()
                device_auth_timer = nil
                pending_device_code = nil
                sync_runtime_state()
                mp.osd_message("Login expired. Try again.", ERROR_MESSAGE_DISPLAY_TIME_S)
                return
            end
            api_call("POST", "/v1/device/token/", { device_code = device_code }, function(token_data)
                if token_data and token_data.api_key then
                    msg.warn("Device login successful, API key received")
                    device_auth_timer:kill()
                    device_auth_timer = nil
                    pending_device_code = nil
                    save_config_key("api_key", token_data.api_key)
                    mp.osd_message("Login successful!", LONG_MESSAGE_DISPLAY_TIME_S)
                    validate_api_key()
                end
            end, true, true)
        end)
    end, false, true)
end

local function logout()
    msg.warn("User logout")
    save_config_key("api_key", "")
    api_key_valid = false
    user_plan = nil
    user_name = nil
    mp.osd_message("Logged out", DEFAULT_MESSAGE_DISPLAY_TIME_S)
    update_main_menu()
end


mp.register_script_message("select-audio-language", function(lang_code)
    set_audio_language(get_work_dir(), lang_code)
    mp.osd_message("Audio language set to: " .. get_language_name(lang_code), DEFAULT_MESSAGE_DISPLAY_TIME_S)
    update_main_menu()
end)
mp.register_script_message("select-subtitle-language", function(lang_code)
    local language = Language.fromCode(lang_code)
    cfg.subtitle_language_code = language.code
    save_config_key("subtitle_language_code", language.code)

    mp.osd_message("Subtitle language set to: " .. language.name, DEFAULT_MESSAGE_DISPLAY_TIME_S)
end)

mp.register_script_message("open-audio-language-menu", show_audio_language_menu)
mp.register_script_message("open-subtitle-language-menu",   show_language_select_menu)
mp.register_script_message("open-model-menu",      show_model_select_menu)
mp.register_script_message("select-model", function(model_code)
    cfg.model = model_code
    save_config_key("model", model_code)
    mp.osd_message("Model set to: " .. model_code, DEFAULT_MESSAGE_DISPLAY_TIME_S)
end)
mp.register_script_message("show-api-menu",        show_api_key_menu)
mp.register_script_message("set-api-key",          set_api_key)
mp.register_script_message("show-api-key",         show_api_key)
mp.register_script_message("open-menu",            show_main_menu)
mp.register_script_message("start-ai-transcription-with-config", start_ai_transcription_with_config)
mp.register_script_message("init-state", init_state)
mp.register_script_message("check-for-updates", function() check_for_update(false) end)
mp.register_script_message("update-config", update_config)

mp.register_script_message("set-config-api-key", function(value)
    save_config_key("api_key", value)
end)
mp.register_script_message("set-config-domain", function(value)
    save_config_key("domain", value)
end)
mp.register_script_message("set-audio-language", function(value)
    set_audio_language(get_work_dir(), value)
    sync_runtime_state()
end)
mp.register_script_message("set-config-subtitle-language", function(value)
    save_config_key("subtitle_language_code", value)
    sync_runtime_state()
end)
mp.register_script_message("set-config-model", function(value)
    save_config_key("model", value)
    sync_runtime_state()
end)
mp.register_script_message("set-config-auto-transcribe", function(value)
    save_config_key("auto_transcribe_new_files", value == "true")
end)
mp.register_script_message("set-config-auto-purchase", function(value)
    save_config_key("auto_purchase_past_daily_limit", value == "true")
end)
mp.register_script_message("set-config-ignore-community", function(value)
    save_config_key("ignore_community_subs", value == "true")
end)
mp.register_script_message("toggle-audio-format", function()
    local cycle = { auto = "mp3", mp3 = "wav", wav = "auto" }
    save_config_key("audio_format", cycle[cfg.audio_format] or "wav")
    update_main_menu()
end)
mp.register_script_message("set-config-audio-format", function(value)
    save_config_key("audio_format", value)
    update_main_menu()
end)
mp.register_script_message("start-ai-transcription", start_ai_transcription)
mp.register_script_message("stop-ai-transcription", stop_ai_transcription)
mp.register_script_message("reset-state", reset_state)
mp.register_script_message("open-subtitle-url", open_subtitle_url)
mp.register_script_message("open-work-dir", open_work_dir)
mp.register_script_message("open-config-file", open_config_file)
mp.register_script_message("open-logs-dir", open_logs_dir)
mp.register_script_message("open-logs-file", open_logs_file)
mp.register_script_message("open-url", function(url) platform.current.open(url) end)
mp.register_script_message("open-premium-page", function()
    platform.current.open("https://" .. cfg.domain_web .. "/products/pricing/")
end)
mp.register_script_message("start-device-login", start_device_login)
mp.register_script_message("logout", logout)
mp.register_script_message("test-error", function() (nil)() end)

mp.add_key_binding("b", "open-nexus-menu", show_main_menu)
mp.add_key_binding("Ctrl+t", "start-ai-transcription", start_ai_transcription)
mp.add_key_binding("Ctrl+Shift+s", "stop-ai-transcription", stop_ai_transcription)

mp.register_event("log-message", function(e)
    pcall(function()
        local timestamp = os.date("%H:%M:%S")
        local text = (e.text or ""):gsub("\n$", "")
        local line = string.format("[%s][%s] %s: %s", timestamp, e.level or "?", e.prefix or "?", text)
        table.insert(log_buffer, line)
        if #log_buffer > LOG_BUFFER_MAX then table.remove(log_buffer, 1) end
        local f = get_log_file()
        if f then
            f:write(line .. "\n")
            f:flush()
        end
    end)
end)

mp.register_event("file-loaded", function()
    local path = mp.get_property("path") or "(none)"
    msg.warn("file-loaded event: " .. path)
    if transcription_active then
        stop_ai_transcription()
    end
    if not cfg.base_dir or cfg.base_dir == "" then
        mp.commandv("script-message", "init-state", "", "", "", "")
    end
end)

mp.register_event("shutdown", function()
    msg.warn("shutdown event: saving state")
    local vol = mp.get_property_number("volume")
    if vol then save_config_key("volume", vol) end
    transcription_active = false
    stop_all_timers()
    if log_file_handle then log_file_handle:close() end
    cleanup_old_logs()
end)

if not nexus_utils.is_iina() and not SKIP_AUTO_UPDATE then
    mp.register_event("start-file", on_startup_update_check)
    mp.register_event("idle", on_startup_update_check)
end



mp.enable_messages("info")
msg.warn("Running startup health check")
check_api_health()
validate_api_key()
