#!/bin/bash
# Take pt-stalk captures of one lab server.
#   bash capture.sh SERVICE [SECONDS] [MODE] [DEST]
#     MODE load  (default) mixed workload + pt-stalk --no-stalk
#          idle  no workload + pt-stalk --no-stalk (a quiet, healthy server)
#          stalk mixed workload; pt-stalk waits for Threads_running > 4 for 3 s
#                and collects twice, as a triggered capture from the field
#     DEST       capture directory (default captures/SERVICE)
source "$(dirname "$0")/lib.sh"
s=${1:?service}; secs=${2:-20}; mode=${3:-load}; port=${PORT[$s]}
out=${4:-$R/captures/$s}; mkdir -p "$out"
pids=()
# Job control gives every background job its own process group, so the whole
# pipeline (loop + mysql client) can be killed; plain `kill $pid` would leave
# the clients running and the write table growing.
set -m
stop_workload() { local p; for p in "${pids[@]}"; do kill -- "-$p" 2>/dev/null; done; wait 2>/dev/null; }
trap stop_workload EXIT
start_workload() {
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
}
common=(--dest="$out" --log="$out/pt-stalk.log" --pid="$out/pt-stalk.pid"
        --host=127.0.0.1 --port="$port" --user=root --password=labpass)
case $mode in
  idle)  pt-stalk --no-stalk --iterations=1 --run-time="$secs" --sleep=1 "${common[@]}" >/dev/null 2>&1 ;;
  load)  start_workload; sleep 5
         pt-stalk --no-stalk --iterations=1 --run-time="$secs" --sleep=1 "${common[@]}" >/dev/null 2>&1 ;;
  stalk) start_workload
         pt-stalk --function=status --variable=Threads_running --threshold=4 --cycles=3 \
           --iterations=2 --run-time="$secs" --sleep=10 "${common[@]}" >/dev/null 2>&1 ;;
  *) echo "unknown mode: $mode" >&2; exit 2 ;;
esac
# pt-stalk returns while its collectors finish in the background
for i in $(seq 60); do pgrep -f "pt-stalk.*--port=$port" >/dev/null || break; sleep 1; done
stop_workload
ls "$out" | sed -n 's/-mysqladmin$//p' | sed "s|^|$s $mode capture: $out/|"
