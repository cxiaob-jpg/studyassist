--[[--
答题链路：组题、题目卡片、答题区（选项 / 键盘）、判题反馈、下一题与结算。

Split out of ui/mainview.lua.  Every function takes the MainView instance as
its first argument (passed implicitly when called as self:method()); bodies
are unchanged from the original MainView: methods.
--]]--

local Device = require("device")
local Blitbuffer = require("ffi/blitbuffer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InfoMessage = require("ui/widget/infomessage")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")

local Badges = require("core.badges")
local Session = require("core.session")
local Widgets = require("ui/widgets")

local Screen = Device.screen

local Common = require("ui/pages/common")
local KP_STATUS_LABEL = Common.KP_STATUS_LABEL
local answer_text = Common.answer_text

local M = {}

local SKILL_LABEL = {
    pinyin = "拼音", measure_word = "量词", synonym = "近义词", antonym = "反义词",
    sentence = "句子", sentence_choice = "句子", word_choice = "词语", accumulation = "积累", reading = "阅读",
    choice = "选择", number = "填数",
    challenge = "拓展",
    add_sub = "口算", table_mul = "乘法口诀", division = "除法", mixed_ops = "混合运算",
    remainder = "有余数除法", length = "长度单位", angles = "角", observe_object = "观察物体",
    time = "认识时间", combinations = "搭配", data = "数据整理", symmetry = "图形运动",
    numbers_10k = "万以内数", mass = "克和千克", reasoning = "推理",
    count_10 = "数一数", position = "位置", add_sub_5 = "5以内加减", shape = "认识图形",
    add_sub_10 = "10以内加减", numbers_20 = "20以内数", add_carry_20 = "20以内进位加",
    sub_borrow_20 = "20以内退位减", classify = "分类", numbers_100 = "100以内数",
    money = "人民币", add_sub_100_simple = "100以内加减", pattern = "找规律",
    combination = "搭配", measure = "测量", add_sub_10k = "万以内加减", times = "倍的认识",
    multi_digit_mul = "多位数乘法", rectangle_square = "长方形和正方形",
    fraction_intro = "分数初步", direction = "方向", div_multi_digit = "除法",
    statistics = "统计", two_digit_mul = "两位数乘法", area = "面积", calendar = "年月日",
    decimal_intro = "小数初步", large_numbers = "大数", area_units = "面积单位",
    angle_measure = "角的度量", three_digit_mul = "三位数乘法",
    parallelogram_trapezoid = "平行四边形和梯形", div_two_digit = "两位数除法",
    bar_chart = "条形统计图", optimization = "优化", operation_laws = "运算定律",
    decimal_meaning = "小数意义", triangle = "三角形", decimal_add_sub = "小数加减",
    average_chart = "平均数", chicken_rabbit = "鸡兔同笼", decimal_mul = "小数乘法",
    probability = "可能性", equation = "方程", polygon_area = "多边形面积",
    planting = "植树问题", factor_multiple = "因数倍数", cuboid_cube = "长方体正方体",
    fraction_meaning = "分数意义", rotation = "图形旋转", fraction_add_sub = "分数加减",
    line_chart = "折线统计图", find_defective = "找次品", fraction_mul = "分数乘法",
    fraction_div = "分数除法", ratio = "比", circle = "圆", percent = "百分数",
    pie_chart = "扇形统计图", number_shape = "数与形", negative = "负数",
    cylinder_cone = "圆柱圆锥", proportion = "比例", math_thinking = "数学思考",
    word_problem = "应用题",
    word_add = "应用题", word_sub = "应用题", word_mul = "应用题", word_div = "应用题",
    word_compare = "应用题", word_two_step = "应用题", word_length = "应用题",
    word_mass = "应用题", word_time = "应用题", word_remainder = "应用题",
}

function M.start_session(self, opts)
    local settings = self.progress.data.settings
    local session, err = Session.new{
        mode = opts.mode,
        subject = opts.subject,
        unit = opts.unit,
        wrong_items = opts.wrong_items,
        ai_questions = opts.ai_questions,
        ai_group_id = opts.ai_group_id,
        kp_questions = opts.kp_questions,
        kp_topic = opts.kp_topic,
        semester = settings.semester,
        plugin_path = self.plugin_path,
        progress = self.progress,
    }
    if not session then
        UIManager:show(InfoMessage:new{
            text = "暂时不能开始练习：" .. tostring(err),
            timeout = 4,
        })
        return
    end
    self.session = session
    self.last_session_opts = opts
    self.last_kp_topic = opts.kp_topic
    self.last_kp_subject = opts.subject
    self.diagnose = nil
    self.state = "quiz"
    self.selected = nil
    self.number_input = ""
    self.feedback = nil
    self:render_quiz()
