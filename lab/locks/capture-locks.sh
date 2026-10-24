#!/bin/bash
# Lock pile-up scenario + pt-stalk capture. Synthetic data only.
#   bash capture-locks.sh [SECONDS]
source "$(dirname "$0")/lib.sh"
secs=${1:-25}; out=$R/captures/locks; mkdir -p "$out"
my -e "create database if not exists lab"
my lab -e "create table if not exists events (id bigint auto_increment primary key, event_id varchar(64), parent_event_id varchar(64),
           status varchar(20), end_time datetime, error_code varchar(20), pad varchar(200))"
my lab -e "create table if not exists jobs (id int primary key, name varchar(40)); insert ignore into jobs values (1,'a'),(2,'b')"
my lab -e "create table if not exists acct (id int primary key, v int); insert ignore into acct values (1,0),(2,0)"
if [ "$(my -NBe 'select count(*) from lab.events')" -lt 300000 ]; then
  my lab -e "insert into events (event_id, parent_event_id, status, pad)
             select concat('ev', n), concat('ev', n), 'STARTED', repeat('x', 150)
             from (select (a.ordinal_position*1000000 + b.ordinal_position*1000 + c.ordinal_position) n
                   from information_schema.columns a, information_schema.columns b, information_schema.columns c limit 300000) t"
fi
pids=(); set -m
stop_workload() { local p; for p in "${pids[@]}"; do kill -- "-$p" 2>/dev/null; done; wait 2>/dev/null; }
trap stop_workload EXIT
# one transaction that scans the table and keeps its locks for 40 s
( my lab -e "begin; update events set status='HELD' where event_id='ev-none' and parent_event_id='ev-none'; select sleep(40); commit;" >/dev/null ) & pids+=($!)
sleep 1
# 30 sessions updating by event_id (no index: each scans and locks the table)
for c in $(seq 30); do
  ( while :; do e="ev$RANDOM$RANDOM"; echo "update events set status='COMPLETED', end_time=now(), error_code='E0' where event_id='$e' and parent_event_id='$e';"; done | my lab >/dev/null ) & pids+=($!)
done
# 8 sessions inserting (blocked by the scans' gap locks)
for c in $(seq 8); do
  ( while :; do e="new$RANDOM$RANDOM"; echo "insert into events (event_id, parent_event_id, status, pad) values ('$e','$e','STARTED','y');"; done | my lab >/dev/null ) & pids+=($!)
done
# metadata lock: open transaction on jobs, an ALTER waiting behind it, a SELECT behind the ALTER
( my lab -e "begin; select * from jobs; select sleep(40); commit;" >/dev/null ) & pids+=($!)
sleep 1
( my lab -e "alter table jobs add column c$RANDOM int" >/dev/null ) & pids+=($!)
sleep 1
( my lab -e "select * from jobs" >/dev/null ) & pids+=($!)
# deadlock: two transactions update the same two rows in opposite order
( my lab -e "begin; update acct set v=v+1 where id=1; select sleep(2); update acct set v=v+1 where id=2; commit;" >/dev/null ) & pids+=($!)
( my lab -e "begin; update acct set v=v+1 where id=2; select sleep(2); update acct set v=v+1 where id=1; commit;" >/dev/null ) & pids+=($!)
sleep 4
pt-stalk --no-stalk --iterations=1 --run-time="$secs" --sleep=1 --dest="$out" --log="$out/pt-stalk.log" --pid="$out/pt-stalk.pid" \
  --host=127.0.0.1 --port=33184 --user=root --password=labpass >/dev/null 2>&1
for i in $(seq 90); do pgrep -f 'pt-stalk.*--port=33184' >/dev/null || break; sleep 1; done
stop_workload
ls "$out" | sed -n 's/-mysqladmin$//p' | sed "s|^|capture: $out/|"
