--[[--
Full-screen StudyAssist UI.

The view keeps one widget on screen and swaps its body between home, unit
selection, quiz, feedback, summary, wrong book, badges, daily report, card
book, card detail and settings. This is
much lighter on e-ink than opening a new window for every question.
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local Size = require("ui/size")
local TitleBar = require("ui/widget/titlebar")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local util = require("util")
local VerticalGroup = require("ui/widget/verticalgroup")

local AIBank = require("core.ai_bank")
local AIClient = require("core.ai_client")
local AIConfig = require("core.ai_config")
local AIVariant = require("core.ai_variant")
local Badges = require("core.badges")
local Bank = require("core.bank")
local Catalog = require("core.catalog")
local Diagnose = require("core.diagnose")
local Knowledge = require("core.knowledge")
local MathGen = require("core.mathgen")
local Progress = require("core.progress")
local Recite = require("core.recite")
local Report = require("core.report")
local Session = require("core.session")
local Shop = require("core.shop")
local Update = require("core.update")
local UpdateDialog = require("ui/update_dialog")
local PinPadDialog = require("ui/pinpad")
local Widgets = require("ui/widgets")
local Words = require("core.words")

local Screen = Device.screen
local _ = require("gettext")

local MainView = InputContainer:extend{
    covers_fullscreen = true,
}

local SUBJECT_LABEL = { chinese = "语文", math = "数学", english = "英语",
                        physics = "物理", chemistry = "化学", biology = "生物",
                        history = "历史", geography = "地理" }
-- Bank-backed subjects shown on the home screen (math renders separately).
local SUBJECT_ORDER = { "chinese", "math", "english", "physics", "chemistry",
                        "biology", "history", "geography" }
-- Default edition fallbacks; must match bank.lua / session.lua.
local DEFAULT_EDITIONS = {
    chinese = "tongbian", math = "renjiao", english = "pep",
    physics = "renjiao", chemistry = "renjiao", biology = "renjiao",
    history = "tongbian", geography = "renjiao",
}
local GRADE_LABEL = { "一年级", "二年级", "三年级", "四年级", "五年级", "六年级",
                      "七年级", "八年级", "九年级", nil, nil, nil,
                      [10] = "高一", [11] = "高二", [12] = "高三" }
local function settings_edition(settings, subject)
    return settings[subject .. "_edition"] or DEFAULT_EDITIONS[subject]
end

-- 每行放几个：尽量均衡（7 个 → 3/2/2，5 个 → 3/2，4 个 → 2/2）
local function balanced_row_counts(n, max_cols)
    if n <= 0 then return {} end
    local cols = math.min(max_cols or 3, n)
    if n == 4 then cols = 2 end
    local rows = math.ceil(n / cols)
    local base, rem = math.floor(n / rows), n % rows
    local out = {}
    for r = 1, rows do
        out[r] = base + (r <= rem and 1 or 0)
    end
    return out
end

-- 学科按钮网格：按均衡行数铺开，每行按钮均分整行宽度
local function subject_grid(list, cw, make_button)
    local rows, idx = {}, 1
    for _, k in ipairs(balanced_row_counts(#list, 3)) do
        local w = math.floor((cw - (k - 1) * Size.span.horizontal_default) / k)
        local row = HorizontalGroup:new{ align = "center" }
        for i = idx, idx + k - 1 do
            if i > idx then table.insert(row, Widgets.hspace(Size.span.horizontal_default)) end
            table.insert(row, make_button(list[i], w))
        end
        table.insert(rows, row)
        idx = idx + k
    end
    return rows
end

-- Grades that actually carry a textbook volume for this subject, across every
-- bundled edition. Used to tell "this subject does not start until grade N"
-- apart from a genuine load failure.
local function subject_grades(plugin_path, subject)
    local out, seen = {}, {}
    local data = Catalog.load(plugin_path)
    local subject_data = data and data.subjects and data.subjects[subject]
    if not subject_data then return out end
    for _, edition in pairs(subject_data.editions or {}) do
        for grade_str in pairs(edition.grades or {}) do
            local grade = tonumber(grade_str)
            if grade and not seen[grade] then
                seen[grade] = true
                table.insert(out, grade)
            end
        end
    end
    table.sort(out)
    return out
end

-- True when at least one edition ships units for (grade, semester).
local function has_volume(plugin_path, subject, grade, semester)
    local data = Catalog.load(plugin_path)
    local subject_data = data and data.subjects and data.subjects[subject]
    if not subject_data then return false end
    for _, edition in pairs(subject_data.editions or {}) do
        local grade_data = edition.grades and edition.grades[tostring(grade)]
        local semester_data = grade_data and grade_data[semester]
        if type(semester_data) == "table" and type(semester_data.units) == "table"
            and #semester_data.units > 0 then
            return true
        end
    end
    return false
end

-- Friendly text for "no content at this stage", e.g.
-- "本学习阶段暂无物理学科（物理覆盖八年级到高三，可在设置里切换年级）".
local function stage_missing_text(plugin_path, subject, grade, semester)
    local label = SUBJECT_LABEL[subject] or "该科目"
    local grades = subject_grades(plugin_path, subject)
    local text = "本学习阶段暂无" .. label .. "学科"
    if #grades == 0 then
        return text .. "（题库中还没有该科目的内容）"
    end
    -- Grade is covered but this half-year volume is not (e.g. 九年级下册).
    local other = semester == "lower" and "upper" or "lower"
    if has_volume(plugin_path, subject, grade, other) then
        return string.format("%s（%s%s暂未收录，可在设置里切换到%s）",
            text, GRADE_LABEL[grade] or (grade .. "年级"),
            semester == "lower" and "下册" or "上册",
            other == "lower" and "下册" or "上册")
    end
    local first, last = grades[1], grades[#grades]
    if first == last then
        return string.format("%s（%s只在%s有内容，可在设置里切换年级）",
            text, label, GRADE_LABEL[first] or (first .. "年级"))
    end
    return string.format("%s（%s覆盖%s到%s，可在设置里切换年级）",
        text, label, GRADE_LABEL[first] or (first .. "年级"),
        GRADE_LABEL[last] or (last .. "年级"))
end
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
-- Title-bar back navigation: parent page for each state (default: home).
-- Second-level pages go straight back to the home page; deeper pages step
-- up one level (e.g. knowledge card -> knowledge list -> home).
local BACK_PARENT = {
    unit_select = "home",
    challenge_menu = "home",
    kp_subject = "home",
    kp_select = "home",
    kp_learn = "kp_select",
    wrongbook = "home",
    wrong_detail = "wrongbook",
    badges = "home",
    shop = "home",
    wallet = "home",
    study_settings = "settings",
    shop_settings = "settings",
    daily_report = "home",
    settings = "home",
    ai_settings = "settings",
    ai_service_edit = "ai_settings",
    ai_preview = "ai_bank",
    summary = "home",
    diagnose_result = "kp_select",
    recite_menu = "home",
    recite = "recite_menu",
    recite_done = "recite_menu",
    word_book = "recite_menu",
    word_drill = "recite_menu",
    word_done = "recite_menu",
}

local KP_STATUS_MARK = { mastered = "★", learning = "●", weak = "▲" }
local KP_STATUS_LABEL = { mastered = "已掌握", learning = "继续加油", weak = "需要加强" }

local function truncate(text, max_chars)
    if not text then return "" end
    local max_bytes = max_chars * 3
    if #text <= max_bytes then return text end
    return util.fixUtf8(text:sub(1, max_bytes), "") .. "…"
end

local function answer_text(question)
    if question.answer_mode == "number" then
        return tostring(question.answer) .. (question.unit_hint or "")
    end
    local prefix = ({ "A. ", "B. ", "C. ", "D. " })[question.answer] or ""
    return prefix .. (question.options[question.answer] or "")
end

function MainView:init()
    self.dimen = Geom:new{
        x = 0, y = 0,
        w = Screen:getWidth(),
        h = Screen:getHeight(),
    }
    self.plugin_path = self.plugin_path
    self.progress = Progress.open()
    self.state = "home"
    self._back_shown = false
    self._current_title = _("学习助理")
    self.selected = nil
    self.number_input = ""
    self.feedback = nil
    self.summary = nil
    self.new_badges = {}
    if self.ai_generating == nil then self.ai_generating = false end
    if self.ai_polishing == nil then self.ai_polishing = false end

    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end

    self.title_bar = TitleBar:new{
        fullscreen = true,
        width = self.dimen.w,
        align = "left",
        title = _("学习助理"),
        title_face = Font:getFace("smalltfont", 22),
        title_h_padding = Size.padding.large,
        close_callback = function() self:onClose() end,
        show_parent = self,
    }
    self.body = VerticalGroup:new{
        align = "center",
        width = self.dimen.w,
    }
    self.main = VerticalGroup:new{
        align = "center",
        width = self.dimen.w,
        self.title_bar,
        self.body,
    }
    self[1] = self.main
    self:render_home()
    self:_maybe_auto_check_update()
end

function MainView:paintTo(bb, x, y)
    -- The plugin is a full-screen page, not a dialog over the reader. Paint an
    -- opaque background first so the underlying reader page never shows through.
    bb:paintRect(x, y, self.dimen.w, self.dimen.h, Blitbuffer.COLOR_WHITE)
    InputContainer.paintTo(self, bb, x, y)
end

function MainView:set_title(text)
    self._current_title = text
    self.title_bar:setTitle(text)
    self:update_back_button()
end

--[[--
Show a persistent back button in the title bar on every non-home page.
TitleBar fixes its icon layout at init, so rebuild it when the back button
appears or disappears (page transitions already repaint the whole screen).
--]]--
function MainView:update_back_button()
    local want_back = self.state ~= "home"
    if want_back == self._back_shown then return end
    self._back_shown = want_back
    self.title_bar = TitleBar:new{
        fullscreen = true,
        width = self.dimen.w,
        align = "left",
        title = self._current_title,
        title_face = Font:getFace("smalltfont", 22),
        title_h_padding = Size.padding.large,
        left_icon = want_back and "chevron.left" or nil,
        left_icon_tap_callback = function() self:onBack() end,
        -- Keep the close (×) button on the home page only: sub pages use the
        -- back chevron so the child cannot drop out of the plugin by accident.
        close_callback = (not want_back) and function() self:onClose() end or nil,
        show_parent = self,
    }
    self.main[1] = self.title_bar
    self.main._size = nil
end

--[[--
Title-bar back: leave the current page without exiting the plugin.
Active practice/diagnosis sessions ask for confirmation first; answers
already given stay saved.
--]]--
function MainView:onBack()
    local state = self.state
    if state == "home" then return end
    if state == "quiz" or state == "feedback"
        or state == "diagnose_quiz" or state == "diagnose_feedback" then
        UIManager:show(ConfirmBox:new{
            text = _("本轮练习还没有完成，确定返回吗？\n\n已经答过的题目和星星会保存。"),
            ok_text = _("返回"),
            cancel_text = _("继续练习"),
            ok_callback = function()
                self.session = nil
                self.diagnose = nil
                self:render_home()
            end,
        })
        return
    end
    if state == "ai_bank" then
        local back = self.ai_bank_back
        self.ai_bank_back = nil
        if back then back() else self:render_home() end
        return
    end
    if state == "choice_list" then
        local back = self.choice_list_back
        self.choice_list_back = nil
        if back then back() else self:render_settings() end
        return
    end
    if state == "unit_select" and self.unit_context == "challenge" then
        self.unit_context = nil
        self:render_challenge_menu()
        return
    end
    local parent = BACK_PARENT[state] or "home"
    if parent == "recite_menu" then
        self:render_recite_menu()
    elseif parent == "kp_select" then
        self:render_kp_select(self.kp_subject or self.diagnose_subject or "math")
    elseif parent == "wrongbook" then
        self:render_wrongbook()
    elseif parent == "settings" then
        self:render_settings()
    elseif parent == "ai_settings" then
        self:render_ai_settings()
    elseif parent == "ai_bank" then
        self:render_ai_bank()
    else
        self:render_home()
    end
end

function MainView:set_body(widget)
    self.body:clear()
    self.body._size = nil
    table.insert(self.body, widget)
    self.main._size = nil
    UIManager:setDirty(self, "ui")
end

-- Geometry for a page that scrolls vertically. The scroll container reserves
-- room for its scroll bars, which would otherwise make the viewport narrower
-- than the content and enable horizontal panning — so widen the viewport by
-- exactly that amount (never beyond the physical screen).
function MainView:scroll_viewport(height)
    local cw = Widgets.width()
    local bar = ScrollableContainer:getScrollbarWidth()
    return Geom:new{
        w = math.min(Screen:getWidth(), cw + bar),
        h = height or (Screen:getHeight() - self.title_bar:getSize().h - 2 * Size.padding.fullscreen),
    }
end

function MainView:close_view()
    self.closed = true
    self.progress:flush()
    UIManager:close(self)
end

function MainView:onClose()
    -- 设置了密码时，退出前先验密码，防止孩子误退
    local pin = self.progress.data.settings.exit_pin
    if pin and #tostring(pin) == 4 then
        self:verify_exit_pin()
        return true
    end
    if self.state == "quiz" or self.state == "feedback"
        or self.state == "diagnose_quiz" or self.state == "diagnose_feedback" then
        UIManager:show(ConfirmBox:new{
            text = _("本轮练习还没有完成，确定退出吗？\n\n已经答过的题目和星星会保存。"),
            ok_text = _("退出"),
            cancel_text = _("继续练习"),
            ok_callback = function() self:close_view() end,
        })
        return true
    end
    self:close_view()
    return true
end

function MainView:ask_pin_input(title, on_done)
    -- 九宫格数字键盘，输满 4 位自动提交；取消/删除见 ui/pinpad.lua
    -- show 必须显式带 "partial"：不带刷新参数时 UIManager 不入队任何刷新，
    -- 若队列里恰好有待刷新的区域（如触发按钮的局部 fast 刷新），屏幕就只刷
    -- 那一小块，弹窗其余部分不显示，要点一下数字才会整屏重绘。
    UIManager:show(PinPadDialog:new{
        title = title,
        on_done = on_done,
    }, "partial")
end

function MainView:verify_exit_pin()
    if self._pin_dialog_open then return end
    self._pin_dialog_open = true
    self:ask_pin_input("退出插件 · 请输入 4 位密码", function(text)
        self._pin_dialog_open = false
        if text == nil then return end -- 取消：留在插件
        local settings = self.progress.data.settings
        if text ~= tostring(settings.exit_pin) then
            UIManager:show(InfoMessage:new{ text = "密码不对，已留在插件。", timeout = 3 })
            return
        end
        -- 密码正确：继续原退出流程（做题中途仍再确认一次，避免丢进度）
        if self.state == "quiz" or self.state == "feedback"
            or self.state == "diagnose_quiz" or self.state == "diagnose_feedback" then
            UIManager:show(ConfirmBox:new{
                text = _("本轮练习还没有完成，确定退出吗？\n\n已经答过的题目和星星会保存。"),
                ok_text = _("退出"),
                cancel_text = _("继续练习"),
                ok_callback = function() self:close_view() end,
            })
        else
            self:close_view()
        end
    end)
end

-- 两个密码各管一段，互不影响：
--   parent  家长密码 —— 进学习设置、进商城后台、兑现卡券、重置学习进度
--   exit    退出插件密码 —— 只关「退出插件」这一件事
local PIN_KINDS = {
    parent = {
        field = "parent_pin",
        label = "家长密码",
        purpose = "进入学习设置、商城后台、兑现卡券和重置学习进度时要输入。",
        ask_title = "设置家长密码（4 位数字）",
    },
    exit = {
        field = "exit_pin",
        label = "退出插件密码",
        purpose = "退出插件（关闭学习助理）时要输入。",
        ask_title = "设置退出插件密码（4 位数字）",
    },
}

function MainView:render_pin_settings(kind, after)
    local meta = PIN_KINDS[kind] or PIN_KINDS.parent
    local settings = self.progress.data.settings
    -- 从哪个页面进来的，设完还回哪去（默认回设置主页）
    local back = after or function() self:render_settings() end
    if not settings[meta.field] then
        self:ask_pin_input(meta.ask_title, function(pin)
            if pin == nil then back() return end
            if not pin:match("^%d%d%d%d$") then
                UIManager:show(InfoMessage:new{ text = "请输入 4 位数字。", timeout = 3 })
                return
            end
            self:ask_pin_input("再输入一次确认", function(pin2)
                if pin2 == nil then back() return end
                if pin2 ~= pin then
                    UIManager:show(InfoMessage:new{ text = "两次输入不一致，未设置。", timeout = 4 })
                else
                    settings[meta.field] = pin
                    self.progress:flush()
                    UIManager:show(InfoMessage:new{
                        text = string.format("%s已设置：%s", meta.label, meta.purpose),
                        timeout = 4 })
                end
                back()
            end)
        end)
        return
    end
    UIManager:show(ConfirmBox:new{
        text = string.format("%s已设置：%s\n\n要清除还是修改？", meta.label, meta.purpose),
        ok_text = "清除密码",
        cancel_text = "修改密码",
        ok_callback = function()
            settings[meta.field] = nil
            self.progress:flush()
            UIManager:show(InfoMessage:new{
                text = string.format("%s已清除。", meta.label), timeout = 3 })
            back()
        end,
        cancel_callback = function()
            -- 修改密码：先验旧密码，防止孩子自行改掉
            self:ask_pin_input(string.format("输入当前%s", meta.label), function(old)
                if old == nil then return end
                if old ~= tostring(settings[meta.field]) then
                    UIManager:show(InfoMessage:new{ text = "当前密码不对。", timeout = 3 })
                    return
                end
                settings[meta.field] = nil
                self:render_pin_settings(kind, after)
            end)
        end,
    })
end

function MainView:confirm_reset_progress()
    UIManager:show(ConfirmBox:new{
        text = "确定清空所有星星、打卡、奖章和错题吗？\n\nAI 服务配置和 AI 题库会保留；这个操作不能撤销。",
        ok_text = "确定清空",
        cancel_text = "取消",
        ok_callback = function()
            self.progress:reset_progress()
            self:render_settings()
        end,
    })
end

function MainView:onCloseWidget()
    self.closed = true
    self.progress:flush()
end

function MainView:subject_label(subject)
    return SUBJECT_LABEL[subject] or "练习"
end

function MainView:semester_label()
    return self.progress.data.settings.semester == "lower" and "下册" or "上册"
end

function MainView:grade_label()
    local grade = tonumber(self.progress.data.settings.grade) or 2
    return GRADE_LABEL[grade] or (grade .. "年级")
end

function MainView:edition_name(subject)
    local settings = self.progress.data.settings
    return self:edition_name_of(subject, settings_edition(settings, subject))
end

-- 当前城市的显示名；未选择时提示按省份推荐。
function MainView:city_label()
    local settings = self.progress.data.settings
    if not settings.city then return "不指定（按省份推荐）" end
    local city = Catalog.city(self.plugin_path, settings.province, settings.city)
    return city and city.name or "不指定（按省份推荐）"
end

-- 四分格按钮用的短城市名；没选城市时只留占位
function MainView:city_short_label()
    local settings = self.progress.data.settings
    if not settings.city then return "城市" end
    local city = Catalog.city(self.plugin_path, settings.province, settings.city)
    return city and city.name or "城市"
end

-- 省市年级 -> 教材匹配结果（城市为空时返回 nil）。
local CITY_SUBJECTS = { yuwen = "chinese", shuxue = "math", yingyu = "english" }

-- 城市 o 字段里记录的出版社名 → 插件物理版本 id（与 catalog/toc 目录一致）
local OTHER_EDITION_ID = {
    wuli = {
        ["人教版"] = "renjiao",
        ["北师大版"] = "bsd", ["北京版"] = "bsd_bj",
        ["苏科版"] = "skb", ["教科版"] = "jkb",
        ["沪科版"] = "hkb", ["沪科粤教版"] = "hkb_hy",
        ["鲁科版"] = "lkb_ws", ["粤教版"] = "yjb", ["沪科教版"] = "hkjb",
    },
}
-- 物理从八年级开始；低于此年级不自动设版本
local OTHER_MIN_GRADE = { wuli = 8 }

function MainView:city_match()
    local settings = self.progress.data.settings
    if not settings.city then return nil end
    return Catalog.city_term(self.plugin_path, settings.province, settings.city,
        settings.grade, settings.semester)
end

-- 某版本在当前这一册的版次，按课本封面写法加括号，如「（2026秋）」。
-- 这一册还没换新版时返回空串，界面上就只显示出版社名。
function MainView:edition_term_suffix(subject, edition)
    local meta = Catalog.edition_meta(self.plugin_path, subject, edition)
    if not meta then return "" end
    local publisher = meta.publisher
    if not publisher or publisher == "" then
        -- 通用版本（如初中数学 junior）本身不带出版社，取城市匹配到的出版社
        local rec, rec_pub = self:recommended_edition(subject)
        if rec == edition then publisher = rec_pub end
    end
    if not publisher or publisher == "" then return "" end
    local settings = self.progress.data.settings
    local year = Catalog.term_year(self.plugin_path, subject, publisher,
        settings.grade, settings.semester)
    local label = Catalog.term_label(year, settings.semester)
    if not label then return "" end
    return string.format("（%s）", label)
end


-- 该科在当前城市/年级下的推荐版本；无匹配或插件未收录时返回 nil。
function MainView:recommended_edition(subject)
    local match = self:city_match()
    for key, plugin_subject in pairs(CITY_SUBJECTS) do
        if plugin_subject == subject and match and match[key] then
            return match[key].edition, match[key].publisher
        end
    end
    return nil
end

-- 两列布局下的教材按钮文案：只放科目 + 当前版本，如「统编版（2026秋）」。
function MainView:edition_tile_label(subject)
    local current = settings_edition(self.progress.data.settings, subject)
    if current and current ~= "" then
        return self:edition_name_of(subject, current) .. self:edition_term_suffix(subject, current)
    end
    -- 源站版本插件未收录（如北京版英语），直接显示出版社名
    local _, rec_pub = self:recommended_edition(subject)
    if rec_pub and rec_pub ~= "" then return rec_pub end
    return "未设置"
end

-- 版本显示名。通用版本（如初中数学 junior）本身没有固定出版社，
-- 按城市匹配到的出版社显示，例如苏州七年级数学显示「苏科版」。
function MainView:edition_name_of(subject, edition)
    local name = Catalog.edition_name(self.plugin_path, subject, edition)
    local meta = Catalog.edition_meta(self.plugin_path, subject, edition)
    if meta and (not meta.publisher or meta.publisher == "") then
        local rec, rec_pub = self:recommended_edition(subject)
        if rec_pub and rec_pub ~= "" and (not rec or rec == edition) then
            return rec_pub
        end
    end
    return name
end

function MainView:course_label()
    return string.format("%s%s · %s · %s", self:grade_label(), self:semester_label(),
        self:edition_name("chinese"), self:edition_name("math"))
end

function MainView:unit_name(question)
    if question.challenge then return "数学拓展" end
    if question.unit_name then return question.unit_name end
    local grade = tonumber(question.grade) or 2
    local semester = question.semester or self.progress.data.settings.semester
    local subject = question.subject or "chinese"
    if subject == "math" then
        local edition = question.edition or "renjiao"
        return MathGen.unit_name(grade, edition, semester, question.unit)
    end
    local units = Bank.units(self.plugin_path, subject, grade, semester, question.edition) or {}
    for _, unit in ipairs(units) do
        if unit.id == question.unit then return unit.name end
    end
    return question.unit or ""
end

function MainView:get_ai_bank()
    if not self.ai_bank then self.ai_bank = AIBank.open() end
    return self.ai_bank
end

function MainView:ai_profile()
    return AIConfig.active_profile(self.progress.data.settings.ai)
end

function MainView:ai_ready()
    local profile = self:ai_profile()
    if not profile then return nil, "请先配置 AI 服务" end
    local ok, err = AIConfig.validate(profile)
    if not ok then return nil, err end
    return profile
end

function MainView:ai_status_label()
    local profile = self:ai_profile()
    if not profile then return "未配置" end
    local ok = AIConfig.validate(profile)
    if not ok then return string.format("%s · 未完成", profile.name) end
    return string.format("%s · %s", profile.name, profile.model)
end

function MainView:find_ai_profile(id)
    return AIConfig.find(self.progress.data.settings.ai, id)
end

function MainView:ensure_ai_ready(callback)
    local profile, err = self:ai_ready()
    if not profile then
        UIManager:show(InfoMessage:new{
            text = "AI 出题还没配置好：" .. tostring(err) .. "\n\n请先在设置中填写 API Key 和模型。",
            timeout = 4,
        })
        self:render_ai_settings()
        return
    end
    callback(profile)
end

function MainView:open_ai_text_input(title, value, password, on_save)
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = value or "",
        text_type = password and "password" or nil,
        buttons = {
            {
                {
                    text = "取消",
                    id = "close",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = "保存",
                    callback = function()
                        local text = dialog:getInputText()
                        UIManager:close(dialog)
                        on_save(text)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function MainView:show_ai_error(message, retry)
    if retry then
        UIManager:show(ConfirmBox:new{
            text = "AI 出题失败：" .. tostring(message),
            ok_text = "重试",
            cancel_text = "返回",
            ok_callback = retry,
        })
    else
        UIManager:show(InfoMessage:new{
            text = "AI 出题失败：" .. tostring(message),
            timeout = 5,
        })
    end
end

function MainView:run_ai_test(profile)
    NetworkMgr:runWhenOnline(function()
        local loading = InfoMessage:new{ text = "正在测试 AI 服务，请稍候…" }
        UIManager:show(loading)
        UIManager:forceRePaint()
        AIClient.test(profile, {
            transport = self.ai_transport,
            callback = function(ok, err)
                UIManager:close(loading)
                if self.closed then return end
                if ok then
                    UIManager:show(InfoMessage:new{ text = "连接成功，可以开始 AI 出题了。", timeout = 4 })
                else
                    UIManager:show(InfoMessage:new{ text = "连接失败：" .. tostring(err), timeout = 6 })
                end
            end,
        })
    end)
end

function MainView:generate_ai(items, per_item)
    if self.ai_generating then
        UIManager:show(InfoMessage:new{ text = "AI 正在生成上一组变种，请稍候。", timeout = 3 })
        return
    end
    local profile, err = self:ai_ready()
    if not profile then
        self:show_ai_error(err)
        return
    end
    local system, user = AIVariant.build_prompt(items, per_item)
    if not system then
        self:show_ai_error(user)
        return
    end
    local bank = self:get_ai_bank()
    local now = os.time()
    local group_id = bank:next_group_id(now)
    NetworkMgr:runWhenOnline(function()
        if self.ai_generating then return end
        self.ai_generating = true
        local loading = InfoMessage:new{
            text = "AI 正在出变种题，请稍候…\n通常需要 10–120 秒，请不要退出。",
        }
        UIManager:show(loading)
        UIManager:forceRePaint()
        local function finish(text, request_err)
            UIManager:close(loading)
            self.ai_generating = false
            if self.closed then return end
            if request_err then
                self:show_ai_error(request_err, function() self:generate_ai(items, per_item) end)
                return
            end
            local questions, parse_err = AIVariant.parse(text, items, per_item, {
                group_id = group_id,
                now = now,
                grade = self.progress.data.settings.grade,
                semester = self.progress.data.settings.semester,
            })
            if not questions then
                self:show_ai_error(parse_err, function() self:generate_ai(items, per_item) end)
                return
            end
            local group = AIVariant.new_group(items, questions, { group_id = group_id, now = now }, profile)
            local saved, save_err = bank:add_group(group)
            if not saved then
                self:show_ai_error(save_err)
                return
            end
            self:render_ai_preview(group_id)
        end
        AIClient.generate(profile, system, user, {
            transport = self.ai_transport,
            callback = finish,
        })
    end)
end

function MainView:start_ai_single(item)
    self:ensure_ai_ready(function()
        self:generate_ai({ item }, 3)
    end)
end

function MainView:start_ai_batch()
    local wrong = self.progress:wrong_items()
    if #wrong == 0 then
        UIManager:show(InfoMessage:new{ text = "错题本还是空的，先做几道题吧。", timeout = 3 })
        return
    end
    local items = {}
    for index = 1, math.min(#wrong, 5) do table.insert(items, wrong[index]) end
    self:ensure_ai_ready(function()
        self:generate_ai(items, 2)
    end)
end

function MainView:render_home()
    self.state = "home"
    self:set_title(_("学习助理"))
    local cw = Widgets.width()
    local today = self.progress:today()
    local streak = self.progress.data.streak.current
    local wrong_count = #self.progress:wrong_items()
    local badge_count = Badges.count(self.progress)
    -- 星星是商城的钱：累计获得减去已兑换花掉的
    local star_balance = Shop.balance(self.progress)
    local pending_coupons = Shop.pending_count(self.progress)

    local stat_width = math.floor(cw / 3)
    local stats = HorizontalGroup:new{
        align = "center",
        Widgets.stat(string.format("★ %d", star_balance), "星星", stat_width),
        Widgets.stat(string.format("%d 天", streak), "连续学习", stat_width),
        Widgets.stat(string.format("%d/%d", today.answered, today.goal), "今日", stat_width),
    }
    local stats_card = Widgets.card(VerticalGroup:new{
        align = "center",
        Widgets.label(self:course_label(), {
            size = 16, color = Blitbuffer.COLOR_DARK_GRAY,
        }),
        Widgets.vspace(Size.span.vertical_default),
        stats,
        Widgets.vspace(Size.span.vertical_default),
        Widgets.progress(today.goal > 0 and today.answered / today.goal or 0, cw - 2 * Size.padding.default),
    }, { width = cw })

    local half = math.floor((cw - Size.span.horizontal_default) / 2)
    local challenge_w = half
    local recite_w = cw - Size.span.horizontal_default - challenge_w

    -- 首页学科按钮跟设置联动：只留当前年级/学期/教材真有题库的科目
    -- （一年级没有英语课本、小学没有物理化学，就不显示，也不再点进去才提示暂无）
    local home_settings = self.progress.data.settings
    local home_grade = tonumber(home_settings.grade) or 2
    local home_semester = home_settings.semester
    local home_subjects = {}
    for _, entry in ipairs(Session.subjects_for(self.plugin_path, home_grade, home_semester, home_settings)) do
        table.insert(home_subjects, entry.subject)
    end

    -- The home page must fit on one screen: no vertical scrolling, and no
    -- horizontal panning. Build it from a height budget so the buttons shrink
    -- a little on short screens instead of forcing the child to scroll.
    local function build(h)
        local challenge_row = HorizontalGroup:new{
            align = "center",
            Widgets.button("今日挑战", {
                width = challenge_w,
                height = Screen:scaleBySize(h.row),
                size = 24,
                callback = function() self:render_challenge_menu() end,
            }),
            Widgets.hspace(Size.span.horizontal_default),
            Widgets.button("背诵·练习", {
                width = recite_w,
                height = Screen:scaleBySize(h.row),
                size = 24,
                callback = function() self:render_recite_menu() end,
            }),
        }
        -- 学科按钮：按当前年级/教材实际有题库的科目动态生成，行内均分宽度
        local subject_rows = subject_grid(home_subjects, cw, function(subject, w)
            return Widgets.button(SUBJECT_LABEL[subject] or subject, {
                width = w,
                height = Screen:scaleBySize(h.subj),
                size = 22,
                callback = function() self:render_unit_select(subject) end,
            })
        end)
        local tool_row_1 = HorizontalGroup:new{
            align = "center",
            Widgets.button(string.format("错题本（%d）", wrong_count), {
                width = half,
                callback = function() self:render_wrongbook() end,
            }),
            Widgets.hspace(Size.span.horizontal_default),
            Widgets.button("AI 题库", {
                width = half,
                callback = function() self:render_ai_bank() end,
            }),
        }
        local tool_row_2 = HorizontalGroup:new{
            align = "center",
            Widgets.button(string.format("奖章墙（%d/%d）", badge_count, #Badges.all()), {
                width = half,
                callback = function() self:render_badges() end,
            }),
            Widgets.hspace(Size.span.horizontal_default),
            Widgets.button("设置", {
                width = half,
                callback = function() self:render_settings() end,
            }),
        }
        local tool_row_3 = HorizontalGroup:new{
            align = "center",
            Widgets.button("星星商城", {
                width = half,
                callback = function() self:render_shop() end,
            }),
            Widgets.hspace(Size.span.horizontal_default),
            Widgets.button(pending_coupons > 0
                    and string.format("钱包（%d 待兑现）", pending_coupons) or "钱包",
                {
                    width = half,
                    callback = function() self:render_wallet() end,
                }),
        }
        local children = {
            align = "center",
            stats_card,
            Widgets.vspace(Size.span.vertical_large),
            challenge_row,
            Widgets.vspace(Size.span.vertical_default),
        }
        if #subject_rows == 0 then
            table.insert(children, Widgets.label(
                "本学习阶段暂无练习题库，可在设置里换年级或教材版本", {
                    size = 17, color = Blitbuffer.COLOR_DARK_GRAY, max_width = cw,
                }))
            table.insert(children, Widgets.vspace(Size.span.vertical_default))
        end
        for _, row in ipairs(subject_rows) do
            table.insert(children, row)
            table.insert(children, Widgets.vspace(Size.span.vertical_default))
        end
        table.insert(children, Widgets.button("知识点学习", {
            width = cw,
            height = Screen:scaleBySize(h.kp),
            size = 22,
            callback = function() self:render_kp_subject() end,
        }))
        table.insert(children, Widgets.vspace(Size.span.vertical_default))
        table.insert(children, tool_row_1)
        table.insert(children, Widgets.vspace(Size.span.vertical_default))
        table.insert(children, tool_row_2)
        table.insert(children, Widgets.vspace(Size.span.vertical_default))
        table.insert(children, tool_row_3)
        return VerticalGroup:new(children)
    end

    local available = Screen:getHeight() - self.title_bar:getSize().h - 2 * Size.padding.fullscreen
    local variants = {
        { row = 64, subj = 58, kp = 56 },
        { row = 58, subj = 54, kp = 54 },
        { row = 52, subj = 52, kp = 52 },
    }
    local content
    for _, h in ipairs(variants) do
        content = build(h)
        if content:getSize().h <= available then break end
    end
    if content:getSize().h > available then
        -- Last resort on very small screens: allow vertical scrolling only.
        -- The scroll container reserves room for its scroll bars, so widen its
        -- viewport a little to keep horizontal panning disabled.
        self:set_body(ScrollableContainer:new{
            dimen = self:scroll_viewport(available),
            show_parent = self,
            content,
        })
    else
        self:set_body(content)
    end
end

--[[--
背诵·练习 (recitation & practice): a plain flashcard loop. Cards are pre-built
per volume (语文背诵 / 英语单词 / 短语 / 课文); 数学栏目（乘法表、纯数字运算）按年级
课本范围现生成; 语文默写看拼音在纸上写词。No answering, no stars — the child
recites/solves out loud, flips the card and self-marks.
--]]--
local RECITE_ROUND = 10

-- 数字口诀读法（乘法口诀 note 用）
local CN_NUM = { "零", "一", "二", "三", "四", "五", "六", "七", "八", "九" }
local function cn_number(n)
    if n < 10 then return CN_NUM[n + 1] end
    local t, o = math.floor(n / 10), n % 10
    local s = (t > 1 and CN_NUM[t + 1] or "") .. "十"
    if o > 0 then s = s .. CN_NUM[o + 1] end
    return s
end

-- 乘法口诀卡：二年级起，1~9 全表（每句只出 a≤b 一种）
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

-- 纯数字运算卡：按低年级课本范围出题（一上 10 以内 / 一下 20 以内 / 二上 100 以内+乘法 / 二下除法）
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

function MainView:recite_stage()
    local settings = self.progress.data.settings
    return tonumber(settings.grade) or 2, settings.semester
end

function MainView:render_recite_menu()
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

function MainView:start_recite(kind_id)
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

function MainView:render_recite_card()
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

function MainView:recite_next()
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

function MainView:render_recite_done()
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

--[[--
英语单词默写: show the Chinese meaning, type the English word.
Pool = "all" (textbook + my words), "builtin" (this volume) or "mine".
--]]--
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

function MainView:render_word_book()
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

function MainView:confirm_remove_word(index, entry)
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

function MainView:add_word_dialog()
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

function MainView:start_word_drill(pool)
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

function MainView:render_word_drill()
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

function MainView:word_drill_input(card)
    self:open_ai_text_input("拼出英文：" .. card.meaning, "", false, function(text)
        self:word_drill_answer(card, tostring(text or ""))
    end)
end

function MainView:word_drill_answer(card, given)
    local drill = self.word_drill
    if not drill then return end
    drill.answered = true
    drill.given = given
    drill.ok = given ~= nil and normalize_word(given) == normalize_word(card.word)
    if drill.ok then drill.correct = drill.correct + 1 end
    self:render_word_drill()
end

function MainView:word_drill_next()
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

function MainView:render_word_done()
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

--[[--
今日挑战的二级菜单：按当前年级列出所有真正有内容的学科。

数据源与混合出题（Session.build_mixed）完全一致 —— 都是
Session.subjects_for() —— 所以这里显示的学科就是“今日挑战涵盖的所有学科”，
不会再出现点进去提示暂无题库的情况。选完学科进三级菜单挑单元，每轮题数跟设置里的每日目标走；
第一行的“全部学科混合”则直接开始跨学科混合出题。
--]]--
function MainView:render_challenge_menu()
    self.state = "challenge_menu"
    self:set_title(_("今日挑战"))
    local cw = Widgets.width()
    local settings = self.progress.data.settings
    local grade = tonumber(settings.grade) or 2
    local semester = settings.semester
    local entries = Session.subjects_for(self.plugin_path, grade, semester, settings)
    local goal = tonumber(settings.daily_goal) or 10

    -- 单科练习统一走首页的学科按钮（那边才有单元细分），这里只留跨学科混合题，
    -- 免得同一套「选学科 → 选单元」在首页出现两份。
    local available = {}
    for _, entry in ipairs(entries) do available[entry.subject] = true end

    local children = {
        align = "center",
        Widgets.label(string.format("%s%s · 覆盖 %d 个学科 · 每轮 %d 题",
            self:grade_label(), self:semester_label(), #entries, goal), {
            size = 18, color = Blitbuffer.COLOR_DARK_GRAY,
        }),
        Widgets.vspace(Size.span.vertical_default),
    }
    if #entries == 0 then
        table.insert(children, Widgets.label("本学习阶段暂无练习题库，可在设置里换年级或教材版本", {
            size = 17, color = Blitbuffer.COLOR_DARK_GRAY, max_width = cw,
        }))
    else
        table.insert(children, Widgets.button(string.format("全部学科混合（%d 题）", goal), {
            width = cw,
            height = Screen:scaleBySize(58),
            size = 22,
            callback = function() self:start_session({ mode = "mixed", count = goal }) end,
        }))
        table.insert(children, Widgets.vspace(Size.span.vertical_default))
        table.insert(children, Widgets.textbox(
            "想练单一科目：回首页点语文 / 数学 / 英语，里面能选单元。", cw, {
                size = 16, alignment = "center", color = Blitbuffer.COLOR_DARK_GRAY,
            }))
        local missing = {}
        for _, subject in ipairs(SUBJECT_ORDER) do
            if not available[subject] then
                table.insert(missing, self:subject_label(subject))
            end
        end
        if #missing > 0 then
            table.insert(children, Widgets.vspace(Size.span.vertical_default))
            table.insert(children, Widgets.label("本学习阶段暂无：" .. table.concat(missing, "、"), {
                size = 16, color = Blitbuffer.COLOR_DARK_GRAY, max_width = cw,
            }))
        end
    end
    table.insert(children, Widgets.vspace(Size.span.vertical_large))
    table.insert(children, Widgets.button("返回首页", {
        width = cw,
        height = Screen:scaleBySize(48),
        size = 20,
        callback = function() self:render_home() end,
    }))
    self:set_body(CenterContainer:new{
        dimen = Geom:new{ w = cw, h = self:scroll_viewport().h },
        VerticalGroup:new(children),
    })
end

--[[--
学科的三级菜单：选单元出题（每轮题数 = 每日目标）。目前只从首页学科按钮进入；
早先「今日挑战里列学科」的入口已删（与首页学科按钮完全重复），context 参数保留兼容。
--]]--
function MainView:render_unit_select(subject, context)
    self.state = "unit_select"
    self.unit_context = context
    local from_challenge = context == "challenge"
    self:set_title(from_challenge and (_("今日挑战 · ") .. self:subject_label(subject))
        or (self:subject_label(subject) .. _("练习")))
    local cw = Widgets.width()
    local settings = self.progress.data.settings
    local semester = settings.semester
    local grade = tonumber(settings.grade) or 2
    local edition = settings_edition(settings, subject)
    MathGen.set_plugin_path(self.plugin_path)
    local units
    local used_edition = edition
    local is_bank_subject = subject ~= "math" or (tonumber(grade) or 2) >= 7
    if is_bank_subject then
        -- No textbook at this grade/semester at all: say so plainly instead of
        -- surfacing a raw loader error like "grade not found".
        if not has_volume(self.plugin_path, subject, grade, semester) then
            UIManager:show(InfoMessage:new{
                text = stage_missing_text(self.plugin_path, subject, grade, semester),
                timeout = 5,
            })
            if from_challenge then self:render_challenge_menu() else self:render_home() end
            return
        end
        units = Bank.units(self.plugin_path, subject, grade, semester, edition)
        if not units then
            local loaded, err = Bank.load(self.plugin_path, subject, grade, semester, edition)
            if not loaded then
                -- Retry fallback editions: an edition may be grade-band bound
                -- (译林 4A only ships grade 4, PEP only 3-6, etc.).
                local fallbacks = {}
                for _, ed in ipairs(Catalog.editions(self.plugin_path, subject)) do
                    if ed.id ~= edition then table.insert(fallbacks, ed.id) end
                end
                for _, fb in ipairs(fallbacks) do
                    if fb ~= edition then
                        loaded, err = Bank.load(self.plugin_path, subject, grade, semester, fb)
                        if loaded then
                            used_edition = fb
                            break
                        end
                    end
                end
            end
            if not loaded then
                UIManager:show(InfoMessage:new{ text = "题库加载失败：" .. tostring(err) })
                if from_challenge then self:render_challenge_menu() else self:render_home() end
                return
            end
            units = loaded.units
        end
    else
        units = MathGen.units(grade, edition, semester) or MathGen.units(semester)
    end

    local goal = tonumber(self.progress.data.settings.daily_goal) or 10
    local range_hint = from_challenge
        and string.format("选择练习范围 · 每轮 %d 题", goal) or "选择练习范围"
    local edition_label = used_edition ~= edition
        and Catalog.edition_name(self.plugin_path, subject, used_edition)
        or self:edition_name(subject)
    local content = VerticalGroup:new{
        align = "center",
        Widgets.label(string.format("%s%s · %s · %s", self:grade_label(), self:semester_label(), edition_label, range_hint), {
            size = 18, color = Blitbuffer.COLOR_DARK_GRAY,
        }),
        Widgets.vspace(Size.span.vertical_default),
        Widgets.button("综合练习（全部单元）", {
            width = cw,
            height = Screen:scaleBySize(60),
            size = 22,
            callback = function()
                self:start_session({ mode = "subject", subject = subject, unit = "all", challenge = from_challenge })
            end,
        }),
        Widgets.vspace(Size.span.vertical_default),
    }

    if subject == "math" and not is_bank_subject then
        table.insert(content, Widgets.button("拓展挑战（数感 · 推理 · 几何 · 数据）", {
            width = cw,
            height = Screen:scaleBySize(60),
            size = 20,
            callback = function() self:start_session({ mode = "challenge", subject = "math", unit = "all" }) end,
        }))
        table.insert(content, Widgets.vspace(Size.span.vertical_default))
    end

    local half = math.floor((cw - Size.span.horizontal_default) / 2)
    local row
    for i, unit in ipairs(units) do
        local button = Widgets.button(unit.name, {
            width = half,
            height = Screen:scaleBySize(52),
            size = 19,
            callback = function()
                self:start_session({ mode = "subject", subject = subject, unit = unit.id, challenge = from_challenge })
            end,
        })
        if i % 2 == 1 then
            row = HorizontalGroup:new{ align = "center", button }
            table.insert(content, row)
            table.insert(content, Widgets.vspace(Size.span.vertical_default))
        else
            table.insert(row, Widgets.hspace(Size.span.horizontal_default))
            table.insert(row, button)
        end
    end
    table.insert(content, Widgets.button(from_challenge and "返回学科选择" or "返回首页", {
        width = cw,
        height = Screen:scaleBySize(48),
        size = 20,
        callback = function()
            if from_challenge then self:render_challenge_menu() else self:render_home() end
        end,
    }))
    self:set_body(content)
end

function MainView:start_session(opts)
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

function MainView:quiz_title()
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

function MainView:render_header()
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

function MainView:render_question_card(question)
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
    table.insert(parts, Widgets.textbox(question.stem, inner_width, {
        size = 27,
        line_height = 0.35,
    }))
    return Widgets.card(parts, { width = cw, padding = Size.padding.large })
end

function MainView:rerender_input()
    if self.diagnose and self.state == "diagnose_quiz" then
        self:render_diagnose_quiz()
    else
        self:render_quiz()
    end
end

function MainView:render_choice_area(question)
    local cw = Widgets.width()
    local area = VerticalGroup:new{ align = "center" }
    local prefixes = { "A. ", "B. ", "C. ", "D. " }
    for i, option in ipairs(question.options or {}) do
        table.insert(area, Widgets.choice_button(prefixes[i] .. option, cw, self.selected == i, function()
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

function MainView:render_keypad(question)
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

function MainView:render_quiz()
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

function MainView:submit_answer(value)
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

function MainView:render_feedback()
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

function MainView:next_question()
    if self.session:advance() then
        self.feedback = nil
        self.selected = nil
        self.number_input = ""
        self:render_quiz()
    else
        self:finish_session()
    end
end

function MainView:finish_session()
    self.summary = self.session:finish()
    self.new_badges = Badges.evaluate(self.progress)
    self:render_summary()
end

function MainView:render_summary()
    self.state = "summary"
    self:set_title("本轮完成")
    local cw = Widgets.width()
    local s = self.summary
    local badge_text
    if #self.new_badges > 0 then
        local names = {}
        for _, badge in ipairs(self.new_badges) do table.insert(names, badge.name) end
        badge_text = "新奖章：" .. table.concat(names, "、")
    else
        badge_text = "继续加油，下一枚奖章在等你！"
    end
    local breakdown = s.breakdown or {}
    local bonus_parts = {}
    if (breakdown.completion or 0) > 0 then table.insert(bonus_parts, "完成 +" .. breakdown.completion) end
    if (breakdown.perfect or 0) > 0 then table.insert(bonus_parts, "满分 +" .. breakdown.perfect) end
    if (breakdown.first_of_day or 0) > 0 then table.insert(bonus_parts, "今日首轮 +" .. breakdown.first_of_day) end
    local breakdown_text = string.format("答题获得 ★%d", s.points - (breakdown.total or 0))
    if #bonus_parts > 0 then
        breakdown_text = breakdown_text .. "，" .. table.concat(bonus_parts, "，")
    end
    local content = VerticalGroup:new{
        align = "center",
        Widgets.card(VerticalGroup:new{
            align = "center",
            Widgets.label(s.perfect and "满分！" or "做得不错！", { size = 30, bold = true }),
            Widgets.vspace(Size.span.vertical_default),
            Widgets.label(string.format("答对 %d/%d 题", s.correct, s.total), { size = 22 }),
            Widgets.vspace(Size.span.vertical_default),
            Widgets.label(string.format("获得 ★%d", s.points), { size = 26, bold = true }),
            Widgets.vspace(Size.span.vertical_default),
            Widgets.label(string.format("最高连对 %d 题", s.max_combo), { size = 18, color = Blitbuffer.COLOR_DARK_GRAY }),
            Widgets.vspace(Size.span.vertical_default),
            Widgets.label(breakdown_text, { size = 15, color = Blitbuffer.COLOR_DARK_GRAY }),
        }, { width = cw, padding = Size.padding.large }),
        Widgets.vspace(Size.span.vertical_large),
        Widgets.textbox(badge_text, cw, { size = 19, alignment = "center" }),
        Widgets.vspace(Size.span.vertical_large),
    }
    if s.mode == "kp" and s.kp_statuses then
        local kp_line
        if self.last_kp_topic and s.kp_statuses[self.last_kp_topic] then
            local graph = Knowledge.graph(self.plugin_path, self.last_kp_subject or "math")
            local node = graph and graph.nodes[self.last_kp_topic]
            local name = node and node.name or self.last_kp_topic
            kp_line = string.format("知识点「%s」：%s", name,
                KP_STATUS_LABEL[s.kp_statuses[self.last_kp_topic]] or "")
        else
            local mastered, learning, weak = 0, 0, 0
            for _, status in pairs(s.kp_statuses) do
                if status == "mastered" then mastered = mastered + 1
                elseif status == "weak" then weak = weak + 1
                else learning = learning + 1 end
            end
            kp_line = string.format("本轮知识点：已掌握 %d · 学习中 %d · 薄弱 %d", mastered, learning, weak)
        end
        table.insert(content, Widgets.textbox(kp_line, cw, { size = 19, alignment = "center" }))
        table.insert(content, Widgets.vspace(Size.span.vertical_default))
    end
    local half = math.floor((cw - Size.span.horizontal_default) / 2)
    table.insert(content, HorizontalGroup:new{
        align = "center",
        Widgets.button("再来一轮", {
            width = half,
            height = Screen:scaleBySize(56),
            size = 21,
            callback = function() self:start_session(self.last_session_opts or { mode = "subject", subject = self.subject or "chinese", unit = self.unit or "all" }) end,
        }),
        Widgets.hspace(Size.span.horizontal_default),
        Widgets.button("回首页", {
            width = half,
            height = Screen:scaleBySize(56),
            size = 21,
            callback = function() self:render_home() end,
        }),
    })
    table.insert(content, Widgets.vspace(Size.span.vertical_default))
    table.insert(content, Widgets.button("看今日总结", {
        width = cw,
        size = 20,
        callback = function() self:open_daily_report() end,
    }))
    if s.mode == "kp" and self.last_kp_subject then
        table.insert(content, Widgets.vspace(Size.span.vertical_default))
        table.insert(content, Widgets.button("返回知识点", {
            width = cw,
            size = 20,
            callback = function()
                if self.last_kp_topic then
                    self:render_kp_learn(self.last_kp_subject, self.last_kp_topic)
                else
                    self:render_kp_select(self.last_kp_subject)
                end
            end,
        }))
    end
    if #self.progress:wrong_items() > 0 then
        table.insert(content, Widgets.vspace(Size.span.vertical_default))
        table.insert(content, Widgets.button(string.format("查看错题本（%d）", #self.progress:wrong_items()), {
            width = cw,
            size = 20,
            callback = function() self:render_wrongbook() end,
        }))
    end
    self:set_body(ScrollableContainer:new{
        dimen = self:scroll_viewport(),
        show_parent = self,
        content,
    })
end

function MainView:render_wrongbook()
    self.state = "wrongbook"
    self:set_title("错题本")
    local cw = Widgets.width()
    local gap = Screen:scaleBySize(8)
    local half = math.floor((cw - gap) / 2)
    local items = self.progress:wrong_items()
    local content = VerticalGroup:new{ align = "center" }
    if #items == 0 then
        table.insert(content, Widgets.label("还没有错题，真棒！", { size = 24, bold = true }))
        table.insert(content, Widgets.vspace(Size.span.vertical_large))
        table.insert(content, Widgets.button("AI 题库", {
            width = cw,
            size = 20,
            callback = function() self:render_ai_bank(nil, function() self:render_wrongbook() end) end,
        }))
        table.insert(content, Widgets.vspace(Size.span.vertical_default))
    else
        -- 按学科分组，二级菜单进学科看错题和知识点
        local by_subject = {}
        for _, item in ipairs(items) do
            by_subject[item.subject] = (by_subject[item.subject] or 0) + 1
        end
        table.insert(content, Widgets.label(string.format("共 %d 道错题，选择学科查看详情。", #items), {
            size = 18, color = Blitbuffer.COLOR_DARK_GRAY,
        }))
        table.insert(content, Widgets.vspace(Size.span.vertical_default))
        local row, rows = {}, {}
        for _, subject in ipairs(SUBJECT_ORDER) do
            if by_subject[subject] then
                table.insert(row, Widgets.button(string.format("%s（%d）", SUBJECT_LABEL[subject], by_subject[subject]), {
                    width = half,
                    height = Screen:scaleBySize(54),
                    size = 19,
                    callback = function() self:render_wrongbook_subject(subject) end,
                }))
                if #row == 2 then
                    table.insert(rows, HorizontalGroup:new{ align = "center", row[1],
                        Widgets.hspace(gap), row[2] })
                    row = {}
                end
            end
        end
        if #row == 1 then
            table.insert(rows, HorizontalGroup:new{ align = "center", row[1],
                Widgets.hspace(gap), Widgets.vspace(0) })
        end
        for _, r in ipairs(rows) do
            table.insert(content, r)
            table.insert(content, Widgets.vspace(Size.span.vertical_default))
        end
        table.insert(content, Widgets.button("复习全部错题", {
            width = cw,
            height = Screen:scaleBySize(56),
            size = 21,
            callback = function() self:start_session({ mode = "wrong" }) end,
        }))
        table.insert(content, Widgets.vspace(Size.span.vertical_default))
        local ai_profile = self:ai_ready()
        local ai_count = math.min(#items, 5) * 2
        table.insert(content, HorizontalGroup:new{
            align = "center",
            Widgets.button(ai_profile and string.format("AI 强化（%d 题）", ai_count) or "AI 强化（先配置）", {
                width = half,
                height = Screen:scaleBySize(54),
                size = 18,
                callback = function() self:start_ai_batch() end,
            }),
            Widgets.hspace(Size.span.horizontal_default),
            Widgets.button("AI 题库", {
                width = half,
                height = Screen:scaleBySize(54),
                size = 18,
                callback = function() self:render_ai_bank(nil, function() self:render_wrongbook() end) end,
            }),
        })
        table.insert(content, Widgets.vspace(Size.span.vertical_default))
    end
    table.insert(content, Widgets.button("回首页", {
        width = cw,
        size = 20,
        callback = function() self:render_home() end,
    }))
    self:set_body(content)
end

-- 错题本二级页：某学科的错题列表 + 错题涉及的知识点（理科含前置知识点）
function MainView:render_wrongbook_subject(subject)
    self.state = "wrongbook"
    self:set_title("错题本 · " .. (SUBJECT_LABEL[subject] or subject))
    local cw = Widgets.width()
    local content = VerticalGroup:new{ align = "center" }
    local subject_items = {}
    for _, item in ipairs(self.progress:wrong_items()) do
        if item.subject == subject then table.insert(subject_items, item) end
    end
    if #subject_items == 0 then
        table.insert(content, Widgets.label("该学科暂无错题。", { size = 20, bold = true }))
    else
        table.insert(content, Widgets.label(string.format("%s 共 %d 道错题。", SUBJECT_LABEL[subject], #subject_items), {
            size = 18, color = Blitbuffer.COLOR_DARK_GRAY,
        }))
        table.insert(content, Widgets.vspace(Size.span.vertical_default))
        local shown = math.min(#subject_items, 10)
        for i = #subject_items, math.max(1, #subject_items - shown + 1), -1 do
            local item = subject_items[i]
            table.insert(content, Widgets.button(truncate(item.stem, 26), {
                width = cw,
                height = Screen:scaleBySize(50),
                size = 18,
                align = "left",
                callback = function() self:render_wrong_detail(item) end,
            }))
            table.insert(content, Widgets.vspace(Size.span.vertical_default))
        end
        table.insert(content, Widgets.button(string.format("复习%s错题（%d 题）", SUBJECT_LABEL[subject], #subject_items), {
            width = cw,
            height = Screen:scaleBySize(56),
            size = 20,
            callback = function() self:start_session({ mode = "wrong", subject = subject, wrong_items = subject_items }) end,
        }))
        table.insert(content, Widgets.vspace(Size.span.vertical_default))

        -- 知识点：错题涉及的知识点及其掌握状态；理科再列前置知识点
        local science = subject == "math" or subject == "physics"
            or subject == "chemistry" or subject == "biology"
        local graph = Knowledge.graph(self.plugin_path, subject)
        local seen_topics = {}
        for _, item in ipairs(subject_items) do
            if item.topic then seen_topics[item.topic] = true end
        end
        local kp_rows = {}
        for topic_id in pairs(seen_topics) do
            local node = graph and graph.nodes[topic_id]
            if node then
                local status = self.progress:kp_status(subject, topic_id)
                table.insert(kp_rows, { id = topic_id, name = node.name,
                    status = status, grade = node.grade })
            end
        end
        if #kp_rows > 0 then
            table.insert(content, Widgets.card(VerticalGroup:new{
                align = "left",
                Widgets.label("错题涉及的知识点", { size = 18, bold = true }),
                Widgets.vspace(Size.span.vertical_default),
            }))
            for _, kp in ipairs(kp_rows) do
                table.insert(content, Widgets.button(
                    string.format("%s · %s", kp.name, KP_STATUS_LABEL[kp.status] or "未学"), {
                    width = cw,
                    height = Screen:scaleBySize(46),
                    size = 17,
                    align = "left",
                    callback = function() self:render_kp_learn(subject, kp.id) end,
                }))
                table.insert(content, Widgets.vspace(Size.span.vertical_default))
                if science then
                    -- 前置知识点（理科承上启下）：列掌握状态，薄弱的优先补
                    for _, edge in ipairs(Knowledge.prereqs(self.plugin_path, subject, kp.id)) do
                        local pre = graph.nodes[edge.id]
                        if pre then
                            local pre_status = self.progress:kp_status(subject, edge.id)
                            if pre_status ~= "mastered" then
                                table.insert(content, Widgets.button(
                                    string.format("└ 前置：%s · %s", pre.name,
                                        KP_STATUS_LABEL[pre_status] or "未学"), {
                                    width = cw,
                                    height = Screen:scaleBySize(42),
                                    size = 15,
                                    align = "left",
                                    callback = function() self:render_kp_learn(subject, edge.id) end,
                                }))
                                table.insert(content, Widgets.vspace(Size.span.vertical_default))
                            end
                        end
                    end
                end
            end
            table.insert(content, Widgets.vspace(Size.span.vertical_default))
        end
    end
    table.insert(content, Widgets.button("回错题本", {
        width = cw,
        size = 20,
        callback = function() self:render_wrongbook() end,
    }))
    self:set_body(content)
end

function MainView:render_wrong_detail(item)
    self.state = "wrong_detail"
    self:set_title("错题详情")
    local cw = Widgets.width()
    local content = VerticalGroup:new{
        align = "center",
        Widgets.card(VerticalGroup:new{
            align = "left",
            Widgets.label(string.format("%s · %s%s", SUBJECT_LABEL[item.subject] or "题", self:unit_name(item), item.competency and (" · " .. item.competency) or ""), { size = 16, color = Blitbuffer.COLOR_DARK_GRAY }),
            Widgets.vspace(Size.span.vertical_default),
            item.passage and Widgets.textbox(item.passage, cw - 4 * Size.padding.default, { size = 18 }) or Widgets.vspace(0),
            item.passage and Widgets.vspace(Size.span.vertical_default) or Widgets.vspace(0),
            Widgets.textbox(item.stem or "", cw - 4 * Size.padding.default, { size = 25 }),
            Widgets.vspace(Size.span.vertical_default),
            Widgets.label("正确答案：" .. answer_text(item), { size = 20, bold = true }),
            Widgets.vspace(Size.span.vertical_default),
            Widgets.textbox(item.explain or "", cw - 4 * Size.padding.default, { size = 17 }),
        }, { width = cw, padding = Size.padding.large }),
        Widgets.vspace(Size.span.vertical_large),
        Widgets.button("重做这道题", {
            width = cw,
            height = Screen:scaleBySize(56),
            size = 21,
            callback = function() self:start_session({ mode = "wrong", wrong_items = { item } }) end,
        }),
        Widgets.vspace(Size.span.vertical_default),
        Widgets.button(self:ai_ready() and "AI 出 3 道变种" or "AI 出 3 道变种（先配置）", {
            width = cw,
            height = Screen:scaleBySize(56),
            size = 21,
            callback = function() self:start_ai_single(item) end,
        }),
        Widgets.vspace(Size.span.vertical_default),
        (#self:get_ai_bank():groups(item.id) > 0) and Widgets.button(string.format("已有 AI 变种（%d 组）", #self:get_ai_bank():groups(item.id)), {
            width = cw,
            height = Screen:scaleBySize(50),
            size = 19,
            callback = function()
                self:render_ai_bank(item.id, function() self:render_wrong_detail(item) end)
            end,
        }) or Widgets.vspace(0),
        (#self:get_ai_bank():groups(item.id) > 0) and Widgets.vspace(Size.span.vertical_default) or Widgets.vspace(0),
        Widgets.button("返回错题本", {
            width = cw,
            size = 20,
            callback = function() self:render_wrongbook() end,
        }),
    }
    self:set_body(content)
end

function MainView:render_ai_settings()
    self.state = "ai_settings"
    self:set_title("AI 出题设置")
    local cw = Widgets.width()
    local ai = self.progress.data.settings.ai
    local active = AIConfig.active_profile(ai)
    local active_text = "未配置"
    if active then
        active_text = string.format("%s · %s", active.name, active.model ~= "" and active.model or "未填模型")
        if not AIConfig.validate(active) then active_text = active.name .. " · 未完成" end
    end
    if ai.config_error then active_text = "配置文件导入失败" end
    local content = VerticalGroup:new{ align = "center" }
    table.insert(content, Widgets.card(VerticalGroup:new{
        align = "left",
        Widgets.label("当前 AI 服务", { size = 16, color = Blitbuffer.COLOR_DARK_GRAY }),
        Widgets.vspace(Size.span.vertical_default),
        Widgets.label(active_text, {
            size = 21, bold = true,
        }),
        Widgets.vspace(Size.span.vertical_default),
        Widgets.textbox("AI 出题需要联网。调用时会把你选择的错题文本发送给对应服务商；API Key 会明文保存在本机（studyassist.lua 或配置文件）中，请使用低额度 Key，并勿在共用设备上保存。也可把 studyassist_ai_config.json 放到 koreader/settings/ 后重启，自动导入 API 地址、Key 和模型。", cw - 4 * Size.padding.default, {
            size = 15, color = Blitbuffer.COLOR_DARK_GRAY,
        }),
    }, { width = cw, padding = Size.padding.large }))
    if ai.config_error then
        table.insert(content, Widgets.vspace(Size.span.vertical_default))
        table.insert(content, Widgets.textbox("配置文件错误：" .. ai.config_error, cw - 4 * Size.padding.default, {
            size = 15, color = Blitbuffer.COLOR_DARK_GRAY,
        }))
    elseif ai.config_source then
        table.insert(content, Widgets.vspace(Size.span.vertical_default))
        table.insert(content, Widgets.textbox("当前 AI 配置来自 koreader/settings/" .. ai.config_source .. "；修改该文件后重启 KOReader 即可重新导入。", cw - 4 * Size.padding.default, {
            size = 15, color = Blitbuffer.COLOR_DARK_GRAY,
        }))
    end
    table.insert(content, Widgets.vspace(Size.span.vertical_large))

    for _, profile in ipairs(ai.profiles) do
        local prefix = profile.id == ai.active_id and "当前 · " or ""
        table.insert(content, Widgets.button(string.format("%s%s · %s", prefix, profile.name, profile.model ~= "" and profile.model or "未填模型"), {
            width = cw,
            height = Screen:scaleBySize(54),
            align = "left",
            size = 18,
            callback = function() self:render_ai_service_edit(profile.id) end,
        }))
        table.insert(content, Widgets.vspace(Size.span.vertical_default))
    end
    table.insert(content, Widgets.button("添加 AI 服务", {
        width = cw,
        height = Screen:scaleBySize(54),
        size = 19,
        callback = function() self:render_ai_preset_select() end,
    }))
    table.insert(content, Widgets.vspace(Size.span.vertical_large))
    table.insert(content, Widgets.textbox("AI 生成内容仅供练习，可能有错误；每次出题都会消耗服务商 token。", cw, {
        size = 15, alignment = "center", color = Blitbuffer.COLOR_DARK_GRAY,
    }))
    table.insert(content, Widgets.vspace(Size.span.vertical_default))
    table.insert(content, Widgets.button("返回设置", {
        width = cw,
        size = 20,
        callback = function() self:render_settings() end,
    }))
    local scroll = ScrollableContainer:new{
        dimen = self:scroll_viewport(),
        show_parent = self,
        content,
    }
    self:set_body(scroll)
end

function MainView:render_ai_preset_select()
    local items = {}
    for _, preset in ipairs(AIConfig.presets()) do
        table.insert(items, {
            id = preset.id,
            name = string.format("%s · %s", preset.name, preset.protocol == "openai" and "OpenAI 兼容" or preset.protocol),
        })
    end
    self:render_choice_list("添加 AI 服务", items, function(item)
        local ai = self.progress.data.settings.ai
        local profile, err = AIConfig.new_profile(item.id, ai)
        if not profile then
            UIManager:show(InfoMessage:new{ text = tostring(err), timeout = 4 })
            return
        end
        table.insert(ai.profiles, profile)
        if not ai.active_id then ai.active_id = profile.id end
        self.progress:flush()
        self:render_ai_service_edit(profile.id)
    end, function() self:render_ai_settings() end)
end

function MainView:render_ai_service_edit(profile_id)
    local profile = self:find_ai_profile(profile_id)
    if not profile then self:render_ai_settings() return end
    self.state = "ai_service_edit"
    self:set_title(profile.name)
    local cw = Widgets.width()
    local ai = self.progress.data.settings.ai
    local content = VerticalGroup:new{ align = "center" }
    table.insert(content, Widgets.card(VerticalGroup:new{
        align = "left",
        Widgets.label(profile.name, { size = 21, bold = true }),
        Widgets.vspace(Size.span.vertical_default),
        Widgets.textbox(string.format("协议：%s\n接口：%s", profile.protocol, profile.base_url ~= "" and profile.base_url or "未填写"), cw - 4 * Size.padding.default, {
            size = 15, color = Blitbuffer.COLOR_DARK_GRAY,
        }),
    }, { width = cw, padding = Size.padding.large }))
    table.insert(content, Widgets.vspace(Size.span.vertical_large))
    table.insert(content, Widgets.button("API Key：" .. AIConfig.mask_key(profile.api_key), {
        width = cw,
        height = Screen:scaleBySize(54),
        align = "left",
        size = 18,
        callback = function()
            self:open_ai_text_input("设置 API Key", profile.api_key, true, function(text)
                profile.api_key = text:match("^%s*(.-)%s*$") or ""
                self.progress:flush()
                self:render_ai_service_edit(profile.id)
            end)
        end,
    }))
    table.insert(content, Widgets.vspace(Size.span.vertical_default))
    table.insert(content, Widgets.button("模型：" .. (profile.model ~= "" and profile.model or "未填写"), {
        width = cw,
        height = Screen:scaleBySize(54),
        align = "left",
        size = 18,
        callback = function()
            self:open_ai_text_input("设置模型名称", profile.model, false, function(text)
                profile.model = text:match("^%s*(.-)%s*$") or ""
                self.progress:flush()
                self:render_ai_service_edit(profile.id)
            end)
        end,
    }))
    table.insert(content, Widgets.vspace(Size.span.vertical_default))
    if profile.preset == "custom" or profile.preset == "ollama" then
        table.insert(content, Widgets.button("接口地址：" .. (profile.base_url ~= "" and profile.base_url or "未填写"), {
            width = cw,
            height = Screen:scaleBySize(54),
            align = "left",
            size = 18,
            callback = function()
                self:open_ai_text_input("设置接口地址", profile.base_url, false, function(text)
                    profile.base_url = text:match("^%s*(.-)%s*$") or ""
                    self.progress:flush()
                    self:render_ai_service_edit(profile.id)
                end)
            end,
        }))
        table.insert(content, Widgets.vspace(Size.span.vertical_default))
    end
    if ai.active_id ~= profile.id then
        table.insert(content, Widgets.button("设为当前服务", {
            width = cw,
            height = Screen:scaleBySize(54),
            size = 19,
            callback = function()
                ai.active_id = profile.id
                self.progress:flush()
                self:render_ai_service_edit(profile.id)
            end,
        }))
        table.insert(content, Widgets.vspace(Size.span.vertical_default))
    end
    table.insert(content, Widgets.button("测试连接", {
        width = cw,
        height = Screen:scaleBySize(54),
        size = 19,
        callback = function() self:run_ai_test(profile) end,
    }))
    table.insert(content, Widgets.vspace(Size.span.vertical_default))
    table.insert(content, Widgets.button("删除这个服务", {
        width = cw,
        height = Screen:scaleBySize(50),
        size = 18,
        callback = function()
            UIManager:show(ConfirmBox:new{
                text = "确定删除这个 AI 服务配置吗？API Key 也会一起删除。",
                ok_text = "删除",
                cancel_text = "取消",
                ok_callback = function()
                    for index = #ai.profiles, 1, -1 do
                        if ai.profiles[index].id == profile.id then table.remove(ai.profiles, index) end
                    end
                    AIConfig.normalize(ai)
                    self.progress:flush()
                    self:render_ai_settings()
                end,
            })
        end,
    }))
    table.insert(content, Widgets.vspace(Size.span.vertical_default))
    table.insert(content, Widgets.button("返回 AI 设置", {
        width = cw,
        size = 20,
        callback = function() self:render_ai_settings() end,
    }))
    local scroll = ScrollableContainer:new{
        dimen = self:scroll_viewport(),
        show_parent = self,
        content,
    }
    self:set_body(scroll)
end

function MainView:render_ai_bank(origin_id, back)
    self.state = "ai_bank"
    self.ai_bank_filter = origin_id
    self.ai_bank_back = back or function() self:render_home() end
    self:set_title(origin_id and "这道题的 AI 变种" or "AI 题库")
    local cw = Widgets.width()
    local bank = self:get_ai_bank()
    local groups = bank:groups(origin_id)
    local content = VerticalGroup:new{ align = "center" }
    if #groups == 0 then
        table.insert(content, Widgets.label(origin_id and "这道题还没有 AI 变种。" or "还没有 AI 变种题。", {
            size = 22, bold = true,
        }))
        table.insert(content, Widgets.vspace(Size.span.vertical_default))
        table.insert(content, Widgets.textbox(origin_id and "回到错题详情，点「AI 出 3 道变种」生成。" or "去错题本选择一道题生成，或在错题本使用「AI 强化」。", cw, {
            size = 16, alignment = "center", color = Blitbuffer.COLOR_DARK_GRAY,
        }))
        table.insert(content, Widgets.vspace(Size.span.vertical_large))
        if not self:ai_profile() then
            table.insert(content, Widgets.button("配置 AI 服务", {
                width = cw,
                height = Screen:scaleBySize(54),
                size = 19,
                callback = function() self:render_ai_settings() end,
            }))
            table.insert(content, Widgets.vspace(Size.span.vertical_default))
        end
    else
        local total_questions = 0
        for _, group in ipairs(groups) do total_questions = total_questions + #group.questions end
        table.insert(content, Widgets.label(string.format("共 %d 组 · %d 道变种题", #groups, total_questions), {
            size = 17, color = Blitbuffer.COLOR_DARK_GRAY,
        }))
        table.insert(content, Widgets.vspace(Size.span.vertical_default))
        for _, group in ipairs(groups) do
            local origin = (group.origins or {})[1] or {}
            local date = group.created_at and group.created_at > 0 and os.date("%m-%d", group.created_at) or "--"
            table.insert(content, Widgets.button(string.format("[%s] %s · %d题 · %s", SUBJECT_LABEL[origin.subject] or "题", truncate(origin.stem, 18), #group.questions, date), {
                width = cw,
                height = Screen:scaleBySize(50),
                size = 17,
                align = "left",
                callback = function() self:render_ai_preview(group.id) end,
            }))
            table.insert(content, Widgets.vspace(Size.span.vertical_default))
        end
    end
    if #groups > 0 and not origin_id then
        table.insert(content, Widgets.button("清空 AI 题库", {
            width = cw,
            height = Screen:scaleBySize(50),
            size = 18,
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = "确定清空全部 AI 变种题吗？这不会删除错题本。",
                    ok_text = "清空",
                    cancel_text = "取消",
                    ok_callback = function()
                        bank:clear()
                        self:render_ai_bank(nil, self.ai_bank_back)
                    end,
                })
            end,
        }))
        table.insert(content, Widgets.vspace(Size.span.vertical_default))
    end
    table.insert(content, Widgets.button("返回", {
        width = cw,
        size = 20,
        callback = self.ai_bank_back,
    }))
    local scroll = ScrollableContainer:new{
        dimen = self:scroll_viewport(),
        show_parent = self,
        content,
    }
    self:set_body(scroll)
end

function MainView:render_ai_preview(group_id)
    local group = self:get_ai_bank():get_group(group_id)
    if not group then
        self:render_ai_bank(self.ai_bank_filter, self.ai_bank_back)
        return
    end
    self.state = "ai_preview"
    self.ai_preview_group_id = group.id
    self:set_title("家长预览")
    local cw = Widgets.width()
    local content = VerticalGroup:new{ align = "center" }
    table.insert(content, Widgets.textbox("AI 生成内容可能有误，请家长检查后再让孩子练习。", cw, {
        size = 16, alignment = "center", bold = true,
    }))
    table.insert(content, Widgets.vspace(Size.span.vertical_default))
    local provider = group.provider or {}
    local provider_text = type(provider.name) == "string" and provider.name or "AI"
    if type(provider.model) == "string" and provider.model ~= "" then
        provider_text = provider_text .. " · " .. provider.model
    end
    local created_text = (group.created_at and group.created_at > 0) and os.date("%Y-%m-%d", group.created_at) or "未知日期"
    table.insert(content, Widgets.label(string.format("%s · %s", provider_text, created_text), {
        size = 14, color = Blitbuffer.COLOR_DARK_GRAY,
    }))
    table.insert(content, Widgets.vspace(Size.span.vertical_large))

    local origin_by_id = {}
    for _, origin in ipairs(group.origins or {}) do origin_by_id[origin.id] = origin end
    for index, question in ipairs(group.questions) do
        local origin = origin_by_id[question.origin_id] or {}
        local parts = {
            align = "left",
            Widgets.label(string.format("变种 %d · 来自：%s", index, truncate(origin.stem or "", 20)), {
                size = 15, color = Blitbuffer.COLOR_DARK_GRAY,
            }),
            Widgets.vspace(Size.span.vertical_default),
        }
        if question.passage and question.passage ~= "" then
            table.insert(parts, Widgets.textbox(question.passage, cw - 4 * Size.padding.default, { size = 16 }))
            table.insert(parts, Widgets.vspace(Size.span.vertical_default))
        end
        table.insert(parts, Widgets.textbox(question.stem, cw - 4 * Size.padding.default, { size = 20 }))
        table.insert(parts, Widgets.vspace(Size.span.vertical_default))
        local prefixes = { "A. ", "B. ", "C. ", "D. " }
        for option_index, option in ipairs(question.options or {}) do
            local mark = option_index == question.answer and "✓ " or "　 "
            table.insert(parts, Widgets.textbox(mark .. prefixes[option_index] .. option, cw - 4 * Size.padding.default, { size = 17 }))
        end
        table.insert(parts, Widgets.vspace(Size.span.vertical_default))
        table.insert(parts, Widgets.label("答案：" .. answer_text(question), { size = 17, bold = true }))
        table.insert(parts, Widgets.vspace(Size.span.vertical_default))
        table.insert(parts, Widgets.textbox(question.explain or "", cw - 4 * Size.padding.default, { size = 15, color = Blitbuffer.COLOR_DARK_GRAY }))
        table.insert(content, Widgets.card(VerticalGroup:new(parts), { width = cw, padding = Size.padding.large }))
        table.insert(content, Widgets.vspace(Size.span.vertical_large))
    end

    local scroll = ScrollableContainer:new{
        dimen = self:scroll_viewport(self:scroll_viewport().h - Screen:scaleBySize(130)),
        show_parent = self,
        content,
    }
    local body = VerticalGroup:new{
        align = "center",
        scroll,
        Widgets.vspace(Size.span.vertical_default),
        Widgets.button(string.format("开始练习（%d 题）", #group.questions), {
            width = cw,
            height = Screen:scaleBySize(58),
            size = 21,
            callback = function()
                self:start_session({ mode = "ai", ai_questions = group.questions, ai_group_id = group.id })
            end,
        }),
        Widgets.vspace(Size.span.vertical_default),
        Widgets.button("删除这组", {
            width = cw,
            height = Screen:scaleBySize(48),
            size = 18,
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = "确定删除这组 AI 变种题吗？",
                    ok_text = "删除",
                    cancel_text = "取消",
                    ok_callback = function()
                        self:get_ai_bank():remove_group(group.id)
                        self:render_ai_bank(self.ai_bank_filter, self.ai_bank_back)
                    end,
                })
            end,
        }),
        Widgets.vspace(Size.span.vertical_default),
        Widgets.button("返回 AI 题库", {
            width = cw,
            size = 20,
            callback = function() self:render_ai_bank(self.ai_bank_filter, self.ai_bank_back) end,
        }),
    }
    self:set_body(body)
end

function MainView:render_badges(page)
    self.state = "badges"
    self:set_title("奖章墙")
    local cw = Widgets.width()
    local gap = Size.span.horizontal_default
    local card_width = math.floor((cw - gap) / 2)
    local half = math.floor((cw - gap) / 2)
    local all = Badges.state(self.progress)
    local per_page = 10
    local total_pages = math.max(1, math.ceil(#all / per_page))
    page = tonumber(page) or self.badge_page or 1
    if page < 1 then page = 1 elseif page > total_pages then page = total_pages end
    self.badge_page = page
    local content = VerticalGroup:new{ align = "center" }
    table.insert(content, Widgets.label(string.format("第 %d/%d 页 · 已解锁 %d/%d",
        page, total_pages, Badges.count(self.progress), #all), {
        size = 16, color = Blitbuffer.COLOR_DARK_GRAY,
    }))
    table.insert(content, Widgets.vspace(Size.span.vertical_default))
    local first = (page - 1) * per_page + 1
    local last = math.min(first + per_page - 1, #all)
    local row
    for i = first, last do
        local badge = all[i]
        local symbol = badge.unlocked and "★" or "☆"
        local progress_text = badge.unlocked and "已获得" or string.format("%d/%d", badge.value, badge.target)
        local card = Widgets.card(VerticalGroup:new{
            align = "center",
            Widgets.label(symbol, { size = 26, bold = true }),
            Widgets.label(badge.name, { size = 18, bold = true }),
            Widgets.textbox(badge.desc, card_width - 4 * Size.padding.default, { size = 14, alignment = "center" }),
            Widgets.label(progress_text, { size = 14, color = Blitbuffer.COLOR_DARK_GRAY }),
        }, { width = card_width, padding = Size.padding.default })
        if (i - first) % 2 == 0 then
            row = HorizontalGroup:new{ align = "center", card }
            table.insert(content, row)
            table.insert(content, Widgets.vspace(gap))
        else
            table.insert(row, Widgets.hspace(gap))
            table.insert(row, card)
        end
    end
    local nav = HorizontalGroup:new{ align = "center" }
    if page > 1 then
        table.insert(nav, Widgets.button("上一页", {
            width = half, size = 20,
            callback = function() self:render_badges(page - 1) end,
        }))
    else
        table.insert(nav, Widgets.hspace(half))
    end
    table.insert(nav, Widgets.hspace(gap))
    if page < total_pages then
        table.insert(nav, Widgets.button("下一页", {
            width = half, size = 20,
            callback = function() self:render_badges(page + 1) end,
        }))
    else
        table.insert(nav, Widgets.hspace(half))
    end
    table.insert(content, nav)
    table.insert(content, Widgets.vspace(Size.span.vertical_default))
    table.insert(content, Widgets.button("回首页", {
        width = cw,
        size = 20,
        callback = function() self:render_home() end,
    }))
    local scroll = ScrollableContainer:new{
        dimen = self:scroll_viewport(),
        show_parent = self,
        content,
    }
    self:set_body(scroll)
end

-- ---------------------------------------------------------------------------
-- Daily report, card draw and card collection
-- ---------------------------------------------------------------------------

function MainView:report_parts_text(report)
    local parts = report.parts or {}
    return string.format("目标 %d/40 · 正确率 %d/30 · 轮次 %d/15 · 挑战 %d/10 · 知识点 %d/5 · 连续 %d/10",
        parts.goal or 0, parts.accuracy or 0, parts.sessions or 0,
        parts.challenge or 0, parts.kp or 0, parts.streak or 0)
end

-- 今日总结：第一次看时按当天数据生成一份，之后每次打开都是同一份（不再消耗任何额度）
function MainView:open_daily_report(now)
    now = now or os.time()
    local report = self.progress:daily_report(now)
    if not report then
        report = Report.create(self.progress, { now = now, plugin_path = self.plugin_path })
        local new_badges = Badges.evaluate(self.progress)
        if #new_badges > 0 then
            local names = {}
            for _, badge in ipairs(new_badges) do table.insert(names, badge.name) end
            UIManager:show(InfoMessage:new{ text = "新奖章：" .. table.concat(names, "、"), timeout = 4 })
        end
    end
    self:render_daily_report()
    if report and not report.ai and self:ai_ready() then
        self:polish_daily_report()
    end
end

function MainView:render_daily_report()
    self.state = "daily_report"
    self:set_title("每日总结")
    local cw = Widgets.width()
    local report = self.progress:daily_report()
    if not report then
        self:render_home()
        return
    end
    local content = VerticalGroup:new{ align = "center" }
    table.insert(content, Widgets.card(VerticalGroup:new{
        align = "center",
        Widgets.label(os.date("%Y年%m月%d日", report.created_at or os.time()), {
            size = 16, color = Blitbuffer.COLOR_DARK_GRAY,
        }),
        Widgets.vspace(Size.span.vertical_default),
        Widgets.label(string.format("%d 分", report.score or 0), { size = 40, bold = true }),
        Widgets.label(Report.grade_label(report.score), { size = 22, bold = true }),
        Widgets.vspace(Size.span.vertical_default),
        Widgets.textbox(self:report_parts_text(report), cw - 4 * Size.padding.default, {
            size = 14, alignment = "center",
        }),
    }, { width = cw, padding = Size.padding.large }))
    table.insert(content, Widgets.vspace(Size.span.vertical_default))
    local stats = Report.stats(self.progress, nil, self.plugin_path)
    table.insert(content, Widgets.textbox(string.format("答题 %d · 答对 %d · 星星 %d · 轮次 %d",
        stats.answered, stats.correct, stats.points, stats.sessions), cw, { size = 16, alignment = "center" }))
    local total = self.progress.data.total
    table.insert(content, Widgets.vspace(Size.span.vertical_default))
    table.insert(content, Widgets.label(string.format("累计答题 %d 道 · 拓展题 %d 道 · 可用星星 ★%d",
        total.answered, total.challenge_answered, Shop.balance(self.progress)), {
        size = 14, color = Blitbuffer.COLOR_DARK_GRAY,
    }))
    table.insert(content, Widgets.vspace(Size.span.vertical_default))
    table.insert(content, Widgets.label(report.ai and "AI 总结" or "离线总结", {
        size = 15, color = Blitbuffer.COLOR_DARK_GRAY,
    }))
    table.insert(content, Widgets.textbox(report.summary or "", cw, { size = 18 }))
    table.insert(content, Widgets.vspace(Size.span.vertical_default))
    if not report.ai and self:ai_ready() then
        table.insert(content, Widgets.button("AI 润色总结", {
            width = cw, size = 20,
            callback = function() self:polish_daily_report() end,
        }))
        table.insert(content, Widgets.vspace(Size.span.vertical_default))
    end
    table.insert(content, Widgets.button("去星星商城", {
        width = cw, size = 20,
        callback = function() self:render_shop() end,
    }))
    table.insert(content, Widgets.vspace(Size.span.vertical_default))
    table.insert(content, Widgets.button("回首页", {
        width = cw, size = 20,
        callback = function() self:render_home() end,
    }))
    local scroll = ScrollableContainer:new{
        dimen = self:scroll_viewport(),
        show_parent = self,
        content,
    }
    self:set_body(scroll)
end

function MainView:show_report_ai_error(message)
    UIManager:show(ConfirmBox:new{
        text = "AI 总结失败：" .. tostring(message) .. "\n\n离线总结不受影响。",
        ok_text = "重试",
        cancel_text = "看离线版",
        ok_callback = function() self:polish_daily_report() end,
    })
end

function MainView:polish_daily_report()
    if self.ai_polishing then
        UIManager:show(InfoMessage:new{ text = "AI 正在写上一份总结，请稍候。", timeout = 3 })
        return
    end
    local report = self.progress:daily_report()
    if not report then return end
    local profile, err = self:ai_ready()
    if not profile then
        UIManager:show(InfoMessage:new{
            text = "AI 还没配置好：" .. tostring(err) .. "\n\n可以先看离线总结，或到设置里配置 AI 服务。",
            timeout = 5,
        })
        return
    end
    local stats = Report.stats(self.progress, nil, self.plugin_path)
    local system, user = Report.build_prompt(stats, report.score)
    NetworkMgr:runWhenOnline(function()
        if self.ai_polishing then return end
        self.ai_polishing = true
        local loading = InfoMessage:new{
            text = "AI 正在写今日总结，请稍候…\n通常需要 10–60 秒，请不要退出。",
        }
        UIManager:show(loading)
        UIManager:forceRePaint()
        local function finish(text, request_err)
            UIManager:close(loading)
            self.ai_polishing = false
            if self.closed then return end
            if request_err then
                self:show_report_ai_error(request_err)
                return
            end
            local parsed, parse_err = Report.parse(text)
            if not parsed then
                self:show_report_ai_error(parse_err)
                return
            end
            report.summary = parsed.summary
            report.ai = true
            self.progress:save_daily_report(report)
            if self.state == "daily_report" then
                self:render_daily_report()
            end
        end
        AIClient.generate(profile, system, user, {
            transport = self.ai_transport,
            callback = finish,
        })
    end)
end

--[[--
星星商城：家长在设置里准备的愿望卡券，孩子用答题赚来的星星兑换。换到的卡券进
钱包，兑现要给家长看，并输入密码，孩子没法自己把奖励「花掉」。
--]]--
function MainView:render_shop()
    self.state = "shop"
    self:set_title("星星商城")
    local cw = Widgets.width()
    local balance = Shop.balance(self.progress)
    local items = Shop.items(self.progress)
    local content = VerticalGroup:new{ align = "center" }

    table.insert(content, Widgets.card(VerticalGroup:new{
        align = "center",
        Widgets.label(string.format("★ %d", balance), { size = 40, bold = true }),
        Widgets.label("可用星星", { size = 16, color = Blitbuffer.COLOR_DARK_GRAY }),
        Widgets.vspace(Size.span.vertical_default),
        Widgets.textbox("答对题目就能赚星星，攒够了换一张卡券；换到的卡券放在钱包里，找家长兑现。",
            cw - 4 * Size.padding.default, {
                size = 15, alignment = "center", color = Blitbuffer.COLOR_DARK_GRAY,
            }),
    }, { width = cw, padding = Size.padding.large }))
    table.insert(content, Widgets.vspace(Size.span.vertical_large))

    if #items == 0 then
        table.insert(content, Widgets.textbox(
            "商城还空着。\n家长可以在「设置 → 商城后台」里把愿望做成卡券（需要密码）。", cw, {
                size = 18, alignment = "center",
            }))
        table.insert(content, Widgets.vspace(Size.span.vertical_default))
    else
        table.insert(content, Widgets.label(string.format("在售卡券（%d）", #items), {
            size = 17, color = Blitbuffer.COLOR_DARK_GRAY,
        }))
        table.insert(content, Widgets.vspace(Size.span.vertical_default))
        -- 一行三张卡：宽度均分整行，高度固定成正方形，行与行始终整齐；
        -- 名字过长时卡内自动换行（最多两行）。
        local gap = Size.span.horizontal_default
        local pad = Size.padding.default
        local cols = 3
        local colw = math.floor((cw - (cols - 1) * gap) / cols)
        local cardh = colw
        local inner = colw - 2 * (pad + Size.border.thin)
        local function coupon_card(item)
            local affordable = balance >= item.cost
            local body = VerticalGroup:new{
                align = "center",
                Widgets.textbox(item.name, inner, {
                    size = 15, alignment = "center", line_height = 0.2, max_lines = 2,
                }),
                Widgets.vspace(Size.span.vertical_small or Size.span.vertical_default),
                Widgets.label(string.format("★ %d", item.cost), {
                    size = 17, bold = true,
                    color = affordable and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY,
                }),
                Widgets.vspace(Size.span.vertical_small or Size.span.vertical_default),
                Widgets.button(affordable and "兑换"
                        or string.format("差 %d 星", item.cost - balance), {
                    width = inner,
                    size = 15,
                    callback = function() self:redeem_shop_item(item.id) end,
                }),
            }
            return Widgets.card(body, { width = colw, height = cardh, padding = pad })
        end
        local idx = 1
        while idx <= #items do
            local row = HorizontalGroup:new{ align = "top" }
            for i = idx, math.min(idx + cols - 1, #items) do
                if i > idx then table.insert(row, Widgets.hspace(gap)) end
                table.insert(row, coupon_card(items[i]))
            end
            table.insert(content, row)
            table.insert(content, Widgets.vspace(Size.span.vertical_default))
            idx = idx + cols
        end
    end

    table.insert(content, Widgets.vspace(Size.span.vertical_default))
    table.insert(content, Widgets.button("我的钱包", {
        width = cw,
        size = 20,
        callback = function() self:render_wallet() end,
    }))
    table.insert(content, Widgets.vspace(Size.span.vertical_default))
    table.insert(content, Widgets.button("返回首页", {
        width = cw,
        size = 20,
        callback = function() self:render_home() end,
    }))
    self:set_body(ScrollableContainer:new{
        dimen = self:scroll_viewport(),
        show_parent = self,
        content,
    })
end

-- 兑换要二次确认：先说清楚花多少、还剩多少，避免孩子连点把星星一次花光。
function MainView:redeem_shop_item(item_id)
    local item = Shop.find(self.progress, item_id)
    if not item or not item.enabled then
        UIManager:show(InfoMessage:new{ text = "这张卡券已经下架或删除。", timeout = 3 })
        self:render_shop()
        return
    end
    local balance = Shop.balance(self.progress)
    if balance < item.cost then
        UIManager:show(InfoMessage:new{
            text = string.format("还差 %d 颗星星", item.cost - balance), timeout = 3,
        })
        self:render_shop()
        return
    end
    UIManager:show(ConfirmBox:new{
        text = string.format("确定兑换「%s」吗？\n\n要花 ★%d，换完还剩 ★%d。\n卡券会放进钱包，找家长兑现时要输密码。",
            item.name, item.cost, balance - item.cost),
        ok_text = "确认兑换",
        cancel_text = "再想想",
        ok_callback = function() self:do_redeem_shop_item(item_id) end,
    })
end

function MainView:do_redeem_shop_item(item_id)
    local record, err = Shop.redeem(self.progress, item_id)
    if not record then
        UIManager:show(InfoMessage:new{ text = tostring(err), timeout = 3 })
        self:render_shop()
        return
    end
    self:render_shop()
    UIManager:show(ConfirmBox:new{
        text = string.format("兑换成功！\n\n「%s」已放进钱包，花掉 ★%d。\n找家长兑现时，家长要输入密码。",
            record.name, record.cost),
        ok_text = "去钱包看看",
        cancel_text = "继续逛",
        ok_callback = function() self:render_wallet() end,
    })
end

--[[--
钱包：星星余额 + 已兑换的卡券。待兑现的卡券要点「找家长兑现」，输入 4 位密码
才算用掉；没有设置密码时不让兑现，先引导家长去设置。
--]]--
function MainView:render_wallet()
    self.state = "wallet"
    self:set_title("钱包")
    local cw = Widgets.width()
    local balance = Shop.balance(self.progress)
    local spent = Shop.spent(self.progress)
    local earned = self.progress.data.total.points or 0
    local records = Shop.redeemed(self.progress)
    local pending = Shop.pending_count(self.progress)
    local content = VerticalGroup:new{ align = "center" }

    table.insert(content, Widgets.card(VerticalGroup:new{
        align = "center",
        Widgets.label(string.format("★ %d", balance), { size = 40, bold = true }),
        Widgets.label("可用星星", { size = 16, color = Blitbuffer.COLOR_DARK_GRAY }),
        Widgets.vspace(Size.span.vertical_default),
        Widgets.label(string.format("累计获得 ★%d · 已兑换花掉 ★%d", earned, spent), {
            size = 15, color = Blitbuffer.COLOR_DARK_GRAY,
        }),
    }, { width = cw, padding = Size.padding.large }))
    table.insert(content, Widgets.vspace(Size.span.vertical_large))

    if #records == 0 then
        table.insert(content, Widgets.textbox("钱包里还没有卡券。\n去星星商城用星星换一张愿望卡券吧。", cw, {
            size = 18, alignment = "center",
        }))
        table.insert(content, Widgets.vspace(Size.span.vertical_default))
    else
        local title = string.format("我的卡券（%d 张", #records)
        if pending > 0 then title = title .. string.format("，%d 张待兑现", pending) end
        title = title .. "）"
        table.insert(content, Widgets.label(title, { size = 17, color = Blitbuffer.COLOR_DARK_GRAY }))
        table.insert(content, Widgets.vspace(Size.span.vertical_default))

        local right_w = math.min(Screen:scaleBySize(140), math.floor(cw * 0.34))
        local left_w = cw - right_w - Size.span.horizontal_default - 2 * Size.padding.default
        for _, record in ipairs(records) do
            local info = VerticalGroup:new{
                align = "left",
                Widgets.label(record.name, { size = 19, bold = true, max_width = left_w }),
                Widgets.label(string.format("★ %d · %s", record.cost,
                    os.date("%m月%d日", record.at or os.time())), {
                    size = 14, color = Blitbuffer.COLOR_DARK_GRAY,
                }),
            }
            local right
            if record.cashed then
                right = Widgets.textbox(string.format("已兑现\n%s", os.date("%m月%d日",
                    record.cashed_at or record.at or os.time())), right_w, {
                    size = 14, color = Blitbuffer.COLOR_DARK_GRAY, alignment = "center",
                })
            else
                right = Widgets.button("找家长兑现", {
                    width = right_w,
                    size = 17,
                    callback = function() self:cash_coupon(record.id) end,
                })
            end
            table.insert(content, Widgets.card(HorizontalGroup:new{
                align = "center",
                info,
                Widgets.hspace(Size.span.horizontal_default),
                right,
            }, { width = cw, padding = Size.padding.default }))
            table.insert(content, Widgets.vspace(Size.span.vertical_default))
        end

        table.insert(content, Widgets.label("兑现就是家长把这份奖励真的给孩子：点「找家长兑现」，由家长输入密码。", {
            size = 14, color = Blitbuffer.COLOR_DARK_GRAY, max_width = cw, alignment = "center",
        }))
        table.insert(content, Widgets.vspace(Size.span.vertical_default))
    end

    table.insert(content, Widgets.button("看今日总结", {
        width = cw,
        size = 20,
        callback = function() self:open_daily_report() end,
    }))
    table.insert(content, Widgets.vspace(Size.span.vertical_default))
    table.insert(content, Widgets.button("去星星商城", {
        width = cw,
        size = 20,
        callback = function() self:render_shop() end,
    }))
    table.insert(content, Widgets.vspace(Size.span.vertical_default))
    table.insert(content, Widgets.button("返回首页", {
        width = cw,
        size = 20,
        callback = function() self:render_home() end,
    }))
    self:set_body(ScrollableContainer:new{
        dimen = self:scroll_viewport(),
        show_parent = self,
        content,
    })
end

function MainView:cash_coupon(record_id)
    local record = Shop.find_record(self.progress, record_id)
    if not record then
        UIManager:show(InfoMessage:new{ text = "找不到这张卡券。", timeout = 3 })
        self:render_wallet()
        return
    end
    if record.cashed then
        UIManager:show(InfoMessage:new{ text = "这张卡券已经兑现过了。", timeout = 3 })
        return
    end
    local pin = self.progress.data.settings.parent_pin
    if not pin or #tostring(pin) ~= 4 then
        UIManager:show(ConfirmBox:new{
            text = "兑现卡券需要家长密码。\n\n现在还没有设置家长密码，先去设置一个吧——这样孩子就不能自己点兑现了。",
            ok_text = "去设置家长密码",
            cancel_text = "稍后",
            ok_callback = function()
                self:render_pin_settings("parent", function() self:render_wallet() end)
            end,
        })
        return
    end
    self:ask_pin_input(string.format("兑现「%s」· 请输入家长密码", record.name), function(text)
        if text == nil then return end
        if tostring(text) ~= tostring(pin) then
            UIManager:show(InfoMessage:new{ text = "密码不对，未兑现。", timeout = 3 })
            return
        end
        local done, err = Shop.cash(self.progress, record_id)
        if not done then
            UIManager:show(InfoMessage:new{ text = tostring(err), timeout = 3 })
            return
        end
        UIManager:show(InfoMessage:new{
            text = string.format("「%s」已兑现 ✓\n记得把这份奖励给孩子。", done.name),
            timeout = 4,
        })
        self:render_wallet()
    end)
end

function MainView:cycle_goal()
    local goal = self.progress.data.settings.daily_goal
    local values = { 5, 10, 15, 20 }
    for i, value in ipairs(values) do
        if goal == value then
            goal = values[(i % #values) + 1]
            break
        end
    end
    self.progress.data.settings.daily_goal = goal
    self.progress:flush()
end

function MainView:render_choice_list(title, items, on_select, back)
    self.state = "choice_list"
    self.choice_list_back = back or function() self:return_to_settings() end
    self:set_title(title)
    local cw = Widgets.width()
    local content = VerticalGroup:new{ align = "center" }
    for _, item in ipairs(items) do
        local label = item.name
        if item.selected then label = "✓ " .. label end
        local captured = item
        table.insert(content, Widgets.button(label, {
            width = cw,
            height = Screen:scaleBySize(50),
            align = "left",
            callback = function() on_select(captured) end,
        }))
        table.insert(content, Widgets.vspace(Size.span.vertical_default))
    end
    local scroll = ScrollableContainer:new{
        dimen = self:scroll_viewport(self:scroll_viewport().h - Screen:scaleBySize(60)),
        show_parent = self,
        content,
    }
    local body = VerticalGroup:new{
        align = "center",
        scroll,
        Widgets.vspace(Size.span.vertical_default),
        Widgets.button("返回", {
            width = cw,
            height = Screen:scaleBySize(48),
            size = 20,
            callback = self.choice_list_back,
        }),
    }
    self:set_body(body)
end

function MainView:render_province_select()
    local settings = self.progress.data.settings
    local items = {}
    for _, province in ipairs(Catalog.provinces(self.plugin_path)) do
        table.insert(items, {
            id = province.id,
            name = province.name,
            selected = settings.province == province.id,
        })
    end
    self:render_choice_list("选择省份", items, function(item)
        settings.province = item.id
        settings.city = nil
        settings.math_edition = Catalog.recommended_math(self.plugin_path, item.id)
        self.progress:flush()
        local count = #Catalog.cities(self.plugin_path, item.id)
        if count == 1 then
            -- 直辖市：唯一城市自动同步选中，并按城市匹配教材版本，避免再选城市（静默处理，不弹提醒）
            local only = Catalog.cities(self.plugin_path, item.id)[1]
            settings.city = only.id
            self.progress:flush()
            self:apply_city_match(only.name, false, true)
            return
        end
        UIManager:show(InfoMessage:new{
            text = string.format("已选择%s（%d 个城市可选）。接着选城市和年级，会自动匹配语文/数学/英语教材版本。",
                item.name, count),
            timeout = 4,
        })
        self:return_to_settings()
    end)
end

function MainView:render_city_select()
    local settings = self.progress.data.settings
    local cities = Catalog.cities(self.plugin_path, settings.province)
    if #cities == 0 then
        UIManager:show(InfoMessage:new{
            text = "请先在学习设置里选择省份。", timeout = 3,
        })
        self:return_to_settings()
        return
    end
    local items = {
        { id = "", name = "不指定（按省份推荐）", selected = not settings.city },
    }
    for _, city in ipairs(cities) do
        table.insert(items, {
            id = city.id,
            name = city.name,
            selected = settings.city == city.id,
        })
    end
    self:render_choice_list("选择城市（" .. #cities .. "）", items, function(item)
        if item.id == "" then
            settings.city = nil
            self.progress:flush()
            self:return_to_settings()
            return
        end
        settings.city = item.id
        self:apply_city_match(item.name, true)
    end)
end

-- 所选版本缺本年级题库时的提示后缀（练习会自动回退到有数据的版本）。
function MainView:coverage_hint(subject, edition)
    local settings = self.progress.data.settings
    if Catalog.edition_covers(self.plugin_path, subject, edition, settings.grade) then
        return ""
    end
    return "（暂无本年级题库，练习自动回退）"
end

-- 按「省份 + 城市 + 年级」匹配语文/数学/英语版本：命中就写入，多版本时列出候选，
-- 插件未收录的版本给出提示但保留原设置。
-- @param city_name 提示用的城市名
-- @param from_city 是否由「选城市」触发（触发时额外提示其他学科差异）
-- @param silent 为 true 时不弹提示，只静默重算（切学期时用）
function MainView:apply_city_match(city_name, from_city, silent)
    local settings = self.progress.data.settings
    local match = self:city_match()
    if not match then return end
    local grade_label = self:grade_label() .. self:semester_label()
    local applied, missing, absent = {}, {}, {}

    for _, key in ipairs({ "yuwen", "shuxue", "yingyu" }) do
        local subject = CITY_SUBJECTS[key]
        local item = match[key]
        if not item then
            table.insert(absent, self:subject_label(subject))
        elseif item.edition and item.edition ~= "" then
            local editions = item.editions or { item.edition }
            if #editions > 1 then
                -- 该年级有多个版本：当前选择命中就保留，否则取第一个
                local current = settings_edition(settings, subject)
                local keep = nil
                for _, id in ipairs(editions) do
                    if id == current then keep = id end
                end
                settings[subject .. "_edition"] = keep or item.edition or editions[1]
                local chosen = settings[subject .. "_edition"]
                table.insert(applied, string.format("%s %s%s%s（可选 %d 个版本）", self:subject_label(subject),
                    self:edition_name_of(subject, chosen), self:edition_term_suffix(subject, chosen),
                    self:coverage_hint(subject, chosen), #editions))
            else
                settings[subject .. "_edition"] = item.edition
                table.insert(applied, string.format("%s %s%s%s", self:subject_label(subject),
                    self:edition_name_of(subject, item.edition), self:edition_term_suffix(subject, item.edition),
                    self:coverage_hint(subject, item.edition)))
            end
        else
            table.insert(missing, string.format("%s（%s）", self:subject_label(subject), item.publisher or ""))
        end
    end

    -- 物理等 o 字段学科：出版社名 → 版本 id，按年级下限自动设置
    local grade = tonumber(settings.grade) or 0
    local other_applied = {}
    if match.other and next(match.other) then
        for okey, publisher in pairs(match.other) do
            local idmap = OTHER_EDITION_ID[okey]
            local min_grade = OTHER_MIN_GRADE[okey]
            if idmap and publisher and (not min_grade or grade >= min_grade) then
                local eid = idmap[publisher]
                local subject = okey == "wuli" and "physics" or nil
                -- 只在该版本确实收录当前年级时才应用（如粤教版仅高中，初中不选用）
                if eid and subject
                    and Catalog.edition_covers(self.plugin_path, subject, eid, grade) then
                    settings[subject .. "_edition"] = eid
                    other_applied[okey] = true
                    table.insert(applied, string.format("%s %s", self:subject_label(subject),
                        self:edition_name_of(subject, eid)))
                end
            end
        end
    end

    self.progress:flush()
    local lines = {}
    if #applied > 0 then
        table.insert(lines, string.format("已按%s%s匹配：%s", city_name or "", grade_label,
            table.concat(applied, " · ")))
    end
    if #missing > 0 then
        table.insert(lines, "未收录：" .. table.concat(missing, "、") .. " —— 插件暂无该版本，练习沿用当前设置")
    end
    if #absent > 0 then
        table.insert(lines, "无书目：" .. table.concat(absent, "、") .. "（源站该年级无数据，保持原设置）")
    end
    if from_city and match.other and next(match.other) then
        local other = {}
        local other_label = { wuli = "物理", huaxue = "化学", shengwu = "生物",
                              lishi = "历史", dili = "地理" }
        for key, publisher in pairs(match.other) do
            if not other_applied[key] then
                table.insert(other, (other_label[key] or key) .. publisher)
            end
        end
        table.sort(other)
        table.insert(lines, "其他学科：" .. table.concat(other, "、"))
    end
    if #lines == 0 then
        table.insert(lines, "该城市该年级暂无教材数据。")
    end
    if not silent then
        UIManager:show(InfoMessage:new{ text = table.concat(lines, "\n"), timeout = 6 })
    end
    self:return_to_settings()
end

function MainView:render_grade_select()
    local settings = self.progress.data.settings
    local items = {}
    for _, grade in ipairs(Catalog.grades(self.plugin_path)) do
        table.insert(items, {
            id = grade,
            name = GRADE_LABEL[grade] or (grade .. "年级"),
            selected = tonumber(settings.grade) == grade,
        })
    end
    self:render_choice_list("选择年级", items, function(item)
        local changed = tonumber(settings.grade) ~= tonumber(item.id)
        settings.grade = item.id
        self.progress:flush()
        -- 已选城市时，年级变了就重新按城市对应版本
        if changed and settings.city then
            local city = Catalog.city(self.plugin_path, settings.province, settings.city)
            self:apply_city_match(city and city.name or nil, false)
        else
            self:return_to_settings()
        end
    end)
end

function MainView:render_edition_select(subject)
    local settings = self.progress.data.settings
    local current = settings_edition(settings, subject)
    local match = self:city_match()
    local rec_key = nil
    for key, plugin_subject in pairs(CITY_SUBJECTS) do
        if plugin_subject == subject then rec_key = key end
    end
    local rec = self:recommended_edition(subject)
    local rec_pub = nil
    if rec_key and match and match[rec_key] then rec_pub = match[rec_key].publisher end
    local items = {}
    if rec then
        table.insert(items, {
            id = rec,
            name = string.format("%s%s｜%s%s使用", self:edition_name_of(subject, rec),
                self:edition_term_suffix(subject, rec),
                self:city_label(), self:grade_label() .. self:semester_label()),
            selected = current == rec,
        })
    end
    -- 同一出版社有新老两套时，按这一册的版次只列适用的那个
    for _, edition in ipairs(Catalog.editions_for_term(self.plugin_path, subject,
            settings.grade, settings.semester)) do
        if edition.id ~= rec then
            table.insert(items, {
                id = edition.id,
                name = edition.name .. self:edition_term_suffix(subject, edition.id),
                selected = current == edition.id,
            })
        end
    end
    if rec_pub and not rec then
        UIManager:show(InfoMessage:new{
            text = string.format("%s%s使用%s，插件暂未收录该版本，下列版本仅供手动选择。",
                self:city_label(), self:grade_label(), rec_pub),
            timeout = 5,
        })
    end
    self:render_choice_list(self:subject_label(subject) .. "教材", items, function(item)
        settings[subject .. "_edition"] = item.id
        self.progress:flush()
        self:return_to_settings()
    end)
end

-- ---------------------------------------------------------------------------
-- Online update (opt-in, user-triggered; user data lives outside the plugin dir).
-- ---------------------------------------------------------------------------

function MainView:check_update()
    if self.update_busy then
        UIManager:show(InfoMessage:new{ text = "正在处理上一个更新请求，请稍候。", timeout = 3 })
        return
    end
    NetworkMgr:runWhenOnline(function()
        if self.closed then return end
        self.update_busy = true
        local loading = InfoMessage:new{ text = "正在检查更新…" }
        UIManager:show(loading)
        UIManager:forceRePaint()
        local settings = self.progress.data.settings
        Update.check({
            api_url = settings.update_api_url,
            local_version = Update.local_version(self.plugin_path),
        }, function(result)
            UIManager:close(loading)
            self.update_busy = false
            if self.closed then return end
            if result.error then
                UIManager:show(InfoMessage:new{ text = "检查更新失败：" .. tostring(result.error), timeout = 6 })
                return
            end
            if not result.available then
                UIManager:show(InfoMessage:new{ text = string.format("已是最新版本 v%s。", result.current), timeout = 4 })
                return
            end
            self:prompt_install_update(result)
        end)
    end)
end

function MainView:prompt_install_update(release)
    -- Show only the first line of the release notes as a short summary; the
    -- full notes can be very long and ConfirmBox is not scrollable.
    local summary = (release.notes or ""):match("^[^\n]*") or ""
    summary = summary:gsub("^#+%s*", "")
    local text = string.format("发现新版本 %s（当前 v%s）。", release.tag, release.current)
    if summary ~= "" then
        text = text .. "\n\n" .. summary
    end
    text = text .. "\n\n升级只替换插件程序，你的星星、打卡、错题本等学习记录完全不受影响。是否下载并升级？"
    UIManager:show(ConfirmBox:new{
        text = text,
        ok_text = "升级",
        cancel_text = "稍后",
        ok_callback = function() self:install_update(release) end,
    })
end

function MainView:install_update(release)
    if self.update_busy then return end
    NetworkMgr:runWhenOnline(function()
        if self.closed then return end
        self.update_busy = true
        -- Progress dialog with a cancel button. The download runs in short
        -- non-blocking ticks with no timeout: however slow the network is,
        -- the user stays in control and can cancel at any time.
        local dialog = UpdateDialog:new{
            total = release.asset_size or 0,
        }
        UIManager:show(dialog)
        local handle
        handle = Update.download_and_install({
            plugin_path = self.plugin_path,
            asset_url = release.asset_url,
            mirror_asset_url = release.mirror_asset_url,
            expect_version = release.version,
            on_progress = function(received, total)
                dialog:update_progress(received, total)
            end,
            on_install = function()
                dialog:set_installing()
            end,
        }, function(ok, err)
            dialog:dismiss()
            self.update_busy = false
            if self.closed then return end
            if not ok then
                if err == Update.CANCELLED then
                    UIManager:show(InfoMessage:new{ text = "已取消更新。", timeout = 3 })
                    return
                end
                UIManager:show(InfoMessage:new{
                    text = "升级失败：" .. tostring(err) .. "\n\n你的学习记录不受影响。",
                    timeout = 8,
                })
                return
            end
            UIManager:show(ConfirmBox:new{
                text = "升级完成！需要重启 KOReader 才能生效。\n\n你的学习记录完全保留。立即重启？",
                ok_text = "重启",
                cancel_text = "稍后",
                ok_callback = function()
                    self.progress:flush()
                    UIManager:restartKOReader()
                end,
                cancel_callback = function()
                    UIManager:show(InfoMessage:new{ text = "好的，下次启动 KOReader 时生效。", timeout = 4 })
                end,
            })
        end)
        dialog.cancel_callback = function()
            if handle then handle.cancel() end
        end
    end)
end

function MainView:_maybe_auto_check_update()
    if self._update_auto_checked then return end
    self._update_auto_checked = true
    local settings = self.progress.data.settings
    if not settings.update_auto_check then return end
    UIManager:scheduleIn(2, function()
        if self.closed then return end
        -- Auto-check is silent and only runs when already online; never prompt
        -- to enable Wi-Fi on startup.
        if not NetworkMgr:isConnected() then return end
        Update.check({
            api_url = settings.update_api_url,
            local_version = Update.local_version(self.plugin_path),
        }, function(result)
            if self.closed then return end
            if result.error or not result.available then return end
            self:prompt_install_update(result)
        end)
    end)
end

--[[--
家长端：维护星星商城的商品。预置了 8 张常见愿望卡券，点一下可以上架/下架，也可以
删掉换成自己家的愿望。Kindle 没有中文输入法时，名称可以打拼音或英文。
--]]--
--[[--
商城后台是家长区：先验密码再进。没设密码时引导去设置，避免孩子自己定价。
--]]--
function MainView:open_shop_settings_gated()
    local pin = self.progress.data.settings.parent_pin
    if not pin or #tostring(pin) ~= 4 then
        UIManager:show(ConfirmBox:new{
            text = "「商城后台」是家长设置区，需要家长密码才能进入。\n\n现在还没有设置家长密码，先去设置一个吧。",
            ok_text = "去设置家长密码",
            cancel_text = "稍后",
            ok_callback = function()
                self:render_pin_settings("parent", function() self:render_shop_settings() end)
            end,
        })
        return
    end
    self:ask_pin_input("商城后台 · 请输入家长密码", function(text)
        if text == nil then return end
        if tostring(text) ~= tostring(pin) then
            UIManager:show(InfoMessage:new{ text = "密码不对，未进入。", timeout = 3 })
            return
        end
        self:render_shop_settings()
    end)
end

function MainView:render_shop_settings()
    self.state = "shop_settings"
    self:set_title("商城后台")
    local cw = Widgets.width()
    local items = Shop.all_items(self.progress)
    local on_sale = 0
    for _, item in ipairs(items) do
        if item.enabled then on_sale = on_sale + 1 end
    end
    local content = VerticalGroup:new{
        align = "center",
        Widgets.textbox(string.format(
            "这些卡券会出现在孩子的星星商城里，用星星兑换。现在有 %d 件在售。\n点卡券上的名字可以改星星数（1~9999 随便定）；下架只是孩子看不到，已兑换的卡券不受影响。",
            on_sale), cw, {
            size = 15, color = Blitbuffer.COLOR_DARK_GRAY, line_height = 0.35,
        }),
        Widgets.vspace(Size.span.vertical_default),
    }

    if #items == 0 then
        table.insert(content, Widgets.textbox("还没有商品，点下面的「添加商品」加一个。", cw, {
            size = 17, alignment = "center",
        }))
        table.insert(content, Widgets.vspace(Size.span.vertical_default))
    end

    -- 一行一张卡：左边卡券名 + 星星数（点一下改价），右边「下架/上架」「删除」两个窄按钮
    local pad = Size.padding.default
    local inner = cw - 2 * (pad + Size.border.thin)
    local btn_gap = Screen:scaleBySize(12)
    local btn_w = Screen:scaleBySize(96)
    local btn_h = Screen:scaleBySize(50)
    local btn_pad = Screen:scaleBySize(4)
    local info_w = inner - 2 * btn_w - 2 * btn_gap

    local function admin_card(item)
        local captured = item
        local info = Widgets.tappable(VerticalGroup:new{
            align = "left",
            Widgets.textbox(item.name, info_w, {
                size = 17, line_height = 0.15, max_lines = 2,
                color = item.enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY,
            }),
            Widgets.vspace(Size.span.vertical_small or Size.span.vertical_default),
            Widgets.label(string.format("★ %d%s", item.cost,
                item.enabled and "" or "（已下架）"), {
                size = 14, color = Blitbuffer.COLOR_DARK_GRAY, max_width = info_w,
            }),
        }, function() self:edit_shop_cost(captured) end)
        local body = HorizontalGroup:new{
            align = "center",
            info,
            Widgets.hspace(btn_gap),
            Widgets.button(item.enabled and "下架" or "上架", {
                width = btn_w,
                height = btn_h,
                size = 15,
                padding = btn_pad,
                callback = function()
                    Shop.set_enabled(self.progress, captured.id, not captured.enabled)
                    self:render_shop_settings()
                end,
            }),
            Widgets.hspace(btn_gap),
            Widgets.button("删除", {
                width = btn_w,
                height = btn_h,
                size = 15,
                padding = btn_pad,
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = string.format("从商城删除「%s」？\n已兑换的卡券还在钱包里。", captured.name),
                        ok_text = "删除",
                        cancel_text = "保留",
                        ok_callback = function()
                            Shop.remove_item(self.progress, captured.id)
                            self:render_shop_settings()
                        end,
                    })
                end,
            }),
        }
        return Widgets.card(body, { width = cw, padding = pad })
    end

    for _, item in ipairs(items) do
        table.insert(content, admin_card(item))
        table.insert(content, Widgets.vspace(Size.span.vertical_default))
    end

    table.insert(content, Widgets.vspace(Size.span.vertical_default))
    table.insert(content, Widgets.button("＋ 添加商品", {
        width = cw,
        height = Screen:scaleBySize(54),
        size = 19,
        callback = function() self:add_shop_item_dialog() end,
    }))
    table.insert(content, Widgets.vspace(Size.span.vertical_default))
    table.insert(content, Widgets.button("返回设置", {
        width = cw,
        size = 20,
        callback = function() self:render_settings() end,
    }))
    self:set_body(ScrollableContainer:new{
        dimen = self:scroll_viewport(),
        show_parent = self,
        content,
    })
end

-- 改一件卡券的星星数。换价只影响之后的兑换，钱包里已有的记录不动。
function MainView:edit_shop_cost(item)
    self:open_ai_text_input(string.format("「%s」要多少颗星星？（填数字，1~9999）", item.name),
        tostring(item.cost), false, function(value)
            local updated, err = Shop.set_cost(self.progress, item.id, value)
            if not updated then
                UIManager:show(InfoMessage:new{ text = tostring(err), timeout = 4 })
                return
            end
            UIManager:show(InfoMessage:new{
                text = string.format("%s　★%d", updated.name, updated.cost), timeout = 3,
            })
            self:render_shop_settings()
        end)
end

function MainView:add_shop_item_dialog()
    self:open_ai_text_input("商品名称（没有中文输入法可打拼音）", "", false, function(text)
        local name = tostring(text or "")
        if name:gsub("%s", "") == "" then
            UIManager:show(InfoMessage:new{ text = "没有输入商品名称", timeout = 3 })
            return
        end
        self:open_ai_text_input("需要多少颗星星？（填数字）", "", false, function(value)
            local item, err, existed = Shop.add_item(self.progress, name, value)
            if not item then
                UIManager:show(InfoMessage:new{ text = tostring(err), timeout = 4 })
                return
            end
            UIManager:show(InfoMessage:new{
                text = string.format("%s：%s　★%d", existed and "已更新" or "已添加", item.name, item.cost),
                timeout = 3,
            })
            self:render_shop_settings()
        end)
    end)
end

-- 学习设置 / 省市教材选择页的「返回」：从学习设置进来的仍回学习设置，
-- 从设置主页直接进来的回设置主页。
function MainView:return_to_settings()
    if self.settings_sub == "study" then
        self:render_study_settings()
    else
        self:render_settings()
    end
end

-- 设置主页那行灰字：当前地区 + 年级学期 + 各科教材，一眼看清孩子在用哪套书。
function MainView:study_summary()
    local settings = self.progress.data.settings
    local place = {}
    local province = Catalog.province(self.plugin_path, settings.province)
    if province then table.insert(place, province.name) end
    local city = settings.city
        and Catalog.city(self.plugin_path, settings.province, settings.city)
    if city then table.insert(place, city.name) end
    if #place == 0 then table.insert(place, "未选择地区") end
    local lines = { table.concat(place, " · ") .. "　"
        .. self:grade_label() .. self:semester_label() }
    local grade = tonumber(settings.grade) or 2
    local books = {}
    for _, subject in ipairs(SUBJECT_ORDER) do
        if has_volume(self.plugin_path, subject, grade, settings.semester) then
            local name = self:edition_name(subject)
            if name and name ~= "" then
                table.insert(books, string.format("%s %s", SUBJECT_LABEL[subject], name))
            end
        end
    end
    if #books > 0 then table.insert(lines, table.concat(books, "　")) end
    return table.concat(lines, "\n")
end

function MainView:render_settings()
    self.state = "settings"
    self.settings_sub = nil
    self:set_title("设置")
    local cw = Widgets.width()
    local settings = self.progress.data.settings
    local content = VerticalGroup:new{ align = "center" }
    -- 一行一列：每个入口独占整行，左边对齐，扫一眼就能顺着往下找
    local row_h = Screen:scaleBySize(54)
    local gap = Size.span.vertical_default
    local function menu_row(label, callback)
        return Widgets.button(label, {
            width = cw,
            height = row_h,
            align = "left",
            size = 18,
            callback = callback,
        })
    end
    local function add(widget)
        table.insert(content, widget)
        table.insert(content, Widgets.vspace(gap))
    end

    -- 学习设置（省份 / 城市 / 年级 / 学期 + 教材版本）整块收进密码后面：
    -- 把年级调低，题就跟着变简单，星星来得更快，这是孩子最容易钻的空子。
    add(menu_row("学习设置（需密码）", function() self:open_study_settings_gated() end))
    table.insert(content, Widgets.textbox(self:study_summary(), cw, {
        size = 15, color = Blitbuffer.COLOR_DARK_GRAY, line_height = 0.35,
    }))
    table.insert(content, Widgets.vspace(gap))

    add(menu_row(string.format("AI 出题设置：%s", self:ai_status_label()), function()
        self:render_ai_settings()
    end))
    add(menu_row(string.format("每日目标：%d 题", settings.daily_goal), function()
        self:cycle_goal()
        self:render_settings()
    end))
    add(menu_row(string.format("答错可重试：%s", settings.retry ~= false and "开" or "关"), function()
        settings.retry = settings.retry == false
        self.progress:flush()
        self:render_settings()
    end))

    -- 两个密码：家长密码管家长区与兑现，退出插件密码只管退出。
    add(menu_row(string.format("家长密码：%s", settings.parent_pin and "已设置" or "未设置"), function()
        self:render_pin_settings("parent")
    end))
    add(menu_row(string.format("退出插件密码：%s", settings.exit_pin and "已设置" or "未设置"), function()
        self:render_pin_settings("exit")
    end))
    add(menu_row("重置学习进度", function()
        -- 有家长密码时先验证，防止孩子自行清空进度
        local pin = settings.parent_pin
        if pin and #tostring(pin) == 4 then
            self:ask_pin_input("重置学习进度 · 请输入家长密码", function(text)
                if text == nil then return end
                if text ~= tostring(pin) then
                    UIManager:show(InfoMessage:new{ text = "密码不对，未重置。", timeout = 3 })
                    return
                end
                self:confirm_reset_progress()
            end)
            return
        end
        self:confirm_reset_progress()
    end))

    table.insert(content, Widgets.vspace(Size.span.vertical_large))
    table.insert(content, Widgets.textbox(string.format("当前版本：v%s", Update.local_version(self.plugin_path)), cw, { size = 18 }))
    table.insert(content, Widgets.vspace(gap))
    add(menu_row(string.format("启动时自动检查更新：%s", settings.update_auto_check and "开" or "关"), function()
        settings.update_auto_check = not settings.update_auto_check
        self.progress:flush()
        self:render_settings()
    end))
    add(menu_row("检查更新", function() self:check_update() end))
    -- 商城后台：家长把愿望做成卡券，孩子用星星兑换；改价/上下架都属于家长操作，
    -- 进去前要家长密码，孩子不能自己把愿望改便宜或加一张。
    add(menu_row(string.format("商城后台（需密码）：%d 件在售", #Shop.items(self.progress)), function()
        self:open_shop_settings_gated()
    end))
    add(menu_row("关于学习助理", function()
        local grade = tonumber(settings.grade) or 2
        local counts = {}
        for _, s in ipairs({ "chinese", "english", "physics", "chemistry",
                             "biology", "history", "geography" }) do
            local b = Bank.load(self.plugin_path, s, grade, settings.semester,
                settings_edition(settings, s))
            counts[s] = b and #b.questions or 0
        end
        local math_note = grade >= 7 and "数学题库：初高中静态题库"
            or "数学题库：程序生成，无限题"
        UIManager:show(InfoMessage:new{
            text = string.format(
                "学习助理 v%s\n%s · %s · %s\n\n语文题库：%d 题\n英语题库：%d 题\n物理题库：%d 题\n化学题库：%d 题\n生物题库：%d 题\n历史题库：%d 题\n地理题库：%d 题\n%s\n\n学习记录和 AI 题库只保存在本机；只有你主动使用 AI 出题或检查更新时才会联网，更新只替换插件程序，不影响学习记录。",
                Update.local_version(self.plugin_path),
                self:grade_label(), self:semester_label(), self:edition_name("math"),
                counts.chinese, counts.english, counts.physics, counts.chemistry,
                counts.biology, counts.history, counts.geography,
                math_note
            ),
            timeout = 6,
        })
    end))

    table.insert(content, Widgets.vspace(Size.span.vertical_large))
    table.insert(content, Widgets.button("回首页", {
        width = cw,
        size = 20,
        callback = function() self:render_home() end,
    }))
    local scroll = ScrollableContainer:new{
        dimen = self:scroll_viewport(),
        show_parent = self,
        content,
    }
    self:set_body(scroll)
end

--[[--
学习设置是家长区：省市、年级、学期和教材版本都在这儿。

年级直接决定题目难度（一年级的口算和四年级的不是一个量级），改低年级等于
把星星变便宜，所以整页要密码才能进。
--]]--
function MainView:open_study_settings_gated()
    local pin = self.progress.data.settings.parent_pin
    if not pin or #tostring(pin) ~= 4 then
        UIManager:show(ConfirmBox:new{
            text = "「学习设置」是家长区，需要家长密码才能进入。\n\n把年级改低，题目就变简单，星星也会来得更容易，所以这里不让小朋友自己改。\n\n现在还没有设置家长密码，先去设置一个吧。",
            ok_text = "去设置家长密码",
            cancel_text = "稍后",
            ok_callback = function()
                self:render_pin_settings("parent", function() self:render_study_settings() end)
            end,
        })
        return
    end
    self:ask_pin_input("学习设置 · 请输入家长密码", function(text)
        if text == nil then return end
        if tostring(text) ~= tostring(pin) then
            UIManager:show(InfoMessage:new{ text = "密码不对，未进入。", timeout = 3 })
            return
        end
        self:render_study_settings()
    end)
end

function MainView:render_study_settings()
    self.state = "study_settings"
    self.settings_sub = "study"
    self:set_title("学习设置")
    local cw = Widgets.width()
    local settings = self.progress.data.settings
    local content = VerticalGroup:new{ align = "center" }
    -- 顶部提示：一句话说明教材是按城市 + 年级 + 学期自动匹配的
    table.insert(content, Widgets.textbox(
        "根据学生城市，年级，学期选择，教材自动匹配。", cw, {
            size = 16, color = Blitbuffer.COLOR_DARK_GRAY, line_height = 0.35,
        }))
    table.insert(content, Widgets.vspace(Size.span.vertical_default))
    -- 省份 / 城市 / 年级 / 学期 一行四等份
    local gap4 = Screen:scaleBySize(8)
    local tile_w4 = math.floor((cw - 3 * gap4) / 4)
    local function pick4(text, callback)
        return Widgets.button(text, {
            width = tile_w4,
            height = Screen:scaleBySize(54),
            align = "center",
            size = 18,
            callback = callback,
        })
    end
    table.insert(content, HorizontalGroup:new{
        align = "center",
        pick4((Catalog.province(self.plugin_path, settings.province) or {}).name or "省份",
            function() self:render_province_select() end),
        Widgets.hspace(gap4),
        pick4(self:city_short_label(), function() self:render_city_select() end),
        Widgets.hspace(gap4),
        pick4(self:grade_label(), function() self:render_grade_select() end),
        Widgets.hspace(gap4),
        pick4(self:semester_label(), function()
            settings.semester = settings.semester == "upper" and "lower" or "upper"
            self.progress:flush()
            -- 上下册可能是不同版次（如数学一上 2024秋版 / 一下 2025春版），要重新匹配
            if settings.city then
                local city = Catalog.city(self.plugin_path, settings.province, settings.city)
                self:apply_city_match(city and city.name or nil, false, true)
            else
                self:render_study_settings()
            end
        end),
    })
    table.insert(content, Widgets.vspace(Size.span.vertical_default))
    -- 教材：只列「这个年级 + 这个学期真有教材」的科目，一行两科；
    -- 一年级没有英语、小学没有理化、九年级没有生物地理时，对应格子直接不出现。
    table.insert(content, Widgets.textbox("教材版本（可自定义选择）", cw, {
        size = 16, color = Blitbuffer.COLOR_DARK_GRAY, line_height = 0.3,
    }))
    table.insert(content, Widgets.vspace(Size.span.vertical_small or Size.span.vertical_default))
    local grade = tonumber(settings.grade) or 2
    local edition_subjects = {}
    for _, subject in ipairs(SUBJECT_ORDER) do
        if has_volume(self.plugin_path, subject, grade, settings.semester) then
            table.insert(edition_subjects, subject)
        end
    end
    local gap = Screen:scaleBySize(8)
    local function edition_tile(subject, width)
        return Widgets.button(
            string.format("%s %s", SUBJECT_LABEL[subject], self:edition_tile_label(subject)), {
                width = width,
                height = Screen:scaleBySize(54),
                align = "left",
                size = 18,
                callback = function() self:render_edition_select(subject) end,
            })
    end
    if #edition_subjects == 0 then
        table.insert(content, Widgets.textbox(
            "这个年级、这个学期还没有可选的教材，换个年级或学期看看。", cw, {
                size = 16, color = Blitbuffer.COLOR_DARK_GRAY, alignment = "center",
            }))
        table.insert(content, Widgets.vspace(Size.span.vertical_default))
    else
        local idx = 1
        for _, count in ipairs(balanced_row_counts(#edition_subjects, 2)) do
            local w = math.floor((cw - (count - 1) * gap) / count)
            local row = HorizontalGroup:new{ align = "center" }
            for i = idx, idx + count - 1 do
                if i > idx then table.insert(row, Widgets.hspace(gap)) end
                table.insert(row, edition_tile(edition_subjects[i], w))
            end
            table.insert(content, row)
            table.insert(content, Widgets.vspace(Size.span.vertical_default))
            idx = idx + count
        end
    end
    table.insert(content, Widgets.textbox(
        "点科目可以自己换版本。换完回这里核对一下，星星商城和练习都按这里的设置走。", cw, {
            size = 15, color = Blitbuffer.COLOR_DARK_GRAY, line_height = 0.35,
        }))
    table.insert(content, Widgets.vspace(Size.span.vertical_large))
    table.insert(content, Widgets.button("返回设置", {
        width = cw,
        size = 20,
        callback = function() self:render_settings() end,
    }))
    local scroll = ScrollableContainer:new{
        dimen = self:scroll_viewport(),
        show_parent = self,
        content,
    }
    self:set_body(scroll)
end

-- ---------------------------------------------------------------------------
-- Knowledge-point learning (synced from cn-math-taxonomy, CC BY-NC 4.0)
-- ---------------------------------------------------------------------------

local function kp_volume_label(grade, semester)
    grade = tonumber(grade) or 1
    local sem = semester == "lower" and "下" or "上"
    if grade >= 10 then
        return string.format("%s·%s学期", GRADE_LABEL[grade] or (grade .. "年级"), sem)
    end
    return string.format("%s%s册", GRADE_LABEL[grade] or (grade .. "年级"), sem)
end

local function kp_status_mark(status)
    return KP_STATUS_MARK[status]
end

local function kp_topic_button_text(name, status)
    local mark = kp_status_mark(status)
    if mark then return mark .. " " .. name end
    return name
end

-- Same difficulty curve as core/session.lua, kept local to avoid coupling.
local function kp_choose_difficulty(rng, level)
    local roll = rng(100)
    if level <= 1 then
        return roll <= 70 and 1 or 2
    elseif level >= 3 then
        if roll <= 10 then return 1 elseif roll <= 50 then return 2 else return 3 end
    end
    if roll <= 30 then return 1 elseif roll <= 80 then return 2 else return 3 end
end

function MainView:render_kp_subject()
    self.state = "kp_subject"
    self:set_title("知识点学习")
    self.selected = nil
    self.number_input = ""
    self.feedback = nil
    local cw = Widgets.width()
    local settings = self.progress.data.settings
    local grade = tonumber(settings.grade) or 2
    local semester = settings.semester
    -- 跟首页学科按钮同一套规则：只列出当前年级/学期真有知识点内容的学科
    local kp_subjects = {}
    for _, subject in ipairs(SUBJECT_ORDER) do
        local volume = Knowledge.load(self.plugin_path, subject, grade, semester,
            settings_edition(settings, subject))
        if volume and #volume.topics > 0 then
            table.insert(kp_subjects, subject)
        end
    end
    local content = VerticalGroup:new{
        align = "center",
        Widgets.textbox("按课标知识点先学后练；诊断会沿先修关系找到薄弱的基础知识。", cw, {
            size = 18, color = Blitbuffer.COLOR_DARK_GRAY,
        }),
        Widgets.vspace(Size.span.vertical_large),
    }
    if #kp_subjects == 0 then
        table.insert(content, Widgets.textbox(
            "本学习阶段暂无知识点内容，可在设置里换年级或教材版本。", cw, {
                size = 20,
            }))
        table.insert(content, Widgets.vspace(Size.span.vertical_default))
    end
    for _, row in ipairs(subject_grid(kp_subjects, cw, function(subject, w)
        return Widgets.button(SUBJECT_LABEL[subject] or subject, {
            width = w,
            height = Screen:scaleBySize(64),
            size = 22,
            callback = function() self:render_kp_select(subject) end,
        })
    end)) do
        table.insert(content, row)
        table.insert(content, Widgets.vspace(Size.span.vertical_default))
    end
    table.insert(content, Widgets.vspace(Size.span.vertical_large))
    table.insert(content, Widgets.button("返回首页", {
        width = cw,
        size = 20,
        callback = function() self:render_home() end,
    }))
    -- Short page: center it in the free area instead of hugging the title bar.
    self:set_body(CenterContainer:new{
        dimen = Geom:new{ w = cw, h = self:scroll_viewport().h },
        content,
    })
end

function MainView:render_kp_select(subject)
    self.state = "kp_select"
    self.kp_subject = subject
    self:set_title(self:subject_label(subject) .. "知识点")
    self.selected = nil
    self.number_input = ""
    self.feedback = nil
    local cw = Widgets.width()
    local settings = self.progress.data.settings
    local grade = tonumber(settings.grade) or 2
    local semester = settings.semester
    -- 按当前所选教材版本加载：有 toc 卷的版本（如译林英语）按课本目录展示。
    local edition = settings_edition(settings, subject)
    local volume, err = Knowledge.load(self.plugin_path, subject, grade, semester, edition)
    if not volume then
        UIManager:show(InfoMessage:new{
            text = string.format("%s%s暂无知识点内容，可在设置里切换年级后再试。",
                self:subject_label(subject), self:grade_label()),
            timeout = 5,
        })
        self:render_home()
        return
    end
    local topic_ids = {}
    for _, topic in ipairs(volume.topics) do table.insert(topic_ids, topic.id) end
    local counts = self.progress:kp_summary(subject, topic_ids)
    local reference
    if volume.edition then
        local name = self:edition_name_of(subject, edition)
        if name ~= "" then
            reference = string.format("课本目录 · %s%s", name,
                self:edition_term_suffix(subject, edition))
        else
            reference = "课本目录"
        end
    else
        reference = (subject == "chinese" or subject == "history")
            and "课标知识点 · 统编参考" or "课标知识点 · 2022 课标"
    end

    local content = VerticalGroup:new{
        align = "center",
        Widgets.label(string.format("%s · %s", kp_volume_label(grade, semester), reference), {
            size = 17, color = Blitbuffer.COLOR_DARK_GRAY,
        }),
        Widgets.vspace(Size.span.vertical_default),
        Widgets.label(string.format("已掌握 %d/%d　★已掌握 ●学习中 ▲薄弱", counts.mastered, counts.total), {
            size = 16, color = Blitbuffer.COLOR_DARK_GRAY,
        }),
        Widgets.vspace(Size.span.vertical_default),
        Widgets.button(string.format("全册知识点综合（%d 题）",
            tonumber(settings.daily_goal) or 10), {
            width = cw,
            height = Screen:scaleBySize(56),
            size = 21,
            callback = function() self:start_kp_mixed(subject) end,
        }),
        Widgets.vspace(Size.span.vertical_default),
    }

    local half = math.floor((cw - Size.span.horizontal_default) / 2)
    for _, unit in ipairs(volume.units) do
        local unit_topics = {}
        for _, topic in ipairs(volume.topics) do
            if topic.unit == unit.id then table.insert(unit_topics, topic) end
        end
        if #unit_topics > 0 then
            table.insert(content, Widgets.label(unit.name, {
                size = 18, bold = true, max_width = cw,
            }))
            table.insert(content, Widgets.vspace(Size.span.vertical_default))
            local row
            for i, topic in ipairs(unit_topics) do
                local status = self.progress:kp_status(subject, topic.id)
                local button = Widgets.button(kp_topic_button_text(topic.name, status), {
                    width = half,
                    height = Screen:scaleBySize(52),
                    size = 18,
                    callback = function() self:render_kp_learn(subject, topic.id) end,
                })
                if i % 2 == 1 then
                    row = HorizontalGroup:new{ align = "center", button }
                    table.insert(content, row)
                    table.insert(content, Widgets.vspace(Size.span.vertical_default))
                else
                    table.insert(row, Widgets.hspace(Size.span.horizontal_default))
                    table.insert(row, button)
                end
            end
            table.insert(content, Widgets.vspace(Size.span.vertical_default))
        end
    end
    table.insert(content, Widgets.button("返回首页", {
        width = cw,
        size = 20,
        callback = function() self:render_home() end,
    }))
    local scroll = ScrollableContainer:new{
        dimen = self:scroll_viewport(),
        show_parent = self,
        content,
    }
    self:set_body(scroll)
end

function MainView:render_kp_learn(subject, topic_id)
    self.state = "kp_learn"
    self.kp_subject = subject
    self.selected = nil
    self.number_input = ""
    self.feedback = nil
    local topic = Knowledge.topic(self.plugin_path, subject, topic_id)
    if not topic then
        UIManager:show(InfoMessage:new{ text = "没有找到这个知识点", timeout = 3 })
        self:render_kp_select(subject)
        return
    end
    self:set_title(topic.name)
    local cw = Widgets.width()
    local inner_width = cw - 2 * Size.padding.large
    local graph = Knowledge.graph(self.plugin_path, subject)
    local node = graph and graph.nodes[topic_id] or {}
    local questions = Knowledge.questions_for(self.plugin_path, subject, topic_id)
    local status = self.progress:kp_status(subject, topic_id)
    local status_text = status and KP_STATUS_LABEL[status] or "未学"

    local example_explain
    for _, q in ipairs(questions) do
        if q.id == topic_id .. "_q1" then example_explain = q.explain break end
    end

    local learn_parts = VerticalGroup:new{
        align = "left",
        Widgets.label(string.format("%s · %s · %s", topic.domain or "",
            kp_volume_label(node.grade, node.semester), status_text), {
            size = 16, color = Blitbuffer.COLOR_DARK_GRAY,
        }),
        Widgets.vspace(Size.span.vertical_default),
        Widgets.textbox(topic.description or "", inner_width, { size = 20 }),
        Widgets.vspace(Size.span.vertical_default),
        Widgets.label("掌握标准", { size = 18, bold = true }),
    }
    for _, criterion in ipairs(topic.mastery_criteria or {}) do
        table.insert(learn_parts, Widgets.textbox("· " .. criterion, inner_width, { size = 18 }))
    end
    local example = topic.example or {}
    if example.question and example.question ~= "" then
        table.insert(learn_parts, Widgets.vspace(Size.span.vertical_default))
        table.insert(learn_parts, Widgets.label("例题", { size = 18, bold = true }))
        table.insert(learn_parts, Widgets.textbox(example.question, inner_width, { size = 19 }))
        table.insert(learn_parts, Widgets.label("参考答案：" .. tostring(example.answer or ""), { size = 18, bold = true }))
        if example_explain then
            table.insert(learn_parts, Widgets.textbox(example_explain, inner_width, { size = 17, color = Blitbuffer.COLOR_DARK_GRAY }))
        end
    end

    local content = VerticalGroup:new{
        align = "center",
        Widgets.card(learn_parts, { width = cw, padding = Size.padding.large }),
        Widgets.vspace(Size.span.vertical_default),
    }

    local prereqs = Knowledge.prereqs(self.plugin_path, subject, topic_id)
    if #prereqs > 0 then
        table.insert(content, Widgets.label("先修知识点（先学这些更容易）", {
            size = 17, color = Blitbuffer.COLOR_DARK_GRAY,
        }))
        table.insert(content, Widgets.vspace(Size.span.vertical_default))
        for _, p in ipairs(prereqs) do
            local pnode = graph and graph.nodes[p.id]
            local pstatus = self.progress:kp_status(subject, p.id)
            local label = kp_topic_button_text(pnode and pnode.name or p.id, pstatus)
            if p.strength == "soft" then label = label .. "（建议）" end
            table.insert(content, Widgets.button(label, {
                width = cw,
                height = Screen:scaleBySize(48),
                size = 18,
                callback = function() self:render_kp_learn(subject, p.id) end,
            }))
            table.insert(content, Widgets.vspace(Size.span.vertical_default))
        end
    end

    table.insert(content, Widgets.button(string.format("开始练习（%d 题）", #questions), {
        width = cw,
        height = Screen:scaleBySize(60),
        size = 22,
        enabled = #questions > 0,
        callback = function() self:start_kp_practice(subject, topic_id) end,
    }))
    table.insert(content, Widgets.vspace(Size.span.vertical_default))
    table.insert(content, Widgets.button("诊断这个知识点", {
        width = cw,
        height = Screen:scaleBySize(56),
        size = 21,
        callback = function() self:start_diagnose(subject, topic_id) end,
    }))
    table.insert(content, Widgets.vspace(Size.span.vertical_default))
    table.insert(content, Widgets.button("返回知识点列表", {
        width = cw,
        size = 20,
        callback = function() self:render_kp_select(subject) end,
    }))
    local scroll = ScrollableContainer:new{
        dimen = self:scroll_viewport(),
        show_parent = self,
        content,
    }
    self:set_body(scroll)
end

function MainView:start_kp_practice(subject, topic_id)
    local questions = Knowledge.questions_for(self.plugin_path, subject, topic_id)
    if #questions == 0 then
        UIManager:show(InfoMessage:new{ text = "这个知识点暂时没有可用题目", timeout = 3 })
        return
    end
    -- Easy questions first; keep source order within the same difficulty.
    local ordered = {}
    for i, q in ipairs(questions) do ordered[i] = { q = q, i = i } end
    table.sort(ordered, function(a, b)
        if a.q.difficulty ~= b.q.difficulty then return a.q.difficulty < b.q.difficulty end
        return a.i < b.i
    end)
    local list = {}
    for _, item in ipairs(ordered) do table.insert(list, item.q) end
    self:start_session({
        mode = "kp",
        subject = subject,
        kp_topic = topic_id,
        kp_questions = list,
    })
end

function MainView:start_kp_mixed(subject)
    local settings = self.progress.data.settings
    local grade = tonumber(settings.grade) or 2
    local volume, err = Knowledge.load(self.plugin_path, subject, grade,
        settings.semester, settings_edition(settings, subject))
    if not volume or #volume.units == 0 then
        UIManager:show(InfoMessage:new{ text = "知识点题库加载失败：" .. tostring(err), timeout = 4 })
        return
    end
    local rng = math.random
    local level = self.progress:adaptive_level(subject, grade)
    -- 题数跟设置里的「每日目标」走，不再写死 10 题
    local goal = tonumber(settings.daily_goal) or 10
    local recent = {}
    for _, id in ipairs(self.progress.data.recent_ids) do recent[id] = true end
    local questions = {}
    for i = 1, goal do
        local unit = volume.units[((i - 1) % #volume.units) + 1]
        local unit_topics = {}
        for _, topic in ipairs(volume.topics) do
            if topic.unit == unit.id then table.insert(unit_topics, topic) end
        end
        if #unit_topics > 0 then
            local topic = unit_topics[rng(#unit_topics)]
            -- 共享知识点（如天气）的题在各自的版本卷里，统一走 questions_for。
            local pool = Knowledge.questions_for(self.plugin_path, subject, topic.id)
            if #pool == 0 then pool = volume.by_topic[topic.id] or {} end
            local difficulty = kp_choose_difficulty(rng, level)
            local candidates = {}
            for _, q in ipairs(pool) do
                if q.difficulty == difficulty and not recent[q.id] then table.insert(candidates, q) end
            end
            if #candidates == 0 then
                for _, q in ipairs(pool) do
                    if not recent[q.id] then table.insert(candidates, q) end
                end
            end
            if #candidates == 0 then candidates = pool end
            if #candidates > 0 then
                local q = candidates[rng(#candidates)]
                table.insert(questions, q)
                recent[q.id] = true
            end
        end
    end
    if #questions == 0 then
        UIManager:show(InfoMessage:new{ text = "没有可用题目", timeout = 3 })
        return
    end
    self:start_session({ mode = "kp", subject = subject, kp_questions = questions })
end

function MainView:start_diagnose(subject, topic_id)
    local graph, err = Knowledge.graph(self.plugin_path, subject)
    if not graph then
        UIManager:show(InfoMessage:new{ text = "知识图谱加载失败：" .. tostring(err), timeout = 4 })
        return
    end
    if #Knowledge.questions_for(self.plugin_path, subject, topic_id) == 0 then
        UIManager:show(InfoMessage:new{ text = "这个知识点暂时没有可用题目", timeout = 3 })
        return
    end
    local engine, derr = Diagnose.new{
        subject = subject,
        target = topic_id,
        graph = graph,
        questions_fn = function(id)
            return Knowledge.questions_for(self.plugin_path, subject, id)
        end,
        judge_fn = Knowledge.judge,
        rng = math.random,
    }
    if not engine then
        UIManager:show(InfoMessage:new{ text = "无法开始诊断：" .. tostring(derr), timeout = 4 })
        return
    end
    self.diagnose = engine
    self.diagnose_subject = subject
    self.diagnose_feedback = nil
    self.diagnose_summary = nil
    self:diagnose_next()
end

function MainView:diagnose_next()
    local item = self.diagnose:next()
    if not item then
        self:finish_diagnose()
        return
    end
    self.diagnose_item = item
    self.selected = nil
    self.number_input = ""
    self:render_diagnose_quiz()
end

function MainView:diagnose_submit(value)
    if not self.diagnose or not self.diagnose_item then return end
    local result = self.diagnose:submit(value)
    if not result then return end
    self.diagnose_feedback = {
        question = self.diagnose_item.question,
        correct = result.correct,
        hint = result.hint,
        status = result.status,
    }
    self:render_diagnose_feedback()
end

function MainView:finish_diagnose()
    local summary = self.diagnose:summary()
    -- Diagnosis is assessment: persist mastery only, no stars / wrong book.
    for _, entry in ipairs(summary.mastered) do
        self.progress:mark_kp_status(self.diagnose_subject, entry.id, "mastered")
    end
    for _, entry in ipairs(summary.shaky) do
        self.progress:mark_kp_status(self.diagnose_subject, entry.id, "learning")
    end
    for _, entry in ipairs(summary.weak) do
        self.progress:mark_kp_status(self.diagnose_subject, entry.id, "weak")
    end
    self.progress:flush()
    self.diagnose_summary = summary
    self:render_diagnose_result()
end

function MainView:render_diagnose_quiz()
    self.state = "diagnose_quiz"
    self:set_title("知识点诊断")
    local engine = self.diagnose
    local question = self.diagnose_item.question
    local cw = Widgets.width()
    local content = VerticalGroup:new{
        align = "center",
        Widgets.label(string.format("已答 %d/%d 题 · 答错会自动检查先修知识", #engine.answers, engine.limit), {
            size = 16, color = Blitbuffer.COLOR_DARK_GRAY,
        }),
        Widgets.vspace(Size.span.vertical_default),
        Widgets.progress(#engine.answers / engine.limit, cw),
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

function MainView:render_diagnose_feedback()
    self.state = "diagnose_feedback"
    self:set_title("知识点诊断")
    local fb = self.diagnose_feedback
    local q = fb.question
    local cw = Widgets.width()
    local parts = VerticalGroup:new{ align = "left" }
    if fb.correct then
        table.insert(parts, Widgets.label("✓ 答对了！", { size = 24, bold = true }))
    else
        table.insert(parts, Widgets.label("✗ 答错了", { size = 24, bold = true }))
        table.insert(parts, Widgets.label("正确答案：" .. answer_text(q), { size = 20, bold = true }))
    end
    table.insert(parts, Widgets.vspace(Size.span.vertical_default))
    table.insert(parts, Widgets.label(fb.hint or "", { size = 18, bold = true }))
    table.insert(parts, Widgets.vspace(Size.span.vertical_default))
    table.insert(parts, Widgets.textbox(q.explain or "", cw - 4 * Size.padding.default, { size = 18 }))
    local content = VerticalGroup:new{
        align = "center",
        Widgets.label(string.format("已答 %d/%d 题", #self.diagnose.answers, self.diagnose.limit), {
            size = 16, color = Blitbuffer.COLOR_DARK_GRAY,
        }),
        Widgets.vspace(Size.span.vertical_default),
        self:render_question_card(q),
        Widgets.vspace(Size.span.vertical_default),
        Widgets.card(parts, { width = cw, padding = Size.padding.large }),
        Widgets.vspace(Size.span.vertical_large),
        Widgets.button("继续", {
            width = cw,
            height = Screen:scaleBySize(58),
            size = 22,
            callback = function() self:diagnose_next() end,
        }),
    }
    self:set_body(content)
end

function MainView:render_diagnose_result()
    self.state = "diagnose_result"
    self:set_title("诊断结果")
    local cw = Widgets.width()
    local summary = self.diagnose_summary
    local graph = self.diagnose.graph
    local target_node = graph.nodes[summary.target] or {}
    local content = VerticalGroup:new{
        align = "center",
        Widgets.card(VerticalGroup:new{
            align = "center",
            Widgets.label("诊断完成", { size = 28, bold = true }),
            Widgets.vspace(Size.span.vertical_default),
            Widgets.label(string.format("目标：%s", target_node.name or summary.target), { size = 19 }),
            Widgets.vspace(Size.span.vertical_default),
            Widgets.label(string.format("共答 %d 题 · 掌握 %d · 不稳 %d · 薄弱 %d",
                summary.asked, #summary.mastered, #summary.shaky, #summary.weak), { size = 18 }),
            summary.limit_reached and Widgets.label("题量用完，还有知识点没测到。", {
                size = 16, color = Blitbuffer.COLOR_DARK_GRAY,
            }) or Widgets.vspace(0),
        }, { width = cw, padding = Size.padding.large }),
        Widgets.vspace(Size.span.vertical_default),
    }

    if #summary.path > 0 then
        table.insert(content, Widgets.label("学习路径（从基础补起）", { size = 19, bold = true }))
        table.insert(content, Widgets.vspace(Size.span.vertical_default))
        for i, entry in ipairs(summary.path) do
            local status_text = entry.status == "weak" and "薄弱" or "不稳"
            local tag = entry.is_root and "根因 · " or ""
            table.insert(content, Widgets.label(string.format("%d. %s%s（%s · %s）",
                i, tag, entry.name, kp_volume_label(entry.grade, entry.semester), status_text), {
                size = 18, max_width = cw,
            }))
            table.insert(content, Widgets.vspace(Size.span.vertical_default))
        end
        table.insert(content, Widgets.button("去学第一个薄弱点", {
            width = cw,
            height = Screen:scaleBySize(58),
            size = 21,
            callback = function()
                self:render_kp_learn(self.diagnose_subject, summary.path[1].id)
            end,
        }))
        table.insert(content, Widgets.vspace(Size.span.vertical_default))
    else
        table.insert(content, Widgets.textbox("没有发现薄弱点，继续保持！", cw, {
            size = 20, alignment = "center",
        }))
        table.insert(content, Widgets.vspace(Size.span.vertical_default))
    end

    if #summary.mastered > 0 then
        local names = {}
        for i, entry in ipairs(summary.mastered) do
            if i <= 8 then table.insert(names, entry.name) end
        end
        local text = "已掌握：" .. table.concat(names, "、")
        if #summary.mastered > 8 then
            text = text .. string.format(" 等 %d 个", #summary.mastered)
        end
        table.insert(content, Widgets.textbox(text, cw, { size = 16, color = Blitbuffer.COLOR_DARK_GRAY }))
        table.insert(content, Widgets.vspace(Size.span.vertical_default))
    end

    table.insert(content, Widgets.button("再诊断一次", {
        width = cw,
        size = 20,
        callback = function() self:start_diagnose(self.diagnose_subject, summary.target) end,
    }))
    table.insert(content, Widgets.vspace(Size.span.vertical_default))
    table.insert(content, Widgets.button("返回知识点列表", {
        width = cw,
        size = 20,
        callback = function() self:render_kp_select(self.diagnose_subject) end,
    }))
    table.insert(content, Widgets.vspace(Size.span.vertical_default))
    table.insert(content, Widgets.button("回首页", {
        width = cw,
        size = 20,
        callback = function() self:render_home() end,
    }))
    local scroll = ScrollableContainer:new{
        dimen = self:scroll_viewport(),
        show_parent = self,
        content,
    }
    self:set_body(scroll)
end


return MainView
