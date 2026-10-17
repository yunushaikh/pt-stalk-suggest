# shellcheck shell=bash
# Caches and limits: thread cache, table caches, open files, prepared statements.

rule_thread_cache() {
    RULE_GROUP=caches
    local cur created conns miss_life tcmin tcmax new
    cur=$(vnum thread_cache_size)
    created=$(sn Threads_created win); conns=$(sn Connections win)
    miss_life=$(calc "$(sn Connections) > 0 ? $(sn Threads_created) / $(sn Connections) : 0")
    tcmin=$(sn Threads_connected min); tcmax=$(sn Threads_connected max)
    ev "Threads_created $(human_num "$created")/s vs Connections $(human_num "$conns")/s in window; since start $(pct "$miss_life" 1) of connections created a thread"
    ev "Threads_connected in window: min $tcmin, max $tcmax; Threads_cached last $(sn Threads_cached); thread_cache_size $cur$(dflt_note thread_cache_size)"
    [[ ${VARS[thread_handling]:-} == pool-of-threads ]] && ev "thread_handling = pool-of-threads: the thread cache matters less"
    new=$(round_up "$(max2 "$(max2 "$(calc_int "$cur * 2")" "$(calc "$tcmax - $tcmin")")" 16)" 8)
    new=$(min2 "$new" "$(max2 "$(vnum max_connections)" 16)")
    local formula="new = max(2 x current, Threads_connected max - min in window, 16), rounded to 8, at most max_connections"
    # pt-stalk itself opens 12-17 connections/s while it collects (measured on
    # idle lab servers, pt-stalk 3.7.1 defaults), so a low rate may be mostly its own
    if is "$created >= 1 && $conns < 25"; then
        ev "pt-stalk itself opens about 12-17 connections/s while collecting (measured on idle servers): at $(human_num "$conns")/s most of these may be pt-stalk's own"
        suggest thread_cache_size REVIEW Low "$cur" "$new" "$formula" \
            "Threads are created for new connections, but the connection rate is low enough to be mostly pt-stalk's own. Check Threads_created against Connections outside a capture before changing it."
    elif is "$created >= 1"; then
        suggest thread_cache_size CHANGE Medium "$cur" "$new" "$formula" \
            "Threads are created more than once per second: each one costs a thread start. Dynamic: SET PERSIST thread_cache_size."
    elif is "$miss_life > 0.10 && $(sn Threads_created life) > 0.1"; then
        suggest thread_cache_size REVIEW Low "$cur" "$new" "$formula" \
            "Since start more than 10% of connections needed a new thread, though not during the capture."
    else
        suggest thread_cache_size OK High "$cur" "keep" "Threads_created < 1/s" "Connections reuse cached threads."
    fi
}

# MySQL shrinks table_open_cache at startup when open_files_limit is too low:
#   table_open_cache = (open_files_limit - 10 - max_connections) / 2
toc_capped_by_ofl() {
    local cur ofl mc
    cur=$(vnum table_open_cache); ofl=$(vnum open_files_limit); mc=$(vnum max_connections)
    # mysqld.cc: max((requested_open_files - 10 - max_connections) / 2, TABLE_OPEN_CACHE_MIN=400)
    is "$ofl > 0 && $cur == ((int(($ofl - 10 - $mc) / 2) > 400) ? int(($ofl - 10 - $mc) / 2) : 400)"
}

