#!/usr/bin/env bash
# Build dist/pt-stalk-suggest: one self-contained script with every library
# inlined, so it can be copied to any host and run on its own (bash 4+, awk).
#   tools/build.sh [OUTPUT]      (default dist/pt-stalk-suggest)
#   VERSION=0.2.0 COMMIT=abc1234 tools/build.sh    stamp a release build
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
out=$(realpath -m "${1:-$root/dist/pt-stalk-suggest}")
mkdir -p "$(dirname "$out")"

libs=("$root/lib/common.sh" "$root/lib/collect.sh" "$root/lib/report.sh" "$root/lib/defaults.sh")
for f in "$root"/lib/rules/*.sh "$root"/lib/sections/*.sh; do libs+=("$f"); done

{
    # everything before the library block
    sed -n '1,/^# >>> libraries/p' "$root/pt-stalk-suggest" | sed '$d'
    echo "# ---- built $(date -u +%Y-%m-%dT%H:%MZ) by tools/build.sh: libraries inlined below ----"
    for f in "${libs[@]}"; do
        echo
        echo "# ======== ${f#"$root"/} ========"
        grep -v '^# shellcheck shell=bash$' "$f"
    done
    echo "# ---- end of inlined libraries ----"
    # everything after it
    sed -n '/^# <<< libraries/,$p' "$root/pt-stalk-suggest" | sed '1d'
} >"$out.tmp"
if [[ -n ${VERSION:-} ]]; then
    [[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$ ]] || { echo "bad VERSION: $VERSION" >&2; exit 1; }
    sed -i "s/^VERSION=.*/VERSION=$VERSION/" "$out.tmp"
fi
[[ -n ${COMMIT:-} ]] && sed -i "s/^BUILD_COMMIT=.*/BUILD_COMMIT=\"${COMMIT:0:7}\"/" "$out.tmp"
bash -n "$out.tmp"
chmod +x "$out.tmp"
mv "$out.tmp" "$out"
echo "built $out ($(wc -l <"$out") lines, $(du -h "$out" | cut -f1))"
