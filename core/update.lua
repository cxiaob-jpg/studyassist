--[[--
GitHub Release self-updater for StudyAssist.

This is the second opt-in network subsystem (after AI). It is user-triggered
and manual by default; an optional startup auto-check is off by default and
only runs when already online. No background polling, no telemetry.

DATA SAFETY (hard guarantee): all user data lives in KOReader's settings
directory (studyassist.lua / studyassist_ai_bank.json / studyassist_ai_config.json),
strictly outside the plugin directory. This module's write set is confined to
the plugin directory and two named sibling temp dirs (.studyassist_update /
.studyassist_backup). It never references the settings directory and never opens
any data file for writing, so replacing the plugin folder cannot touch learning
history. spec/unit/studyassist_update_spec.lua proves this byte-for-byte.

Only modules already bundled with KOReader are used: ssl.https / socket.http /
ltn12 / socketutil (release check transport), json (release parsing),
ffi/archiver (libarchive unzip, also used by the on-device dictionary),
util / ffi/util (file ops). The release zip itself downloads through
core/update_http.lua: incremental non-blocking ticks with a progress bar,
no timeout, and user cancellation.
--]]--

local ffiutil = require("ffi/util")
local JSON = require("json")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local socketutil = require("socketutil")
local util = require("util")

local UpdateHttp = require("core.update_http")

local Update = {}

--- Sentinel error string reported when the user cancels a download.
Update.CANCELLED = UpdateHttp.CANCELLED

local DEFAULT_API_URL = "https://api.github.com/repos/cxiaob-jpg/studyassist/releases/latest"
-- 国内镜像（CNB，与 GitHub 仓库同源同步）。CNB 的 OpenAPI 即使仓库公开也
-- 要求登录（匿名 401），但 Release 附件的 browser_download_url 匿名可用，
-- 所以流程是：检查更新走 GitHub（小 JSON，快），下载大附件优先走镜像的
-- 确定性 URL，失败回退 GitHub 附件地址。
local MIRROR_API_URL = "https://api.cnb.cool/byh-mirror/studyassist/-/releases"
local MIRROR_DOWNLOAD_BASE = "https://cnb.cool/byh-mirror/studyassist/-/releases/download/"
local ASSET_NAME = "studyassist.koplugin.zip"
local TOP_DIR = "studyassist.koplugin"
local STAGING_NAME = ".studyassist_update"
local BACKUP_NAME = ".studyassist_backup"
local MAX_REDIRECTS = 5

Update.DEFAULT_API_URL = DEFAULT_API_URL
Update.MIRROR_API_URL = MIRROR_API_URL
Update.MIRROR_DOWNLOAD_BASE = MIRROR_DOWNLOAD_BASE
Update.ASSET_NAME = ASSET_NAME

-- ---------------------------------------------------------------------------
-- Transport (blocking GET, redirect-following). Mirrors core/ai_http.lua's
-- synchronous path; on Kindle the Turbo looper is off, so AI also blocks.
-- The release zip is small (~hundreds of KB), so an in-memory body is safe and
-- keeps redirect handling simple (a file sink would capture 3xx bodies too).
-- ---------------------------------------------------------------------------

local function sync_get(url, headers, block_timeout, total_timeout)
    local http = require("socket.http")
    local https = require("ssl.https")
    local ltn12 = require("ltn12")
    local hops = 0
    while true do
        local client = url:match("^https://") and https or http
        local chunks = {}
        socketutil:set_timeout(block_timeout, total_timeout)
        local ok, one, code, resp_headers, status = pcall(client.request, {
            url = url,
            method = "GET",
            headers = headers,
            redirect = false,
            sink = ltn12.sink.table(chunks),
        })
        socketutil:reset_timeout()
        if not ok then return nil, tostring(one) end
        if one ~= 1 then return nil, tostring(code or one) end
        if not code then return nil, tostring(status or "网络请求失败") end
        if code == 301 or code == 302 or code == 303 or code == 307 or code == 308 then
            local loc = resp_headers and resp_headers["location"]
            if not loc then return nil, "重定向缺少 Location" end
            hops = hops + 1
            if hops > MAX_REDIRECTS then return nil, "重定向次数过多" end
            if loc:match("^https?://") then
                url = loc
            elseif loc:sub(1, 1) == "/" then
                url = url:match("^(https?://[^/]+)") .. loc
            else
                url = url:match("^(https?://[^/]+)") .. "/" .. loc
            end
        elseif code ~= 200 then
            return nil, "HTTP " .. tostring(code), code
        else
            return table.concat(chunks), nil, code
        end
    end
