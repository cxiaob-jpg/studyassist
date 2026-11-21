--[[--
Shared constants and pure helpers for StudyAssist page modules.

Extracted from ui/mainview.lua so that the split-out page modules under
ui/pages/ can reuse the same labels and helper functions without reaching
back into mainview's file-local scope.  mainview.lua re-imports these under
the same local names (see the top of that file), so the code that stays in
mainview is unchanged.

Only put things here that are used by more than one page module (or by a
page module AND mainview).  Page-private helpers live inside their own
page module.
--]]--

local Size = require("ui/size")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local Widgets = require("ui/widgets")
local util = require("util")

local Catalog = require("core.catalog")

local Common = {}

Common.SUBJECT_LABEL = { chinese = "语文", math = "数学", english = "英语",
                         physics = "物理", chemistry = "化学", biology = "生物",
                         history = "历史", geography = "地理" }

-- Bank-backed subjects shown on the home screen (math renders separately).
Common.SUBJECT_ORDER = { "chinese", "math", "english", "physics", "chemistry",
                         "biology", "history", "geography" }

-- Default edition fallbacks; must match bank.lua / session.lua.
Common.DEFAULT_EDITIONS = {
    chinese = "tongbian", math = "renjiao", english = "pep",
    physics = "renjiao", chemistry = "renjiao", biology = "renjiao",
    history = "tongbian", geography = "renjiao",
}

Common.GRADE_LABEL = { "一年级", "二年级", "三年级", "四年级", "五年级", "六年级",
                       "七年级", "八年级", "九年级" }

Common.KP_STATUS_MARK = { mastered = "★", learning = "●", weak = "▲" }
Common.KP_STATUS_LABEL = { mastered = "已掌握", learning = "继续加油", weak = "需要加强" }

-- Rounds shown per recitation / word-drill session.
Common.RECITE_ROUND = 10

-- Province/city textbook-match result keys -> plugin subject ids.  Shared by
-- mainview's city_match() and the region selection page.
Common.CITY_SUBJECTS = { yuwen = "chinese", shuxue = "math", yingyu = "english" }

function Common.settings_edition(settings, subject)
    return settings[subject .. "_edition"] or Common.DEFAULT_EDITIONS[subject]
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
Common.balanced_row_counts = balanced_row_counts

-- 学科按钮网格：按均衡行数铺开，每行按钮均分整行宽度
function Common.subject_grid(list, cw, make_button)
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

function Common.answer_text(question)
    if question.answer_mode == "number" then
        return tostring(question.answer) .. (question.unit_hint or "")
    end
    local prefix = ({ "A. ", "B. ", "C. ", "D. " })[question.answer] or ""
    return prefix .. (question.options[question.answer] or "")
end

-- Button titles only: clip long stems to a rough character budget.
function Common.truncate(text, max_chars)
    if not text then return "" end
    local max_bytes = max_chars * 3
    if #text <= max_bytes then return text end
    return util.fixUtf8(text:sub(1, max_bytes), "") .. "…"
end

-- True when at least one edition ships units for (grade, semester).
function Common.has_volume(plugin_path, subject, grade, semester)
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

return Common
