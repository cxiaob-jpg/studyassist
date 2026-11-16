--[[--
StudyAssist: a small grades 1-6 Chinese and math practice app for KOReader.

@module koplugin.studyassist
--]]--

local Dispatcher = require("dispatcher")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local MainView = require("ui/mainview")
local _ = require("gettext")

local StudyAssist = WidgetContainer:extend{
    name = "studyassist",
    is_doc_only = false,
}

local autostarted = false

function StudyAssist:init()
    math.randomseed(os.time() + math.floor((os.clock() or 0) * 1000))
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    -- 开机自动进入：环境变量 STUDYASSIST_AUTOSTART=1
    -- 兼容旧版配置名 KIDLEARN_AUTOSTART=1，避免升级后自动启动失效
    local autostart_env = os.getenv("STUDYASSIST_AUTOSTART") or os.getenv("KIDLEARN_AUTOSTART")
    if not autostarted and autostart_env == "1" then
        autostarted = true
        UIManager:scheduleIn(1, function() self:showMainView() end)
    end
end

function StudyAssist:onDispatcherRegisterActions()
    Dispatcher:registerAction("studyassist_open", {
        category = "none",
        event = "StudyAssistOpen",
        title = _("打开学习助理"),
        general = true,
    })
end

function StudyAssist:addToMainMenu(menu_items)
    menu_items.studyassist = {
        text = _("学习助理"),
        sorting_hint = "more_tools",
        callback = function()
            self:showMainView()
        end,
    }
end

function StudyAssist:showMainView()
    UIManager:show(MainView:new{
        plugin = self,
        plugin_path = self.path,
    })
end

function StudyAssist:onStudyAssistOpen()
    self:showMainView()
    return true
end

return StudyAssist
