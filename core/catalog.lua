--[[--
Textbook catalog loader.

The catalog is the single runtime source of truth for provinces, grades,
textbook editions, and unit metadata.  It is intentionally plain JSON so it can
be bundled with the plugin and read without any network access.
--]]--

local JSON = require("json")
local logger = require("logger")
local util = require("util")

local Catalog = {}

local cache = {}

local function read_json(path)
    local content, err = util.readFromFile(path, "rb")
    if not content then return nil, err or ("cannot read " .. path) end
    local ok, data = pcall(JSON.decode, content)
    if not ok or type(data) ~= "table" then
        return nil, tostring(data or "invalid JSON")
    end
    return data
end

function Catalog.load(plugin_path)
    if not plugin_path or plugin_path == "" then return nil, "plugin path missing" end
    if cache[plugin_path] then return cache[plugin_path] end
    local data, err = read_json(plugin_path .. "/data/catalog.json")
    if not data then return nil, err end
    if type(data.subjects) ~= "table" or type(data.provinces) ~= "table" then
        return nil, "catalog missing subjects/provinces"
    end
    cache[plugin_path] = data
    return data
end

function Catalog.grades(plugin_path)
    local data = Catalog.load(plugin_path)
    if not data then return { 1, 2, 3, 4, 5, 6 } end
    return data.grades or { 1, 2, 3, 4, 5, 6 }
end

function Catalog.provinces(plugin_path)
    local data = Catalog.load(plugin_path)
    if not data then return {} end
    return data.provinces or {}
end

function Catalog.province(plugin_path, province_id)
    for _, item in ipairs(Catalog.provinces(plugin_path)) do
        if item.id == province_id then return item end
    end
    return nil
end

function Catalog.recommended_math(plugin_path, province_id)
    local province = Catalog.province(plugin_path, province_id)
    return province and province.default_math or "renjiao"
end

-- City-level textbook mapping (data/cities.json). 城市 -> 学科 -> 年级区间 ->
-- 教材版本，用于在设置里按「省份 + 城市 + 年级」自动匹配教材版本。
-- 数据结构（schema 3）：
--   city.s.shuxue = { { "1-6", "sujiao2024", "苏教版" }, { "7-9", "junior", "苏科版" } }
--   每项为 { 年级区间, 插件版本 id（空串=插件未收录）, 出版社中文名 }
local city_cache = {}

function Catalog.cities_data(plugin_path)
    if not plugin_path or plugin_path == "" then return nil end
    if city_cache[plugin_path] ~= nil then
        return city_cache[plugin_path] or nil
    end
    local data = read_json(plugin_path .. "/data/cities.json")
    if not data or type(data.provinces) ~= "table" then
        city_cache[plugin_path] = false
        return nil
    end
    city_cache[plugin_path] = data
    return data
end

function Catalog.cities(plugin_path, province_id)
    local data = Catalog.cities_data(plugin_path)
    local province = data and data.provinces and data.provinces[province_id]
    return province and province.cities or {}
end

function Catalog.city(plugin_path, province_id, city_id)
    if not city_id then return nil end
    for _, city in ipairs(Catalog.cities(plugin_path, province_id)) do
        if city.id == city_id then return city end
    end
    return nil
end

-- 解析 "1-6" / "4" 形式的年级区间。
local function in_range(range, grade)
    if type(range) ~= "string" or not grade then return false end
    local a, b = range:match("^(%d+)%s*%-%s*(%d+)$")
    if a then
        a, b = tonumber(a), tonumber(b)
        return grade >= a and grade <= b
    end
    return tonumber(range) == grade
end

