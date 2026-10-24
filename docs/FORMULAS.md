# Formulas and their sources

How `pt-stalk-suggest` turns pt-stalk data into suggestions, and where each
assumption comes from. Source references point into the Percona Server trees
at the tags the rules were checked against:

| Series | Tag | Commit |
|---|---|---|
| 5.7 | `Percona-Server-5.7.44-48` | `497f936a` |
| 8.0 | `Percona-Server-8.0.46-37` | `39e2b60e` |
| 8.4 | `Percona-Server-8.4.11-11` | `57878ff8` |

Paths are relative to the tree root; `ha_innodb.cc` means
`storage/innobase/handler/ha_innodb.cc`. Line numbers are for those tags.

## 1. Turning samples into rates

pt-stalk runs `mysqladmin extended-status -i1` for the capture window
(`--run-time`, default 30 s), so `*-mysqladmin` holds one status table per
second. For every numeric variable the tool computes:

| Field | Meaning | Formula |
|---|---|---|
| first / last | value at the first / last sample | |
| min / max / avg | over all samples (useful for gauges such as `Threads_running`) | |
| life | average rate since MySQL started | `last / Uptime` |
| win | average rate during the capture | `(last - first) / (Uptime_last - Uptime_first)` |
| peak | highest one-interval rate | `max(delta_i / Uptime_delta_i)` |

This is what `pt-mext -r` shows. The tool parses the file itself because
pt-mext drops the final sample of every file (verified: 29 of 30 samples
printed). A final sample cut short when pt-stalk stops mysqladmin is dropped.
`--keep-work DIR` writes a pt-mext style table per capture (`<prefix>.mext`).

Several captures in one directory are combined: window rates use the summed
deltas over the summed window seconds; `peak` is the highest of all;
`life` comes from the newest capture. Captures taken before a MySQL restart
(start time = capture time - Uptime) are skipped because counters reset.

## 2. Host resources

| What | File | Notes |
|---|---|---|
| CPUs | `iostat`/`mpstat` header `(N CPU)`, else `procstat` | |
| CPU busy / iowait | `mpstat` rows for `all` | columns located from the header, right to left |
| RAM, MemAvailable, swap | `meminfo` | worst sample over all captures |
| swap activity | `vmstat` si/so | first row of each file is the since-boot average and is skipped |
| mysqld RSS, other RSS | `ps` | newest capture |
| data disk | `df` (longest mount prefix of `datadir`) mapped to an `iostat` device | partition `nvme1n1p1` -> `nvme1n1`; falls back to the busiest device |
| server variables | `variables`, first `SHOW GLOBAL VARIABLES` block | |
| checkpoint / history / semaphores | `innodbstatus1`, `innodbstatus2` | worst over all captures |
| startup reductions | `log_error` lines `Changed limits: ...` | `share/messages_to_error_log.txt:474-484` (8.4) |

pt-stalk records neither cgroup limits nor the disk type. Memory suggestions
assume the host's RAM is available to mysqld.

## 3. Memory budget

```
budget        = RAM - OS reserve - RSS of all other processes - unused hugepages
OS reserve    = 10% of RAM, at least 1G, at most 8G      (--os-reserve to override)
global        = innodb_buffer_pool_size + innodb_log_buffer_size + key_buffer_size
                + query_cache_size (5.7)
TempTable     = temptable_max_ram (8.0+, when internal_tmp_mem_storage_engine=TempTable)
per_conn      = sort + join + read + read_rnd buffers + thread_stack + 2 x net_buffer_length
                + binlog_cache_size (when log_bin=ON)
per_conn_tmp  = min(tmp_table_size, max_heap_table_size)   (5.7 / MEMORY engine)
expected      = global + per_conn x Max_used_connections
worst         = global + TempTable + (per_conn + per_conn_tmp) x max_connections
overhead      = max(mysqld RSS - buffer pool, global - buffer pool + per_conn x Max_used_connections)
```

Source facts behind it:
- 5.7 allocates `query_cache_size` at startup even with `query_cache_type=OFF`:
  `init()` only disables the cache (`sql/sql_cache.cc:2612`), then
  `resize(query_cache_size)` runs regardless (`sql/mysqld.cc:4081`).
- Sort buffer: 5.7 allocates `min(rows, sort_buffer_size)` in one block
  (`sql/filesort.cc:400`); 8.0/8.4 grow it from 32K by 1.5x
  (`sql/filesort_utils.cc:321`) but allocate it in full when a merge is needed
  (`:437`). Join buffers grow on demand in 8.0+ (`sql/iterators/hash_join_buffer.cc`).
  So `per_conn` is an upper bound.
