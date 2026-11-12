-- 墨守 InkWatch · 智能体状态屏
-- 电脑上运行 inkwatch（局域网 HTTP），X4 长轮询 /state，状态一变就换一屏；审批回 /answer。
-- 画面：左边墨守的脸（只有眼睛）+ 一句话，右边卡片，底栏是会话胶囊。
-- 性能：不用 g:arc（固件逐像素算角度，很慢），弧拆成直线；只开 3 个字号（18/22/28）。
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
-- 会话名：电脑端给的中文标题（智能体标题 / 你的第一句话），没有才用项目文件夹
local function label(s) local l = str(s and s.label) return l ~= "" and l or str(s and s.project) end
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

-- 字号只开 3 个：s18 正文、b22 标题和按钮、b28 主句和大数字。墨水屏 1 位显示，小字发虚，不要再加更小的
local function stage(g, kind, line1, line2)
  local cx, cy = 195, 160
  ring(g, cx, cy, 116)
  g:circle(cx, cy, 94, { fill = true })
  eyes(g, kind, cx - 94, cy - 94, 1.88, 0)
  text(g, cx, 314, fit(line1, F.b28, 370), F.b28, { align = "center", valign = "middle", bold = true })
  if line2 and line2 ~= "" then text(g, cx, 356, fit(line2, F.s18, 370), F.s18, { align = "center", valign = "middle" }) end
end

---------------------------------------------------------------- 画法零件
local PX, PY, PW, PH = 390, 52, 396, 350 -- 右卡
local IX, IW = PX + 16, PW - 32         -- 卡内左边和宽
local BOTTOM = PY + PH - 16             -- 卡内最下沿

local function src_badge(g, x, y, src)
  local t = ({ dsh = "DS", claude = "CC", codex = "CX" })[src] or "AI"
  g:rect(x, y, 30, 30, { radius = 8, fill = true })
  text(g, x + 15, y + 15, t, F.s18, { align = "center", valign = "middle", color = 0, bold = true })
end

