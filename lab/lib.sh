#!/bin/bash
# Shared helpers for the lab scripts. Synthetic data only.
R=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
P=pt-stalk-suggestion-lab
DC="docker compose -p $P -f $R/docker-compose.yml"
SERVICES="ps57 ps80 ps84"
declare -A PORT=([ps57]=33057 [ps80]=33080 [ps84]=33084)
my() { local svc=$1; shift; mysql -h127.0.0.1 -P"${PORT[$svc]}" -uroot -plabpass "$@" 2>/dev/null; }
wait_up() {
  local s
  for s in $SERVICES; do
    for i in $(seq 180); do my "$s" -NBe 'select 1' >/dev/null && break; sleep 1; done
    my "$s" -NBe 'select 1' >/dev/null || { echo "$s did not answer in 180 s: $DC logs $s"; return 1; }
  done
}