- TempTable max RAM: 8.0 default 1G (`sql/sys_vars.cc:5714`); 8.4 default
  `clamp(3% of RAM, 1G, 4G)` (`sql/sys_vars.cc:5527`).

## 4. Rules

Status: **CHANGE** act on it; **REVIEW** judgement call or not enough
evidence; **OK** no change; **INFO** informational. Confidence High / Medium /
Low. When uptime is under one hour every CHANGE/REVIEW confidence drops a step
(warm-up inflates counters).

### innodb_buffer_pool_size
- Signals: miss rate `Innodb_buffer_pool_reads / Innodb_buffer_pool_read_requests`
  (window and lifetime), `Innodb_buffer_pool_pages_free` minimum,
  `Innodb_buffer_pool_wait_free`, swap activity.
- `cap = budget - overhead`, rounded down to `chunk_size x instances`. MySQL
  rounds the size up to that multiple (`include/buf0buf.ic:1410` 5.7,
  `:1114` 8.0, `:1131` 8.4).
- Shrink to `cap` (CHANGE) only under real memory pressure: the host swaps,
  RSS is more than 5% over the budget, or MemAvailable falls below 5% of RAM.
  RSS just over the (heuristic) budget without those is REVIEW, pointing at
  memory mysqld uses beyond its settings.
- Miss rates count only with at least 10 disk reads/s. Grow to `cap` when the
  miss rate exceeds 1% and there is headroom and no swapping; 0.1-1% (or
  free-page waits) is REVIEW. Disk-read evidence is checked before free pages,
  because Percona's LRU manager keeps pages free even when the pool is too
  small. More than 10% free with few reads after a day: OK. Within the first
  day: REVIEW only.

### Redo log size
- Variable: 5.7 and 8.0 < 8.0.30: `innodb_log_file_size x innodb_log_files_in_group`
  (5.7 read-only, total < 512G, `storage/innobase/srv/srv0start.cc:2169`).
  8.0.30+: `innodb_redo_log_capacity`, dynamic, 8M..512G
  (`include/log0constants.h:94,97`); it wins over the legacy pair
  (`ha_innodb.cc:5069` 8.0, `:5005` 8.4).
- Redo pressure = checkpoint age (and modified age) / max checkpoint age.
  Percona exports `Innodb_checkpoint_age` / `Innodb_checkpoint_max_age` every
  second in all three series, so the tool uses the per-second maximum.
  Otherwise it reads SHOW ENGINE INNODB STATUS. Community 5.7 does not print
  the max, so it is computed as in `log_calc_max_ages()`
  (`storage/innobase/log/log0log.cc:829-855`):
  `max = ((capacity - 2048 x files) x 0.9 - (4 x (10 + innodb_thread_concurrency) + 8) x page_size) x 0.9`.
  On the lab 5.7 server this gives 12,878,438 bytes; the server printed 12,878,439.
- What the fractions of "Max checkpoint age" mean:
  - 5.7: async preflush at 7/8, sync preflush at 15/16, async checkpoint at
    31/32 (`log0log.cc:132-139, 829-855`).
  - 8.0/8.4: "Max checkpoint age" = `log_free_check_capacity()`
    (`log/log0log.cc:1160` 8.0, `:1162` 8.4), the point where user threads
    stall. Adaptive flushing ramps to ~87%, sync flushing starts ~93%
    (modified age), aggressive checkpoints ~97%
    (`log/log0files_capacity.cc`, `log/log0chkp.cc:741, 845`).
  - The tool uses 0.87 (aggressive) and 0.93 (sync) for every series.
- Size: `one hour of writes = max(window, lifetime) Innodb_os_log_written/s x 3600`,
  rounded up to 1G.
  - Pressure >= 0.87: CHANGE High, target = one hour, at most
    `max(buffer pool, 2 x current)`.
  - Under an hour held and pressure >= 0.5: CHANGE Medium.
  - Under 20 minutes held but no pressure seen in the capture: REVIEW Medium
    (the log is not limiting this window; check at peak write times).
  - 20-60 minutes without pressure: REVIEW Low.
  - The target is at most about the buffer pool size while there is no
    pressure (8.0's `innodb_dedicated_server` uses <= 0.75 x buffer pool,
    `ha_innodb.cc:5114-5133`); already that large: OK.
  - Otherwise OK.
- `Innodb_os_log_written` counts bytes written minus write-ahead padding
  (`log/log0write.cc:1816` 8.0/8.4; `log0log.cc:1562` 5.7).

### innodb_log_buffer_size
- `Innodb_log_waits` counts only waits for space in the log buffer
  (`log/log0buf.cc:843-847` 8.0/8.4; `log0log.cc:432-445` 5.7), not waits for
  redo capacity.
