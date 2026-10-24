# shellcheck shell=bash
# InnoDB: redo log size, log buffer, I/O capacity, LRU scan depth,
# thread concurrency, durability settings.

# Redo capacity in bytes for this version, and how it is configured
redo_capacity() {
    if ver_ge 8.0.30 && has_var innodb_redo_log_capacity; then
        REDO_PARAM=innodb_redo_log_capacity
        REDO_CAP=$(vnum innodb_redo_log_capacity)
        REDO_DESC="innodb_redo_log_capacity"
        [[ -n $(dflt innodb_redo_log_capacity) ]] && REDO_DESC+=", default for $MYSQL_SERIES: $(dflt innodb_redo_log_capacity)"
    else
        REDO_PARAM="innodb_log_file_size (x files)"
        REDO_CAP=$(calc_int "$(vnum innodb_log_file_size) * $(max2 "$(vnum innodb_log_files_in_group)" 1)")
        REDO_DESC="innodb_log_file_size $(human_bytes "$(vnum innodb_log_file_size)") x $(vnum innodb_log_files_in_group) files"
        [[ -n $(dflt innodb_log_file_size) ]] && REDO_DESC+=", default for $MYSQL_SERIES: $(dflt innodb_log_file_size) x 2"
    fi
}

# Redo pressure, as fractions of "Max checkpoint age" (the point where user
# threads stall in log_free_check). From the source:
#   5.7  log0log.cc:829-855  async preflush at 7/8, sync preflush at 15/16
#   8.x  log0files_capacity.cc / log0chkp.cc: adaptive ramp ends ~0.87,
#        sync flush ~0.93 (measured on the oldest modified page's age)
FLUSH_AGGRESSIVE=0.87
FLUSH_SYNC=0.93

# Sets CKPT_FILL (checkpoint age / max), MOD_FILL (modified age / max),
# CKPT_AGE, CKPT_MAX and CKPT_SRC; empty values when unknown.
checkpoint_fill() {
    local age="" max="" mod
    CKPT_EST="" CKPT_SRC=""
    if has_stat Innodb_checkpoint_max_age && is "$(sn Innodb_checkpoint_max_age) > 0"; then
        # Percona exports both every second (5.7, 8.0, 8.4)
        age=$(sn Innodb_checkpoint_age max); max=$(sn Innodb_checkpoint_max_age)
        CKPT_SRC="Innodb_checkpoint_age, max of every sample"
    else
        age=$(ib checkpoint_age); max=$(ib max_checkpoint_age)
        CKPT_SRC="SHOW ENGINE INNODB STATUS"
        if [[ -z $max ]] && ver_lt 8.0.0 && is "$REDO_CAP > 0"; then
            # Community 5.7 does not print it: log_calc_max_ages(), log0log.cc:829-855
            local files ps tc
            files=$(max2 "$(vnum innodb_log_files_in_group)" 1)
            ps=$(num "$(v innodb_page_size)" 16384); tc=$(vnum innodb_thread_concurrency)
            max=$(calc_int "((($(vnum innodb_log_file_size) - 2048) * $files) * 0.9 - (4 * (10 + $tc) + 8) * $ps) * 0.9")
            CKPT_EST=" (max computed as in log_calc_max_ages)"
        fi
    fi
    mod=$(ib modified_age)
    CKPT_FILL="" MOD_FILL="" CKPT_AGE="" CKPT_MAX=""
    if [[ -n $age && -n $max ]] && is "$max > 0"; then
        CKPT_FILL=$(calc "$age / $max"); CKPT_AGE=$age; CKPT_MAX=$max
        # With no dirty pages InnoDB prints current_lsn - 0 as the modified age
        # (buf_pool_get_oldest_modification_lwm() returns 0, buf0buf.cc). A real
        # modified age cannot exceed the max checkpoint age, so ignore those.
        [[ -n $mod ]] && is "$mod <= $max" && MOD_FILL=$(calc "$mod / $max")
    fi
}

# Worst of checkpoint age and modified age, as a fraction of max (or "")
redo_pressure() {
    [[ -z $CKPT_FILL ]] && return
    max2 "$CKPT_FILL" "${MOD_FILL:-0}"
}

