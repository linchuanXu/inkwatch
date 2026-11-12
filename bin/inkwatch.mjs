#!/usr/bin/env node
// inkwatch：电脑端小程序。三个角色共用一个文件：
//   inkwatch serve           常驻：局域网 HTTP 服务，X4 来取状态、回传审批
//   inkwatch hook <来源>      被智能体的 hooks 调用：读 stdin 事件，转给 serve；PreToolUse 时等 X4 的决定
//   inkwatch install          给 DSH / Claude Code / Codex 装上钩子
//   inkwatch pair / status    显示 X4 要填的地址和配对码
//   inkwatch status           后台服务是否在跑，地址和配对码
//   inkwatch uninstall        卸载钩子和开机自启
// 只用 Node 自带模块，不需要 npm install。Mac / Windows / Linux 同一份。
import http from 'node:http'
import { execFileSync, spawn } from 'node:child_process'
import os from 'node:os'
import fs from 'node:fs'
import path from 'node:path'
import crypto from 'node:crypto'
import { fileURLToPath } from 'node:url'
import zlib from 'node:zlib'

const HOME = os.homedir()
const SELF = fileURLToPath(import.meta.url)
// 装好的那份脚本和配置在同一个目录：钩子由智能体拉起时，按脚本所在目录找配置，不依赖环境变量
const DIR = process.env.INKWATCH_HOME ||
  (fs.existsSync(path.join(path.dirname(SELF), 'config.json')) ? path.dirname(SELF) : path.join(HOME, '.inkwatch'))
const CONF = path.join(DIR, 'config.json')
const PORT_DEFAULT = 47320
const WIN = process.platform === 'win32'
const MAC = process.platform === 'darwin'
// 装好后脚本固定放在这里，钩子和开机自启都指向它（npx 的缓存目录随时会被清掉）
const INSTALLED = path.join(DIR, 'inkwatch.mjs')

fs.mkdirSync(DIR, { recursive: true })

function loadConf() {
  let c = {}
  try { c = JSON.parse(fs.readFileSync(CONF, 'utf8')) } catch {}
  let dirty = false
  if (!c.port) { c.port = PORT_DEFAULT; dirty = true }
  if (!c.code) { c.code = randomCode(); dirty = true }
  if (!c.secret) { c.secret = crypto.randomBytes(16).toString('hex'); dirty = true }
  if (!c.approve) { c.approve = 'risky'; dirty = true } // risky | all | none
  if (dirty) saveConf(c)
  return c
}
function saveConf(c) {
  fs.writeFileSync(CONF, JSON.stringify(c, null, 2), { mode: 0o600 })
}
function randomCode() {
  const A = '23456789ABCDEFGHJKMNPQRSTUVWXYZ' // 去掉 0 O 1 I L，墨水屏小字也不会认错
  let s = ''
  for (const b of crypto.randomBytes(4)) s += A[b % A.length]
  return s
}
function lanIPs() {
  const out = []
  for (const [name, list] of Object.entries(os.networkInterfaces())) {
    for (const a of list || []) {
      if (a.family !== 'IPv4' && a.family !== 4) continue
      if (a.internal || a.address.startsWith('169.254.')) continue
      if (/^(utun|bridge|vEthernet|VirtualBox|VMware|docker|br-|vboxnet)/i.test(name)) continue
      out.push(a.address)
    }
  }
  return out
}
function nowSec() { return Math.floor(Date.now() / 1000) }
function cap(s, n) {
  s = String(s ?? '')
  return s.length > n ? s.slice(0, n - 1) + '…' : s
}
function home(p) { return p && p.startsWith(HOME) ? '~' + p.slice(HOME.length) : p }

// ------------------------------------------------------------------ 风险判断
// 只有「改不回来 / 出门」的命令才停下来等 X4。普通读写不打扰。
const RISKY = [
  [/\bgit\s+push\b/, '推送到远端'],
  [/\bgit\s+(reset\s+--hard|clean\s+-[a-z]*f|checkout\s+--\s|branch\s+-D|rebase\b|filter-branch)/, '改写或丢弃 Git 历史'],
  [/\brm\s+(-[a-zA-Z]*[rf]|.*\*)/, '删除文件'],
  [/\b(sudo|chmod\s+-R|chown\s+-R)\b/, '提权或批量改权限'],
  [/\b(npm|pnpm|yarn)\s+publish\b|\btwine\s+upload\b|\bcargo\s+publish\b/, '发布软件包'],
  [/\b(kubectl\s+(apply|delete|rollout|set)|terraform\s+(apply|destroy)|helm\s+(install|upgrade|uninstall))\b/, '改线上环境'],
  [/\bcurl\b.*\s-X\s*(POST|PUT|DELETE|PATCH)\b|\bcurl\b.*\s(-d|--data)\b/, '向外部发送数据'],
  [/\b(drop\s+(table|database)|truncate\s+table|delete\s+from)\b/i, '删除数据库数据'],
  [/\bdd\s+if=|\bmkfs\b|\bdiskutil\s+(erase|partition)/, '改写磁盘'],
  // Windows / PowerShell
  [/\b(Remove-Item|rd|rmdir|del|erase)\b.*(-Recurse|-Force|\/s\b|\/q\b)/i, '删除文件'],
  [/\b(Format-Volume|Clear-Disk|diskpart)\b/i, '改写磁盘'],
  [/\bStart-Process\b.*-Verb\s+RunAs|\brunas\b/i, '提权'],
  [/\bInvoke-(WebRequest|RestMethod)\b.*-Method\s+(Post|Put|Delete|Patch)/i, '向外部发送数据'],
  [/\breg\s+(delete|add)\b|\bSet-ItemProperty\b.*HK(LM|CU):/i, '改注册表'],
]
function riskOf(tool, input) {
  const t = String(tool || '').toLowerCase()
  if (!/bash|shell|exec|pwsh|command/.test(t)) return null
  const cmd = String(input?.command ?? input?.cmd ?? (Array.isArray(input) ? input.join(' ') : ''))
  for (const [re, why] of RISKY) if (re.test(cmd)) return why
  return null
}

