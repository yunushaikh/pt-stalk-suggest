# shellcheck shell=bash
# Compiled-in defaults per release series, read from the Percona Server source
# (5.7.44-48, 8.0.46-37, 8.4.11-11). Shown next to current values so a reader
# can tell a deliberate setting from a default. Sources, relative to the tree:
#   5.7  storage/innobase/handler/ha_innodb.cc, sql/sys_vars.cc, sql/sql_const.h
#   8.0  same files plus storage/innobase/include/log0constants.h
#   8.4  same as 8.0
# "auto" means the server computes it at startup (see dflt_auto below).

declare -gA DEFAULTS_57=(
    [innodb_buffer_pool_size]=128M        # srv0srv.cc:299
    [innodb_log_file_size]=48M            # ha_innodb.cc:22405
    [innodb_log_files_in_group]=2         # ha_innodb.cc:22410
    [innodb_log_buffer_size]=16M          # ha_innodb.cc:22400 (read-only)
    [innodb_io_capacity]=200              # ha_innodb.cc:21753
    [innodb_io_capacity_max]=2000         # ha_innodb.cc:4613  max(2 x io_capacity, 2000)
    [innodb_lru_scan_depth]=1024          # ha_innodb.cc:22266
    [innodb_page_cleaners]=4              # ha_innodb.cc:21936 (capped to BP instances)
    [innodb_max_dirty_pages_pct]=75       # ha_innodb.cc:21941
    [table_open_cache]=2000               # sql_const.h:125
    [table_definition_cache]=auto         # mysqld.cc:6061
    [thread_cache_size]=auto              # mysqld.cc:3189
    [max_connections]=151                 # sql_const.h:132
    [tmp_table_size]=16M                  # sys_vars.cc:4697
    [max_heap_table_size]=16M             # sys_vars.cc:2544
    [sort_buffer_size]=256K               # sys_vars.cc:3962
    [binlog_cache_size]=32K               # sys_vars.cc:758
    [key_buffer_size]=8M                  # my_global.h:367
    [query_cache_size]=1M                 # sys_vars.cc:3587
    [innodb_open_files]=auto              # ha_innodb.cc:4706
    [max_prepared_stmt_count]=16382       # sys_vars.cc:2629
    [innodb_thread_concurrency]=0         # ha_innodb.cc:22450
)
declare -gA DEFAULTS_80=(
    [innodb_buffer_pool_size]=128M        # srv0srv.cc:443
    [innodb_redo_log_capacity]=100M       # ha_innodb.cc:23673
    [innodb_log_buffer_size]=16M          # log0constants.h:485
    [innodb_io_capacity]=200              # ha_innodb.cc:23010
    [innodb_io_capacity_max]=2000         # ha_innodb.cc:5294  max(2 x io_capacity, 2000)
    [innodb_lru_scan_depth]=1024          # ha_innodb.cc:23518
    [innodb_page_cleaners]=4              # ha_innodb.cc:23147 (capped to BP instances)
    [innodb_max_dirty_pages_pct]=90       # ha_innodb.cc:23152
    [table_open_cache]=4000               # sys_vars.h:103
    [table_definition_cache]=auto         # mysqld.cc:9336
    [thread_cache_size]=auto              # mysqld.cc:5341
    [max_connections]=151                 # sys_vars.h:110
    [tmp_table_size]=16M                  # sys_vars.cc:5644
    [temptable_max_ram]=1G                # sys_vars.cc:5714
    [sort_buffer_size]=256K               # sys_vars.cc:5073
    [binlog_cache_size]=32K               # sys_vars.cc:1201
    [key_buffer_size]=8M                  # keycache.h:62
    [innodb_open_files]=auto              # ha_innodb.cc:5335
    [max_prepared_stmt_count]=16382       # sys_vars.cc:3225
    [innodb_thread_concurrency]=0         # ha_innodb.cc:23888
)
declare -gA DEFAULTS_84=(
    [innodb_buffer_pool_size]=128M        # srv0srv.cc:452
    [innodb_redo_log_capacity]=100M       # ha_innodb.cc:23840
    [innodb_log_buffer_size]=64M          # log0constants.h:485
    [innodb_io_capacity]=10000            # ha_innodb.cc:23172
    [innodb_io_capacity_max]=20000        # ha_innodb.cc:5193  2 x io_capacity
    [innodb_lru_scan_depth]=1024          # ha_innodb.cc:23676
    [innodb_page_cleaners]=auto           # ha_innodb.cc:5387  = buffer pool instances
    [innodb_max_dirty_pages_pct]=90       # ha_innodb.cc:23324
    [table_open_cache]=4000               # sys_vars.h:105
    [table_definition_cache]=auto         # mysqld.cc:11015
    [thread_cache_size]=auto              # mysqld.cc:6993
    [max_connections]=151                 # sys_vars.h:112
    [tmp_table_size]=16M                  # sys_vars.cc:5455
    [temptable_max_ram]=auto              # sys_vars.cc:5527  clamp(3% RAM, 1G, 4G)
    [sort_buffer_size]=256K               # sys_vars.cc:166
    [binlog_cache_size]=32K               # sys_vars.cc:1263
    [key_buffer_size]=8M                  # keycache.h:62
    [innodb_open_files]=auto              # ha_innodb.cc:5250
    [max_prepared_stmt_count]=16382       # sys_vars.cc:3068
    [innodb_thread_concurrency]=0         # ha_innodb.cc:24054
)

# Values the server derives at startup, for this server's other settings
dflt_auto() {
    local mc toc
    mc=$(vnum max_connections); toc=$(vnum table_open_cache)
    case $1 in
        thread_cache_size)      calc_int "8 + int($mc / 100) > 100 ? 100 : 8 + int($mc / 100)" ;;
        table_definition_cache) calc_int "400 + int($toc / 2) > 2000 ? 2000 : 400 + int($toc / 2)" ;;
        innodb_open_files)      echo "300, or table_open_cache when file-per-table" ;;
        innodb_page_cleaners)   echo "buffer pool instances" ;;
        temptable_max_ram)
            local m; m=$(calc "0.03 * $(num "$(h mem_total)")")
            human_bytes "$(calc_int "$m < 1073741824 ? 1073741824 : ($m > 4294967296 ? 4294967296 : $m)")" ;;
    esac
}

# dflt VAR -> the default for this server's series, "" when unknown
dflt() {
    local d=""
    case $MYSQL_SERIES in
        5.7) d=${DEFAULTS_57[$1]:-} ;;
        8.0) d=${DEFAULTS_80[$1]:-} ;;
        8.[1-9]|9.*) d=${DEFAULTS_84[$1]:-} ;;
    esac
    [[ $d == auto ]] && d="$(dflt_auto "$1")"
    printf '%s' "$d"
}

# "(default 16M)" suffix for evidence lines; empty when unknown
dflt_note() {
    local d; d=$(dflt "$1")
    [[ -n $d ]] && printf ' (default for %s: %s)' "$MYSQL_SERIES" "$d"
}
