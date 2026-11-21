--[[--
AI variant bank pages: bank list and parent preview.

Split out of ui/mainview.lua.  Every function takes the MainView instance as
its first argument (passed implicitly when called as self:method()); bodies
are unchanged from the original MainView: methods.
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local ConfirmBox = require("ui/widget/confirmbox")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local Size = require("ui/size")
local Screen = require("device").screen
local Widgets = require("ui/widgets")

local Common = require("ui/pages/common")
local SUBJECT_LABEL = Common.SUBJECT_LABEL
local truncate = Common.truncate
local answer_text = Common.answer_text

local M = {}

function M.render_ai_bank(self, origin_id, back)
    self.state = "ai_bank"
    self.ai_bank_filter = origin_id
    self.ai_bank_back = back or function() self:render_home() end
    self:set_title(origin_id and "这道题的 AI 变种" or "AI 题库")
    local cw = Widgets.width()
    local bank = self:get_ai_bank()
    local groups = bank:groups(origin_id)
    local content = VerticalGroup:new{ align = "center" }
    if #groups == 0 then
        table.insert(content, Widgets.label(origin_id and "这道题还没有 AI 变种。" or "还没有 AI 变种题。", {
            size = 22, bold = true,
        }))
        table.insert(content, Widgets.vspace(Size.span.vertical_default))
        table.insert(content, Widgets.textbox(origin_id and "回到错题详情，点「AI 出 3 道变种」生成。" or "去错题本选择一道题生成，或在错题本使用「AI 强化」。", cw, {
            size = 16, alignment = "center", color = Blitbuffer.COLOR_DARK_GRAY,
        }))
        table.insert(content, Widgets.vspace(Size.span.vertical_large))
        if not self:ai_profile() then
            table.insert(content, Widgets.button("配置 AI 服务", {
                width = cw,
                height = Screen:scaleBySize(54),
                size = 19,
                callback = function() self:render_ai_settings() end,
            }))
            table.insert(content, Widgets.vspace(Size.span.vertical_default))
        end
    else
        local total_questions = 0
        for _, group in ipairs(groups) do total_questions = total_questions + #group.questions end
        table.insert(content, Widgets.label(string.format("共 %d 组 · %d 道变种题", #groups, total_questions), {
            size = 17, color = Blitbuffer.COLOR_DARK_GRAY,
        }))
        table.insert(content, Widgets.vspace(Size.span.vertical_default))
        for _, group in ipairs(groups) do
            local origin = (group.origins or {})[1] or {}
            local date = group.created_at and group.created_at > 0 and os.date("%m-%d", group.created_at) or "--"
            table.insert(content, Widgets.button(string.format("[%s] %s · %d题 · %s", SUBJECT_LABEL[origin.subject] or "题", truncate(origin.stem, 18), #group.questions, date), {
                width = cw,
                height = Screen:scaleBySize(50),
                size = 17,
                align = "left",
                callback = function() self:render_ai_preview(group.id) end,
            }))
            table.insert(content, Widgets.vspace(Size.span.vertical_default))
        end
    end
    if #groups > 0 and not origin_id then
        table.insert(content, Widgets.button("清空 AI 题库", {
            width = cw,
            height = Screen:scaleBySize(50),
            size = 18,
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = "确定清空全部 AI 变种题吗？这不会删除错题本。",
                    ok_text = "清空",
                    cancel_text = "取消",
                    ok_callback = function()
                        bank:clear()
                        self:render_ai_bank(nil, self.ai_bank_back)
                    end,
                })
            end,
        }))
        table.insert(content, Widgets.vspace(Size.span.vertical_default))
    end
    table.insert(content, Widgets.button("返回", {
        width = cw,
        size = 20,
        callback = self.ai_bank_back,
    }))
    local scroll = ScrollableContainer:new{
        dimen = self:scroll_viewport(),
        show_parent = self,
        content,
    }
    self:set_body(scroll)
end

