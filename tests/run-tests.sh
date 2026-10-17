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
    got=$(printf '%s\n' "$out" | sed -n '/^Summary/,/^Details/p;/^  \[[A-Z]*\] /p;/^Other findings/,$p')
    if ((update)); then
        printf '%s\n' "$got" >"$here/expected/$name.txt"; ok "$name (updated)"
    elif diff -u "$here/expected/$name.txt" <(printf '%s\n' "$got") >"$tmp/diff"; then
        ok "$name"
    else
        bad "$name" "$(head -40 "$tmp/diff")"
    fi
done

echo "documentation sample"
# docs/example-output.txt (shown in the README) must be what the tool prints
# for the ps84-stalk fixture, so the sample never drifts from real output.
sample=$("$root/pt-stalk-suggest" --color never "$tmp/ps84-stalk" 2>&1 | sed "s|$tmp/ps84-stalk|/var/lib/pt-stalk|; s/[[:space:]]*$//")
if ((update)); then
    printf '%s\n' "$sample" >"$root/docs/example-output.txt"; ok "docs/example-output.txt (updated)"
elif diff -u "$root/docs/example-output.txt" <(printf '%s\n' "$sample") >"$tmp/diff"; then
    ok "docs/example-output.txt matches the ps84-stalk fixture"
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
