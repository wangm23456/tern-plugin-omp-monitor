--!strict
-- 宿主端：精确定位鼠标点击与双击直达，消除重复图标与漂浮溢出，保留完整状态与目录

type AgentItem = {
   pane: number,
   title: string,
   state: string,
   model: string,
   cwd: string,
   busy: boolean,
   command: string?,
   running_cmd: string?,
   running_ms: number?,
   last_cmd: string?,
   last_took_ms: number?,
   last_msg: string?,
   error: string?,
}

type State = {
   selected_pane: number?,
   filter: string, -- "all" | "working" | "waiting" | "idle"
}

local ui = tern.ui

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

local function get_env(): { [string]: string }
   local home = tern.getenv("HOME") or ""
   local path = tern.getenv("PATH") or ""
   return {
      PATH = home .. "/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" .. path,
      HOME = home,
   }
end

local function find_tern(): string
   local home = tern.getenv("HOME") or ""
   local cands = {
      home .. "/.local/bin/tern",
      "/opt/homebrew/bin/tern",
      "/usr/local/bin/tern",
      "tern",
   }
   for _, p in cands do
      if tern.fs.exists(p) then return p end
   end
   return "tern"
end

local function get_items(): { AgentItem }
   local raw = tern.kv.get("omp_snapshot")
   if type(raw) == "table" then
      return raw
   end
   return {}
end

local function status_badge_span(st: string, busy: boolean): Span
   if busy or st == "working" then
      return ui.span(t("⚡ 工作中", "⚡ Working"), "warning strong")
   elseif st == "waiting_input" then
      return ui.span(t("⏳ 待输入", "⏳ Waiting"), "accent strong")
   elseif st == "exited" then
      return ui.span(t("✖ 已退出", "✖ Exited"), "muted")
   else
      return ui.span(t("✓ 空闲", "✓ Idle"), "success")
   end
end

local function filter_items(items: { AgentItem }, filter: string): { AgentItem }
   if filter == "all" then
      return items
   end
   local res = {}
   for _, it in items do
      if filter == "working" and (it.busy or it.state == "working") then
         table.insert(res, it)
      elseif filter == "waiting" and it.state == "waiting_input" then
         table.insert(res, it)
      elseif filter == "idle" and (not it.busy and it.state == "idle") then
         table.insert(res, it)
      end
   end
   return res
end

-- 动作执行函数
local function do_focus(pane: number)
   local bin = find_tern()
   tern.process.run({ bin, "focus", tostring(pane) }, { env = get_env() }, function(_res) end)
end

local function do_interrupt(pane: number, cx: BlockCx)
   tern.pane.write(pane, "\3")
   cx:toast("warning", t("OMP 监控", "OMP Monitor"), t("已向 Pane #" .. pane .. " 发送中断信号 (Ctrl+C)", "Sent interrupt (Ctrl+C) to Pane #" .. pane))
end

local function do_close(pane: number, cx: BlockCx)
   local bin = find_tern()
   tern.process.run({ bin, "close", tostring(pane) }, { env = get_env() }, function(_res)
      cx:toast("info", t("OMP 监控", "OMP Monitor"), t("已关闭 Pane #" .. pane, "Closed Pane #" .. pane))
   end)
end