- Waits during the capture: CHANGE High to `max(2 x current, peak redo/s rounded to a power of 2, floor)`,
  at most 256M; waits only since start: REVIEW Low to `max(2 x current, floor)`.
  Floor 32M (5.7) / 64M (8.0+).
- Defaults 16M (5.7, 8.0), 64M (8.4). Read-only in 5.7, dynamic in 8.0+.

### innodb_io_capacity / innodb_io_capacity_max
- Defaults: 200 / `max(2 x 200, 2000)` in 5.7 and 8.0
  (`ha_innodb.cc:4613` 5.7, `:5294` 8.0); 10000 / `2 x io_capacity` in 8.4
  (`ha_innodb.cc:23172, 5193`).
- Adaptive flushing is capped at io_capacity_max per second
  (`buf/buf0flu.cc:2742` 5.7, `:2649` 8.0, `:2711` 8.4). Sync (redo-pressure)
  flushing is not: 5.7 requests an unlimited batch (`buf0flu.cc:3311`); 8.0/8.4
  flush up to `2 x io_capacity_max` per pass without sleeping
  (`buf0flu.cc:2596, 2638` 8.0). So when the redo log is undersized the tool
  says "fix redo first".
- Pressure (redo > 50% or dirty pages > 90% of `innodb_max_dirty_pages_pct`)
  with flushing at >= 80% of io_capacity: CHANGE to `observed flush rate x 1.25`
  when disk %util peak < 80%, else REVIEW (storage is the limit).

### innodb_lru_scan_depth, innodb_page_cleaners
- `Innodb_buffer_pool_wait_free` counts loops in `buf_LRU_get_free_block()`
  that found no free page (`buf/buf0lru.cc:1562, 1655` 5.7; `:1482, 1587` 8.0;
  `:1485, 1593` 8.4).
- Waits in the window: CHANGE to `min(2 x current, 4096)`.
- `innodb_page_cleaners` is capped to buffer pool instances in every series
  (`srv/srv0start.cc:1982` 5.7, `ha_innodb.cc:5488` 8.0); 8.4 defaults it to
  the instance count (`ha_innodb.cc:5387`).

### innodb_thread_concurrency
- With 0 (the default) InnoDB does not track a queue, so "N queries in queue"
  is always 0 (`ha_innodb.cc:1972` 5.7, `:2035` 8.4).
- CHANGE when the limit is set and queries queue; REVIEW when the average
  `Threads_running` exceeds 2 x CPUs.

### Durability
Shows `innodb_flush_log_at_trx_commit` / `sync_binlog`; INFO only.

### thread_cache_size
- Autosized to `min(8 + max_connections / 100, 100)` when not set
  (`sql/mysqld.cc:3189` 5.7, `:5341` 8.0, `:6993` 8.4).
- `Threads_created` >= 1/s: CHANGE to
  `max(2 x current, Threads_connected max - min, 16)`, rounded to 8.

### table_open_cache, open_files_limit
- At startup MySQL requests
  `max(10 + max_connections + 2 x table_open_cache, 5 x max_connections, open_files_limit or 5000)`
  descriptors. If it gets fewer, it lowers table_open_cache to
  `max((open_files - 10 - max_connections) / 2, 400)` and logs
  `Changed limits: table_open_cache: N (requested M)`
  (`sql/mysqld.cc:5985-6042` 5.7, `:9267-9324` 8.0, `:10941-11004` 8.4).
  `open_files_limit = 10 + max_connections + 2 x table_open_cache` also holds
  when the limit was computed from an untouched cache. So the tool reports a
  reduction as fact only from the error log, and as "probably" only for a
  non-default cache size.
- Each session uses instance `thread_id % table_open_cache_instances`
  (`sql/table_cache.h:168` 5.7, `:216` 8.0, `:218` 8.4), which holds
  `table_open_cache / instances` tables. `Table_open_cache_overflows` counts
  evictions from a full instance (`table_cache.h:330` 5.7, `:387` 8.0, `:381` 8.4).
- `Opened_tables` equals `Table_open_cache_misses` in all lab and field
  captures checked, so internal temporary tables do not inflate it.
- Opened_tables >= 1/s and the cache >= 90% full: CHANGE to `2 x current`.
  Opened_tables >= 1/s, mostly overflows, cache not full: CHANGE (per-instance
  overflow). Otherwise REVIEW.
- open_files_limit must be >= `10 + max_connections + 2 x table_open_cache`
  for the suggested cache.

### table_definition_cache
- Autosized to `min(400 + table_open_cache / 2, 2000)` (`sql/mysqld.cc:6061` 5.7,
  `:9336` 8.0, `:11015` 8.4).
