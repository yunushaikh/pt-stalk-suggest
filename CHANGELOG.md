# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.1] - 2026-10-24

### Changed

- **Redo log evidence shows both rates:** how long the capacity lasts at the since-start write rate and at the capture's rate, and which one the sizing used. A capture taken while writes were blocked (by row locks, say) no longer looks like a quiet server. Durations under 10 minutes keep a decimal; long ones are shown in days.

## [0.2.0] - 2026-10-24

### Added

- **Disk and I/O section:** per-device iostat with the datadir device marked (LVM volumes mapped through `lsblk-all` when a collection script saved it), iowait, vmstat blocked processes and run queue, InnoDB read/write/flush/redo/fsync rates, and a verdict. When the CPUs are saturated it explains that iowait reads near 0 even if queries wait for disk. When `pt-summary.out` is present, its time is compared with the capture's.
- **Sessions and queries section** (processlist): what sessions were doing, explained in plain words; table-level lock waits; long-running statements (`--long-query`, default 10 s); the same statement from many sessions (jobs, batch work); busiest tables; clients, with a note when connections come through MySQL Router.
- **Transactions and locks section** (INNODB_TRX, InnoDB status, metadata locks, lock-waits): oldest transactions; statements that lock far more rows than they change, with the WHERE columns to index; transactions left open; what waiters wait for (table, index, lock type, explained); metadata lock holders and waiters; who blocks whom; latest deadlock relative to the capture; latch waits; lock waits that reach `innodb_lock_wait_timeout`.
- **Buffer pool sizing says what to do:** reduce, keep, increase, or add RAM and then increase (with the RAM needed for a 50% larger pool). Evidence adds the pool's contents (data, free, pages taken by row locks and the adaptive hash index), LRU churn (pages re-used vs read once), the data disk's read latency and pt-mysql-summary's own sample when present; misses caused by table scans are called out, because an index helps more than a larger pool.
- Each section lists the files it read. The findings most likely to explain an incident are listed first.
- Test fixture `ps84-locks`: a lab capture of scanning UPDATEs, a transaction holding locks, an ALTER TABLE behind an open transaction and a deadlock.

### Fixed

- **Wrong data disk for LVM datadirs:** a `/dev/mapper/...` datadir fell back to the busiest device (often the root disk). With `lsblk-all` it is now mapped to its `dm-N` device; without it, the report says the mapping is unknown.
- **Server and host clocks:** transaction and deadlock times are in the MySQL server's time zone, pt-stalk's samples in the host's. Times are now converted, so ages are right when the two differ.
- **Overlapping transaction samples:** with millions of row locks pt-stalk's transactions dump (it includes every `data_locks` row) takes longer than a second and samples overlap; transactions are now counted once per sample, and a caveat explains the dump's cost.
- **Redo log CHANGE without pressure:** without checkpoint-age pressure in the capture the suggestion is now REVIEW, and the formula shows the arithmetic.
- **Buffer pool shrink on a thin margin:** shrinking needs swapping, RSS more than 5% over budget, or MemAvailable under 5% of RAM; otherwise REVIEW, pointing at memory mysqld uses beyond its settings.
- Row lock wait averages are shown in seconds; statement shapes handle doubled quotes (`'it''s'`); mysql client probes (`select @@version_comment`, `select $$`) are not counted as application work.
- **Captures of different servers were merged:** a directory with pt-stalk output from two MySQL servers was combined into one report. Captures are now grouped by `server_uuid` (else hostname:port); only the newest capture's server is analysed and the others are listed in the caveats.
- **Buffer pool reported "the working set fits"** while thousands of pages per second were read from disk. Percona's LRU manager keeps pages free even when the pool is too small, so the disk-read evidence is now checked before free pages.
- **Query cache with a high hit rate** is now REVIEW ("test first") instead of CHANGE. It is CHANGE High when the hit rate is under 50%, entries are pruned for lack of memory, or the processlist shows sessions in "Waiting for query cache lock".
- **thread_cache_size on quiet servers:** pt-stalk itself opens about 12–17 connections/s while collecting (measured on idle servers). Below 25 connections/s the suggestion is REVIEW and says so.
- The LRU advice mentions innodb_page_cleaners only when it differs from the buffer pool instance count.

## [0.1.1] - 2026-10-17

### Added

- **Example report in the README**, with the full sample in [docs/example-output.txt](docs/example-output.txt). A test keeps the sample identical to real output.

- **Six more test fixtures** taken after almost two days of uptime: an idle capture and a triggered pair (`Threads_running > 4`) for each of 5.7, 8.0 and 8.4. Lab `capture.sh` gained `idle` and `stalk` modes, and `make-fixture.sh` packs every capture in a directory.
- **Overlapping captures are reported** ("captures overlap by 17 s"). This happens when pt-stalk's `--sleep` is shorter than `--run-time`.

### Fixed

- **False redo pressure on idle servers:** with no dirty pages InnoDB prints the current LSN as "Modified age" (`buf_pool_get_oldest_modification_lwm()` returns 0). Values above the max checkpoint age are now ignored.
- **Buffer pool growth suggested on a trickle of reads:** a miss rate now counts only with at least 10 disk reads/s (or free-page waits).
- **Redo capacity evidence:** short times now show in seconds ("holds 1.7 s of writes", not "0 minutes"), and the duplicated size in brackets is gone.
- **innodb_max_dirty_pages_pct** is shown as `90`, not `90.000000`.

### Changed

- CI and release workflows use `actions/checkout@v5` and `softprops/action-gh-release@v3`; the previous versions ran on the retired Node.js 20.

## [0.1.0] - 2026-10-15

First public preview.

### Added

- **Reads a raw pt-stalk directory**: every capture under it is combined, and captures taken before a MySQL restart are skipped. No MySQL connection is made and Percona Toolkit is not needed.
- **Per-second rates without pt-mext**: the mysqladmin samples are parsed directly. pt-mext drops the final sample of each file; this parser does not. `--keep-work` still writes a pt-mext style table.
- **Host resources**: CPUs, CPU busy and iowait, RAM, swap use and activity, mysqld RSS, and the datadir disk's IOPS, utilisation and latency.
- **Memory budget**: RAM, OS reserve and other processes, against expected and worst-case use and the actual RSS.
- **Version-aware rules for 5.7, 8.0 and 8.4**:
  - Memory: buffer pool, max_connections.
  - InnoDB: redo log size, log buffer, io_capacity / io_capacity_max, lru_scan_depth, thread_concurrency, durability.
  - Caches: thread cache, table_open_cache (including per-instance overflow), table_definition_cache, open_files_limit, innodb_open_files, max_prepared_stmt_count.
  - Buffers: temp tables (MEMORY and TempTable), sort buffer, binlog cache, key buffer, query cache.
- **Formulas checked against the Percona Server source** of each series (5.7.44-48, 8.0.46-37, 8.4.11-11). Defaults per version are shown in the evidence. See [docs/FORMULAS.md](docs/FORMULAS.md).
- **Findings and caveats**: problems configuration does not fix (index-less joins, full scans, row lock waits, history list length, swapping, aborted clients), and the limits of the data.
- **Single-file build** (`tools/build.sh`): one script with all libraries inlined, tested to give identical output on bash 4.2 and newer, with gawk and with mawk.
- **Tests**: unit tests, golden output of three lab fixtures, standalone-build check, and a privacy check (no case numbers or denylisted names).
