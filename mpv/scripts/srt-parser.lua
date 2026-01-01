local Event = {}
Event.__index = Event

function Event:new(start_time, end_time, text)
    return setmetatable({
        start_time = start_time or 0,
        end_time = end_time or 0,
        text = text or ""
    }, self)
end

function Event:__index(key)
    if key == "duration" then
        return self.end_time - self.start_time
    end
    return Event[key]
end

local TIMESTAMP_PATTERN = "(%d+:%d+:%d+[,.]%d+)%s*[%-]+>%s*(%d+:%d+:%d+[,.]%d+)"
local SEQUENCE_PATTERN = "^%d+$"

local NEWLINE_PATTERN = "[^\r\n]+"
local WHITESPACE_STRIP_PATTERN = "^%s*(.-)%s*$"

local function timestamp_to_seconds(timestamp)
    if not timestamp then return 0 end
    local h, m, s, ms = timestamp:match("(%d+):(%d+):(%d+)[,.](%d+)")
    if not h then return 0 end
    return tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s) + tonumber(ms) / 1000
end

local function seconds_to_timestamp(seconds)
    if not seconds or seconds < 0 then seconds = 0 end
    local h = math.floor(seconds / 3600)
    local m = math.floor(seconds / 60) % 60
    local s = math.floor(seconds % 60)
    local ms = math.floor((seconds - math.floor(seconds)) * 1000)
    return string.format("%02d:%02d:%02d,%03d", h, m, s, ms)
end

local function is_sequence_number(line)
    return line:match(SEQUENCE_PATTERN) ~= nil
end

local function is_empty_or_next_sequence(line, next_line)
    return line == "" and (not next_line or is_sequence_number(next_line))
end

local function split_lines(content)
    local lines = {}
    for line in content:gmatch(NEWLINE_PATTERN) do
        table.insert(lines, line:match(WHITESPACE_STRIP_PATTERN))
    end
    return lines
end


local function parse_subtitle_block(lines, start_index)
    local i = start_index

    if not is_sequence_number(lines[i]) then return nil, i + 1 end
    i = i + 1

    if i > #lines then return nil, i end
    local start_ts, end_ts = lines[i]:match(TIMESTAMP_PATTERN)
    if not start_ts then return nil, i + 1 end

    local start_seconds = timestamp_to_seconds(start_ts)
    local end_seconds = timestamp_to_seconds(end_ts)
    i = i + 1

    local text_lines = {}
    while i <= #lines do
        local line = lines[i]
        local next_line = lines[i + 1]

        if is_sequence_number(line) or is_empty_or_next_sequence(line, next_line) then
            break
        end

        if line ~= "" then
            table.insert(text_lines, line)
        end
        i = i + 1
    end

    if #text_lines > 0 then
        local subtitle_text = table.concat(text_lines, "\n")
        local event = Event:new(start_seconds, end_seconds, subtitle_text)
        return event, i
    end

    return nil, i
end

local Subtitle = {}
Subtitle.__index = Subtitle

function Subtitle:new(filepath)
    local obj = setmetatable({
        filepath = filepath or "",
        events = {}
    }, self)

    if filepath and filepath ~= "" then
        obj:load()
    end

    return obj
end

function Subtitle:load()
    if not self.filepath or self.filepath == "" then
        return
    end

    local file = io.open(self.filepath, "r")
    if not file then
        self.events = {}
        return
    end

    local content = file:read("*all")
    file:close()

    local lines = split_lines(content)

    self.events = {}
    local i = 1

    while i <= #lines do
        if lines[i] == "" then
            i = i + 1
        else
            local event, next_i = parse_subtitle_block(lines, i)
            if event then
                table.insert(self.events, event)
            end
            i = next_i
        end
    end
end

function Subtitle:add_events(new_events)
    if not new_events or #new_events == 0 then
        return
    end

    for _, event in ipairs(new_events) do
        table.insert(self.events, event)
    end

    table.sort(self.events, function(a, b) return a.start_time < b.start_time end)
end

function Subtitle:parse_speeches_srt(srt_content, time_offset)
    time_offset = time_offset or 0

    local lines = split_lines(srt_content)

    local i = 1
    while i <= #lines do
        if lines[i] == "" then
            i = i + 1
        else
            local event, next_i = parse_subtitle_block(lines, i)
            if event then
                event.start_time = event.start_time + time_offset
                event.end_time = event.end_time + time_offset
                table.insert(self.events, event)
            end
            i = next_i
        end
    end

    table.sort(self.events, function(a, b) return a.start_time < b.start_time end)
end

function Subtitle:parse_api_json(json_content, time_offset)
    local msg = require 'mp.msg'
    local utils = require 'mp.utils'

    time_offset = time_offset or 0

    local json_data = utils.parse_json(json_content)

    if not json_data or not json_data.events then
        msg.error("Invalid JSON response: missing events array")
        return false
    end

    msg.error("Found " .. #json_data.events .. " events in JSON")

    for _, event in ipairs(json_data.events) do
        local subtitle_event = Event:new(
            (event.start / 1000) + time_offset,
            (event["end"] / 1000) + time_offset,
            event.text
        )
        table.insert(self.events, subtitle_event)
    end

    table.sort(self.events, function(a, b) return a.start_time < b.start_time end)

    msg.error("Total events in subtitle object: " .. #self.events)

    return true
end

function Subtitle:save()
    if not self.filepath or self.filepath == "" then
        return false
    end

    local file = io.open(self.filepath, "w")
    if not file then
        return false
    end

    local output_parts = {}

    for i, event in ipairs(self.events) do
        table.insert(output_parts, tostring(i))
        table.insert(output_parts, seconds_to_timestamp(
            event.start_time) .. " --> " .. seconds_to_timestamp(event.end_time))
        table.insert(output_parts, event.text or "")

        if i < #self.events then
            table.insert(output_parts, "")
        end
    end

    file:write(table.concat(output_parts, "\n") .. "\n")
    file:close()
    return true
end

return {
    Event = Event,
    Subtitle = Subtitle
}

