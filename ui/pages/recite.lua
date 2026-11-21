--[[--
背诵页：闪卡式自评练习（语文背诵 / 英语单词 / 短语 / 课文 / 乘法表 / 纯数字运算）。

Split out of ui/mainview.lua.  Every function takes the MainView instance as
its first argument (passed implicitly when called as self:method()); bodies
are unchanged from the original MainView: methods.
--]]--

local Blitbuffer = require("ffi/blitbuffer")
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

local CN_NUM = { "零", "一", "二", "三", "四", "五", "六", "七", "八", "九" }

local function cn_number(n)
    if n < 10 then return CN_NUM[n + 1] end
    local t, o = math.floor(n / 10), n % 10
    local s = (t > 1 and CN_NUM[t + 1] or "") .. "十"
    if o > 0 then s = s .. CN_NUM[o + 1] end
    return s
end

local function mul_cards()
    local cards = {}
    for a = 1, 9 do
        for b = a, 9 do
            table.insert(cards, {
                id = string.format("mul_%d_%d", a, b),
                kind = "mul",
                front = string.format("%d × %d = ?", a, b),
                back = tostring(a * b),
                note = string.format("口诀：%s%s%s", CN_NUM[a + 1], CN_NUM[b + 1],
                    a * b < 10 and ("得" .. CN_NUM[a * b + 1]) or cn_number(a * b)),
            })
        end
    end
    return cards
end

