#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 asuramaya and coldspot contributors
# coldspot-deploy — the single local-iteration ritual (`make deploy`).
#
# NOT a first-time install (use install.sh for the pill, sudoers, systemd units,
# auto-update timer). This pushes the *moving parts* — bins, the BPF object, the
# daemon — into their installed locations in the one order that actually works,
# and only when the smoke test passes. It exists because the manual ritual was
# easy to half-do, and two failure modes bit repeatedly:
#   * a new BPF object reloaded by the OLD installed loader, so new programs
#     never attached  -> we install the loader bin BEFORE reloading;
#   * daemon changes shipped without `make smoke`, crashing it  -> smoke runs
#     FIRST, before we touch anything or even ask for sudo.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
PREFIX="${PREFIX:-/usr/local}"
BINDIR="$PREFIX/bin"
SHAREDIR="$PREFIX/share/coldspot"
PIN="/sys/fs/bpf/coldspot"
VERSION="$(tr -d '[:space:]' < "$SRC/VERSION" 2>/dev/null || echo unknown)"

# 1. SMOKE FIRST — as the invoking user, before any privilege. A failing smoke
#    aborts here, before we've changed a single installed file or prompted sudo.
if [[ "${_COLDSPOT_DEPLOY_PRIVED:-}" != 1 ]]; then
  echo "== smoke =="
  bash "$SRC/tests/smoke.sh"
fi

# escalate only for the install/reload half (re-exec, skipping the smoke above)
if [[ $EUID -ne 0 ]]; then
  echo "-- re-running install half with sudo --"
  exec sudo -E env _COLDSPOT_DEPLOY_PRIVED=1 bash "$0" "$@"
fi

# note whether the core is live BEFORE we overwrite the object, so we only
# reload a core that was already running (deploy shouldn't load it from cold).
core_loaded=0; [[ -e "$PIN/usage" ]] && core_loaded=1

# 2. binaries — including coldspot-bpf (the loader) and coldspotd. Installing the
#    loader before the reload below is the whole point: stale loader = the new
#    programs in the object never get attached.
echo "== bins -> $BINDIR =="
for b in coldspot coldspotd coldspot-stance coldspot-bpf coldspot-update; do
  install -m 0755 -o root -g root "$SRC/bin/$b" "$BINDIR/$b"
done
install -d -m 0755 "$SHAREDIR"
install -m 0644 "$SRC/VERSION" "$SHAREDIR/VERSION"

# 3. BPF sources + rebuild the object into the installed share (local BTF only).
echo "== bpf core -> $SHAREDIR/bpf =="
install -Dm644 "$SRC/bpf/coldspot.bpf.c"     "$SHAREDIR/bpf/coldspot.bpf.c"
install -Dm644 "$SRC/bpf/coldspot_helpers.h" "$SHAREDIR/bpf/coldspot_helpers.h"
if command -v clang >/dev/null && command -v bpftool >/dev/null; then
  env COLDSPOT_BPF_DIR="$SHAREDIR/bpf" "$BINDIR/coldspot-bpf" build
else
  echo "   (clang/bpftool absent; skipping object build)"
  core_loaded=0   # nothing to reload without a fresh object
fi

# 4. reload the core with the freshly-installed loader — only if it was loaded.
if [[ "$core_loaded" == 1 ]]; then
  echo "== reload bpf core =="
  env COLDSPOT_BPF_DIR="$SHAREDIR/bpf" "$BINDIR/coldspot-bpf" unload || true
  env COLDSPOT_BPF_DIR="$SHAREDIR/bpf" "$BINDIR/coldspot-bpf" load
else
  echo "   (bpf core was not loaded; not starting it — run: sudo coldspot-bpf load)"
fi

# 5. restart the daemon if it's running under systemd (picks up daemon changes).
if systemctl is-active --quiet coldspotd 2>/dev/null; then
  echo "== restart coldspotd =="
  systemctl restart coldspotd
else
  echo "   (coldspotd not active; not starting it)"
fi

echo "== deploy ok (v$VERSION) =="
