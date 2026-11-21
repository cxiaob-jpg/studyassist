--[[--
一轮练习的结算页：得分、星星、连对、新奖章与下一步操作。

Split out of ui/mainview.lua.  The function takes the MainView instance as its
first argument (passed implicitly when called as self:method()); the body is
unchanged from the original MainView: method.
--]]--

local Device = require("device")
local Blitbuffer = require("ffi/blitbuffer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local Size = require("ui/size")
local VerticalGroup = require("ui/widget/verticalgroup")

local Knowledge = require("core.knowledge")
local Widgets = require("ui/widgets")

local Screen = Device.screen
local _ = require("gettext")

local Common = require("ui/pages/common")
local KP_STATUS_LABEL = Common.KP_STATUS_LABEL

local M = {}

function M.render_summary(self)
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
return M