-- 返回某城市某年级的教材匹配结果：
--   { yuwen = { edition = "tongbian", editions = { "tongbian" },
--               publisher = "统编版", range = "1-9" }, ...,
--     other = { wuli = "苏科版" } }
-- editions 为该年级该科的全部候选版本（数据里 run[2] 可为单个 id 或 id 数组）；
-- edition 为 nil 表示插件未收录该版本，publisher 仍然给出实际出版社供提示。
function Catalog.city_grade(plugin_path, province_id, city_id, grade)
    local city = Catalog.city(plugin_path, province_id, city_id)
    if not city then return nil end
    local g = tonumber(grade)
    local out = { other = city.o or {} }
    for subject, runs in pairs(city.s or {}) do
        for _, run in ipairs(runs) do
            if in_range(run[1], g) then
                local editions = {}
                local raw = run[2]
                if type(raw) == "table" then
                    for _, id in ipairs(raw) do
                        if type(id) == "string" and id ~= "" then table.insert(editions, id) end
                    end
                elseif type(raw) == "string" and raw ~= "" then
                    table.insert(editions, raw)
                end
                out[subject] = {
                    edition = editions[1],
                    editions = editions,
                    publisher = run[3],
                    range = run[1],
                }
                break
            end
        end
    end
    return out
end

-- 该学科该版本是否收录了某个年级的题库（任一学期有单元即算）。
function Catalog.edition_covers(plugin_path, subject, edition_id, grade)
    if not edition_id or not grade then return false end
    local data = Catalog.load(plugin_path)
    local subject_data = data and data.subjects and data.subjects[subject]
    local edition = subject_data and subject_data.editions and subject_data.editions[edition_id]
    if not edition then return false end
    local by_grade = edition.grades and edition.grades[tostring(grade)]
    if type(by_grade) ~= "table" then return false end
    for _, semester in pairs(by_grade) do
        if type(semester) == "table" and type(semester.units) == "table" and #semester.units > 0 then
            return true
        end
    end
    return false
end

function Catalog.editions(plugin_path, subject)
    local data = Catalog.load(plugin_path)
    if not data then return {} end
    local subject_data = data.subjects and data.subjects[subject]
    if not subject_data then return {} end
    local out = {}
    local order = subject_data.order or {}
    for _, edition_id in ipairs(order) do
        local edition = subject_data.editions and subject_data.editions[edition_id]
        if edition then
            table.insert(out, { id = edition_id, name = edition.name or edition_id })
        end
    end
    if #out == 0 then
        for edition_id, edition in pairs(subject_data.editions or {}) do
            table.insert(out, { id = edition_id, name = edition.name or edition_id })
        end
        table.sort(out, function(a, b) return a.id < b.id end)
    end
    return out
end

function Catalog.edition_name(plugin_path, subject, edition_id)
    local data = Catalog.load(plugin_path)
    local subject_data = data and data.subjects and data.subjects[subject]
    local edition = subject_data and subject_data.editions and subject_data.editions[edition_id]
    return edition and edition.name or edition_id
end

function Catalog.grade_data(plugin_path, subject, edition, grade, semester)
    local data, err = Catalog.load(plugin_path)
    if not data then return nil, err end
    local subject_data = data.subjects and data.subjects[subject]
    if not subject_data then return nil, "subject not found" end
    local edition_data = subject_data.editions and subject_data.editions[edition]
    if not edition_data then return nil, "edition not found" end
    local grade_data = edition_data.grades and edition_data.grades[tostring(grade)]
    if not grade_data then return nil, "grade not found" end
    local semester_data = grade_data[semester]
    if type(semester_data) ~= "table" then return nil, "semester not found" end
    return semester_data
end

function Catalog.units(plugin_path, subject, edition, grade, semester)
    local data, err = Catalog.grade_data(plugin_path, subject, edition, grade, semester)
    if not data then return nil, err end
    if type(data.units) ~= "table" then return nil, "units missing" end
    return data.units
end

function Catalog.bank_path(plugin_path, subject, edition, grade, semester)
    local data, err = Catalog.grade_data(plugin_path, subject, edition, grade, semester)
    if not data then return nil, err end
    if type(data.file) ~= "string" then return nil, "bank file missing" end
    return plugin_path .. "/data/" .. data.file
end

function Catalog.find_unit(plugin_path, subject, edition, grade, semester, unit_id)
    local units = Catalog.units(plugin_path, subject, edition, grade, semester)
    if not units then return nil end
    for _, unit in ipairs(units) do
        if unit.id == unit_id then return unit end
    end
    return nil
end

function Catalog.clear_cache()
    cache = {}
    logger.dbg("StudyAssist: catalog cache cleared")
end

return Catalog