local monitor_block: BlockDef<State> = {
   init = function(_cx, _args, _saved)
      return { selected_pane = nil, filter = "all" }
   end,

   title = function(_state)
      local all = get_items()
      local working = 0
      for _, it in all do
         if it.busy or it.state == "working" then working += 1 end
      end
      return t("OMP 监控 (", "OMP Monitor (") .. working .. "/" .. #all .. t(" 忙碌)", " busy)")
   end,

   view = function(state, _cx)
      local all_items = get_items()

      -- 统计指标
      local count = { total = #all_items, working = 0, waiting = 0, idle = 0 }
      for _, it in all_items do
         if it.busy or it.state == "working" then
            count.working += 1
         elseif it.state == "waiting_input" then
            count.waiting += 1
         else
            count.idle += 1
         end
      end

      local filtered = filter_items(all_items, state.filter)

      -- 确定当前选中的实例
      local cur: AgentItem? = nil
      if #filtered > 0 then
         if state.selected_pane then
            for _, it in filtered do
               if it.pane == state.selected_pane then
                  cur = it
                  break
               end
            end
         end
         if not cur then
            cur = filtered[1]
            state.selected_pane = cur.pane
         end
      else
         state.selected_pane = nil
      end

      -- 1. 顶部指标概览栏
      local kpi_card = ui.card(ui.span("🖥 TERN · " .. t("OMP 智能体运行态势监控", "OMP Agent Status Monitor"), "strong accent"), {
         ui.row({
            ui.badge(t("总实例: ", "Total: ") .. count.total, "strong"),
            ui.badge(t("⚡ 工作中: ", "⚡ Working: ") .. count.working, if count.working > 0 then "warning strong" else "muted"),
            ui.badge(t("⏳ 待输入: ", "⏳ Waiting: ") .. count.waiting, if count.waiting > 0 then "accent strong" else "muted"),
            ui.badge(t("✓ 空闲: ", "✓ Idle: ") .. count.idle, if count.idle > 0 then "success" else "muted"),
         }),
      })

      -- 2. 标签栏 (点击切换)
      local tab_nodes = {
         ui.el("button", {
            id = "filter:all",
            text = (if state.filter == "all" then "● " else "○ ") .. t("全部 (", "All (") .. count.total .. ")",
            actions = { click = "filter:all" },
         }),
         ui.el("button", {
            id = "filter:working",
            text = (if state.filter == "working" then "● " else "○ ") .. t("⚡ 工作中 (", "⚡ Working (") .. count.working .. ")",
            actions = { click = "filter:working" },
         }),
         ui.el("button", {
            id = "filter:waiting",
            text = (if state.filter == "waiting" then "● " else "○ ") .. t("⏳ 待输入 (", "⏳ Waiting (") .. count.waiting .. ")",
            actions = { click = "filter:waiting" },
         }),
         ui.el("button", {
            id = "filter:idle",
            text = (if state.filter == "idle" then "● " else "○ ") .. t("✓ 空闲 (", "✓ Idle (") .. count.idle .. ")",
            actions = { click = "filter:idle" },
         }),
         ui.el("button", {
            id = "refresh",
            text = t("⟳ 刷新", "⟳ Refresh"),
            actions = { click = "refresh" },
         }),
      }
      local tab_bar = ui.row(tab_nodes)

      -- 3. 实例列表 (纯净单图标，对齐目录，完整绑定点击 actions)
      local rows: { Node } = {}
      for _, it in filtered do
         local is_cur = (cur and cur.pane == it.pane)
         local is_working = (it.busy or it.state == "working")

         local running_desc = if it.running_cmd
            then string.format("⚙ %s (%dms)", it.running_cmd, it.running_ms or 0)
            elseif it.last_cmd
            then string.format("↩ %s (%dms)", it.last_cmd, it.last_took_ms or 0)
            else ""

         -- 不传 icon 属性，彻底根除双重重复图标
         local built = ui.list({ {
            label = {
               status_badge_span(it.state, it.busy),
               ui.span("  #" .. it.pane .. " ", if is_cur then "strong accent" else "muted"),
               ui.span(it.title, if is_cur then "strong accent" else "strong"),
               ui.span("  [" .. it.model .. "]", "accent"),
            },
            detail = ui.span("📁 " .. it.cwd, "muted"),
            value = ui.span(running_desc, if is_working then "warning strong" else "muted"),
            tone = if is_working then "warning" elseif it.state == "waiting_input" then "accent" else "success",
            hint = { "enter" },
         } })

         local row = built.c and built.c[1]
         if row then
            if not row.p then row.p = {} end
            row.p.id = "agent_" .. it.pane
            row.p.key = tostring(it.pane)
            row.p.actions = {
               click = "select:" .. it.pane,
               dblclick = "focus:" .. it.pane,
            }
            table.insert(rows, row)
         end
      end

      local list_node = ui.node("list", {
         id = "agents_list",
         key = "agents_list",
         selected = if cur then ("agent_" .. cur.pane) else nil,
         empty = { ui.span(t("当前分类下无运行中的 OMP 实例。", "No running OMP instances in this filter."), "muted") },
      }, rows)

      local list_section = ui.card(ui.span("📋 " .. t("运行中的 OMP 实例列表 (单击行直接选中 · 双击行立即跳转)", "Running OMP Instances (Click row to select · Double-click to jump)"), "strong"), {
         list_node,
      })

      -- 4. 选中实例的专属详情卡片 (安全截断预览，彻底根绝文本漂浮遮挡)
      local detail_section: Node? = nil
      if cur then
         local kv_pairs = {
            { ui.span(t("窗格编号", "Pane ID")), ui.span("#" .. cur.pane, "accent strong") },
            { ui.span(t("当前状态", "Status")), status_badge_span(cur.state, cur.busy) },
            { ui.span(t("绑定模型", "Model")), ui.span(cur.model, "accent") },
            { ui.span(t("工作目录", "Working Dir")), ui.span(cur.cwd) },
         }
         if cur.running_cmd then
            table.insert(kv_pairs, { ui.span(t("当前子命令", "Running Command")), ui.span(cur.running_cmd .. string.format(" (" .. t("已耗时 ", "took ") .. "%dms)", cur.running_ms or 0), "warning strong") })
         elseif cur.last_cmd then
            table.insert(kv_pairs, { ui.span(t("上次已完成命令", "Last Command")), ui.span(cur.last_cmd .. string.format(" (%dms)", cur.last_took_ms or 0), "muted") })
         end

         local action_buttons = {
            ui.el("button", {
               id = "focus:" .. cur.pane,
               text = t("🔍 跳转到此窗格 (Enter / 双击行)", "🔍 Jump to Pane (Enter / Double-click)"),
               actions = { click = "focus:" .. cur.pane },
            }),
            ui.el("button", {
               id = "interrupt:" .. cur.pane,
               text = t("⏹ 打断当前轮次 (i)", "⏹ Interrupt Run (i)"),
               actions = { click = "interrupt:" .. cur.pane },
            }),
            ui.el("button", {
               id = "stop:" .. cur.pane,
               text = t("✕ 关闭此实例 (x)", "✕ Close Instance (x)"),
               actions = { click = "stop:" .. cur.pane },
            }),
         }

         local detail_children: { Node } = {
            ui.kv(kv_pairs),
            ui.row(action_buttons),
         }

         if cur.last_msg and #cur.last_msg > 0 then
            table.insert(detail_children, ui.rule(ui.span(t("最新对话输出预览", "Recent Output Preview"))))
            local short_msg = string.sub(cur.last_msg, 1, 150)
            short_msg = string.gsub(short_msg, "\n+", " ")
            if #cur.last_msg > 150 then
               short_msg ..= " …"
            end
            table.insert(detail_children, ui.text({ ui.span(short_msg, "muted") }))
         end

         detail_section = ui.card(ui.span("🔎 " .. t("实例详情与操作 · ", "Instance Details & Actions · ") .. cur.title, "strong accent"), detail_children)
      end

      local main_nodes = { kpi_card, tab_bar, list_section }
      if detail_section then
         table.insert(main_nodes, detail_section)
      end
      
      local dock_items = {
         ui.el("button", {
               id = "prev",
            text = t("▲ 上项 (k)", "▲ Prev (k)"),
            actions = { click = "prev" },
         }),
         ui.el("button", {
            id = "next",
            text = t("▼ 下项 (j)", "▼ Next (j)"),
            actions = { click = "next" },
         }),
         ui.el("button", {
            id = "refresh",
            text = t("⟳ 刷新 (r)", "⟳ Refresh (r)"),
            actions = { click = "refresh" },
         }),
      }

      return {
         main = ui.col(main_nodes),
         -- dock = ui.row(dock_items),
      }
   end,

   key = function(state, key, cx)
      local all = get_items()
      local filtered = filter_items(all, state.filter)
      local total = #filtered

      local cur_idx = 1
      for i, it in filtered do
         if it.pane == state.selected_pane then
            cur_idx = i
            break
         end
      end

      if key.name == "j" or key.name == "down" then
         local next_idx = math.min(cur_idx + 1, math.max(1, total))
         if filtered[next_idx] then
            state.selected_pane = filtered[next_idx].pane
         end
         return true
      elseif key.name == "k" or key.name == "up" then
         local prev_idx = math.max(cur_idx - 1, 1)
         if filtered[prev_idx] then
            state.selected_pane = filtered[prev_idx].pane
         end
         return true
      elseif key.name == "1" then
         state.filter, state.selected_pane = "all", nil
         return true
      elseif key.name == "2" then
         state.filter, state.selected_pane = "working", nil
         return true
      elseif key.name == "3" then
         state.filter, state.selected_pane = "waiting", nil
         return true
      elseif key.name == "4" then
         state.filter, state.selected_pane = "idle", nil
         return true
      elseif key.name == "enter" and state.selected_pane then
         do_focus(state.selected_pane)
         return true
      elseif key.name == "i" and state.selected_pane then
         do_interrupt(state.selected_pane, cx)
         return true
      elseif key.name == "x" and state.selected_pane then
         do_close(state.selected_pane, cx)
         return true
      elseif key.name == "r" then
         cx:render()
         return true
      end
      return false
   end,

   event = function(state, ev: UiEvent, cx: BlockCx)
      local act = ev.act or ""
      local id = ev.id or ""
      local item = ev.item or ""

      -- 1. 全局提取目标 Pane ID (无论来自 act, item 还是 id)
      local target_pane: number? = nil
      for _, s in { act, item, id } do
         local p = string.match(s, "(%d+)")
         if p then
            target_pane = tonumber(p)
            break
         end
      end

      -- 2. 双击激活 (activate) 或双击动作 (focus:) -> 立即跳转聚焦
      if ev.ev == "activate" or string.sub(act, 1, 6) == "focus:" or string.sub(id, 1, 6) == "focus:" then
         if target_pane then
            state.selected_pane = target_pane
            do_focus(target_pane)
            cx:render()
            return
         end
      end

      -- 3. 单击选中 (select) 或单选动作 (select:) -> 切换当前选中并渲染
      if ev.ev == "select" or string.sub(act, 1, 7) == "select:" or string.sub(id, 1, 7) == "select:" then
         if target_pane then
            state.selected_pane = target_pane
            cx:render()
            return
         end
      end

      -- 4. 标签切换过滤
      if string.sub(act, 1, 7) == "filter:" or string.sub(id, 1, 7) == "filter:" then
         local f_name = if string.sub(act, 1, 7) == "filter:" then string.sub(act, 8) else string.sub(id, 8)
         state.filter = f_name
         state.selected_pane = nil
         cx:render()
         return
      end

      -- 5. 控制动作
      if string.sub(act, 1, 10) == "interrupt:" or string.sub(id, 1, 10) == "interrupt:" then
         local pid = target_pane
         if pid then do_interrupt(pid, cx) end
         return
      elseif string.sub(act, 1, 5) == "stop:" or string.sub(id, 1, 5) == "stop:" then
         local pid = target_pane
         if pid then do_close(pid, cx) end
         return
      elseif act == "prev" or id == "prev" then
         local all = get_items()
         local filtered = filter_items(all, state.filter)
         for i, it in filtered do
            if it.pane == state.selected_pane then
               if i > 1 then state.selected_pane = filtered[i - 1].pane end
               break
            end
         end
         cx:render()
         return
      elseif act == "next" or id == "next" then
         local all = get_items()
         local filtered = filter_items(all, state.filter)
         for i, it in filtered do
            if it.pane == state.selected_pane then
               if i < #filtered then state.selected_pane = filtered[i + 1].pane end
               break
            end
         end
         cx:render()
         return
      elseif act == "refresh" or id == "refresh" then
         cx:render()
         return
      end
   end,
}

tern.block.define("main", monitor_block)
