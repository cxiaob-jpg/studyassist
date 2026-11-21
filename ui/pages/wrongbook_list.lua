--[[--
Wrong-book list pages: subject overview and per-subject wrong items
(+ involved knowledge points).

Split out of ui/mainview.lua.  Every function takes the MainView instance as
its first argument (passed implicitly when called as self:method()); bodies
are unchanged from the original MainView: methods.
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local VerticalGroup = require("ui/widget/verticalgroup")
local Size = require("ui/size")
local Screen = require("device").screen
local Knowledge = require("core.knowledge")
local Widgets = require("ui/widgets")

local Common = require("ui/pages/common")
local SUBJECT_ORDER = Common.SUBJECT_ORDER
local SUBJECT_LABEL = Common.SUBJECT_LABEL
local KP_STATUS_LABEL = Common.KP_STATUS_LABEL
local truncate = Common.truncate

local M = {}

function M.render_wrongbook(self)
    self.state = "wrongbook"
    self:set_title("错题本")
    local cw = Widgets.width()
    local gap = Screen:scaleBySize(8)
    local half = math.floor((cw - gap) / 2)
    local items = self.progress:wrong_items()
    local content = VerticalGroup:new{ align = "center" }
    if #items == 0 then
        table.insert(content, Widgets.label("还没有错题，真棒！", { size = 24, bold = true }))
        table.insert(content, Widgets.vspace(Size.span.vertical_large))
        table.insert(content, Widgets.button("AI 题库", {
            width = cw,
            size = 20,
            callback = function() self:render_ai_bank(nil, function() self:render_wrongbook() end) end,
        }))
        table.insert(content, Widgets.vspace(Size.span.vertical_default))
    else
        -- 按学科分组，二级菜单进学科看错题和知识点
        local by_subject = {}
        for _, item in ipairs(items) do
            by_subject[item.subject] = (by_subject[item.subject] or 0) + 1
        end
        table.insert(content, Widgets.label(string.format("共 %d 道错题，选择学科查看详情。", #items), {
            size = 18, color = Blitbuffer.COLOR_DARK_GRAY,
        }))
        table.insert(content, Widgets.vspace(Size.span.vertical_default))
        local row, rows = {}, {}
        for _, subject in ipairs(SUBJECT_ORDER) do
            if by_subject[subject] then
                table.insert(row, Widgets.button(string.format("%s（%d）", SUBJECT_LABEL[subject], by_subject[subject]), {
                    width = half,
                    height = Screen:scaleBySize(54),
                    size = 19,
                    callback = function() self:render_wrongbook_subject(subject) end,
                }))
                if #row == 2 then
                    table.insert(rows, HorizontalGroup:new{ align = "center", row[1],
                        Widgets.hspace(gap), row[2] })
                    row = {}
                end
            end
        end
        if #row == 1 then
            table.insert(rows, HorizontalGroup:new{ align = "center", row[1],
                Widgets.hspace(gap), Widgets.vspace(0) })
        end
        for _, r in ipairs(rows) do
            table.insert(content, r)
            table.insert(content, Widgets.vspace(Size.span.vertical_default))
        end
        table.insert(content, Widgets.button("复习全部错题", {
            width = cw,
            height = Screen:scaleBySize(56),
            size = 21,
            callback = function() self:start_session({ mode = "wrong" }) end,
        }))
        table.insert(content, Widgets.vspace(Size.span.vertical_default))
        local ai_profile = self:ai_ready()
        local ai_count = math.min(#items, 5) * 2
        table.insert(content, HorizontalGroup:new{
            align = "center",
            Widgets.button(ai_profile and string.format("AI 强化（%d 题）", ai_count) or "AI 强化（先配置）", {
                width = half,
                height = Screen:scaleBySize(54),
                size = 18,
                callback = function() self:start_ai_batch() end,
            }),
            Widgets.hspace(Size.span.horizontal_default),
            Widgets.button("AI 题库", {
                width = half,
                height = Screen:scaleBySize(54),
                size = 18,
                callback = function() self:render_ai_bank(nil, function() self:render_wrongbook() end) end,
            }),
        })
        table.insert(content, Widgets.vspace(Size.span.vertical_default))
    end
    table.insert(content, Widgets.button("回首页", {
        width = cw,
        size = 20,
        callback = function() self:render_home() end,
    }))
    self:set_body(content)
end

-- 错题本二级页：某学科的错题列表 + 错题涉及的知识点（理科含前置知识点）
function M.render_wrongbook_subject(self, subject)
    self.state = "wrongbook"
    self:set_title("错题本 · " .. (SUBJECT_LABEL[subject] or subject))
    local cw = Widgets.width()
    local content = VerticalGroup:new{ align = "center" }
    local subject_items = {}
    for _, item in ipairs(self.progress:wrong_items()) do
        if item.subject == subject then table.insert(subject_items, item) end
    end
    if #subject_items == 0 then
        table.insert(content, Widgets.label("该学科暂无错题。", { size = 20, bold = true }))
    else
        table.insert(content, Widgets.label(string.format("%s 共 %d 道错题。", SUBJECT_LABEL[subject], #subject_items), {
            size = 18, color = Blitbuffer.COLOR_DARK_GRAY,
        }))
        table.insert(content, Widgets.vspace(Size.span.vertical_default))
        local shown = math.min(#subject_items, 10)
        for i = #subject_items, math.max(1, #subject_items - shown + 1), -1 do
            local item = subject_items[i]
            table.insert(content, Widgets.button(truncate(item.stem, 26), {
                width = cw,
                height = Screen:scaleBySize(50),
                size = 18,
                align = "left",
                callback = function() self:render_wrong_detail(item) end,
            }))
            table.insert(content, Widgets.vspace(Size.span.vertical_default))
        end
        table.insert(content, Widgets.button(string.format("复习%s错题（%d 题）", SUBJECT_LABEL[subject], #subject_items), {
            width = cw,
            height = Screen:scaleBySize(56),
            size = 20,
            callback = function() self:start_session({ mode = "wrong", subject = subject, wrong_items = subject_items }) end,
        }))
        table.insert(content, Widgets.vspace(Size.span.vertical_default))

        -- 知识点：错题涉及的知识点及其掌握状态；理科再列前置知识点
        local science = subject == "math" or subject == "physics"
            or subject == "chemistry" or subject == "biology"
        local graph = Knowledge.graph(self.plugin_path, subject)
        local seen_topics = {}
        for _, item in ipairs(subject_items) do
            if item.topic then seen_topics[item.topic] = true end
        end
        local kp_rows = {}
        for topic_id in pairs(seen_topics) do
            local node = graph and graph.nodes[topic_id]
            if node then
                local status = self.progress:kp_status(subject, topic_id)
                table.insert(kp_rows, { id = topic_id, name = node.name,
                    status = status, grade = node.grade })
            end
        end
        if #kp_rows > 0 then
            table.insert(content, Widgets.card(VerticalGroup:new{
                align = "left",
                Widgets.label("错题涉及的知识点", { size = 18, bold = true }),
                Widgets.vspace(Size.span.vertical_default),
            }))
            for _, kp in ipairs(kp_rows) do
                table.insert(content, Widgets.button(
                    string.format("%s · %s", kp.name, KP_STATUS_LABEL[kp.status] or "未学"), {
                    width = cw,
                    height = Screen:scaleBySize(46),
                    size = 17,
                    align = "left",
                    callback = function() self:render_kp_learn(subject, kp.id) end,
                }))
                table.insert(content, Widgets.vspace(Size.span.vertical_default))
                if science then
                    -- 前置知识点（理科承上启下）：列掌握状态，薄弱的优先补
                    for _, edge in ipairs(Knowledge.prereqs(self.plugin_path, subject, kp.id)) do
                        local pre = graph.nodes[edge.id]
                        if pre then
                            local pre_status = self.progress:kp_status(subject, edge.id)
                            if pre_status ~= "mastered" then
                                table.insert(content, Widgets.button(
                                    string.format("└ 前置：%s · %s", pre.name,
                                        KP_STATUS_LABEL[pre_status] or "未学"), {
                                    width = cw,
                                    height = Screen:scaleBySize(42),
                                    size = 15,
                                    align = "left",
                                    callback = function() self:render_kp_learn(subject, edge.id) end,
                                }))
                                table.insert(content, Widgets.vspace(Size.span.vertical_default))
                            end
                        end
                    end
                end
            end
            table.insert(content, Widgets.vspace(Size.span.vertical_default))
        end
    end
    table.insert(content, Widgets.button("回错题本", {
        width = cw,
        size = 20,
        callback = function() self:render_wrongbook() end,
    }))
    self:set_body(content)
end

return M
