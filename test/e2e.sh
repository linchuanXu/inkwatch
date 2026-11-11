#!/bin/sh
# 端到端（Mac / Linux）：在假的 HOME 里真跑 install，DSH 用 install 生成的补丁，
# 另一个进程扮演 X4：长轮询 /state，看到审批就点「拒绝」。不碰你自己的 ~/.dsh、~/.claude。
#   sh test/e2e.sh
set -u
A="$(cd "$(dirname "$0")/.." && pwd)"
T=/tmp/inkwatch-e2e
FH="$T/home"
mkdir -p "$FH/.dsh/profiles" "$T/work"
printf '{"port":47399,"code":"TEST"}' > "$T/conf.json"
mkdir -p "$FH/.inkwatch" && cp "$T/conf.json" "$FH/.inkwatch/config.json"
HOME="$FH" INKWATCH_NO_AUTOSTART=1 node "$A/bin/inkwatch.mjs" install dsh > "$T/install.txt" 2>&1
node "$FH/.inkwatch/inkwatch.mjs" serve > "$T/serve.log" 2>&1 &
SP=$!
sleep 1
node "$A/test/fake_x4.mjs" 47399 TEST > "$T/x4.log" 2>&1 &
XP=$!
# DSH 用你自己的 HOME（要登录态），只通过 --patch 挂上假 HOME 里生成的钩子
cd "$T/work" && perl -e 'alarm 240; exec @ARGV' dsh headless --patch "$FH/.inkwatch/dsh-patch.yml" "先用 shell 运行 echo hello，再用 shell 运行 git push origin main --force（测试，会被拒），最后一句话总结" > "$T/dsh.txt" 2>&1
sleep 5
kill $XP $SP 2>/dev/null
echo "== install"; cat "$T/install.txt" | head -4
echo "== X4 看到的"; cat "$T/x4.log"
echo "== DSH 最后几行"; tail -3 "$T/dsh.txt"