rule_redo_log() {
    RULE_GROUP=innodb
    redo_capacity; checkpoint_fill
    local win life peak rate mins hour target new conf fill limit
    win=$(sn Innodb_os_log_written win); life=$(sn Innodb_os_log_written life); peak=$(sn Innodb_os_log_written peak)
    rate=$(max2 "$win" "$life")
    mins=$(calc "$rate > 0 ? $REDO_CAP / $rate / 60 : 99999")
    fill=$(redo_pressure)

    ev "Redo written: $(human_bytes "$win")/s in window (peak $(human_bytes "$peak")/s), $(human_bytes "$life")/s since start"
    ev "Capacity $(human_bytes "$REDO_CAP") ($REDO_DESC) holds $(human_dur "$(calc "$mins * 60")") of writes at $(human_bytes "$rate")/s"
    if [[ -n $fill ]]; then
        ev "Checkpoint age: max $(human_bytes "$CKPT_AGE") of $(human_bytes "$CKPT_MAX") = $(pct "$CKPT_FILL" 1)${MOD_FILL:+; modified age $(pct "$MOD_FILL" 1)} ($CKPT_SRC)$CKPT_EST"
        ev "Flushing thresholds: aggressive from ~$(pct $FLUSH_AGGRESSIVE 1), sync flush (writes stall) from ~$(pct $FLUSH_SYNC 1) of max checkpoint age"
    fi

    # 512G is the hard limit in every series (5.7: total of all files < 512G)
    limit=$((512 * GiB))
    hour=$(round_up "$(calc "$rate * 3600")" "$GiB")
    # Heuristic ceiling when there is no flushing pressure: about the buffer
    # pool size (innodb_dedicated_server uses <= 0.75 x buffer pool in 8.0).
    local bp_cap; bp_cap=$(round_up "$(max2 "$(vnum innodb_buffer_pool_size)" "$GiB")" "$GiB")

    REDO_UNDERSIZED=0
    local formula status why
    if [[ -n $fill ]] && is "$fill >= $FLUSH_AGGRESSIVE"; then
        target=$(min2 "$hour" "$(max2 "$bp_cap" "$(calc_int "$REDO_CAP * 2")")")
        formula="target = one hour of writes, at most max(buffer pool size, 2 x current) and 512G: checkpoint age reached the aggressive-flushing zone"
        status=CHANGE conf=High REDO_UNDERSIZED=1
        why="InnoDB reached $(pct "$fill" 1) of the max checkpoint age: it flushes pages furiously (and stalls writes above ~93%) to free redo space."
    elif is "$mins < 60"; then
        target=$(min2 "$hour" "$bp_cap")
        formula="one hour of writes = $(human_bytes "$rate")/s x 3600 = $(human_bytes "$(calc "$rate * 3600")"), rounded up to a whole GiB = $(human_bytes "$hour"), at most about the buffer pool size ($(human_bytes "$bp_cap")) while there is no flushing pressure"
        if is "$target <= $REDO_CAP"; then
            suggest "$REDO_PARAM" OK Medium "$(human_bytes "$REDO_CAP")" "keep" "$formula" \
                "Less than an hour of writes fits, but the redo log is already about the size of the buffer pool and the checkpoint age is not near the flushing thresholds."
            return
        elif [[ -n $fill ]] && is "$fill >= 0.5"; then
            status=CHANGE conf=Medium REDO_UNDERSIZED=1
            why="The redo log holds only $(human_dur "$(calc "$mins * 60")") of writes and the checkpoint age already reached $(pct "$fill" 1) of its maximum during the capture."
        elif is "$mins < 20"; then
            status=REVIEW conf=Medium
            why="At the $( is "$rate == $life" && echo 'since-start average' || echo 'capture' ) write rate the redo log holds only $(human_dur "$(calc "$mins * 60")") of writes, but during the capture the checkpoint age stayed at $(pct "${fill:-0}" 1) of its maximum, so it is not limiting this window. A larger redo log smooths flushing during write bursts at the cost of longer crash recovery; check the checkpoint age at peak write times before changing it."
        else
            status=REVIEW conf=Low
            why="Less than an hour of writes fits, but the checkpoint age is not near the flushing thresholds. Growing it smooths flushing at the cost of longer crash recovery."
        fi
    else
        suggest "$REDO_PARAM" OK High "$(human_bytes "$REDO_CAP")" "keep" "capacity >= one hour of writes, checkpoint age below the flushing thresholds" "Enough redo space."
        return
    fi
    is "$target > $limit" && target=$limit

    if ver_ge 8.0.30 && has_var innodb_redo_log_capacity; then
        new=$(human_bytes "$target")
        why+=" Dynamic since 8.0.30: SET PERSIST innodb_redo_log_capacity = $target;"
    else
        local files per; files=$(max2 "$(vnum innodb_log_files_in_group)" 1)
        per=$(round_up "$(calc "$target / $files")" $((256 * MiB)))
        new="$(human_bytes "$per") x $files"
        why+=" Needs a restart: innodb_log_file_size = $(human_bytes "$per") (files_in_group = $files)."
    fi
    suggest "$REDO_PARAM" "$status" "$conf" "$(human_bytes "$REDO_CAP")" "$new" "$formula" "$why"
}

