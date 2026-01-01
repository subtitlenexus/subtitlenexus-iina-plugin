local function createLanguageEnum(languages)
    local enum = {}
    local codes = {}
    local names = {}

    for key, data in pairs(languages) do
        local code, name = data[1], data[2]

        local lang = setmetatable({
            code = code,
            name = name
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
    ARABIC      = { "ar",  "العربية" },
    CHINESE     = { "zh",  "中文" },
    DUTCH       = { "nl",  "Nederlands" },
    ENGLISH     = { "en",  "English" },
    FRENCH      = { "fr",  "Français" },
    GERMAN      = { "de",  "Deutsch" },
    HINDI       = { "hi",  "हिन्दी" },
    INDONESIAN  = { "id",  "Bahasa Indonesia" },
    ITALIAN     = { "it",  "Italiano" },
    JAPANESE    = { "ja",  "Japanese" },
    KOREAN      = { "ko",  "한국어" },
    MALAY       = { "ms",  "Bahasa Melayu" },
    PORTUGUESE  = { "pt",  "Português" },
    RUSSIAN     = { "ru",  "Русский" },
    SPANISH     = { "es",  "Español" },
    THAI        = { "th",  "ไทย" },
    TURKISH     = { "tr",  "Türkçe" },
    VIETNAMESE  = { "vi",  "Tiếng Việt" }
})

return Language
