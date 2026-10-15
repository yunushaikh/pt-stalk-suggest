# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
