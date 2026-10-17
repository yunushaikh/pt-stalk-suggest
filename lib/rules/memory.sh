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

rule_buffer_pool() {
    RULE_GROUP=memory
    local bp chunk inst unit reads req miss_win miss_life free_min total dirty wait_free cap
    bp=$(vnum innodb_buffer_pool_size)
    chunk=$(vnum innodb_buffer_pool_chunk_size); inst=$(vnum innodb_buffer_pool_instances)
    unit=$(calc_int "$chunk * $inst"); is "$unit > 0" || unit=$((128 * MiB))

    reads=$(sd Innodb_buffer_pool_reads); req=$(sd Innodb_buffer_pool_read_requests)
    miss_win=$(calc "$req > 0 ? $reads / $req : 0")
    miss_life=$(calc "$(sn Innodb_buffer_pool_read_requests) > 0 ? $(sn Innodb_buffer_pool_reads) / $(sn Innodb_buffer_pool_read_requests) : 0")
    total=$(sn Innodb_buffer_pool_pages_total)
    free_min=$(sn Innodb_buffer_pool_pages_free min)
    wait_free=$(sd Innodb_buffer_pool_wait_free)
    cap=$(round_down "$(calc "$MEM_BUDGET - $MEM_OVERHEAD")" "$unit")
    is "$cap < 0" && cap=0

    ev "Miss rate (disk reads / logical reads): $(pct "$miss_win" 1) in window, $(pct "$miss_life" 1) since start"
    ev "Disk reads: $(human_num "$(s Innodb_buffer_pool_reads win)")/s in window (peak $(human_num "$(s Innodb_buffer_pool_reads peak)")/s); logical reads $(human_num "$(s Innodb_buffer_pool_read_requests win)")/s"
    ev "Free pages: min $(human_num "$free_min") of $(human_num "$total") ($(pct "$free_min" "$total")); wait_free events in window: $(human_num "$wait_free")"
    ev "Room for buffer pool: budget $(human_bytes "$MEM_BUDGET") - other mysqld memory $(human_bytes "$MEM_OVERHEAD") ($MEM_OVERHEAD_SRC) = $(human_bytes "$cap")"
    if [[ $MEM_SWAPPING -eq 1 || $(num "$(h swap_used_max)") -gt 0 ]]; then
        ev "Swap: used $(human_bytes "$(h swap_used_max)"), swap-in avg $(h swap_in_avg) KiB/s (max $(h swap_in_max)), swap-out avg $(h swap_out_avg) KiB/s"
    fi
    [[ $(vnum innodb_dedicated_server) -eq 1 ]] && ev "innodb_dedicated_server=ON: the buffer pool is sized automatically at startup"

    if ((!MEM_KNOWN)); then
        suggest innodb_buffer_pool_size INFO Low "$(human_bytes "$bp")" "unknown" "needs RAM from meminfo" \
            "The capture has no meminfo file, so there is no memory budget to size the buffer pool against. The miss-rate evidence above still applies."
        return
    fi
    local formula="cap = (RAM - OS reserve - other processes) - max(mysqld RSS - buffer pool, other global + per-connection x Max_used_connections), rounded down to chunk_size x instances ($(human_bytes "$unit"))"
    local warm=1 uptime; uptime=$(num "$(h uptime)")
    ((uptime < 86400)) && warm=0

    # Ignore miss rates on a trickle of reads: growth needs >= 10 disk reads/s
    local rps; rps=$(sn Innodb_buffer_pool_reads win)
    if is "$rps < 10" && is "$wait_free == 0"; then miss_win=0; fi

    if is "$bp > $cap * 1.05" && { [[ $MEM_SWAPPING -eq 1 ]] || is "$MEM_RSS > $MEM_BUDGET"; }; then
        suggest innodb_buffer_pool_size CHANGE "$([[ $MEM_SWAPPING -eq 1 ]] && echo High || echo Medium)" \
            "$(human_bytes "$bp")" "$(human_bytes "$cap")" "$formula" \
            "The host is short of memory (swapping or mysqld above its budget). Shrink the buffer pool to the cap, or add RAM. Online resize: SET GLOBAL innodb_buffer_pool_size."
    # Disk-read evidence comes before free pages: Percona's LRU manager keeps
    # pages free even while the pool is too small (free pages and thousands of
    # reads/s together), so "free pages > 10%" alone does not prove a fit.
    elif ((!warm)) && is "$miss_win > 0.001 || $wait_free > 0"; then
        suggest innodb_buffer_pool_size REVIEW Low "$(human_bytes "$bp")" "$(human_bytes "$(max2 "$bp" "$cap")")" "$formula" \
            "Disk reads are high, but MySQL started less than a day ago: part of it is the buffer pool warming up. Take another capture after a day of normal load before resizing."
    elif is "$miss_win > 0.01"; then
        if is "$cap > $bp * 1.10" && [[ $MEM_SWAPPING -eq 0 ]]; then
            suggest innodb_buffer_pool_size CHANGE Medium "$(human_bytes "$bp")" "$(human_bytes "$cap")" "$formula" \
                "More than 1% of page reads go to disk and there is RAM headroom. Raise it toward the cap; recheck the miss rate after the change."
        else
            suggest innodb_buffer_pool_size REVIEW Medium "$(human_bytes "$bp")" "no headroom" "$formula" \
                "The working set does not fit in the pool, but there is no RAM to grow it (or the host is already swapping). Options: add RAM, reduce per-connection buffers, or fix the queries that scan large ranges."
        fi
    elif is "$miss_win > 0.001 || $wait_free > 0"; then
        if is "$cap > $bp * 1.10" && [[ $MEM_SWAPPING -eq 0 ]]; then
            suggest innodb_buffer_pool_size REVIEW Low "$(human_bytes "$bp")" "$(human_bytes "$cap")" "$formula" \
                "Between 0.1% and 1% of page reads go to disk$(is "$wait_free > 0" && echo ', and threads waited for free pages'): a larger pool would help somewhat, and there is RAM headroom."
        else
            suggest innodb_buffer_pool_size OK Medium "$(human_bytes "$bp")" "keep" "miss rate 0.1%-1%, no room to grow" \
                "A larger pool would help a little, but the host is swapping or has no RAM headroom, so keep the current size."
        fi
    elif is "$total > 0 && $free_min / $total > 0.10" && ((warm)); then
        suggest innodb_buffer_pool_size OK High "$(human_bytes "$bp")" "keep" "few disk reads and free pages > 10% after warm-up" \
            "Reads are served from memory and more than 10% of the pool stayed free: the working set fits. It could even be reduced if memory is needed elsewhere."
    else
        suggest innodb_buffer_pool_size OK High "$(human_bytes "$bp")" "keep" "miss rate < 0.1% (or no headroom needed)" \
            "Reads are served from memory."
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
