#!/bin/bash
# Shared helpers for the lock-scenario lab. Synthetic data only.
R=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
P=pt-stalk-locks-lab
DC="docker compose -p $P -f $R/docker-compose.yml"
SERVICES="ps84"
my() { mysql -h127.0.0.1 -P33184 -uroot -plabpass "$@" 2>/dev/null; }
wait_up() { for i in $(seq 180); do my -NBe 'select 1' >/dev/null && return 0; sleep 1; done; echo "ps84 did not answer in 180 s: $DC logs ps84"; return 1; }
