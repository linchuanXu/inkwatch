-- 墨守 InkWatch · 智能体状态屏
-- 电脑上运行 inkwatch（局域网 HTTP），X4 长轮询 /state，状态一变就换一屏；审批回 /answer。
-- 画面：左边墨守的脸（只有眼睛）+ 一句话，右边卡片，底栏是会话胶囊。
-- 性能：不用 g:arc（固件逐像素算角度，很慢），弧拆成直线；只开 4 个字号。
local CTX, CLASSIC
local F = {}
local HIT = {}

---------------------------------------------------------------- 状态
-- ctx.state.link = { host = "192.168.1.5:47320", code = "4K7Q" } 自动存档
local S = {
  conn = "none",      -- none | connecting | ok | lost
  err = nil,
  data = nil,         -- 最近一次 /state
  rev = 0,
  sel = nil,          -- 选中的会话 id
  busy = false,       -- 正在发 /answer
  fails = 0,
}
local job, retry_timer

---------------------------------------------------------------- 小工具
local function font_px(px, sample)
  local f = CTX.fonts.size and CTX.fonts:size(px, sample)
  if f and f.px then return f end
  return px >= 28 and CTX.fonts.large or CTX.fonts.medium
end
local function text(g, x, y, s, f, o)
  o = o or {}
  o.font = f
  return g:text(x, y, s, o)
