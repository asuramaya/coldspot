# Contributing to coldspot

coldspot governs a privileged daemon and an eBPF core on the machine you're developing on.
Contributions that keep the trust boundary small (the daemon is the only privileged actor,
full stop) are very welcome.

Before changing much, read [docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md). It explains the
control socket's group-gated model and the BPF core's design, which are the decisions most
likely to bite you if you don't know about them.

## Setup

```bash
git clone https://github.com/asuramaya/coldspot
cd coldspot
sudo make install    # daemon + BPF core + coldspot group (needs sudo, see below)
make pill             # the GNOME pill, as yourself, no sudo
coldspot status        # confirm the daemon answers
```

`install.sh` is root-only and never re-invokes itself under `sudo`. It says so plainly if you
forget it, rather than quietly escalating. `make deploy` is the local-iteration loop: it smoke
tests first, then pushes the binaries + rebuilt eBPF object into place and reloads the core in
the one order that makes new programs actually attach.

## The checks

Same ones CI runs:

```bash
make check          # ruff + shellcheck, py_compile, node --check, unit + contract tests
make check-sutra    # the vendored sutra spine still matches canonical, byte for byte
make smoke           # boots a real coldspotd against a fake iface, no root needed
make attack           # fuzzes the control socket adversarially, no root needed
```

`make check` already depends on `check-sutra`, so running it covers both. Unlike some sibling
pills, coldspot is not exempt from `make attack`: it has a real socket surface (the control
socket) and a real daemon behind it, and the fuzzer exists specifically to keep that surface
honest.

If `check-sutra` reports lag, the shared `sutra` repo has moved ahead. Re-vendor rather than
editing `src/bin/sutra.py` in place. It's vendored byte-identical on purpose, and hand edits are
exactly what the integrity check exists to catch:

```bash
bash ~/code/REPOS/sutra/vendor.sh src/bin src/extension/coldspot@asuramaya
```

`make smoke` and `make attack` never touch a real network interface or your real installation.
They run against a fake iface and a throwaway control socket, so they're safe on the machine
you actually use coldspot on.

## Style

Bash runs under `set -euo pipefail` and stays ShellCheck-clean. Python stays `ruff check`
clean. Quote your expansions, prefer small functions.

The daemon owns the truth. The CLI and the GNOME pill only ever read `status.json` or send a
command over the control socket. Logic that belongs in `coldspotd` should not creep into
either one.

Names that come off the network or a raw `/proc` read (SSIDs, `comm` strings) are
attacker-controlled or at least untrusted. They reach displays, logs and `jq` as sanitized text
only. See the BPF core's DNS snoop and the SSID handling in
[docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md) for the existing pattern.

## Pull requests

Open one against `main`. CI has to pass. If you change behaviour, update
[docs/USAGE.md](../docs/USAGE.md) and add a `CHANGELOG.md` entry. Small, focused PRs get looked
at fastest.

Each document has an owner, and it's worth a moment to put a change in the right one.
`README.md` answers what a stranger needs before installing. `docs/USAGE.md` covers everything
after. `docs/ARCHITECTURE.md` explains how it's built. A fact that lands in two of them will
drift.

## Releasing

Not covered here. See [docs/RELEASING.md](../docs/RELEASING.md), because a release involves a
hardware key and a person, and getting the order wrong can break the update path for everyone
who already installed.
