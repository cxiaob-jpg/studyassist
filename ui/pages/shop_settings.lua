--[[--
商城后台（家长区）：商品上下架、改价、删除与新增，进入前需要家长密码。

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

local Shop = require("core.shop")
local Widgets = require("ui/widgets")

local Screen = require("device").screen
local _ = require("gettext")

local M = {}

function M.open_shop_settings_gated(self)
    local pin = self.progress.data.settings.parent_pin
    if not pin or #tostring(pin) ~= 4 then
        UIManager:show(ConfirmBox:new{
            text = "「商城后台」是家长设置区，需要家长密码才能进入。\n\n现在还没有设置家长密码，先去设置一个吧。",
            ok_text = "去设置家长密码",
            cancel_text = "稍后",
            ok_callback = function()
                self:render_pin_settings("parent", function() self:render_shop_settings() end)
            end,
        })
        return
    end
    self:ask_pin_input("商城后台 · 请输入家长密码", function(text)
        if text == nil then return end
        if tostring(text) ~= tostring(pin) then
            UIManager:show(InfoMessage:new{ text = "密码不对，未进入。", timeout = 3 })
            return
        end
        self:render_shop_settings()
    end)
end

function M.render_shop_settings(self)
    self.state = "shop_settings"
    self:set_title("商城后台")
    local cw = Widgets.width()
    local items = Shop.all_items(self.progress)
    local on_sale = 0
    for _, item in ipairs(items) do
        if item.enabled then on_sale = on_sale + 1 end
    end
    local content = VerticalGroup:new{
        align = "center",
        Widgets.textbox(string.format(
            "这些卡券会出现在孩子的星星商城里，用星星兑换。现在有 %d 件在售。\n点卡券上的名字可以改星星数（1~9999 随便定）；下架只是孩子看不到，已兑换的卡券不受影响。",
            on_sale), cw, {
            size = 15, color = Blitbuffer.COLOR_DARK_GRAY, line_height = 0.35,
        }),
        Widgets.vspace(Size.span.vertical_default),
    }

    if #items == 0 then
        table.insert(content, Widgets.textbox("还没有商品，点下面的「添加商品」加一个。", cw, {
            size = 17, alignment = "center",
        }))
        table.insert(content, Widgets.vspace(Size.span.vertical_default))
    end

    -- 一行一张卡：左边卡券名 + 星星数（点一下改价），右边「下架/上架」「删除」两个窄按钮
    local pad = Size.padding.default
    local inner = cw - 2 * (pad + Size.border.thin)
    local btn_gap = Screen:scaleBySize(12)
    local btn_w = Screen:scaleBySize(96)
    local btn_h = Screen:scaleBySize(50)
    local btn_pad = Screen:scaleBySize(4)
    local info_w = inner - 2 * btn_w - 2 * btn_gap

    local function admin_card(item)
        local captured = item
        local info = Widgets.tappable(VerticalGroup:new{
            align = "left",
            Widgets.textbox(item.name, info_w, {
                size = 17, line_height = 0.15, max_lines = 2,
                color = item.enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY,
            }),
            Widgets.vspace(Size.span.vertical_small or Size.span.vertical_default),
            Widgets.label(string.format("★ %d%s", item.cost,
                item.enabled and "" or "（已下架）"), {
                size = 14, color = Blitbuffer.COLOR_DARK_GRAY, max_width = info_w,
            }),
        }, function() self:edit_shop_cost(captured) end)
        local body = HorizontalGroup:new{
            align = "center",
            info,
            Widgets.hspace(btn_gap),
            Widgets.button(item.enabled and "下架" or "上架", {
                width = btn_w,
                height = btn_h,
                size = 15,
                padding = btn_pad,
                callback = function()
                    Shop.set_enabled(self.progress, captured.id, not captured.enabled)
                    self:render_shop_settings()
                end,
            }),
            Widgets.hspace(btn_gap),
            Widgets.button("删除", {
                width = btn_w,
                height = btn_h,
                size = 15,
                padding = btn_pad,
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = string.format("从商城删除「%s」？\n已兑换的卡券还在钱包里。", captured.name),
                        ok_text = "删除",
                        cancel_text = "保留",
                        ok_callback = function()
                            Shop.remove_item(self.progress, captured.id)
                            self:render_shop_settings()
                        end,
                    })
                end,
            }),
        }
        return Widgets.card(body, { width = cw, padding = pad })
    end

    for _, item in ipairs(items) do
        table.insert(content, admin_card(item))
        table.insert(content, Widgets.vspace(Size.span.vertical_default))
    end

    table.insert(content, Widgets.vspace(Size.span.vertical_default))
    table.insert(content, Widgets.button("＋ 添加商品", {
        width = cw,
        height = Screen:scaleBySize(54),
        size = 19,
        callback = function() self:add_shop_item_dialog() end,
    }))
    table.insert(content, Widgets.vspace(Size.span.vertical_default))
    table.insert(content, Widgets.button("返回设置", {
        width = cw,
        size = 20,
        callback = function() self:render_settings() end,
    }))
    self:set_body(ScrollableContainer:new{
        dimen = self:scroll_viewport(),
        show_parent = self,
        content,
    })
end

function M.edit_shop_cost(self, item)
    self:open_ai_text_input(string.format("「%s」要多少颗星星？（填数字，1~9999）", item.name),
        tostring(item.cost), false, function(value)
            local updated, err = Shop.set_cost(self.progress, item.id, value)
            if not updated then
                UIManager:show(InfoMessage:new{ text = tostring(err), timeout = 4 })
                return
            end
            UIManager:show(InfoMessage:new{
                text = string.format("%s　★%d", updated.name, updated.cost), timeout = 3,
            })
            self:render_shop_settings()
        end)
end

function M.add_shop_item_dialog(self)
    self:open_ai_text_input("商品名称（没有中文输入法可打拼音）", "", false, function(text)
        local name = tostring(text or "")
        if name:gsub("%s", "") == "" then
            UIManager:show(InfoMessage:new{ text = "没有输入商品名称", timeout = 3 })
            return
        end
        self:open_ai_text_input("需要多少颗星星？（填数字）", "", false, function(value)
            local item, err, existed = Shop.add_item(self.progress, name, value)
            if not item then
                UIManager:show(InfoMessage:new{ text = tostring(err), timeout = 4 })
                return
            end
            UIManager:show(InfoMessage:new{
                text = string.format("%s：%s　★%d", existed and "已更新" or "已添加", item.name, item.cost),
                timeout = 3,
            })
            self:render_shop_settings()
        end)
    end)
end

return M
