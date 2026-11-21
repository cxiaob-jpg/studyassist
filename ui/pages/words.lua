--[[--
单词页：我的单词库、默写练习与完成页。

Split out of ui/mainview.lua.  Every function takes the MainView instance as
its first argument (passed implicitly when called as self:method()); bodies
are unchanged from the original MainView: methods.
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InfoMessage = require("ui/widget/infomessage")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")

local Recite = require("core/recite")
local Widgets = require("ui/widgets")
local Words = require("core/words")

local Screen = Device.screen
local _ = require("gettext")

local Common = require("ui/pages/common")
local RECITE_ROUND = Common.RECITE_ROUND

local M = {}

local function word_drill_cards(plugin_path, grade, semester, pool)
    local cards = {}
    if pool ~= "mine" then
        for _, card in ipairs(Recite.cards(plugin_path, "english", grade, semester, "word")) do
            if card.back and card.back ~= "" then
                table.insert(cards, { id = card.id, word = card.front, meaning = card.back })
            end
        end
    end
    if pool ~= "builtin" then
        for _, card in ipairs(Words.drill_cards()) do
            table.insert(cards, { id = card.id, word = card.front, meaning = card.back, user = true })
        end
    end
    return cards
end

local function normalize_word(text)
    text = tostring(text or ""):lower()
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    text = text:gsub("[%p]$", "")
    return text
end

function M.render_word_book(self)
    self.state = "word_book"
    self:set_title("我的单词库")
    local cw = Widgets.width()
    local entries = Words.list()
    local drill_count = #Words.drill_cards()
    local content = VerticalGroup:new{
        align = "center",
        Widgets.textbox(string.format("共 %d 个单词，其中 %d 个可以默写（需要中文意思）",
            #entries, drill_count), cw, {
            size = 17, color = Blitbuffer.COLOR_DARK_GRAY,
        }),
        Widgets.vspace(Size.span.vertical_default),
        Widgets.button("添加单词", {
            width = cw,
            height = Screen:scaleBySize(58),
            size = 22,
            callback = function() self:add_word_dialog() end,
        }),
        Widgets.vspace(Size.span.vertical_default),
        Widgets.button(string.format("默写我的单词（%d）", drill_count), {
            width = cw,
            height = Screen:scaleBySize(58),
            size = 22,
            enabled = drill_count > 0,
            callback = function() self:start_word_drill("mine") end,
        }),
        Widgets.vspace(Size.span.vertical_default),
    }

    if #entries == 0 then
        table.insert(content, Widgets.textbox("还没有自己的单词。点「添加单词」，把课外遇到的词记下来。", cw, {
            size = 18,
        }))
        table.insert(content, Widgets.vspace(Size.span.vertical_large))
    else
        table.insert(content, Widgets.textbox("点单词可以删除", cw, {
            size = 15, color = Blitbuffer.COLOR_DARK_GRAY,
        }))
        table.insert(content, Widgets.vspace(Size.span.vertical_default))
        local shown = math.min(#entries, 12)
        for i = #entries, math.max(1, #entries - shown + 1), -1 do
            local entry = entries[i]
            table.insert(content, Widgets.button(string.format("%s   %s", entry.word,
                entry.meaning ~= "" and entry.meaning or "（未填中文）"), {
                width = cw,
                height = Screen:scaleBySize(48),
                size = 18,
                align = "left",
                callback = function() self:confirm_remove_word(i, entry) end,
            }))
            table.insert(content, Widgets.vspace(Size.span.vertical_default))
        end
    end

    table.insert(content, Widgets.button("返回背诵菜单", {
        width = cw,
        size = 20,
        callback = function() self:render_recite_menu() end,
    }))
    self:set_body(content)
end

function M.confirm_remove_word(self, index, entry)
    local text = string.format("从单词库里删除「%s」吗？", entry.word)
    UIManager:show(ConfirmBox:new{
        text = text,
        ok_text = "删除",
        cancel_text = "留下",
        ok_callback = function()
            Words.remove(index)
            self:render_word_book()
        end,
    })
end

function M.add_word_dialog(self)
    self:open_ai_text_input("输入英文单词", "", false, function(text)
        local word = tostring(text or "")
        if normalize_word(word) == "" then
            UIManager:show(InfoMessage:new{ text = "没有输入单词", timeout = 3 })
            return
        end
        self:open_ai_text_input("输入中文意思（可留空）", "", false, function(meaning)
            local entry, err, existed = Words.add(word, meaning)
            if not entry then
                UIManager:show(InfoMessage:new{ text = tostring(err), timeout = 4 })
                return
            end
            local tail = entry.meaning ~= "" and ("  " .. entry.meaning) or "（未填中文，暂不能默写）"
            UIManager:show(InfoMessage:new{
                text = (existed and "已更新：" or "已添加：") .. entry.word .. tail,
                timeout = 3,
            })
            self:render_word_book()
        end)
    end)
end

function M.start_word_drill(self, pool)
    local grade, semester = self:recite_stage()
    local cards = word_drill_cards(self.plugin_path, grade, semester, pool or "all")
    if #cards == 0 then
        UIManager:show(InfoMessage:new{
            text = "还没有可默写的单词：先在「我的单词库」里添加，或在设置里切换年级。",
            timeout = 4,
        })
        return
    end
    for i = #cards, 2, -1 do
        local j = math.random(i)
        cards[i], cards[j] = cards[j], cards[i]
    end
    local round = {}
    for i = 1, math.min(#cards, RECITE_ROUND) do round[i] = cards[i] end
    self.word_drill = {
        pool = pool or "all",
        cards = round,
        index = 1,
        correct = 0,
        answered = false,
        given = nil,
        ok = false,
        hint = false,
    }
    self:render_word_drill()
end

function M.render_word_drill(self)
    local drill = self.word_drill
    if not drill or not drill.cards or #drill.cards == 0 then
        self.word_drill = nil
        self:render_recite_menu()
        return
    end
    self.state = "word_drill"
    self:set_title("英语默写")
    local cw = Widgets.width()
    local card = drill.cards[drill.index]

    local hint_text
    if drill.hint then
        local word = card.word
        local letters = {}
        for i = 1, #word do
            letters[i] = i == 1 and word:sub(1, 1) or "＿"
        end
        hint_text = "提示：" .. table.concat(letters, " ")
    else
        hint_text = ""
    end

    local parts = VerticalGroup:new{
        align = "center",
        Widgets.textbox(card.meaning, cw - 4 * Size.padding.large, {
            size = 30, alignment = "center", line_height = 0.45,
        }),
    }
    if card.user then
        table.insert(parts, Widgets.vspace(Size.span.vertical_default))
        table.insert(parts, Widgets.textbox("（我的单词）", cw - 4 * Size.padding.large, {
            size = 15, color = Blitbuffer.COLOR_DARK_GRAY, alignment = "center",
        }))
    end
    if hint_text ~= "" then
        table.insert(parts, Widgets.vspace(Size.span.vertical_default))
        table.insert(parts, Widgets.textbox(hint_text, cw - 4 * Size.padding.large, {
            size = 22, alignment = "center", color = Blitbuffer.COLOR_DARK_GRAY,
        }))
    end
    if drill.answered then
        table.insert(parts, Widgets.vspace(Size.span.vertical_large))
        table.insert(parts, Widgets.textbox(drill.ok and "✓ 拼写正确" or ("✗ 正确答案：" .. card.word),
            cw - 4 * Size.padding.large, {
                size = 26, alignment = "center",
            }))
        if drill.given and drill.given ~= "" then
            table.insert(parts, Widgets.vspace(Size.span.vertical_default))
            table.insert(parts, Widgets.textbox("你的答案：" .. drill.given, cw - 4 * Size.padding.large, {
                size = 18, alignment = "center", color = Blitbuffer.COLOR_DARK_GRAY,
            }))
        end
    end

    local content = VerticalGroup:new{
        align = "center",
        Widgets.label(string.format("第 %d/%d 个 · 答对 %d 个",
            drill.index, #drill.cards, drill.correct), {
            size = 17, color = Blitbuffer.COLOR_DARK_GRAY,
        }),
        Widgets.vspace(Size.span.vertical_large),
        Widgets.card(parts, { width = cw, padding = Size.padding.large }),
        Widgets.vspace(Size.span.vertical_default),
        Widgets.textbox("看中文，用键盘拼出英文", cw, {
            size = 15, color = Blitbuffer.COLOR_DARK_GRAY,
        }),
        Widgets.vspace(Size.span.vertical_large),
    }

    if drill.answered then
        table.insert(content, Widgets.button(drill.index >= #drill.cards and "看看结果" or "下一个", {
            width = cw,
            height = Screen:scaleBySize(64),
            size = 24,
            callback = function() self:word_drill_next() end,
        }))
    else
        table.insert(content, Widgets.button("输入答案", {
            width = cw,
            height = Screen:scaleBySize(64),
            size = 25,
            callback = function() self:word_drill_input(card) end,
        }))
        table.insert(content, Widgets.vspace(Size.span.vertical_default))
        table.insert(content, HorizontalGroup:new{
            align = "center",
            Widgets.button("看提示", {
                width = math.floor((cw - Size.span.horizontal_default) / 2),
                size = 19,
                callback = function()
                    drill.hint = true
                    self:render_word_drill()
                end,
            }),
            Widgets.hspace(Size.span.horizontal_default),
            Widgets.button("不会，看答案", {
                width = math.floor((cw - Size.span.horizontal_default) / 2),
                size = 19,
                callback = function() self:word_drill_answer(card, nil) end,
            }),
        })
    end
    table.insert(content, Widgets.vspace(Size.span.vertical_default))
    table.insert(content, Widgets.button("结束默写", {
        width = cw,
        size = 18,
        callback = function() self:render_word_done() end,
    }))
    self:set_body(content)
end

function M.word_drill_input(self, card)
    self:open_ai_text_input("拼出英文：" .. card.meaning, "", false, function(text)
        self:word_drill_answer(card, tostring(text or ""))
    end)
end

function M.word_drill_answer(self, card, given)
    local drill = self.word_drill
    if not drill then return end
    drill.answered = true
    drill.given = given
    drill.ok = given ~= nil and normalize_word(given) == normalize_word(card.word)
    if drill.ok then drill.correct = drill.correct + 1 end
    self:render_word_drill()
end

function M.word_drill_next(self)
    local drill = self.word_drill
    if not drill then return end
    drill.index = drill.index + 1
    drill.answered = false
    drill.given = nil
    drill.ok = false
    drill.hint = false
    if drill.index > #drill.cards then
        self:render_word_done()
        return
    end
    self:render_word_drill()
end

function M.render_word_done(self)
    local drill = self.word_drill or { cards = {}, correct = 0, pool = "all" }
    self.state = "word_done"
    self:set_title("默写完成")
    local cw = Widgets.width()
    local content = VerticalGroup:new{
        align = "center",
        Widgets.card(VerticalGroup:new{
            align = "center",
            Widgets.label("默写完成！", { size = 30, bold = true }),
            Widgets.vspace(Size.span.vertical_default),
            Widgets.label(string.format("拼对 %d/%d 个", drill.correct, #drill.cards), { size = 24 }),
        }, { width = cw, padding = Size.padding.large }),
        Widgets.vspace(Size.span.vertical_large),
        Widgets.button("再默写一组", {
            width = cw,
            height = Screen:scaleBySize(58),
            size = 22,
            callback = function() self:start_word_drill(drill.pool) end,
        }),
        Widgets.vspace(Size.span.vertical_default),
        Widgets.button("我的单词库", {
            width = cw,
            size = 20,
            callback = function() self:render_word_book() end,
        }),
        Widgets.vspace(Size.span.vertical_default),
        Widgets.button("返回背诵菜单", {
            width = cw,
            size = 20,
            callback = function() self:render_recite_menu() end,
        }),
    }
    self:set_body(content)
end

return M