function M.render_ai_preview(self, group_id)
    local group = self:get_ai_bank():get_group(group_id)
    if not group then
        self:render_ai_bank(self.ai_bank_filter, self.ai_bank_back)
        return
    end
    self.state = "ai_preview"
    self.ai_preview_group_id = group.id
    self:set_title("家长预览")
    local cw = Widgets.width()
    local content = VerticalGroup:new{ align = "center" }
    table.insert(content, Widgets.textbox("AI 生成内容可能有误，请家长检查后再让孩子练习。", cw, {
        size = 16, alignment = "center", bold = true,
    }))
    table.insert(content, Widgets.vspace(Size.span.vertical_default))
    local provider = group.provider or {}
    local provider_text = type(provider.name) == "string" and provider.name or "AI"
    if type(provider.model) == "string" and provider.model ~= "" then
        provider_text = provider_text .. " · " .. provider.model
    end
    local created_text = (group.created_at and group.created_at > 0) and os.date("%Y-%m-%d", group.created_at) or "未知日期"
    table.insert(content, Widgets.label(string.format("%s · %s", provider_text, created_text), {
        size = 14, color = Blitbuffer.COLOR_DARK_GRAY,
    }))
    table.insert(content, Widgets.vspace(Size.span.vertical_large))

    local origin_by_id = {}
    for _, origin in ipairs(group.origins or {}) do origin_by_id[origin.id] = origin end
    for index, question in ipairs(group.questions) do
        local origin = origin_by_id[question.origin_id] or {}
        local parts = {
            align = "left",
            Widgets.label(string.format("变种 %d · 来自：%s", index, truncate(origin.stem or "", 20)), {
                size = 15, color = Blitbuffer.COLOR_DARK_GRAY,
            }),
            Widgets.vspace(Size.span.vertical_default),
        }
        if question.passage and question.passage ~= "" then
            table.insert(parts, Widgets.textbox(question.passage, cw - 4 * Size.padding.default, { size = 16 }))
            table.insert(parts, Widgets.vspace(Size.span.vertical_default))
        end
        table.insert(parts, Widgets.textbox(question.stem, cw - 4 * Size.padding.default, { size = 20 }))
        table.insert(parts, Widgets.vspace(Size.span.vertical_default))
        local prefixes = { "A. ", "B. ", "C. ", "D. " }
        for option_index, option in ipairs(question.options or {}) do
            local mark = option_index == question.answer and "✓ " or "　 "
            table.insert(parts, Widgets.textbox(mark .. prefixes[option_index] .. option, cw - 4 * Size.padding.default, { size = 17 }))
        end
        table.insert(parts, Widgets.vspace(Size.span.vertical_default))
        table.insert(parts, Widgets.label("答案：" .. answer_text(question), { size = 17, bold = true }))
        table.insert(parts, Widgets.vspace(Size.span.vertical_default))
        table.insert(parts, Widgets.textbox(question.explain or "", cw - 4 * Size.padding.default, { size = 15, color = Blitbuffer.COLOR_DARK_GRAY }))
        table.insert(content, Widgets.card(VerticalGroup:new(parts), { width = cw, padding = Size.padding.large }))
        table.insert(content, Widgets.vspace(Size.span.vertical_large))
    end

    local scroll = ScrollableContainer:new{
        dimen = self:scroll_viewport(self:scroll_viewport().h - Screen:scaleBySize(130)),
        show_parent = self,
        content,
    }
    local body = VerticalGroup:new{
        align = "center",
        scroll,
        Widgets.vspace(Size.span.vertical_default),
        Widgets.button(string.format("开始练习（%d 题）", #group.questions), {
            width = cw,
            height = Screen:scaleBySize(58),
            size = 21,
            callback = function()
                self:start_session({ mode = "ai", ai_questions = group.questions, ai_group_id = group.id })
            end,
        }),
        Widgets.vspace(Size.span.vertical_default),
        Widgets.button("删除这组", {
            width = cw,
            height = Screen:scaleBySize(48),
            size = 18,
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = "确定删除这组 AI 变种题吗？",
                    ok_text = "删除",
                    cancel_text = "取消",
                    ok_callback = function()
                        self:get_ai_bank():remove_group(group.id)
                        self:render_ai_bank(self.ai_bank_filter, self.ai_bank_back)
                    end,
                })
            end,
        }),
        Widgets.vspace(Size.span.vertical_default),
        Widgets.button("返回 AI 题库", {
            width = cw,
            size = 20,
            callback = function() self:render_ai_bank(self.ai_bank_filter, self.ai_bank_back) end,
        }),
    }
    self:set_body(body)
end

return M
