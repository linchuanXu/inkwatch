#!/bin/sh
# 审批撤回：钩子被智能体杀掉、或已经收到 PostToolUse 时，X4 上的「需要确认」要消失
set -u
A="$(cd "$(dirname "$0")/.." && pwd)"
T=/tmp/inkwatch-stale
mkdir -p "$T"
export INKWATCH_HOME="$T"
printf '{"port":47397,"code":"TEST","secret":"s"}' > "$T/config.json"
node "$A/bin/inkwatch.mjs" serve > "$T/serve.log" 2>&1 &
SP=$!
sleep 1
st() { curl -s -H 'x-inkwatch-code: TEST' http://127.0.0.1:47397/state | node -e "let b='';process.stdin.on('data',c=>b+=c).on('end',()=>{const d=JSON.parse(b);console.log('待审批',d.asks.length,d.asks.map(a=>a.action).join(','))})"; }
st >/dev/null # 让服务认为 X4 在线
EV='{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"/tmp","tool_name":"Bash","tool_use_id":"t1","tool_input":{"command":"git push origin main"}}'
# 1) 钩子进程被杀
echo "$EV" | node "$A/bin/inkwatch.mjs" hook claude & HP=$!
sleep 1; printf '1 钩子挂起时：'; st
kill $HP; sleep 1; printf '1 钩子被杀后：'; st
# 2) 钩子还在等，但智能体已经跑完这一步（PostToolUse 到了）
echo "$EV" | node "$A/bin/inkwatch.mjs" hook claude > "$T/hook2.out" & HP=$!
sleep 1; printf '2 钩子挂起时：'; st
echo '{"hook_event_name":"PostToolUse","session_id":"s1","cwd":"/tmp","tool_name":"Bash","tool_use_id":"t1","tool_input":{"command":"git push origin main"},"tool_response":"ok"}' | node "$A/bin/inkwatch.mjs" hook claude
sleep 1; printf '2 收到 PostToolUse 后：'; st
wait $HP; printf '2 钩子输出（应为空 = 交回智能体）：'; cat "$T/hook2.out"; echo
kill $SP
