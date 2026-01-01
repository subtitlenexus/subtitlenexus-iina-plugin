local mp = require "mp"
local msg = require 'mp.msg'
local utils = require "mp.utils"

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("(.*/)")
local platform = dofile(utils.join_path(script_dir, "platform.lua"))

local MPV_CONFIG_DIR = mp.command_native({"expand-path", "~~/"})
local file_paths = platform.get_file_paths(MPV_CONFIG_DIR)

local download_active = false
local total_file_size = 0
local cached_release = nil

local DEFAULT_MESSAGE_DISPLAY_TIME_S = 4
local DEFAULT_EXIT_TIMEOUT_S = 2
local PROGRESS_CHECK_TIMER_S = 0.5

local function execute_installer(installer_path)
    msg.info("[update] Executing installer: " .. installer_path)
    local result, error_msg = platform.execute_installer(installer_path)
    if not result and error_msg then
        mp.osd_message(error_msg, DEFAULT_MESSAGE_DISPLAY_TIME_S)
        return
    end
    mp.add_timeout(DEFAULT_EXIT_TIMEOUT_S, function() os.remove(installer_path) end)
    mp.add_timeout(DEFAULT_EXIT_TIMEOUT_S, function() mp.command("quit") end)
end

local function find_installer_in_directory(extract_dir)
    local installer_path = file_paths.extracted_installer_path(extract_dir)
    if utils.file_info(installer_path) then
        return installer_path
    end
    return nil
end

local function handle_download_complete(download_path)
    download_active = false
    mp.osd_message("Download complete! Extracting...", 2)

    local extract_dir = file_paths.temp_extract_dir
    platform.current.create_directory(extract_dir)

    if platform.current.extract_zip(download_path, extract_dir) then
        local installer_path = find_installer_in_directory(extract_dir)
        if installer_path then
            mp.osd_message("Installer found! Starting installation...", 2)
            os.remove(download_path)
            mp.add_timeout(1, function()
                execute_installer(installer_path)
                mp.add_timeout(10, function()
                    platform.current.cleanup_directory(extract_dir)
                end)
            end)
        else
            mp.osd_message("Installer not found in extracted files", DEFAULT_MESSAGE_DISPLAY_TIME_S)
        end
    else
        mp.osd_message("Failed to extract update", DEFAULT_MESSAGE_DISPLAY_TIME_S)
    end
end

local function show_download_percentage(percent)
    mp.osd_message(string.format("Downloading update: %d%%", percent), 1)
end

local function get_file_size(url)
    local result = mp.command_native({
        name = "subprocess",
        args = { "curl", "-fsSLI", url },
        capture_stdout = true,
        playback_only = false,
    })
    if result.status == 0 and result.stdout then
        local last_len
        for len in result.stdout:gmatch("[Cc]ontent%-[Ll]ength:%s*(%d+)") do
            last_len = len
        end
        if last_len then
            local n = tonumber(last_len)
            if n and n > 0 then return n end
        end
    end
    return nil
end

local function monitor_file_progress(download_path)
    local function check_file_size()
        if not download_active then return end
        local file_info = utils.file_info(download_path)
        if file_info then
            local percent = math.min(100, math.floor((file_info.size / total_file_size) * 100))
            show_download_percentage(percent)
            if file_info.size >= total_file_size then
                handle_download_complete(download_path)
                return
            end
        end
        mp.add_timeout(PROGRESS_CHECK_TIMER_S, check_file_size)
    end
    mp.add_timeout(PROGRESS_CHECK_TIMER_S, check_file_size)
end

local function download_with_size_progress(url, download_path, file_size)
    total_file_size = file_size
    download_active = true
    mp.command_native({
        name = "subprocess",
        args = { "curl", "-L", "-o", download_path, "--progress-bar", url },
        detach = true,
        playback_only = false,
    })
    monitor_file_progress(download_path)
end

local function download_without_size_progress(url, download_path)
    mp.osd_message("Downloading update...", 60)
    mp.command_native_async({
        name = "subprocess",
        args = { "curl", "-fsSL", "-o", download_path, url },
        playback_only = false,
    }, function(success, res)
        if success and res and res.status == 0 then
            handle_download_complete(download_path)
        else
            mp.osd_message("Download failed", DEFAULT_MESSAGE_DISPLAY_TIME_S)
        end
    end)
end

local function get_size_from_partial_download(url)
    local result = mp.command_native({
        name = "subprocess",
        args = { "curl", "-fsSL", "-r", "0-0", "-D", "-", "-o", "/dev/null", url },
        capture_stdout = true,
        playback_only = false,
    })
    if result.status == 0 and result.stdout then
        local total = result.stdout:match("[Cc]ontent%-[Rr]ange:%s*bytes%s*%d+%-%d+%s*/%s*(%d+)")
        if total then return tonumber(total) end
        local clen = result.stdout:match("[Cc]ontent%-[Ll]ength:%s*(%d+)")
        if clen then return tonumber(clen) end
    end
    return nil
end

local function start_download_with_progress(download_url)
    if not download_url then
        mp.osd_message("Download not available for " .. platform.current.name, DEFAULT_MESSAGE_DISPLAY_TIME_S)
        return
    end

    local download_path = file_paths.download_path
    os.remove(download_path)

    local file_size = get_file_size(download_url) or get_size_from_partial_download(download_url)
    if file_size and file_size > 0 then
        download_with_size_progress(download_url, download_path, file_size)
    else
        msg.warn("[update] Could not determine file size, downloading without progress")
        download_without_size_progress(download_url, download_path)
    end
end

local function close_menu()
    mp.commandv("script-message-to", "uosc", "close-menu")
end

local function show_update_prompt(version, download_url)
    cached_release = { version = version, download_url = download_url }
    local popup = {
        type = "menu",
        title = "Update Available",
        id = "nexus-update-prompt",
        items = {
            { title = "A new version " .. version .. " is available. Install now?", value = nil, selectable = false },
            { title = "", value = nil, selectable = false },
            { title = "Yes", value = { "script-message-to", "update_nexus", "install-update" } },
            { title = "No", value = { "script-message-to", "update_nexus", "skip-update" } },
        }
    }
    mp.commandv("script-message-to", "uosc", "open-menu", utils.format_json(popup))
end

mp.register_script_message("install-update", function()
    close_menu()
    if cached_release and cached_release.download_url then
        start_download_with_progress(cached_release.download_url)
    else
        mp.osd_message("No download URL available", DEFAULT_MESSAGE_DISPLAY_TIME_S)
    end
end)

mp.register_script_message("skip-update", function()
    close_menu()
    mp.osd_message("Update skipped", DEFAULT_MESSAGE_DISPLAY_TIME_S)
end)

return {
    show_update_prompt = show_update_prompt,
}
