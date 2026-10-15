# Install

pt-stalk-suggest is one bash script. It needs bash 4.2 or newer, awk (gawk or
mawk) and GNU coreutils, which every Linux distribution has. It is tested on
current Ubuntu and on CentOS 7. Percona Toolkit and a MySQL connection are not
needed.

## Latest release

```bash
curl -fLO https://github.com/yunushaikh/pt-stalk-suggest/releases/latest/download/pt-stalk-suggest
chmod +x pt-stalk-suggest
./pt-stalk-suggest --version
```

## Verify the download

```bash
curl -fLO https://github.com/yunushaikh/pt-stalk-suggest/releases/latest/download/SHA256SUMS
sha256sum -c SHA256SUMS
```

## A specific version

```bash
curl -fLO https://github.com/yunushaikh/pt-stalk-suggest/releases/download/v0.1.0/pt-stalk-suggest
```

All versions: https://github.com/yunushaikh/pt-stalk-suggest/releases

## macOS

Not tested. macOS ships bash 3.2, which is too old; with Homebrew's bash
(`brew install bash coreutils`) it may work, but this has not been verified.

## From source

See [BUILD.md](BUILD.md).
