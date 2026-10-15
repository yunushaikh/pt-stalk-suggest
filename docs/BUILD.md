# Build from source

```bash
git clone https://github.com/yunushaikh/pt-stalk-suggest.git
cd pt-stalk-suggest
./pt-stalk-suggest /path/to/pt-stalk/dir     # runs from the checkout, loading lib/
```

## Single file

```bash
tools/build.sh                                 # -> dist/pt-stalk-suggest
VERSION=0.1.0 COMMIT=$(git rev-parse HEAD) tools/build.sh   # stamp a version, as releases do
```

`tools/build.sh` inlines `lib/*.sh` and `lib/rules/*.sh` into one script and
checks its syntax. The test suite builds it and compares its output with the
checkout version byte for byte.

## Tests

```bash
tests/run-tests.sh            # unit, golden output, standalone build, privacy
tests/run-tests.sh --update   # accept new output after an intended rule change
```

CI runs the suite with gawk and with mawk on every push and pull request.

## Releasing

1. Move the `[Unreleased]` notes in `CHANGELOG.md` under a new
   `## [X.Y.Z] - YYYY-MM-DD` heading and set `VERSION=X.Y.Z` in
   `pt-stalk-suggest`.
2. Commit, then tag and push:
   ```bash
   git tag vX.Y.Z
   git push origin main vX.Y.Z
   ```
3. The Release workflow runs the tests, builds `pt-stalk-suggest` stamped
   with the version and commit, writes `SHA256SUMS`, and publishes both as a
   GitHub Release with the CHANGELOG section as notes. If the run fails,
   re-run it from the Actions tab (Release → Run workflow) with the tag.

Versions follow [Semantic Versioning](https://semver.org/): a new rule or
option is a minor version; a fix to a formula or output is a patch.