end
function M.quiz_title(self)
    if self.session.mode == "mixed" or self.session.mode == "daily" then return "今日挑战" end
    if self.last_session_opts and self.last_session_opts.challenge then
        return "今日挑战 · " .. self:subject_label(self.session.subject)
    end
    if self.session.mode == "wrong" then return "错题复习" end
    if self.session.mode == "ai" then return "AI 强化" end
    if self.session.mode == "challenge" then return "数学拓展" end
    if self.session.mode == "kp" then return "知识点练习" end
    return self:subject_label(self.session.subject) .. "练习"
end
function M.render_header(self)
    local cw = Widgets.width()
    local third = math.floor(cw / 3)
    local total_points = self.progress.data.total.points
    return HorizontalGroup:new{
        align = "center",
        Widgets.center(Widgets.label(string.format("第 %d/%d 题", self.session:position(), self.session:total()), {
            size = 18, bold = true,
        }), third),
        Widgets.center(Widgets.label(string.format("连对 %d", self.session.combo), {
            size = 18, color = Blitbuffer.COLOR_DARK_GRAY,
        }), third),
        Widgets.center(Widgets.label(string.format("★ %d", total_points), {
            size = 18, bold = true,
        }), third),
    }
end
function M.render_question_card(self, question)
    local cw = Widgets.width()
    local unit_name = self:unit_name(question)
    local skill
    if question.challenge then
        skill = question.competency or "动脑"
    else
        skill = SKILL_LABEL[question.skill] or question.skill or question.type or ""
    end
    local tag = string.format("%s · %s", unit_name, skill)
    -- In a mixed session every question may come from a different subject, so
    -- name the subject on the card as well.
    if self.session and (self.session.mode == "mixed" or self.session.mode == "daily") then
        tag = string.format("%s · %s", self:subject_label(question.subject), tag)
    end
    if question.ai_generated then tag = "AI 变种 · " .. tag end
    if question.remedial_hint then tag = question.remedial_hint .. " · " .. tag end
    local inner_width = cw - 2 * Size.padding.large
    local parts = VerticalGroup:new{
        align = "left",
        Widgets.label(tag, { size = 16, color = Blitbuffer.COLOR_DARK_GRAY, max_width = cw - 2 * Size.padding.default }),
        Widgets.vspace(Size.span.vertical_default),
    }
    if question.passage and question.passage ~= "" then
        table.insert(parts, Widgets.card(VerticalGroup:new{
            align = "left",
            Widgets.label("读一读", { size = 16, bold = true }),
            Widgets.vspace(Size.span.vertical_default),
            Widgets.textbox(question.passage, inner_width - 2 * Size.padding.default, { size = 19 }),
        }, { width = cw - 2 * Size.padding.default }))
        table.insert(parts, Widgets.vspace(Size.span.vertical_default))
    end
    -- Figure questions ship the whole question (stem + diagram + options) as
    -- one PNG; show it in place of the text stem. Fall back to text if missing.
    local figure = nil
    if question.figure_image then
        local path = self.plugin_path and (self.plugin_path .. "/" .. question.figure_image) or nil
        figure = Widgets.figure(path, inner_width)
    end
    if figure then
        table.insert(parts, figure)
    else
        table.insert(parts, Widgets.textbox(question.stem, inner_width, {
            size = 27,
            line_height = 0.35,
        }))
    end
    return Widgets.card(parts, { width = cw, padding = Size.padding.large })
end
function M.rerender_input(self)
    if self.diagnose and self.state == "diagnose_quiz" then
        self:render_diagnose_quiz()
    else
        self:render_quiz()
    end
end
function M.render_choice_area(self, question)
    local cw = Widgets.width()
    local area = VerticalGroup:new{ align = "center" }
    local prefixes = { "A. ", "B. ", "C. ", "D. " }
    for i, option in ipairs(question.options or {}) do
        -- Figure questions already show the full option text in the image;
        -- buttons only need the letter so the option isn't printed twice.
        local label = question.figure_image and prefixes[i]:gsub("%s$", "")
            or (prefixes[i] .. option)
        table.insert(area, Widgets.choice_button(label, cw, self.selected == i, function()
            self.selected = i
            self:rerender_input()
        end))
        if i < #question.options then
            table.insert(area, Widgets.vspace(Size.span.vertical_default))
        end
    end
    table.insert(area, Widgets.vspace(Size.span.vertical_default))
    table.insert(area, Widgets.button("确认答案", {
        width = cw,
        height = Screen:scaleBySize(58),
        size = 22,
        enabled = self.selected ~= nil,
        callback = function()
            if self.selected then self:submit_answer(self.selected) end
        end,
    }))
    return area
