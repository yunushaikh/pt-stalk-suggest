# shellcheck shell=bash
# Memory budget, innodb_buffer_pool_size, max_connections.
#
# The memory budget is shared by several parameters, so it is computed once
# here and the other rules read the MEM_* globals.

compute_memory_budget() {
    MEM_TOTAL=$(num "$(h mem_total)")
    # Without meminfo there is no budget: memory-based suggestions are skipped
    MEM_KNOWN=1; is "$MEM_TOTAL > 0" || MEM_KNOWN=0
    if [[ -n ${OPT_OS_RESERVE:-} ]]; then
        MEM_OS_RESERVE=$(to_bytes "$OPT_OS_RESERVE")
    else
        # 10% of RAM, at least 1 GiB, at most 8 GiB
        MEM_OS_RESERVE=$(calc_int "$MEM_TOTAL * 0.10 < $GiB ? $GiB : ($MEM_TOTAL * 0.10 > 8 * $GiB ? 8 * $GiB : $MEM_TOTAL * 0.10)")
    fi
    MEM_OTHER_RSS=$(num "$(h other_rss)")
    MEM_HUGE_UNUSED=0
    if is "$(num "$(h hugepages_bytes)") > 0" && [[ $(vnum large_pages) -eq 0 ]]; then
        MEM_HUGE_UNUSED=$(num "$(h hugepages_bytes)")
    fi
    MEM_BUDGET=$(calc_int "$MEM_TOTAL - $MEM_OS_RESERVE - $MEM_OTHER_RSS - $MEM_HUGE_UNUSED")

    local bp qc=0
    bp=$(vnum innodb_buffer_pool_size)
    # 5.7 allocates query_cache_size at startup even with query_cache_type=OFF
    # (mysqld.cc:4081 resize() regardless of the type)
    has_var query_cache_size && qc=$(vnum query_cache_size)
    MEM_GLOBAL=$(calc_int "$bp + $(vnum innodb_log_buffer_size) + $(vnum key_buffer_size) + $qc")

    # TempTable (8.0+) can grow to temptable_max_ram in RAM, shared by all sessions
    MEM_ONDEMAND=0
    if ver_ge 8.0.0 && [[ ${VARS[internal_tmp_mem_storage_engine]:-TempTable} == TempTable ]]; then
        MEM_ONDEMAND=$(vnum temptable_max_ram)
    fi

    local binlog=0
    [[ $(vnum log_bin) -eq 1 ]] && binlog=$(vnum binlog_cache_size)
    MEM_PER_THREAD=$(calc_int "$(vnum sort_buffer_size) + $(vnum join_buffer_size) + $(vnum read_buffer_size) + $(vnum read_rnd_buffer_size) + $(vnum thread_stack) + 2 * $(vnum net_buffer_length) + $binlog")

    # 5.7 (or MEMORY engine): each session may hold an in-memory temp table
    MEM_TMP_PER_THREAD=0
    if ver_lt 8.0.0 || [[ ${VARS[internal_tmp_mem_storage_engine]:-} == MEMORY ]]; then
        MEM_TMP_PER_THREAD=$(min2 "$(vnum tmp_table_size)" "$(vnum max_heap_table_size)")
    fi

    MEM_MUC=$(sn Max_used_connections)
    MEM_EXPECTED=$(calc_int "$MEM_GLOBAL + $MEM_PER_THREAD * $MEM_MUC")
    MEM_WORST=$(calc_int "$MEM_GLOBAL + $MEM_ONDEMAND + ($MEM_PER_THREAD + $MEM_TMP_PER_THREAD) * $(vnum max_connections)")
    MEM_RSS=$(num "$(h mysqld_rss)")

    # Memory mysqld uses beyond the buffer pool: the larger of what we observe
    # (RSS - buffer pool) and what the settings imply.
    local calc_over obs_over=0
    calc_over=$(calc_int "$MEM_GLOBAL - $bp + $MEM_PER_THREAD * $MEM_MUC")
    is "$MEM_RSS > $bp" && obs_over=$(calc_int "$MEM_RSS - $bp")
    MEM_OVERHEAD=$(max2 "$calc_over" "$obs_over")
    MEM_OVERHEAD_SRC=$([[ $MEM_OVERHEAD == "$obs_over" && $obs_over != 0 ]] && echo "observed RSS - buffer pool" || echo "calculated from settings")

    # mysqld using far more than its settings explain (allocator fragmentation,
    # AHI, many tables / partitions, P_S) is worth reporting on its own
    if is "$obs_over > 2 * $calc_over && $obs_over > 2 * $GiB"; then
        finding "mysqld uses $(human_bytes "$obs_over") beyond the buffer pool, while its settings explain about $(human_bytes "$calc_over"). Check performance_schema.memory_summary_global_by_event_name for the largest consumers; glibc malloc fragmentation is a common cause (jemalloc helps)."
    fi

    MEM_SWAPPING=0
    is "$(num "$(h swap_in_avg)") > 0 || $(num "$(h swap_out_avg)") > 0" && MEM_SWAPPING=1
    return 0
}

