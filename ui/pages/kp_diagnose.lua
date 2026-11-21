--[[--
Knowledge-point learning and adaptive diagnosis pages.

Split out of ui/mainview.lua.  Every public function takes the MainView
instance as its first argument (passed implicitly when called as
self:method()); bodies are unchanged from the original MainView: methods.
The kp_* local helpers at the top are page-private and were moved here
together with the functions that use them.
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local InfoMessage = require("ui/widget/infomessage")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local VerticalGroup = require("ui/widget/verticalgroup")
local Size = require("ui/size")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")
local Knowledge = require("core.knowledge")
local Diagnose = require("core.diagnose")
local Widgets = require("ui/widgets")

local Common = require("ui/pages/common")
local GRADE_LABEL = Common.GRADE_LABEL
local KP_STATUS_MARK = Common.KP_STATUS_MARK
local KP_STATUS_LABEL = Common.KP_STATUS_LABEL
local SUBJECT_LABEL = Common.SUBJECT_LABEL
local SUBJECT_ORDER = Common.SUBJECT_ORDER
local settings_edition = Common.settings_edition
local subject_grid = Common.subject_grid
local answer_text = Common.answer_text

local M = {}

-- ---------------------------------------------------------------------------
-- Page-private helpers (used only by the functions below)
-- ---------------------------------------------------------------------------

local function kp_volume_label(grade, semester)
    grade = tonumber(grade) or 1
    local sem = semester == "lower" and "下" or "上"
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

-- ---------------------------------------------------------------------------
-- Knowledge-point pages
-- ---------------------------------------------------------------------------

function M.render_kp_subject(self)
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
        if self:subject_visible(subject, grade, semester) then
            local volume = Knowledge.load(self.plugin_path, subject, grade, semester,
                settings_edition(settings, subject))
            if volume and #volume.topics > 0 then
                table.insert(kp_subjects, subject)
            end
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

function M.render_kp_select(self, subject)
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

function M.render_kp_learn(self, subject, topic_id)
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

function M.start_kp_practice(self, subject, topic_id)
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

function M.start_kp_mixed(self, subject)
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

-- ---------------------------------------------------------------------------
-- Adaptive diagnosis
-- ---------------------------------------------------------------------------

function M.start_diagnose(self, subject, topic_id)
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

function M.diagnose_next(self)
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

function M.diagnose_submit(self, value)
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

function M.finish_diagnose(self)
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

function M.render_diagnose_quiz(self)
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

function M.render_diagnose_feedback(self)
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

function M.render_diagnose_result(self)
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

return M