end
local function hit(x, y, w, h, fn) HIT[#HIT + 1] = { x, y, w, h, fn } end
local function str(v) if v == nil or v == CTX.json.null then return "" end return tostring(v) end
local function num(v) return type(v) == "number" and v or 0 end
local function list(v) return type(v) == "table" and v or {} end

-- 截成一行：超过宽度就截断加省略号
local function fit(s, f, w)
  s = str(s):gsub("\n", " ")
  if f:measure(s) <= w then return s end
  local out = ""
  for _, c in utf8.codes(s) do
    local nxt = out .. utf8.char(c)
    if f:measure(nxt .. "…") > w then break end
    out = nxt
  end
  return out .. "…"
end

local function dur(sec)
  sec = math.floor(num(sec))
  if sec < 60 then return sec .. " 秒" end
  if sec < 3600 then return (sec // 60) .. " 分 " .. string.format("%02d", sec % 60) .. " 秒" end
  return (sec // 3600) .. " 小时 " .. ((sec % 3600) // 60) .. " 分"
end
local function ago(t)
  local d = num(S.data and S.data.now) - num(t)
  if d < 60 then return "刚刚" end
  if d < 3600 then return (d // 60) .. " 分钟前" end
  return (d // 3600) .. " 小时前"
end
local function tok(n)
  n = num(n)
  if n >= 1000000 then return string.format("%.1fM", n / 1000000) end
  if n >= 1000 then return (n // 1000) .. "k" end
  return tostring(n)
end

---------------------------------------------------------------- 脸
local function quad(pts, x0, y0, cx, cy, x1, y1, n)
  for i = 1, n do
    local t = i / n
    local a, b, c = (1 - t) ^ 2, 2 * (1 - t) * t, t * t
    pts[#pts + 1] = math.floor(a * x0 + b * cx + c * x1 + 0.5)
    pts[#pts + 1] = math.floor(a * y0 + b * cy + c * y1 + 0.5)
  end
end

-- 100×100 方格里的眼睛，(ox, oy) 左上角，s 缩放
local function eyes(g, kind, ox, oy, s, col)
  local function P(x, y) return math.floor(ox + x * s + 0.5), math.floor(oy + y * s + 0.5) end
  local lw = math.max(2, math.floor(6 * s + 0.5))
  local function pill(x, y, w, h)
    local px, py = P(x, y)
    local pw, ph = math.floor(w * s + 0.5), math.floor(h * s + 0.5)
    g:rect(px, py, pw, ph, { radius = pw // 2, fill = true, color = col })
  end
  if kind == "hello" then
    pill(28, 38, 13, 26); pill(59, 38, 13, 26)
  elseif kind == "think" then
    pill(36, 28, 13, 22); pill(65, 28, 13, 22)
  elseif kind == "ask" then
    local a, b = P(34, 50); local c, d = P(66, 50)
    local r = math.floor(11 * s + 0.5)
    g:circle(a, b, r, { fill = true, color = col }); g:circle(c, d, r, { fill = true, color = col })
  elseif kind == "angry" then
    for side = 0, 1 do
      local function X(x) return side == 0 and x or 100 - x end
      local pts = {}
      local ax, ay = P(X(22), 44); pts[#pts + 1] = ax; pts[#pts + 1] = ay
      local bx, by = P(X(44), 52); pts[#pts + 1] = bx; pts[#pts + 1] = by
      local c1x, c1y = P(X(44), 64); local mx, my = P(X(33), 64)
      quad(pts, bx, by, c1x, c1y, mx, my, 6)
      local c2x, c2y = P(X(22), 64); local ex, ey = P(X(22), 52)
      quad(pts, mx, my, c2x, c2y, ex, ey, 6)
      g:polygon(pts, { fill = true, color = col })
    end
  elseif kind == "sleepy" then
    for _, x in ipairs({ 22, 58 }) do
      local x0, y0 = P(x, 54); local x1 = P(x + 20, 54)
      g:line(x0, y0, x1, y0, { line_width = lw, color = col })
    end
  else -- happy
    local a1, b1 = P(24, 42); local a2, b2 = P(40, 51); local a3, b3 = P(24, 60)
    g:polyline({ a1, b1, a2, b2, a3, b3 }, { line_width = lw, color = col })
    a1, b1 = P(76, 42); a2, b2 = P(60, 51); a3, b3 = P(76, 60)
    g:polyline({ a1, b1, a2, b2, a3, b3 }, { line_width = lw, color = col })
  end
end

local RING
local function ring(g, cx, cy, r)
  if not RING then
    RING = {}
    for d = 0, 359, 8 do
      local a, b = math.rad(d), math.rad(d + 4)
      RING[#RING + 1] = { math.floor(r * math.cos(a) + 0.5), math.floor(r * math.sin(a) + 0.5),
        math.floor(r * math.cos(b) + 0.5), math.floor(r * math.sin(b) + 0.5) }
    end
  end
  for _, s in ipairs(RING) do g:line(cx + s[1], cy + s[2], cx + s[3], cy + s[4], { line_width = 2 }) end
end

local function stage(g, kind, line1, line2)
  local cx, cy = 195, 175
  ring(g, cx, cy, 129)
  g:circle(cx, cy, 105, { fill = true })
  eyes(g, kind, cx - 105, cy - 105, 2.1, 0)
  text(g, cx, 330, fit(line1, F.b20, 360), F.b20, { align = "center", valign = "middle", bold = true })
  if line2 and line2 ~= "" then text(g, cx, 362, fit(line2, F.s13, 360), F.s13, { align = "center", valign = "middle" }) end
end

---------------------------------------------------------------- 画法零件
local PX, PY, PW, PH = 390, 46, 396, 354 -- 右卡
local IX, IW = PX + 16, PW - 32         -- 卡内左边和宽

local function src_badge(g, x, y, src)
  local t = ({ dsh = "DS", claude = "CC", codex = "CX" })[src] or "AI"
  g:rect(x, y, 24, 24, { radius = 7, fill = true })
  text(g, x + 12, y + 12, t, F.s13, { align = "center", valign = "middle", color = 0, bold = true })
end

local function card_head(g, src, title, tag, tag_solid)
  g:rect(PX, PY, PW, PH, { radius = 12, line_width = 2 })
  local x = IX
  if src then src_badge(g, x, PY + 13, src); x = x + 32 end
  local tw = 0
  if tag and tag ~= "" then
    tw = F.s13:measure(tag) + 18
    local tx = PX + PW - 16 - tw
    g:rect(tx, PY + 15, tw, 20, { radius = 10, fill = tag_solid, line_width = 2 })
    text(g, tx + tw // 2, PY + 25, tag, F.s13, { align = "center", valign = "middle", color = tag_solid and 0 or 15 })
  end
  text(g, x, PY + 25, fit(title, F.b17, PX + PW - 16 - tw - 10 - x), F.b17, { valign = "middle", bold = true })
  g:rect(IX, PY + 46, IW, 2, { fill = true })
  return PY + 58
end

local function row(g, y, l, r)
  text(g, IX, y, l, F.s15)
  text(g, IX + IW, y, fit(r, F.s15, IW - F.s15:measure(l) - 16), F.s15, { align = "right", bold = true })
end

local function quote(g, y, s, lines)
  g:rect(IX, y, 4, lines * F.s15.line_height + 4, { fill = true })
  g:text_box(IX + 12, y + 2, IW - 12, lines * F.s15.line_height, str(s), { font = F.s15, wrap = "char", overflow = "ellipsis" })
  return y + lines * F.s15.line_height + 12
end

local function button(g, x, y, w, h, label, solid, fn)
  if solid then g:rect(x, y, w, h, { radius = 12, fill = true })
  else g:rect(x, y, w, h, { radius = 12, line_width = 2 }) end
  text(g, x + w // 2, y + h // 2, label, h >= 44 and F.b17 or F.s15, { align = "center", valign = "middle", color = solid and 0 or 15, bold = h >= 44 })
  hit(x, y, w, h, fn)
end

local function stat_boxes(g, y, items)
  local n = #items
  local w = (IW - (n - 1) * 8) // n
  for i, it in ipairs(items) do
    local x = IX + (i - 1) * (w + 8)
    g:rect(x, y, w, 50, { radius = 10, line_width = 2 })
    text(g, x + 10, y + 6, it[1], F.s13)
    text(g, x + 10, y + 24, fit(it[2], F.b20, w - 16), F.b20, { bold = true })
  end
  return y + 60
end

local function check(g, x, y, kind)
  if kind == "done" then g:rect(x, y, 16, 16, { radius = 4, fill = true })
  elseif kind == "run" then
    g:circle(x + 8, y + 8, 8, { line_width = 2 })
    g:circle(x + 8, y + 8, 4, { fill = true })
  else g:rect(x, y, 16, 16, { radius = 4, line_width = 2 }) end
end

local function dashes(g, y)
  for dx = IX, IX + IW - 4, 8 do g:line(dx, y, dx + 3, y) end
end

---------------------------------------------------------------- 联网
local function base() return "http://" .. CTX.state.link.host end

local schedule
local function poll(wait)
  if job or not CTX.state.link then return end
  local url = base() .. "/state?since=" .. S.rev .. "&wait=" .. (wait or 0)
  job = CTX.net:request({ url = url, headers = { ["x-inkwatch-code"] = CTX.state.link.code }, timeout_ms = 30000 }, function(ctx, res)
    job = nil
    if res.ok and res.status == 200 then
      ctx.budget:extend()
      local d = ctx.json:decode(res.body)
      if type(d) == "table" then
        local changed = num(d.rev) ~= S.rev or S.conn ~= "ok"
        S.data, S.rev, S.conn, S.err, S.fails = d, num(d.rev), "ok", nil, 0
        if changed then ctx:invalidate() end
      end
      schedule(0)
    elseif res.ok and res.status == 401 then
      S.conn, S.err = "lost", "配对码不对，电脑上运行 inkwatch status 查看"
      ctx:invalidate()
    else
      S.fails = S.fails + 1
      local was = S.conn
      S.conn = "lost"
      S.err = res.err == "no_network" and "X4 没连上 Wi-Fi" or "连不上电脑，确认电脑开着、墨守服务在运行、和 X4 在同一网络"
      if was ~= "lost" or S.fails == 1 then ctx:invalidate() end
      schedule(math.min(30000, 3000 * S.fails))
    end
  end)
end
function schedule(delay)
  if retry_timer then retry_timer:cancel(); retry_timer = nil end
  if delay <= 0 then poll(20000) return end
  retry_timer = CTX:after(delay, function() retry_timer = nil; poll(0) end)
end

local function post(path, body)
  if S.busy or not CTX.state.link then return end
  if job then job:cancel(); job = nil end
  S.busy = true
  CTX:invalidate()
  local function go()
    local j, err = CTX.net:request({ url = base() .. path, method = "POST", headers = { ["x-inkwatch-code"] = CTX.state.link.code, ["content-type"] = "application/json" },
      body = CTX.json:encode(body), timeout_ms = 15000 }, function(ctx, res)
      S.busy = false
      if res.ok and res.status == 200 then
        local d = ctx.json:decode(res.body)
        if type(d) == "table" then S.data, S.rev = d, num(d.rev) end
      end
      ctx:invalidate()
      schedule(0)
    end)
    if not j and err == "busy" then CTX:after(500, go) end -- 被取消的长轮询还没释放
  end
  go()
end

---------------------------------------------------------------- 配对
local function ask_link()
  local cur = CTX.state.link or {}
  CTX.input:text({ title = "电脑地址（安装后终端里显示的）", text = cur.host or "192.168.", max_bytes = 40 }, function(ctx, host)
    if not host or host == "" then return end
    host = host:gsub("^%s+", ""):gsub("%s+$", ""):gsub("^http://", "")
    if not host:find(":") then host = host .. ":47320" end
    ctx.input:text({ title = "配对码（4 位）", text = cur.code or "", max_bytes = 8 }, function(ctx2, code)
      if not code or code == "" then return end
      ctx2.state.link = { host = host, code = code:upper():gsub("%s", "") }
      S.rev, S.data, S.conn, S.err, S.fails = 0, nil, "connecting", nil, 0
      ctx2:invalidate()
      schedule(0)
    end)
  end)
end

---------------------------------------------------------------- 选当前显示的东西
local PRI = { ask = 5, error = 4, work = 3, done = 2, idle = 1 }
local function sessions() return list(S.data and S.data.sessions) end
local function current()
  local ss = sessions()
  if S.sel then for _, s in ipairs(ss) do if s.id == S.sel then return s end end end
  local best
  for _, s in ipairs(ss) do
    if not best or (PRI[s.state] or 0) > (PRI[best.state] or 0) then best = s end
  end
  return best
end
local function asks_for(id)
  local out = {}
  for _, a in ipairs(list(S.data and S.data.asks)) do if not id or a.session == id then out[#out + 1] = a end end
  return out
end

---------------------------------------------------------------- 各屏
local function draw_bar(g)
  local now = CTX.clock:now()
  local hm, md = "--:--", ""
  if now and now.valid then
    local wd = { "日", "一", "二", "三", "四", "五", "六" }
    hm = string.format("%02d:%02d", now.hour, now.minute)
    md = string.format("%d/%d 周%s", now.month, now.day, wd[(now.weekday or 0) % 7 + 1] or "")
  end
  text(g, 20, 17, hm, F.s15, { valign = "middle", bold = true })
  text(g, 20 + F.s15:measure(hm, { bold = true }) + 12, 17, md, F.s15, { valign = "middle" })
  local b = CTX.device:battery()
  local pills = { { "电量 " .. ((b and b.percent and b.percent >= 0) and b.percent or "--") .. "%" } }
  local nask = #asks_for()
  if nask > 0 then pills[#pills + 1] = { "等你 " .. nask .. " 个", true } end
  if S.conn == "ok" then pills[#pills + 1] = { "已连接 · " .. str(S.data and S.data.host), true, "dot" }
  elseif S.conn == "lost" then pills[#pills + 1] = { "连不上电脑", false, "ring" }
  elseif S.conn == "connecting" then pills[#pills + 1] = { "连接中…", false, "ring" }
  else pills[#pills + 1] = { "未连接", false, "ring" } end
  local x = 780
  for _, p in ipairs(pills) do
    local label = fit(p[1], F.s13, 220)
    local w = F.s13:measure(label) + 20 + (p[3] and 12 or 0)
    x = x - w
    if p[2] then g:rect(x, 6, w, 22, { radius = 11, fill = true })
    else g:rect(x, 6, w, 22, { radius = 11, line_width = 2 }) end
    local tx = x + 10
    if p[3] == "dot" then g:circle(x + 13, 17, 3, { fill = true, color = p[2] and 0 or 15 }); tx = x + 22
    elseif p[3] == "ring" then g:circle(x + 13, 17, 4, { line_width = 2, color = p[2] and 0 or 15 }); tx = x + 22 end
    text(g, tx, 17, label, F.s13, { valign = "middle", color = p[2] and 0 or 15 })
    x = x - 8
  end
  g:rect(0, 33, 800, 2, { fill = true })
end

local function draw_gear(g)
  g:circle(762, 446, 23, { line_width = 2 })
  g:circle(762, 446, 6, { line_width = 2 })
  for i = 0, 7 do
    local a = math.rad(i * 45)
    g:line(762 + math.floor(10 * math.cos(a) + 0.5), 446 + math.floor(10 * math.sin(a) + 0.5),
      762 + math.floor(14 * math.cos(a) + 0.5), 446 + math.floor(14 * math.sin(a) + 0.5), { line_width = 2 })
  end
  hit(736, 420, 52, 52, ask_link)
end

local function draw_dock(g, cur)
  g:rect(0, 412, 800, 2, { fill = true })
  local ss = sessions()
  if #ss == 0 then
    text(g, 16, 446, S.conn == "ok" and "电脑上还没有智能体在跑 · 开一个 DSH / Claude Code / Codex 试试" or "连接后，电脑上每个智能体会出现在这一栏", F.s15, { valign = "middle" })
  end
  local x = 14
  for _, s in ipairs(ss) do
    local on = cur and s.id == cur.id
    local name, proj = str(s.name), fit(s.project, F.s13, 110)
    local w = 6 + 30 + 8 + math.max(F.s13:measure(name), F.s13:measure(proj)) + 14
    local n = #asks_for(s.id)
    local mark = n > 0 and tostring(n) or (s.state == "error" and "!" or nil)
    if mark then w = w + 24 end
    if x + w > 728 then break end
    if on then g:rect(x, 423, w, 46, { radius = 14, fill = true })
    else g:rect(x, 423, w, 46, { radius = 14, line_width = 2 }) end
    local c = on and 0 or 15
    g:rect(x + 6, 431, 30, 30, { radius = 8, line_width = 2, color = c })
    text(g, x + 21, 446, ({ dsh = "DS", claude = "CC", codex = "CX" })[s.source] or "AI", F.s13, { align = "center", valign = "middle", color = c, bold = true })
    text(g, x + 44, 436, name, F.s13, { valign = "middle", color = c })
    text(g, x + 44, 455, proj, F.s13, { valign = "middle", color = c })
    if mark then
      g:circle(x + w - 20, 446, 9, { fill = true, color = on and 0 or 15 })
      text(g, x + w - 20, 446, mark, F.s13, { align = "center", valign = "middle", color = on and 15 or 0, bold = true })
    end
    hit(x, 423, w, 46, function() S.sel = s.id; CTX:invalidate() end)
    x = x + w + 8
  end
  draw_gear(g)
end

-- ① 配对
local function screen_pair(g)
  local line2 = S.err or "把我放在桌上，帮你盯着电脑上的 AI 智能体"
  stage(g, S.conn == "lost" and "sleepy" or "hello", S.conn == "lost" and "找不到你的电脑" or "你好，我是墨守", line2)
  local y = card_head(g, nil, "连接你的电脑", "局域网直连")
  local steps = {
    { "1", "电脑上打开安装说明，复制一行命令运行" },
    { nil, "github.com/linchuanXu/inkwatch", true },
    { "2", "终端最后会显示「电脑地址」和「配对码」" },
    { "3", "点下面的按钮填进来，只填一次" },
    { nil, "忘了地址：node ~/.inkwatch/inkwatch.mjs status", false, true },
  }
  for _, s in ipairs(steps) do
    if s[3] then
      g:rect(IX + 26, y, IW - 26, 30, { radius = 8, fill = true })
      text(g, IX + 38, y + 15, fit(s[2], F.s15, IW - 50), F.s15, { valign = "middle", color = 0 })
      y = y + 38
    else
      if s[1] then
        g:circle(IX + 9, y + 11, 10, { fill = true })
        text(g, IX + 9, y + 11, s[1], F.s13, { align = "center", valign = "middle", color = 0, bold = true })
      end
      local f = s[4] and F.s13 or F.s15
      text(g, IX + 26, y + 11, fit(s[2], f, IW - 26), f, { valign = "middle" })
      y = y + 28
    end
  end
  local l = CTX.state.link
  button(g, IX, PY + PH - 62, IW, 46, l and ("重新填写（" .. l.host .. "）") or "填写电脑地址和配对码", true, ask_link)
end

-- ② 空闲
local function screen_idle(g, cur)
  local t = S.data.today or {}
  local last = list(t.recent)[1]
  stage(g, "sleepy", "待命中", last and ("上一个任务 " .. ago(last.at) .. "完成 · 有事叫我") or "有事叫我")
  local y = card_head(g, nil, "今天", #sessions() .. " 个会话")
  y = stat_boxes(g, y, { { "完成任务", tostring(num(t.done)) }, { "用时", num(t.minutes) >= 60 and ((num(t.minutes) // 60) .. "h " .. (num(t.minutes) % 60) .. "m") or (num(t.minutes) .. " 分") }, { "审批", num(t.asks) .. " 次" } })
  for i, r in ipairs(list(t.recent)) do
    if i > 4 then break end
    src_badge(g, IX, y, r.source)
    text(g, IX + 32, y + 12, fit(r.title, F.s15, IW - 32 - 90), F.s15, { valign = "middle" })
    text(g, IX + IW, y + 12, ago(r.at), F.s13, { align = "right", valign = "middle" })
    y = y + 32
    if i < #list(t.recent) and i < 4 then dashes(g, y - 4) end
  end
  if #list(t.recent) == 0 then
    text(g, IX, y + 10, "今天还没有完成的任务", F.s15)
  end
  if num(t.asks) > 0 then row(g, PY + PH - 34, "审批平均回应", dur(t.ask_avg_sec)) end
end

-- ③ 干活
local function screen_work(g, s)
  local steps = list(s.steps)
  local todos = list(s.todos)
  local line2
  if #todos > 0 then
    local done = 0
    for _, t in ipairs(todos) do if t.status == "completed" then done = done + 1 end end
    line2 = "第 " .. math.min(#todos, done + 1) .. " 步 / 共 " .. #todos .. " 步 · 已 " .. dur(s.elapsed)
  else
    line2 = "已 " .. dur(s.elapsed) .. " · 调用工具 " .. num(s.tools) .. " 次"
  end
  stage(g, "think", str(s.step) ~= "" and str(s.step) or "思考中", line2)
  local y = card_head(g, s.source, s.project, "进行中", true)
  if str(s.prompt) ~= "" then y = quote(g, y, "「" .. str(s.prompt) .. "」", 2) end
  local items = {}
  if #todos > 0 then
    for _, t in ipairs(todos) do items[#items + 1] = { t.text, t.status == "completed" and "done" or (t.status == "in_progress" and "run" or "todo") } end
  else
    for i, st in ipairs(steps) do items[#items + 1] = { st.text, st.done and "done" or "run", st.done and num(st.sec) > 0 and dur(st.sec) or (i == #steps and "进行中" or "") } end
  end
  local maxn = (PY + PH - 40 - y) // 28
  local first = math.max(1, #items - maxn + 1)
  for i = first, #items do
    local it = items[i]
    check(g, IX, y + 4, it[2])
    local f = it[2] == "run" and F.s15 or F.s15
    local right = it[3] or ""
    local rw = right ~= "" and F.s13:measure(right) + 10 or 0
    text(g, IX + 26, y + 12, fit(it[1], f, IW - 26 - rw), f, { valign = "middle", bold = it[2] == "run" })
    if right ~= "" then text(g, IX + IW, y + 12, right, F.s13, { align = "right", valign = "middle" }) end
    y = y + 28
    if i < #items then dashes(g, y - 3) end
  end
  local foot = "工具 " .. num(s.tools) .. " 次"
  if num(s.subagents) > 0 then foot = "子代理 " .. num(s.subagents) .. " · " .. foot end
  text(g, IX + IW, PY + PH - 24, foot, F.s13, { align = "right", valign = "middle" })
end

-- ④ 审批
local function screen_ask(g, s, a)
  local waited = num(S.data.now) - num(a.at)
  stage(g, "ask", "这条命令我不敢自己跑", "已经等了 " .. dur(waited))
  local y = card_head(g, a.source, str(a.project) .. " 想执行", "需要确认", true)
  local lh = F.s15.line_height
  local n = math.min(3, F.s15:layout(str(a.command), IW - 24, 2000, { wrap = "char" }))
  g:rect(IX, y, IW, n * lh + 18, { radius = 10, fill = true })
  g:text_box(IX + 12, y + 9, IW - 24, n * lh, str(a.command), { font = F.s15, wrap = "char", overflow = "ellipsis", color = 0 })
  y = y + n * lh + 28
  row(g, y, "原因", str(a.why)); y = y + 26
  row(g, y, "目录", str(a.cwd)); y = y + 26
  row(g, y, "来自", str(a.name)); y = y + 26
  local by = PY + PH - 114
  local bw = (IW - 10) // 2
  button(g, IX, by, bw, 46, "拒绝", false, function() post("/answer", { id = a.id, answer = "deny" }) end)
  button(g, IX + bw + 10, by, bw, 46, "允许一次", true, function() post("/answer", { id = a.id, answer = "allow" }) end)
  local w1 = F.s15:measure("在电脑上看") + 28
  button(g, IX, by + 54, w1, 46, "在电脑上看", false, function() post("/answer", { id = a.id, answer = "pass" }) end)
  button(g, IX + w1 + 10, by + 54, IW - w1 - 10, 46, "本会话都允许", false, function() post("/answer", { id = a.id, answer = "session" }) end)
end

-- ⑤ 卡住
local function screen_error(g, s)
  local e = s.error ~= CTX.json.null and s.error or {}
  stage(g, "angry", "卡住了！", str(e.cmd) ~= "" and ("跑 " .. str(e.cmd) .. " 出错") or "出错了")
  local y = card_head(g, s.source, str(s.project) .. " · 出错", "需要你", true)
  local tail = list(e.tail)
  local lh = F.s13.line_height
  g:rect(IX, y, IW, #tail * lh + 16, { radius = 10, line_width = 2 })
  for i, l in ipairs(tail) do text(g, IX + 12, y + 8 + (i - 1) * lh, fit(l, F.s13, IW - 24), F.s13) end
  y = y + #tail * lh + 26
  if str(s.summary) ~= "" then y = quote(g, y, s.summary, 3) end
  button(g, IX, PY + PH - 62, IW, 46, "知道了，我去电脑上看", true, function() post("/ack", { id = s.id }) end)
end

-- ⑥ 完成
local function screen_done(g, s)
  stage(g, "happy", "做完啦！", "用时 " .. dur(s.elapsed) .. " · " .. ago(s.updated))
  local title = str(s.title) ~= "" and str(s.title) or str(s.project)
  local y = card_head(g, s.source, title, "完成")
  local summary = str(s.summary) ~= "" and s.summary or s.prompt
  y = quote(g, y, summary, 3)
  local files = list(s.files)
  for i, f in ipairs(files) do
    if i > 3 then break end
    local d = "+" .. num(f.add) .. (num(f.del) > 0 and (" −" .. num(f.del)) or "")
    text(g, IX, y, fit(f.file, F.s13, IW - 80), F.s13)
    text(g, IX + IW, y, d, F.s13, { align = "right", bold = true })
    y = y + 20
  end
  y = y + 6
  stat_boxes(g, y, { { "改了文件", #files .. " 个" }, { "工具", num(s.tools) .. " 次" }, { "Token", tok(s.tokens) } })
  button(g, IX, PY + PH - 62, IW, 46, "知道了", true, function() post("/ack", { id = s.id }) end)
end

---------------------------------------------------------------- 生命周期
function on_load(ctx)
  CTX = ctx
  CLASSIC = not ctx.input.pointer
  ctx.budget:extend()
  F.s13 = font_px(13)
  F.s15 = font_px(15)
  F.b17 = font_px(17)
  F.b20 = font_px(20)
  if ctx.net.keep_wifi then ctx.net:keep_wifi(-1) end -- 应用开着就一直在线
  if ctx.state.link then S.conn = "connecting"; schedule(0) end
  -- 每分钟重画一次：顶栏时间、「已等了几分钟」
  local function minute()
    local now = ctx.clock:now()
    ctx:after(((now and now.valid) and (60 - (now.second or 0)) or 60) * 1000, function()
      ctx:invalidate(); minute()
    end)
  end
  minute()
end

function on_draw(ctx, g)
  ctx.budget:extend()
  HIT = {}
  g:clear(0)
  draw_bar(g)
  local cur = current()
  if S.conn ~= "ok" or not S.data then
    screen_pair(g)
    draw_dock(g, nil)
  else
    local asks = asks_for(cur and cur.id or nil)
    if #asks == 0 and not S.sel then asks = asks_for() end
    if #asks > 0 then
      screen_ask(g, cur, asks[1])
    elseif not cur or cur.state == "idle" then
      screen_idle(g, cur)
    elseif cur.state == "work" then
      screen_work(g, cur)
    elseif cur.state == "error" then
      screen_error(g, cur)
    else
      screen_done(g, cur)
    end
    draw_dock(g, cur)
  end
  if S.busy then
    g:rect(330, 222, 140, 36, { radius = 18, fill = true })
    text(g, 400, 240, "发送中…", F.s15, { align = "center", valign = "middle", color = 0 })
  end
end

function on_input(ctx, ev)
  if ev.type == "pointer" then
    if ev.phase == "up" then
      for i = #HIT, 1, -1 do
        local h = HIT[i]
        if ev.x >= h[1] and ev.y >= h[2] and ev.x < h[1] + h[3] and ev.y < h[2] + h[4] then h[5](); break end
      end
    end
    return true
  end
  if ev.type == "key" then
    if ev.key == "back" then
      if S.sel and ev.phase == "up" then S.sel = nil; ctx:invalidate(); return true end
      return ev.phase ~= "up" or S.sel ~= nil
    end
    if ev.phase == "down" and ev.key == "ok" and (S.conn ~= "ok") then ask_link() end
    return true
  end
  return false
end

function on_resume(ctx)
  if ctx.state.link and not job then schedule(0) end
end
