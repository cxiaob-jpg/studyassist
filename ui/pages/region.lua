--[[--
地区 / 年级 / 教材选择页：省份、城市、年级、教材版本。

Split out of ui/mainview.lua.  Every function takes the MainView instance as
its first argument (passed implicitly when called as self:method()); bodies
are unchanged from the original MainView: methods.
--]]--

local Device = require("device")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local Size = require("ui/size")
local VerticalGroup = require("ui/widget/verticalgroup")

local Catalog = require("core.catalog")
local Widgets = require("ui/widgets")

local Screen = Device.screen
local _ = require("gettext")

local Common = require("ui/pages/common")
local GRADE_LABEL = Common.GRADE_LABEL
local settings_edition = Common.settings_edition
local CITY_SUBJECTS = Common.CITY_SUBJECTS

local M = {}

-- 插件只支持小学 + 初中；即使 catalog 被误写入高中年级，也不在学习设置里暴露。
local MAX_SUPPORTED_GRADE = 9

-- 城市 o 字段里记录的出版社名 → 插件版本 id（与 catalog/toc 目录一致）
local OTHER_EDITION_ID = {
    wuli = {
        ["人教版"] = "renjiao",
        ["北师大版"] = "bsd", ["北京版"] = "bsd_bj",
        ["苏科版"] = "skb", ["教科版"] = "jkb",
        ["沪科版"] = "hkb", ["沪科粤教版"] = "hkb_hy",
        ["鲁科版"] = "lkb_ws",
    },
    huaxue = {
        ["人教版"] = "renjiao",
        ["鲁教版"] = "ljb", ["沪教版"] = "hjb", ["科粤版"] = "kyyb",
    },
    dili = {
        ["人教版"] = "renjiao",
        ["湘教版"] = "xjb", ["鲁教版"] = "ljb", ["中图版"] = "ztb",
        -- 商务版、晋教版暂无完整册次目录，未收录，保持默认版本
    },
    shengwu = {
        ["人教版"] = "renjiao",
        ["苏教版"] = "sjb", ["北师大版"] = "bsd", ["苏科版"] = "skb",
        ["济南版"] = "jinan", ["鲁科版"] = "lkb",
        -- cities.json 里冀少版被记成了 "jsb"（抓取残留的出版社代码），两个都认
        ["冀少版"] = "jsb", ["jsb"] = "jsb",
    },
}
-- o 字段学科键 -> 插件学科
local OTHER_SUBJECT = { wuli = "physics", huaxue = "chemistry", dili = "geography",
                        shengwu = "biology" }
-- 各学科起始年级；低于此年级不自动设版本
local OTHER_MIN_GRADE = { wuli = 8, huaxue = 9, dili = 7, shengwu = 7 }

function M.render_choice_list(self, title, items, on_select, back)
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

function M.render_province_select(self)
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
        self:return_to_settings()
    end)
end

function M.render_city_select(self)
    local settings = self.progress.data.settings
    local cities = Catalog.cities(self.plugin_path, settings.province)
    if #cities == 0 then
        -- 还没选省份：直接退回设置（城市列表为空，没有可选项）
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

function M.apply_city_match(self)
    local settings = self.progress.data.settings
    local match = self:city_match()
    if not match then return end
    local grade = tonumber(settings.grade) or 0

    for _, key in ipairs({ "yuwen", "shuxue", "yingyu" }) do
        local subject = CITY_SUBJECTS[key]
        local item = match[key]
        if self:edition_manually_set(subject) then
            -- 家长手动指定过教材：自动匹配不覆盖他的选择
        elseif not item then
            -- 映射里这一册没有：这门课还没开的年级要清掉上一册匹配到的版本，
            -- 否则它会被当成「已指定」继续显示；源站没抓到的册保持原设置。
            local start = Catalog.subject_start_grade(self.plugin_path,
                settings.province, settings.city, subject)
            if start and grade < start then
                settings[subject .. "_edition"] = nil
            end
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
            else
                settings[subject .. "_edition"] = item.edition
            end
        end
    end

    -- 物理等 o 字段学科：出版社名 → 版本 id，按年级下限自动设置
    if match.other and next(match.other) then
        for okey, publisher in pairs(match.other) do
            local idmap = OTHER_EDITION_ID[okey]
            local min_grade = OTHER_MIN_GRADE[okey]
            if idmap and publisher and (not min_grade or grade >= min_grade) then
                local eid = idmap[publisher]
                local subject = OTHER_SUBJECT[okey]
                -- 只在该版本确实收录当前年级时才应用；家长手动指定过的也不覆盖

                if eid and subject and not self:edition_manually_set(subject)
                    and Catalog.edition_covers(self.plugin_path, subject, eid, grade) then
                    settings[subject .. "_edition"] = eid
                end
            end
        end
    end

    self.progress:flush()
    self:return_to_settings()
