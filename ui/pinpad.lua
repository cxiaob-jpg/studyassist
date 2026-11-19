--[[--
Numeric pin pad dialog (3x4 digit grid, no virtual keyboard).

Used for the exit PIN and progress reset PIN. Tapping digits fills a masked
progress line; at 4 digits the entry auto-submits and calls `on_done(code)`.
Tapping 取消 (or the hardware Back key) calls `on_done(nil)`.
Renders as a small centered popup (ConfirmBox-style transparent fullscreen
container); taps outside the keypad are swallowed, not forwarded below.
Built only from KOReader built-in widgets, consistent with the plugin's
zero-dependency rule.
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

local Screen = Device.screen

local PinPadDialog = InputContainer:extend{
    name = "pinpad",
    title = "请输入 4 位密码",
    on_done = nil, -- function(code_or_nil)
    modal = true,
    covers_fullscreen = false,
}

function PinPadDialog:init()
    self.code = ""
    self.dismissed = false
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()

    local btn_w = math.floor(screen_w * 0.17)
    local btn_h = math.floor(screen_h * 0.075)
    local gap = math.floor(btn_w * 0.22)
    local pad = Size.padding.large
    local grid_w = btn_w * 3 + gap * 2

    local title_w = TextWidget:new{
        text = self.title,
        face = Font:getFace("cfont", math.floor(screen_h * 0.028)),
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    self.dots_w = TextWidget:new{
        text = "○ ○ ○ ○",
        face = Font:getFace("cfont", math.floor(screen_h * 0.034)),
        fgcolor = Blitbuffer.COLOR_BLACK,
    }

    local function make_btn(text, callback)
        return Button:new{
            text = text,
            width = btn_w,
            height = btn_h,
            bordersize = Size.border.default,
            radius = Size.radius.default,
            text_font_size = math.floor(btn_h * 0.48),
            text_font_bold = true,
            callback = callback,
        }
    end

    local function grid_row(cells)
        local hg = HorizontalGroup:new{}
        for i, cell in ipairs(cells) do
            if i > 1 then
                table.insert(hg, HorizontalSpan:new{ width = gap })
            end
            table.insert(hg, cell)
        end
        return CenterContainer:new{
            dimen = Geom:new{ w = grid_w, h = btn_h },
            hg,
        }
    end

    local body = VerticalGroup:new{}
    table.insert(body, CenterContainer:new{
        dimen = Geom:new{ w = grid_w, h = title_w:getSize().h },
        title_w,
    })
    table.insert(body, VerticalSpan:new{ width = pad })
    table.insert(body, CenterContainer:new{
        dimen = Geom:new{ w = grid_w, h = self.dots_w:getSize().h },
        self.dots_w,
    })
    table.insert(body, VerticalSpan:new{ width = pad * 1.5 })

    local rows = {
        { "1", "2", "3" },
        { "4", "5", "6" },
        { "7", "8", "9" },
        { "删除", "0", "取消" },
    }
    for _, row in ipairs(rows) do
        local cells = {}
        for _, label in ipairs(row) do
            if label == "删除" then
                cells[#cells + 1] = make_btn(label, function()
                    self:press_delete()
                end)
            elseif label == "取消" then
                cells[#cells + 1] = make_btn(label, function()
                    self:cancel()
                end)
            else
                cells[#cells + 1] = make_btn(label, function()
                    self:press_digit(label)
                end)
            end
        end
        table.insert(body, grid_row(cells))
        table.insert(body, VerticalSpan:new{ width = gap })
    end

    local frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        radius = Size.radius.window,
        padding = pad,
        margin = 0,
        body,
    }
    -- ConfirmBox 同款居中小窗：透明全屏容器只负责居中 + 覆盖手势，
    -- 不铺全屏白底（整屏白板在 e-ink 上会出现局部漏刷）。
    self[1] = CenterContainer:new{
        dimen = Screen:getSize(),
        frame,
    }

    -- Back 键取消（有实体键的设备）
    self.key_events.Close = { { Device.input.group.Back } }
    -- 按钮之外的点击不穿透到下层视图
    self.stop_events_propagation = true
end

function PinPadDialog:refresh_dots()
    local parts = {}
    for i = 1, 4 do
        parts[i] = (i <= #self.code) and "●" or "○"
    end
    self.dots_w:setText(table.concat(parts, " "))
end

function PinPadDialog:press_digit(d)
    if self.dismissed or #self.code >= 4 then return end
    self.code = self.code .. d
    self:refresh_dots()
    UIManager:setDirty(self, "partial")
    if #self.code == 4 then
        self:finish(self.code)
    end
end

function PinPadDialog:press_delete()
    if self.dismissed or #self.code == 0 then return end
    self.code = self.code:sub(1, -2)
    self:refresh_dots()
    UIManager:setDirty(self, "partial")
end

function PinPadDialog:finish(code)
    if self.dismissed then return end
    self.dismissed = true
    UIManager:close(self)
    if self.on_done then
        self.on_done(code)
    end
end

function PinPadDialog:cancel()
    self:finish(nil)
end

function PinPadDialog:onClose()
    self:cancel()
    return true
end

function PinPadDialog:onCloseWidget()
    UIManager:setDirty(nil, "ui")
end

return PinPadDialog
