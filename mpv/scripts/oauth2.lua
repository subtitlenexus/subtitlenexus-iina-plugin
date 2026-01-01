local mp = require 'mp'
local msg = require 'mp.msg'
local utils = require 'mp.utils'
local input = require 'mp.input'

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("(.*/)")
local platform = dofile(utils.join_path(script_dir, "platform.lua"))

local M = {}

M.CLIENT_ID = "8ii9bWG6ZNGoiASmk35c7kkJaclfB1iz9UNef4Iq"

function M.get_redirect_uri(domain)
    return "https://" .. domain .. "/users/~oauth-code/"
end

local function random_string(length)
    local chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    math.randomseed(os.time() + (tonumber(tostring({}):match("0x(%x+)")) or 0))
    local result = {}
    for _ = 1, length do
        table.insert(result, chars:sub(math.random(#chars), math.random(#chars)))
    end
    return table.concat(result)
end

local function sha256_base64url(data)
    local temp_file = platform.current.temp_dir .. "/nexus_pkce_" .. os.time()

    local f = io.open(temp_file, "wb")
    if not f then return nil end
    f:write(data)
    f:close()

    local res = mp.command_native({
        name = "subprocess", capture_stdout = true,
        args = platform.current.sha256_base64url_args(temp_file)
    })
    os.remove(temp_file)

    if res and res.status == 0 and res.stdout then
        local b64 = res.stdout:gsub("%s+", "")
        return b64:gsub("+", "-"):gsub("/", "_"):gsub("=", "")
    end
    return nil
end

function M.generate_pkce()
    local verifier = random_string(64)
    local challenge = sha256_base64url(verifier)
    return verifier, challenge
end

function M.get_auth_url(domain, code_challenge)
    local redirect_uri = M.get_redirect_uri(domain)
    local url = "https://%s/o/authorize/?client_id=%s&response_type=code" ..
        "&redirect_uri=%s&code_challenge=%s&code_challenge_method=S256"
    return string.format(url, domain, M.CLIENT_ID, redirect_uri, code_challenge)
end

function M.open_browser(url)
    mp.command_native({name = "subprocess", detach = true, args = platform.current.open_url(url)})
end

function M.exchange_code(domain, code, code_verifier, callback)
    local redirect_uri = M.get_redirect_uri(domain)
    mp.command_native_async({
        name = "subprocess",
        capture_stdout = true,
        capture_stderr = true,
        args = {
            "curl", "-s", "-X", "POST",
            "-d", "grant_type=authorization_code",
            "-d", "code=" .. code,
            "-d", "redirect_uri=" .. redirect_uri,
            "-d", "client_id=" .. M.CLIENT_ID,
            "-d", "code_verifier=" .. code_verifier,
            "https://" .. domain .. "/o/token/"
        }
    }, function(_, res)
        if not res or res.status ~= 0 then
            callback(nil, "Network error")
            return
        end
        local ok, data = pcall(utils.parse_json, res.stdout)
        if ok and data and data.access_token then
            callback(data)
        else
            callback(nil, data and data.error_description or "Token exchange failed")
        end
    end)
end

function M.refresh_token(domain, refresh_token, callback)
    mp.command_native_async({
        name = "subprocess",
        capture_stdout = true,
        args = {
            "curl", "-s", "-X", "POST",
            "-d", "grant_type=refresh_token",
            "-d", "refresh_token=" .. refresh_token,
            "-d", "client_id=" .. M.CLIENT_ID,
            "https://" .. domain .. "/o/token/"
        }
    }, function(_, res)
        if not res or res.status ~= 0 then
            callback(nil, "Network error")
            return
        end
        local ok, data = pcall(utils.parse_json, res.stdout)
        if ok and data and data.access_token then
            callback(data)
        else
            callback(nil, "Refresh failed")
        end
    end)
end

function M.start_login(domain, on_success, on_error)
    local verifier, challenge = M.generate_pkce()
    if not challenge then
        on_error("Failed to generate PKCE challenge")
        return
    end

    local url = M.get_auth_url(domain, challenge)
    M.open_browser(url)

    mp.osd_message("Browser opened. After login, copy the code and press 'L' to enter it.", 5)

    M._pending = {domain = domain, verifier = verifier, on_success = on_success, on_error = on_error}
end

function M.enter_code()
    if not M._pending then
        mp.osd_message("No pending login. Press Ctrl+L to start.", 2)
        return
    end

    input.get({
        prompt = "Paste authorization code:",
        submit = function(code)
            input.terminate()
            code = code and code:match("^%s*(.-)%s*$") or ""
            if code == "" then
                mp.osd_message("Cancelled", 2)
                M._pending = nil
                return
            end

            mp.osd_message("Exchanging code...", 2)
            M.exchange_code(M._pending.domain, code, M._pending.verifier, function(tokens, err)
                if tokens then
                    M._pending.on_success(tokens)
                else
                    M._pending.on_error(err or "Unknown error")
                end
                M._pending = nil
            end)
        end
    })
end

return M
