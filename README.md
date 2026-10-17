# pt-stalk-suggest

Suggest MySQL configuration changes from a raw pt-stalk directory.

Point it at the directory a customer uploaded. It reads every capture in it,
turns the per-second status samples into rates (as `pt-mext -r` does), measures
the host (RAM, CPUs, disk, swap, mysqld memory) and prints, for each parameter:
current value, suggested value, the evidence, the formula used and a
confidence level. No connection to MySQL is made.

```
./pt-stalk-suggest /path/to/pt-stalk/dir
./pt-stalk-suggest --all /path/to/pt-stalk/dir          # also show evidence for OK parameters
./pt-stalk-suggest -p 2026_10_13_12_39_26 /path/to/dir  # one capture only
```

Requires bash 4.2+, awk (gawk or mawk) and GNU coreutils (Linux). Percona
Toolkit is not needed to run it.

| Doc | Contents |
|---|---|
| [docs/INSTALL.md](docs/INSTALL.md) | Download the single file, verify it |
| [docs/USAGE.md](docs/USAGE.md) | Options, which pt-stalk files are used, saving a report |
| [docs/FORMULAS.md](docs/FORMULAS.md) | Every formula and threshold, with Percona Server source references |
| [docs/BUILD.md](docs/BUILD.md) | Build from source, tests, releasing |
| [CHANGELOG.md](CHANGELOG.md) | Changes per version |

## Releases

Each release has one file, `pt-stalk-suggest`, with every library inlined,
plus `SHA256SUMS`:

```bash
curl -fLO https://github.com/yunushaikh/pt-stalk-suggest/releases/latest/download/pt-stalk-suggest
chmod +x pt-stalk-suggest
./pt-stalk-suggest /path/to/pt-stalk/dir
```

Check the installed version with `pt-stalk-suggest --version`. The single
file is built by `tools/build.sh`; the tests check that it gives byte-identical
output to the checkout version, with gawk and mawk, and it was run on CentOS 7
(bash 4.2).

## Example

Two triggered captures from the test lab: Percona Server 8.4, up for almost
two days, with pt-stalk firing on `Threads_running > 4` under a write-heavy
workload and the redo log left at its 100M default. Excerpt; the full report
is in [docs/example-output.txt](docs/example-output.txt).

```text
$ pt-stalk-suggest /var/lib/pt-stalk
...
Source
----------------------------------------------------------------------------------------------------
  Directory          /var/lib/pt-stalk
  Captures used      2: 2026_10_17_06_47_56 2026_10_17_06_48_08
  Samples            60 per-second samples, 58 s of window (captures overlap by 17 s)

Server
----------------------------------------------------------------------------------------------------
  Version            Percona Server 8.4.11-11  (rules for 8.4)
  Host               lab-host
  Uptime             1d 21h
  CPUs               22  (busy avg 66.8%, max 84.6%; iowait avg 10.6%)
  RAM                91.5G  (MemAvailable min 70.2G)
  Swap               8G total, 0B used; swap-in avg 0.0 KiB/s; vm.swappiness 60
  Data disk          dm-0 (/)  w/s avg 11357.2, %util avg 74.2 max 85.4
  Threads_running    avg 8.40, max 13

Summary
----------------------------------------------------------------------------------------------------
  Parameter                           Current        Suggested       Status  Conf.
  innodb_redo_log_capacity            100M           1G              CHANGE  High
  table_open_cache                    4000           8000            CHANGE  Medium
  open_files_limit                    8210           17000           CHANGE  Medium
  binlog_cache_size                   32K            128K            CHANGE  Medium
  innodb_io_capacity / _max           10000 / 20000  fix redo first  REVIEW  Low
  sort_buffer_size                    256K           512K            REVIEW  Low
  innodb_buffer_pool_size             256M           keep            OK      High
  max_connections                     200            keep            OK      High
  innodb_log_buffer_size              64M            keep            OK      High
  innodb_lru_scan_depth               1024           keep            OK      High
  innodb_thread_concurrency           0              keep            OK      Medium
  durability (flush_log/sync_binlog)  1 / 1          keep            OK      High
  thread_cache_size                   10             keep            OK      High
  table_definition_cache              2000           keep            OK      High
  innodb_open_files                   4000           keep            OK      High
  max_prepared_stmt_count             16382          keep            OK      High
  tmp_table_size                      16M            keep            OK      High
  key_buffer_size                     8M             keep            OK      High

Details (evidence and formulas)
----------------------------------------------------------------------------------------------------

  [CHANGE] innodb_redo_log_capacity   100M -> 1G   (confidence: High)
    Evidence   Redo written: 75.6M/s in window (peak 98.4M/s), 425.2K/s since start
               Capacity 100M (innodb_redo_log_capacity, default for 8.4: 100M) holds 1.3 s of
               writes at 75.6M/s
               Checkpoint age: max 83.3M of 83.3M = 100.0%; modified age 74.6%
               (Innodb_checkpoint_age, max of every sample)
               Flushing thresholds: aggressive from ~87.0%, sync flush (writes stall) from ~93.0%
               of max checkpoint age
    Formula    target = one hour of writes, at most max(buffer pool size, 2 x current) and 512G:
               checkpoint age reached the aggressive-flushing zone
    Why        InnoDB reached 100.0% of the max checkpoint age: it flushes pages furiously (and
               stalls writes above ~93%) to free redo space. Dynamic since 8.0.30: SET PERSIST
               innodb_redo_log_capacity = 1073741824;

  [CHANGE] table_open_cache   4000 -> 8000   (confidence: Medium)
    Evidence   Opened_tables: 752/s in window (peak 1046/s), 4.02/s since start
               Open_tables: max 1235 of table_open_cache 4000 (default for 8.4: 4000) (30.9%);
               instances 16
               Cache miss rate in window: 7.5%; overflows 752/s
               Per instance: 4000 / 16 = 250 tables; a session always uses instance thread_id % 16,
               and most reopens are overflows of one instance
    Formula    new = 2 x current (rounded to 500), repeat until Opened_tables/s is near 0; requires
               open_files_limit >= 10 + max_connections + 2 x table_open_cache = 16210
    Why        Tables are evicted from a full instance while the cache as a whole is not full:
               sessions touch more tables than one instance holds. Raise table_open_cache (dynamic)
               so table_open_cache / instances covers the tables a busy session uses, or lower
               table_open_cache_instances (needs a restart).

...
```