rule_table_open_cache() {
    RULE_GROUP=caches
    local cur inst opened peak open_max fill misses hits overflows new
    cur=$(vnum table_open_cache); inst=$(vnum table_open_cache_instances)
    opened=$(sn Opened_tables win); peak=$(sn Opened_tables peak)
    open_max=$(sn Open_tables max); fill=$(calc "$cur > 0 ? $open_max / $cur : 0")
    misses=$(sd Table_open_cache_misses); hits=$(sd Table_open_cache_hits); overflows=$(sn Table_open_cache_overflows win)
    ev "Opened_tables: $(human_num "$opened")/s in window (peak $(human_num "$peak")/s), $(human_num "$(sn Opened_tables life)")/s since start"
    ev "Open_tables: max $open_max of table_open_cache $cur$(dflt_note table_open_cache) ($(pct "$fill" 1)); instances $inst"
    has_stat Table_open_cache_misses && ev "Cache miss rate in window: $(pct "$misses" "$(calc "$misses + $hits")"); overflows $(human_num "$overflows")/s"
    if [[ -n ${HOST[changed_table_open_cache]:-} ]]; then
        local got req; read -r got req <<<"${HOST[changed_table_open_cache]}"
        ev "Error log: \"Changed limits: table_open_cache: $got (requested $req)\": MySQL reduced it at startup because open_files_limit is too low"
    elif toc_capped_by_ofl && [[ $cur != "$(dflt table_open_cache)" ]]; then
        # open_files_limit = 10 + max_connections + 2 x table_open_cache also holds when the
        # limit was computed from an untouched cache, so only flag a non-default cache
        ev "table_open_cache = (open_files_limit $(vnum open_files_limit) - 10 - max_connections $(vnum max_connections)) / 2: probably reduced at startup by a low open_files_limit (look for \"Changed limits: table_open_cache\" in the error log)"
    fi
    new=$(round_up "$(calc "$cur * 2")" 500)
    TOC_SUGGESTED=$cur
    local need; need=$(calc_int "10 + $(vnum max_connections) + 2 * $new")
    local formula="new = 2 x current (rounded to 500), repeat until Opened_tables/s is near 0; requires open_files_limit >= 10 + max_connections + 2 x table_open_cache = $need"
    if is "$opened >= 1 && $fill >= 0.9"; then
        TOC_SUGGESTED=$new
        suggest table_open_cache CHANGE "$(is "$opened >= 10" && echo High || echo Medium)" "$cur" "$new" "$formula" \
            "The cache is full and tables are reopened every second (each open costs a table definition lookup and file handles). Dynamic, but open_files_limit is fixed at startup (LimitNOFILE in systemd)."
    elif is "$opened >= 1 && $overflows >= $opened * 0.5"; then
        # Each session uses instance thread_id % table_open_cache_instances
        # (sql/table_cache.h get_cache), which holds table_open_cache / instances
        # tables, so one busy session can overflow its instance while the cache
        # as a whole is mostly empty.
        TOC_SUGGESTED=$new
        ev "Per instance: $cur / $inst = $(calc_int "$cur / ($inst > 0 ? $inst : 1)") tables; a session always uses instance thread_id % $inst, and most reopens are overflows of one instance"
        suggest table_open_cache CHANGE Medium "$cur" "$new" "$formula" \
            "Tables are evicted from a full instance while the cache as a whole is not full: sessions touch more tables than one instance holds. Raise table_open_cache (dynamic) so table_open_cache / instances covers the tables a busy session uses, or lower table_open_cache_instances (needs a restart)."
    elif is "$opened >= 1"; then
        suggest table_open_cache REVIEW Low "$cur" "keep" "cache not full" \
            "Tables are opened often although the cache is not full. Typical causes: FLUSH TABLES, temporary tables, or per-instance overflows (table_open_cache_instances). Check what opens them."
    else
        suggest table_open_cache OK High "$cur" "keep" "Opened_tables < 1/s" "Open tables are reused."
    fi
}

rule_table_definition_cache() {
    RULE_GROUP=caches
    local cur opened open_max fill new
    cur=$(vnum table_definition_cache)
    opened=$(sn Opened_table_definitions win); open_max=$(sn Open_table_definitions max)
    fill=$(calc "$cur > 0 ? $open_max / $cur : 0")
    ev "Opened_table_definitions: $(human_num "$opened")/s in window, $(human_num "$(sn Opened_table_definitions life)")/s since start"
    ev "Open_table_definitions: max $open_max of $cur ($(pct "$fill" 1))$(dflt_note table_definition_cache)"
    new=$(round_up "$(max2 "$(calc "$cur * 1.5")" "$(calc "$open_max * 1.25")")" 100)
    if is "$opened >= 0.5 && $fill >= 0.9"; then
        suggest table_definition_cache CHANGE Medium "$cur" "$new" "new = max(1.5 x current, 1.25 x Open_table_definitions), rounded to 100" \
            "The definition cache is full and definitions are reloaded continuously. Dynamic: SET PERSIST table_definition_cache."
    else
        suggest table_definition_cache OK High "$cur" "keep" "definitions reloaded < 0.5/s or cache not full" "Fine."
    fi
}