render_memory_budget() {
    section "Memory budget"
    if ((!MEM_KNOWN)); then
        kv "RAM" "unknown (no meminfo file in the capture): memory-based suggestions skipped"
        kv "Per connection" "$(human_bytes "$MEM_PER_THREAD")  (sort+join+read+read_rnd+thread_stack+net buffers+binlog cache)"
        return
    fi
    kv "RAM" "$(human_bytes "$MEM_TOTAL")"
    kv "OS reserve" "$(human_bytes "$MEM_OS_RESERVE")  (10% of RAM, 1G..8G; override with --os-reserve)"
    kv "Other processes" "$(human_bytes "$MEM_OTHER_RSS")  (sum of non-mysqld RSS in ps)"
    is "$MEM_HUGE_UNUSED > 0" && kv "Unused hugepages" "$(human_bytes "$MEM_HUGE_UNUSED")  (reserved but large_pages=OFF)"
    kv "Budget for mysqld" "${C_B}$(human_bytes "$MEM_BUDGET")${C_0}  = RAM - reserve - other processes"
    echo
    kv "Global buffers" "$(human_bytes "$MEM_GLOBAL")  (buffer pool + log buffer + key buffer + query cache)"
    is "$MEM_ONDEMAND > 0" && kv "TempTable max" "$(human_bytes "$MEM_ONDEMAND")  (temptable_max_ram, on demand)"
    kv "Per connection" "$(human_bytes "$MEM_PER_THREAD")  (sort+join+read+read_rnd+thread_stack+net buffers+binlog cache)"
    is "$MEM_TMP_PER_THREAD > 0" && kv "Per conn. tmp tbl" "$(human_bytes "$MEM_TMP_PER_THREAD")  (min(tmp_table_size, max_heap_table_size))"
    kv "Expected use" "$(human_bytes "$MEM_EXPECTED")  = global + per-connection x Max_used_connections ($MEM_MUC)"
    kv "Worst case" "$(human_bytes "$MEM_WORST")  = global + TempTable + per-connection x max_connections ($(vnum max_connections))"
    kv "mysqld RSS now" "$(human_bytes "$MEM_RSS")  ($(pct "$MEM_RSS" "$MEM_TOTAL") of RAM)"
    local verdict
    if is "$MEM_RSS > $MEM_BUDGET"; then verdict="${C_R}RSS is above the budget${C_0}"
    elif is "$MEM_WORST > $MEM_BUDGET"; then verdict="${C_Y}fits today, but the worst case exceeds the budget${C_0}"
    else verdict="${C_G}fits, including the worst case${C_0}"; fi
    kv "Verdict" "$verdict"
}

