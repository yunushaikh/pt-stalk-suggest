# pt-stalk-suggest

Suggest MySQL configuration changes from a raw pt-stalk directory.

It reads every capture in pt-stalk,
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

A capture from the test lab that recreates a common incident on Percona Server
8.4: thirty sessions run `UPDATE ... WHERE event_id = ?` on a table with no
index on `event_id`, so each one scans and locks the whole table; INSERTs wait
behind their gap locks; one transaction keeps its locks while it sleeps; an
`ALTER TABLE` waits behind an open transaction; two sessions deadlock. Excerpt
of the incident sections; the full report, including the configuration
suggestions, is in [docs/example-output.txt](docs/example-output.txt).

```text
$ pt-stalk-suggest /var/lib/pt-stalk
...
Sessions and queries (processlist)
----------------------------------------------------------------------------------------------------
  Samples            25 processlist snapshots (one per second)
  Sessions           up to 50 connected; active statements avg 42.0, max 42 (sleeping, system and pt-stalk sessions left out)

  What the active sessions were doing (sessions per snapshot: avg / max)
    updating                             30.0 / 30    changing rows; long times usually mean waiting
                                                    for row locks
    update                                8.0 / 8     an INSERT is adding rows; long times usually
                                                    mean waiting for locks
    User sleep                            2.0 / 2
    Waiting for table metadata lock       2.0 / 2     waiting to use the table at all: another
                                                    session holds a table-level lock (an ALTER/DDL,
                                                    or a long open transaction that touched the
                                                    table)

  Table-level lock waits seen
    Waiting for table metadata lock: 50 session-snapshots, longest 32s
    Meaning: sessions could not even start using a table because another session held a table-level
    lock on it. Typical causes: an ALTER TABLE or other DDL waiting behind a long transaction,
    FLUSH TABLES WITH READ LOCK from a backup, or LOCK TABLES. Everything that touches that table
    queues behind it.

  Long-running statements (running 10s or longer; one entry per session, at its longest)
       34s  id 18  root@172.23.0.1  db lab  state: User sleep
           select sleep(40)
       33s  id 31  root@172.23.0.1  db lab  state: update
           insert into events (event_id, parent_event_id, status, pad) values
           ('new467430866','new467430866','STARTED','y')
       33s  id 37  root@172.23.0.1  db lab  state: update
           insert into events (event_id, parent_event_id, status, pad) values
           ('new2509310329','new2509310329','STARTED','y')
    ...

  Repeated statements (literals replaced by ?; sessions = distinct connections running it)
    sessions max at once max time  hosts  statement
          30         30      33s      1  update events set status=?, end_time=now(), error_code=?
                                         where event_id=? and parent_event_id=?
           8          8      33s      1  insert into events (event_id, parent_event_id, status,
                                         pad) values (?+)
           2          2      34s      1  select sleep(?+)
           1          1      31s      1  select * from jobs
           1          1      32s      1  alter table jobs add column c30388 int

...
Transactions and locks
----------------------------------------------------------------------------------------------------
  How to read this: InnoDB locks the rows a statement changes, and under REPEATABLE READ also the
  rows (and the gaps between them) it reads to find them, until the transaction commits. A
  statement that has to read a whole table to change one row therefore locks the whole table, and
  everything else that writes to it waits.

  Transactions       up to 40 open at once; up to 38 waiting for a row lock at the same time (2026-10-24 09:05:35)
  Longest lock wait  33s (trx 2607); innodb_lock_wait_timeout = 50s

  Statements that lock far more rows than they change
    trx 2606 (thread 18): 304.1k rows locked, 0 modified, REPEATABLE READ, open 31s
      now running: select sleep(40)
      Meaning: an earlier statement in this transaction took the locks, and the transaction is
      still open while it does something else. It blocks every write that needs those rows until
      the application commits or rolls back. Find what the application does between that write and
      its COMMIT.

  What waiting transactions are waiting for (SHOW ENGINE INNODB STATUS)
  Waiting            up to 38 transactions waiting in one status snapshot; longest wait shown 33s
       60 x  `lab`.`events`  index PRIMARY
             lock_mode X
             = waiting to lock a row and the gap before it (next-key lock), as UPDATE/DELETE do
             under REPEATABLE READ
       16 x  `lab`.`events`  index PRIMARY
             lock_mode X insert intention
             = an INSERT waiting for a gap lock that another statement took while scanning
             (REPEATABLE READ locks the gaps between rows it reads)
    Waits on index PRIMARY: these statements look rows up through the primary key (the table
    itself), so they are not using a secondary index on the columns in their WHERE clause.

  Metadata (table-level) lock waits: 2 session(s) waiting (performance_schema.metadata_locks)
    lab.jobs: waiting requests 1 x EXCLUSIVE, 1 x SHARED_READ
      holds   thread 41       SHARED_READ                  User sleep for 33s: select sleep(40)
      holds   thread 58       SHARED_UPGRADABLE            Waiting for table metadata lock for 32s: alter table jobs add column c30388 int
      waits   thread 60                                    Waiting for table metadata lock for 31s: select * from jobs
    Meaning: a session asked for a table-level lock that conflicts with one another session holds.
    Usually an ALTER TABLE (it needs EXCLUSIVE) waits for an open transaction that read or wrote
    the table (SHARED_READ / SHARED_WRITE) to finish, and every new query on that table then queues
    behind the ALTER. The fix is to end the holding transaction (commit, or kill it) or run DDL
    when no long transactions are open.

  Who blocks whom (pt-stalk lock-waits)
    thread 18 from 172.23.0.1:53338 blocks up to 38 transactions (longest wait 33s)
      now: User sleep for 34s: select sleep(40)
    thread 21 from 172.23.0.1:53348 blocks up to 29 transactions (longest wait 33s)
      now: updating for 33s: update events set status='COMPLETED', end_time=now(), error_code='E0'
           where event_id='ev12939362' and parent_e
    ...
```

## What it checks

| Group | Parameters |
|---|---|
| Memory | memory budget, `innodb_buffer_pool_size`, `max_connections` |
| InnoDB | redo log size (`innodb_redo_log_capacity` or `innodb_log_file_size`), `innodb_log_buffer_size`, `innodb_io_capacity` / `_max`, `innodb_lru_scan_depth`, `innodb_thread_concurrency`, durability settings |
| Caches | `thread_cache_size`, `table_open_cache`, `table_definition_cache`, `open_files_limit`, `innodb_open_files`, `max_prepared_stmt_count` |
| Buffers | temp tables (`tmp_table_size`, `max_heap_table_size`), `sort_buffer_size`, `binlog_cache_size`, `key_buffer_size`, query cache (5.7) |
| Disk and I/O | per-device iostat (IOPS, latency, queue, %util) with the datadir device marked, iowait and blocked processes, run queue, InnoDB read/write/flush/redo/fsync rates, a verdict |
| Sessions and queries | from the processlist: what sessions were doing (explained), table-level lock waits, long-running statements, the same statement from many sessions (jobs), busiest tables, clients |
| Transactions and locks | oldest transactions, statements that lock far more rows than they change (missing index), what waiters wait for, metadata locks, who blocks whom, latest deadlock, latch waits, lock-wait timeouts |
| Findings | the incident's likely causes first, then joins without indexes, full scans, history list length, swapping, aborted clients, thread pile-ups |

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
