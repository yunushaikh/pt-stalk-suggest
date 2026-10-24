#!/usr/bin/env bash
# Test suite for pt-stalk-suggest.
#   tests/run-tests.sh            run everything
#   tests/run-tests.sh --update   rewrite tests/expected/* from the current output
set -uo pipefail
export LC_ALL=C
export COLUMNS=100   # fixed report width so golden output does not depend on the terminal
here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")
update=0; [[ ${1:-} == --update ]] && update=1
pass=0 fail=0
ok()  { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; [[ -n ${2:-} ]] && printf '%s\n' "$2" | sed 's/^/        /'; }
eq()  { if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1" "expected: $3"$'\n'"got:      $2"; fi; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

source "$root/lib/common.sh"
source "$root/lib/collect.sh"

echo "helpers"
eq "calc guarded division by zero" "$(calc '0 > 0 ? 0 / 0 : 0' 2>&1)" "0"
eq "calc decimals" "$(calc '10 / 4')" "2.5"
eq "calc big integer" "$(calc_int '15491214828032 + 1')" "15491214828033"
eq "human_bytes G" "$(human_bytes 80530636800)" "75G"
eq "human_bytes M.1" "$(human_bytes 1572864)" "1.5M"
eq "round_up" "$(round_up 8990 500)" "9000"
eq "pow2_up" "$(pow2_up 89029632)" "134217728"
eq "to_bytes" "$(to_bytes 4G)" "4294967296"
eq "human_dur minutes keep a decimal" "$(human_dur 162)" "2.7 min"
eq "human_dur hours" "$(human_dur 18000)" "5.0 h"
eq "human_dur days" "$(human_dur 400000)" "4.6 days"

echo "incident parsers"
source "$root/lib/sections/sessions.sh"
source "$root/lib/sections/locks.sh"
eq "epoch() without mktime (mawk)" "$(awk "$AWK_EPOCH"' BEGIN { print epoch("2026-10-23 14:40:31") - epoch("2026-10-22 23:59:59") }')" "52832"
eq "epoch() across a leap day" "$(awk "$AWK_EPOCH"' BEGIN { print epoch("2028-03-01 00:00:00") - epoch("2028-02-28 00:00:00") }')" "172800"
eq "statement shape" "$(printf '%s\n' "update t set s='x', n=42 where id IN (1,2,3) and k='a''b' and v2=7" | awk "$AWK_FINGERPRINT"' { print fingerprint($0) }')" "update t set s=?, n=? where id IN (?+) and k=? and v2=?"
printf 'TS 1 2026-10-24 09:05:35\n*************************** 1. row ***************************\n           Id: 7\n         User: app\n         Host: 10.0.0.5:51234\n           db: shop\n      Command: Query\n         Time: 19\n        State: Searching rows for update\n         Info: update orders\n                set status=1\n                where ref=5\n' >"$tmp/pl"
eq "processlist row, multi-line SQL joined" "$(parse_processlist "$tmp/pl" | tr '\t' '|')" "1|7|app|10.0.0.5|shop|Query|19|Searching rows for update|update orders set status=1 where ref=5"

echo "mysqladmin parser"
# Three complete samples, one second apart, and a fourth cut short (as when
# pt-stalk stops mysqladmin mid-output): the fourth must be ignored.
{
    for i in 1 2 3; do
        printf '+------+------+\n| Variable_name | Value |\n+------+------+\n'
        printf '| Opened_tables | %d |\n| Threads_running | %d |\n| Uptime | %d |\n| Ssl_cipher | AES |\n+------+------+\n' \
            $((100 + i * i * 10)) $((i == 2 ? 9 : 3)) $((1000 + i))
    done
    printf '+------+------+\n| Variable_name | Value |\n+------+------+\n| Opened_tables | 999 |\n'
} >"$tmp/x-mysqladmin"
MEXT_OUT=$tmp/x.mext metrics_from_mysqladmin "$tmp/x-mysqladmin" >"$tmp/x.tsv"
eq "meta: 3 samples, 2 s, uptime 1003" "$(awk -F'\t' '$1 == "#meta"' "$tmp/x.tsv")" $'#meta\t3\t2\t1003'
# Opened_tables 110, 140, 190: win (190-110)/2 = 40/s, peak 50/s, life 190/1003
eq "counter first/last/win/peak" "$(awk -F'\t' '$1 == "Opened_tables" { print $2, $3, $8 + 0, $9 + 0 }' "$tmp/x.tsv")" "110 190 40 50"
eq "gauge min/max/avg" "$(awk -F'\t' '$1 == "Threads_running" { print $4, $5, $6 + 0 }' "$tmp/x.tsv")" "3 9 5"
eq "non-numeric variable skipped" "$(grep -c '^Ssl_cipher' "$tmp/x.tsv")" "0"
eq "pt-mext style row" "$(grep '^Opened_tables' "$tmp/x.mext" | tr '\t' ' ')" "Opened_tables 110 30 50"

echo "fixtures (golden summaries)"
mkdir -p "$here/expected"
for fx in "$here"/fixtures/*.tar.gz; do
    name=$(basename "$fx" .tar.gz)
    tar -C "$tmp" -xzf "$fx"
    out=$("$root/pt-stalk-suggest" --color never --all "$tmp/$name" 2>&1)
    # The summary table plus the status line of every detail block
    # The I/O, sessions and locks sections, the summary table, the status line
    # of every detail block, findings and caveats
    got=$(printf '%s\n' "$out" | sed -n '/^Disk and I\/O/,/^Details/p;/^  \[[A-Z]*\] /p;/^Other findings/,$p')
    if ((update)); then
        printf '%s\n' "$got" >"$here/expected/$name.txt"; ok "$name (updated)"
    elif diff -u "$here/expected/$name.txt" <(printf '%s\n' "$got") >"$tmp/diff"; then
        ok "$name"
    else
        bad "$name" "$(head -40 "$tmp/diff")"
    fi
done

echo "query cache lock waits (5.7)"
# The ps57-stalk capture has a 97% hit rate: REVIEW. Add processlist samples
# showing sessions waiting on the query cache mutex: it must become CHANGE High.
qc_line() { "$root/pt-stalk-suggest" --color never "$1" 2>&1 | grep -E '^  query_cache_type / _size '; }
eq "high hit rate, no waits: REVIEW" "$(qc_line "$tmp/ps57-stalk" | awk '{print $(NF-1)}')" "REVIEW"
cp -r "$tmp/ps57-stalk" "$tmp/ps57-qcwait"
p=$(ls "$tmp/ps57-qcwait" | sed -n 's/-mysqladmin$//p' | tail -1)
printf 'TS 1 2026-10-17 06:43:30\n*** 1. row ***\n  State: Waiting for query cache lock\nTS 2 2026-10-17 06:43:31\n*** 1. row ***\n  State: Sending data\n' >"$tmp/ps57-qcwait/$p-processlist"
eq "lock waits seen: CHANGE High" "$(qc_line "$tmp/ps57-qcwait" | awk '{print $(NF-1), $NF}')" "CHANGE High"

echo "directories with several servers or captures"
# Captures of two servers in one directory: only the newest capture's server
# is analysed, the other is listed as skipped.
mkdir -p "$tmp/mixed"; cp "$tmp"/ps80-idle/* "$tmp"/ps84-idle/* "$tmp/mixed/"
mixed=$("$root/pt-stalk-suggest" --color never "$tmp/mixed" 2>&1)
eq "mixed servers: one capture used" "$(printf '%s\n' "$mixed" | awk '/Captures used/ {print $3}')" "1:"
eq "mixed servers: version of the newest" "$(printf '%s\n' "$mixed" | awk '/^  Version/ {print $4}')" "8.4.11-11"
eq "mixed servers: caveat names the skipped one" "$(printf '%s\n' "$mixed" | grep -c 'different MySQL server')" "1"
mkdir -p "$tmp/same"; cp "$tmp"/ps84-idle/* "$tmp"/ps84-stalk/* "$tmp/same/"
eq "same server: idle + triggered pair combined" "$("$root/pt-stalk-suggest" --color never "$tmp/same" | awk '/Captures used/ {print $3}')" "3:"
one=$(ls "$tmp/ps84-stalk" | sed -n 's/-mysqladmin$//p' | head -1)
eq "--prefix picks one capture" "$("$root/pt-stalk-suggest" --color never -p "$one" "$tmp/ps84-stalk" | awk '/Captures used/ {print $3, $4}')" "1: $one"
mkdir -p "$tmp/empty"
eq "empty directory: clear error" "$("$root/pt-stalk-suggest" "$tmp/empty" 2>&1 | head -1)" "ERROR: no pt-stalk captures (*-mysqladmin) found under $tmp/empty"

echo "buffer pool outcomes"
# Derived inputs: scale a counter in every sample of a fixture copy.
scale_status() {   # dir variable factor
    local f
    for f in "$1"/*-mysqladmin; do
        awk -F'|' -v var="$2" -v k="$3" 'BEGIN { OFS = "|" } $2 ~ ("^ " var " ") { $3 = sprintf(" %-20d", int(($3 + 0) * k)) } 1' "$f" >"$f.new" && mv "$f.new" "$f"
    done
}
bp_line() { "$root/pt-stalk-suggest" --color never "$@" 2>&1 | awk '/^  innodb_buffer_pool_size / { $1 = ""; sub(/^ /, ""); print }'; }
cp -r "$tmp/ps80-stalk" "$tmp/bp-hot"; scale_status "$tmp/bp-hot" Innodb_buffer_pool_read_requests 0.1
eq "miss > 1% with headroom: increase" "$(bp_line "$tmp/bp-hot")" "64M increase to 128M CHANGE Low"
eq "miss > 1% without headroom: add RAM, then grow" "$(bp_line --os-reserve 65.9G "$tmp/bp-hot")" "64M add ~1G RAM, then 128M CHANGE Low"
eq "no memory left at all: add RAM" "$(bp_line --os-reserve 90G "$tmp/bp-hot")" "64M add RAM CHANGE High"
cp -r "$tmp/ps84-idle" "$tmp/bp-big"; scale_status "$tmp/bp-big" Innodb_buffer_pool_pages_data 0.3; scale_status "$tmp/bp-big" Innodb_buffer_pool_pages_free 600
eq "warm, mostly empty, no misses: can reduce" "$(bp_line "$tmp/bp-big")" "256M can reduce to 128M REVIEW Low"
eq "healthy: keep" "$(bp_line "$tmp/ps84-stalk")" "256M keep OK High"

echo "lock scenario (ps84-locks: scan UPDATEs without an index, an open transaction, ALTER behind it, a deadlock)"
locks=$("$root/pt-stalk-suggest" --color never "$tmp/ps84-locks" 2>&1)
has() { if printf '%s\n' "$locks" | grep -qE "$2"; then ok "$1"; else bad "$1" "no line matching: $2"; fi; }
has "transactions counted once per sample" '^  Transactions +up to 40 open at once; up to 38 waiting'
has "server clock (UTC) converted to host time (IST)" '^ +31s  trx 2606 '
has "big locker found" 'trx 2606 \(thread 18\): 304\.1k rows locked, 0 modified'
has "top blocker from pt-stalk lock-waits" 'thread 18 from .* blocks up to 38 transactions'
has "metadata lock wait: ALTER behind open transaction" 'Metadata \(table-level\) lock waits.*: 2 session'
has "metadata lock: SELECT queued behind the ALTER" 'waits +thread 60 .*select \* from jobs'
has "processlist metadata-lock state" 'Waiting for table metadata lock'
has "deadlock time placed relative to the capture" 'Latest deadlock +2026-10-24 03:35:30 \(5 s before the first capture\) on `lab`.`acct`'
has "waits on PRIMARY explained" 'Waits on index PRIMARY'

echo "documentation sample"
# docs/example-output.txt (shown in the README) must be what the tool prints
# for the ps84-locks fixture, so the sample never drifts from real output.
sample=$("$root/pt-stalk-suggest" --color never "$tmp/ps84-locks" 2>&1 | sed "s|$tmp/ps84-locks|/var/lib/pt-stalk|; s/[[:space:]]*$//")
if ((update)); then
    printf '%s\n' "$sample" >"$root/docs/example-output.txt"; ok "docs/example-output.txt (updated)"
elif diff -u "$root/docs/example-output.txt" <(printf '%s\n' "$sample") >"$tmp/diff"; then
    ok "docs/example-output.txt matches the ps84-locks fixture"
else
    bad "docs/example-output.txt is out of date (run tests/run-tests.sh --update)" "$(head -20 "$tmp/diff")"
fi

echo "single-file build"
mkdir -p "$tmp/standalone"
if "$root/tools/build.sh" "$tmp/standalone/pt-stalk-suggest" >/dev/null; then
    for fx in "$here"/fixtures/*.tar.gz; do
        name=$(basename "$fx" .tar.gz)
        # run from a directory with no lib/ next to it
        if diff <(cd "$tmp/standalone" && ./pt-stalk-suggest --color never --all "$tmp/$name" 2>&1) \
                <("$root/pt-stalk-suggest" --color never --all "$tmp/$name" 2>&1) >"$tmp/diff"; then
            ok "standalone output identical: $name"
        else
            bad "standalone output differs: $name" "$(head -20 "$tmp/diff")"
        fi
    done
else
    bad "tools/build.sh failed"
fi

echo "privacy"
# No case numbers or ticket paths anywhere in the repository; optional local
# denylist (customer names, domains) kept OUTSIDE the repository.
deny=${PT_SUGGEST_DENYLIST:-$HOME/.config/pt-stalk-suggest/denylist}
mapfile -t repo_files < <(cd "$root" && git ls-files --cached --others --exclude-standard 2>/dev/null | grep -v '^tests/fixtures/')
hits=$(cd "$root" && grep -nE 'CS0[0-9]{6}|data/ticket' "${repo_files[@]}" 2>/dev/null | grep -v '^tests/run-tests.sh:')
for fx in "$here"/fixtures/*.tar.gz; do
    hits+=$(tar -xzOf "$fx" | grep -cE 'CS0[0-9]{6}' | grep -v '^0$' | sed "s|^|$fx: |")
done
if [[ -r $deny ]]; then
    while IFS= read -r w; do
        [[ -z $w || $w == \#* ]] && continue
        hits+=$(cd "$root" && grep -nliF "$w" "${repo_files[@]}" 2>/dev/null)
        for fx in "$here"/fixtures/*.tar.gz; do tar -xzOf "$fx" | grep -qiF "$w" && hits+=" $fx"; done
    done <"$deny"
fi
if [[ -z $hits ]]; then
    ok "no case numbers / denylisted names in the repo (denylist: $([[ -r $deny ]] && echo used || echo not present))"
else
    bad "identifiers found" "$hits"
fi

echo
echo "passed $pass, failed $fail"
((fail == 0))
