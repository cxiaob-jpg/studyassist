--[[--
Badges wall and daily report pages.

Split out of ui/mainview.lua.  Every function takes the MainView instance as
its first argument (passed implicitly when called as self:method()), so the
bodies are byte-for-byte the original MainView: methods.  Cross-page calls
go through self and keep working regardless of which file a method lives in.
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local VerticalGroup = require("ui/widget/verticalgroup")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local NetworkMgr = require("ui/network/manager")
local Badges = require("core/badges")
local Report = require("core/report")
local Shop = require("core/shop")
local AIClient = require("core/ai_client")
local Widgets = require("ui/widgets")

local M = {}

function M.render_badges(self, page)
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

function M.report_parts_text(self, report)
    local parts = report.parts or {}
    return string.format("目标 %d/40 · 正确率 %d/30 · 轮次 %d/15 · 挑战 %d/10 · 知识点 %d/5 · 连续 %d/10",
        parts.goal or 0, parts.accuracy or 0, parts.sessions or 0,
        parts.challenge or 0, parts.kp or 0, parts.streak or 0)
end

-- 今日总结：第一次看时按当天数据生成一份，之后每次打开都是同一份（不再消耗任何额度）
function M.open_daily_report(self, now)
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

function M.render_daily_report(self)
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

function M.show_report_ai_error(self, message)
    UIManager:show(ConfirmBox:new{
        text = "AI 总结失败：" .. tostring(message) .. "\n\n离线总结不受影响。",
        ok_text = "重试",
        cancel_text = "看离线版",
        ok_callback = function() self:polish_daily_report() end,
    })
end

function M.polish_daily_report(self)
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

return M