// ------------------------------------------------------------------ 把事件翻成墨水屏能看懂的一行
// 屏上一律显示「人话」：命令翻成动作，文件只留文件名，内部记账类工具不显示
function describeTool(tool, input) {
  const t = String(tool || '')
  const lt = t.toLowerCase()
  input = input || {}
  const file = input.file_path || input.path || input.filePath || input.notebook_path
  if (/^mcp__/.test(lt)) return describeMcp(lt, input)
  if (/bash|shell|exec|pwsh|command/.test(lt)) {
    const raw = String(input.command ?? input.cmd ?? '')
    return { kind: 'run', text: describeCommand(raw), raw: cap(raw, 300) }
  }
  if (/^(read|view)$/.test(lt) || lt === 'read_file') return { kind: 'read', text: `读 ${base(file)}`, file }
  if (/^(write|create)/.test(lt)) return { kind: 'write', text: `写 ${base(file)}`, file }
  if (/edit|replace|patch/.test(lt)) return { kind: 'edit', text: `改 ${base(file)}`, file }
  if (/glob|grep|search|find|^ls$/.test(lt)) return { kind: 'search', text: '查找文件' }
  if (/web|fetch|browse/.test(lt)) return { kind: 'web', text: /search/.test(lt) ? '上网搜索' : `看网页 ${hostOf(input.url)}`.trim() }
  if (/todo/.test(lt)) return { kind: 'plan', text: '更新计划' }
  if (/task|agent|subagent|spawn/.test(lt)) return { kind: 'agent', text: `派子代理${input.description ? '：' + cap(input.description, 24) : ''}` }
  if (/ask|question/.test(lt)) return { kind: 'ask', text: '问你一个问题' }
  return { kind: 'tool', text: '使用工具' }
}
function base(p) { return p ? path.basename(String(p)) : '' }
function short(p) { return base(p) }
function hostOf(u) { try { return new URL(String(u)).hostname.replace(/^www\./, '') } catch { return '' } }

// MCP 工具：mcp__服务__方法。宿主自己的记账工具隐藏，其他按服务名给个中文说法
const MCP_HIDE = /update_plan|wrap_up|mark_chapter|todo/
const MCP_NAMES = [
  [/figma/, '操作 Figma'], [/feishu|lark/, '操作飞书'], [/github/, '操作 GitHub'], [/browser|preview|playwright|chrome/, '操作浏览器'],
  [/codegraph/, '查代码结构'], [/xtapp/, '操作 XTApp 预览'], [/slack/, '操作 Slack'], [/notion/, '操作 Notion'],
  [/session|sidebar|window|view/, '管理会话'], [/terminal/, '操作终端'], [/sched|cron/, '安排定时任务'],
]
function describeMcp(lt, input) {
  if (MCP_HIDE.test(lt)) return { kind: 'hidden', text: '' }
  for (const [re, name] of MCP_NAMES) if (re.test(lt)) return { kind: 'tool', text: name }
  return { kind: 'tool', text: '使用工具' }
}