end

function M.render_grade_select(self)
    local settings = self.progress.data.settings
    local items = {}
    for _, grade in ipairs(Catalog.grades(self.plugin_path)) do
        grade = tonumber(grade)
        if grade and grade >= 1 and grade <= MAX_SUPPORTED_GRADE then
            table.insert(items, {
                id = grade,
                name = GRADE_LABEL[grade] or (grade .. "年级"),
                selected = tonumber(settings.grade) == grade,
            })
        end
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

function M.render_edition_select(self, subject)
    local settings = self.progress.data.settings
    local current = settings_edition(settings, subject)
    local rec = self:recommended_edition(subject)
    local items = {}
    local manual = self:edition_manually_set(subject)
    if rec then
        -- 第一条 = 地区推荐的版本（点它等于跟随地区，会清掉手动指定）
        table.insert(items, {
            id = rec,
            follow_region = true,
            name = string.format("%s%s｜%s%s使用", self:edition_name_of(subject, rec),
                self:edition_term_suffix(subject, rec),
                self:city_label(), self:grade_label() .. self:semester_label()),
            selected = current == rec and not manual,
        })
    end
    -- 同一出版社有新老两套时，按这一册的版次只列适用的那个；
    -- 并且只列该年级确实有内容的版本（避免一年级选到不覆盖本年级的出版社）
    local term_list = Catalog.editions_for_term(self.plugin_path, subject,
        settings.grade, settings.semester)
    local covering = {}
    for _, edition in ipairs(term_list) do
        if Catalog.edition_covers(self.plugin_path, subject, edition.id, settings.grade) then
            table.insert(covering, edition)
        end
    end
    for _, edition in ipairs(covering) do
        if edition.id ~= rec then
            table.insert(items, {
                id = edition.id,
                name = edition.name .. self:edition_term_suffix(subject, edition.id),
                selected = current == edition.id and manual,
            })
        end
    end
    -- 手动指定过的科目给一条撤销入口（只在真的指定过时出现）
    if manual then
        table.insert(items, {
            id = "__auto__",
            clear_manual = true,
            name = "取消指定（恢复跟随地区）",
        })
    end
    if #covering == 0 then
        -- 一册都没有：列表只剩「取消指定」或空列表，不再弹提示说明
        if #items == 0 then
            self:return_to_settings()
            return
        end
    end
    self:render_choice_list(self:subject_label(subject) .. "教材", items, function(item)
        settings.edition_manual = settings.edition_manual or {}
        if item.clear_manual then
            -- 取消指定：版本回到自动匹配（本地区没这门课就是「暂无」）
            settings[subject .. "_edition"] = nil
            settings.edition_manual[subject] = nil
        elseif item.follow_region then
            -- 选了地区推荐版本 = 跟随地区，不再算手动指定
            settings[subject .. "_edition"] = item.id
            settings.edition_manual[subject] = nil
        else
            -- 手动指定：钉住这个版本，地区没开课也照常显示
            settings[subject .. "_edition"] = item.id
            settings.edition_manual[subject] = true
        end
        self.progress:flush()
        self:return_to_settings()
    end)
end

return M
