--!strict
-- 窗口端：实时采集 OMP 实例状态，处理链接路由与窗口交互
local function is_zh(): boolean
   local cfg_lang = tern.getenv("TERN_LANG") or tern.getenv("PLUGIN_LANG")
   if cfg_lang and #cfg_lang > 0 then
      return string.find(string.lower(cfg_lang), "zh") ~= nil
   end
   local home = tern.getenv("HOME") or ""
   if #home > 0 then
      local s_paths = {
         home .. "/Library/Application Support/Tern/settings.json",
         home .. "/.config/tern/settings.json",
      }
      for _, sp in s_paths do
         if tern.fs.exists(sp) then
            local ok, raw = pcall(function() return tern.fs.read(sp, 32768) end)
            if ok and raw and #raw > 0 then
               local pok, data = pcall(function() return tern.json.decode(raw) end)
               if pok and type(data) == "table" and type(data.language) == "string" then
                  return string.find(string.lower(data.language), "zh") ~= nil
               end
            end
         end
      end
   end
   local env_lang = (tern.getenv("LANG") or "") .. (tern.getenv("LC_ALL") or "") .. (tern.getenv("LC_MESSAGES") or "")
   if #env_lang > 0 and (string.find(string.lower(env_lang), "zh") ~= nil or string.find(string.lower(env_lang), "cn") ~= nil) then
      return true
   end
   if #home > 0 then
      local pref_path = home .. "/Library/Preferences/.GlobalPreferences.plist"
      if tern.fs.exists(pref_path) then
         local ok, bytes = pcall(function() return tern.fs.read(pref_path, 16384) end)
         if ok and bytes and (string.find(bytes, "zh-Hans") or string.find(bytes, "zh-Hant") or string.find(bytes, "zh_CN")) then
            return true
         end
      end
   end
   return false
end

local function t(zh: string, en: string): string
   return if is_zh() then zh else en
end

local function sync_omp_status(cx: WindowCx)
   local agents = cx.agents:list()
   local snapshot = {}

   for _, a in agents do
      local p = cx.session:pane(a.pane)
      local last_msg = a.last_message
      if (not last_msg or #last_msg == 0) and a.state ~= "exited" then
         pcall(function()
            local tr = cx.agents:transcript(a.pane, { last = 1 })
            if tr and #tr > 0 and tr[1].text and #tr[1].text > 0 then
               last_msg = tr[1].text
            end
         end)
      end

      table.insert(snapshot, {
         pane = a.pane,
         title = if p and #p.title > 0 then p.title else ("Agent #" .. a.pane),
         state = a.state, -- "idle" | "working" | "waiting_input" | "exited"
         model = a.model or "default",
         cwd = if p and #p.cwd > 0 then p.cwd else a.cwd,
         busy = if p and p.busy ~= nil then p.busy else (a.state == "working"),
         command = a.command or "",
         running_cmd = if p and p.running then p.running.line else nil,
         running_ms = if p and p.running then p.running.ms else nil,
         last_cmd = if p and p.last then p.last.line else nil,
         last_took_ms = if p and p.last then p.last.took_ms else nil,
         last_msg = last_msg,
         error = a.delivery_error,
      })
   end

   tern.kv.set("omp_snapshot", snapshot)
end

-- 打开面板命令
tern.command({
   id = "open",
   title = t("OMP 监控: 开启运行状态面板", "OMP Monitor: Open Agent Status Monitor"),
   icon = "cpu",
   run = function(cx)
      sync_omp_status(cx)
      cx:new_block("omp-monitor.main", nil, "beside")
      cx:toast("info", t("OMP 监控", "OMP Monitor"), t("已开启 OMP 运行监控看板", "Opened OMP agent status monitor"))
   end,
})

tern.command({
   id = "open_tab",
   title = t("OMP 监控: 在独立标签页打开面板", "OMP Monitor: Open Status Monitor in New Tab"),
   icon = "cpu",
   run = function(cx)
      sync_omp_status(cx)
      cx:new_block("omp-monitor.main", nil, "tab")
   end,
})

-- 核心交互：URL 路由处理跳转与控制动作
tern.route.link(function(link, cx)
   -- 1. 跳转聚焦窗格
   local focus_pane = string.match(link.url, "^omp:focus/(%d+)$")
   if focus_pane then
      local pid = tonumber(focus_pane)
      if pid then
         cx.layout:focus(pid)
         cx:toast("info", "OMP 监控", "已聚焦至窗格 #" .. pid)
         return { handled = true }
      end
   end

   -- 2. 打断正在进行的轮次
   local interrupt_pane = string.match(link.url, "^omp:interrupt/(%d+)$")
   if interrupt_pane then
      local pid = tonumber(interrupt_pane)
      if pid then
         cx.agents:interrupt(pid)
         cx:toast("warning", "OMP 监控", "已向 Pane #" .. pid .. " 发送中断信号")
         sync_omp_status(cx)
         return { handled = true }
      end
   end

   -- 3. 关闭停止 Agent 实例
   local stop_pane = string.match(link.url, "^omp:stop/(%d+)$")
   if stop_pane then
      local pid = tonumber(stop_pane)
      if pid then
         cx.agents:stop(pid)
         cx:toast("info", "OMP 监控", "已停止并关闭 Pane #" .. pid)
         sync_omp_status(cx)
         return { handled = true }
      end
   end

   return nil
end)

-- 生命周期事件自动触发同步
tern.on("agent_finished", function(_ev, cx)
   sync_omp_status(cx)
end)

tern.on("pane_created", function(_ev, cx)
   sync_omp_status(cx)
end)

tern.on("pane_closed", function(_ev, cx)
   sync_omp_status(cx)
end)

-- 定时高频刷新保活
local function loop(cx: WindowCx?)
   if cx then
      sync_omp_status(cx)
   end
   tern.timer(1500, loop)
end
tern.timer(1500, loop)
