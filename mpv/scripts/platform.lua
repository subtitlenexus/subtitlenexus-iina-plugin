local mp = require 'mp'
local utils = require "mp.utils"

local function createPlatformEnum(platforms)
    local enum = {}
    local names = {}

    for key, data in pairs(platforms) do
        local platformData = data

        local platform = setmetatable(platformData, {
            __tostring = function(self) return self.name end,
            __eq = function(self, other)
                return type(other) == "string" and self.name == other
            end
        })

        enum[key] = platform
        names[platformData.name] = platform
    end

    enum.fromName = function(name) return names[name] end

    return setmetatable(enum, {
        __newindex = function() error("Cannot modify Platform enum") end
    })
end

local Platform = createPlatformEnum({
    WINDOWS = {
        name = "windows",
        download_filename = "nexus-mpv-installer-windows.zip",
        extracted_installer = "nexus-mpv-installer.exe",
        temp_extract_dir = "temp_update",
        null_device = "NUL",
        temp_dir = os.getenv("TEMP") or "C:\\Temp",
        curl_args = {"--ssl-no-revoke"},

        format_path = function(path)
            return path:gsub("/", "\\")
        end,

        create_directory = function(dir_path)
            os.execute("mkdir \"" .. dir_path .. "\"")
        end,

        extract_zip = function(zip_path, extract_dir)
            local args = {
                "powershell", "-Command",
                string.format("Expand-Archive -Path '%s' -DestinationPath '%s' -Force",
                             zip_path, extract_dir)
            }

            local result = utils.subprocess({
                args = args,
                cancellable = false,
            })

            return (result.status == 0)
        end,

        cleanup_directory = function(dir_path)
            os.execute("rmdir /s /q \"" .. dir_path .. "\"")
        end,

        execute_installer = function(installer_path)
            local args = {
                "cmd", "/c", "start", '""', "/B",
                installer_path, "/VERYSILENT", "/NORESTART", "/SUPPRESSMSGBOXES"
            }

            return utils.subprocess({
                args = args,
                detach = true,
                playback_only = false,
            })
        end,

        build_installer_args = function(installer_path)
            return {"cmd", "/c", "start", '""', "/B", installer_path, "/VERYSILENT", "/NORESTART", "/SUPPRESSMSGBOXES"}
        end,

        open = function(path)
            mp.commandv("run", "explorer", path)
        end,

        is_network_path = function(path)
            if path:match("^\\\\") then return true end
            return false
        end,

        shell_args = function(cmd)
            return { "cmd", "/c", cmd }
        end,

        sha256_base64url_args = function(file_path)
            local ps_cmd = "[Convert]::ToBase64String([System.Security.Cryptography.SHA256]" ..
                "::Create().ComputeHash([System.IO.File]::ReadAllBytes('" .. file_path .. "')))"
            return { "powershell", "-Command", ps_cmd }
        end,

        open_url = function(url)
            return { "cmd", "/c", "start", "", url }
        end
    },

    MACOS = {
        name = "macos",
        download_filename = "nexus-mpv-installer-macos.zip",
        extracted_installer = "Install Nexus MPV.app",
        temp_extract_dir = "temp_update",
        null_device = "/dev/null",
        temp_dir = os.getenv("TMPDIR") or "/tmp",
        curl_args = {},

        format_path = function(path)
            return path
        end,

        create_directory = function(dir_path)
            os.execute("mkdir -p \"" .. dir_path .. "\"")
        end,

        extract_zip = function(zip_path, extract_dir)
            local args = {"unzip", "-o", zip_path, "-d", extract_dir}

            local result = utils.subprocess({
                args = args,
                cancellable = false,
            })

            return (result.status == 0)
        end,

        cleanup_directory = function(dir_path)
            os.execute("rm -rf \"" .. dir_path .. "\"")
        end,

        execute_installer = function(installer_path)
            if installer_path:match("%.app$") then
                local args = {"open", "-n", installer_path}
                return utils.subprocess({
                    args = args,
                    detach = true,
                    playback_only = false,
                })
            else
                return nil, "Unable to locate App Bundle"
            end
        end,

        build_installer_args = function(installer_path)
            return {"sh", installer_path, "--silent", "--no-restart"}
        end,

        open = function(path)
            mp.commandv("run", "open", path)
        end,

        is_network_path = function(path)
            if path:match("^/Volumes/") then
                local volume = path:match("^/Volumes/([^/]+)")
                local local_volumes = { "Macintosh HD", "Macintosh HD - Data", "Recovery" }
                for _, v in ipairs(local_volumes) do
                    if volume == v then return false end
                end
                return true
            end
            return false
        end,

        shell_args = function(cmd)
            return { "sh", "-c", cmd }
        end,

        sha256_base64url_args = function(file_path)
            return { "sh", "-c", "shasum -a 256 -b '" .. file_path .. "' | xxd -r -p | base64" }
        end,

        open_url = function(url)
            return { "open", url }
        end
    }
})

local function detect_platform()
    if package.config:sub(1,1) == "\\" then
        return Platform.WINDOWS
    end

    local result = utils.subprocess({
        args = {"uname"},
        cancellable = false,
    })

    if result and result.stdout then
        local uname_output = result.stdout:lower():gsub("%s+", "")
        if uname_output:match("darwin") then
            return Platform.MACOS
        end
    end

    return Platform.MACOS
end

local current_platform = detect_platform()

local function get_file_paths(mpv_config_dir)
    return {
        download_path = current_platform.format_path(
            utils.join_path(mpv_config_dir, current_platform.download_filename)),
        temp_extract_dir = current_platform.format_path(
            utils.join_path(mpv_config_dir, current_platform.temp_extract_dir)),
        extracted_installer_path = function(extract_dir)
            return current_platform.format_path(utils.join_path(extract_dir, current_platform.extracted_installer))
        end
    }
end

return {
    Platform = Platform,
    current = current_platform,
    get_file_paths = get_file_paths
}
