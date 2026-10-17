# shellcheck shell=bash
# Turn a raw pt-stalk directory into the arrays the rules read:
#   STAT["Var|field"]  status counters (see metrics_from_mysqladmin)
#   VARS[name]         SHOW GLOBAL VARIABLES
#   HOST[key]          CPU, memory, swap, disk, mysqld RSS
#   INNODB[key]        values from SHOW ENGINE INNODB STATUS
#   CAPTURES[]         prefixes (path without the "-mysqladmin" suffix) in use

declare -gA STAT=() VARS=() HOST=() INNODB=()
declare -ga CAPTURES=() SKIPPED_CAPTURES=() SKIPPED_OTHER_SERVER=()

# ---------------------------------------------------------------------------
# Capture discovery
# ---------------------------------------------------------------------------
# Epoch of a capture: the first "TS <epoch>" line of a sampled file, else the
# YYYY_MM_DD_HH_MM_SS prefix, else the file mtime.
capture_epoch() {
    local p=$1 f ts base
    for f in "$p-meminfo" "$p-procstat" "$p-df"; do
        [[ -r $f ]] || continue
        ts=$(awk '/^TS /{ split($2, a, "."); print a[1]; exit }' "$f")
        [[ -n $ts ]] && { echo "$ts"; return; }
    done
    base=${p##*/}
    if [[ $base =~ ^([0-9]{4})_([0-9]{2})_([0-9]{2})_([0-9]{2})_([0-9]{2})_([0-9]{2})$ ]]; then
        date -d "${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]} ${BASH_REMATCH[4]}:${BASH_REMATCH[5]}:${BASH_REMATCH[6]}" +%s
        return
    fi
    stat -c %Y "$p-mysqladmin"
}

# Which MySQL server a capture belongs to: server_uuid, else hostname:port
capture_server_id() {
    local f=$1-variables id
    [[ -r $f ]] || { echo unknown; return; }
    id=$(awk -F'\t' '/^Variable_name\t/ { inb = 1; next } inb && /^$/ { exit }
        inb && $1 == "server_uuid" { u = $2 } inb && $1 == "hostname" { h = $2 } inb && $1 == "port" { p = $2 }
        END { print (u != "" ? u : h ":" p) }' "$f")
    echo "${id:-unknown}"
}

discover_captures() {
    local dir=$1 only=${2:-} f p
    local -a found=()
    while IFS= read -r f; do
        p=${f%-mysqladmin}
        [[ -n $only && ${p##*/} != "$only" ]] && continue
        [[ -s $f ]] || { warn "empty file, skipped: $f"; continue; }
        found+=("$p")
    done < <(find "$dir" -type f -name '*-mysqladmin' 2>/dev/null | sort)
    ((${#found[@]})) || die "no pt-stalk captures (*-mysqladmin) found under $dir${only:+ with prefix $only}"
    printf '%s\n' "${found[@]}"
}

# ---------------------------------------------------------------------------
# Status metrics
# The *-mysqladmin file holds repeated "mysqladmin extended-status" tables, one
# per second. pt-mext -r shows the same data as per-sample deltas, but it drops
# the final sample of each file, so the file is parsed here directly.
#
# One TSV row per variable:
#   name first last min max avg life win peak
#     first/last  value at the first/last sample
#     min/max/avg over all samples (meaningful for gauges like Threads_running)
#     life        last / Uptime                    (average rate since start)
#     win         (last - first) / window seconds  (average rate in the capture)
#     peak        highest per-interval rate         (delta / Uptime delta)
# A "#meta" row carries: samples window_secs uptime_last
# With MEXT_OUT set, a pt-mext -r style table (first value, then deltas) is
# written there too.
# ---------------------------------------------------------------------------
metrics_from_mysqladmin() {
    local file=$1
    awk -v mext="${MEXT_OUT:-}" '
        function trim(x) { gsub(/^ +| +$/, "", x); return x }
        /Variable_name/ { k++; rows[k] = 0; next }
        /^\|/ && k {
            split($0, a, "|"); nm = trim(a[2]); vl = trim(a[3])
            if (!(nm in seen)) { seen[nm] = 1; order[++n] = nm }
            if (vl !~ /^-?[0-9]+(\.[0-9]+)?$/) bad[nm] = 1
            V[nm, k] = vl; rows[k]++
        }
        END {
            # a sample cut short when pt-stalk stopped mysqladmin is dropped
            if (k > 1 && rows[k] < rows[1]) k--
            if (k < 1 || !(("Uptime", 1) in V)) { print "no Uptime in mysqladmin output" > "/dev/stderr"; exit 1 }
            for (j = 1; j <= k; j++) upt[j] = V["Uptime", j]
            secs = upt[k] - upt[1]
            printf "#meta\t%d\t%d\t%d\n", k, secs, upt[k]
            for (r = 1; r <= n; r++) {
                nm = order[r]
                if (nm in bad) continue
                first = V[nm, 1] + 0; c = first; mn = c; mx = c; sum = c; pk = ""; line = nm "\t" first
                for (j = 2; j <= k; j++) {
                    if (!((nm, j) in V)) { line = line "\t0"; continue }
                    p = c; c = V[nm, j] + 0; d = c - p; sum += c
                    line = line "\t" d
                    if (c < mn) mn = c
                    if (c > mx) mx = c
                    dt = upt[j] - upt[j - 1]
                    if (dt > 0) { rt = d / dt; if (pk == "" || rt > pk) pk = rt }
                }
                if (mext != "") print line > mext
                life = (upt[k] > 0) ? c / upt[k] : 0
                win  = (secs > 0) ? (c - first) / secs : 0
                printf "%s\t%.0f\t%.0f\t%.0f\t%.0f\t%.4f\t%.6f\t%.6f\t%.6f\n", \
                    nm, first, c, mn, mx, sum / k, life, win, (pk == "" ? 0 : pk)
            }
        }' "$file"
}

# Combine per-capture TSVs (given in time order) into one TSV.
aggregate_metrics() {
    awk -F'\t' '
        FNR == 1 { cap++ }
        $1 == "#meta" {
            samples += $2; secs += $3; start = $4 - $3
            # pt-stalk starts the next collection after --sleep, which can be
            # shorter than --run-time: windows may overlap
            if (cap > 1 && start < uplast) overlap += uplast - start
            uplast = $4; next
        }
        {
            v = $1
            if (!(v in first)) { first[v] = $2; order[++n] = v; mn[v] = $4; mx[v] = $5 }
            last[v] = $3
            if ($4 < mn[v]) mn[v] = $4
            if ($5 > mx[v]) mx[v] = $5
            avgsum[v] += $6; avgcnt[v]++
            life[v] = $7
            wdelta[v] += $3 - $2
            if (!(v in peak) || $9 > peak[v]) peak[v] = $9
        }
        END {
            printf "#meta\t%d\t%d\t%d\t%d\t%d\n", samples, secs, uplast, cap, overlap
            for (i = 1; i <= n; i++) {
                v = order[i]
                printf "%s\t%s\t%s\t%s\t%s\t%.4f\t%s\t%.6f\t%s\n", v, first[v], last[v], mn[v], mx[v], \
                    avgsum[v] / avgcnt[v], life[v], (secs > 0 ? wdelta[v] / secs : 0), peak[v]
            }
        }' "$@"
}

load_metrics() {
    local tsv=$1 name first last mn mx avg life win peak
    while IFS=$'\t' read -r name first last mn mx avg life win peak; do
        if [[ $name == "#meta" ]]; then
            HOST[samples]=$first HOST[window_secs]=$last HOST[uptime]=$mn HOST[captures_used]=$mx HOST[overlap_secs]=${avg:-0}
            continue
        fi
        STAT["$name|first"]=$first STAT["$name|last"]=$last
        STAT["$name|min"]=$mn STAT["$name|max"]=$mx STAT["$name|avg"]=$avg
        STAT["$name|life"]=$life STAT["$name|win"]=$win STAT["$name|peak"]=$peak
    done <"$tsv"
}

# ---------------------------------------------------------------------------
# Server variables: first "Variable_name<TAB>Value" block (tab or |-table form)
# ---------------------------------------------------------------------------
load_variables() {
    local f=$1 name val
    [[ -r $f ]] || { warn "no variables file: $f"; return; }
    while IFS=$'\t' read -r name val; do
        VARS[$name]=$val
    done < <(awk '
        /^Variable_name\t/ || /^\| *Variable_name *\|/ { inb = 1; next }
        inb && (/^$/ || /^[a-z]+ .* from /) { exit }
        inb && /^\+--/ { next }
        inb && /^\|/ { split($0, a, "|"); gsub(/^ +| +$/, "", a[2]); gsub(/^ +| +$/, "", a[3]); print a[2] "\t" a[3]; next }
        inb { print }' "$f")
    ((${#VARS[@]})) || warn "could not parse server variables from $f"
}

# ---------------------------------------------------------------------------
# Host resources
# ---------------------------------------------------------------------------
# Existing files with SUFFIX across all captures used (time order)
sampled_files() {
    local p
    for p in "${CAPTURES[@]}"; do [[ -r $p-$1 ]] && printf '%s\n' "$p-$1"; done
}

# Static facts (hostname, ps, sysctl, df) come from the newest capture;
# sampled files (meminfo, vmstat, mpstat, iostat) are read from every capture.
load_host() {
    local p=${CAPTURES[${#CAPTURES[@]} - 1]} x
    local -a mem vms mps ios
    mapfile -t mem < <(sampled_files meminfo)
    mapfile -t vms < <(sampled_files vmstat)
    mapfile -t mps < <(sampled_files mpstat)
    mapfile -t ios < <(sampled_files iostat)

    [[ -r $p-hostname ]] && HOST[hostname]=$(head -1 "$p-hostname")

    # CPU count: "(16 CPU)" in the iostat/mpstat header, else cpuN lines in procstat
    x=$(grep -hoE '\([0-9]+ CPU\)' "$p-iostat" "$p-mpstat" 2>/dev/null | head -1 | tr -dc 0-9)
    [[ -z $x && -r $p-procstat ]] && x=$(awk '/^TS/{ if (seen) exit; seen = 1; next } /^cpu[0-9]+ /{ n++ } END { print n + 0 }' "$p-procstat")
    HOST[cpus]=$(num "$x")

    # meminfo (values in kB): totals from the first sample, worst case over samples
    if ((${#mem[@]})); then
        while IFS='=' read -r k x; do HOST[$k]=$x; done < <(awk '
            /^MemTotal:/      { if (!mt) mt = $2 }
            /^MemAvailable:/  { if (ma == "" || $2 < ma) ma = $2 }
            /^SwapTotal:/     { if (!st) st = $2 }
            /^SwapFree:/      { if (sf == "" || $2 < sf) sf = $2 }
            /^HugePages_Total:/ { hp = $2 }
            /^Hugepagesize:/  { hs = $2 }
            END {
                printf "mem_total=%.0f\nmem_avail_min=%.0f\nswap_total=%.0f\nswap_used_max=%.0f\nhugepages_bytes=%.0f\n",
                    mt * 1024, ma * 1024, st * 1024, (st - sf) * 1024, hp * hs * 1024
            }' "${mem[@]}")
    fi

    # vmstat swap activity (si/so are KiB/s); the first data row is the since-boot average
    if ((${#vms[@]})); then
        while IFS='=' read -r k x; do HOST[$k]=$x; done < <(awk '
            FNR == 1 { rows = 0 }
            /^ *r +b / { for (i = 1; i <= NF; i++) col[$i] = i; next }
            !col["si"] || $1 !~ /^[0-9]+$/ { next }
            { rows++; if (rows == 1) next; n++; si += $col["si"]; so += $col["so"]; if ($col["si"] > msi) msi = $col["si"]; if ($col["so"] > mso) mso = $col["so"] }
            END { printf "swap_in_avg=%.1f\nswap_out_avg=%.1f\nswap_in_max=%.0f\nswap_out_max=%.0f\n", (n ? si / n : 0), (n ? so / n : 0), msi, mso }' "${vms[@]}")
    fi

    # ps: mysqld RSS and the RSS of everything else (kB -> bytes)
    if [[ -r $p-ps ]]; then
        while IFS='=' read -r k x; do HOST[$k]=$x; done < <(awk '
            /^TS / { if (seen) exit; next }
            $0 ~ /RSS/ && !rc { for (i = 1; i <= NF; i++) { if ($i == "RSS") rc = i; if ($i == "CMD" || $i == "COMMAND") cc = i }; seen = 1; next }
            !rc { next }
            {
                cmd = ""; for (i = cc; i <= NF; i++) cmd = cmd " " $i
                if (cmd ~ /(^|\/| )mysqld( |$)/) { if ($rc > m) m = $rc; mc++ }
                else o += $rc
            }
            END { printf "mysqld_rss=%.0f\nmysqld_count=%d\nother_rss=%.0f\n", m * 1024, mc, o * 1024 }' "$p-ps")
    fi

    # mpstat "all" rows: CPU busy % and iowait %. Columns are located from the
    # header counting from the right, because the time column may carry AM/PM.
    if ((${#mps[@]})); then
        while IFS='=' read -r k x; do HOST[$k]=$x; done < <(awk '
            /%idle/ { for (i = 1; i <= NF; i++) { if ($i == "CPU") c = NF - i; if ($i == "%iowait") w = NF - i }; next }
            /^Average/ || c == "" || NF < c + 1 { next }
            $(NF - c) == "all" { n++; b = 100 - $NF; sb += b; if (b > mb) mb = b; sw += $(NF - w) }
            END { if (n) printf "cpu_busy_avg=%.1f\ncpu_busy_max=%.1f\ncpu_iowait_avg=%.1f\n", sb / n, mb, sw / n }' "${mps[@]}")
    fi

    # Startup reductions logged by mysqld (ER_CHANGED_TABLE_OPEN_CACHE etc.):
    #   "Changed limits: table_open_cache: 4495 (requested 5000)"
    local -a errs; mapfile -t errs < <(sampled_files log_error)
    if ((${#errs[@]})); then
        while IFS='=' read -r k x; do HOST[$k]=$x; done < <(sed -nE \
            's/.*Changed limits: (table_open_cache|max_connections|max_open_files): ([0-9]+) \(requested ([0-9]+)\).*/changed_\1=\2 \3/p' "${errs[@]}" | tail -3)
    fi

    # Sessions waiting on the 5.7 query cache mutex, from the processlist samples
    local -a pls; mapfile -t pls < <(sampled_files processlist)
    if ((${#pls[@]})); then
        while IFS='=' read -r k x; do HOST[$k]=$x; done < <(awk '
            /^TS / { n++ } /State: Waiting for query cache lock/ { w++ }
            END { printf "processlist_samples=%d\nqc_lock_waits=%d\n", n, w }' "${pls[@]}")
    fi

    # vm.swappiness
    [[ -r $p-sysctl ]] && HOST[swappiness]=$(awk -F' = ' '$1 == "vm.swappiness" { print $2; exit }' "$p-sysctl")

    load_disk "$p" "${ios[@]}"
}

# Pick the device holding datadir (via df) and summarise its iostat samples.
load_disk() {
    local p=$1 datadir dev mount; shift
    local -a ios=("$@")
    datadir=${VARS[datadir]:-/var/lib/mysql/}
    if [[ -r $p-df ]]; then
        read -r dev mount < <(awk -v d="$datadir" '
            /^TS / { if (seen) exit; seen = 1; next }
            /^Filesystem/ { next }
            { m = $NF; if (index(d, m) == 1 && length(m) > length(best)) { best = m; bdev = $1 } }
            END { print bdev, best }' "$p-df")
        HOST[data_mount]=$mount HOST[data_fs_dev]=$dev
    fi
    ((${#ios[@]})) || return 0

    # iostat -dx shows whole devices: map nvme1n1p1 -> nvme1n1, sda3 -> sda
    local want=${dev##*/}
    [[ $want =~ ^(nvme[0-9]+n[0-9]+)p[0-9]+$ ]] && want=${BASH_REMATCH[1]}
    [[ $want =~ ^((s|v|xv|h)d[a-z]+)[0-9]+$ ]] && want=${BASH_REMATCH[1]}

    local k x
    while IFS='=' read -r k x; do HOST[$k]=$x; done < <(awk -v want="$want" '
        FNR == 1 { blk = 0 }
        /^Device/ {
            blk++; delete col
            for (i = 1; i <= NF; i++) col[$i] = i
            # sysstat < 12 has a single "await" column
            wa = ("w_await" in col) ? col["w_await"] : col["await"]
            next
        }
        blk < 2 || NF < 5 || /^Linux/ { next }       # block 1 is the since-boot average
        {
            d = $1; seen[d] = 1; n[d]++
            r = $col["r/s"]; w = $col["w/s"]; u = $col["%util"]; a = $wa
            sr[d] += r; sw[d] += w; su[d] += u; sa[d] += a
            if (r > mr[d]) mr[d] = r
            if (w > mw[d]) mw[d] = w
            if (u > mu[d]) mu[d] = u
            if (a > ma[d]) ma[d] = a
        }
        END {
            pick = (want in seen) ? want : ""
            how = pick ? "datadir" : "busiest"
            if (!pick) for (d in seen) if (pick == "" || sw[d] > sw[pick]) pick = d
            if (!pick) exit
            c = n[pick]
            printf "disk=%s\ndisk_how=%s\ndisk_samples=%d\n", pick, how, c
            printf "disk_r_avg=%.1f\ndisk_r_max=%.1f\ndisk_w_avg=%.1f\ndisk_w_max=%.1f\n", sr[pick] / c, mr[pick], sw[pick] / c, mw[pick]
            printf "disk_util_avg=%.1f\ndisk_util_max=%.1f\ndisk_wawait_avg=%.2f\ndisk_wawait_max=%.2f\n", su[pick] / c, mu[pick], sa[pick] / c, ma[pick]
        }' "${ios[@]}")
}

# ---------------------------------------------------------------------------
# InnoDB status: worst values across every innodbstatus file used
# ---------------------------------------------------------------------------
load_innodb() {
    local k x
    local -a files=()
    for x in "$@"; do files+=("$x"-innodbstatus*); done
    [[ -e ${files[0]} ]] || return 0
    while IFS='=' read -r k x; do INNODB[$k]=$x; done < <(awk '
        function keep(k, v) { if (!(k in M) || v > M[k]) M[k] = v }
        FNR == 1 { lsn = ""; ckpt = "" }
        /^Log sequence number/   { lsn = $NF }
        /^Last checkpoint at/    { ckpt = $NF; if (lsn != "") keep("checkpoint_age", lsn - ckpt) }
        /^Checkpoint age  /      { keep("checkpoint_age", $NF) }
        /^Max checkpoint age/    { keep("max_checkpoint_age", $NF) }
        /^Modified age/          { keep("modified_age", $NF) }
        /^History list length/   { keep("history_list", $NF) }
        /queries inside InnoDB/  { keep("queries_inside", $1); keep("queries_queued", $(NF - 3)) }
        /has waited at/          { w[FILENAME]++ }
        END {
            for (f in w) keep("semaphore_waits", w[f])
            for (k in M) printf "%s=%.0f\n", k, M[k]
        }' "${files[@]}")
}

# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------
collect_all() {
    local dir=$1 only=${2:-} work=$3 p e up start
    local -a all=() rows=()

    mapfile -t all < <(discover_captures "$dir" "$only")

    # Per-capture metrics, then keep only captures from the latest server start
    # (counters reset on restart, so mixing them would corrupt the rates).
    local i=0
    for p in "${all[@]}"; do
        i=$((i + 1))
        note "parsing ${p##*/}-mysqladmin"
        MEXT_OUT=""; [[ -n ${KEEP_WORK:-} ]] && MEXT_OUT="$work/${p##*/}.mext"
        if ! metrics_from_mysqladmin "$p-mysqladmin" >"$work/cap$i.tsv" || [[ ! -s $work/cap$i.tsv ]]; then
            warn "could not parse ${p##*/}-mysqladmin, skipped"
            continue
        fi
        e=$(capture_epoch "$p")
        up=$(awk -F'\t' '$1 == "#meta" { print $4; exit }' "$work/cap$i.tsv")
        start=$((e - up))
        rows+=("$e"$'\t'"$start"$'\t'"$p"$'\t'"$work/cap$i.tsv"$'\t'"$(capture_server_id "$p")")
    done
    ((${#rows[@]})) || die "no capture could be parsed"

    # A directory can hold captures of several servers (pt-stalk output from
    # more than one host). Analyse the server of the newest capture only.
    local server latest_start
    server=$(printf '%s\n' "${rows[@]}" | sort -n -k1,1 | tail -1 | cut -f5)
    latest_start=$(printf '%s\n' "${rows[@]}" | awk -F'\t' -v s="$server" '$5 == s' | sort -n -k2,2 | tail -1 | cut -f2)
    SERVER_ID=$server
    local -a tsvs=()
    local ep st pref tsv sid
    while IFS=$'\t' read -r ep st pref tsv sid; do
        if [[ $sid != "$server" ]]; then
            SKIPPED_OTHER_SERVER+=("${pref##*/} ($sid)")
        elif ((st < latest_start - 120)); then
            SKIPPED_CAPTURES+=("${pref##*/}")
        else
            CAPTURES+=("$pref"); tsvs+=("$tsv")
            HOST[last_epoch]=$ep
        fi
    done < <(printf '%s\n' "${rows[@]}" | sort -n -k1,1)

    aggregate_metrics "${tsvs[@]}" >"$work/metrics.tsv"
    load_metrics "$work/metrics.tsv"

    local newest=${CAPTURES[${#CAPTURES[@]} - 1]}
    load_variables "$newest-variables"
    load_host
    load_innodb "${CAPTURES[@]}"

    # Version: "8.4.6-6-pro" -> 80406
    local ver=${VARS[version]:-0.0.0} a b c
    IFS=. read -r a b c <<<"${ver%%-*}"
    MYSQL_VER_NUM=$(( $(num "$a") * 10000 + $(num "$b") * 100 + $(num "${c%%[^0-9]*}") ))
    MYSQL_SERIES="$(num "$a").$(num "$b")"
    case "${VARS[version_comment]:-}" in
        *XtraDB*Cluster*) MYSQL_FLAVOR="Percona XtraDB Cluster" ;;
        *Percona*)        MYSQL_FLAVOR="Percona Server" ;;
        *MariaDB*)        MYSQL_FLAVOR="MariaDB" ;;
        *)                MYSQL_FLAVOR="MySQL" ;;
    esac
}