rule_open_files() {
    RULE_GROUP=caches
    local ofl open_max mc need
    ofl=$(vnum open_files_limit); open_max=$(sn Open_files max); mc=$(vnum max_connections)
    need=$(calc_int "10 + $mc + 2 * $(max2 "${TOC_SUGGESTED:-0}" "$(vnum table_open_cache)")")
    ev "Open_files: max $open_max of open_files_limit $ofl ($(pct "$open_max" "$ofl"))"
    ev "Needed for max_connections $mc and table_open_cache ${TOC_SUGGESTED:-$(vnum table_open_cache)}: 10 + $mc + 2 x ${TOC_SUGGESTED:-$(vnum table_open_cache)} = $need"
    local new; new=$(round_up "$(max2 "$need" "$(calc "$open_max * 1.5")")" 1000)
    if is "$ofl < $need" || is "$open_max > $ofl * 0.8"; then
        suggest open_files_limit CHANGE Medium "$ofl" "$new" "new = max(10 + max_connections + 2 x table_open_cache, 1.5 x Open_files), rounded to 1000" \
            "Too low for the table cache (or close to exhausted). Not dynamic: set LimitNOFILE in the systemd unit (or ulimit -n) and open_files_limit, then restart."
    else
        suggest open_files_limit OK High "$ofl" "keep" "limit >= requirement" "Enough file descriptors."
    fi

    local iof inum
    iof=$(vnum innodb_open_files); inum=$(sn Innodb_num_open_files max)
    ev "Innodb_num_open_files: max $inum of innodb_open_files $iof ($(pct "$inum" "$iof"))"
    if is "$iof > 0 && $inum >= $iof * 0.95"; then
        local inew; inew=$(round_up "$(calc "$iof * 2")" 500)
        suggest innodb_open_files REVIEW Low "$iof" "$inew" "new = 2 x current (must stay below open_files_limit)" \
            "InnoDB keeps closing and reopening tablespace files at the limit. Worth raising when there are many file-per-table tablespaces. $(ver_lt 8.0.0 && echo 'Needs a restart in 5.7.' || echo 'Read-only variable; at runtime use SELECT innodb_set_open_files_limit(N).')"
    else
        suggest innodb_open_files OK High "$iof" "keep" "below 95% of the limit" "Fine."
    fi
}

rule_prepared_stmt() {
    RULE_GROUP=caches
    local lim used prep close
    lim=$(vnum max_prepared_stmt_count); used=$(sn Prepared_stmt_count max)
    prep=$(sn Com_stmt_prepare win); close=$(sn Com_stmt_close win)
    ev "Prepared_stmt_count: max $used of $lim ($(pct "$used" "$lim"))"
    ev "Com_stmt_prepare $(human_num "$prep")/s, Com_stmt_close $(human_num "$close")/s in window"
    if is "$lim > 0 && $used >= $lim * 0.8"; then
        suggest max_prepared_stmt_count CHANGE Medium "$lim" "$(round_up "$(calc "$lim * 2")" 1000)" "new = 2 x current" \
            "Close to the limit; when reached, new PREPAREs fail. If the count only grows, the application is leaking statements; raising the limit only delays the failure."
    else
        suggest max_prepared_stmt_count OK High "$lim" "keep" "usage < 80%" "Fine."
    fi
    if is "$prep > 1 && $close < $prep * 0.5"; then
        finding "Statements are prepared $(human_num "$prep")/s but closed only $(human_num "$close")/s: the application may not close prepared statements (they are freed only when the connection ends)."
    fi
}