# pt-mysql-summary.out, when a collection script saved it next to the capture:
# its InnoDB section (fill) and its own 10-second status sample. Its counters
# are rounded ("fuzzy") and it ran at a different moment than pt-stalk.
read_mysql_summary_bp() {
    PMS_TIME="" PMS_FILL="" PMS_READS="" PMS_REQS=""
    local f; f=$(extra_file pt-mysql-summary.out) || return 0
    PMS_TIME=$(awk -F'|' '/^ *Time \|/ { sub(/^ */, "", $2); print $2; exit }' "$f")
    PMS_FILL=$(awk -F'|' '/^ *Buffer Pool Fill \|/ { gsub(/ /, "", $2); print $2; exit }' "$f")
    # Variable / Per day / Per second / N secs: take the per-second column
    read -r PMS_READS PMS_REQS < <(awk '/^# Status Counters/ { in_sc = 1; next } /^# / { in_sc = 0 }
        in_sc && $1 == "Innodb_buffer_pool_reads" { r = $3 } in_sc && $1 == "Innodb_buffer_pool_read_requests" { q = $3 }
        END { print r + 0, q + 0 }' "$f")
}

rule_buffer_pool() {
    RULE_GROUP=memory
    local bp chunk inst unit reads req miss_win miss_life free_min total wait_free cap page
    bp=$(vnum innodb_buffer_pool_size)
    chunk=$(vnum innodb_buffer_pool_chunk_size); inst=$(vnum innodb_buffer_pool_instances)
    unit=$(calc_int "$chunk * $inst"); is "$unit > 0" || unit=$((128 * MiB))
    page=$(num "$(v innodb_page_size)" 16384)

    reads=$(sd Innodb_buffer_pool_reads); req=$(sd Innodb_buffer_pool_read_requests)
    miss_win=$(calc "$req > 0 ? $reads / $req : 0")
    miss_life=$(calc "$(sn Innodb_buffer_pool_read_requests) > 0 ? $(sn Innodb_buffer_pool_reads) / $(sn Innodb_buffer_pool_read_requests) : 0")
    total=$(sn Innodb_buffer_pool_pages_total)
    free_min=$(sn Innodb_buffer_pool_pages_free min)
    wait_free=$(sd Innodb_buffer_pool_wait_free)
    cap=$(round_down "$(calc "$MEM_BUDGET - $MEM_OVERHEAD")" "$unit")
    is "$cap < 0" && cap=0
    local rps; rps=$(sn Innodb_buffer_pool_reads win)

    # ---- evidence: how often reads miss the pool
    ev "Miss rate (Innodb_buffer_pool_reads / Innodb_buffer_pool_read_requests): $(pct "$miss_win" 1) in window, $(pct "$miss_life" 1) since start"
    ev "Disk reads: $(human_num "$rps")/s in window (peak $(human_num "$(s Innodb_buffer_pool_reads peak)")/s) for $(human_num "$(s Innodb_buffer_pool_read_requests win)") logical reads/s; data disk read latency $(h disk_rawait_avg) ms"
    read_mysql_summary_bp
    if [[ -n $PMS_TIME ]]; then
        local pms_miss; pms_miss=$(calc "$PMS_REQS > 0 ? $PMS_READS / $PMS_REQS : 0")
        ev "pt-mysql-summary.out ($PMS_TIME, its own 10 s sample, rounded): Buffer Pool Fill ${PMS_FILL:-?}; $(human_num "$PMS_READS") disk reads/s of $(human_num "$PMS_REQS") requests/s = $(pct "$pms_miss" 1) miss"
    fi
    # ---- evidence: what the pool holds
    local data_max misc_max
    data_max=$(sn Innodb_buffer_pool_pages_data max); misc_max=$(sn Innodb_buffer_pool_pages_misc max)
    ev "Pool pages: data $(pct "$data_max" "$total"), free min $(pct "$free_min" "$total"), other uses $(pct "$misc_max" "$total") (Innodb_buffer_pool_pages_misc: adaptive hash index and row-lock memory); free-page waits in window: $(human_num "$wait_free")"
    # ---- evidence: LRU churn (InnoDB status), read-ahead waste
    local yr nyr evn
    yr=$(num "$(ib young_rate)"); nyr=$(num "$(ib notyoung_rate)"); evn=$(num "$(ib evicted_noaccess)")
    if [[ -n $(ib young_rate) ]]; then
        ev "LRU (InnoDB status): $(human_num "$yr") pages/s made young (re-used), $(human_num "$nyr")/s not made young (read once), $(human_num "$evn")/s evicted without ever being read"
    fi
    ev "Room for the pool: budget $(human_bytes "$MEM_BUDGET") - other mysqld memory $(human_bytes "$MEM_OVERHEAD") ($MEM_OVERHEAD_SRC) = $(human_bytes "$cap")"
    if [[ $MEM_SWAPPING -eq 1 || $(num "$(h swap_used_max)") -gt 0 ]]; then
        ev "Swap: used $(human_bytes "$(h swap_used_max)"), swap-in avg $(h swap_in_avg) KiB/s (max $(h swap_in_max)), swap-out avg $(h swap_out_avg) KiB/s"
    fi
    [[ $(vnum innodb_dedicated_server) -eq 1 ]] && ev "innodb_dedicated_server=ON: the buffer pool is sized automatically at startup"

    # Pages taken out of the LRU for other uses: row-lock heaps and the AHI come
    # from the buffer pool (MEM_HEAP_FOR_LOCK_HEAP = MEM_HEAP_BUFFER, mem0mem.h;
    # pages_misc = total - LRU - free, srv0srv.cc)
    if is "$total > 0 && $misc_max > $total * 0.10"; then
        finding "$(pct "$misc_max" "$total") of the buffer pool was used for other things than data (Innodb_buffer_pool_pages_misc): InnoDB takes row-lock memory and the adaptive hash index from the pool, so millions of row locks or a large hash index leave less room for cached data."
    fi

    if ((!MEM_KNOWN)); then
        suggest innodb_buffer_pool_size INFO Low "$(human_bytes "$bp")" "unknown" "needs RAM from meminfo" \
            "The capture has no meminfo file, so there is no memory budget to size the buffer pool against. The miss-rate evidence above still applies."
        return
    fi
    local formula="cap = (RAM - OS reserve - other processes) - max(mysqld RSS - buffer pool, other global + per-connection x Max_used_connections), rounded down to chunk_size x instances ($(human_bytes "$unit"))"
    local warm=1 uptime; uptime=$(num "$(h uptime)")
    ((uptime < 86400)) && warm=0

    # Ignore miss rates on a trickle of reads: growth needs >= 10 disk reads/s
    if is "$rps < 10" && is "$wait_free == 0"; then miss_win=0; fi

    # Misses that come from table scans: pages read once (not made young) far
    # outnumber re-used ones and rows are read sequentially at a high rate. The
    # midpoint insertion keeps scans from flushing hot pages, so a bigger pool
    # helps less than an index.
    local scans=0 scan_note=""
    if is "$nyr > 5 * $yr && $nyr > 1000 && $(sn Handler_read_rnd_next win) >= 100000"; then
        scans=1
        scan_note=" Most pages are read once (not made young: $(human_num "$nyr")/s vs $(human_num "$yr")/s re-used) while $(human_num "$(sn Handler_read_rnd_next win)") rows/s are read by table scans: indexing those queries cuts the disk reads more than a larger pool."
    fi
    # Do the misses hurt? Slow data-disk reads make them expensive.
    local slow_disk=0; is "$(num "$(h disk_rawait_avg)") >= 5" && slow_disk=1

    # Real memory pressure: swapping, RSS clearly over budget, or almost no
    # MemAvailable left. A small overshoot of the (heuristic) budget alone is
    # not enough to shrink the pool.
    local avail_min pressure=0 why_mem=""
    avail_min=$(num "$(h mem_avail_min)")
    if [[ $MEM_SWAPPING -eq 1 ]]; then pressure=1; why_mem="the host is swapping"
    elif is "$MEM_RSS > $MEM_BUDGET * 1.05"; then pressure=1; why_mem="mysqld RSS is more than 5% over its budget"
    elif is "$avail_min > 0 && $avail_min < $MEM_TOTAL * 0.05"; then pressure=1; why_mem="MemAvailable fell below 5% of RAM"
    fi
    ev "MemAvailable min $(human_bytes "$avail_min") ($(pct "$avail_min" "$MEM_TOTAL") of RAM); swap $(human_bytes "$(h swap_total)")$( is "$(num "$(h swap_total)") == 0" && echo ' (none: if memory runs out, the kernel OOM killer stops mysqld)')"

    # Sizes for the "increase" outcomes
    local grow add_ram want
    grow=$(round_down "$(min2 "$cap" "$(calc "$bp * 2")")" "$unit")
    want=$(round_up "$(calc "$bp * 1.5")" "$unit")
    add_ram=$(round_up "$(max2 0 "$(calc "$want - $cap")")" "$GiB")
    # Size for the "reduce" outcome: the cached data plus 20%, at least 128M
    local fits; fits=$(round_up "$(max2 "$(calc "$data_max * $page * 1.2")" $((128 * MiB)))" "$unit")

    if is "$bp > $cap * 1.05" && ((pressure)) && is "$cap < $unit || $cap < 128 * $MiB"; then
        # nothing sensible left to shrink to: the rest of mysqld and the host
        # already use the memory
        suggest innodb_buffer_pool_size CHANGE High "$(human_bytes "$bp")" "add RAM" "$formula" \
            "The host is short of memory ($why_mem) and, after the OS reserve, other processes and mysqld's memory outside the pool, there is no room left for a buffer pool at all. Add RAM or reduce what else uses memory (other processes, per-connection buffers, max_connections); shrinking the pool alone cannot fix this."
    elif is "$bp > $cap * 1.05" && ((pressure)); then
        suggest innodb_buffer_pool_size CHANGE "$([[ $MEM_SWAPPING -eq 1 ]] && echo High || echo Medium)" \
            "$(human_bytes "$bp")" "reduce to $(human_bytes "$cap")" "$formula" \
            "The host is short of memory ($why_mem). Shrink the buffer pool to the cap, or add RAM. Online resize: SET GLOBAL innodb_buffer_pool_size."
    elif ((!warm)) && is "$miss_win > 0.001 || $wait_free > 0"; then
        suggest innodb_buffer_pool_size REVIEW Low "$(human_bytes "$bp")" "recheck after a day" "$formula" \
            "Disk reads are high, but MySQL started less than a day ago: part of it is the buffer pool warming up. Take another capture after a day of normal load before resizing."
    elif is "$miss_win > 0.01"; then
        local conf=Medium; ((scans)) && conf=Low; ((slow_disk && !scans)) && conf=High
        if is "$cap > $bp * 1.10 && $MEM_RSS <= $MEM_BUDGET" && [[ $MEM_SWAPPING -eq 0 ]]; then
            suggest innodb_buffer_pool_size CHANGE "$conf" "$(human_bytes "$bp")" "increase to $(human_bytes "$grow")" "target = min(cap, 2 x current); $formula" \
                "More than 1% of page reads go to disk and there is RAM headroom. Grow in one step (online: SET GLOBAL innodb_buffer_pool_size) and check the miss rate again.$scan_note"
        else
            suggest innodb_buffer_pool_size CHANGE "$conf" "$(human_bytes "$bp")" "add ~$(human_bytes "$add_ram") RAM, then $(human_bytes "$want")" "want = 1.5 x current (rounded to $(human_bytes "$unit")); RAM to add = want - cap" \
                "More than 1% of page reads go to disk, but the host has no memory left for a larger pool. For a 50% larger pool ($(human_bytes "$want")) the server needs about $(human_bytes "$add_ram") more RAM, or less memory used elsewhere (per-connection buffers, other processes).$scan_note"
        fi
    elif is "$bp > $cap * 1.05" && is "$MEM_RSS > $MEM_BUDGET"; then
        local reads_say="Reads are served from memory (miss rate $(pct "$miss_win" 1)), so the pool is not too small."
        is "$miss_win > 0.001" && reads_say="Some reads miss the pool ($(pct "$miss_win" 1)), but there is no memory to grow it."
        suggest innodb_buffer_pool_size REVIEW Medium "$(human_bytes "$bp")" "keep; fix memory use" "$formula" \
            "$reads_say mysqld RSS ($(human_bytes "$MEM_RSS")) is at its budget ($(human_bytes "$MEM_BUDGET"), which keeps a $(human_bytes "$MEM_OS_RESERVE") OS reserve), but the host is not swapping and $(human_bytes "$avail_min") stayed available. First find why mysqld uses $(human_bytes "$(calc_int "$MEM_RSS - $bp")") beyond the buffer pool (see Other findings); reduce the pool to $(human_bytes "$cap") only if memory keeps growing."
    elif is "$miss_win > 0.001 || $wait_free > 0"; then
        if is "$cap > $bp * 1.10" && [[ $MEM_SWAPPING -eq 0 ]]; then
            suggest innodb_buffer_pool_size REVIEW Low "$(human_bytes "$bp")" "increase to $(human_bytes "$grow")" "target = min(cap, 2 x current); $formula" \
                "Between 0.1% and 1% of page reads go to disk$(is "$wait_free > 0" && echo ', and threads waited for free pages'): a larger pool would help somewhat, and there is RAM headroom.$scan_note"
        else
            suggest innodb_buffer_pool_size OK Medium "$(human_bytes "$bp")" "keep" "miss rate 0.1%-1%, no room to grow" \
                "A larger pool would help a little, but the host is swapping or has no RAM headroom, so keep the current size.$scan_note"
        fi
    elif ((warm)) && is "$total > 0 && $free_min / $total > 0.20 && $fits < $bp * 0.8"; then
        local conf=Low; is "$MEM_RSS > $MEM_BUDGET * 0.95 || $avail_min < $MEM_TOTAL * 0.10" && conf=Medium
        suggest innodb_buffer_pool_size REVIEW "$conf" "$(human_bytes "$bp")" "can reduce to $(human_bytes "$fits")" "fits = data pages ($(human_num "$data_max")) x page size x 1.2, rounded up to $(human_bytes "$unit")" \
            "After a day of uptime more than 20% of the pool is still empty and reads are served from memory: the data actually used fits in about $(human_bytes "$fits"). Reduce only if the memory is needed elsewhere; the free space also absorbs growth."
    else
        suggest innodb_buffer_pool_size OK High "$(human_bytes "$bp")" "keep" "miss rate < 0.1% (or under 10 disk reads/s)" \
            "Reads are served from memory: no reason to grow it.$( ((scans)) && echo ' Table scans still read many pages once; that is a query problem, not a pool-size one.')"
    fi
}

rule_max_connections() {
    RULE_GROUP=memory
    local mc muc refused tc_max new
    mc=$(vnum max_connections); muc=$(sn Max_used_connections)
    refused=$(sn Connection_errors_max_connections)
    tc_max=$(sn Threads_connected max)

    ev "Max_used_connections: $muc of max_connections $mc$(dflt_note max_connections) ($(pct "$muc" "$mc")); Threads_connected max in window: $tc_max"
    ev "Connection_errors_max_connections since start: $(human_num "$refused") (in window: $(human_num "$(sd Connection_errors_max_connections)"))"
    ((MEM_KNOWN)) && ev "Worst-case memory at max_connections: $(human_bytes "$MEM_WORST") vs budget $(human_bytes "$MEM_BUDGET")"

    local fits_formula="each connection may use up to $(human_bytes "$(calc_int "$MEM_PER_THREAD + $MEM_TMP_PER_THREAD")"); room = (budget - global buffers - TempTable) / per-connection"
    local room
    room=$(calc_int "($MEM_BUDGET - $MEM_GLOBAL - $MEM_ONDEMAND) / ($MEM_PER_THREAD + $MEM_TMP_PER_THREAD + 1)")

    if is "$refused > 0"; then
        new=$(round_up "$(calc "$mc * 1.5")" 50)
        ((MEM_KNOWN)) && is "$new > $room && $room > $mc" && new=$(round_down "$room" 50)
        suggest max_connections CHANGE Medium "$mc" "$new" "new = max_connections x 1.5, limited by memory ($fits_formula)" \
            "Connections were refused because the limit was reached. Raise the limit, but also check why the application opens so many connections (pooling, leaks, slow queries piling up)."
    elif is "$muc >= $mc * 0.85"; then
        new=$(round_up "$(calc "$muc * 1.3")" 50)
        suggest max_connections REVIEW Medium "$mc" "$new" "new = Max_used_connections x 1.3" \
            "Peak usage reached 85% of the limit. Raise it before connections get refused."
    elif ((MEM_KNOWN)) && is "$muc < $mc * 0.25 && $MEM_WORST > $MEM_BUDGET"; then
        new=$(round_up "$(max2 "$(calc "$muc * 2")" 100)" 50)
        suggest max_connections REVIEW Low "$mc" "$new" "new = max(Max_used_connections x 2, 100)" \
            "Peak usage is below 25% of the limit and the worst case does not fit in RAM. Lowering it bounds the worst-case memory; only do it if the peak seen since start is representative."
    else
        suggest max_connections OK High "$mc" "keep" "peak < 85% of the limit, no refused connections" "Enough headroom."
    fi
}
