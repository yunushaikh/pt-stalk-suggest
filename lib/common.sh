# shellcheck shell=bash
# Common helpers: logging, awk-based math, unit formatting, data accessors.

GiB=1073741824
MiB=1048576

die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
note() { [[ ${VERBOSE:-0} -eq 1 ]] && printf '  .. %s\n' "$*" >&2; return 0; }

# ---------------------------------------------------------------------------
# Math. Bash has integers only, so everything goes through awk.
#   calc 'expr'      -> prints the value (up to 6 decimals, trailing zeros cut)
#   calc_int 'expr'  -> prints the value rounded to an integer
#   is 'expr'        -> exit status 0 when expr is true
# Empty operands must be guarded by the caller (see num()).
# ---------------------------------------------------------------------------
# gawk folds constant expressions while parsing, so "0 > 0 ? 0 / 0 : 0" dies
# with "division by zero" even though the guard is false. Adding a runtime
# zero (z) to every number keeps the ternary guards working.
_rt() { sed -E 's/([0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?)/(\1+z)/g' <<<"$1"; }
calc() {
    awk -v z=0 "BEGIN { v = ($(_rt "$1")); s = sprintf(\"%.6f\", v); sub(/0+\$/, \"\", s); sub(/\\.\$/, \"\", s); print s }"
}
calc_int() { awk -v z=0 "BEGIN { printf \"%.0f\n\", ($(_rt "$1")) }"; }
is()       { awk -v z=0 "BEGIN { exit !($(_rt "$1")) }"; }

# num VALUE [DEFAULT] -> VALUE when numeric, otherwise DEFAULT (0)
num() {
    local v=${1:-} d=${2:-0}
    [[ $v =~ ^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$ ]] && printf '%s' "$v" || printf '%s' "$d"
}

# round_up VALUE STEP -> VALUE rounded up to a multiple of STEP
round_up()   { awk -v v="$1" -v s="$2" 'BEGIN { r = int(v / s); if (r * s < v) r++; printf "%.0f\n", r * s }'; }
round_down() { awk -v v="$1" -v s="$2" 'BEGIN { printf "%.0f\n", int(v / s) * s }'; }

# next power of two >= VALUE
pow2_up() { awk -v v="$1" 'BEGIN { p = 1; while (p < v) p *= 2; printf "%.0f\n", p }'; }

max2() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%s\n", (a + 0 > b + 0) ? a : b }'; }
min2() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%s\n", (a + 0 < b + 0) ? a : b }'; }

# ---------------------------------------------------------------------------
# Formatting
# ---------------------------------------------------------------------------
# human_bytes 80530636800 -> 75.0G
human_bytes() {
    awk -v b="$(num "$1")" 'BEGIN {
        split("B K M G T P", u, " "); i = 1; neg = (b < 0); if (neg) b = -b
        while (b >= 1024 && i < 6) { b /= 1024; i++ }
        s = (i == 1) ? sprintf("%d%s", b, u[i]) : sprintf("%.1f%s", b, u[i])
        if (s ~ /\.0[KMGTP]$/) s = substr(s, 1, length(s) - 3) substr(s, length(s))
        print (neg ? "-" : "") s
    }'
}

# human_num 12345.678 -> 12.3k ; small values keep 2 decimals
human_num() {
    awk -v n="$(num "$1")" 'BEGIN {
        a = (n < 0) ? -n : n
        if (a >= 1e9)      s = sprintf("%.1fG", n / 1e9)
        else if (a >= 1e6) s = sprintf("%.1fM", n / 1e6)
        else if (a >= 1e4) s = sprintf("%.1fk", n / 1e3)
        else if (a >= 100 || a == int(a)) s = sprintf("%.0f", n)
        else               s = sprintf("%.2f", n)
        print s
    }'
}

# pct PART WHOLE -> "12.3%" (or "n/a")
pct() {
    awk -v p="$(num "$1")" -v w="$(num "$2")" 'BEGIN {
        if (w == 0) { print "n/a"; exit }
        v = 100 * p / w
        print (v < 0.1 && v > 0) ? sprintf("%.3f%%", v) : sprintf("%.1f%%", v)
    }'
}

# human_secs 1175225 -> 13d 14h
human_secs() {
    awk -v s="$(num "$1")" 'BEGIN {
        d = int(s / 86400); h = int((s % 86400) / 3600); m = int((s % 3600) / 60)
        if (d > 0) printf "%dd %dh\n", d, h
        else if (h > 0) printf "%dh %dm\n", h, m
        else printf "%dm %ds\n", m, s % 60
    }'
}

# human_dur 102.5 -> "1.7 min" ; 1.7 -> "1.7 s" ; 9000 -> "2.5 h"
human_dur() {
    awk -v s="$(num "$1")" 'BEGIN {
        if (s < 120)       printf "%.1f s\n", s
        else if (s < 7200) printf "%.0f min\n", s / 60
        else               printf "%.1f h\n", s / 3600
    }'
}

# to_bytes "64M" -> 67108864 (accepts plain numbers too)
to_bytes() {
    awk -v v="$1" 'BEGIN {
        u = toupper(substr(v, length(v))); n = v + 0
        if (u == "K") n *= 1024; else if (u == "M") n *= 1048576
        else if (u == "G") n *= 1073741824; else if (u == "T") n *= 1099511627776
        printf "%.0f\n", n
    }'
}

# ---------------------------------------------------------------------------
# Data accessors (arrays are filled by lib/collect.sh)
#   v NAME            -> server variable (SHOW GLOBAL VARIABLES)
#   s NAME [FIELD]    -> status metric; FIELD = first|last|min|max|avg|life|win|peak
#   h KEY             -> host resource value
#   ib KEY            -> value parsed from SHOW ENGINE INNODB STATUS
# ---------------------------------------------------------------------------
v()  { printf '%s' "${VARS[$1]:-}"; }
h()  { printf '%s' "${HOST[$1]:-}"; }
ib() { printf '%s' "${INNODB[$1]:-}"; }
s() {
    local f=${2:-last}
    printf '%s' "${STAT["$1|$f"]:-}"
}
sn()  { num "$(s "$1" "${2:-last}")"; }                        # status as a number (0 if missing)
sd()  { calc "$(sn "$1" last) - $(sn "$1" first)"; }           # change during the capture window
has_var()  { [[ -n ${VARS[$1]+x} ]]; }
has_stat() { [[ -n ${STAT["$1|last"]+x} ]]; }

# Variable value as a number, with ON/OFF mapped to 1/0
vnum() {
    local x=${VARS[$1]:-}
    case ${x^^} in ON|TRUE|YES) echo 1 ;; OFF|FALSE|NO|'') echo 0 ;; *) num "$x" ;; esac
}

# ---------------------------------------------------------------------------
# Version helpers. MYSQL_VER_NUM is MAJOR*10000 + MINOR*100 + PATCH.
# ---------------------------------------------------------------------------
ver_ge() {   # ver_ge 8.0.30
    local IFS=. a b c; read -r a b c <<<"$1"
    (( MYSQL_VER_NUM >= a * 10000 + b * 100 + ${c:-0} ))
}
ver_lt() { ! ver_ge "$1"; }
