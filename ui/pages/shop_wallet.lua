--[[--
Star shop and wallet pages.

Split out of ui/mainview.lua.  Every function takes the MainView instance as
its first argument (passed implicitly when called as self:method()); bodies
are unchanged from the original MainView: methods.
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local VerticalGroup = require("ui/widget/verticalgroup")
local Size = require("ui/size")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")
local Shop = require("core/shop")
local Widgets = require("ui/widgets")

local M = {}

--[[--
星星商城：家长在设置里准备的愿望卡券，孩子用答题赚来的星星兑换。换到的卡券进
钱包，兑现要给家长看，并输入密码，孩子没法自己把奖励「花掉」。
--]]--
function M.render_shop(self)
    self.state = "shop"
    self:set_title("星星商城")
    local cw = Widgets.width()
    local balance = Shop.balance(self.progress)
    local items = Shop.items(self.progress)
    local content = VerticalGroup:new{ align = "center" }

    table.insert(content, Widgets.card(VerticalGroup:new{
        align = "center",
        Widgets.label(string.format("★ %d", balance), { size = 40, bold = true }),
        Widgets.label("可用星星", { size = 16, color = Blitbuffer.COLOR_DARK_GRAY }),
        Widgets.vspace(Size.span.vertical_default),
        Widgets.textbox("答对题目就能赚星星，攒够了换一张卡券；换到的卡券放在钱包里，找家长兑现。",
            cw - 4 * Size.padding.default, {
                size = 15, alignment = "center", color = Blitbuffer.COLOR_DARK_GRAY,
            }),
    }, { width = cw, padding = Size.padding.large }))
    table.insert(content, Widgets.vspace(Size.span.vertical_large))

    if #items == 0 then
        table.insert(content, Widgets.textbox(
            "商城还空着。\n家长可以在「设置 → 商城后台」里把愿望做成卡券（需要密码）。", cw, {
                size = 18, alignment = "center",
            }))
        table.insert(content, Widgets.vspace(Size.span.vertical_default))
    else
        table.insert(content, Widgets.label(string.format("在售卡券（%d）", #items), {
            size = 17, color = Blitbuffer.COLOR_DARK_GRAY,
        }))
        table.insert(content, Widgets.vspace(Size.span.vertical_default))
        -- 一行三张卡：宽度均分整行，高度固定成正方形，行与行始终整齐；
        -- 名字过长时卡内自动换行（最多两行）。
        local gap = Size.span.horizontal_default
        local pad = Size.padding.default
        local cols = 3
        local colw = math.floor((cw - (cols - 1) * gap) / cols)
        local cardh = colw
        local inner = colw - 2 * (pad + Size.border.thin)
        local function coupon_card(item)
            local affordable = balance >= item.cost
            local body = VerticalGroup:new{
                align = "center",
                Widgets.textbox(item.name, inner, {
                    size = 15, alignment = "center", line_height = 0.2, max_lines = 2,
                }),
                Widgets.vspace(Size.span.vertical_small or Size.span.vertical_default),
                Widgets.label(string.format("★ %d", item.cost), {
                    size = 17, bold = true,
                    color = affordable and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY,
                }),
                Widgets.vspace(Size.span.vertical_small or Size.span.vertical_default),
                Widgets.button(affordable and "兑换"
                        or string.format("差 %d 星", item.cost - balance), {
                    width = inner,
                    size = 15,
                    callback = function() self:redeem_shop_item(item.id) end,
                }),
            }
            return Widgets.card(body, { width = colw, height = cardh, padding = pad })
        end
        local idx = 1
        while idx <= #items do
            local row = HorizontalGroup:new{ align = "top" }
            for i = idx, math.min(idx + cols - 1, #items) do
                if i > idx then table.insert(row, Widgets.hspace(gap)) end
                table.insert(row, coupon_card(items[i]))
            end
            table.insert(content, row)
            table.insert(content, Widgets.vspace(Size.span.vertical_default))
            idx = idx + cols
        end
    end

    table.insert(content, Widgets.vspace(Size.span.vertical_default))
    table.insert(content, Widgets.button("我的钱包", {
        width = cw,
        size = 20,
        callback = function() self:render_wallet() end,
    }))
    table.insert(content, Widgets.vspace(Size.span.vertical_default))
    table.insert(content, Widgets.button("返回首页", {
        width = cw,
        size = 20,
        callback = function() self:render_home() end,
    }))
    self:set_body(ScrollableContainer:new{
        dimen = self:scroll_viewport(),
        show_parent = self,
        content,
    })
end

-- 兑换要二次确认：先说清楚花多少、还剩多少，避免孩子连点把星星一次花光。
function M.redeem_shop_item(self, item_id)
    local item = Shop.find(self.progress, item_id)
    if not item or not item.enabled then
        UIManager:show(InfoMessage:new{ text = "这张卡券已经下架或删除。", timeout = 3 })
        self:render_shop()
        return
    end
    local balance = Shop.balance(self.progress)
    if balance < item.cost then
        UIManager:show(InfoMessage:new{
            text = string.format("还差 %d 颗星星", item.cost - balance), timeout = 3,
        })
        self:render_shop()
        return
    end
    UIManager:show(ConfirmBox:new{
        text = string.format("确定兑换「%s」吗？\n\n要花 ★%d，换完还剩 ★%d。\n卡券会放进钱包，找家长兑现时要输密码。",
            item.name, item.cost, balance - item.cost),
        ok_text = "确认兑换",
        cancel_text = "再想想",
        ok_callback = function() self:do_redeem_shop_item(item_id) end,
    })
end

function M.do_redeem_shop_item(self, item_id)
    local record, err = Shop.redeem(self.progress, item_id)
    if not record then
        UIManager:show(InfoMessage:new{ text = tostring(err), timeout = 3 })
        self:render_shop()
        return
    end
    self:render_shop()
    UIManager:show(ConfirmBox:new{
        text = string.format("兑换成功！\n\n「%s」已放进钱包，花掉 ★%d。\n找家长兑现时，家长要输入密码。",
            record.name, record.cost),
        ok_text = "去钱包看看",
        cancel_text = "继续逛",
        ok_callback = function() self:render_wallet() end,
    })
end

--[[--
钱包：星星余额 + 已兑换的卡券。待兑现的卡券要点「找家长兑现」，输入 4 位密码
才算用掉；没有设置密码时不让兑现，先引导家长去设置。
--]]--
function M.render_wallet(self)
    self.state = "wallet"
    self:set_title("钱包")
    local cw = Widgets.width()
    local balance = Shop.balance(self.progress)
    local spent = Shop.spent(self.progress)
    local earned = self.progress.data.total.points or 0
    local records = Shop.redeemed(self.progress)
    local pending = Shop.pending_count(self.progress)
    local content = VerticalGroup:new{ align = "center" }

    table.insert(content, Widgets.card(VerticalGroup:new{
        align = "center",
        Widgets.label(string.format("★ %d", balance), { size = 40, bold = true }),
        Widgets.label("可用星星", { size = 16, color = Blitbuffer.COLOR_DARK_GRAY }),
        Widgets.vspace(Size.span.vertical_default),
        Widgets.label(string.format("累计获得 ★%d · 已兑换花掉 ★%d", earned, spent), {
            size = 15, color = Blitbuffer.COLOR_DARK_GRAY,
        }),
    }, { width = cw, padding = Size.padding.large }))
    table.insert(content, Widgets.vspace(Size.span.vertical_large))

    if #records == 0 then
        table.insert(content, Widgets.textbox("钱包里还没有卡券。\n去星星商城用星星换一张愿望卡券吧。", cw, {
            size = 18, alignment = "center",
        }))
        table.insert(content, Widgets.vspace(Size.span.vertical_default))
    else
        local title = string.format("我的卡券（%d 张", #records)
        if pending > 0 then title = title .. string.format("，%d 张待兑现", pending) end
        title = title .. "）"
        table.insert(content, Widgets.label(title, { size = 17, color = Blitbuffer.COLOR_DARK_GRAY }))
        table.insert(content, Widgets.vspace(Size.span.vertical_default))

        local right_w = math.min(Screen:scaleBySize(140), math.floor(cw * 0.34))
        local left_w = cw - right_w - Size.span.horizontal_default - 2 * Size.padding.default
        for _, record in ipairs(records) do
            local info = VerticalGroup:new{
                align = "left",
                Widgets.label(record.name, { size = 19, bold = true, max_width = left_w }),
                Widgets.label(string.format("★ %d · %s", record.cost,
                    os.date("%m月%d日", record.at or os.time())), {
                    size = 14, color = Blitbuffer.COLOR_DARK_GRAY,
                }),
            }
            local right
            if record.cashed then
                right = Widgets.textbox(string.format("已兑现\n%s", os.date("%m月%d日",
                    record.cashed_at or record.at or os.time())), right_w, {
                    size = 14, color = Blitbuffer.COLOR_DARK_GRAY, alignment = "center",
                })
            else
                right = Widgets.button("找家长兑现", {
                    width = right_w,
                    size = 17,
                    callback = function() self:cash_coupon(record.id) end,
                })
            end
            table.insert(content, Widgets.card(HorizontalGroup:new{
                align = "center",
                info,
                Widgets.hspace(Size.span.horizontal_default),
                right,
            }, { width = cw, padding = Size.padding.default }))
            table.insert(content, Widgets.vspace(Size.span.vertical_default))
        end

        table.insert(content, Widgets.label("兑现就是家长把这份奖励真的给孩子：点「找家长兑现」，由家长输入密码。", {
            size = 14, color = Blitbuffer.COLOR_DARK_GRAY, max_width = cw, alignment = "center",
        }))
        table.insert(content, Widgets.vspace(Size.span.vertical_default))
    end

    table.insert(content, Widgets.button("看今日总结", {
        width = cw,
        size = 20,
        callback = function() self:open_daily_report() end,
    }))
    table.insert(content, Widgets.vspace(Size.span.vertical_default))
    table.insert(content, Widgets.button("去星星商城", {
        width = cw,
        size = 20,
        callback = function() self:render_shop() end,
    }))
    table.insert(content, Widgets.vspace(Size.span.vertical_default))
    table.insert(content, Widgets.button("返回首页", {
        width = cw,
        size = 20,
        callback = function() self:render_home() end,
    }))
    self:set_body(ScrollableContainer:new{
        dimen = self:scroll_viewport(),
        show_parent = self,
        content,
    })
end

function M.cash_coupon(self, record_id)
    local record = Shop.find_record(self.progress, record_id)
    if not record then
        UIManager:show(InfoMessage:new{ text = "找不到这张卡券。", timeout = 3 })
        self:render_wallet()
        return
    end
    if record.cashed then
        UIManager:show(InfoMessage:new{ text = "这张卡券已经兑现过了。", timeout = 3 })
        return
    end
    local pin = self.progress.data.settings.parent_pin
    if not pin or #tostring(pin) ~= 4 then
        UIManager:show(ConfirmBox:new{
            text = "兑现卡券需要家长密码。\n\n现在还没有设置家长密码，先去设置一个吧——这样孩子就不能自己点兑现了。",
            ok_text = "去设置家长密码",
            cancel_text = "稍后",
            ok_callback = function()
                self:render_pin_settings("parent", function() self:render_wallet() end)
            end,
        })
        return
    end
    self:ask_pin_input(string.format("兑现「%s」· 请输入家长密码", record.name), function(text)
        if text == nil then return end
        if tostring(text) ~= tostring(pin) then
            UIManager:show(InfoMessage:new{ text = "密码不对，未兑现。", timeout = 3 })
            return
        end
        local done, err = Shop.cash(self.progress, record_id)
        if not done then
            UIManager:show(InfoMessage:new{ text = tostring(err), timeout = 3 })
            return
        end
        UIManager:show(InfoMessage:new{
            text = string.format("「%s」已兑现 ✓\n记得把这份奖励给孩子。", done.name),
            timeout = 4,
        })
        self:render_wallet()
    end)
end

return M