end
function M.render_keypad(self, question)
    local cw = Widgets.width()
    local gap = Size.span.horizontal_default
    local key_width = math.floor((cw - 2 * gap) / 3)
    local format = question.answer_format
    local extended = format == "decimal" or format == "fraction"
    -- Knowledge questions may need up to 8 chars (e.g. 1000000 or 11/12);
    -- legacy generated questions keep the original 5-char integer limit.
    local max_len = format and 8 or 5
    local input_text = self.number_input ~= "" and self.number_input or "?"
    local display_card = Widgets.card(VerticalGroup:new{
        align = "center",
        Widgets.label("请输入答案", { size = 16, color = Blitbuffer.COLOR_DARK_GRAY }),
        Widgets.vspace(Size.span.vertical_default),
        Widgets.label(input_text, { size = 34, bold = true }),
        question.unit_hint and Widgets.label(question.unit_hint, { size = 18 }) or Widgets.vspace(0),
    }, { width = cw, padding = Size.padding.default })

    local function digit(d)
        return function()
            if #self.number_input < max_len then
                self.number_input = self.number_input .. d
                self:rerender_input()
            end
        end
    end
    local function row(keys)
        local group = HorizontalGroup:new{ align = "center" }
        for i, key in ipairs(keys) do
            if i > 1 then table.insert(group, Widgets.hspace(gap)) end
            table.insert(group, Widgets.button(key.label, {
                width = key_width,
                height = Screen:scaleBySize(58),
                size = 24,
                enabled = key.enabled ~= false,
                callback = key.callback,
            }))
        end
        return group
    end
    local function backspace()
        if #self.number_input > 0 then
            self.number_input = self.number_input:sub(1, -2)
            self:rerender_input()
        end
    end
    local function confirm()
        if self.number_input == "" then return end
        if extended then
            local input = self.number_input
            local valid
            if format == "fraction" then
                local num, den = input:match("^(%d+)/(%d+)$")
                if num then
                    valid = tonumber(den) ~= 0
                else
                    valid = tonumber(input) ~= nil
                end
            else
                valid = tonumber(input) ~= nil
            end
            if not valid then
                UIManager:show(InfoMessage:new{
                    text = format == "fraction" and "请输入分数（如 1/2）或小数" or "请输入小数（如 0.5）",
                    timeout = 3,
                })
                return
            end
            self:submit_answer(input)
        else
            self:submit_answer(tonumber(self.number_input))
        end
    end

    local area = VerticalGroup:new{
        align = "center",
        display_card,
        Widgets.vspace(Size.span.vertical_default),
        row({ { label = "1", callback = digit("1") }, { label = "2", callback = digit("2") }, { label = "3", callback = digit("3") } }),
        Widgets.vspace(Size.span.vertical_default),
        row({ { label = "4", callback = digit("4") }, { label = "5", callback = digit("5") }, { label = "6", callback = digit("6") } }),
        Widgets.vspace(Size.span.vertical_default),
        row({ { label = "7", callback = digit("7") }, { label = "8", callback = digit("8") }, { label = "9", callback = digit("9") } }),
        Widgets.vspace(Size.span.vertical_default),
    }
    if extended then
        local has_dot = self.number_input:find(".", 1, true) ~= nil
        local has_slash = self.number_input:find("/", 1, true) ~= nil
        table.insert(area, row({
            { label = ".", enabled = not has_dot and not has_slash, callback = digit(".") },
            { label = "/", enabled = format == "fraction" and not has_slash and not has_dot and self.number_input ~= "", callback = digit("/") },
            { label = "←", callback = backspace },
        }))
        table.insert(area, Widgets.vspace(Size.span.vertical_default))
        table.insert(area, row({
            { label = "0", callback = digit("0") },
            { label = "清空", callback = function()
                self.number_input = ""
                self:rerender_input()
            end },
            { label = "确认", enabled = self.number_input ~= "", callback = confirm },
        }))
    else
        table.insert(area, row({
            { label = "←", callback = backspace },
            { label = "0", callback = digit("0") },
            { label = "确认", enabled = self.number_input ~= "", callback = confirm },
        }))
    end
    return area
