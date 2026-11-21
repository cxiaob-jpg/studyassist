--[[--
设置页：主设置菜单 + 学习设置（省份/城市/年级/学期/教材）。

Split out of ui/mainview.lua.  Every function takes the MainView instance as
its first argument (passed implicitly when called as self:method()); bodies
are unchanged from the original MainView: methods.
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local ConfirmBox = require("ui/widget/confirmbox")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InfoMessage = require("ui/widget/infomessage")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")

local Catalog = require("core.catalog")
local Shop = require("core.shop")
local Update = require("core.update")
local Widgets = require("ui/widgets")

local Screen = require("device").screen
local _ = require("gettext")

local Common = require("ui/pages/common")
local SUBJECT_LABEL = Common.SUBJECT_LABEL
local SUBJECT_ORDER = Common.SUBJECT_ORDER
local balanced_row_counts = Common.balanced_row_counts
local has_volume = Common.has_volume

local M = {}

function M.return_to_settings(self)
    if self.settings_sub == "study" then
        self:render_study_settings()
    else
        self:render_settings()
    end
end

function M.study_summary(self)
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
        if self:subject_visible(subject, grade, settings.semester)
            and has_volume(self.plugin_path, subject, grade, settings.semester) then
            local name = self:edition_name(subject)
            if name and name ~= "" then
                local note = self:substitute_note(subject, grade)
                table.insert(books, string.format("%s %s%s", SUBJECT_LABEL[subject], name,
                    note and ("（" .. note .. "）") or ""))
            end
        end
    end
    if #books > 0 then table.insert(lines, table.concat(books, "　")) end
    return table.concat(lines, "\n")
end

function M.render_settings(self)
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

function M.open_study_settings_gated(self)
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

function M.render_study_settings(self)
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
    -- 教材：八科全列出，一行两科。没有书的（一年级没有英语、小学没有理化、
    -- 上海一年级没有数学、九年级没有生物地理）显示「暂无」，格子照样能点，
    -- 点进去可以手动指定别的版本 —— 指定后首页和知识点就出现该科。
    table.insert(content, Widgets.textbox("教材版本（可自定义选择）", cw, {
        size = 16, color = Blitbuffer.COLOR_DARK_GRAY, line_height = 0.3,
    }))
    table.insert(content, Widgets.vspace(Size.span.vertical_small or Size.span.vertical_default))
    local grade = tonumber(settings.grade) or 2
    local edition_subjects = {}
    for _, subject in ipairs(SUBJECT_ORDER) do
        table.insert(edition_subjects, subject)
    end
    local gap = Screen:scaleBySize(8)
    local function edition_tile(subject, width)
        local note = self:substitute_note(subject, grade)
        local label = self:subject_no_book(subject, grade, settings.semester)
            and "暂无" or self:edition_tile_label(subject)
        return Widgets.button(
            string.format("%s %s%s", SUBJECT_LABEL[subject], label,
                note and ("（" .. note .. "）") or ""), {
                width = width,
                height = Screen:scaleBySize(54),
                align = "left",
                size = note and 16 or 18,
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
        "点科目可以自己换版本。写「暂无」的是这个年级还没有这门课的教材（本地区没开课，或各版本都还没收录）——点进去照样能指定版本，指定后首页和知识点里就会出现该科。换完回这里核对一下，练习都按这里的设置走。", cw, {
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

return M
