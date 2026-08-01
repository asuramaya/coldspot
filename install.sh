#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 asuramaya and coldspot contributors
# coldspot installer — metered-link data saver: daemon, root helpers, systemd
# units. Root-only, and ONLY root-only: this script never re-execs itself under
# sudo (a script that quietly escalates itself is exactly what made a nested
# `sudo make install` misattribute the human user to "root" — see git log). If
# you're not root, it says so and stops; you always type sudo yourself, exactly
# once, so there is no ambiguity about who actually ran it. The GNOME pill is a
# SEPARATE, per-account, non-root step — see `coldspot-pill` — since installing
# a file into your own home never needed root in the first place.
set -euo pipefail

REPO="asuramaya/coldspot"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo /nonexistent)"
PREFIX="${PREFIX:-/usr/local}"
BINDIR="$PREFIX/bin"
SHAREDIR="$PREFIX/share/coldspot"
UNITDIR="/etc/systemd/system"
EXT_UUID="coldspot@asuramaya"
# principal = WHO (the repo's stable identity); namespace = WHAT-FOR (what
# this signature authorizes). Never conflate the two — see RELEASE.md.
SIGN_PRINCIPAL="coldspot"
SIGN_NAMESPACE="coldspot-release"

# Trust anchor for the curl-pipe-bash bootstrap below, EMBEDDED directly:
# `curl .../install.sh | sudo bash` fetches this ONE file over the network, so
# at that point there is no sibling packaging/release-signing/allowed_signers
# to read — unlike coldspot-update (an installed, persistent script), which
# reads that file straight off disk. Ships empty until a key is provisioned;
# kept in sync with packaging/release-signing/allowed_signers by
# `make sync-signers` (packaging/sync-signers.sh) — never hand-edit this.
# Single-quoted deliberately: the value can span multiple lines (one per
# pinned key) and must never be
# shell-interpolated. While empty, the bootstrap below degrades to sha256-only
# with a printed warning rather than refusing to install outright — this is a
# one-time, human-typed `sudo` action, not the unattended daily updater
# (coldspot-update), which has the stricter no-key-no-install policy.
RELEASE_ALLOWED_SIGNERS='coldspot namespaces="coldspot-release,pills-tag" sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIAvqlv848gk9uzM40ZsFZTQeXsQKpxYaK4Fi8ubNl1H7AAAAFnNzaDphc3VyYW1heWEtbWFzdGVyLTE= ra-master-1
coldspot namespaces="coldspot-release,pills-tag" sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIFJBKAsk6b4YR2UH/UZ1Rk24PxepTYNkF7zflo01AmlZAAAAFnNzaDphc3VyYW1heWEtbWFzdGVyLTI= ra-master-2
coldspot namespaces="coldspot-release,pills-tag" sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIHTVqgo3ARbpTq04YlQksobfGIbBAw21nbE6HyeCPgxBAAAAFnNzaDphc3VyYW1heWEtbWFzdGVyLTM= ra-master-3
coldspot namespaces="coldspot-release,pills-tag" sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIP15ZeSJYWryHN2WEHDlJbWk/vA+j5JFgb9RSzT1SHveAAAAFnNzaDphc3VyYW1heWEtbWFzdGVyLTQ= ra-master-4
'

# ---- root, checked FIRST, before any download --------------------------
# Fail fast and plainly rather than self-elevating: `curl | bash` without sudo
# gets told to add sudo BEFORE anything is fetched, not after a wasted download.
if [[ $EUID -ne 0 ]]; then
  cat >&2 <<'EOF'
coldspot needs root to install (binaries, systemd units, the bpf core). Re-run
with sudo:

  curl -fsSL https://raw.githubusercontent.com/asuramaya/coldspot/main/install.sh | sudo bash

or from a checkout:

  sudo ./install.sh        (or: sudo make install)
EOF
  exit 1
fi