local function calc_cards(grade, semester)
    local cards = {}
    local function add(fmt, ans, note)
        table.insert(cards, {
            id = string.format("calc_%d", #cards + 1),
            kind = "calc",
            front = fmt,
            back = tostring(ans),
            note = note or "",
        })
    end
    local r = math.random
    if grade <= 1 then
        if semester == "lower" then
            -- 一下：20 以内进位加 / 退位减（课本重点，结果不越界）
            for _ = 1, 30 do
                if r(1, 2) == 1 then
                    local a = r(2, 9)
                    local b = r(math.max(11 - a, 2), 9) -- 个位相加必进位，和 11~18
                    add(string.format("%d + %d = ?", a, b), a + b)
                else
                    local m = r(11, 18)
                    local s = r(m % 10 + 1, 9)          -- 个位不够减，必退位
                    add(string.format("%d - %d = ?", m, s), m - s)
                end
            end
        else
            -- 一上：10 以内加减（不出现 0 开头/0+0 这类无意义题）
            for _ = 1, 30 do
                if r(1, 2) == 1 then
                    local a = r(1, 9)
                    local b = r(1, math.min(9, 10 - a))
                    add(string.format("%d + %d = ?", a, b), a + b)
                else
                    local hi = r(2, 10)
                    local lo = r(1, hi - 1)
                    add(string.format("%d - %d = ?", hi, lo), hi - lo)
                end
            end
        end
    elseif grade == 2 then
        -- 二年级：100 以内加减 + 表内乘除（下期偏重除法，含有余数除法）
        local add_cnt = (semester == "lower") and 10 or 15
        local mul_cnt = (semester == "lower") and 6 or 10
        for _ = 1, add_cnt do
            local a, b = r(15, 88), r(5, 60)
            if a + b <= 100 and r(1, 2) == 1 then
                add(string.format("%d + %d = ?", a, b), a + b)
            else
                local hi, lo = math.max(a, b), math.min(a, b)
                add(string.format("%d - %d = ?", hi, lo), hi - lo)
            end
        end
        for _ = 1, mul_cnt do
            local a, b = r(2, 9), r(2, 9)
            add(string.format("%d × %d = ?", a, b), a * b)
        end
        for _ = 1, 30 - add_cnt - mul_cnt do
            local a, b = r(2, 9), r(2, 9)
            if semester == "lower" and r(1, 3) == 1 then
                local rem = r(1, a - 1)
                add(string.format("%d ÷ %d = ?", a * b + rem, a),
                    string.format("%d……%d", b, rem))
            else
                add(string.format("%d ÷ %d = ?", a * b, a), b)
            end
        end
    end
    return cards
end

function M.recite_stage(self)
    local settings = self.progress.data.settings
    return tonumber(settings.grade) or 2, settings.semester
end

function M.render_recite_menu(self)
    self.state = "recite_menu"
    self:set_title("背诵·练习")
    self.selected = nil
    self.number_input = ""
    self.feedback = nil
    local cw = Widgets.width()
    local grade, semester = self:recite_stage()
    local counts = Recite.counts(self.plugin_path, grade, semester)
    local dict_count = #Recite.dictation(self.plugin_path, grade, semester)

    -- 收集有内容的栏目（三列网格；顺序即课本常见顺序）
    local items = {}
    local function add(label, hint, cb) table.insert(items, { label = label, hint = hint, cb = cb }) end

    if (counts.poem_full or 0) > 0 then
        add("语文背诵", string.format("诗文 %d 篇 · 看名字背全文", counts.poem_full),
            function() self:start_recite("poem_full") end)
    end
    if dict_count > 0 then
        add("语文默写", string.format("词语 %d 个 · 看拼音纸上写", dict_count),
            function() self:start_recite("dict") end)
    end
    local word_drill_total = #Recite.cards(self.plugin_path, "english", grade, semester, "word")
        + #Words.drill_cards()
    if word_drill_total > 0 then
        add("英语单词默写", string.format("%d 个 · 看中文拼英文", word_drill_total),
            function() self:start_word_drill("all") end)
    end
    if (counts.word_rev or 0) + #Words.drill_cards() > 0 then
        add("英语单词背诵", string.format("%d 张 · 看中文背单词", (counts.word_rev or 0) + #Words.drill_cards()),
            function() self:start_recite("word_rev") end)
    end
    if (counts.phrase or 0) > 0 then
        add("英语短语背诵", string.format("%d 条 · 看短语背中文", counts.phrase),
            function() self:start_recite("phrase") end)
    end
    if (counts.sentence or 0) > 0 then
        add("英语课文背诵", string.format("%d 句 · 看中文背整句", counts.sentence),
            function() self:start_recite("sentence") end)
    end
    if grade >= 2 then
        add("乘法表背诵", "乘法口诀 · 按年级课本", function() self:start_recite("mul") end)
    end
    if grade <= 2 then
        add("纯数字运算", semester == "lower" and "口算卡 · 按课本范围" or "口算卡 · 按课本范围",
            function() self:start_recite("calc") end)
    end

    local content = VerticalGroup:new{
        align = "center",
        Widgets.textbox(string.format("%s%s · 先背一背/练一练，再翻过来对一对",
            self:grade_label(), self:semester_label()), cw, {
            size = 18, color = Blitbuffer.COLOR_DARK_GRAY,
        }),
        Widgets.vspace(Size.span.vertical_default),
    }

    local gap = Size.span.horizontal_default
    local cellw = math.floor((cw - 2 * gap) / 3)
    local row
    for i, it in ipairs(items) do
        local cell = VerticalGroup:new{
            align = "center",
            Widgets.button(it.label, {
                width = cellw,
                height = Screen:scaleBySize(46),
                size = 17,
                callback = it.cb,
            }),
            Widgets.textbox(it.hint, cellw, {
                size = 12, color = Blitbuffer.COLOR_DARK_GRAY, alignment = "center",
            }),
        }
        if (i - 1) % 3 == 0 then
            row = HorizontalGroup:new{ align = "center", cell }
            table.insert(content, row)
            table.insert(content, Widgets.vspace(Size.span.vertical_default))
        else
            table.insert(row, Widgets.hspace(gap))
            table.insert(row, cell)
        end
    end

    if #items == 0 then
        table.insert(content, Widgets.textbox("本学习阶段暂无背诵·练习内容，可在设置里切换年级。", cw, {
            size = 20,
        }))
        table.insert(content, Widgets.vspace(Size.span.vertical_large))
    end

    -- 我的单词库：最后一行，单独一行占满
    table.insert(content, Widgets.vspace(Size.span.vertical_default))
    table.insert(content, Widgets.button(string.format("我的单词库（%d）", Words.count()), {
        width = cw,
        height = Screen:scaleBySize(58),
        size = 21,
        callback = function() self:render_word_book() end,
    }))
    table.insert(content, Widgets.textbox("课外遇到的单词都可以加进来，一起默写", cw, {
        size = 15, color = Blitbuffer.COLOR_DARK_GRAY,
    }))
    table.insert(content, Widgets.vspace(Size.span.vertical_default))
    table.insert(content, Widgets.button("返回首页", {
        width = cw,
        size = 20,
        callback = function() self:render_home() end,
    }))
    self:set_body(content)
end

function M.start_recite(self, kind_id)
    local grade, semester = self:recite_stage()
    local cards, label, empty_msg

    if kind_id == "mul" or kind_id == "calc" then
        -- 数学栏目：按年级课本范围现生成（不读题库文件）
        cards = kind_id == "mul" and mul_cards() or calc_cards(grade, semester)
        label = kind_id == "mul" and "乘法表背诵" or "纯数字运算"
        empty_msg = label .. "暂无内容。"
    elseif kind_id == "dict" then
        -- 语文默写：看拼音，纸上写词，翻面核对
        local words = Recite.dictation(self.plugin_path, grade, semester)
        cards = {}
        for _, w in ipairs(words) do
            if w.w and w.py and w.w ~= "" and w.py ~= "" then
                -- 音节之间拉开间隔，方便孩子逐个音节往纸上写
                local py = w.py:gsub("%s+", "  ")
                table.insert(cards, {
                    id = "dict_" .. w.w,
                    kind = "dict",
                    front = py,
                    back = w.w,
                    note = string.format("共 %d 个字", select(2, w.py:gsub("%S+", ""))),
                })
            end
        end
        label = "语文默写"
        empty_msg = "语文默写暂无词表，可在设置里切换年级。"
    else
        local info = Recite.kind_info(kind_id)
        if not info then return end
        cards = Recite.cards(self.plugin_path, info.subject, grade, semester, kind_id)
        if kind_id == "word_rev" then
            -- 并入我的单词库：看中文意思，背英文单词
            for _, card in ipairs(Words.drill_cards()) do
                table.insert(cards, {
                    id = card.id .. "_rev",
                    kind = "word_rev",
                    front = card.back,
                    back = card.front,
                })
            end
        end
        label = info.label
        empty_msg = "本学习阶段暂无" .. info.label .. "内容，可在设置里切换年级。"
    end

    if #cards == 0 then
        UIManager:show(InfoMessage:new{ text = empty_msg, timeout = 4 })
        return
    end
    for i = #cards, 2, -1 do
        local j = math.random(i)
        cards[i], cards[j] = cards[j], cards[i]
    end
    local round = {}
    for i = 1, math.min(#cards, RECITE_ROUND) do round[i] = cards[i] end
    self.recite = {
        kind = kind_id,
        label = label,
        cards = round,
        index = 1,
        revealed = false,
        remembered = 0,
    }
    self:render_recite_card()
end

function M.render_recite_card(self)
    local r = self.recite
    if not r or not r.cards or #r.cards == 0 then
        self.recite = nil
        self:render_recite_menu()
        return
    end
    self.state = "recite"
    self:set_title("背诵 · " .. r.label)
    local cw = Widgets.width()
    local card = r.cards[r.index]

    -- 正面字号：默写拼音全屏大字；运算题大号；其余默认
    local front_size = 30
    if r.kind == "dict" then
        front_size = 44
    elseif r.kind == "mul" or r.kind == "calc" then
        front_size = 36
    elseif r.kind == "poem_full" then
        front_size = 26
    end

    local card_parts = VerticalGroup:new{
        align = "center",
        Widgets.textbox(card.front, cw - 4 * Size.padding.large, {
            size = front_size,
            alignment = "center",
            line_height = 0.45,
        }),
    }
    if r.revealed then
        table.insert(card_parts, Widgets.vspace(Size.span.vertical_large))
        table.insert(card_parts, Widgets.textbox("—— 答案 ——", cw - 4 * Size.padding.large, {
            size = 16, color = Blitbuffer.COLOR_DARK_GRAY, alignment = "center",
        }))
        table.insert(card_parts, Widgets.vspace(Size.span.vertical_default))
        table.insert(card_parts, Widgets.textbox(card.back, cw - 4 * Size.padding.large, {
            size = r.kind == "dict" and 36 or 27,
            alignment = "center",
            line_height = 0.45,
        }))
        if card.note and card.note ~= "" then
            table.insert(card_parts, Widgets.vspace(Size.span.vertical_default))
            table.insert(card_parts, Widgets.textbox(card.note, cw - 4 * Size.padding.large, {
                size = 15, color = Blitbuffer.COLOR_DARK_GRAY, alignment = "center",
                line_height = 0.3,
            }))
        end
    end

    local content = VerticalGroup:new{
        align = "center",
        Widgets.label(string.format("第 %d/%d 张 · 记住 %d 张",
            r.index, #r.cards, r.remembered), {
            size = 17, color = Blitbuffer.COLOR_DARK_GRAY,
        }),
        Widgets.vspace(Size.span.vertical_large),
        Widgets.card(card_parts, { width = cw, padding = Size.padding.large }),
        Widgets.vspace(Size.span.vertical_large),
    }

    if not r.revealed then
        table.insert(content, Widgets.button("看答案", {
            width = cw,
            height = Screen:scaleBySize(64),
            size = 25,
            callback = function()
                r.revealed = true
                self:render_recite_card()
            end,
        }))
    else
        table.insert(content, HorizontalGroup:new{
            align = "center",
            Widgets.button("记住了 ✓", {
                width = math.floor((cw - Size.span.horizontal_default) / 2),
                height = Screen:scaleBySize(64),
                size = 23,
                callback = function()
                    r.remembered = r.remembered + 1
                    self:recite_next()
                end,
            }),
            Widgets.hspace(Size.span.horizontal_default),
            Widgets.button("再背一遍", {
                width = math.floor((cw - Size.span.horizontal_default) / 2),
                height = Screen:scaleBySize(64),
                size = 23,
                callback = function() self:recite_next() end,
            }),
        })
    end
    table.insert(content, Widgets.vspace(Size.span.vertical_default))
    table.insert(content, Widgets.button("结束本轮", {
        width = cw,
        size = 18,
        callback = function() self:render_recite_done() end,
    }))
    self:set_body(content)
end

function M.recite_next(self)
    local r = self.recite
    if not r then return end
    r.index = r.index + 1
    r.revealed = false
    if r.index > #r.cards then
        self:render_recite_done()
        return
    end
    self:render_recite_card()
end

function M.render_recite_done(self)
    local r = self.recite or { label = "", remembered = 0, cards = {} }
    self.state = "recite_done"
    self:set_title("背诵完成")
    local cw = Widgets.width()
    local content = VerticalGroup:new{
        align = "center",
        Widgets.card(VerticalGroup:new{
            align = "center",
            Widgets.label("背完一轮！", { size = 30, bold = true }),
            Widgets.vspace(Size.span.vertical_default),
            Widgets.label(string.format("本轮 %d 张，记住 %d 张",
                #r.cards, math.min(r.remembered, #r.cards)), { size = 22 }),
            Widgets.vspace(Size.span.vertical_default),
            Widgets.label(r.label or "", { size = 17, color = Blitbuffer.COLOR_DARK_GRAY }),
        }, { width = cw, padding = Size.padding.large }),
        Widgets.vspace(Size.span.vertical_large),
        Widgets.button("再背一轮", {
            width = cw,
            height = Screen:scaleBySize(58),
            size = 22,
            callback = function() self:start_recite(r.kind) end,
        }),
        Widgets.vspace(Size.span.vertical_default),
        Widgets.button("返回背诵菜单", {
            width = cw,
            size = 20,
            callback = function() self:render_recite_menu() end,
        }),
        Widgets.vspace(Size.span.vertical_default),
        Widgets.button("返回首页", {
            width = cw,
            size = 20,
            callback = function() self:render_home() end,
        }),
    }
    self:set_body(content)
end

return M