end

local default_transport = {
    get = function(url, headers, block_timeout, total_timeout)
        return sync_get(url, headers, block_timeout or 20, total_timeout or 30)
    end,
}

-- ---------------------------------------------------------------------------
-- Pure helpers (unit-tested without network).
-- ---------------------------------------------------------------------------

function Update.normalize_version(tag)
    if type(tag) ~= "string" then return "" end
    local v = tag:match("^%s*(.-)%s*$") or ""
    v = v:gsub("^[vV]", "")
    return v
end

local function split_version(v)
    v = Update.normalize_version(v)
    local core, suffix = v:match("^([0-9%.]+)(.*)$")
    if not core then core, suffix = v, "" end
    local parts = {}
    for n in core:gmatch("(%d+)") do
        table.insert(parts, tonumber(n))
    end
    return parts, suffix
end

--- Compare two version strings. Returns 1 if a>b, -1 if a<b, 0 if equal.
-- Numeric dot components are compared numerically (1.10 > 1.9); missing
-- components count as 0 (1.3 == 1.3.0). With an equal numeric core, a plain
-- release outranks a suffixed pre-release (1.3.0 > 1.3.0-beta).
function Update.compare_versions(a, b)
    local pa, sa = split_version(a)
    local pb, sb = split_version(b)
    local n = math.max(#pa, #pb)
    for i = 1, n do
        local x = pa[i] or 0
        local y = pb[i] or 0
        if x > y then return 1 elseif x < y then return -1 end
    end
    if sa == "" and sb ~= "" then return 1 end
    if sa ~= "" and sb == "" then return -1 end
    if sa == sb then return 0 end
    return sa < sb and -1 or 1
end

function Update.is_newer(remote_tag, local_version)
    return Update.compare_versions(remote_tag, local_version) > 0
end

--- Parse one release object (GitHub "releases/latest" item or one entry of
-- the CNB mirror list) and pick the plugin zip asset.
local function parse_release_item(data)
    local tag = data.tag_name
    if type(tag) ~= "string" or tag == "" then
        return nil, "Release 缺少 tag_name"
    end
    local asset
    if type(data.assets) == "table" then
        for _, a in ipairs(data.assets) do
            if type(a) == "table" and a.name == ASSET_NAME then
                asset = a
                break
            end
        end
    end
    if not asset then
        return nil, "Release 没有 " .. ASSET_NAME .. " 附件"
    end
    local url = asset.browser_download_url
    if type(url) ~= "string" or url == "" then
        return nil, "附件缺少下载地址"
    end
    return {
        tag = tag,
        version = Update.normalize_version(tag),
        notes = type(data.body) == "string" and data.body or "",
        asset_url = url,
        asset_name = asset.name,
        asset_size = tonumber(asset.size) or 0,
    }
end

--- Parse a release check response. Accepts either a single release object
-- (GitHub) or an array of releases (CNB mirror list); for arrays the entry
-- flagged is_latest wins, otherwise the highest version carries the vote.
function Update.parse_release(text)
    if type(text) ~= "string" or text == "" then
        return nil, "空的 Release 响应"
    end
    local ok, data = pcall(JSON.decode, text)
    if not ok or type(data) ~= "table" then
        return nil, "Release 响应不是有效 JSON"
    end
    if data[1] ~= nil then
        local flagged, best, best_v
        for _, rel in ipairs(data) do
            if type(rel) == "table" and rel.draft ~= true and rel.prerelease ~= true then
                local item = parse_release_item(rel)
                if item then
                    if rel.is_latest == true then
                        flagged = item
                        break
                    end
                    local v = item.version
                    if not best_v or Update.compare_versions(v, best_v) > 0 then
                        best, best_v = item, v
                    end
                end
            end
        end
        local chosen = flagged or best
        if not chosen then
            return nil, "Release 列表里没有可用的 " .. ASSET_NAME
        end
        return chosen
    end
    return parse_release_item(data)
end

--- Validate one zip entry path. Rejects absolute paths, ".." traversal,
-- backslashes, and anything outside the single top-level plugin folder.
-- The top-level directory entry itself ("studyassist.koplugin/") is allowed.
function Update.sanitize_entry_path(path)
    if type(path) ~= "string" or path == "" then return nil end
    if path:find("\\", 1, true) then return nil end
    if path:sub(1, 1) == "/" then return nil end
    for comp in path:gmatch("[^/]+") do
        if comp == ".." then return nil end
    end
    local trimmed = path:gsub("/+$", "")
    if trimmed == TOP_DIR then
        return path
    end
    if path:sub(1, #TOP_DIR + 1) ~= TOP_DIR .. "/" then return nil end
    if #path <= #TOP_DIR + 1 then return nil end
    return path
end

--- Read the installed version from the plugin's _meta.lua (single source).
function Update.local_version(plugin_path)
    if type(plugin_path) ~= "string" then return "0.0.0" end
    local ok, meta = pcall(dofile, plugin_path .. "/_meta.lua")
    if ok and type(meta) == "table" and type(meta.version) == "string" and meta.version ~= "" then
        return meta.version
    end
    return "0.0.0"
end

-- ---------------------------------------------------------------------------
-- Check for a newer release. Synchronous; invokes callback inline with either
-- { available, tag, version, notes, asset_url, asset_size, current } or
-- { error, current }. opts: { api_url?, local_version?, transport? }.
-- ---------------------------------------------------------------------------

function Update.check(opts, callback)
    opts = opts or {}
    local transport = opts.transport or default_transport
    local current = opts.local_version or "0.0.0"
    -- 检查源：显式指定 api_url 时只用它（测试/自定义）；否则 GitHub 检查
    -- 优先（CNB OpenAPI 匿名也要求登录，只适合做下载镜像），CNB 探测作备选。
    local sources
    local api_url = opts.api_url
    if type(api_url) == "string" and api_url ~= "" then
        sources = { { url = api_url, accept = "application/vnd.github+json" } }
    else
        sources = {
            { url = DEFAULT_API_URL, accept = "application/vnd.github+json" },
            { url = MIRROR_API_URL, accept = "application/vnd.cnb.api+json",
              block_timeout = 8, total_timeout = 10 },
        }
    end
    local last_err
    for _, src in ipairs(sources) do
        local headers = {
            ["User-Agent"] = "StudyAssist-Updater/" .. current,
            ["Accept"] = src.accept,
        }
        local body, err = transport.get(src.url, headers,
            src.block_timeout or 20, src.total_timeout or 30)
        local release
        if body then
            release, last_err = Update.parse_release(body)
        else
            last_err = err or "网络请求失败"
        end
        if release then
            release.current = current
            release.available = Update.is_newer(release.tag, current)
            -- 附件下载的镜像候选：CNB 按确定性的 tag URL 匿名可下载。
            release.mirror_asset_url = MIRROR_DOWNLOAD_BASE .. release.tag .. "/" .. ASSET_NAME
            callback(release)
            return
        end
    end
    callback({ error = last_err, current = current })
end

-- ---------------------------------------------------------------------------
-- Download + install. The download runs incrementally in short non-blocking
-- ticks (core/update_http.lua): real byte progress, NO timeout (a slow or
-- stalled network just waits), and the user can cancel at any time through
-- the returned handle. The install phase is fast local I/O. Every write is
-- confined to the plugin dir and the two named temp dirs; the settings dir is
-- never touched.
-- opts: { plugin_path, asset_url, mirror_asset_url?, expect_version?,
--         on_progress?(received, total), on_install?(),
--         transport? (legacy synchronous override, used by unit tests),
--         schedule?/unschedule?/tcp?/ssl_wrap? (test injection) }.
-- When mirror_asset_url is set, it is tried first and the download silently
-- falls back to asset_url on failure (user cancel always aborts).
-- callback(ok, err, info); err == Update.CANCELLED when the user cancels.
-- Returns a handle { cancel() }.
-- ---------------------------------------------------------------------------

local NOOP_HANDLE = { cancel = function() end }

function Update.download_and_install(opts, callback)
    opts = opts or {}
    local plugin_path = opts.plugin_path
    local asset_url = opts.asset_url
    if type(plugin_path) ~= "string" or plugin_path == "" then
        callback(false, "缺少插件目录")
        return NOOP_HANDLE
    end
    if type(asset_url) ~= "string" or asset_url == "" then
        callback(false, "缺少下载地址")
        return NOOP_HANDLE
    end

    -- Guard: refuse symlinked / development installs (e.g. test_plugin.sh link).
    local sym = lfs.symlinkattributes(plugin_path)
    if sym and sym.mode == "link" then
        callback(false, "当前是开发版（符号链接）安装，请手动更新插件目录。")
        return NOOP_HANDLE
    end
    local real = ffiutil.realpath(plugin_path)
    if not real or lfs.attributes(real, "mode") ~= "directory" then
        callback(false, "无法定位插件目录")
        return NOOP_HANDLE
    end
    local parent = ffiutil.dirname(real)
    local staging = parent .. "/" .. STAGING_NAME
    local backup = parent .. "/" .. BACKUP_NAME

    -- Clean leftovers from a previous interrupted attempt (named temp dirs only).
    if util.pathExists(staging) then ffiutil.purgeDir(staging) end
    if util.pathExists(backup) then ffiutil.purgeDir(backup) end

    -- Install phase: runs only after the full body is in memory. Staging is
    -- created here (not before the download) so a cancelled download leaves
    -- no artifacts behind.
    local function install_body(body)
        local ok, err = util.makePath(staging)
        if not ok then
            callback(false, "无法创建暂存目录（目录可能不可写）：" .. tostring(err))
            return
        end

        local function fail(message)
            if util.pathExists(staging) then ffiutil.purgeDir(staging) end
            logger.warn("StudyAssist update:", message)
            callback(false, message)
        end

        local zip_path = staging .. "/update.zip"
        local fh, ferr = io.open(zip_path, "wb")
        if not fh then
            fail("无法写入暂存文件：" .. tostring(ferr))
            return
        end
        fh:write(body)
        fh:close()

        if opts.on_install then opts.on_install() end

        -- Extract with libarchive. Read each file to memory and write it ourselves
        -- to a sanitized destination: this keeps normal file permissions (the
        -- libarchive disk writer would otherwise drop read bits) and means
        -- libarchive never writes to disk paths directly.
        local Archiver = require("ffi/archiver")
        local arc = Archiver.Reader:new()
        if not arc:open(zip_path) then
            fail("无法打开更新包：" .. tostring(arc.err))
            return
        end
        local extracted = staging .. "/" .. TOP_DIR
        for entry in arc:iterate() do
            local rel = Update.sanitize_entry_path(entry.path)
            if not rel then
                arc:close()
                fail("更新包含不安全路径：" .. tostring(entry.path))
                return
            end
            local dest = staging .. "/" .. rel
            if entry.mode == "directory" then
                local mok, merr = util.makePath(dest)
                if not mok then arc:close(); fail("创建目录失败：" .. tostring(merr)); return end
            elseif entry.mode == "file" then
                local mok, merr = util.makePath(ffiutil.dirname(dest))
                if not mok then arc:close(); fail("创建目录失败：" .. tostring(merr)); return end
                local content = arc:extractToMemory(entry.path)
                if not content then
                    arc:close()
                    fail("解压失败：" .. tostring(arc.err))
                    return
                end
                local fh, ferr = io.open(dest, "wb")
                if not fh then
                    arc:close()
                    fail("写入更新文件失败：" .. tostring(ferr))
                    return
                end
                fh:write(content)
                fh:close()
            else
                arc:close()
                fail("更新包含不支持的条目类型：" .. tostring(entry.mode))
                return
            end
        end
        arc:close()

        -- Validate the extracted plugin before touching the installed one.
        if lfs.attributes(extracted .. "/main.lua", "mode") ~= "file"
            or lfs.attributes(extracted .. "/_meta.lua", "mode") ~= "file" then
            fail("更新包结构不正确（缺少 main.lua / _meta.lua）")
            return
        end
        if opts.expect_version then
            local got = Update.local_version(extracted)
            if got ~= Update.normalize_version(opts.expect_version) then
                fail("更新包版本与 Release 不一致")
                return
            end
        end

        -- Swap with rollback. rename is atomic on the same filesystem; staging is a
        -- sibling of the plugin dir, so both renames stay on one filesystem.
        local rok, rerr = os.rename(real, backup)
        if not rok then
            fail("无法备份当前插件（目录可能不可写）：" .. tostring(rerr))
            return
        end
        local mok, merr = os.rename(extracted, real)
        if not mok then
            os.rename(backup, real) -- roll back to the previous code
            fail("无法安装新插件，已回滚：" .. tostring(merr))
            return
        end

        -- Success: remove old-code backup and staging (named temp dirs only).
        ffiutil.purgeDir(backup)
        ffiutil.purgeDir(staging)
        callback(true, nil, { plugin_path = real })
    end

    -- Engine callback contract: (ok, body_or_err).
    -- 下载源：镜像优先（国内快），失败（非用户取消）自动回退 GitHub 附件地址。
    local urls = {}
    if type(opts.mirror_asset_url) == "string" and opts.mirror_asset_url ~= "" then
        urls[#urls + 1] = opts.mirror_asset_url
    end
    urls[#urls + 1] = asset_url
    local url_index = 0

    local start_download -- forward declaration for the retry path

    local function after_download(ok, body_or_err)
        if not ok then
            if body_or_err ~= Update.CANCELLED then
                url_index = url_index + 1
                if url_index < #urls then
                    logger.warn("StudyAssist update: 下载失败，改用备用地址：", body_or_err)
                    start_download(urls[url_index + 1])
                    return
                end
                logger.warn("StudyAssist update: 下载更新失败：", body_or_err)
            end
            callback(false, body_or_err or "下载更新失败")
            return
        end
        install_body(body_or_err)
    end

    start_download = function(url)
        return UpdateHttp.get({
            url = url,
            headers = { ["User-Agent"] = "StudyAssist-Updater" },
            on_progress = opts.on_progress,
            schedule = opts.schedule,
            unschedule = opts.unschedule,
            tcp = opts.tcp,
            ssl_wrap = opts.ssl_wrap,
        }, after_download)
    end

    if opts.transport then
        -- Legacy synchronous transport (unit tests / fallback only).
        local body, derr
        for _, url in ipairs(urls) do
            body, derr = opts.transport.get(url, { ["User-Agent"] = "StudyAssist-Updater" }, 20, 180)
            if body then break end
        end
        if body then
            after_download(true, body)
        else
            after_download(false, derr)
        end
        return NOOP_HANDLE
    end

    return start_download(urls[1])
end

return Update
