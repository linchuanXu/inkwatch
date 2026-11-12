#!/bin/sh
# 智能体自己设了「不用问我」（bypassPermissions）时，危险命令也不等 X4；默认模式照样等
set -u
A="$(cd "$(dirname "$0")/.." && pwd)"
T=/tmp/inkwatch-bypass
mkdir -p "$T"
export INKWATCH_HOME="$T"
printf '{"port":47396,"code":"TEST","secret":"s","approve":"risky"}' > "$T/config.json"
node "$A/bin/inkwatch.mjs" serve > "$T/serve.log" 2>&1 & SP=$!
sleep 1
st() { curl -s -H 'x-inkwatch-code: TEST' http://127.0.0.1:47396/state | node -e "let b='';process.stdin.on('data',c=>b+=c).on('end',()=>console.log('待审批',JSON.parse(b).asks.length))"; }
st >/dev/null # X4 在线
printf '1 bypass 模式跑 git push：'
S=$(date +%s)
echo '{"hook_event_name":"PreToolUse","session_id":"b1","cwd":"/tmp","permission_mode":"bypassPermissions","tool_name":"Bash","tool_use_id":"t1","tool_input":{"command":"git push origin main"}}' | node "$A/bin/inkwatch.mjs" hook claude > "$T/o1"
echo "钩子 $(( $(date +%s) - S )) 秒返回，输出「$(cat "$T/o1")」"; printf '  '; st
printf '2 默认模式跑 git push：'
echo '{"hook_event_name":"PreToolUse","session_id":"b2","cwd":"/tmp","permission_mode":"default","tool_name":"Bash","tool_use_id":"t2","tool_input":{"command":"git push origin main"}}' | node "$A/bin/inkwatch.mjs" hook claude > "$T/o2" & HP=$!
sleep 1; st
kill $HP $SP 2>/dev/null
