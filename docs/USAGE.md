# Usage

```
pt-stalk-suggest [options] PT_STALK_DIR
```

`PT_STALK_DIR` is the directory pt-stalk wrote to (`--dest`, default
`/var/lib/pt-stalk`) or any directory above it: every `*-mysqladmin` file
found under it is a capture. Captures from before the latest MySQL restart
are skipped, because status counters reset on restart.

| Option | Meaning |
|---|---|
| `-p, --prefix TS` | use only the capture with this prefix, e.g. `2026_10_13_12_39_26` |
| `-a, --all` | also show the evidence for parameters that are OK |
| `-r, --os-reserve SIZE` | memory to keep for the OS (default 10% of RAM, 1G..8G), e.g. `4G` |
| `--color WHEN` | `auto` (default), `always`, `never` |
| `--keep-work DIR` | keep intermediate files, including a pt-mext style table per capture |
| `-v, --verbose` | progress on stderr |
| `-V, --version` | print the version |

The report width follows the terminal; set `COLUMNS=100` for a fixed width,
e.g. when saving the report to a file:

```bash
COLUMNS=100 pt-stalk-suggest --color never /path/to/dir > report.txt
```

## What the capture should contain

The tool reads these pt-stalk files when present; only `mysqladmin` and
`variables` are required:

| File | Used for |
|---|---|
| `mysqladmin` | status counters, per second |
| `variables` | current configuration and version |
| `meminfo`, `vmstat` | RAM, swap use and swap activity |
| `mpstat`, `iostat`, `df` | CPUs, CPU use, data disk activity |
| `ps` | mysqld RSS and other processes' memory |
| `innodbstatus1`, `innodbstatus2` | checkpoint age, history list, semaphores |
| `sysctl`, `log_error` | vm.swappiness, startup limit changes |

A capture taken with `--no-stalk --run-time 30` during normal load, plus one
taken during the problem, gives the most useful comparison.

## Reading the report

See the README sections "Reading the output" and "Limits", and
[FORMULAS.md](FORMULAS.md) for how every suggestion is calculated.
