--[[--
Session construction and answer bookkeeping for StudyAssist.
--]]--

local Bank = require("core.bank")
local Catalog = require("core.catalog")
local Knowledge = require("core.knowledge")
local MathGen = require("core.mathgen")

local Session = {}
Session.__index = Session

local SUBJECTS = { "chinese", "math", "english", "physics", "chemistry",
                   "biology", "history", "geography" }

-- Fallback textbook edition per subject when settings carry no explicit
-- choice for it. Bank-backed subjects must match bank.lua's DEFAULT_EDITION.
local DEFAULT_EDITIONS = {
    chinese = "tongbian",
    math = "renjiao",
    english = "pep",
    physics = "renjiao",
    chemistry = "renjiao",
    biology = "renjiao",
    history = "tongbian",
    geography = "renjiao",
}

-- Edition to retry when the resolved edition has no bank for the current
-- grade (e.g. math "renjiao" covers 1-6, "junior" 7-9, "senior" 10-12).
local FALLBACK_EDITIONS = {
    math = { "junior", "senior" },
    -- 译林 currently ships grade 4 only; PEP covers 3-6, 人教 covers 7-12.
    english = { "pep", "yilin", "renjiao", "renjiao-senior" },
    -- 统编「老教材」只收了小学 1~6 与初三，高一~高三（以及初中 7~8）没有题库；
    -- 家长在设置里误选老教材时回落到现行统编版，别让语文整科消失。
    chinese = { "tongbian" },
    -- 高中生物目前只收人教版（必修1/2、选必1~3），选其他版本的高中没有题库，回落人教版。
    biology = { "renjiao" },
}

local function edition_for(resolved, subject)
    return resolved[subject .. "_edition"] or DEFAULT_EDITIONS[subject]
end

-- 家长在设置里手动指定过这门课的教材（不跟随地区自动匹配）。
local function manual_edition(settings, subject)
    local manual = settings and settings.edition_manual
    return type(manual) == "table" and manual[subject] == true
end

local function is_correct(question, value)
    if question.topic then
        -- Knowledge-point questions (and their wrong-book snapshots) may carry
        -- fraction/decimal answers; route them through the knowledge judge.
        return Knowledge.judge(question, value)
    end
    if question.answer_mode == "number" then
        local n = tonumber(value)
        return n ~= nil and n == question.answer
    end
    return tonumber(value) == question.answer
end

local function choose_difficulty(rng, level)
    local roll = rng(100)
    if level <= 1 then
        return roll <= 70 and 1 or 2
    elseif level >= 3 then
        if roll <= 10 then return 1 elseif roll <= 50 then return 2 else return 3 end
    end
    if roll <= 30 then return 1 elseif roll <= 80 then return 2 else return 3 end
end

local function resolved_settings(opts)
    local settings = opts.progress and opts.progress.data.settings or {}
    return {
        grade = tonumber(opts.grade) or tonumber(settings.grade) or 2,
        semester = opts.semester or settings.semester or "upper",
        chinese_edition = opts.chinese_edition or settings.chinese_edition or "tongbian",
        math_edition = opts.math_edition or settings.math_edition or "renjiao",
    }
end

-- Load a bank, retrying fallback editions when the resolved edition has no
-- data for the current grade. Returns bank, err, used_edition.
local function load_bank(plugin_path, subject, grade, semester, edition)
    local bank, err = Bank.load(plugin_path, subject, grade, semester, edition)
    if bank then return bank, nil, edition end
    for _, fb in ipairs(FALLBACK_EDITIONS[subject] or {}) do
        if fb ~= edition then
            bank, err = Bank.load(plugin_path, subject, grade, semester, fb)
            if bank then return bank, nil, fb end
        end
    end
    return nil, err, edition
end

local function unit_list(subject, semester, grade, edition, bank)
    if subject == "math" and grade <= 6 then
        return MathGen.units(grade, edition, semester) or {}
    end
    return bank and bank.units or {}
end

local function pick_bank(bank, unit, difficulty, recent, rng)
    local q = Bank.pick(bank, {
        unit = unit,
        difficulty = difficulty,
        recent_ids = recent,
        rng = rng,
    })
    if not q then
        q = Bank.pick(bank, { unit = unit, recent_ids = recent, rng = rng })
    end
    if not q then
        q = Bank.pick(bank, { unit = "all", rng = rng })
    end
    return q
end

