--[[--
User word book ("我的单词库").

Extra vocabulary the child meets outside the textbook is stored next to the
learning progress (koreader/settings/studyassist_words.lua) so that updating the
plugin never wipes it. Entries are { word = "apple", meaning = "苹果" }.
--]]--

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local logger = require("logger")

local Words = {}

local book

local function default_path()
    return DataStorage:getSettingsDir() .. "/studyassist_words.lua"
end

function Words.open(path)
    if book then return book end
    path = path or default_path()
    local settings = LuaSettings:open(path)
    local entries = settings:readSetting("entries")
    if type(entries) ~= "table" then entries = {} end
    book = { path = path, settings = settings, entries = entries }
    return book
end

local function persist()
    if not book then return nil end
    book.settings:saveSetting("entries", book.entries)
    book.settings:flush()
    return true
end

local function trim(text)
    return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

function Words.list()
    return Words.open().entries
end

function Words.count()
    local n = 0
    for _, entry in ipairs(Words.open().entries) do
        if entry.word and entry.word ~= "" then n = n + 1 end
    end
    return n
end

--[[--
Add (or update) a word. Returns entry, err, existed.
A missing meaning is allowed: the card is then only usable for "看单词背中文"
style self-checking, and is skipped by the spelling drill.
--]]--
function Words.add(word, meaning)
    word = trim(word)
    meaning = trim(meaning)
    if word == "" then return nil, "请输入英文单词" end
    if not word:match("^[%a][%a%s'%-%.]*$") then
        return nil, "英文单词只能包含字母"
    end
    local entries = Words.open().entries
    for _, entry in ipairs(entries) do
        if (entry.word or ""):lower() == word:lower() then
            if meaning ~= "" then entry.meaning = meaning end
            persist()
            return entry, nil, true
        end
    end
    local entry = { word = word, meaning = meaning, added = os.time() }
    table.insert(entries, entry)
    persist()
    logger.info("StudyAssist: word added", word)
    return entry, nil, false
end

function Words.remove(index)
    local entries = Words.open().entries
    local entry = entries[index]
    if not entry then return nil end
    table.remove(entries, index)
    persist()
    return entry
end

function Words.clear()
    if not book then Words.open() end
    book.entries = {}
    persist()
end

--[[--
Spelling drill pool: user words that carry a Chinese meaning. Shapes match the
built-in recite word cards so the drill can mix both.
--]]--
function Words.drill_cards()
    local cards = {}
    for _, entry in ipairs(Words.open().entries) do
        if entry.word and entry.word ~= "" and entry.meaning and entry.meaning ~= "" then
            table.insert(cards, {
                id = "user_" .. entry.word:lower(),
                kind = "word",
                front = entry.word,
                back = entry.meaning,
                user = true,
            })
        end
    end
    return cards
end

return Words
