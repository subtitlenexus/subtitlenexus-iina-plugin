local utils = require "mp.utils"

local function init_cfg()
    local cfg = {
        api_key  = "NOT_SET",
        domain = "api.subtitlenexus.com",
        domain_web = "subtitlenexus.com",
        subtitle_language_code = "en",
        default_audio_language_code = "ja",
        model = "vega-preview",
        base_dir = "",
        advanced_mode = false,
        auto_transcribe_new_files = false,
        auto_purchase_past_daily_limit = false,
        ignore_community_subs = false,
        audio_format = "auto",  -- "auto", "mp3", or "wav"
        volume = 50,
        application_id = ""
    }
    return cfg
end

local function generate_uuid()
    math.randomseed(os.time() + os.clock() * 1000000)
    local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
    return template:gsub("[xy]", function(c)
        local v = (c == "x") and math.random(0, 15) or math.random(8, 11)
        return string.format("%x", v)
    end)
end

local function get_file_hash_sha256(filePath, mp)
    if not filePath or not mp then
        return nil
    end

    local chunk_size = 65536

    local file = io.open(filePath, "rb")
    if not file then
        print("Error: Could not open file: " .. filePath)
        return nil
    end

    local data_start = file:read(chunk_size)
    file:seek("set", chunk_size)
    local size = file:seek("end", -chunk_size) + chunk_size
    local data_end = file:read(chunk_size)
    file:close()

    if not data_start or not data_end then
        print("Error: Could not read file chunks")
        return nil
    end

    local hash_input = data_start .. data_end .. tostring(size)

    local temp_dir = os.getenv("TMPDIR") or os.getenv("TEMP") or "/tmp/"
    if not temp_dir:match("/$") then
        temp_dir = temp_dir .. "/"
    end
    local temp_file = temp_dir .. "nexus_hash_" .. generate_uuid() .. ".tmp"

    local temp = io.open(temp_file, "wb")
    if not temp then
        print("Error: Could not create temp file")
        return nil
    end
    temp:write(hash_input)
    temp:close()

    local is_windows = package.config:sub(1, 1) == "\\"

    local sha_cmd
    if is_windows then
        sha_cmd = {"certutil", "-hashfile", temp_file, "SHA256"}
    else
        sha_cmd = {"shasum", "-a", "256", temp_file}
    end

    local res = mp.command_native({
        name = "subprocess",
        capture_stdout = true,
        capture_stderr = true,
        args = sha_cmd
    })

    os.remove(temp_file)

    if res and res.status == 0 and res.stdout then
        local hash = res.stdout:match("(%x+)")
        if hash then
            return hash
        end
    end

    print("Error: SHA256 command failed")
    if res and res.stderr then
        print("stderr: " .. res.stderr)
    end
    return nil
end

local function get_file_hash(filePath, data_start, data_end, size)
    local chunk_size = 65536
    local max_size = 4294967296

    if filePath then
        local file = io.open(filePath, "rb")
        if not file then
            print("Error: Could not open file.")
            return false
        end
        data_start = file:read(chunk_size)
        file:seek("set", chunk_size)
        size = file:seek("end", -chunk_size) + chunk_size
        data_end = file:read(chunk_size)
        file:close()
    end

    local lo = size
    local hi = 0
    local a,b,c,d,e,f,g,h
    local hash_data = data_start .. data_end
    local overflow
    for i = 1, #hash_data, 8 do
        a, b, c, d, e, f, g, h = hash_data:byte(i, i+7)
        lo = lo + a + b*256 + c*65536 + d*16777216
        hi = hi + e + f*256 + g*65536 + h*16777216

        if lo > max_size then
            overflow = math.floor(lo / max_size)
            lo = lo - (overflow * max_size)
            hi = hi + overflow
        end

        if hi > max_size then
            overflow = math.floor(hi / max_size)
            hi = hi - (overflow * max_size)
        end
    end
    return string.format("%08x%08x", hi, lo)
end


local function read_json(path)
    local file = io.open(path, "r")
    if not file then return nil end
    local content = file:read("*a")
    file:close()
    local ok, data = pcall(utils.parse_json, content)
    return ok and data or nil
end

local function write_json(path, data)
    local file = io.open(path, "w")
    if not file then
        error("Could not open file: " .. path)
    end
    local jsonString = utils.format_json(data)
    file:write(jsonString)
    file:close()
end

local function sanitize_filename(filename)
    local name = filename:match("(.+)%..+$") or filename
    return name:gsub("[^%w]", "_"):lower()
end

local function bytes_to_mb(bytes)
    return bytes / 1048576
end

local function is_iina()
    return mp.get_property_native("user-data/nexus/is_iina") == true
end

return {
    init_cfg = init_cfg,
    generate_uuid = generate_uuid,
    get_file_hash = get_file_hash,
    get_file_hash_sha256 = get_file_hash_sha256,
    read_json = read_json,
    write_json = write_json,
    sanitize_filename = sanitize_filename,
    bytes_to_mb = bytes_to_mb,
    is_iina = is_iina
}