local function math_skill_for(units, unit_id, attempt)
    for _, unit in ipairs(units) do
        if unit.id == unit_id and type(unit.skills) == "table" and #unit.skills > 0 then
            return unit.skills[((attempt - 1) % #unit.skills) + 1]
        end
    end
    return nil
end

-- Subjects that actually ship content for a grade/semester, in canonical
-- order. Entries: { subject=, bank=, units= }. Used by the UI to build the
-- subject menu and by the mixed "今日挑战" builder.
--
-- 还要过一道地区关：该地区这个年级还没开这门课（上海一年级没有沪教版数学、
-- 多数地区一年级没有英语）时跳过，不然只能拿别的出版社的题库顶上。
-- 例外：家长在设置里手动指定了教材 —— 那就按他的选择显示。
function Session.subjects_for(plugin_path, grade, semester, settings)
    settings = settings or {}
    local out = {}
    if plugin_path and plugin_path ~= "" then MathGen.set_plugin_path(plugin_path) end
    for _, subject in ipairs(SUBJECTS) do
        local manual = manual_edition(settings, subject)
        local not_started = Catalog.subject_not_started(plugin_path,
            settings.province, settings.city, subject, grade)
        if not_started and not manual then
            -- 该地区这门课从这个年级之后才开始，跳过
        else
            local entry
            if subject == "math" and grade <= 6 then
                -- 数学 1~6 年级是现场生成题，教材只决定单元名，所以必须单独确认
                -- 这一册真的存在（沪教版没有一年级，就不该出现在首页）。
                local edition = edition_for(settings, "math")
                if manual or Catalog.edition_has_volume(plugin_path, "math", edition, grade, semester) then
                    local units = MathGen.units(grade, edition, semester) or {}
                    if #units > 0 then
                        entry = { subject = subject, units = units }
                    end
                end
            else
                local bank = load_bank(plugin_path, subject, grade, semester,
                    edition_for(settings, subject))
                if bank and #bank.units > 0 then
                    entry = { subject = subject, bank = bank, units = bank.units }
                end
            end
            if entry then table.insert(out, entry) end
        end
    end
    return out
end

local function build_subject(opts)
    local resolved = resolved_settings(opts)
    local count = tonumber(opts.count) or 10
    local subject = opts.subject or "chinese"
    local semester = resolved.semester
    local grade = resolved.grade
    local rng = opts.rng or math.random
    local questions = {}
    local recent = {}
    local level = opts.progress and opts.progress:adaptive_level(subject, grade) or 2
    for _, id in ipairs(opts.progress.data.recent_ids) do recent[id] = true end

    if opts.plugin_path then MathGen.set_plugin_path(opts.plugin_path) end

    if subject ~= "math" or grade >= 7 then
        -- Generic bank-backed subject (math uses static banks for grades 7-9).
        local edition = edition_for(resolved, subject)
        local bank, err = load_bank(opts.plugin_path, subject, grade, semester, edition)
        if not bank then return nil, err end
        local units = unit_list(subject, semester, grade, edition, bank)
        if #units == 0 then return nil, "题库为空" end
        local unit = opts.unit
        if not unit or unit == "all" then
            for i = 1, count do
                local u = units[((i - 1) % #units) + 1]
                local q = pick_bank(bank, u.id, choose_difficulty(rng, level), recent, rng)
                if q then
                    table.insert(questions, q)
                    recent[q.id] = true
                end
            end
        else
            for i = 1, count do
                local q = pick_bank(bank, unit, choose_difficulty(rng, level), recent, rng)
                if q then
                    table.insert(questions, q)
                    recent[q.id] = true
                end
            end
        end
    else
        local units = unit_list("math", semester, grade, resolved.math_edition)
        if #units == 0 then return nil, "数学题库为空" end
        local unit = opts.unit
        for i = 1, count do
            local q
            if (not unit or unit == "all") and i == 6 then
                q = MathGen.generate_word_problem({
                    semester = semester,
                    grade = grade,
                    edition = resolved.math_edition,
                    difficulty = choose_difficulty(rng, level),
                }, rng)
            elseif (not unit or unit == "all") and (i == 4 or i == 8) then
                q = MathGen.generate_challenge({
                    semester = semester,
                    grade = grade,
                    edition = resolved.math_edition,
                    unit = "all",
                }, rng)
            else
                local u = (unit and unit ~= "all") and unit or units[((i - 1) % #units) + 1].id
                q = MathGen.generate({
                    semester = semester,
                    grade = grade,
                    edition = resolved.math_edition,
                    unit = u,
                    skill = math_skill_for(units, u, i),
                    difficulty = choose_difficulty(rng, level),
                }, rng)
            end
            table.insert(questions, q)
        end
    end

    if #questions == 0 then return nil, "没有可用题目" end
    return questions
end

local function build_daily(opts)
    local resolved = resolved_settings(opts)
    local semester = resolved.semester
    local grade = resolved.grade
    local rng = opts.rng or math.random
    local level_chinese = opts.progress and opts.progress:adaptive_level("chinese", grade) or 2
    local level_math = opts.progress and opts.progress:adaptive_level("math", grade) or 2
    if opts.plugin_path then MathGen.set_plugin_path(opts.plugin_path) end
    local chinese_bank = load_bank(opts.plugin_path, "chinese", grade, semester, resolved.chinese_edition)
    local recent = {}
    for _, id in ipairs(opts.progress.data.recent_ids) do recent[id] = true end

    local chinese_units = chinese_bank
        and unit_list("chinese", semester, grade, resolved.chinese_edition, chinese_bank) or {}
    -- Junior-high and senior-high math (grade >= 7) come from static banks,
    -- not MathGen.
    local math_bank
    if grade >= 7 then
        math_bank = load_bank(opts.plugin_path, "math", grade, semester,
            edition_for(resolved, "math"))
    end
    local math_units = grade >= 7
        and (math_bank and math_bank.units or {})
        or unit_list("math", semester, grade, resolved.math_edition)
    -- Daily practice mixes chinese + math; both are optional so a stage that
    -- only ships one of them still works (e.g. 高一 has no chinese bank).
    if #chinese_units == 0 and #math_units == 0 then
        return nil, "本学习阶段暂无可用题库，可在设置里切换年级"
    end
    local chinese, math_questions = {}, {}
    for i = 1, 5 do
        if #chinese_units > 0 then
            local u = chinese_units[((i - 1) % #chinese_units) + 1]
            local q = pick_bank(chinese_bank, u.id, choose_difficulty(rng, level_chinese), recent, rng)
            if q then
                table.insert(chinese, q)
                recent[q.id] = true
            end
        end
        if #math_units == 0 then
            -- no math content at this stage; skip
        elseif grade >= 7 then
            local mu = math_units[((i - 1) % #math_units) + 1]
            local mq = pick_bank(math_bank, mu.id, choose_difficulty(rng, level_math), recent, rng)
            if mq then
                table.insert(math_questions, mq)
                recent[mq.id] = true
            end
        elseif i == 4 then
            table.insert(math_questions, MathGen.generate_word_problem({
                semester = semester,
                grade = grade,
                edition = resolved.math_edition,
                difficulty = choose_difficulty(rng, level_math),
            }, rng))
        elseif i == 5 then
            table.insert(math_questions, MathGen.generate_challenge({
                semester = semester,
                grade = grade,
                edition = resolved.math_edition,
                unit = "all",
            }, rng))
        else
            local u = math_units[((i - 1) % #math_units) + 1].id
            table.insert(math_questions, MathGen.generate({
                semester = semester,
                grade = grade,
                edition = resolved.math_edition,
                unit = u,
                skill = math_skill_for(math_units, u, i),
                difficulty = choose_difficulty(rng, level_math),
            }, rng))
        end
    end

    local questions = {}
    for i = 1, 5 do
        if chinese[i] then table.insert(questions, chinese[i]) end
        if math_questions[i] then table.insert(questions, math_questions[i]) end
    end
    return questions
end

-- "今日挑战": pull `count` questions round-robin from every subject that has
-- content at this grade, so one session covers the whole stage.
local function build_mixed(opts, count)
    local resolved = resolved_settings(opts)
    local grade = resolved.grade
    local semester = resolved.semester
    local rng = opts.rng or math.random
    local target = math.max(1, math.floor(tonumber(count) or 10))
    if opts.plugin_path then MathGen.set_plugin_path(opts.plugin_path) end
    local settings = opts.progress and opts.progress.data.settings or {}
    local pools = Session.subjects_for(opts.plugin_path, grade, semester, settings)
    if #pools == 0 then
        return nil, "本学习阶段暂无可用题库，可在设置里切换年级"
    end
    local recent = {}
    for _, id in ipairs(opts.progress.data.recent_ids) do recent[id] = true end

    local questions, seen = {}, {}
    local pool_index, guard = 1, 0
    while #questions < target and guard < target * 12 do
        local pool = pools[pool_index]
        pool_index = pool_index % #pools + 1
        guard = guard + 1
        local level = opts.progress and opts.progress:adaptive_level(pool.subject, grade) or 2
        local unit = pool.units[rng(#pool.units)]
        local q
        if pool.bank then
            q = pick_bank(pool.bank, unit.id, choose_difficulty(rng, level), recent, rng)
        else
            local ok, generated = pcall(MathGen.generate, {
                semester = semester,
                grade = grade,
                edition = edition_for(resolved, "math"),
                unit = unit.id,
                skill = math_skill_for(pool.units, unit.id, #questions + 1),
                difficulty = choose_difficulty(rng, level),
            }, rng)
            if ok then q = generated end
        end
        if q and q.id and not seen[q.id] then
            seen[q.id] = true
            recent[q.id] = true
            table.insert(questions, q)
        end
    end
    if #questions == 0 then return nil, "没有可用题目" end
    return questions
end

local function build_challenge(opts)
    local resolved = resolved_settings(opts)
    local semester = resolved.semester
    local grade = resolved.grade
    local rng = opts.rng or math.random
    if opts.plugin_path then MathGen.set_plugin_path(opts.plugin_path) end
    local questions = {}
    local plan = MathGen.challenge_plan({
        semester = semester,
        unit = opts.unit,
        count = tonumber(opts.count) or 10,
        grade = grade,
    }, rng)
    for _, id in ipairs(plan) do
        local q = MathGen.generate_challenge({
            semester = semester,
            grade = grade,
            edition = resolved.math_edition,
            unit = opts.unit,
            id = id,
        }, rng)
        q.grade = grade
        q.edition = resolved.math_edition
        table.insert(questions, q)
    end
    return questions
end

--[[--
Wrong-book session with prerequisite diagnosis.

Wrong items whose knowledge point keeps failing (wrong_count >= 2, or the
point's status is "weak") trigger a prerequisite check: up to two remedial
questions from the weakest unmastered prerequisite topic are inserted before
the wrong questions, until the prerequisite shows mastery.  A single-item
redo (wrong_items passed by the caller) is diagnosed the same way.

@treturn table questions, nil error, table remedial_meta
--]]--
local function build_wrong(opts)
    local items = opts.wrong_items or opts.progress:wrong_items()
    local progress = opts.progress
    local plugin_path = opts.plugin_path
    local remedial, remedial_meta, seen = {}, {}, {}
    for _, item in ipairs(items) do
        if #remedial >= 4 then break end
        local t, sub = item.topic, item.subject
        if t and sub and plugin_path and not seen[sub .. "|" .. t]
            and ((item.wrong_count or 0) >= 2 or progress:kp_status(sub, t) == "weak") then
            seen[sub .. "|" .. t] = true
            local cands = Knowledge.remedial_candidates(plugin_path, sub, t, progress)
            local pick = cands[1]
            if pick and #pick.questions > 0 then
                table.insert(remedial_meta, {
                    subject = sub,
                    topic = t,
                    prereq_topic = pick.id,
                    prereq_name = pick.name,
                })
                for i = 1, math.min(2, #pick.questions) do
                    local q = pick.questions[i]
                    q.remedial_hint = "先修补练 · " .. pick.name
                    table.insert(remedial, q)
                end
            end
        end
    end
    local questions = {}
    for _, q in ipairs(remedial) do
        table.insert(questions, q)
    end
    for i = 1, math.min(#items, 10) do
        table.insert(questions, items[i])
    end
    return questions, nil, remedial_meta
end

function Session.new(opts)
    opts = opts or {}
    local resolved = resolved_settings(opts)
    -- 会话题数默认跟「每日目标」走；显式传入 opts.count 时以传入值为准
    if not opts.count then
        opts.count = tonumber(opts.progress and opts.progress.data.settings.daily_goal) or 10
    end
    local mode = opts.mode or "subject"
    local questions, err, remedial_meta
    if mode == "daily" then
        questions, err = build_daily(opts)
    elseif mode == "mixed" then
        questions, err = build_mixed(opts, opts.count)
    elseif mode == "challenge" then
        questions = build_challenge(opts)
    elseif mode == "wrong" then
        questions, err, remedial_meta = build_wrong(opts)
    elseif mode == "ai" then
        questions = opts.ai_questions or {}
        if #questions == 0 then questions = nil; err = "没有 AI 变种题" end
    elseif mode == "kp" then
        questions = opts.kp_questions or {}
        if #questions == 0 then questions = nil; err = "没有可用的知识点题目" end
    else
        questions, err = build_subject(opts)
    end
    if not questions then return nil, err end
    if #questions == 0 then return nil, "没有可用题目" end

    return setmetatable({
        mode = mode,
        subject = opts.subject or (mode == "challenge" and "math" or nil),
        unit = opts.unit,
        kp_topic = opts.kp_topic,
        kp_subject = opts.subject,
        remedial = remedial_meta,
        remedial_count = remedial_meta and #remedial_meta or 0,
        grade = resolved.grade,
        semester = resolved.semester,
        questions = questions,
        index = 1,
        attempt = 1,
        combo = 0,
        max_combo = 0,
        first_try_correct = 0,
        first_try_results = {},
        answered = 0,
        points = 0,
        progress = opts.progress,
        retry_enabled = opts.progress.data.settings.retry ~= false,
        now_fn = opts.now_fn or os.time,
    }, Session)
end

function Session:current()
    return self.questions[self.index]
end

function Session:total()
    return #self.questions
end

function Session:position()
    return self.index
end

function Session:submit(value)
    local q = self:current()
    if not q then return nil end
    local correct = is_correct(q, value)
    local now = self.now_fn()
    local points_result
    local combo_bonus = 0

    if self.attempt == 1 then
        self.answered = self.answered + 1
        table.insert(self.first_try_results, {
            topic = q.topic,
            subject = q.subject,
            correct = correct,
        })
        if correct then
            self.first_try_correct = self.first_try_correct + 1
            if self.mode ~= "review" then
                self.combo = self.combo + 1
                if self.combo == 3 then combo_bonus = 5
                elseif self.combo == 5 then combo_bonus = 10
                elseif self.combo == 10 then combo_bonus = 20 end
                if self.combo > self.max_combo then self.max_combo = self.combo end
            end
        else
            self.combo = 0
        end
        points_result = self.progress:record_answer(q, {
            attempt = 1,
            correct = correct,
            mode = self.mode,
            combo = self.combo,
            combo_bonus = combo_bonus,
            now = now,
        })
    else
        points_result = self.progress:record_answer(q, {
            attempt = 2,
            correct = correct,
            mode = self.mode,
            now = now,
        })
    end

    local awarded = points_result and points_result.points or 0
    self.points = self.points + awarded
    local final = correct or self.attempt >= 2 or not self.retry_enabled
    return {
        question = q,
        correct = correct,
        attempt = self.attempt,
        final = final,
        can_retry = not correct and not final,
        points = awarded,
        combo = self.combo,
        combo_bonus = combo_bonus,
        awarded = awarded,
    }
end

function Session:retry()
    if self.attempt >= 2 then return false end
    self.attempt = 2
    return true
end

function Session:give_up()
    self.attempt = 2
end

function Session:advance()
    self.index = self.index + 1
    self.attempt = 1
    return self.index <= #self.questions
end

function Session:finish()
    local perfect = self.first_try_correct == #self.questions
    local breakdown = self.progress:record_session({
        mode = self.mode,
        perfect = perfect,
        total = #self.questions,
        correct = self.first_try_correct,
    }, self.now_fn())
    self.points = self.points + (breakdown and breakdown.total or 0)
    local kp_statuses
    if self.mode == "kp" then
        kp_statuses = self.progress:finalize_kp_session(
            self.kp_subject or (self.questions[1] and self.questions[1].subject) or "math",
            self.first_try_results,
            self.kp_topic ~= nil,
            self.now_fn())
    elseif self.mode == "wrong" then
        -- 错题会话里的知识点题（含先修补练）也回写掌握状态，
        -- 这样反复错的前置知识点会随练习逐步收敛到 mastered。
        local by_subject, subject_order = {}, {}
        for _, r in ipairs(self.first_try_results) do
            if r.topic and r.subject then
                local bucket = by_subject[r.subject]
                if not bucket then
                    bucket = {}
                    by_subject[r.subject] = bucket
                    table.insert(subject_order, r.subject)
                end
                table.insert(bucket, { topic = r.topic, correct = r.correct })
            end
        end
        kp_statuses = {}
        for _, sub in ipairs(subject_order) do
            local statuses = self.progress:finalize_kp_session(
                sub, by_subject[sub], false, self.now_fn())
            for tid, st in pairs(statuses) do
                kp_statuses[sub .. "|" .. tid] = st
            end
        end
    end
    return {
        mode = self.mode,
        total = #self.questions,
        answered = self.answered,
        correct = self.first_try_correct,
        points = self.points,
        max_combo = self.max_combo,
        perfect = perfect,
        breakdown = breakdown or {},
        kp_statuses = kp_statuses,
    }
end

Session.is_correct = is_correct
Session.SUBJECTS = SUBJECTS

return Session
