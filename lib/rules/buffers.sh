# shellcheck shell=bash
# Per-session buffers and caches: temporary tables, sort buffer, binlog cache,
# key buffer (MyISAM), query cache (5.7 only).

rule_tmp_tables() {
    RULE_GROUP=buffers
    local disk tmp ratio ratio_life disk_rate engine limit cur new param
    disk=$(sd Created_tmp_disk_tables); tmp=$(sd Created_tmp_tables)
    ratio=$(calc "$tmp > 0 ? $disk / $tmp : 0")
    ratio_life=$(calc "$(sn Created_tmp_tables) > 0 ? $(sn Created_tmp_disk_tables) / $(sn Created_tmp_tables) : 0")
    disk_rate=$(sn Created_tmp_disk_tables win)
    engine=${VARS[internal_tmp_mem_storage_engine]:-MEMORY}
    ver_lt 8.0.0 && engine=MEMORY

    ev "Created_tmp_disk_tables: $(human_num "$disk_rate")/s in window = $(pct "$ratio" 1) of $(human_num "$(sn Created_tmp_tables win)") tmp tables/s; $(pct "$ratio_life" 1) since start"

    if [[ $engine == TempTable ]]; then
        cur=$(vnum tmp_table_size)
        ev "Engine TempTable: tmp_table_size $(human_bytes "$cur")$(dflt_note tmp_table_size) per table, temptable_max_ram $(human_bytes "$(vnum temptable_max_ram)")$(dflt_note temptable_max_ram) shared"
        if [[ $(vnum temptable_use_mmap) -eq 1 ]]; then
            ev "temptable_use_mmap = ON: tables that outgrow temptable_max_ram move to mmap files, which Created_tmp_disk_tables does NOT count (sql_tmp_table.cc); disk spills are under-reported"
        else
            ev "temptable_use_mmap = OFF: tables over the RAM limit become InnoDB tables and are counted in Created_tmp_disk_tables"
        fi
        param="tmp_table_size"
        limit=$cur
    else
        limit=$(min2 "$(vnum tmp_table_size)" "$(vnum max_heap_table_size)")
        ev "Engine MEMORY: limit = min(tmp_table_size $(human_bytes "$(vnum tmp_table_size)"), max_heap_table_size $(human_bytes "$(vnum max_heap_table_size)")) = $(human_bytes "$limit")"
        param="tmp_table_size = max_heap_table_size"
        cur=$limit
    fi
    new=$(min2 "$(calc_int "$limit * 2")" $((256 * MiB)))
    is "$new < $limit" && new=$limit

    local why="More than 25% of temporary tables go to disk. A larger in-memory limit helps only when they spill because of size; "
    if [[ $engine == MEMORY ]]; then
        why+="in 5.7 any TEXT/BLOB column forces a disk table regardless of size. Check the queries (slow log, Created_tmp_disk_tables per digest in performance_schema) before raising it."
    else
        why+="TempTable also spills when temptable_max_ram (shared) runs out; check memory/temptable/% in performance_schema.memory_summary_global_by_event_name."
    fi
    if is "$ratio > 0.25 && $disk_rate >= 1"; then
        if is "$limit >= 256 * $MiB"; then
            suggest "$param" REVIEW Medium "$(human_bytes "$cur")" "keep" "already >= 256M" \
                "Disk temp tables are frequent although the limit is already large: fix the queries (indexes for GROUP BY / ORDER BY, avoid wide DISTINCT/UNION)."
        else
            suggest "$param" REVIEW Medium "$(human_bytes "$cur")" "$(human_bytes "$new")" "new = 2 x current limit, at most 256M (it is per temporary table)" "$why"
        fi
    else
        suggest "$param" OK High "$(human_bytes "$cur")" "keep" "disk tmp tables < 25% or < 1/s" "Fine."
    fi
}

rule_sort_buffer() {
    RULE_GROUP=buffers
    local cur merges sorts
    cur=$(vnum sort_buffer_size)
    merges=$(sn Sort_merge_passes win); sorts=$(calc "$(sn Sort_range win) + $(sn Sort_scan win)")
    ev "Sort_merge_passes $(human_num "$merges")/s vs sorts $(human_num "$sorts")/s in window; $(human_num "$(sn Sort_merge_passes life)")/s since start"
    if is "$cur > 4 * $MiB"; then
        suggest sort_buffer_size REVIEW Medium "$(human_bytes "$cur")" "256K-2M" "keep global <= 2M; raise per session for the queries that need it" \
            "A large global sort buffer is allocated in full by every sorting session, so it costs memory under concurrency and can make small sorts slower."
    elif is "$merges >= 1"; then
        suggest sort_buffer_size REVIEW Low "$(human_bytes "$cur")" "$(human_bytes "$(min2 "$(calc_int "$cur * 2")" $((2 * MiB)))")" "new = 2 x current, at most 2M globally" \
            "Sorts do not fit in the buffer and merge through temporary files. Prefer SET SESSION sort_buffer_size for the reporting queries that need it, or an index that avoids the sort."
    else
        suggest sort_buffer_size OK High "$(human_bytes "$cur")" "keep" "Sort_merge_passes < 1/s" "Sorts fit in memory."
    fi
}

