#!/bin/bash
# One-time data for the workload: 300 small tables (more than table_open_cache = 64),
# a 200k-row table with a TEXT column (sorts, temp tables), and a write table.
source "$(dirname "$0")/lib.sh"
for s in ${1:-$SERVICES}; do
  {
    echo "create database if not exists lab; use lab;"
    for i in $(seq 1 300); do echo "create table if not exists t$i (id int primary key, v int); insert ignore into t$i values (1,1),(2,2);"; done
    echo "create table if not exists big (id int auto_increment primary key, grp int, txt text, pad varchar(200));"
    echo "create table if not exists w (id bigint auto_increment primary key, a int, b varchar(255));"
  } | my "$s"
  rows=$(my "$s" -NBe 'select count(*) from lab.big')
  if [ "${rows:-0}" -lt 200000 ]; then
    my "$s" lab -e "insert into big (grp, txt, pad) select floor(rand()*5000), repeat(md5(rand()), 4), repeat('x', 200)
      from information_schema.columns a, information_schema.columns b limit 200000"
  fi
  echo "$s: big=$(my "$s" -NBe 'select count(*) from lab.big') tables=$(my "$s" -NBe "select count(*) from information_schema.tables where table_schema='lab'")"
done
