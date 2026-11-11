// 扮演 X4：长轮询 /state，打印每次状态，看到审批就回「拒绝」
const [port, code] = process.argv.slice(2)
const base = `http://127.0.0.1:${port}`
let rev = 0
const seen = new Set()
for (;;) {
  let s
  try {
    const r = await fetch(`${base}/state?since=${rev}&wait=20000`, { headers: { 'x-inkwatch-code': code } })
    s = await r.json()
  } catch (e) { console.log('ERR', e.message); await new Promise((r) => setTimeout(r, 1000)); continue }
  if (s.error) { console.log('ERR', s.error); process.exit(1) }
  rev = s.rev
  const ses = s.sessions[0]
  console.log(`rev ${s.rev} | ${ses ? `${ses.name}/${ses.project} ${ses.state} | ${ses.step} | 步骤 ${ses.steps.length}` : '无会话'} | 等审批 ${s.asks.length} | 今天完成 ${s.today.done}`)
  for (const a of s.asks) {
    if (seen.has(a.id)) continue
    seen.add(a.id)
    console.log(`  审批：${a.command}（${a.why}）→ 拒绝`)
    await fetch(`${base}/answer`, { method: 'POST', headers: { 'x-inkwatch-code': code, 'content-type': 'application/json' }, body: JSON.stringify({ id: a.id, answer: 'deny' }) })
  }
  if (ses && ses.state === 'done') { console.log('  完成摘要：', ses.summary.slice(0, 80), '| 标题', ses.title, '| tokens', ses.tokens) }
}
