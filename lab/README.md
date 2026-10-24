# Lab

Three Percona Server versions in docker with deliberately poor settings (5.7,
8.0) and defaults (8.4), used to produce the test fixtures. Synthetic data only.

```
docker compose -p pt-stalk-suggestion-lab -f lab/docker-compose.yml up -d
bash lab/setup-data.sh            # 300 small tables, a 200k-row table, a write table
bash lab/capture.sh ps57 20                 # workload + pt-stalk --no-stalk for 20 s
bash lab/capture.sh ps57 30 idle            # no workload: a quiet, healthy server
bash lab/capture.sh ps57 30 stalk           # pt-stalk triggers on Threads_running > 4, twice
tests/make-fixture.sh lab/captures/ps57/<prefix> ps57        # one capture
tests/make-fixture.sh lab/captures/ps57 ps57-stalk           # every capture in the directory

The `*-idle` and `*-stalk` fixtures were taken after the servers had been up
for almost two days, so they show warmed-up counters.
```

`capture.sh` runs pt-stalk from the host, so it needs Percona Toolkit and the
mysql client installed locally. The password in `.env` is a lab-only value.

## Lock scenario (`lab/locks`)

One Percona Server 8.4 container that recreates a lock pile-up for the
`ps84-locks` fixture: UPDATEs by a column with no index (each scans and locks
the table), INSERTs behind their gap locks, a transaction holding locks while
it sleeps, an ALTER TABLE behind an open transaction, and a deadlock.

```
docker compose -p pt-stalk-locks-lab -f lab/locks/docker-compose.yml up -d
bash lab/locks/capture-locks.sh 25
tests/make-fixture.sh lab/locks/captures/locks ps84-locks
```

On 8.4 pt-stalk dumps every `performance_schema.data_locks` row into the
transactions file (about 4 GB for this scenario); `make-fixture.sh` keeps only
the INNODB_TRX and data_lock_waits rows.
