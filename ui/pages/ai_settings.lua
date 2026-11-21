--[[--
AI settings pages: service list, preset picker, and per-service editor.

Split out of ui/mainview.lua.  Every function takes the MainView instance as
its first argument (passed implicitly when called as self:method()); bodies
are unchanged from the original MainView: methods.
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local Size = require("ui/size")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")
local AIConfig = require("core/ai_config")
local Widgets = require("ui/widgets")

local M = {}

function M.render_ai_settings(self)
    self.state = "ai_settings"
    self:set_title("AI 出题设置")
    local cw = Widgets.width()
    local ai = self.progress.data.settings.ai
    local active = AIConfig.active_profile(ai)
    local active_text = "未配置"
    if active then
        active_text = string.format("%s · %s", active.name, active.model ~= "" and active.model or "未填模型")
        if not AIConfig.validate(active) then active_text = active.name .. " · 未完成" end
    end
    if ai.config_error then active_text = "配置文件导入失败" end
    local content = VerticalGroup:new{ align = "center" }
    table.insert(content, Widgets.card(VerticalGroup:new{
        align = "left",
        Widgets.label("当前 AI 服务", { size = 16, color = Blitbuffer.COLOR_DARK_GRAY }),
        Widgets.vspace(Size.span.vertical_default),
        Widgets.label(active_text, {
            size = 21, bold = true,
        }),
        Widgets.vspace(Size.span.vertical_default),
        Widgets.textbox("AI 出题需要联网。调用时会把你选择的错题文本发送给对应服务商；API Key 会明文保存在本机（studyassist.lua 或配置文件）中，请使用低额度 Key，并勿在共用设备上保存。也可把 studyassist_ai_config.json 放到 koreader/settings/ 后重启，自动导入 API 地址、Key 和模型。", cw - 4 * Size.padding.default, {
            size = 15, color = Blitbuffer.COLOR_DARK_GRAY,
        }),
    }, { width = cw, padding = Size.padding.large }))
    if ai.config_error then
        table.insert(content, Widgets.vspace(Size.span.vertical_default))
        table.insert(content, Widgets.textbox("配置文件错误：" .. ai.config_error, cw - 4 * Size.padding.default, {
            size = 15, color = Blitbuffer.COLOR_DARK_GRAY,
        }))
    elseif ai.config_source then
        table.insert(content, Widgets.vspace(Size.span.vertical_default))
        table.insert(content, Widgets.textbox("当前 AI 配置来自 koreader/settings/" .. ai.config_source .. "；修改该文件后重启 KOReader 即可重新导入。", cw - 4 * Size.padding.default, {
            size = 15, color = Blitbuffer.COLOR_DARK_GRAY,
        }))
    end
    table.insert(content, Widgets.vspace(Size.span.vertical_large))

    for _, profile in ipairs(ai.profiles) do
        local prefix = profile.id == ai.active_id and "当前 · " or ""
        table.insert(content, Widgets.button(string.format("%s%s · %s", prefix, profile.name, profile.model ~= "" and profile.model or "未填模型"), {
            width = cw,
            height = Screen:scaleBySize(54),
            align = "left",
            size = 18,
            callback = function() self:render_ai_service_edit(profile.id) end,
        }))
        table.insert(content, Widgets.vspace(Size.span.vertical_default))
    end
    table.insert(content, Widgets.button("添加 AI 服务", {
        width = cw,
        height = Screen:scaleBySize(54),
        size = 19,
        callback = function() self:render_ai_preset_select() end,
    }))
    table.insert(content, Widgets.vspace(Size.span.vertical_large))
    table.insert(content, Widgets.textbox("AI 生成内容仅供练习，可能有错误；每次出题都会消耗服务商 token。", cw, {
        size = 15, alignment = "center", color = Blitbuffer.COLOR_DARK_GRAY,
    }))
    table.insert(content, Widgets.vspace(Size.span.vertical_default))
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

function M.render_ai_preset_select(self)
    local items = {}
    for _, preset in ipairs(AIConfig.presets()) do
        table.insert(items, {
            id = preset.id,
            name = string.format("%s · %s", preset.name, preset.protocol == "openai" and "OpenAI 兼容" or preset.protocol),
        })
    end
    self:render_choice_list("添加 AI 服务", items, function(item)
        local ai = self.progress.data.settings.ai
        local profile, err = AIConfig.new_profile(item.id, ai)
        if not profile then
            UIManager:show(InfoMessage:new{ text = tostring(err), timeout = 4 })
            return
        end
        table.insert(ai.profiles, profile)
        if not ai.active_id then ai.active_id = profile.id end
        self.progress:flush()
        self:render_ai_service_edit(profile.id)
    end, function() self:render_ai_settings() end)
end

function M.render_ai_service_edit(self, profile_id)
    local profile = self:find_ai_profile(profile_id)
    if not profile then self:render_ai_settings() return end
    self.state = "ai_service_edit"
    self:set_title(profile.name)
    local cw = Widgets.width()
    local ai = self.progress.data.settings.ai
    local content = VerticalGroup:new{ align = "center" }
    table.insert(content, Widgets.card(VerticalGroup:new{
        align = "left",
        Widgets.label(profile.name, { size = 21, bold = true }),
        Widgets.vspace(Size.span.vertical_default),
        Widgets.textbox(string.format("协议：%s\n接口：%s", profile.protocol, profile.base_url ~= "" and profile.base_url or "未填写"), cw - 4 * Size.padding.default, {
            size = 15, color = Blitbuffer.COLOR_DARK_GRAY,
        }),
    }, { width = cw, padding = Size.padding.large }))
    table.insert(content, Widgets.vspace(Size.span.vertical_large))
    table.insert(content, Widgets.button("API Key：" .. AIConfig.mask_key(profile.api_key), {
        width = cw,
        height = Screen:scaleBySize(54),
        align = "left",
        size = 18,
        callback = function()
            self:open_ai_text_input("设置 API Key", profile.api_key, true, function(text)
                profile.api_key = text:match("^%s*(.-)%s*$") or ""
                self.progress:flush()
                self:render_ai_service_edit(profile.id)
            end)
        end,
    }))
    table.insert(content, Widgets.vspace(Size.span.vertical_default))
    table.insert(content, Widgets.button("模型：" .. (profile.model ~= "" and profile.model or "未填写"), {
        width = cw,
        height = Screen:scaleBySize(54),
        align = "left",
        size = 18,
        callback = function()
            self:open_ai_text_input("设置模型名称", profile.model, false, function(text)
                profile.model = text:match("^%s*(.-)%s*$") or ""
                self.progress:flush()
                self:render_ai_service_edit(profile.id)
            end)
        end,
    }))
    table.insert(content, Widgets.vspace(Size.span.vertical_default))
    if profile.preset == "custom" or profile.preset == "ollama" then
        table.insert(content, Widgets.button("接口地址：" .. (profile.base_url ~= "" and profile.base_url or "未填写"), {
            width = cw,
            height = Screen:scaleBySize(54),
            align = "left",
            size = 18,
            callback = function()
                self:open_ai_text_input("设置接口地址", profile.base_url, false, function(text)
                    profile.base_url = text:match("^%s*(.-)%s*$") or ""
                    self.progress:flush()
                    self:render_ai_service_edit(profile.id)
                end)
            end,
        }))
        table.insert(content, Widgets.vspace(Size.span.vertical_default))
    end
    if ai.active_id ~= profile.id then
        table.insert(content, Widgets.button("设为当前服务", {
            width = cw,
            height = Screen:scaleBySize(54),
            size = 19,
            callback = function()
                ai.active_id = profile.id
                self.progress:flush()
                self:render_ai_service_edit(profile.id)
            end,
        }))
        table.insert(content, Widgets.vspace(Size.span.vertical_default))
    end
    table.insert(content, Widgets.button("测试连接", {
        width = cw,
        height = Screen:scaleBySize(54),
        size = 19,
        callback = function() self:run_ai_test(profile) end,
    }))
    table.insert(content, Widgets.vspace(Size.span.vertical_default))
    table.insert(content, Widgets.button("删除这个服务", {
        width = cw,
        height = Screen:scaleBySize(50),
        size = 18,
        callback = function()
            UIManager:show(ConfirmBox:new{
                text = "确定删除这个 AI 服务配置吗？API Key 也会一起删除。",
                ok_text = "删除",
                cancel_text = "取消",
                ok_callback = function()
                    for index = #ai.profiles, 1, -1 do
                        if ai.profiles[index].id == profile.id then table.remove(ai.profiles, index) end
                    end
                    AIConfig.normalize(ai)
                    self.progress:flush()
                    self:render_ai_settings()
                end,
            })
        end,
    }))
    table.insert(content, Widgets.vspace(Size.span.vertical_default))
    table.insert(content, Widgets.button("返回 AI 设置", {
        width = cw,
        size = 20,
        callback = function() self:render_ai_settings() end,
    }))
    local scroll = ScrollableContainer:new{
        dimen = self:scroll_viewport(),
        show_parent = self,
        content,
    }
    self:set_body(scroll)
end

return M
