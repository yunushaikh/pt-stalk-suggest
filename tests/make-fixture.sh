#!/usr/bin/env bash
# Build a test fixture from a pt-stalk capture taken in the synthetic lab.
#
#   tests/make-fixture.sh /path/to/captures/ps57/2026_10_15_09_45_41 ps57   one capture
#   tests/make-fixture.sh /path/to/captures/ps57-stalk ps57-stalk          every capture in a dir
#
# Keeps only the files pt-stalk-suggest reads and scrubs host details:
#   - the hostname becomes "lab-host" everywhere
#   - ps keeps the mysqld lines; every other process is summed into one line
#   - sysctl keeps vm.swappiness only; df keeps the "/" filesystem only
#   - variables keeps the SHOW GLOBAL VARIABLES block only
# Never use this on customer data: fixtures are committed to the repository.
set -euo pipefail
src=${1:?capture prefix (path without the -suffix) or a directory of captures}
name=${2:?fixture name}
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
out=$tmp/$name; mkdir -p "$out"

if [[ -d $src ]]; then
    mapfile -t prefixes < <(find "$src" -name '*-mysqladmin' | sed 's/-mysqladmin$//' | sort)
else
    prefixes=("$src")
fi
((${#prefixes[@]})) || { echo "no captures in $src" >&2; exit 1; }

for prefix in "${prefixes[@]}"; do
base=${prefix##*/}
host=$(head -1 "$prefix-hostname")
scrub() { sed "s/$host/lab-host/g"; }

for f in mysqladmin meminfo vmstat mpstat iostat innodbstatus1 innodbstatus2; do
    [[ -r $prefix-$f ]] && scrub <"$prefix-$f" >"$out/$base-$f"
done
echo lab-host >"$out/$base-hostname"
awk '/^Variable_name\t/ { inb = 1 } inb && /^$/ { exit } inb' "$prefix-variables" |
    sed -E "s/^(hostname|report_host)\t.*/\1\tlab-host/" >"$out/$base-variables"
awk '/^TS / || /^Filesystem/ || $NF == "/"' "$prefix-df" >"$out/$base-df"
grep -E '^vm\.swappiness' "$prefix-sysctl" >"$out/$base-sysctl" || true
awk 'NR == 1 { print; for (i = 1; i <= NF; i++) if ($i == "RSS") rc = i; next }
     $0 ~ /(^|\/| )mysqld( |$)/ { print; next }
     { o += $rc }
     END { printf "root 1 0 0 0 %d 0 00:00 ? 00:00:00 other-processes\n", o }' "$prefix-ps" >"$out/$base-ps"
done

if grep -rqiE "$USER|${USER%%.*}" "$out"; then
    grep -rliE "$USER|${USER%%.*}" "$out" >&2
    echo "refusing: the files above still mention the local user" >&2
    exit 1
fi
mkdir -p "$here/fixtures"
tar -C "$tmp" -czf "$here/fixtures/$name.tar.gz" "$name"
echo "wrote tests/fixtures/$name.tar.gz ($(du -h "$here/fixtures/$name.tar.gz" | cut -f1))"