rule_binlog_cache() {
    RULE_GROUP=buffers
    if [[ $(vnum log_bin) -ne 1 ]]; then not_applicable binlog_cache_size "log_bin=OFF"; return; fi
    local cur use disk ratio new
    cur=$(vnum binlog_cache_size)
    use=$(sd Binlog_cache_use); disk=$(sd Binlog_cache_disk_use)
    ratio=$(calc "$use > 0 ? $disk / $use : 0")
    ev "Binlog_cache_disk_use / Binlog_cache_use: $(pct "$ratio" 1) in window ($(human_num "$(sn Binlog_cache_use win)") trx/s), $(pct "$(sn Binlog_cache_disk_use)" "$(sn Binlog_cache_use)") since start"
    ev "Statement cache spills: $(pct "$(sn Binlog_stmt_cache_disk_use)" "$(sn Binlog_stmt_cache_use)") since start"
    new=$(min2 "$(pow2_up "$(calc_int "$cur * 4")")" $((4 * MiB)))
    if is "$ratio > 0.10 && $use > 0"; then
        if is "$cur >= 4 * $MiB"; then
            suggest binlog_cache_size REVIEW Medium "$(human_bytes "$cur")" "keep" "already >= 4M" \
                "Transactions are larger than a 4M cache: they are big transactions; consider splitting them instead of growing a per-connection buffer."
        else
            suggest binlog_cache_size CHANGE Medium "$(human_bytes "$cur")" "$(human_bytes "$new")" "new = 4 x current (power of 2), at most 4M" \
                "More than 10% of transactions spill their binlog events to a temporary file. The cache is allocated per connection only when it writes, so a few MB is affordable. Dynamic."
        fi
    else
        suggest binlog_cache_size OK High "$(human_bytes "$cur")" "keep" "spill ratio <= 10%" "Fine."
    fi
}

rule_key_buffer() {
    RULE_GROUP=buffers
    local cur req life miss unused bs
    cur=$(vnum key_buffer_size); req=$(sn Key_read_requests win); life=$(sn Key_read_requests life)
    miss=$(calc "$(sn Key_read_requests) > 0 ? $(sn Key_reads) / $(sn Key_read_requests) : 0")
    unused=$(sn Key_blocks_unused); bs=$(vnum key_cache_block_size)
    ev "Key_read_requests $(human_num "$req")/s in window, $(human_num "$life")/s since start; miss rate $(pct "$miss" 1)"
    ev "Key_blocks_unused $unused x $(human_bytes "$bs") = $(human_bytes "$(calc_int "$unused * $bs")") free"
    if is "$life < 1 && $req < 1"; then
        if is "$cur > 64 * $MiB"; then
            suggest key_buffer_size REVIEW Low "$(human_bytes "$cur")" "16M" "Key_read_requests ~ 0/s: MyISAM indexes unused, 8-16M is enough" \
                "Almost no MyISAM index reads: the memory is better given to the InnoDB buffer pool."
        else
            suggest key_buffer_size OK High "$(human_bytes "$cur")" "keep" "MyISAM unused, buffer small" "Fine."
        fi
    elif is "$miss > 0.01 && $unused * $bs < $cur * 0.05"; then
        suggest key_buffer_size CHANGE Medium "$(human_bytes "$cur")" "$(human_bytes "$(calc_int "$cur * 2")")" "new = 2 x current (check the memory budget)" \
            "MyISAM index reads miss the key cache more than 1% of the time and the cache is full. Better long-term: convert the tables to InnoDB."
    else
        suggest key_buffer_size OK High "$(human_bytes "$cur")" "keep" "miss rate <= 1% or free blocks left" "Fine."
    fi
}

rule_query_cache() {
    RULE_GROUP=buffers
    if ! has_var query_cache_type; then not_applicable query_cache "removed in 8.0"; return; fi
    local type size hits sel prunes ratio
    type=${VARS[query_cache_type]}; size=$(vnum query_cache_size)
    hits=$(sn Qcache_hits win); sel=$(sn Com_select win); prunes=$(sn Qcache_lowmem_prunes win)
    ratio=$(calc "($hits + $sel) > 0 ? $hits / ($hits + $sel) : 0")
    ev "query_cache_type = $type, query_cache_size = $(human_bytes "$size")"
    if [[ $type == OFF || $type == 0 ]]; then
        if is "$size > 0"; then
            ev "5.7 allocates query_cache_size at startup even when query_cache_type = OFF (sql_cache.cc / mysqld.cc:4081)"
            suggest query_cache_size REVIEW Medium "$(human_bytes "$size")" "0" "type OFF -> size 0" "The cache is off but its memory is still allocated. Set query_cache_size = 0 too (needs a restart to release it if set at startup)."
        else
            suggest query_cache_type OK High "OFF" "keep" "disabled" "Disabled, as recommended."
        fi
        return
    fi
    ev "Hit rate in window $(pct "$ratio" 1) (Qcache_hits $(human_num "$hits")/s vs Com_select $(human_num "$sel")/s); lowmem prunes $(human_num "$prunes")/s; free memory $(human_bytes "$(sn Qcache_free_memory)")"
    local conf=Medium
    is "$prunes > 0 || $ratio < 0.5" && conf=High
    suggest "query_cache_type / _size" CHANGE "$conf" "$type / $(human_bytes "$size")" "OFF / 0" "disable" \
        "The query cache is a global mutex: every write invalidates entries and every SELECT checks it, which serialises concurrent sessions. It is removed in 8.0. Disable it and verify the read latency; both can be changed at runtime."
}
