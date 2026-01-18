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
    CHINESE_TW  = { "zh-TW", "中文(繁體)",    "Chinese (Traditional)" },
    CZECH       = { "cs",  "Čeština",        "Czech" },
    DUTCH       = { "nl",  "Nederlands",     "Dutch" },
    ENGLISH     = { "en",  "English",        "English" },
    FRENCH      = { "fr",  "Français",       "French" },
    FRENCH_CA   = { "fr-CA", "Français (Canada)", "French (Canada)" },
    GERMAN      = { "de",  "Deutsch",        "German" },
    HINDI       = { "hi",  "हिन्दी",           "Hindi" },
    INDONESIAN  = { "id",  "Bahasa Indonesia", "Indonesian" },
    ITALIAN     = { "it",  "Italiano",       "Italian" },
    JAPANESE    = { "ja",  "日本語",          "Japanese" },
    KOREAN      = { "ko",  "한국어",          "Korean" },
    MALAY       = { "ms",  "Bahasa Melayu",  "Malay" },
    POLISH      = { "pl",  "Polski",         "Polish" },
    PORTUGUESE  = { "pt",  "Português",      "Portuguese" },
    PORTUGUESE_PT = { "pt-PT", "Português (Portugal)", "Portuguese (Portugal)" },
    RUSSIAN     = { "ru",  "Русский",        "Russian" },
    SPANISH     = { "es",  "Español",        "Spanish" },
    SPANISH_ES  = { "es-ES", "Español (España)", "Spanish (Spain)" },
    TAGALOG     = { "tl",  "Tagalog",        "Tagalog" },
    THAI        = { "th",  "ไทย",            "Thai" },
    TURKISH     = { "tr",  "Türkçe",         "Turkish" },
    VIETNAMESE  = { "vi",  "Tiếng Việt",     "Vietnamese" }
})

return Language