# ---- verified release bootstrap (kast-style) -------------------------------
# When run without its sibling files (i.e. `curl -fsSL .../install.sh | sudo
# bash`), fetch the published, checksum-verified release tarball and re-exec
# from it. Runs as root (we already checked above), same as everything else.
verify_release_tarball() {
  local tarball="$1" base="https://github.com/${REPO}/releases/latest/download" \
        tmp sums_name sums want got
  command -v sha256sum >/dev/null 2>&1 || {
    echo "sha256sum not found; cannot verify the download. Install coreutils." >&2; exit 1; }
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
  # SHA256SUMS is the family's unified manifest (ruling 0d38a1f9) as of
  # coldspot 0.6.0 -- covers the tarball AND the .deb under one signature.
  # Falls back to the pre-0.6.0 single-purpose file so this exact install.sh
  # keeps working against an OLDER release too, without a second migration.
  # Both are the same "<hash>  <filename>" format; only the name and row
  # count differ, so the parse below is unchanged either way.
  sums_name="SHA256SUMS"
  sums="$tmp/$sums_name"
  if ! curl -fsSL "${base}/${sums_name}" -o "$sums"; then
    sums_name="coldspot.tar.gz.sha256"
    sums="$tmp/$sums_name"
    curl -fsSL "${base}/${sums_name}" -o "$sums" \
      || { echo "could not fetch release checksum; refusing unverified download." >&2; exit 1; }
  fi
  want="$(awk '$2 == "coldspot.tar.gz" { print $1; exit }' "$sums")"
  [[ -n "$want" ]] || { echo "release checksum file has no entry for coldspot.tar.gz; aborting." >&2; exit 1; }
  got="$(sha256sum "$tarball" | awk '{print $1}')"
  [[ "$want" == "$got" ]] || { echo "checksum mismatch on coldspot.tar.gz; aborting." >&2; exit 1; }
  echo "verified release checksum (${sums_name})."

  # Signature over that checksum manifest (the exact bytes fetched above,
  # under whichever name was actually fetched), against the embedded trust
  # anchor (docs/RELEASE-SIGNING.md). Ships empty until a key is provisioned
  # — this is a one-time human-typed bootstrap, not the unattended
  # auto-updater (coldspot-update, which refuses outright with no key), so
  # it degrades to the checksum-only check above with a warning rather than
  # blocking install.
  if [[ -z "$RELEASE_ALLOWED_SIGNERS" ]]; then
    echo "warning: no release-signing key provisioned yet — proceeding on sha256" >&2
    echo "         alone. See docs/RELEASE-SIGNING.md." >&2
    return 0
  fi
  command -v ssh-keygen >/dev/null 2>&1 || {
    echo "ssh-keygen not found; cannot verify the release signature. Aborting." >&2; exit 1; }
  local sig signers
  sig="$tmp/${sums_name}.sig"
  curl -fsSL "${base}/${sums_name}.sig" -o "$sig" \
    || { echo "could not fetch release signature; refusing unsigned install." >&2; exit 1; }
  signers="$tmp/allowed_signers"
  # No added newline: RELEASE_ALLOWED_SIGNERS is embedded byte-for-byte from
  # the anchor file by `make sync-signers`, trailing newline included — that
  # exact-copy invariant is what CI's signing-sync check enforces.
  printf '%s' "$RELEASE_ALLOWED_SIGNERS" > "$signers"
  if ! ssh-keygen -Y verify -f "$signers" -I "$SIGN_PRINCIPAL" -n "$SIGN_NAMESPACE" \
        -s "$sig" < "$sums" >/dev/null 2>&1; then
    echo "signature verification FAILED; refusing to install." >&2; exit 1
  fi
  echo "verified release signature."
}

bootstrap_from_release() {
  command -v curl >/dev/null 2>&1 || { echo "curl is required for remote install" >&2; exit 1; }
  command -v tar  >/dev/null 2>&1 || { echo "tar is required for remote install" >&2; exit 1; }
  local tmp tarball inner
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  tarball="$tmp/coldspot.tar.gz"
  echo "== fetching latest coldspot release =="
  if ! curl -fsSL "https://github.com/${REPO}/releases/latest/download/coldspot.tar.gz" -o "$tarball"; then
    # No unreviewed-`main` fallback: this runs as root, and falling back to a
    # mutable branch on ANY fetch hiccup (network blip, or an attacker simply
    # interfering with the release-asset request) would turn a transient
    # failure into an unverified root install. Fail closed instead.
    cat >&2 <<EOF
could not fetch a published release tarball for ${REPO}. This installer
never falls back to the unreviewed main branch as root — clone the repo and
run install.sh from the checkout instead:

  git clone https://github.com/${REPO} && cd coldspot && sudo ./install.sh
EOF
    exit 1
  fi
  verify_release_tarball "$tarball"
  tar -xzf "$tarball" -C "$tmp"
  inner="$(find "$tmp" -maxdepth 2 -name install.sh -type f | head -n1)"
  [[ -n "$inner" ]] || { echo "install.sh not found in archive" >&2; exit 1; }
  bash "$inner" "$@"; exit $?
}

[[ -f "$SRC/src/bin/coldspotd" ]] || bootstrap_from_release "$@"