rule_log_buffer() {
    RULE_GROUP=innodb
    local cur waits_win waits_life peak new floor
    cur=$(vnum innodb_log_buffer_size)
    waits_win=$(sd Innodb_log_waits); waits_life=$(sn Innodb_log_waits)
    peak=$(sn Innodb_os_log_written peak)
    ev "Innodb_log_waits: $(human_num "$waits_win") in window, $(human_num "$waits_life") since start ($(human_num "$(calc "$(sn Innodb_log_waits life) * 3600")")/hour)"
    ev "Peak redo per second: $(human_bytes "$peak"); innodb_log_buffer_size $(human_bytes "$cur")$(dflt_note innodb_log_buffer_size)"
    ev "Innodb_log_waits counts waits for space in the log buffer only (log0buf.cc), not waits for redo capacity"
    local how="Dynamic: SET PERSIST innodb_log_buffer_size."
    ver_lt 8.0.0 && how="Needs a restart in 5.7."
    floor=$((32 * MiB)); ver_ge 8.0.0 && floor=$((64 * MiB))
    local formula
    if is "$waits_win > 0"; then
        # waits now: make room for a second of peak redo as well
        new=$(max2 "$(max2 "$(calc_int "$cur * 2")" "$(pow2_up "$peak")")" "$floor")
        is "$new > 256 * $MiB" && new=$((256 * MiB))
        formula="new = max(2 x current, peak redo bytes/s rounded up to a power of 2, $(human_bytes "$floor")), at most 256M"
    else
        new=$(max2 "$(calc_int "$cur * 2")" "$floor")
        formula="new = max(2 x current, $(human_bytes "$floor"))"
    fi
    if is "$waits_win > 0"; then
        suggest innodb_log_buffer_size CHANGE High "$(human_bytes "$cur")" "$(human_bytes "$new")" "$formula" \
            "Transactions waited for space in the log buffer during the capture. $how"
    elif is "$waits_life > 0"; then
        suggest innodb_log_buffer_size REVIEW Low "$(human_bytes "$cur")" "$(human_bytes "$new")" "$formula" \
            "Log buffer waits happened since start, but not during the capture (probably bulk loads or large transactions). $how"
    else
        suggest innodb_log_buffer_size OK High "$(human_bytes "$cur")" "keep" "Innodb_log_waits = 0" "No waits for the log buffer."
    fi
}

