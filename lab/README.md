# Lab

Three Percona Server versions in docker with deliberately poor settings (5.7,
8.0) and defaults (8.4), used to produce the test fixtures. Synthetic data only.

```
docker compose -p pt-stalk-suggestion-lab -f lab/docker-compose.yml up -d
bash lab/setup-data.sh            # 300 small tables, a 200k-row table, a write table
bash lab/capture.sh ps57 20       # workload + pt-stalk --no-stalk for 20 s
tests/make-fixture.sh lab/captures/ps57/<prefix> ps57
```

`capture.sh` runs pt-stalk from the host, so it needs Percona Toolkit and the
mysql client installed locally. The password in `.env` is a lab-only value.
