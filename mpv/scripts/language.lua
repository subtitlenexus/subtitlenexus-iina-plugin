local function createLanguageEnum(languages)
    local enum = {}
    local codes = {}
    local names = {}

    for key, data in pairs(languages) do
        local code, name, english_name = data[1], data[2], data[3]

        local lang = setmetatable({
            code = code,
            name = name,
            english_name = english_name
        }, {
            __tostring = function(self) return self.code end,
            __eq = function(self, other)
                return type(other) == "string" and self.code == other
            end
        })

        enum[key] = lang
        codes[code] = lang
        names[name] = lang
    end

    enum.fromCode = function(code) return codes[code] end
    enum.fromName = function(name) return names[name] end

    return setmetatable(enum, {
        __newindex = function() error("Cannot modify Language enum") end
    })
end

local Language = createLanguageEnum({
    ARABIC      = { "ar",  "العربية",        "Arabic" },
    CHINESE     = { "zh",  "中文",            "Chinese" },
    DUTCH       = { "nl",  "Nederlands",     "Dutch" },
    ENGLISH     = { "en",  "English",        "English" },
    FRENCH      = { "fr",  "Français",       "French" },
    GERMAN      = { "de",  "Deutsch",        "German" },
    HINDI       = { "hi",  "हिन्दी",           "Hindi" },
    INDONESIAN  = { "id",  "Bahasa Indonesia", "Indonesian" },
    ITALIAN     = { "it",  "Italiano",       "Italian" },
    JAPANESE    = { "ja",  "日本語",          "Japanese" },
    KOREAN      = { "ko",  "한국어",          "Korean" },
    MALAY       = { "ms",  "Bahasa Melayu",  "Malay" },
    PORTUGUESE  = { "pt",  "Português",      "Portuguese" },
    RUSSIAN     = { "ru",  "Русский",        "Russian" },
    SPANISH     = { "es",  "Español",        "Spanish" },
    THAI        = { "th",  "ไทย",            "Thai" },
    TURKISH     = { "tr",  "Türkçe",         "Turkish" },
    VIETNAMESE  = { "vi",  "Tiếng Việt",     "Vietnamese" }
})

return Language
