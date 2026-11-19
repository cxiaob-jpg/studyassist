--[[--
Recitation ("背诵") card decks.

Decks are pre-built JSON files under data/recite/<subject>/g<grade>_<semester>.json
and contain ready-to-show flashcards: front text, back text and an optional note.
No network access is needed.
--]]--

local JSON = require("json")
local logger = require("logger")
local util = require("util")

local Recite = {}

local cache = {}

local function read_json(path)
    local content = util.readFromFile(path, "rb")
    if not content then return nil end
    local ok, data = pcall(JSON.decode, content)
    if not ok or type(data) ~= "table" then return nil end
    return data
end

-- Deck categories shown in the 背诵·练习 menu. `subject` picks the data folder.
-- 数学栏目（乘法表/纯数字运算）不走题库文件，由 mainview 按年级课本范围现生成。
Recite.KINDS = {
    { id = "poem_full", subject = "chinese", label = "语文背诵", hint = "看诗名，背全文" },
    { id = "word_rev", subject = "english", label = "英语单词背诵", hint = "看中文，背英文" },
    { id = "phrase", subject = "english", label = "英语短语背诵", hint = "看短语，背中文" },
    { id = "sentence", subject = "english", label = "英语课文背诵", hint = "看中文，背整句" },
}

function Recite.deck(plugin_path, subject, grade, semester)
    if not plugin_path or plugin_path == "" then return nil end
    local key = table.concat({ plugin_path, subject, tostring(grade), semester or "upper" }, "|")
    if cache[key] ~= nil then return cache[key] or nil end
    local path = string.format("%s/data/recite/%s/g%d_%s.json",
        plugin_path, subject, grade, semester or "upper")
    local data = read_json(path)
    if not data or type(data.cards) ~= "table" then
        logger.dbg("StudyAssist: no recite deck", path)
        cache[key] = false
        return nil
    end
    cache[key] = data
    return data
end

function Recite.cards(plugin_path, subject, grade, semester, kind)
    local deck = Recite.deck(plugin_path, subject, grade, semester)
    local out = {}
    if not deck then return out end
    -- "word_rev" reuses the word deck flipped: 看中文，背英文.
    local source_kind = kind
    local reverse = false
    if kind == "word_rev" then
        source_kind = "word"
        reverse = true
    end
    for _, card in ipairs(deck.cards) do
        if not source_kind or card.kind == source_kind then
            if reverse then
                if card.back and card.back ~= "" and card.front and card.front ~= "" then
                    table.insert(out, {
                        id = card.id .. "_rev",
                        kind = "word_rev",
                        front = card.back,
                        back = card.front,
                        note = card.note,
                    })
                end
            else
                table.insert(out, card)
            end
        end
    end
    return out
end

-- Count per kind for the current stage: { poem = 12, word = 48, ... }
function Recite.counts(plugin_path, grade, semester)
    local counts = {}
    for _, kind in ipairs(Recite.KINDS) do
        counts[kind.id] = #Recite.cards(plugin_path, kind.subject, grade, semester, kind.id)
    end
    return counts
end

function Recite.kind_info(kind_id)
    for _, kind in ipairs(Recite.KINDS) do
        if kind.id == kind_id then return kind end
    end
    return nil
end

-- 语文默写词表：data/dictation/chinese/g<grade>_<semester>.json
-- 格式 { words = { { w = "词语", py = "cí yǔ" }, ... } }
function Recite.dictation(plugin_path, grade, semester)
    if not plugin_path or plugin_path == "" then return {} end
    local key = "dict|" .. plugin_path .. "|" .. tostring(grade) .. "|" .. (semester or "upper")
    if cache[key] ~= nil then return cache[key] or {} end
    local path = string.format("%s/data/dictation/chinese/g%d_%s.json",
        plugin_path, grade, semester or "upper")
    local data = read_json(path)
    local words = (data and type(data.words) == "table") and data.words or {}
    cache[key] = words
    return words
end

function Recite.clear_cache()
    cache = {}
end

return Recite