# We already know we're root (checked at the top, before any of the above ran).
# The ONLY thing that still needs to know about a human account is the group
# membership grant below — and since this script never sudos itself, $SUDO_USER
# is reliable here: it's set by whichever single sudo call the human actually
# typed. If it's unset (e.g. you're in a plain root shell, not via sudo), we
# say so plainly rather than guessing.
REAL_USER="${SUDO_USER:-}"
VERSION="$(tr -d '[:space:]' < "$SRC/packaging/VERSION" 2>/dev/null || echo unknown)"

echo "== coldspot ${VERSION} installer =="

# 1. binaries + version marker
echo "-- binaries -> $BINDIR"
for b in coldspot coldspotd coldspot-stance coldspot-bpf coldspot-update coldspot-pill coldspot-healthcheck; do
  install -m 0755 -o root -g root "$SRC/src/bin/$b" "$BINDIR/$b"
done
install -d -m 0755 "$SHAREDIR"
install -m 0644 "$SRC/packaging/VERSION" "$SHAREDIR/VERSION"
# coldspot-update's installed-anchor candidate (its checkout-relative
# fallback only ever helps a dev checkout, not a real install) -- without
# this, an installed coldspot-update could never find the signing anchor at
# all, armed or not (caught while adopting it onto the shared sutra_update
# spine; ByeByte and RAMstein already had this line, coldspot never did).
install -m 0644 "$SRC/packaging/release-signing/allowed_signers" "$SHAREDIR/allowed_signers"

