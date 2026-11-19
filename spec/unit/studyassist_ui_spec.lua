-- Timestamp on the real current date at a fixed hour, so daily-key cleanup
-- and record_answer (which use the real clock) stay aligned across describes.
local function today_at(hour)
    local t = os.date("*t")
    t.hour = hour
    t.min = 0
    t.sec = 0
    return os.time(t)
end

-- Record first-try correct math answers on the real current day.
local function record_answers(progress, count, prefix)
    for i = 1, count do
        progress:record_answer({
            id = string.format("%s-%d", prefix or "ui-gate", i),
            subject = "math", semester = "upper", unit = "m2",
            type = "math_number", skill = "add_sub", difficulty = 1,
            answer_mode = "number", stem = "1 + 1 = ?", answer = 2, explain = "1 + 1 = 2。",
        }, { attempt = 1, correct = true })
    end
end

describe("StudyAssist UI smoke", function()
    local DataStorage
    local Device
    local MainView
    local AIBank
    local view
    local ai_bank_path

    setup(function()
        require("commonrequire")
        package.path = "plugins/studyassist.koplugin/?.lua;" .. package.path
        DataStorage = require("datastorage")
        Device = require("device")
        MainView = require("ui/mainview")
        AIBank = require("core.ai_bank")
    end)

    before_each(function()
        ai_bank_path = DataStorage:getDataDir() .. "/studyassist_ui_ai_bank_spec.json"
        os.remove(ai_bank_path)
        os.remove(ai_bank_path .. ".bad")
        os.remove(ai_bank_path .. ".tmp")
        view = MainView:new{
            plugin_path = "./plugins/studyassist.koplugin",
            plugin = {},
        }
        view.ai_bank = AIBank.open(ai_bank_path)
    end)

    after_each(function()
        os.remove(ai_bank_path)
        os.remove(ai_bank_path .. ".bad")
        os.remove(ai_bank_path .. ".tmp")
    end)

    it("builds every top-level page", function()
        assert.are.equal("home", view.state)
        view:render_unit_select("chinese")
        assert.are.equal("unit_select", view.state)
        view:render_settings()
        assert.are.equal("settings", view.state)
        view:render_badges()
        assert.are.equal("badges", view.state)
        view:render_wrongbook()
        assert.are.equal("wrongbook", view.state)
        view:render_home()
        assert.are.equal("home", view.state)
    end)

    it("runs a math question through quiz and feedback pages", function()
        view:start_session({ mode = "subject", subject = "math", unit = "m2" })
        assert.are.equal("quiz", view.state)
        local q = view.session:current()
        assert.is_not_nil(q)
        view:submit_answer(q.answer)
        assert.are.equal("feedback", view.state)
        assert.is_true(view.feedback.correct)
        view:next_question()
        assert.are.equal("quiz", view.state)
    end)

    it("builds a math challenge page", function()
        view:start_session({ mode = "challenge", subject = "math", unit = "all" })
        assert.are.equal("quiz", view.state)
        local q = view.session:current()
        assert.is_true(q.challenge)
        assert.is_string(q.competency)
    end)

    it("builds a Chinese quiz page with the real bank", function()
        view:start_session({ mode = "subject", subject = "chinese", unit = "u1" })
        assert.are.equal("quiz", view.state)
        local q = view.session:current()
        assert.are.equal("chinese", q.subject)
        assert.are.equal(4, #q.options)
    end)

    it("opens province, grade and textbook selectors", function()
        view:render_settings()
        assert.are.equal("settings", view.state)
        view:render_province_select()
        assert.are.equal("choice_list", view.state)
        view:render_grade_select()
        assert.are.equal("choice_list", view.state)
        view:render_edition_select("chinese")
        assert.are.equal("choice_list", view.state)
        view:render_edition_select("math")
        assert.are.equal("choice_list", view.state)
    end)

    it("runs grade-one Chinese and grade-six math questions", function()
        view.progress.data.settings.grade = 1
        view.progress.data.settings.semester = "upper"
        view:start_session({ mode = "subject", subject = "chinese", unit = "all" })
        assert.are.equal("quiz", view.state)
        assert.are.equal(1, view.session:current().grade)

        view.progress.data.settings.grade = 6
        view.progress.data.settings.math_edition = "renjiao"
        view:start_session({ mode = "subject", subject = "math", unit = "all" })
        assert.are.equal("quiz", view.state)
        assert.are.equal(6, view.session:current().grade)
    end)

    it("builds AI settings, bank and wrong-detail AI entries", function()
        view:render_ai_settings()
        assert.are.equal("ai_settings", view.state)
        view:render_ai_preset_select()
        assert.are.equal("choice_list", view.state)
        view:render_ai_bank()
        assert.are.equal("ai_bank", view.state)
        local item = {
            id = "wrong-ai-ui", subject = "math", grade = 4, semester = "upper",
            edition = "renjiao", unit = "m2", unit_name = "测试单元",
            type = "math_choice", skill = "add_sub", difficulty = 2,
            answer_mode = "choice", stem = "1 + 1 = ?", options = { "1", "2", "3", "4" },
            answer = 2, explain = "1 + 1 = 2。",
        }
        view:render_wrong_detail(item)
        assert.are.equal("wrong_detail", view.state)
    end)

    local function find_button(widget, needle)
        if type(widget) ~= "table" then return nil end
        if type(widget.text) == "string" and widget.text:find(needle, 1, true) and widget.callback then
            return widget
        end
        for i = 1, #widget do
            local found = find_button(widget[i], needle)
            if found then return found end
        end
        return nil
    end

    it("enters AI settings from the settings page", function()
        view:render_settings()
        local button = assert(find_button(view.body, "AI 出题"))
        button.callback()
        assert.are.equal("ai_settings", view.state)
    end)

    it("paints settings and AI settings as full-screen pages", function()
        view:render_settings()
        view:paintTo(Device.screen.bb, 0, 0)
        view:render_ai_settings()
        local settings_scroll = view.body[1]
        assert.is_not_nil(settings_scroll[1])
        view:paintTo(Device.screen.bb, 0, 0)
        assert.are.equal("ai_settings", view.state)

        view:render_ai_bank()
        local bank_scroll = view.body[1]
        assert.is_not_nil(bank_scroll[1])
        view:paintTo(Device.screen.bb, 0, 0)
        assert.are.equal("ai_bank", view.state)
    end)

    it("previews a stored AI variant group", function()
        view.ai_bank:add_group({
            id = "aig-ui-1", created_at = 1760000000,
            provider = { name = "DeepSeek", model = "deepseek-chat" },
            origins = { { id = "wrong-ai-ui", subject = "math", stem = "1 + 1 = ?" } },
            questions = {
                {
                    id = "aig-ui-1-q1", origin_id = "wrong-ai-ui", ai_generated = true,
                    subject = "math", grade = 4, unit = "m2", unit_name = "测试单元",
                    type = "math_choice", skill = "add_sub", difficulty = 2,
                    answer_mode = "choice", stem = "2 + 2 = ?", options = { "3", "4", "5", "6" },
                    answer = 2, explain = "2 + 2 = 4。",
                },
            },
        })
        view:render_ai_preview("aig-ui-1")
        assert.are.equal("ai_preview", view.state)
    end)

    it("reflects the selected grade and textbook labels", function()
        view.progress.data.settings.grade = 4
        view.progress.data.settings.math_edition = "sujiao"
        assert.are.equal("四年级", view:grade_label())
        assert.are.equal("苏教版", view:edition_name("math"))
        assert.is_truthy(view:course_label():find("四年级", 1, true))
        assert.is_truthy(view:course_label():find("苏教版", 1, true))
    end)
end)

describe("StudyAssist knowledge UI smoke", function()
    local DataStorage
    local MainView
    local AIBank
    local view
    local ai_bank_path

    setup(function()
        require("commonrequire")
        package.path = "plugins/studyassist.koplugin/?.lua;" .. package.path
        DataStorage = require("datastorage")
        MainView = require("ui/mainview")
        AIBank = require("core.ai_bank")
    end)

    before_each(function()
        ai_bank_path = DataStorage:getDataDir() .. "/studyassist_ui_kp_spec_ai_bank.json"
        os.remove(ai_bank_path)
        view = MainView:new{
            plugin_path = "./plugins/studyassist.koplugin",
            plugin = {},
        }
        view.ai_bank = AIBank.open(ai_bank_path)
    end)

    after_each(function()
        os.remove(ai_bank_path)
        os.remove(ai_bank_path .. ".bad")
        os.remove(ai_bank_path .. ".tmp")
    end)

    it("builds the knowledge pages", function()
        view:render_kp_subject()
        assert.are.equal("kp_subject", view.state)
        view:render_kp_select("math")
        assert.are.equal("kp_select", view.state)
        view:render_kp_select("chinese")
        assert.are.equal("kp_select", view.state)
        view:render_kp_learn("math", "cnm_p001")
        assert.are.equal("kp_learn", view.state)
    end)

    it("runs a knowledge practice session to the summary", function()
        view:start_kp_practice("math", "cnm_p001")
        assert.are.equal("quiz", view.state)
        assert.are.equal("kp", view.session.mode)
        assert.are.equal(4, view.session:total())
        for i = 1, 4 do
            local q = view.session:current()
            view:submit_answer(q.answer)
            assert.are.equal("feedback", view.state)
            view:next_question()
        end
        assert.are.equal("summary", view.state)
        assert.is_not_nil(view.summary.kp_statuses)
    end)

    it("builds a mixed knowledge session for Chinese", function()
        view:start_kp_mixed("chinese")
        assert.are.equal("quiz", view.state)
        assert.are.equal(10, view.session:total())
        for _, q in ipairs(view.session.questions) do
            assert.are.equal("chinese", q.subject)
            assert.is_string(q.topic)
        end
    end)

    it("runs a diagnosis to the result page and persists mastery", function()
        view:start_diagnose("math", "cnm_p001")
        assert.are.equal("diagnose_quiz", view.state)
        local guard = 0
        while view.state ~= "diagnose_result" and guard < 20 do
            guard = guard + 1
            if view.state == "diagnose_quiz" then
                local q = view.diagnose_item.question
                view:submit_answer(q.answer)
                assert.are.equal("diagnose_feedback", view.state)
            elseif view.state == "diagnose_feedback" then
                view:diagnose_next()
            else
                break
            end
        end
        assert.are.equal("diagnose_result", view.state)
        assert.are.equal("mastered", view.progress:kp_status("math", "cnm_p001"))
    end)

    it("builds the extended keypad for a fraction question", function()
        view:start_session({
            mode = "kp",
            subject = "math",
            kp_topic = "cnm_p079",
            kp_questions = {
                {
                    id = "cnm_p079_q2", topic = "cnm_p079", subject = "math",
                    grade = 3, semester = "upper", unit = "u1",
                    unit_name = "分数的初步认识", type = "knowledge", skill = "数与代数",
                    difficulty = 1, answer_mode = "number", answer_format = "fraction",
                    stem = "每份是多少？", answer = "1/4", explain = "平均分成 4 份。",
                },
            },
        })
        assert.are.equal("quiz", view.state)
        assert.are.equal("fraction", view.session:current().answer_format)
        view:submit_answer("0.25")
        assert.are.equal("feedback", view.state)
        assert.is_true(view.feedback.correct)
    end)
    it("paints the knowledge pages full-screen", function()
        local Device = require("device")
        view:render_kp_select("math")
        view:paintTo(Device.screen.bb, 0, 0)
        view:render_kp_learn("math", "cnm_p001")
        view:paintTo(Device.screen.bb, 0, 0)
        view:start_diagnose("math", "cnm_p001")
        view:paintTo(Device.screen.bb, 0, 0)
        assert.are.equal("diagnose_quiz", view.state)
        local q = view.diagnose_item.question
        view:submit_answer(q.answer)
        view:paintTo(Device.screen.bb, 0, 0)
        assert.are.equal("diagnose_feedback", view.state)
        view:diagnose_next()
        view:paintTo(Device.screen.bb, 0, 0)
    end)
    it("backtracks across volumes on real data when answers are wrong", function()
        local settings = view.progress.data.settings
        local old_grade = settings.grade
        settings.grade = 3
        settings.semester = "upper"
        view:start_diagnose("math", "cnm_p079") -- 认识几分之一, hard prereq cnm_p278, soft cnm_p043 (grade 2)
        assert.are.equal("diagnose_quiz", view.state)
        local guard = 0
        while view.state ~= "diagnose_result" and guard < 30 do
            guard = guard + 1
            if view.state == "diagnose_quiz" then
                local q = view.diagnose_item.question
                local wrong = q.answer_mode == "number" and "999999"
                    or ((q.answer % #q.options) + 1)
                view:submit_answer(wrong)
            elseif view.state == "diagnose_feedback" then
                view:diagnose_next()
            else
                break
            end
        end
        assert.are.equal("diagnose_result", view.state)
        assert.are.equal("weak", view.progress:kp_status("math", "cnm_p079"))
        -- Hard prerequisite must be tested before the soft one.
        assert.are.equal("cnm_p079", view.diagnose.answers[1].topic)
        assert.are.equal("cnm_p079", view.diagnose.answers[2].topic)
        assert.are.equal("cnm_p278", view.diagnose.answers[3].topic)
        assert.is_true(#view.diagnose_summary.path > 0)
        settings.grade = old_grade
    end)
end)

describe("StudyAssist title-bar back navigation", function()
    local DataStorage
    local Device
    local MainView
    local AIBank
    local view
    local ai_bank_path

    setup(function()
        require("commonrequire")
        package.path = "plugins/studyassist.koplugin/?.lua;" .. package.path
        DataStorage = require("datastorage")
        Device = require("device")
        MainView = require("ui/mainview")
        AIBank = require("core.ai_bank")
    end)

    before_each(function()
        ai_bank_path = DataStorage:getDataDir() .. "/studyassist_ui_back_spec_ai_bank.json"
        os.remove(ai_bank_path)
        view = MainView:new{
            plugin_path = "./plugins/studyassist.koplugin",
            plugin = {},
        }
        view.ai_bank = AIBank.open(ai_bank_path)
    end)

    after_each(function()
        os.remove(ai_bank_path)
        os.remove(ai_bank_path .. ".bad")
        os.remove(ai_bank_path .. ".tmp")
    end)

    it("shows the back button only outside the home page", function()
        assert.are.equal("home", view.state)
        assert.is_nil(view.title_bar.left_icon)
        view:render_kp_select("math")
        assert.are.equal("chevron.left", view.title_bar.left_icon)
        view:render_home()
        assert.is_nil(view.title_bar.left_icon)
    end)

    it("returns second-level pages straight to home", function()
        view:render_unit_select("math")
        view:onBack()
        assert.are.equal("home", view.state)
        view:render_kp_select("chinese")
        view:onBack()
        assert.are.equal("home", view.state)
        view:render_settings()
        view:onBack()
        assert.are.equal("home", view.state)
        view:render_wrongbook()
        view:onBack()
        assert.are.equal("home", view.state)
        view:render_badges()
        view:onBack()
        assert.are.equal("home", view.state)
    end)

    it("steps up from the knowledge card to the list, then home", function()
        view:render_kp_learn("chinese", "cnc_p001")
        assert.are.equal("kp_learn", view.state)
        view:onBack()
        assert.are.equal("kp_select", view.state)
        assert.are.equal("chinese", view.kp_subject)
        view:onBack()
        assert.are.equal("home", view.state)
    end)

    it("keeps the session and asks for confirmation when backing out of a quiz", function()
        view:start_session({ mode = "subject", subject = "math", unit = "m1" })
        assert.are.equal("quiz", view.state)
        assert.are.equal("chevron.left", view.title_bar.left_icon)
        view:onBack()
        assert.are.equal("quiz", view.state) -- ConfirmBox pending, not exited
        assert.is_not_nil(view.session)
    end)

    it("honours custom back callbacks for choice lists and the AI bank", function()
        view:render_province_select()
        assert.are.equal("choice_list", view.state)
        view:onBack()
        assert.are.equal("settings", view.state)
        view:render_ai_bank(nil, function() view:render_wrongbook() end)
        assert.are.equal("ai_bank", view.state)
        view:onBack()
        assert.are.equal("wrongbook", view.state)
    end)

    it("builds the daily report without any card draw", function()
        view.progress.data.daily[os.date("%Y-%m-%d")] = nil
        view.progress:flush()
        record_answers(view.progress, 1, "ui-report")
        view:open_daily_report(today_at(20))
        assert.are.equal("daily_report", view.state)
        local report = view.progress:daily_report()
        assert.is_not_nil(report)
        assert.is_false(report.ai)
        assert.is_nil(report.cards)
        assert.is_nil(report.card_words)
        assert.are.equal("string", type(report.summary))
        assert.is_true(#report.summary > 0)
        assert.is_true((report.score or 0) >= 0)
        view:paintTo(Device.screen.bb, 0, 0)
        -- re-entering the same day shows the stored report, no regeneration
        view:open_daily_report(today_at(20))
        assert.are.equal("daily_report", view.state)
        assert.are.equal(report.created_at, view.progress:daily_report().created_at)
    end)

    it("opens the star shop and the wallet", function()
        local Shop = require("core.shop")
        view.progress.data.total.points = 100
        view:render_shop()
        assert.are.equal("shop", view.state)
        view:paintTo(Device.screen.bb, 0, 0)
        view:render_wallet()
        assert.are.equal("wallet", view.state)
        view:paintTo(Device.screen.bb, 0, 0)
        -- Redeem the cheapest wish, then the wallet lists it as pending.
        local items = Shop.items(view.progress)
        assert.is_true(#items > 0)
        local cheapest = items[1]
        for _, item in ipairs(items) do
            if item.cost < cheapest.cost then cheapest = item end
        end
        local record, err = Shop.redeem(view.progress, cheapest.id)
        assert.is_not_nil(record, err)
        assert.are.equal(1, Shop.pending_count(view.progress))
        view:render_wallet()
        assert.are.equal("wallet", view.state)
        view:paintTo(Device.screen.bb, 0, 0)
        -- Wallet back to home is a single step.
        view:render_home()
        assert.are.equal("home", view.state)
    end)

    it("keeps region and textbook setup on its own password-protected page", function()
        view:render_settings()
        assert.are.equal("settings", view.state)
        view:paintTo(Device.screen.bb, 0, 0)
        -- 学习设置是独立一页，省市 / 年级 / 学期 / 教材都在这儿
        view:render_study_settings()
        assert.are.equal("study_settings", view.state)
        view:paintTo(Device.screen.bb, 0, 0)
        -- 选完省市、年级或教材都回学习设置，不跳回设置主页
        view:return_to_settings()
        assert.are.equal("study_settings", view.state)
        view:render_settings()
        assert.are.equal("settings", view.state)
        view:return_to_settings()
        assert.are.equal("settings", view.state)
        -- 没设家长密码时进门只会弹提示，不会直接进页面
        view.progress.data.settings.parent_pin = nil
        view.progress.data.settings.exit_pin = "9999"
        view:open_study_settings_gated()
        assert.are.equal("settings", view.state)
        view:open_shop_settings_gated()
        assert.are.equal("settings", view.state)
        -- 两个密码互不影响：只设退出插件密码进不了家长区，反之亦然
        view.progress.data.settings.parent_pin = "1234"
        view:render_settings()
        assert.are.equal("settings", view.state)
        view:paintTo(Device.screen.bb, 0, 0)
    end)

    it("paginates the badge wall", function()
        view:render_badges(2)
        assert.are.equal("badges", view.state)
        assert.are.equal(2, view.badge_page)
        view:render_badges(99)
        assert.are.equal(5, view.badge_page)
        view:render_badges(0)
        assert.are.equal(1, view.badge_page)
        view:paintTo(Device.screen.bb, 0, 0)
    end)

    it("paints correctly after the title bar is rebuilt", function()
        view:render_kp_select("math")
        view:paintTo(Device.screen.bb, 0, 0)
        view:onBack()
        assert.are.equal("home", view.state)
        view:paintTo(Device.screen.bb, 0, 0)
        view:render_kp_learn("math", "cnm_p001")
        view:paintTo(Device.screen.bb, 0, 0)
    end)

    it("shows update download progress and wires the cancel button", function()
        local UIManager = require("ui/uimanager")
        local UpdateDialog = require("ui/update_dialog")
        local cancelled = 0
        local dialog = UpdateDialog:new{
            total = 2048,
            cancel_callback = function() cancelled = cancelled + 1 end,
        }
        UIManager:show(dialog)
        dialog:update_progress(0, 2048)
        dialog:update_progress(1024, 2048)
        dialog:update_progress(2048, 2048)
        dialog:paintTo(Device.screen.bb, 0, 0)
        dialog:set_installing()
        dialog:paintTo(Device.screen.bb, 0, 0)
        dialog:dismiss()
        assert.are.equal(0, cancelled) -- completing never cancels

        -- Unknown total (chunked): bytes-only status, cancel still works.
        local dialog2 = UpdateDialog:new{
            total = 0,
            cancel_callback = function() cancelled = cancelled + 1 end,
        }
        UIManager:show(dialog2)
        dialog2:update_progress(4096, 0)
        dialog2.cancel_button.callback() -- simulate tapping "取消下载"
        assert.are.equal(1, cancelled)
        dialog2:dismiss()
    end)
end)

describe("StudyAssist pin pad", function()
    local Device, UIManager, PinPadDialog

    setup(function()
        require("commonrequire")
        package.path = "plugins/studyassist.koplugin/?.lua;" .. package.path
        Device = require("device")
        UIManager = require("ui/uimanager")
        PinPadDialog = require("ui/pinpad")
    end)

    it("collects digits, masks them and auto-submits at 4", function()
        local result = "unset"
        local dialog = PinPadDialog:new{
            title = "退出插件 · 请输入 4 位密码",
            on_done = function(code) result = code end,
        }
        UIManager:show(dialog)
        assert.are.equal("○ ○ ○ ○", dialog.dots_w.text)
        dialog:press_digit("1")
        dialog:press_digit("2")
        dialog:press_digit("3")
        assert.are.equal("● ● ● ○", dialog.dots_w.text)
        assert.are.equal("unset", result) -- 未满 4 位不提交
        dialog:press_digit("4")
        assert.are.equal("1234", result)  -- 满 4 位自动提交
    end)

    it("ignores extra digits after 4 and delete/cancel report nil", function()
        local result = "unset"
        local dialog = PinPadDialog:new{
            title = "设置退出密码（4 位数字）",
            on_done = function(code) result = code end,
        }
        dialog:press_digit("1")
        dialog:press_digit("2")
        dialog:press_digit("3")
        dialog:press_delete()
        assert.are.equal("● ● ○ ○", dialog.dots_w.text)
        dialog:press_digit("9")
        dialog:press_digit("4")
        assert.are.equal("1294", result)

        local cancelled = "unset"
        local dialog2 = PinPadDialog:new{
            title = "再输入一次确认",
            on_done = function(code) cancelled = code end,
        }
        dialog2:press_digit("5")
        dialog2:press_digit("6")
        dialog2:cancel()
        assert.are.equal(nil, cancelled)
    end)
end)