// shell 命令 → 动作。只看第一条有意义的命令（跳过 cd、export、变量赋值、sleep）
const CMD_RULES = [
  [/^git\s+push\b.*(--force|-f\b)/, '强制推送代码'], [/^git\s+push\b/, '推送代码'], [/^git\s+(pull|fetch)\b/, '拉取代码'],
  [/^git\s+commit\b/, '提交代码'], [/^git\s+(add|restore|rm)\b/, '整理改动'], [/^git\s+(diff|show)\b/, '看代码改动'],
  [/^git\s+(status|log|branch|remote|rev-parse)\b/, '看 Git 状态'], [/^git\s+(checkout|switch|merge|rebase|reset|stash|cherry-pick)\b/, '切换或合并分支'],
  [/^git\s+clone\b/, '下载仓库'], [/^gh\s+pr\b/, '处理 PR'], [/^gh\s+/, '操作 GitHub'],
  [/^(npm|pnpm|yarn|bun)\s+(i|install|add|ci)\b/, '安装依赖'], [/^(npm|pnpm|yarn|bun)\s+(run\s+)?(test|vitest|jest)\b/, '跑测试'],
  [/^(npm|pnpm|yarn|bun)\s+(run\s+)?build\b/, '构建项目'], [/^(npm|pnpm|yarn|bun)\s+(run\s+)?(dev|start|serve)\b/, '启动服务'],
  [/^(npm|pnpm|yarn|bun)\s+(run\s+)?(lint|format|typecheck|check)\b/, '检查代码'], [/^(npm|pnpm|yarn|bun)\s+publish\b/, '发布软件包'],
  [/^(npx|pnpm\s+dlx|bunx)\s+(vitest|jest|playwright)\b/, '跑测试'], [/^(pytest|python3?\s+-m\s+pytest|go\s+test|cargo\s+test|make\s+test)\b/, '跑测试'],
  [/^(pip3?|uv|poetry)\s+(install|add|sync)\b/, '安装依赖'], [/^(make|cmake|cargo\s+build|go\s+build|idf\.py)\b/, '编译'],
  [/^(python3?|node|deno|bun|ruby|perl|php|go\s+run|cargo\s+run)\b\s+(-[a-zA-Z]+\s+)*("[^"]+"|'[^']+'|[^\s|;&]+)/, (m) => /^-/.test(m[3]) ? '运行脚本' : `运行 ${base(m[3].replace(/["']/g, ''))}`],
  [/^(python3?|node)\b/, '运行脚本'], [/^(sh|bash|zsh)\s+([^\s|;&]+)/, (m) => `运行 ${base(m[2].replace(/["']/g, ''))}`],
  [/^(curl|wget|http|iwr|Invoke-WebRequest)\b/, '请求网络'], [/^(ssh|scp|rsync)\b/, '连接远程机器'],
  [/^(kubectl|helm|terraform|docker|docker-compose)\b/, '操作部署环境'],
  [/^(ls|tree|find|fd|du|stat|file|wc|Get-ChildItem)\b/, '查看文件'], [/^(cat|head|tail|less|sed\s+-n|bat|Get-Content|nl|jq)\b/, '读文件'],
  [/^(grep|rg|ag|ack|Select-String)\b/, '搜索代码'], [/^(mkdir|New-Item)\b/, '建文件夹'], [/^(cp|mv|ln|Copy-Item|Move-Item)\b/, '整理文件'],
  [/^(rm|rmdir|del|Remove-Item)\b/, '删除文件'], [/^(chmod|chown)\b/, '改文件权限'], [/^(sed|perl|awk)\b/, '批量改文本'],
  [/^(echo|printf|true|test|\[)\b/, '输出信息'], [/^(open|code|cursor)\b/, '打开文件'], [/^(sudo)\b/, '用管理员权限运行'],
  [/^(ps|top|kill|pkill|lsof)\b/, '查看进程'], [/^(diskutil|hdiutil)\b/, '操作磁盘'], [/^(brew|apt|apt-get|winget|choco)\b/, '安装软件'],
  [/^(tar|zip|unzip|gzip)\b/, '打包或解压'], [/^(ffmpeg|magick|convert|sips)\b/, '处理图片或视频'], [/^(sqlite3|psql|mysql|redis-cli)\b/, '查数据库'],
  [/^(ds|opencode|claude|codex|dsh)\b/, '调用另一个 AI'], [/^(lark-cli)\b/, '操作飞书'],
]
function describeCommand(raw) {
  // 拆成多条，跳过 cd / export / 赋值 / sleep / set
  const parts = String(raw).replace(/\\\n/g, ' ').replace(/\$\([^)]*\)/g, 'X').split(/&&|\|\||;|\n|\|/).map((x) => x.trim()).filter(Boolean)
  for (let p of parts) {
    p = p.replace(/^\(+|\)+$/g, '').replace(/^(\w+=("[^"]*"|'[^']*'|\S*)\s+)+/, '').trim()
    if (!p || /^(cd|pushd|popd|export|set|source|\.|sleep|for|do|done|if|then|fi|else|while|local|mkdir\s+-p\s+\/tmp)\b/.test(p) || /^\w+=/.test(p)) continue
    for (const [re, out] of CMD_RULES) {
      const m = p.match(re)
      if (m) return typeof out === 'function' ? out(m) : out
    }
    const word = base(p.split(/\s+/)[0].replace(/["']/g, ''))
    return /^[\w.-]{1,20}$/.test(word) ? `运行 ${word}` : '运行命令'
  }
  return '运行命令'
}

// 会话名：优先用智能体自己起的标题，其次是你第一句话，最后才是项目文件夹
function shortTitle(s) {
  s = String(s || '').replace(/\s+/g, ' ').replace(/[`*_#>]/g, '').trim()
  // 去掉常见的开头客套
  s = s.replace(/^(帮我|请|麻烦|你|能不能|可以)+/, '')
  const cut = s.split(/[，。！？,.!?；;：:\n]/)[0] || s
  return cap(cut, 16)
}
function claudeTitle(transcript) {
  // 只读文件末尾 256 KB，找最后一条 custom-title / ai-title / summary
  try {
    if (!transcript || !fs.existsSync(transcript)) return ''
    const st = fs.statSync(transcript)
    const n = Math.min(st.size, 256 * 1024)
    const fd = fs.openSync(transcript, 'r')
    const buf = Buffer.alloc(n)
    fs.readSync(fd, buf, 0, n, st.size - n)
    fs.closeSync(fd)
    const lines = buf.toString('utf8').split('\n')
    for (let i = lines.length - 1; i >= 0; i--) {
      const l = lines[i]
      if (!/"(custom-title|ai-title|summary)"/.test(l)) continue
      try {
        const e = JSON.parse(l)
        const t = e.customTitle || e.aiTitle || e.title || e.summary
        if (t) return String(t)
      } catch {}
    }
  } catch {}
  return ''
}
function folderOf(cwd) {
  // 往上找 git 根目录当项目名；找不到就用当前文件夹
  let d = cwd
  for (let i = 0; d && i < 8; i++) {
    if (fs.existsSync(path.join(d, '.git'))) return path.basename(d)
    const up = path.dirname(d)
    if (up === d) break
    d = up
  }
  return path.basename(cwd || '') || ''
}
function parseInput(v) {
  if (v && typeof v === 'object') return v
  if (typeof v === 'string') { try { return JSON.parse(v) } catch { return { command: v } } }
  return {}
}

// ------------------------------------------------------------------ 结束时补充：最后一句话、标题、Token
// DSH 的钩子不给 transcript_path，直接读它的会话日志（多段 zstd 拼接的 JSONL，Node 22.15+ 自带解压）
function readDshSession(sessionId) {
  try {
    if (!zlib.zstdDecompressSync) return null
    const root = path.join(process.env.DSH_HOME || path.join(HOME, '.dsh'), 'sessions')
    let file = null
    for (const d of fs.readdirSync(root)) {
      const f = path.join(root, d, sessionId, 'session.v4.jsonl.zstd')
      if (fs.existsSync(f)) { file = f; break }
    }
    if (!file) return null
    const b = fs.readFileSync(file)
    const M = Buffer.from([0x28, 0xb5, 0x2f, 0xfd])
    const at = []
    for (let i = b.indexOf(M); i >= 0; i = b.indexOf(M, i + 4)) at.push(i)
    let text = ''
    for (let k = 0; k < at.length; k++) {
      try { text += zlib.zstdDecompressSync(b.subarray(at[k], at[k + 1] ?? b.length)).toString() } catch {}
    }
    let last = '', title = '', tokens = 0
    for (const line of text.split('\n')) {
      if (!line) continue
      let e
      try { e = JSON.parse(line) } catch { continue }
      if (e.type === 'assistant/message') {
        const t = (e.data?.message?.content || []).filter((c) => c.type === 'text').map((c) => c.text).join('')
        if (t) last = t
      } else if (e.type === 'session/title') title = e.data?.title || title
      const u = e.data?.usage
      if (u && typeof u.totalTokens === 'number') tokens += u.totalTokens
    }
    return { last, title, tokens }
  } catch { return null }
}

// Claude Code / Codex：读 transcript_path（JSONL）里最后一条助手文字和 token 合计
function readTranscript(p) {
  try {
    if (!p || !fs.existsSync(p)) return null
    let last = '', tokens = 0
    for (const line of fs.readFileSync(p, 'utf8').split('\n')) {
      if (!line) continue
      let e
      try { e = JSON.parse(line) } catch { continue }
      const m = e.message || e.payload || e
      if ((m.role === 'assistant' || e.type === 'assistant') && Array.isArray(m.content)) {
        const t = m.content.filter((c) => c.type === 'text' || c.type === 'output_text').map((c) => c.text).join('')
        if (t) last = t
      }
      const u = m.usage
      if (u) tokens += (u.input_tokens || 0) + (u.output_tokens || 0) + (u.cache_read_input_tokens || 0)
    }
    return { last, tokens }
  } catch { return null }
}

// ------------------------------------------------------------------ serve：会话状态
const SOURCES = { dsh: 'DSH', claude: 'Claude Code', codex: 'Codex' }
const sessions = new Map()   // id -> 会话
const pending = new Map()    // 审批 id -> { session, resolve, ... }
const history = []           // 今天完成的任务（最多 30 条）
let today = { day: dayKey(), done: 0, ms: 0, asks: 0, askMs: 0 }
let rev = 1
let lastPoll = 0

function dayKey() { const d = new Date(); return `${d.getFullYear()}-${d.getMonth() + 1}-${d.getDate()}` }
function rollDay() {
  if (today.day !== dayKey()) { today = { day: dayKey(), done: 0, ms: 0, asks: 0, askMs: 0 }; history.length = 0 }
}
const waiters = new Set() // X4 的长轮询：状态一变立刻回
function bump() { rev++; for (const w of waiters) w() }

function sessionFor(source, ev) {
  const id = `${source}:${ev.session_id || 'default'}`
  let s = sessions.get(id)
  if (!s) {
    s = {
      id, source, name: SOURCES[source] || source,
      // 项目名只在第一次见到时定下来，之后智能体 cd 到哪都不变
      project: folderOf(ev.cwd) || '未命名项目', cwd: ev.cwd || '',
      state: 'idle', prompt: '', firstPrompt: '', title: '', step: '', steps: [], todos: null, files: {},
      tools: 0, subagents: 0, started: 0, updated: nowSec(), error: null, summary: '', titleAt: 0,
    }
    sessions.set(id, s)
  }
  if (ev.transcript_path) s.transcript = ev.transcript_path
  // Claude Code 的标题在会话记录里，最多 30 秒读一次
  if (s.transcript && nowSec() - s.titleAt > 30) {
    s.titleAt = nowSec()
    const t = claudeTitle(s.transcript)
    if (t) s.title = t
  }
  s.updated = nowSec()
  return s
}
function labelOf(s) {
  return shortTitle(s.title) || shortTitle(s.firstPrompt) || s.project
}

function pushStep(s, text) {
  if (!text) return
  const last = s.steps[s.steps.length - 1]
  if (last && last.text === text) return
  if (last && !last.done) { last.done = true; last.sec = nowSec() - last.at }
  s.steps.push({ text, at: nowSec(), done: false })
  while (s.steps.length > 6) s.steps.shift()
}

function onEvent(source, ev) {
  rollDay()
  const s = sessionFor(source, ev)
  const name = ev.hook_event_name
  if (name === 'SessionStart') {
    if (s.state === 'done' || s.state === 'error') s.state = 'idle'
  } else if (name === 'UserPromptSubmit') {
    if (!s.firstPrompt && ev.prompt && !/^\s*</.test(ev.prompt)) s.firstPrompt = String(ev.prompt)
    // DSH 的会话标题由模型几秒后起好，写在它的会话日志里
    if (source === 'dsh' && !s.title) setTimeout(() => { const x = readDshSession(ev.session_id); if (x?.title) { s.title = x.title; bump() } }, 8000)
    Object.assign(s, { state: 'work', prompt: cap(ev.prompt, 200), step: '思考中', steps: [], todos: null, files: {}, tools: 0, subagents: 0, started: Date.now(), error: null, summary: '' })
  } else if (name === 'PreToolUse') {
    if (s.state !== 'work') { s.state = 'work'; if (!s.started) s.started = Date.now() }
    const input = parseInput(ev.tool_input)
    const d = describeTool(ev.tool_name, input)
    if (d.kind === 'hidden') { bump(); return }
    s.step = d.text
    s.tools++
    if (d.kind === 'plan' && Array.isArray(input.todos)) {
      s.todos = input.todos.slice(0, 8).map((t) => ({ text: cap(t.content ?? t.text ?? '', 60), status: t.status }))
    } else if (d.kind === 'agent') {
      s.subagents++
      pushStep(s, d.text)
    } else if (d.kind !== 'read' && d.kind !== 'search') {
      pushStep(s, d.text)
    }
  } else if (name === 'PostToolUse') {
    const input = parseInput(ev.tool_input)
    const d = describeTool(ev.tool_name, input)
    if ((d.kind === 'write' || d.kind === 'edit') && d.file) {
      const f = s.files[d.file] || (s.files[d.file] = { add: 0, del: 0 })
      const before = String(input.old_string ?? '').split('\n').length - (input.old_string ? 0 : 1)
      const after = String(input.new_string ?? input.content ?? '').split('\n').length
      f.add += after; f.del += Math.max(0, before)
    }
    const resp = String(ev.tool_response ?? '')
    if (d.kind === 'run' && /\b(FAIL|failed|Error:|error:|Traceback|ERR!)\b/.test(resp)) {
      s.error = { cmd: d.text, tail: resp.trim().split('\n').slice(-4).map((l) => cap(l, 70)) }
    } else if (d.kind === 'run') {
      s.error = null
    }
    if (d.kind === 'agent') s.subagents = Math.max(0, s.subagents - 1)
  } else if (name === 'Stop' || name === 'SubagentStop') {
    if (name === 'SubagentStop') { s.subagents = Math.max(0, s.subagents - 1); bump(); return }
    const last = s.steps[s.steps.length - 1]
    if (last && !last.done) { last.done = true; last.sec = nowSec() - last.at }
    const ms = s.started ? Date.now() - s.started : 0
    s.state = s.error ? 'error' : 'done'
    s.elapsed = Math.round(ms / 1000)
    const extra = source === 'dsh' ? readDshSession(ev.session_id) : readTranscript(ev.transcript_path)
    s.summary = cap(ev.last_assistant_message || extra?.last || '', 240).replace(/`/g, '')
    if (extra?.title) s.title = extra.title
    s.tokens = extra?.tokens || 0
    s.doneAt = nowSec()
    if (!s.error) {
      today.done++; today.ms += ms
      history.unshift({ source: s.source, project: s.project, title: labelOf(s), at: nowSec() })
      while (history.length > 30) history.pop()
    }
    s.started = 0
    if (source === 'dsh') setTimeout(() => {
      const x = readDshSession(ev.session_id)
      if (x) { s.summary = cap(x.last, 240).replace(/`/g, ''); s.title = x.title || s.title; s.tokens = x.tokens; bump() }
    }, 2500)
  }
  bump()
}

// 审批：hook 进程把请求挂在这里，等 X4 回答；X4 不在或超时就交还给智能体自己的审批界面
function askApproval(source, ev, why, waitMs) {
  rollDay()
  const s = sessionFor(source, ev)
  const input = parseInput(ev.tool_input)
  const id = crypto.randomBytes(6).toString('hex')
  const req = {
    id, session: s.id, source: s.source, name: s.name, project: s.project, label: labelOf(s), cwd: home(s.cwd),
    action: describeTool(ev.tool_name, input).text,
    tool: ev.tool_name, command: cap(input.command ?? input.cmd ?? JSON.stringify(input), 300),
    why, at: nowSec(),
  }
  s.state = 'ask'
  bump()
  return new Promise((resolve) => {
    const timer = setTimeout(() => finish('timeout'), waitMs)
    function finish(answer) {
      clearTimeout(timer)
      if (!pending.has(id)) return
      pending.delete(id)
      if (answer === 'allow' || answer === 'deny') { today.asks++; today.askMs += Date.now() - req.at * 1000 }
      if (answer === 'session') { s.allowAll = true; answer = 'allow'; today.asks++ }
      if (s.state === 'ask' && ![...pending.values()].some((p) => p.req.session === s.id)) s.state = 'work'
      bump()
      resolve(answer)
    }
    pending.set(id, { req, finish })
  })
}

function snapshot() {
  rollDay()
  // 20 分钟没动静、也没在等你的会话收起来
  for (const [id, s] of sessions) if (nowSec() - s.updated > 1200 && s.state !== 'ask') sessions.delete(id)
  const list = [...sessions.values()].sort((a, b) => b.updated - a.updated).slice(0, 4)
  const asks = [...pending.values()].map((p) => p.req).sort((a, b) => a.at - b.at)
  return {
    rev, now: nowSec(), host: os.hostname().replace(/\.local$/, ''),
    today: { done: today.done, minutes: Math.round(today.ms / 60000), asks: today.asks, ask_avg_sec: today.asks ? Math.round(today.askMs / today.asks / 1000) : 0, recent: history.slice(0, 4) },
    asks,
    sessions: list.map((s) => ({
      id: s.id, source: s.source, name: s.name, project: s.project, label: labelOf(s), state: s.state,
      prompt: s.prompt, step: s.step,
      steps: s.steps.map((x) => ({ text: x.text, done: x.done, sec: x.sec || 0 })),
      todos: s.todos, tools: s.tools, subagents: s.subagents,
      elapsed: s.state === 'work' && s.started ? Math.round((Date.now() - s.started) / 1000) : (s.elapsed || 0),
      files: Object.entries(s.files).slice(0, 5).map(([f, v]) => ({ file: short(f), add: v.add, del: v.del })),
      error: s.error, summary: s.summary, title: s.title || '', tokens: s.tokens || 0, updated: s.updated,
    })),
  }
}

// ------------------------------------------------------------------ serve：HTTP
function readBody(req) {
  return new Promise((resolve) => {
    let b = ''
    req.on('data', (c) => { b += c; if (b.length > 1e6) req.destroy() })
    req.on('end', () => resolve(b))
  })
}
function send(res, code, obj) {
  const body = JSON.stringify(obj)
  res.writeHead(code, { 'content-type': 'application/json; charset=utf-8', 'content-length': Buffer.byteLength(body) })
  res.end(body)
}

function serve() {
  const conf = loadConf()
  const server = http.createServer(async (req, res) => {
    const url = new URL(req.url, 'http://x')
    const local = req.socket.remoteAddress === '127.0.0.1' || req.socket.remoteAddress === '::1' || req.socket.remoteAddress === '::ffff:127.0.0.1'
    try {
      // 本机 hook 进程用 secret；X4 用配对码
      if (url.pathname === '/hook' && req.method === 'POST') {
        if (!local || req.headers['x-inkwatch-secret'] !== conf.secret) return send(res, 403, { error: 'forbidden' })
        const { source, event, approve } = JSON.parse(await readBody(req) || '{}')
        onEvent(source, event)
        if (approve) {
          const why = approve
          const x4Alive = Date.now() - lastPoll < 90000
          if (!x4Alive) return send(res, 200, { decision: 'pass' })
          const s = sessionFor(source, event)
          if (s.allowAll) return send(res, 200, { decision: 'allow' })
          const answer = await askApproval(source, event, why, 10 * 60 * 1000)
          return send(res, 200, { decision: answer === 'allow' ? 'allow' : answer === 'deny' ? 'deny' : 'pass' })
        }
        return send(res, 200, { ok: true })
      }
      if (url.pathname === '/health') return send(res, 200, { ok: true, app: 'inkwatch' })
      const code = (req.headers['x-inkwatch-code'] || url.searchParams.get('code') || '').toUpperCase()
      if (code !== conf.code) return send(res, 401, { error: 'bad_code' })
      lastPoll = Date.now()
      if (url.pathname === '/state') {
        const since = Number(url.searchParams.get('since') || 0)
        const wait = Math.min(25000, Number(url.searchParams.get('wait') || 0))
        if (since && since === rev && wait > 0) {
          await new Promise((r) => {
            const done = () => { clearTimeout(t); waiters.delete(done); r() }
            const t = setTimeout(done, wait)
            waiters.add(done)
            req.on('close', done)
          })
        }
        return send(res, 200, snapshot())
      }
      if (url.pathname === '/answer' && req.method === 'POST') {
        const { id, answer } = JSON.parse(await readBody(req) || '{}')
        const p = pending.get(id)
        if (!p) return send(res, 404, { error: 'gone' })
        if (!['allow', 'deny', 'session', 'pass'].includes(answer)) return send(res, 400, { error: 'bad_answer' })
        p.finish(answer)
        return send(res, 200, snapshot())
      }
      if (url.pathname === '/ack' && req.method === 'POST') {
        const { id } = JSON.parse(await readBody(req) || '{}')
        const s = sessions.get(id)
        if (s && (s.state === 'done' || s.state === 'error')) { s.state = 'idle'; bump() }
        return send(res, 200, snapshot())
      }
      return send(res, 404, { error: 'not_found' })
    } catch (e) {
      return send(res, 500, { error: String(e.message || e) })
    }
  })
  server.on('error', (e) => {
    if (e.code === 'EADDRINUSE') {
      console.log(`端口 ${conf.port} 已被占用：inkwatch 可能已经在后台运行（inkwatch status 查看）。`)
      process.exit(0)
    }
    throw e
  })
  server.listen(conf.port, '0.0.0.0', () => {
    printPair(conf)
    console.log('\n正在运行。电脑上的智能体一有动静，X4 就会更新。Ctrl-C 退出。')
  })
}
function printPair(conf) {
  const ips = lanIPs()
  console.log('\n  在 X4 的「墨守」里填：')
  console.log(`    电脑地址   ${ips[0] || '(没找到局域网地址)'}${conf.port === PORT_DEFAULT ? '' : ':' + conf.port}`)
  console.log(`    配对码     ${conf.code}`)
  if (ips.length > 1) console.log(`    其他地址   ${ips.slice(1).join('  ')}`)
}

// ------------------------------------------------------------------ hook：被智能体调用
async function hook(source) {
  const conf = loadConf()
  const raw = await new Promise((resolve) => {
    let b = ''
    process.stdin.on('data', (c) => { b += c })
    process.stdin.on('end', () => resolve(b))
  })
  let ev = {}
  try { ev = JSON.parse(raw || '{}') } catch { process.exit(0) }
  let approve = null
  if (ev.hook_event_name === 'PreToolUse' && conf.approve !== 'none') {
    approve = conf.approve === 'all' && /bash|shell|exec/i.test(ev.tool_name || '') ? '需要确认' : riskOf(ev.tool_name, parseInput(ev.tool_input))
  }
  const body = JSON.stringify({ source, event: ev, approve })
  const result = await new Promise((resolve) => {
    const req = http.request({ host: '127.0.0.1', port: conf.port, path: '/hook', method: 'POST', headers: { 'content-type': 'application/json', 'x-inkwatch-secret': conf.secret, 'content-length': Buffer.byteLength(body) }, timeout: approve ? 11 * 60 * 1000 : 3000 }, (res) => {
      let b = ''
      res.on('data', (c) => { b += c })
      res.on('end', () => { try { resolve(JSON.parse(b)) } catch { resolve({}) } })
    })
    req.on('error', () => resolve({})) // serve 没开：什么都不做，智能体照常
    req.on('timeout', () => { req.destroy(); resolve({}) })
    req.end(body)
  })
  if (approve && result.decision && result.decision !== 'pass') {
    const allow = result.decision === 'allow'
    const reason = allow ? '已在 X4 上允许' : '用户在 X4 上拒绝了这条命令'
    if (source === 'codex' && !allow) {
      // Codex 的钩子不认 permissionDecision：退出码 2 = 拦下，stderr 给模型看
      process.stderr.write(reason)
      process.exit(2)
    }
    if (source !== 'codex') {
      process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: allow ? 'allow' : 'deny', permissionDecisionReason: reason } }))
    }
  }
  process.exit(0)
}

// ------------------------------------------------------------------ install：装钩子
const EVENTS = ['SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'Stop', 'SubagentStop']
// 路径一律用正斜杠加双引号：cmd、PowerShell、Git Bash、sh 都认
function q(p) { return '"' + String(p).replace(/\\/g, '/') + '"' }
function hookCommand(source) {
  // Mac/Linux 写 node 的绝对路径（从图形界面启动的智能体常常没有 nvm 的 PATH）；
  // Windows 写 PATH 里的 node：PowerShell 不能直接执行带引号的程序路径
  return `${WIN ? 'node' : q(process.execPath)} ${q(INSTALLED)} hook ${source}`
}
function hooksFor(source, events = EVENTS) {
  const cmd = hookCommand(source)
  const out = {}
  for (const e of events) {
    const entry = { hooks: [{ type: 'command', command: cmd, timeout: e === 'PreToolUse' ? 660 : 10 }] }
    if (e === 'PreToolUse' || e === 'PostToolUse') entry.matcher = '*'
    out[e] = [entry]
  }
  return out
}
function mergeHooks(file, source, events) {
  let j = {}
  try { j = JSON.parse(fs.readFileSync(file, 'utf8')) } catch {}
  j.hooks = j.hooks || {}
  const add = hooksFor(source, events)
  for (const [e, list] of Object.entries(add)) {
    const keep = (j.hooks[e] || []).filter((g) => !JSON.stringify(g).includes('inkwatch'))
    j.hooks[e] = [...keep, ...list]
  }
  fs.mkdirSync(path.dirname(file), { recursive: true })
  if (fs.existsSync(file)) fs.copyFileSync(file, file + '.bak-inkwatch')
  fs.writeFileSync(file, JSON.stringify(j, null, 2))
}
function exists(cmd) {
  for (const d of (process.env.PATH || '').split(path.delimiter)) if (fs.existsSync(path.join(d, cmd))) return true
  return false
}

// ------------------------------------------------------------------ 开机自启
const PLIST = path.join(HOME, 'Library', 'LaunchAgents', 'com.inkwatch.serve.plist')
const STARTUP = path.join(process.env.APPDATA || path.join(HOME, 'AppData', 'Roaming'), 'Microsoft', 'Windows', 'Start Menu', 'Programs', 'Startup')
const STARTUP_VBS = path.join(STARTUP, 'InkWatch.vbs')
const LOG = path.join(DIR, 'serve.log')

function xmlEsc(s) { return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;') }

function autostartOn() {
  if (process.env.INKWATCH_NO_AUTOSTART) return '已跳过（INKWATCH_NO_AUTOSTART）'
  if (MAC) {
    const xml = [
      '<?xml version="1.0" encoding="UTF-8"?>',
      '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
      '<plist version="1.0"><dict>',
      '  <key>Label</key><string>com.inkwatch.serve</string>',
      `  <key>ProgramArguments</key><array><string>${xmlEsc(process.execPath)}</string><string>${xmlEsc(INSTALLED)}</string><string>serve</string></array>`,
      '  <key>RunAtLoad</key><true/>',
      '  <key>KeepAlive</key><true/>',
      `  <key>StandardOutPath</key><string>${xmlEsc(LOG)}</string>`,
      `  <key>StandardErrorPath</key><string>${xmlEsc(LOG)}</string>`,
      '</dict></plist>', '',
    ].join('\n')
    fs.mkdirSync(path.dirname(PLIST), { recursive: true })
    try { execFileSync('launchctl', ['unload', PLIST], { stdio: 'ignore' }) } catch {}
    fs.writeFileSync(PLIST, xml)
    execFileSync('launchctl', ['load', '-w', PLIST], { stdio: 'ignore' })
    return '登录后自动在后台运行'
  }
  if (WIN) {
    // 启动文件夹里放一个隐藏窗口的 VBS：登录后在后台运行；现在也立刻启动一次
    const Q = '""'
    const line = `sh.Run "${Q}${process.execPath}${Q} ${Q}${INSTALLED}${Q} serve", 0, False`
    fs.mkdirSync(STARTUP, { recursive: true })
    fs.writeFileSync(STARTUP_VBS, 'Set sh = CreateObject("WScript.Shell")\r\n' + line + '\r\n')
    spawn('wscript.exe', [STARTUP_VBS], { detached: true, stdio: 'ignore' }).unref()
    return '登录后自动在后台运行'
  }
  const out = fs.openSync(LOG, 'a')
  spawn(process.execPath, [INSTALLED, 'serve'], { detached: true, stdio: ['ignore', out, out] }).unref()
  return '已在后台运行（Linux 开机自启请自己加到 systemd --user）'
}
function autostartOff() {
  if (MAC && fs.existsSync(PLIST)) {
    try { execFileSync('launchctl', ['unload', '-w', PLIST], { stdio: 'ignore' }) } catch {}
    fs.rmSync(PLIST, { force: true })
  }
  if (WIN && fs.existsSync(STARTUP_VBS)) fs.rmSync(STARTUP_VBS, { force: true })
}
function ping(port) {
  return new Promise((resolve) => {
    const req = http.get({ host: '127.0.0.1', port, path: '/health', timeout: 1500 }, (res) => { res.resume(); resolve(res.statusCode === 200) })
    req.on('error', () => resolve(false))
    req.on('timeout', () => { req.destroy(); resolve(false) })
  })
}

async function install(args) {
  const want = args.length ? args : ['dsh', 'claude', 'codex']
  const done = []
  // 把自己复制到 ~/.inkwatch，钩子和自启都指向这份
  if (path.resolve(SELF) !== path.resolve(INSTALLED)) fs.copyFileSync(SELF, INSTALLED)
  loadConf()
  if (want.includes('dsh') && (exists('dsh') || fs.existsSync(path.join(HOME, '.dsh')))) {
    // DSH 用自带的 Claude Code 兼容桥读我们的 hooks.json；补丁写进每个 profile 的 cordis.patch.yml
    const hooksFile = path.join(DIR, 'dsh-hooks.json')
    fs.writeFileSync(hooksFile, JSON.stringify({ hooks: hooksFor('dsh') }, null, 2))
    const profiles = path.join(HOME, '.dsh', 'profiles')
    // 跳过 DSH 自己留的备份目录（web.backup-时间戳）
    const names = fs.existsSync(profiles) ? fs.readdirSync(profiles).filter((n) => !/\.backup-/.test(n) && fs.existsSync(path.join(profiles, n, 'cordis.patch.yml'))) : []
    const block = `\n# inkwatch: X4 状态屏（inkwatch uninstall 会删掉这段）\n- insert:\n    - id: inkwatch-hooks\n      name: '@deepseek-ai/dsh-hooks-claude-code'\n      config:\n        configPath: ${q(hooksFile)}\n# /inkwatch\n`
    for (const n of names) {
      const f = path.join(profiles, n, 'cordis.patch.yml')
      const txt = fs.readFileSync(f, 'utf8')
      if (txt.includes('inkwatch-hooks')) continue
      fs.copyFileSync(f, f + '.bak-inkwatch')
      // 补丁文件是一个 YAML 数组：空的写成「[]」，要换成列表项，不能在后面直接追加
      const body = txt.replace(/^\[\]\s*$/m, '').replace(/\s*$/, '\n')
      fs.writeFileSync(f, body + block)
    }
    const extra = path.join(DIR, 'dsh-patch.yml')
    fs.writeFileSync(extra, block.trimStart())
    done.push(`DSH（profile：${names.join('、') || '无'}；其他 profile 用 --patch ${home(extra)}）`)
  }
  if (want.includes('claude') && (exists('claude') || fs.existsSync(path.join(HOME, '.claude')))) {
    mergeHooks(path.join(HOME, '.claude', 'settings.json'), 'claude')
    done.push('Claude Code（~/.claude/settings.json）')
  }
  if (want.includes('codex') && (exists('codex') || fs.existsSync(path.join(HOME, '.codex')))) {
    mergeHooks(path.join(HOME, '.codex', 'hooks.json'), 'codex', ['SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'Stop'])
    done.push('Codex（~/.codex/hooks.json，需在 config.toml 打开 hooks 功能）')
  }
  console.log(done.length ? '已装好钩子：\n  ' + done.join('\n  ') : '没找到 DSH / Claude Code / Codex（装好它们后再运行一次 install）')
  console.log('后台服务：' + autostartOn())
  const conf = loadConf()
  let up = false
  for (let i = 0; i < 10 && !up; i++) {
    up = await ping(conf.port)
    if (!up) await new Promise((r) => setTimeout(r, 500))
  }
  console.log(up ? '后台服务：运行中' : '后台服务：还没起来，稍后运行 inkwatch status 看看')
  if (WIN) console.log('\n第一次运行时 Windows 防火墙会弹窗：勾选「专用网络」并点允许，否则 X4 连不上。')
  if (MAC) console.log('\n如果弹出「是否允许 node 接受传入网络连接」，点「允许」。')
  console.log('已经开着的智能体要重开一次，钩子才会生效。')
  printPair(conf)
}

function uninstall() {
  const profiles = path.join(HOME, '.dsh', 'profiles')
  if (fs.existsSync(profiles)) for (const n of fs.readdirSync(profiles)) {
    const f = path.join(profiles, n, 'cordis.patch.yml')
    if (!fs.existsSync(f)) continue
    const txt = fs.readFileSync(f, 'utf8')
    let cut = txt.replace(/\n?# inkwatch: X4[\s\S]*?# \/inkwatch\n/, '\n')
    if (!/^\s*-/m.test(cut)) cut = cut.replace(/\s*$/, '\n[]\n') // 只剩注释时还原成空数组
    if (cut !== txt) fs.writeFileSync(f, cut)
  }
  for (const file of [path.join(HOME, '.claude', 'settings.json'), path.join(HOME, '.codex', 'hooks.json')]) {
    let j
    try { j = JSON.parse(fs.readFileSync(file, 'utf8')) } catch { continue }
    if (!j.hooks) continue
    for (const e of Object.keys(j.hooks)) {
      j.hooks[e] = j.hooks[e].filter((g) => !JSON.stringify(g).includes('inkwatch'))
      if (!j.hooks[e].length) delete j.hooks[e]
    }
    fs.writeFileSync(file, JSON.stringify(j, null, 2))
  }
  autostartOff()
  console.log('已卸载钩子和开机自启。配置留在 ' + home(DIR) + '，不需要可以直接删掉。')
}

// ------------------------------------------------------------------ 入口
const [cmd, ...args] = process.argv.slice(2)
if (cmd === 'serve') serve()
else if (cmd === 'hook') hook(args[0] || 'claude')
else if (cmd === 'install') install(args)
else if (cmd === 'uninstall') uninstall()
else if (cmd === 'status') {
  const c = loadConf()
  ping(c.port).then((up) => {
    console.log(up ? '后台服务：运行中' : '后台服务：没在运行（重新运行 install，或 inkwatch serve 手动启动）')
    printPair(c)
  })
} else if (cmd === 'pair') {
  const c = loadConf()
  if (args[0] === '--new') { c.code = randomCode(); saveConf(c) }
  printPair(c)
} else if (cmd === 'approve') {
  const c = loadConf()
  if (['risky', 'all', 'none'].includes(args[0])) { c.approve = args[0]; saveConf(c) }
  console.log('审批模式：' + c.approve + '（risky = 只拦危险命令；all = 每条 shell 命令都问；none = 只显示不拦）')
} else {
  console.log(`inkwatch：把电脑上的 AI 智能体状态推到 X4，并在 X4 上审批

  inkwatch install [dsh|claude|codex]   装钩子并设为开机后台运行（默认三家都装）
  inkwatch status                       后台服务是否在跑，以及地址和配对码
  inkwatch serve                        前台运行（调试用）
  inkwatch pair [--new]                 显示电脑地址和配对码（--new 换一个码）
  inkwatch approve risky|all|none       哪些命令要在 X4 上确认
  inkwatch uninstall                    卸载钩子和开机自启`)
}