end
function M.render_quiz(self)
    self.state = "quiz"
    self:set_title(self:quiz_title())
    local question = self.session:current()
    local cw = Widgets.width()
    local content = VerticalGroup:new{
        align = "center",
        self:render_header(),
        Widgets.vspace(Size.span.vertical_default),
        Widgets.progress((self.session:position() - 1) / self.session:total(), cw),
        Widgets.vspace(Size.span.vertical_default),
        self:render_question_card(question),
        Widgets.vspace(Size.span.vertical_default),
    }
    if question.answer_mode == "number" then
        table.insert(content, self:render_keypad(question))
    else
        table.insert(content, self:render_choice_area(question))
    end
    self:set_body(content)
end
function M.submit_answer(self, value)
    if self.diagnose and self.state == "diagnose_quiz" then
        self:diagnose_submit(value)
        return
    end
    if not self.session then return end
    self.feedback = self.session:submit(value)
    if self.feedback then
        self:render_feedback()
    end
end
function M.render_feedback(self)
    self.state = "feedback"
    self:set_title(self:quiz_title())
    local q = self.feedback.question
    local cw = Widgets.width()
    local content = VerticalGroup:new{
        align = "center",
        self:render_header(),
        Widgets.vspace(Size.span.vertical_default),
        self:render_question_card(q),
        Widgets.vspace(Size.span.vertical_default),
    }

    local feedback_parts = VerticalGroup:new{ align = "left" }
    if self.feedback.correct then
        local base_points = self.feedback.awarded - (self.feedback.combo_bonus or 0)
        table.insert(feedback_parts, Widgets.label(string.format("✓ 答对了！ +%d ★", base_points), {
            size = 24, bold = true,
        }))
        if self.feedback.combo_bonus > 0 then
            table.insert(feedback_parts, Widgets.vspace(Size.span.vertical_default))
            table.insert(feedback_parts, Widgets.label(string.format("连对 %d 题，额外 +%d ★", self.feedback.combo, self.feedback.combo_bonus), {
                size = 18, bold = true,
            }))
        end
    elseif self.feedback.can_retry then
        table.insert(feedback_parts, Widgets.label("再想想，你可以的！", { size = 24, bold = true }))
        table.insert(feedback_parts, Widgets.vspace(Size.span.vertical_default))
        table.insert(feedback_parts, Widgets.label("再试一次答对，可以得到 5 颗星星。", { size = 17, color = Blitbuffer.COLOR_DARK_GRAY }))
    else
        table.insert(feedback_parts, Widgets.label("正确答案：" .. answer_text(q), { size = 24, bold = true }))
    end
    table.insert(feedback_parts, Widgets.vspace(Size.span.vertical_default))
    if self.feedback.correct or not self.feedback.can_retry then
        table.insert(feedback_parts, Widgets.textbox(q.explain or "", cw - 4 * Size.padding.default, { size = 18 }))
    else
        table.insert(feedback_parts, Widgets.label("别着急，先自己算一算，再试一次。", {
            size = 17, color = Blitbuffer.COLOR_DARK_GRAY,
        }))
    end
    table.insert(content, Widgets.card(feedback_parts, { width = cw, padding = Size.padding.large }))
    table.insert(content, Widgets.vspace(Size.span.vertical_large))

    if self.feedback.can_retry then
        local half = math.floor((cw - Size.span.horizontal_default) / 2)
        table.insert(content, HorizontalGroup:new{
            align = "center",
            Widgets.button("再试一次", {
                width = half,
                height = Screen:scaleBySize(56),
                size = 21,
                callback = function()
                    self.session:retry()
                    self.feedback = nil
                    self.selected = nil
                    self.number_input = ""
                    self:render_quiz()
                end,
            }),
            Widgets.hspace(Size.span.horizontal_default),
            Widgets.button("看答案", {
                width = half,
                height = Screen:scaleBySize(56),
                size = 21,
                callback = function()
                    self.session:give_up()
                    self.feedback.final = true
                    self.feedback.can_retry = false
                    self:render_feedback()
                end,
            }),
        })
    else
        table.insert(content, Widgets.button("继续", {
            width = cw,
            height = Screen:scaleBySize(58),
            size = 22,
            callback = function() self:next_question() end,
        }))
    end
    self:set_body(content)
end
function M.next_question(self)
    if self.session:advance() then
        self.feedback = nil
        self.selected = nil
        self.number_input = ""
        self:render_quiz()
    else
        self:finish_session()
    end
end
function M.finish_session(self)
    self.summary = self.session:finish()
    self.new_badges = Badges.evaluate(self.progress)
    self:render_summary()
end
return M
