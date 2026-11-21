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
local VerticalGroup = require("ui/widget/verticalgroup")

local AIBank = require("core.ai_bank")
local AIClient = require("core.ai_client")
local AIConfig = require("core.ai_config")
local AIVariant = require("core.ai_variant")
local Badges = require("core.badges")
local Bank = require("core.bank")
local Catalog = require("core.catalog")
local MathGen = require("core.mathgen")
local Progress = require("core.progress")
local Session = require("core.session")
local Shop = require("core.shop")
local PinPadDialog = require("ui/pinpad")
local Widgets = require("ui/widgets")

local Screen = Device.screen
local _ = require("gettext")

-- Shared labels/helpers live in ui/pages/common so the split-out page modules
-- (ui/pages/*) can reuse them.  Re-imported here under the same local names
-- so the code that stays in this file is unchanged.
local Common = require("ui/pages/common")
local SUBJECT_LABEL = Common.SUBJECT_LABEL
local SUBJECT_ORDER = Common.SUBJECT_ORDER
local DEFAULT_EDITIONS = Common.DEFAULT_EDITIONS
local GRADE_LABEL = Common.GRADE_LABEL
local KP_STATUS_MARK = Common.KP_STATUS_MARK
local KP_STATUS_LABEL = Common.KP_STATUS_LABEL
local settings_edition = Common.settings_edition
local balanced_row_counts = Common.balanced_row_counts
local subject_grid = Common.subject_grid
local answer_text = Common.answer_text
local CITY_SUBJECTS = Common.CITY_SUBJECTS
local has_volume = Common.has_volume

local MainView = InputContainer:extend{
    covers_fullscreen = true,
}

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

-- Friendly text for "no content at this stage", e.g.
-- "本学习阶段暂无物理学科（物理覆盖八年级到九年级，可在设置里切换年级）".
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

-- 家长有没有在「学习设置 → 教材版本」里手动指定过这门课的教材。
function MainView:edition_manually_set(subject)
    local manual = self.progress.data.settings.edition_manual
    return type(manual) == "table" and manual[subject] == true
end

-- 这门课在当前地区/年级/学期该不该出现 —— 首页、今日挑战、知识点全部走这一个判定，
-- 别再各写一套（以前首页看内容、设置看任意版本，才会打架）。
--   1. 地区这门课还没开（上海一年级数学、一年级英语）→ 不显示
--      除非家长手动指定了教材 —— 指定了就是他要用，照常显示
--   2. 数学 1~6 年级是现场生成题，教材里没有这一册 → 不显示
-- 映射断档/整科缺失不算「没有」（见 Catalog.city_subject_state），照旧按内容判断。
function MainView:subject_visible(subject, grade, semester)
    local settings = self.progress.data.settings
    if self:edition_manually_set(subject) then return true end
    if Catalog.subject_not_started(self.plugin_path, settings.province, settings.city, subject, grade) then
        return false
    end
    if subject == "math" and (tonumber(grade) or 0) <= 6 then
        local edition = settings_edition(settings, "math")
        if not Catalog.edition_has_volume(self.plugin_path, "math", edition, grade, semester) then
            return false
        end
    end
    return true
end

-- 这一科在当前年级/学期到底有没有书（设置页格子上显示「暂无」的判据）。
-- 两种情况都算没有：本地区这个年级还没开这门课；或者任何版本都还没有这一册
-- （一年级物理、一年级英语这种）。手动指定过的科目一律算有。
function MainView:subject_no_book(subject, grade, semester)
    if self:edition_manually_set(subject) then return false end
    local settings = self.progress.data.settings
    semester = semester or settings.semester
    if Catalog.subject_not_started(self.plugin_path,
        settings.province, settings.city, subject, grade) then
        return true
    end
    return not has_volume(self.plugin_path, subject, grade, semester)
end

-- 地区用的出版社插件没收录时的标注，例如「冀教版未收录」。
-- 界面上拼在版本名后面：英语 人教版（冀教版未收录），家长一眼看出不是孩子那本书。
function MainView:substitute_note(subject, grade)
    local settings = self.progress.data.settings
    local state, _, publisher = Catalog.city_subject_state(self.plugin_path,
        settings.province, settings.city, subject, grade)
    if state == "not_started" then
        -- 手动指定的情况才走到这里（没指定时格子显示「暂无」）
        return self:edition_manually_set(subject) and "本地区未开课" or nil
    end
    if state ~= "uncollected" then return nil end
    local used = settings_edition(settings, subject)
    local local_name = publisher or "本地教材"
    if Catalog.edition_name(self.plugin_path, subject, used) == local_name then return nil end
    return local_name .. "未收录"
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
    -- 兜底：正常情况下按钮都不显示了，这里只是防止从旧页面/旧会话点进来。
    if not self:subject_visible(subject, grade, semester) then
        local start = Catalog.subject_start_grade(self.plugin_path,
            settings.province, settings.city, subject)
        local label = self:subject_label(subject)
        local text
        if start and start > grade then
            text = string.format("%s还没有%s课（本地区从%s开始），可在设置里换年级。",
                self:grade_label(), label, GRADE_LABEL[start] or (start .. "年级"))
        else
            text = string.format("%s%s教材暂缺，可在设置里换个版本。", self:grade_label(), label)
        end
        UIManager:show(InfoMessage:new{ text = text, timeout = 5 })
        if from_challenge then self:render_challenge_menu() else self:render_home() end
        return
    end
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

--[[--
Page modules split out of this file (see ui/pages/).  Each module returns a
table of methods; they get mounted onto MainView so that `self:method()` calls
keep working unchanged and cross-page calls resolve through self no matter which
file a method actually lives in.

Two guards, because a silent overwrite is invisible until something renders the
wrong screen at runtime:
  * a name already on MainView (or already mounted by another page) is a hard
    error rather than a silent clobber;
  * only functions may be exported — a stray constant in a page table would end
    up being called as `self:CONSTANT()`.

Adding a page = add its file to ui/pages/ and its name to PAGE_MODULES; the
order does not matter (mounting is a plain table copy).
--]]--
local PAGE_MODULES = {
    "badges_report", "shop_wallet", "kp_diagnose", "wrongbook_list",
    "wrongbook_detail", "ai_settings", "ai_bank", "update_pages",
    "recite", "words", "region", "shop_settings", "settings", "quiz",
    "summary",
}

local function mount_page(module_name)
    local page = require("ui/pages/" .. module_name)
    for name, fn in pairs(page) do
        if MainView[name] ~= nil then
            error(string.format(
                "studyassist: ui/pages/%s.lua exports '%s', which is already on MainView",
                module_name, name), 0)
        end
        if type(fn) ~= "function" then
            error(string.format(
                "studyassist: ui/pages/%s.lua exports '%s' (%s), expected a function",
                module_name, name, type(fn)), 0)
        end
        MainView[name] = fn
    end
end

for _, module_name in ipairs(PAGE_MODULES) do
    mount_page(module_name)
end

return MainView
