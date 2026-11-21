--[[--
Online update pages: manual check, install prompt, non-blocking download +
install, and silent auto-check on startup.

Split out of ui/mainview.lua.  Every function takes the MainView instance as
its first argument (passed implicitly when called as self:method()); bodies
are unchanged from the original MainView: methods.
--]]--

local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local NetworkMgr = require("ui/network/manager")
local Update = require("core/update")
local UpdateDialog = require("ui/update_dialog")

local M = {}

function M.check_update(self)
    if self.update_busy then
        UIManager:show(InfoMessage:new{ text = "正在处理上一个更新请求，请稍候。", timeout = 3 })
        return
    end
    NetworkMgr:runWhenOnline(function()
        if self.closed then return end
        self.update_busy = true
        local loading = InfoMessage:new{ text = "正在检查更新…" }
        UIManager:show(loading)
        UIManager:forceRePaint()
        local settings = self.progress.data.settings
        Update.check({
            api_url = settings.update_api_url,
            local_version = Update.local_version(self.plugin_path),
        }, function(result)
            UIManager:close(loading)
            self.update_busy = false
            if self.closed then return end
            if result.error then
                UIManager:show(InfoMessage:new{ text = "检查更新失败：" .. tostring(result.error), timeout = 6 })
                return
            end
            if not result.available then
                UIManager:show(InfoMessage:new{ text = string.format("已是最新版本 v%s。", result.current), timeout = 4 })
                return
            end
            self:prompt_install_update(result)
        end)
    end)
end

function M.prompt_install_update(self, release)
    -- Show only the first line of the release notes as a short summary; the
    -- full notes can be very long and ConfirmBox is not scrollable.
    local summary = (release.notes or ""):match("^[^\n]*") or ""
    summary = summary:gsub("^#+%s*", "")
    local text = string.format("发现新版本 %s（当前 v%s）。", release.tag, release.current)
    if summary ~= "" then
        text = text .. "\n\n" .. summary
    end
    text = text .. "\n\n升级只替换插件程序，你的星星、打卡、错题本等学习记录完全不受影响。是否下载并升级？"
    UIManager:show(ConfirmBox:new{
        text = text,
        ok_text = "升级",
        cancel_text = "稍后",
        ok_callback = function() self:install_update(release) end,
    })
end

function M.install_update(self, release)
    if self.update_busy then return end
    NetworkMgr:runWhenOnline(function()
        if self.closed then return end
        self.update_busy = true
        -- Progress dialog with a cancel button. The download runs in short
        -- non-blocking ticks with no timeout: however slow the network is,
        -- the user stays in control and can cancel at any time.
        local dialog = UpdateDialog:new{
            total = release.asset_size or 0,
        }
        UIManager:show(dialog)
        local handle
        handle = Update.download_and_install({
            plugin_path = self.plugin_path,
            asset_url = release.asset_url,
            mirror_asset_url = release.mirror_asset_url,
            expect_version = release.version,
            on_progress = function(received, total)
                dialog:update_progress(received, total)
            end,
            on_install = function()
                dialog:set_installing()
            end,
        }, function(ok, err)
            dialog:dismiss()
            self.update_busy = false
            if self.closed then return end
            if not ok then
                if err == Update.CANCELLED then
                    UIManager:show(InfoMessage:new{ text = "已取消更新。", timeout = 3 })
                    return
                end
                UIManager:show(InfoMessage:new{
                    text = "升级失败：" .. tostring(err) .. "\n\n你的学习记录不受影响。",
                    timeout = 8,
                })
                return
            end
            UIManager:show(ConfirmBox:new{
                text = "升级完成！需要重启 KOReader 才能生效。\n\n你的学习记录完全保留。立即重启？",
                ok_text = "重启",
                cancel_text = "稍后",
                ok_callback = function()
                    self.progress:flush()
                    UIManager:restartKOReader()
                end,
                cancel_callback = function()
                    UIManager:show(InfoMessage:new{ text = "好的，下次启动 KOReader 时生效。", timeout = 4 })
                end,
            })
        end)
        dialog.cancel_callback = function()
            if handle then handle.cancel() end
        end
    end)
end

function M._maybe_auto_check_update(self)
    if self._update_auto_checked then return end
    self._update_auto_checked = true
    local settings = self.progress.data.settings
    if not settings.update_auto_check then return end
    UIManager:scheduleIn(2, function()
        if self.closed then return end
        -- Auto-check is silent and only runs when already online; never prompt
        -- to enable Wi-Fi on startup.
        if not NetworkMgr:isConnected() then return end
        Update.check({
            api_url = settings.update_api_url,
            local_version = Update.local_version(self.plugin_path),
        }, function(result)
            if self.closed then return end
            if result.error or not result.available then return end
            self:prompt_install_update(result)
        end)
    end)
end

return M