## What it checks

| Group | Parameters |
|---|---|
| Memory | memory budget, `innodb_buffer_pool_size`, `max_connections` |
| InnoDB | redo log size (`innodb_redo_log_capacity` or `innodb_log_file_size`), `innodb_log_buffer_size`, `innodb_io_capacity` / `_max`, `innodb_lru_scan_depth`, `innodb_thread_concurrency`, durability settings |
| Caches | `thread_cache_size`, `table_open_cache`, `table_definition_cache`, `open_files_limit`, `innodb_open_files`, `max_prepared_stmt_count` |
| Buffers | temp tables (`tmp_table_size`, `max_heap_table_size`), `sort_buffer_size`, `binlog_cache_size`, `key_buffer_size`, query cache (5.7) |
| Findings | joins without indexes, full scans, row lock waits, history list length, swapping, aborted clients, thread pile-ups |

Rules are version-aware for 5.7, 8.0 and 8.4. Every formula, threshold and
default was checked against the Percona Server source of each series; see
[docs/FORMULAS.md](docs/FORMULAS.md) for the formulas and the source lines.

## Reading the output

- **Source / Server**: captures used, version, uptime, CPUs, RAM, swap, data disk.
- **Memory budget**: RAM minus OS reserve and other processes, against what
  mysqld is configured to use (expected and worst case) and actually uses (RSS).
- **Summary**: one line per parameter, sorted CHANGE, REVIEW, INFO, OK.
- **Details**: evidence (counters, rates, defaults for the version), the
  formula, and why.
- **Other findings**: problems that configuration does not fix.
- **Caveats**: limits of the data (short uptime, short window, restarts,
  container memory limits).

| Status | Meaning |
|---|---|
| CHANGE | the evidence supports changing it |
| REVIEW | worth a look; judgement or more data needed |
| INFO | informational, no automatic suggestion |
| OK | no change |

Rates are shown three ways: **in window** (average over the capture),
**peak** (highest one-second rate) and **since start** (counter / Uptime).
pt-stalk usually captures an incident, so compare the window with the
since-start figures before changing anything.

## Limits

- pt-stalk does not record cgroup memory limits: inside a container or pod,
  RAM is the host's. Kubernetes support is planned.
- Disk type (SSD/HDD) is unknown; io_capacity suggestions rely on the observed
  flush rate and device utilisation.
- PXC / Galera rules are not included yet.

## Tests

```
tests/run-tests.sh            # unit tests, golden output of 3 fixtures, privacy check
tests/run-tests.sh --update   # accept new output after an intended rule change
```

Fixtures in `tests/fixtures/` are captures from the synthetic lab in `lab/`
(Percona Server 5.7, 8.0 and 8.4 in docker), scrubbed by
`tests/make-fixture.sh`. **Never build fixtures from customer data.** The
privacy test fails on case numbers and on any word listed in
`~/.config/pt-stalk-suggest/denylist`, a local file kept outside the repository.

## Layout

```
pt-stalk-suggest        entry point: options, rule order, report
lib/common.sh           math (awk), formatting, data accessors
lib/collect.sh          capture discovery, mysqladmin parser, host and InnoDB status parsing
lib/defaults.sh         compiled-in defaults per series, with source lines
lib/report.sh           suggestion records and terminal rendering
lib/rules/*.sh          one function per parameter
docs/FORMULAS.md        formulas, thresholds and source references
tools/build.sh          builds the single-file dist/pt-stalk-suggest
lab/                    docker compose lab used to generate fixtures
tests/                  test runner, fixture builder, fixtures, expected output
```