rule_io_capacity() {
    RULE_GROUP=innodb
    local cap capmax flushed peak total dirty dirty_pct maxdirty util_max util_avg new newmax
    cap=$(vnum innodb_io_capacity); capmax=$(vnum innodb_io_capacity_max)
    flushed=$(sn Innodb_buffer_pool_pages_flushed win); peak=$(sn Innodb_buffer_pool_pages_flushed peak)
    total=$(sn Innodb_buffer_pool_pages_total); dirty=$(sn Innodb_buffer_pool_pages_dirty max)
    dirty_pct=$(calc "$total > 0 ? 100 * $dirty / $total : 0")
    maxdirty=$(vnum innodb_max_dirty_pages_pct)
    util_max=$(num "$(h disk_util_max)"); util_avg=$(num "$(h disk_util_avg)")
    redo_capacity; checkpoint_fill

    ev "Pages flushed: $(human_num "$flushed")/s in window (peak $(human_num "$peak")/s) vs io_capacity $cap / io_capacity_max $capmax (defaults for $MYSQL_SERIES: $(dflt innodb_io_capacity) / $(dflt innodb_io_capacity_max))"
    ev "Dirty pages: max $(human_num "$dirty_pct")% of the pool (innodb_max_dirty_pages_pct = $(human_num "$maxdirty"))"
    local fill; fill=$(redo_pressure)
    [[ -n $fill ]] && ev "Redo pressure: $(pct "$fill" 1) of max checkpoint age (aggressive flushing from ~$(pct $FLUSH_AGGRESSIVE 1))"
    if [[ -n $(h disk) ]]; then
        ev "Disk $(h disk) ($(h disk_how)): w/s avg $(h disk_w_avg) max $(h disk_w_max); r/s avg $(h disk_r_avg); %util avg $util_avg max $util_max; w_await avg $(h disk_wawait_avg) ms"
    fi

    new=$(round_up "$(max2 "$(calc "$flushed * 1.25")" "$cap")" 100)
    newmax=$(max2 "$capmax" "$(calc_int "$new * 2")")
    local formula="io_capacity = observed flush rate x 1.25 (rounded to 100); io_capacity_max = max(current, 2 x io_capacity)"
    local pressure=0
    { [[ -n $fill ]] && is "$fill > 0.5"; } && pressure=1
    is "$dirty_pct > $maxdirty * 0.9" && pressure=1

    if ((pressure)) && [[ ${REDO_UNDERSIZED:-0} -eq 1 ]]; then
        suggest "innodb_io_capacity / _max" REVIEW Low "$cap / $capmax" "fix redo first" "re-evaluate after the redo log change" \
            "The flushing pressure comes from a redo log that is too small. Sync flushing is not limited by io_capacity_max (buf0flu.cc: it flushes up to 2 x io_capacity_max per pass without sleeping), so raising io_capacity does not help here. Resize the redo log, take a new capture, then revisit io_capacity."
    elif ((pressure)) && is "$flushed > $cap * 0.8"; then
        if is "$util_max < 80"; then
            suggest "innodb_io_capacity / _max" CHANGE Medium "$cap / $capmax" "$new / $newmax" "$formula" \
                "Flushing runs at the io_capacity ceiling while dirty pages / checkpoint age build up, and the disk has spare capacity. Dynamic: SET PERSIST innodb_io_capacity, innodb_io_capacity_max."
        else
            suggest "innodb_io_capacity / _max" REVIEW Medium "$cap / $capmax" "keep" "disk %util max >= 80%" \
                "Flushing cannot keep up, but the disk is already busy. Raising io_capacity will not help; the storage (or the write load) is the limit."
        fi
    elif is "$util_max >= 95 && $peak >= $capmax * 0.8"; then
        suggest "innodb_io_capacity / _max" REVIEW Low "$cap / $capmax" "keep" "disk saturated while flushing near io_capacity_max" \
            "The disk hits 100% while InnoDB flushes near its maximum. Background flushing may be competing with reads; consider whether io_capacity_max is above what the device sustains."
    else
        suggest "innodb_io_capacity / _max" OK Medium "$cap / $capmax" "keep" "no flushing pressure" \
            "Dirty pages and checkpoint age are under control."
    fi
}

rule_lru_scan_depth() {
    RULE_GROUP=innodb
    local cur waits life new cleaners inst
    cur=$(vnum innodb_lru_scan_depth); waits=$(sd Innodb_buffer_pool_wait_free); life=$(sn Innodb_buffer_pool_wait_free)
    cleaners=$(vnum innodb_page_cleaners); inst=$(vnum innodb_buffer_pool_instances)
    ev "Innodb_buffer_pool_wait_free: $(human_num "$waits") in window, $(human_num "$life") since start"
    ev "Free pages min $(human_num "$(sn Innodb_buffer_pool_pages_free min)"); innodb_page_cleaners $cleaners$(dflt_note innodb_page_cleaners), buffer pool instances $inst"
    new=$(min2 "$(calc_int "$cur * 2")" 4096)
    if is "$waits > 0"; then
        if is "$cur < 4096"; then
            suggest innodb_lru_scan_depth CHANGE Medium "$cur" "$new" "new = min(2 x current, 4096)" \
                "Threads had to wait for a free page: page cleaners do not free pages fast enough.$(is "$cleaners < $inst" && echo ' Also set innodb_page_cleaners = innodb_buffer_pool_instances.') Dynamic."
        else
            suggest innodb_lru_scan_depth REVIEW Medium "$cur" "keep" "already >= 4096" \
                "Free-page waits even with a deep LRU scan: the buffer pool is too small for the workload, or the disk is the limit."
        fi
    elif is "$life > 0"; then
        suggest innodb_lru_scan_depth REVIEW Low "$cur" "$new" "new = min(2 x current, 4096)" \
            "Free-page waits happened since start, but not during the capture."
    else
        suggest innodb_lru_scan_depth OK High "$cur" "keep" "no free-page waits" "Page cleaners keep up."
    fi
    if is "$cleaners < $inst"; then
        finding "innodb_page_cleaners ($cleaners) is lower than innodb_buffer_pool_instances ($inst); set them equal so each instance has a cleaner."
    fi
}

