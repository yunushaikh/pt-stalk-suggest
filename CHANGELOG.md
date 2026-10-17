# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

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
