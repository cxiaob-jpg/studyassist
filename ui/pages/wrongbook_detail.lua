--[[--
Single wrong-item detail page.

Split out of ui/mainview.lua.  Every function takes the MainView instance as
its first argument (passed implicitly when called as self:method()); bodies
are unchanged from the original MainView: methods.
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local VerticalGroup = require("ui/widget/verticalgroup")
local Size = require("ui/size")
local Screen = require("device").screen
local Widgets = require("ui/widgets")

local Common = require("ui/pages/common")
local SUBJECT_LABEL = Common.SUBJECT_LABEL
local answer_text = Common.answer_text

local M = {}

function M.render_wrong_detail(self, item)
    self.state = "wrong_detail"
    self:set_title("错题详情")
    local cw = Widgets.width()
    local content = VerticalGroup:new{
        align = "center",
        Widgets.card(VerticalGroup:new{
            align = "left",
            Widgets.label(string.format("%s · %s%s", SUBJECT_LABEL[item.subject] or "题", self:unit_name(item), item.competency and (" · " .. item.competency) or ""), { size = 16, color = Blitbuffer.COLOR_DARK_GRAY }),
            Widgets.vspace(Size.span.vertical_default),
            item.passage and Widgets.textbox(item.passage, cw - 4 * Size.padding.default, { size = 18 }) or Widgets.vspace(0),
            item.passage and Widgets.vspace(Size.span.vertical_default) or Widgets.vspace(0),
            Widgets.textbox(item.stem or "", cw - 4 * Size.padding.default, { size = 25 }),
            Widgets.vspace(Size.span.vertical_default),
            Widgets.label("正确答案：" .. answer_text(item), { size = 20, bold = true }),
            Widgets.vspace(Size.span.vertical_default),
            Widgets.textbox(item.explain or "", cw - 4 * Size.padding.default, { size = 17 }),
        }, { width = cw, padding = Size.padding.large }),
        Widgets.vspace(Size.span.vertical_large),
        Widgets.button("重做这道题", {
            width = cw,
            height = Screen:scaleBySize(56),
            size = 21,
            callback = function() self:start_session({ mode = "wrong", wrong_items = { item } }) end,
        }),
        Widgets.vspace(Size.span.vertical_default),
        Widgets.button(self:ai_ready() and "AI 出 3 道变种" or "AI 出 3 道变种（先配置）", {
            width = cw,
            height = Screen:scaleBySize(56),
            size = 21,
            callback = function() self:start_ai_single(item) end,
        }),
        Widgets.vspace(Size.span.vertical_default),
        (#self:get_ai_bank():groups(item.id) > 0) and Widgets.button(string.format("已有 AI 变种（%d 组）", #self:get_ai_bank():groups(item.id)), {
            width = cw,
            height = Screen:scaleBySize(50),
            size = 19,
            callback = function()
                self:render_ai_bank(item.id, function() self:render_wrong_detail(item) end)
            end,
        }) or Widgets.vspace(0),
        (#self:get_ai_bank():groups(item.id) > 0) and Widgets.vspace(Size.span.vertical_default) or Widgets.vspace(0),
        Widgets.button("返回错题本", {
            width = cw,
            size = 20,
            callback = function() self:render_wrongbook() end,
        }),
    }
    self:set_body(content)
end

return M
