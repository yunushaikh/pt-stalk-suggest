# shellcheck shell=bash
# "Disk and I/O" section: per-device iostat, CPU iowait and blocked processes,
# InnoDB I/O rates, and where each number comes from.

# Files of the captures in use with SUFFIX, as a short list for "Files:" lines
files_of() {
    local suffix p types="" caps=""
    for suffix in "$@"; do
        for p in "${CAPTURES[@]}"; do [[ -r $p-$suffix ]] && { types+="${types:+, }$suffix"; break; }; done
    done
    for p in "${CAPTURES[@]}"; do caps+="${caps:+, }${p##*/}"; done
    [[ -n $types ]] && printf '<capture>-{%s} for capture %s' "$types" "$caps" || printf 'none'
}

# Extra files some collection scripts put next to the pt-stalk output
extra_file() {
    local dir f
    dir=$(dirname "${CAPTURES[0]}")
    for f in "$@"; do [[ -r $dir/$f ]] && { printf '%s' "$dir/$f"; return 0; }; done
    return 1
}

# Datadir -> block device. df gives the filesystem (e.g. /dev/mapper/vg-lv);
# iostat shows dm-N for LVM volumes, which only lsblk (MAJ:MIN 253:N) can map.
map_datadir_device() {
    DATA_DEV=${HOST[data_fs_dev]:-}; DATA_IOSTAT_DEV="" DATA_DISKS="" DATA_MAP_HOW=""
    local lsblk dev=${DATA_DEV##*/}
    if [[ $dev =~ ^(nvme[0-9]+n[0-9]+)p[0-9]+$ ]]; then DATA_IOSTAT_DEV=${BASH_REMATCH[1]}; DATA_MAP_HOW="partition of"
    elif [[ $dev =~ ^((s|v|xv|h)d[a-z]+)[0-9]+$ ]]; then DATA_IOSTAT_DEV=${BASH_REMATCH[1]}; DATA_MAP_HOW="partition of"
    elif [[ $dev =~ ^(sd|vd|xvd|hd|nvme)[a-z0-9]*$ ]]; then DATA_IOSTAT_DEV=$dev; DATA_MAP_HOW="device"
    fi
    if [[ -z $DATA_IOSTAT_DEV ]] && lsblk=$(extra_file lsblk-all lsblk); then
        # lsblk tree: a disk line, then children "├─name  253:3 ... lvm  /mysql/data"
        read -r DATA_IOSTAT_DEV DATA_DISKS < <(awk -v mnt="${HOST[data_mount]:-}" '
            /MAJ:MIN/ { next }
            {
                line = $0; name = $1; gsub(/^[^a-zA-Z0-9]+/, "", name)
                if (line ~ /^[a-zA-Z0-9]/) disk = name
                if ($NF == mnt && mnt != "") {
                    split($2, mm, ":"); dm = (mm[1] == 253) ? "dm-" mm[2] : name
                    print dm, disk; exit
                }
            }' "$lsblk")
        [[ -n $DATA_IOSTAT_DEV ]] && DATA_MAP_HOW="lsblk ($(basename "$lsblk"))"
    fi
}

render_disk_section() {
    local -a ios vms mps
    mapfile -t ios < <(sampled_files iostat)
    mapfile -t vms < <(sampled_files vmstat)
    mapfile -t mps < <(sampled_files mpstat)
    ((${#ios[@]} + ${#vms[@]} + ${#mps[@]})) || return 0
    section "Disk and I/O"
    map_datadir_device

    # ---- where the data lives
    local where="datadir ${VARS[datadir]:-?} is on ${HOST[data_mount]:-?} (${DATA_DEV:-?})"
    if [[ -n $DATA_IOSTAT_DEV ]]; then
        where+=" = iostat device $DATA_IOSTAT_DEV${DATA_DISKS:+ on disk $DATA_DISKS} [$DATA_MAP_HOW]"
    else
        where+="; iostat names LVM/multipath volumes dm-N, and pt-stalk records no mapping, so all busy devices are listed"
    fi
    printf '  '; wrap 2 "$where"
    echo

    # ---- per-device table (since-boot block of each file skipped)
    if ((${#ios[@]})); then
        printf '  %s%-10s %8s %8s %8s %8s %9s %9s %8s %7s %7s%s\n' "$C_B" Device "r/s avg" "r/s max" "w/s avg" "w/s max" "r_await" "w_await" "aqu-sz" "%util" "%util" "$C_0"
        printf '  %-10s %8s %8s %8s %8s %9s %9s %8s %7s %7s\n' "" "" "" "" "" "avg ms" "avg ms" "max" "avg" "max"
        awk -v want="$DATA_IOSTAT_DEV" '
            FNR == 1 { blk = 0 }
            /^Device/ {
                blk++; delete col
                for (i = 1; i <= NF; i++) col[$i] = i
                ra = ("r_await" in col) ? col["r_await"] : col["await"]
                wa = ("w_await" in col) ? col["w_await"] : col["await"]
                aq = ("aqu-sz" in col) ? col["aqu-sz"] : col["avgqu-sz"]
                next
            }
            blk < 2 || NF < 5 || /^Linux/ { next }
            {
                d = $1; seen[d] = 1; n[d]++
                r = $col["r/s"]; w = $col["w/s"]; u = $col["%util"]
                sr[d] += r; sw[d] += w; su[d] += u; sra[d] += $ra; swa[d] += $wa
                if (r > mr[d]) mr[d] = r
                if (w > mw[d]) mw[d] = w
                if (u > mu[d]) mu[d] = u
                if ($aq > mq[d]) mq[d] = $aq
            }
            END {
                for (d in seen) {
                    if (sr[d] + sw[d] == 0 && d != want) continue
                    printf "%s\t%.1f\t%.0f\t%.1f\t%.0f\t%.2f\t%.2f\t%.1f\t%.1f\t%.1f\n", d, sr[d]/n[d], mr[d], sw[d]/n[d], mw[d], sra[d]/n[d], swa[d]/n[d], mq[d], su[d]/n[d], mu[d]
                }
            }' "${ios[@]}" | sort -t$'\t' -k9,9nr | head -8 | while IFS=$'\t' read -r d ra rm wa wm rw ww q ua um; do
                local mark=""; [[ $d == "$DATA_IOSTAT_DEV" ]] && mark=" <- datadir"
                printf '  %-10s %8s %8s %8s %8s %9s %9s %8s %7s %7s%s\n' "$d" "$ra" "$rm" "$wa" "$wm" "$rw" "$ww" "$q" "$ua" "$um" "$mark"
            done
        echo
    fi

    # ---- CPU view of I/O: iowait, blocked processes, run queue
    local busy iow_avg iow_max b_avg b_max wa_max r_avg cpus
    busy=$(num "$(h cpu_busy_avg)"); cpus=$(num "$(h cpus)")
    if ((${#mps[@]})); then
        read -r iow_avg iow_max < <(awk '
            /%iowait/ { for (i = 1; i <= NF; i++) { if ($i == "CPU") c = NF - i; if ($i == "%iowait") w = NF - i }; next }
            /^Average/ || c == "" || NF < c + 1 { next }
            $(NF - c) == "all" { n++; s += $(NF - w); if ($(NF - w) > m) m = $(NF - w) }
            END { printf "%.1f %.1f\n", (n ? s / n : 0), m }' "${mps[@]}")
        kv "CPU iowait" "avg $iow_avg%, max $iow_max% (mpstat, all CPUs)"
    fi
    if ((${#vms[@]})); then
        read -r b_avg b_max wa_max r_avg < <(awk '
            FNR == 1 { rows = 0 }
            /^ *r +b / { for (i = 1; i <= NF; i++) col[$i] = i; next }
            !col["b"] || $1 !~ /^[0-9]+$/ { next }
            { rows++; if (rows == 1) next; n++; sb += $col["b"]; sr += $col["r"]
              if ($col["b"] > mb) mb = $col["b"]; if ($col["wa"] > mw) mw = $col["wa"] }
            END { printf "%.1f %d %d %.1f\n", (n ? sb / n : 0), mb, mw, (n ? sr / n : 0) }' "${vms[@]}")
        kv "Blocked on I/O" "vmstat b: avg $b_avg, max $b_max processes (wa max $wa_max%)"
        ((cpus)) && kv "Run queue" "vmstat r: avg $r_avg on $cpus CPUs ($(calc "$r_avg / $cpus" | cut -c1-4) per CPU)"
    fi
    if is "$busy >= 90"; then
        printf '  '; wrap 2 "Note: CPUs were $busy% busy. iowait only counts time a CPU is idle while I/O is pending, so on a saturated CPU it stays near 0 even when queries wait for disk. Judge the disk by r_await, aqu-sz and %util above, and by vmstat b."
    fi
    echo

    # ---- InnoDB I/O rates (window average, peak per second)
    io_line() {   # label counter unit(bytes|count)
        has_stat "$2" || return 0
        local w p
        w=$(sn "$2" win); p=$(sn "$2" peak)
        if [[ $3 == bytes ]]; then kv "$1" "$(human_bytes "$w")/s avg, $(human_bytes "$p")/s peak  ($2)"
        else kv "$1" "$(human_num "$w")/s avg, $(human_num "$p")/s peak  ($2)"; fi
    }
    io_line "InnoDB reads" Innodb_data_reads count
    io_line "  read volume" Innodb_data_read bytes
    io_line "InnoDB writes" Innodb_data_writes count
    io_line "  write volume" Innodb_data_written bytes
    io_line "Pages flushed" Innodb_buffer_pool_pages_flushed count
    io_line "Doublewrite pages" Innodb_dblwr_pages_written count
    io_line "Redo written" Innodb_os_log_written bytes
    io_line "Redo fsyncs" Innodb_os_log_fsyncs count
    io_line "Data fsyncs" Innodb_data_fsyncs count
    local pend
    pend="reads $(sn Innodb_data_pending_reads max), writes $(sn Innodb_data_pending_writes max), fsyncs $(sn Innodb_data_pending_fsyncs max), redo fsyncs $(sn Innodb_os_log_pending_fsyncs max)"
    kv "Pending I/O (max)" "$pend"

    # ---- verdict, in plain words
    local util_max aq_max r_await
    read -r util_max aq_max r_await < <(awk -v want="${DATA_IOSTAT_DEV:-${HOST[disk]:-}}" '
        FNR == 1 { blk = 0 }
        /^Device/ { blk++; delete col; for (i = 1; i <= NF; i++) col[$i] = i
                    ra = ("r_await" in col) ? col["r_await"] : col["await"]; aq = ("aqu-sz" in col) ? col["aqu-sz"] : col["avgqu-sz"]; next }
        blk < 2 || $1 != want { next }
        { n++; s += $ra; if ($col["%util"] > u) u = $col["%util"]; if ($aq > q) q = $aq }
        END { printf "%.1f %.1f %.2f\n", u, q, (n ? s / n : 0) }' "${ios[@]}")
    local verdict
    if is "$util_max >= 90 || $aq_max >= 8 || $r_await >= 10"; then
        verdict="The data disk is under pressure (%util max $util_max, queue up to $aq_max, read latency $r_await ms): queries that read from disk wait for it."
    elif is "$util_max >= 60"; then
        verdict="The data disk is busy at times (%util max $util_max) but latency stays at $r_await ms for reads."
    else
        verdict="The data disk is not the bottleneck: %util max $util_max, read latency $r_await ms, queue up to $aq_max."
    fi
    echo
    kv "Verdict" "$verdict"
    is "$busy >= 90" && kv "" "CPU, not disk, is the limit in this window ($busy% busy)."

    # ---- other summaries collected with the capture, with their own times
    local ps_sum when first
    if ps_sum=$(extra_file pt-summary.out); then
        when=$(awk -F'|' '/^ *Date \|/ { print $2; exit }' "$ps_sum" | sed 's/^ *//')
        first=${CAPTURES[0]##*/}
        echo
        printf '  '; wrap 2 "pt-summary.out is from $when; the first capture is $first (local time). Its vmstat section is a separate, rounded 5-second sample taken at that moment (the first row is the average since boot), so it shows different seconds than the capture."
    fi
    echo
    printf '  %sFiles%s  ' "$C_D" "$C_0"; wrap 9 "$(files_of iostat vmstat mpstat df mysqladmin)${DATA_MAP_HOW:+; device map: $DATA_MAP_HOW}"
}
