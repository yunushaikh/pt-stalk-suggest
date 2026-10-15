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