- `Opened_table_definitions` >= 0.5/s and the cache >= 90% full: CHANGE to
  `max(1.5 x current, 1.25 x Open_table_definitions)`.

### innodb_open_files
- Autosized to 300, or table_open_cache with file-per-table, clamped by
  open_files_limit (`ha_innodb.cc:4706` 5.7, `:5335` 8.0, `:5250` 8.4).
  Read-only; 8.0/8.4 can change it at runtime with
  `SELECT innodb_set_open_files_limit(N)`
  (`include/detail/fil/open_files_limit.h`).

### max_prepared_stmt_count
`Prepared_stmt_count` >= 80% of the limit: CHANGE to 2 x. Prepares far above
closes is reported as a probable statement leak.

### Temporary tables
- 5.7: in-memory limit `min(tmp_table_size, max_heap_table_size)`
  (`sql/sql_tmp_table.cc:1432`). Any BLOB/TEXT column or `big_tables` forces a
  disk table regardless of size (`:1084`).
- 8.0/8.4 TempTable: `tmp_table_size` is a per-table limit
  (`storage/temptable/include/temptable/allocator.h`). `Created_tmp_disk_tables`
  is incremented only when the table is not TempTable
  (`sql/sql_tmp_table.cc:2299-2313` 8.0, `:2338` 8.4). A TempTable that spills
  to mmap files is **not** counted. mmap is on by default in 8.0
  (`temptable_use_mmap=ON`) and off in 8.4 (`temptable_max_mmap=0`), where
  overflow goes straight to InnoDB and is counted.
- No status counter records TempTable hitting temptable_max_ram in either series.
- Disk tables > 25% of temp tables and >= 1/s: REVIEW to `2 x limit`, at most 256M.

### sort_buffer_size
`Sort_merge_passes` (once per `merge_buffers()`, `sql/filesort.cc`) >= 1/s:
REVIEW to `2 x current`, at most 2M globally. Over 4M: REVIEW down.

### binlog_cache_size
`Binlog_cache_disk_use / Binlog_cache_use` > 10% (counted once per non-empty
cache flush, `sql/binlog.cc:724` 5.7, `:1079` 8.0, `:1084` 8.4): CHANGE to
`4 x current` (power of 2), at most 4M.

### key_buffer_size
MyISAM unused (`Key_read_requests` < 1/s) and the buffer > 64M: REVIEW down
to 16M. Miss rate > 1% with a full cache: CHANGE to 2 x.

### Query cache (5.7)
Enabled: CHANGE to OFF / 0. OFF with a size > 0: REVIEW, because the memory
is still allocated.

## 5. Incident sections

These sections describe what happened during the capture; they do not change
configuration suggestions, but their findings are listed first.

**Disk and I/O.** iostat's first block in each file is the average since boot
and is skipped. iowait counts only idle CPU time with I/O pending, so on a
saturated CPU it reads near 0 even when queries wait for disk; vmstat `b`
(processes blocked on I/O) and the device's `r_await`, `aqu-sz` and `%util` are
used instead. Verdict: under pressure when %util max >= 90, queue >= 8 or read
latency >= 10 ms; busy from %util 60.

**Sessions and queries.** Sleeping, system, event-scheduler and pt-stalk's own
sessions are left out. Statement shapes replace string and number literals
with `?` and collapse value lists, so the same statement from many sessions
groups together. Table names come from the SQL text (UPDATE, INTO, FROM,
JOIN).

**Transactions and locks.**
- Sample times are the host's local time (the `TS` line); `trx_started`,
  `trx_wait_started` and deadlock times are the server's. The offset comes
  from `time_zone` / `system_time_zone` when unambiguous, else from the newest
  transaction rounded to 15 minutes.
- A statement that locks at least 10,000 rows and at least 100 times the rows
  it modifies is reported as scanning: under REPEATABLE READ InnoDB keeps a
  lock on every row it reads to find the rows to change.
- Waiters come from `TRX HAS BEEN WAITING ... RECORD LOCKS ... index X of table
  Y ... lock_mode ...` in InnoDB status. With no index matching the WHERE
  clause, waits appear on index `PRIMARY`.
- Metadata locks come from `performance_schema.metadata_locks` (LOCK_STATUS
  PENDING = waiting); counts are per snapshot.
- Who blocks whom comes from pt-stalk's lock-waits summary. When pt-stalk could
  not collect it ("Lock collection already running"), the transactions holding
  the most row locks are listed as likely blockers.
- Lock waits that reach `innodb_lock_wait_timeout` fail with ERROR 1205.

## 6. Defaults shown in the evidence

`lib/defaults.sh` holds the compiled-in defaults per series with their
source lines. The evidence prints them as `(default for 8.4: 64M)`, so a
deliberate setting stands out from an untouched default.