local function card_head(g, src, title, tag, tag_solid)
  g:rect(PX, PY, PW, PH, { radius = 12, line_width = 2 })
  local x = IX
  if src then src_badge(g, x, PY + 13, src); x = x + 40 end
  local tw = 0
  if tag and tag ~= "" then
    tw = F.s18:measure(tag) + 20
    local tx = PX + PW - 16 - tw
    g:rect(tx, PY + 14, tw, 28, { radius = 14, fill = tag_solid, line_width = 2 })
    text(g, tx + tw // 2, PY + 28, tag, F.s18, { align = "center", valign = "middle", color = tag_solid and 0 or 15 })
  end
  text(g, x, PY + 28, fit(title, F.b22, PX + PW - 16 - tw - 10 - x), F.b22, { valign = "middle", bold = true })
  g:rect(IX, PY + 54, IW, 2, { fill = true })
  return PY + 68
end

local function button(g, x, y, w, h, label, solid, fn, f)
  f = f or F.b22
  if solid then g:rect(x, y, w, h, { radius = 12, fill = true })
  else g:rect(x, y, w, h, { radius = 12, line_width = 2 }) end
  text(g, x + w // 2, y + h // 2, label, f, { align = "center", valign = "middle", color = solid and 0 or 15, bold = true })
  hit(x, y, w, h, fn)
end

local function stat_boxes(g, y, items)
  local n = #items
  local w = (IW - (n - 1) * 8) // n
  for i, it in ipairs(items) do
    local x = IX + (i - 1) * (w + 8)
    g:rect(x, y, w, 84, { radius = 10, line_width = 2 })
    text(g, x + w // 2, y + 22, it[1], F.s18, { align = "center", valign = "middle" })
    text(g, x + w // 2, y + 58, fit(it[2], F.b28, w - 12), F.b28, { align = "center", valign = "middle", bold = true })
  end
  return y + 96
end

local function check(g, x, y, kind)
  if kind == "done" then g:rect(x, y, 20, 20, { radius = 5, fill = true })
  elseif kind == "run" then
    g:circle(x + 10, y + 10, 10, { line_width = 2 })
    g:circle(x + 10, y + 10, 5, { fill = true })
  else g:rect(x, y, 20, 20, { radius = 5, line_width = 2 }) end
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
    md = string.format("周%s", wd[(now.weekday or 0) % 7 + 1] or "")
  end
  text(g, 20, 21, hm, F.b22, { valign = "middle", bold = true })
  text(g, 20 + F.b22:measure(hm, { bold = true }) + 12, 21, md, F.s18, { valign = "middle" })
  local b = CTX.device:battery()
  local pills = { { ((b and b.percent and b.percent >= 0) and b.percent or "--") .. "%" } }
  local nask = #asks_for()
  if nask > 0 then pills[#pills + 1] = { "等你 " .. nask .. " 个", true } end
  if S.conn == "ok" then pills[#pills + 1] = { "已连接", true }
  elseif S.conn == "lost" then pills[#pills + 1] = { "连不上电脑", false }
  elseif S.conn == "connecting" then pills[#pills + 1] = { "连接中…", false }
  else pills[#pills + 1] = { "未连接", false } end
  local x = 784
  for _, p in ipairs(pills) do
    local w = F.s18:measure(p[1]) + 24
    x = x - w
    if p[2] then g:rect(x, 6, w, 30, { radius = 15, fill = true })
    else g:rect(x, 6, w, 30, { radius = 15, line_width = 2 }) end
    text(g, x + w // 2, 21, p[1], F.s18, { align = "center", valign = "middle", color = p[2] and 0 or 15 })
    x = x - 8
  end
  g:rect(0, 42, 800, 2, { fill = true })
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

-- 底栏：每个会话一颗胶囊，只写会话名
local function draw_dock(g, cur)
  g:rect(0, 412, 800, 2, { fill = true })
  local ss = sessions()
  if #ss == 0 then
    text(g, 20, 446, S.conn == "ok" and "电脑上还没有智能体在跑" or "连上后，这里列出每个智能体", F.s18, { valign = "middle" })
  end
  local x = 14
  for _, s in ipairs(ss) do
    local on = cur and s.id == cur.id
    local name = fit(label(s), F.s18, 150)
    local w = 6 + 30 + 10 + F.s18:measure(name, { bold = true }) + 16
    local n = #asks_for(s.id)
    local mark = n > 0 and tostring(n) or (s.state == "error" and "!" or nil)
    if mark then w = w + 30 end
    if x + w > 728 then break end
    if on then g:rect(x, 422, w, 48, { radius = 14, fill = true })
    else g:rect(x, 422, w, 48, { radius = 14, line_width = 2 }) end
    local c = on and 0 or 15
    g:rect(x + 8, 431, 30, 30, { radius = 8, line_width = 2, color = c })
    text(g, x + 23, 446, ({ dsh = "DS", claude = "CC", codex = "CX" })[s.source] or "AI", F.s18, { align = "center", valign = "middle", color = c, bold = true })
    text(g, x + 46, 446, name, F.s18, { valign = "middle", color = c, bold = true })
    if mark then
      g:circle(x + w - 22, 446, 12, { fill = true, color = on and 0 or 15 })
      text(g, x + w - 22, 446, mark, F.s18, { align = "center", valign = "middle", color = on and 15 or 0, bold = true })
    end
    hit(x, 422, w, 48, function() S.sel = s.id; CTX:invalidate() end)
    x = x + w + 8
  end
  draw_gear(g)
end

-- 一行带圆点序号的步骤
local function step_line(g, y, n, s)
  g:circle(IX + 13, y, 13, { fill = true })
  text(g, IX + 13, y, n, F.s18, { align = "center", valign = "middle", color = 0, bold = true })
  text(g, IX + 36, y, fit(s, F.s18, IW - 36), F.s18, { valign = "middle" })
end

-- ① 配对
local function screen_pair(g)
  local lost = S.conn == "lost"
  stage(g, lost and "sleepy" or "hello", lost and "找不到电脑" or "你好，我是墨守", S.err or "帮你盯着电脑上的 AI")
  local y = card_head(g, nil, "连接你的电脑")
  step_line(g, y + 18, "1", "电脑上运行安装命令，见")
  g:rect(IX + 36, y + 40, IW - 36, 38, { radius = 8, fill = true })
  text(g, IX + 48, y + 59, fit("github.com/linchuanXu/inkwatch", F.s18, IW - 60), F.s18, { valign = "middle", color = 0 })
  step_line(g, y + 106, "2", "填入终端显示的地址和配对码")
  local l = CTX.state.link
  button(g, IX, BOTTOM - 60, IW, 60, l and "重新填写" or "填写地址和配对码", true, ask_link)
end

-- ② 空闲
local function screen_idle(g, cur)
  local t = S.data.today or {}
  stage(g, "sleepy", "待命中", "有事叫我")
  local y = card_head(g, nil, "今天")
  local m = num(t.minutes)
  y = stat_boxes(g, y, { { "完成", tostring(num(t.done)) }, { "用时", m >= 60 and ((m // 60) .. "h" .. (m % 60)) or (m .. "分") }, { "审批", tostring(num(t.asks)) } })
  local recent = list(t.recent)
  if #recent == 0 then text(g, IX, y + 18, "今天还没有完成的任务", F.s18, { valign = "middle" }) end
  for i, r in ipairs(recent) do
    if i > 3 or y + 36 > BOTTOM then break end
    check(g, IX, y + 8, "done")
    text(g, IX + 32, y + 18, fit(r.title, F.s18, IW - 32), F.s18, { valign = "middle" })
    y = y + 40
  end
end

-- ③ 干活：左边一句「正在做什么」，右边只列计划
local function screen_work(g, s)
  local todos = list(s.todos)
  local line2
  if #todos > 0 then
    local done = 0
    for _, t in ipairs(todos) do if t.status == "completed" then done = done + 1 end end
    line2 = "第 " .. math.min(#todos, done + 1) .. "/" .. #todos .. " 步 · " .. dur(s.elapsed)
  else
    line2 = "已 " .. dur(s.elapsed)
  end
  stage(g, "think", str(s.step) ~= "" and str(s.step) or "思考中", line2)
  local y = card_head(g, s.source, label(s), "进行中", true)
  local items = {}
  if #todos > 0 then
    for _, t in ipairs(todos) do items[#items + 1] = { t.text, t.status == "completed" and "done" or (t.status == "in_progress" and "run" or "todo") } end
  else
    for _, st in ipairs(list(s.steps)) do items[#items + 1] = { st.text, st.done and "done" or "run" } end
  end
  local maxn = (BOTTOM - y) // 42
  local first = math.max(1, #items - maxn + 1)
  for i = first, #items do
    local it = items[i]
    check(g, IX, y + 9, it[2])
    text(g, IX + 32, y + 19, fit(it[1], F.s18, IW - 32), F.s18, { valign = "middle", bold = it[2] == "run" })
    y = y + 42
  end
end

-- ④ 审批：大字写要做什么，按钮要大
local function screen_ask(g, s, a)
  stage(g, "ask", "等你确认", "已等 " .. dur(num(S.data.now) - num(a.at)))
  local y = card_head(g, a.source, label(a))
  local act = str(a.action) ~= "" and str(a.action) or str(a.why)
  g:rect(IX, y, IW, 58, { radius = 10, fill = true })
  text(g, IX + IW // 2, y + 29, fit(act, F.b28, IW - 24), F.b28, { align = "center", valign = "middle", color = 0, bold = true })
  y = y + 76
  if str(a.why) ~= "" and str(a.why) ~= act then
    text(g, IX, y, fit("原因：" .. str(a.why), F.s18, IW), F.s18, { valign = "middle" })
  end
  local bw = (IW - 10) // 2
  local by = BOTTOM - 60 - 10 - 52
  button(g, IX, by, bw, 60, "拒绝", false, function() post("/answer", { id = a.id, answer = "deny" }) end)
  button(g, IX + bw + 10, by, bw, 60, "允许", true, function() post("/answer", { id = a.id, answer = "allow" }) end)
  button(g, IX, by + 70, bw, 52, "电脑上看", false, function() post("/answer", { id = a.id, answer = "pass" }) end, F.s18)
  button(g, IX + bw + 10, by + 70, bw, 52, "本会话都允许", false, function() post("/answer", { id = a.id, answer = "session" }) end, F.s18)
end

-- ⑤ 卡住
local function screen_error(g, s)
  local e = s.error ~= CTX.json.null and s.error or {}
  stage(g, "angry", "卡住了", str(e.cmd) ~= "" and ("跑 " .. str(e.cmd) .. " 出错") or "出错了")
  local y = card_head(g, s.source, label(s), "出错", true)
  local tail = list(e.tail)
  local lh = 30
  local n = math.min(#tail, 3)
  for i = #tail - n + 1, #tail do
    text(g, IX, y + 15, fit(tail[i], F.s18, IW), F.s18, { valign = "middle" })
    y = y + lh
  end
  button(g, IX, BOTTOM - 60, IW, 60, "知道了", true, function() post("/ack", { id = s.id }) end)
end

-- ⑥ 完成
local function screen_done(g, s)
  stage(g, "happy", "做完啦", "用时 " .. dur(s.elapsed))
  local y = card_head(g, s.source, label(s), "完成")
  local summary = str(s.summary) ~= "" and s.summary or s.prompt
  local lh = F.s18.line_height
  g:text_box(IX, y, IW, lh * 3, (str(summary):gsub("\n", " ")), { font = F.s18, wrap = "char", overflow = "ellipsis" })
  y = y + lh * 3 + 12
  stat_boxes(g, y, { { "改文件", tostring(#list(s.files)) }, { "工具", tostring(num(s.tools)) }, { "Token", tok(s.tokens) } })
  button(g, IX, BOTTOM - 56, IW, 56, "知道了", true, function() post("/ack", { id = s.id }) end)
end

---------------------------------------------------------------- 生命周期
function on_load(ctx)
  CTX = ctx
  CLASSIC = not ctx.input.pointer
  ctx.budget:extend()
  F.s18 = font_px(18)
  F.b22 = font_px(22)
  F.b28 = font_px(28)
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
    g:rect(320, 218, 160, 44, { radius = 22, fill = true })
    text(g, 400, 240, "发送中…", F.b22, { align = "center", valign = "middle", color = 0 })
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