# coldspotd/coldspot both `import sutra` as a sibling, found via the sutra
# bootstrap preamble pasted at the top of each (see BOOTSTRAP.md in the sutra
# repo) — a PRIVATE per-pill dir, never $BINDIR: two pills vendoring
# identically-named sutra.py into the same shared bin dir make each other
# uninstallable (ruling 3e44bd95). .version/.commit travel with the .py so
# the installed copy stays checkable, not just the dev-tree one.
echo "-- vendored sutra -> $SHAREDIR/lib"
install -d -m 0755 "$SHAREDIR/lib"
for f in "$SRC"/src/share/coldspot/lib/*; do
  install -m 0644 -o root -g root "$f" "$SHAREDIR/lib/$(basename "$f")"
done
# An older install left its vendored copies beside the binaries in $BINDIR —
# nothing else ever cleans those up, and a stale, unanchored duplicate lying
# around is exactly the blind spot that let /usr/bin and /usr/local/bin run
# different canonical commits undetected in the first place.
rm -f "$BINDIR"/sutra*.py "$BINDIR"/sutra*.version "$BINDIR"/sutra*.commit

# 2. bpf core sources + build (clang + local BTF, no network)
echo "-- bpf core sources -> $SHAREDIR/bpf"
install -Dm644 "$SRC/src/bpf/coldspot.bpf.c"     "$SHAREDIR/bpf/coldspot.bpf.c"
install -Dm644 "$SRC/src/bpf/coldspot_helpers.h" "$SHAREDIR/bpf/coldspot_helpers.h"
if command -v clang >/dev/null && command -v bpftool >/dev/null; then
  echo "-- building bpf core from local kernel BTF"
  env COLDSPOT_BPF_DIR="$SHAREDIR/bpf" "$BINDIR/coldspot-bpf" build \
    || echo "   (bpf build skipped; v0 metering works without it)"
else
  echo "   (clang/bpftool absent; skipping bpf core — v0 metering still works)"
fi

# 3. default config (kept across reinstalls)
[[ -f /etc/coldspot.conf ]] || install -Dm644 "$SRC/src/data/config/coldspot.conf.example" /etc/coldspot.conf

# man pages
install -Dm644 "$SRC/src/data/man/man1/coldspot.1"  "$PREFIX/share/man/man1/coldspot.1"
install -Dm644 "$SRC/src/data/man/man8/coldspotd.8" "$PREFIX/share/man/man8/coldspotd.8"

# 4. privilege model: no sudo. The CLI talks to coldspotd over its control
# socket, and access is gated by membership in the `coldspot` system group (the
# daemon sets the socket root:coldspot 0660 and checks SO_PEERCRED). Create the
# group and add the real user to it.
echo "-- coldspot group + membership"
# Drop the obsolete passwordless-root grant from older versions: the CLI no
# longer uses sudo, so a NOPASSWD rule for the root helpers is a needless
# local-root vector. Remove it if a prior install left it behind.
rm -f /etc/sudoers.d/coldspot
getent group coldspot >/dev/null || groupadd -r coldspot
if [[ -n "$REAL_USER" ]]; then
  usermod -aG coldspot "$REAL_USER" || true
else
  echo "   couldn't tell which account to add (no \$SUDO_USER — running from a" \
       "root shell rather than sudo?)"
  echo "   add yourself manually:  sudo usermod -aG coldspot <your-username>"
fi

# 5. systemd: meter daemon (+ updater units, installed but NOT enabled)
echo "-- systemd units + enabling"
install -m 0644 "$SRC/src/data/systemd/system/coldspotd.service"       "$UNITDIR/coldspotd.service"
install -m 0644 "$SRC/src/data/systemd/system/coldspot-update.service" "$UNITDIR/coldspot-update.service"
install -m 0644 "$SRC/src/data/systemd/system/coldspot-update.timer"   "$UNITDIR/coldspot-update.timer"
systemctl daemon-reload
systemctl enable coldspotd.service
# `enable --now` on an ALREADY-active unit is a no-op start — it would leave the
# old binary running in memory even though we just overwrote it on disk. Detect
# a re-install and explicitly restart so the new daemon (and any unit-file
# changes, e.g. hardening directives) actually take effect.
if systemctl is-active --quiet coldspotd.service; then
  echo "-- restarting coldspotd to load the updated daemon"
  systemctl restart coldspotd.service
else
  systemctl start coldspotd.service
fi
# The daily updater runs code as root unattended, so it is OPT-IN for security:
# we install the timer but do NOT enable it. Turn it on deliberately (see the
# post-install note) after setting `auto_update = on` in /etc/coldspot.conf.

# 6. GNOME pill SOURCE, staged system-wide (like the bpf sources above) — NOT
# installed into any account. Writing into a user's $HOME never needed root, so
# it isn't done here; each account runs `coldspot-pill install` for itself
# (works for every user on a shared box, not just whoever ran this installer).
echo "-- GNOME pill source -> $SHAREDIR/extension/$EXT_UUID"
install -Dm644 "$SRC/src/extension/$EXT_UUID/metadata.json" "$SHAREDIR/extension/$EXT_UUID/metadata.json"
install -Dm644 "$SRC/src/extension/$EXT_UUID/extension.js"  "$SHAREDIR/extension/$EXT_UUID/extension.js"
# extension.js imports pill.js as a sibling (Pass 4: PALETTE/CHIP/CHIP_ON/
# dataRow collapsed to the vendored commons) -- without this line the staged
# extension source is missing a file it needs at runtime, and coldspot-pill
# install would ship a pill that fails to load.
install -Dm644 "$SRC/src/extension/$EXT_UUID/pill.js"       "$SHAREDIR/extension/$EXT_UUID/pill.js"

# 7. verify perms
echo "-- verifying"
verify() { local got; got="$(stat -c '%a' "$1" 2>/dev/null || echo '?')"
  [[ "$got" == "$2" ]] && echo "   OK   $1 ($got)" || echo "   WARN $1 is $got, expected $2"; }
verify "$BINDIR/coldspotd" 755

if [[ -n "$REAL_USER" ]]; then
  GROUP_NOTE=">>> $REAL_USER was added to the 'coldspot' group, which gates the privileged
    verbs. LOG OUT AND BACK IN (or run 'newgrp coldspot' in a shell) for the
    membership to take effect before the CLI can drive them. <<<"
else
  GROUP_NOTE=">>> no account was added to the 'coldspot' group (see the warning above) —
    add yours with: sudo usermod -aG coldspot <your-username>, then log out/in. <<<"
fi

cat <<EOF

== coldspot ${VERSION} installed ==
  coldspot status            see the meter
  coldspot budget 500        cap this session at 500 MB
  coldspot siege             only the active task on the wire
  coldspot flows             per-destination breakdown (needs the bpf core)
  coldspot update [--check]  pull newer releases (opt-in daily timer, see below)
  coldspot-pill install      add the GNOME pill to YOUR account (as yourself, no sudo)
  coldspot-healthcheck       one-line vitals verdict (exit 0 = healthy)
  Remove:  curl -fsSL https://raw.githubusercontent.com/${REPO}/main/uninstall.sh | sudo bash

$GROUP_NOTE

daily auto-update is OFF by default (it runs code as root unattended). To opt in:
  set 'auto_update = on' in /etc/coldspot.conf, then:
  sudo systemctl enable --now coldspot-update.timer

per-app talkers without the bpf core need systemd accounting:
  sudo sed -i 's/^#\\?DefaultIPAccounting=.*/DefaultIPAccounting=yes/' /etc/systemd/system.conf && sudo systemctl daemon-reexec

>>> the GNOME pill is per-account now — run 'coldspot-pill install' as
    yourself (every user on this box can do the same) <<<
EOF
