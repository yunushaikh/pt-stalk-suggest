#!/bin/bash
# Run a mixed workload against one server and take a pt-stalk capture of it.
#   bash capture.sh ps57 [seconds]
source "$(dirname "$0")/lib.sh"
s=${1:?service}; secs=${2:-20}; port=${PORT[$s]}
out=$R/captures/$s; mkdir -p "$out"
pids=()
# Job control gives every background job its own process group, so the whole
# pipeline (loop + mysql client) can be killed; plain `kill $pid` would leave
# the clients running and the write table growing.
set -m
stop_workload() { local p; for p in "${pids[@]}"; do kill -- "-$p" 2>/dev/null; done; wait 2>/dev/null; }
trap stop_workload EXIT
# table cache churn: one session reading random tables out of 300
( while :; do for i in $(seq 200); do echo "select * from lab.t$((RANDOM % 300 + 1));"; done; done | my "$s" >/dev/null ) & pids+=($!)
# connection churn: short connections (thread_cache_size = 0 on 5.7/8.0)
( while :; do my "$s" -NBe 'select 1' >/dev/null; done ) & pids+=($!)
( while :; do my "$s" -NBe 'select 1' >/dev/null; done ) & pids+=($!)
# writes: multi-row transactions bigger than the 4K binlog cache
for c in 1 2 3 4; do
  ( while :; do echo "begin; insert into lab.w (a,b) select grp, left(txt,200) from lab.big where id between $((RANDOM*5)) and $((RANDOM*5 + 200)); commit;"; done | my "$s" >/dev/null ) & pids+=($!)
done
# sorts on a TEXT column and GROUP BY with temp tables
( while :; do echo "select grp, count(*), max(txt) from lab.big group by grp order by 3 desc limit 5; select * from lab.big where grp < 300 order by pad, txt limit 10;"; done | my "$s" lab >/dev/null ) & pids+=($!)
sleep 5
pt-stalk --no-stalk --iterations=1 --run-time="$secs" --sleep=1 --dest="$out" \
  --log="$R/captures/pt-stalk-$s.log" --pid="$R/captures/pt-stalk-$s.pid" \
  --host=127.0.0.1 --port="$port" --user=root --password=labpass >/dev/null 2>&1
# pt-stalk returns while its collectors finish in the background
for i in $(seq 60); do pgrep -f "pt-stalk.*--port=$port" >/dev/null || break; sleep 1; done
stop_workload
ls "$out" | sed -n 's/-mysqladmin$//p' | tail -1 | sed "s|^|$s capture: $out/|"