rule_thread_concurrency() {
    RULE_GROUP=innodb
    local cur cpus ravg rmax queued busy
    cur=$(vnum innodb_thread_concurrency); cpus=$(num "$(h cpus)")
    ravg=$(sn Threads_running avg); rmax=$(sn Threads_running max)
    queued=$(num "$(ib queries_queued)"); busy=$(num "$(h cpu_busy_avg)")
    ev "Threads_running: avg $(human_num "$ravg"), max $rmax in window; CPUs: $cpus; CPU busy avg $busy% (max $(h cpu_busy_max)%)"
    if is "$cur > 0"; then
        ev "InnoDB queue: max $queued queries waiting at innodb_thread_concurrency = $cur"
    else
        ev "innodb_thread_concurrency = 0: InnoDB does not track a queue (the status line always shows 0 in queue)"
    fi
    ev "thread_handling = ${VARS[thread_handling]:-n/a}"
    if is "$cur > 0 && $queued > 0"; then
        local new; new=$(max2 "$(calc_int "$cur * 2")" "$(calc_int "$cpus * 2")")
        suggest innodb_thread_concurrency CHANGE Medium "$cur" "$new" "new = max(2 x current, 2 x CPUs)" \
            "Queries are queued at the InnoDB concurrency limit. Raise it, or set 0 (unlimited) if CPU is not saturated."
    elif is "$cur == 0 && $cpus > 0 && $ravg > 2 * $cpus"; then
        local tp="consider innodb_thread_concurrency = $((cpus * 2))"
        [[ $MYSQL_FLAVOR == Percona* ]] && tp="consider the thread pool (thread_handling = pool-of-threads) or innodb_thread_concurrency = $((cpus * 2))"
        suggest innodb_thread_concurrency REVIEW Low "$cur" "$((cpus * 2))" "2 x CPUs" \
            "On average more than two running threads per CPU: threads compete for CPU and mutexes. $tp. Test first; this mostly helps when contention, not single slow queries, is the problem."
    else
        suggest innodb_thread_concurrency OK Medium "$cur" "keep" "running threads <= 2 x CPUs, no queue" "No concurrency pressure."
    fi
}

rule_durability() {
    RULE_GROUP=innodb
    local flc sb fs wa
    flc=${VARS[innodb_flush_log_at_trx_commit]:-n/a}; sb=${VARS[sync_binlog]:-n/a}
    fs=$(sn Innodb_os_log_fsyncs win); wa=$(num "$(h disk_wawait_avg)")
    ev "innodb_flush_log_at_trx_commit = $flc, sync_binlog = $sb, log_bin = ${VARS[log_bin]:-n/a}"
    ev "Redo fsyncs $(human_num "$fs")/s in window; data disk w_await avg $wa ms"
    if [[ $flc == 1 && ( $sb == 1 || ${VARS[log_bin]:-OFF} == OFF ) ]]; then
        if is "$wa > 5"; then
            suggest "durability (flush_log/sync_binlog)" INFO Medium "$flc / $sb" "keep" "" \
                "Fully durable, but writes take over 5 ms on average, which caps the commit rate. Prefer faster storage or group commit (binlog_group_commit_sync_delay) over relaxing durability."
        else
            suggest "durability (flush_log/sync_binlog)" OK High "$flc / $sb" "keep" "" "Fully durable and fsync latency is low."
        fi
    else
        suggest "durability (flush_log/sync_binlog)" INFO High "$flc / $sb" "1 / 1 (see why)" "" \
            "Not fully durable: a crash (or OS crash) can lose up to about a second of committed transactions, and the binlog may diverge from InnoDB. Fine only if this was a deliberate choice."
    fi
}
