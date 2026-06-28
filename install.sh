#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 asuramaya and coldspot contributors
# coldspot installer — metered-link data saver: daemon + GNOME pill.
# Standardized with kast/phanspeed: verified `curl | bash` bootstrap, sudo
# re-exec, real-user extension install, version marker, daily auto-update timer.
set -euo pipefail

REPO="asuramaya/coldspot"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo /nonexistent)"
PREFIX="${PREFIX:-/usr/local}"
BINDIR="$PREFIX/bin"
SHAREDIR="$PREFIX/share/coldspot"
UNITDIR="/etc/systemd/system"
EXT_UUID="coldspot@asuramaya"

# ---- verified release bootstrap (kast-style) -------------------------------
# When run without its sibling files (i.e. `curl -fsSL .../install.sh | bash`),
# fetch the published, checksum-verified release tarball and re-exec from it.
verify_release_tarball() {
  local tarball="$1" want got
  command -v sha256sum >/dev/null 2>&1 || {
    echo "sha256sum not found; cannot verify the download. Install coreutils." >&2; exit 1; }
  want="$(curl -fsSL "https://github.com/${REPO}/releases/latest/download/coldspot.tar.gz.sha256" 2>/dev/null \
        | awk '$2 == "coldspot.tar.gz" { print $1; exit }')"
  [[ -n "$want" ]] || { echo "could not fetch release checksum; refusing unverified download." >&2; exit 1; }
  got="$(sha256sum "$tarball" | awk '{print $1}')"
  [[ "$want" == "$got" ]] || { echo "checksum mismatch on coldspot.tar.gz; aborting." >&2; exit 1; }
  echo "verified release checksum."
}

bootstrap_from_release() {
  command -v curl >/dev/null 2>&1 || { echo "curl is required for remote install" >&2; exit 1; }
  command -v tar  >/dev/null 2>&1 || { echo "tar is required for remote install" >&2; exit 1; }
  local tmp tarball inner from_release=1
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  tarball="$tmp/coldspot.tar.gz"
  echo "== fetching latest coldspot release =="
  if ! curl -fsSL "https://github.com/${REPO}/releases/latest/download/coldspot.tar.gz" -o "$tarball"; then
    from_release=0
    echo "  WARNING: no published release asset — falling back to the UNREVIEWED main branch." >&2
    [[ "${COLDSPOT_NO_UNSTABLE:-0}" == "1" ]] && { echo "Refusing main-branch fallback (COLDSPOT_NO_UNSTABLE=1)." >&2; exit 1; }
    curl -fsSL "https://github.com/${REPO}/archive/refs/heads/main.tar.gz" -o "$tarball" \
      || { echo "download failed." >&2; exit 1; }
  fi
  [[ "$from_release" -eq 1 ]] && verify_release_tarball "$tarball"
  tar -xzf "$tarball" -C "$tmp"
  inner="$(find "$tmp" -maxdepth 2 -name install.sh -type f | head -n1)"
  [[ -n "$inner" ]] || { echo "install.sh not found in archive" >&2; exit 1; }
  bash "$inner" "$@"; exit $?
}

[[ -f "$SRC/bin/coldspotd" ]] || bootstrap_from_release "$@"

# ---- privilege + real-user resolution (phanspeed-style) --------------------
if [[ $EUID -ne 0 ]]; then
  echo "Re-running with sudo..."
  exec sudo -E bash "$0" "$@"
fi
REAL_USER="${SUDO_USER:-$USER}"
USER_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
USER_UID="$(id -u "$REAL_USER")"
EXT_DIR="$USER_HOME/.local/share/gnome-shell/extensions/$EXT_UUID"
VERSION="$(tr -d '[:space:]' < "$SRC/VERSION" 2>/dev/null || echo unknown)"

echo "== coldspot ${VERSION} installer =="

# 1. binaries + version marker
echo "-- binaries -> $BINDIR"
for b in coldspot coldspotd coldspot-stance coldspot-bpf coldspot-update; do
  install -m 0755 -o root -g root "$SRC/bin/$b" "$BINDIR/$b"
done
install -d -m 0755 "$SHAREDIR"
install -m 0644 "$SRC/VERSION" "$SHAREDIR/VERSION"

# 2. bpf core sources + build (clang + local BTF, no network)
echo "-- bpf core sources -> $SHAREDIR/bpf"
install -Dm644 "$SRC/bpf/coldspot.bpf.c"     "$SHAREDIR/bpf/coldspot.bpf.c"
install -Dm644 "$SRC/bpf/coldspot_helpers.h" "$SHAREDIR/bpf/coldspot_helpers.h"
if command -v clang >/dev/null && command -v bpftool >/dev/null; then
  echo "-- building bpf core from local kernel BTF"
  env COLDSPOT_BPF_DIR="$SHAREDIR/bpf" "$BINDIR/coldspot-bpf" build \
    || echo "   (bpf build skipped; v0 metering works without it)"
else
  echo "   (clang/bpftool absent; skipping bpf core — v0 metering still works)"
fi

# 3. default config (kept across reinstalls)
[[ -f /etc/coldspot.conf ]] || install -Dm644 "$SRC/config/coldspot.conf.example" /etc/coldspot.conf

# 4. let `coldspot stance`/the loader call the root helpers without a prompt.
# Write the file directly (install reading /dev/stdin is fragile under sudo) and
# validate it before keeping it, so a bad sudoers can never lock out sudo.
cat > /etc/sudoers.d/coldspot.tmp <<EOF
%sudo ALL=(root) NOPASSWD: $BINDIR/coldspot-stance, $BINDIR/coldspot-bpf
EOF
chmod 0440 /etc/sudoers.d/coldspot.tmp
if visudo -cf /etc/sudoers.d/coldspot.tmp >/dev/null 2>&1; then
  mv -f /etc/sudoers.d/coldspot.tmp /etc/sudoers.d/coldspot
else
  rm -f /etc/sudoers.d/coldspot.tmp
  echo "   WARN sudoers validation failed; skipped (coldspot stance/bpf will prompt for sudo)"
fi

# 5. systemd: meter daemon + daily auto-update timer
echo "-- systemd units + enabling"
install -m 0644 "$SRC/systemd/system/coldspotd.service"       "$UNITDIR/coldspotd.service"
install -m 0644 "$SRC/systemd/system/coldspot-update.service" "$UNITDIR/coldspot-update.service"
install -m 0644 "$SRC/systemd/system/coldspot-update.timer"   "$UNITDIR/coldspot-update.timer"
systemctl daemon-reload
systemctl enable --now coldspotd.service
# Unlike phanspeed (.deb), coldspot is a source/tarball install that updates in
# place by re-running this installer, so in-place auto-update is safe to enable.
systemctl enable --now coldspot-update.timer

# 6. GNOME pill into the real user's home
echo "-- GNOME pill -> $EXT_DIR"
sudo -u "$REAL_USER" mkdir -p "$EXT_DIR"
install -m 0644 -o "$REAL_USER" -g "$REAL_USER" "$SRC/extension/$EXT_UUID/metadata.json" "$EXT_DIR/metadata.json"
install -m 0644 -o "$REAL_USER" -g "$REAL_USER" "$SRC/extension/$EXT_UUID/extension.js"  "$EXT_DIR/extension.js"
runu() { sudo -u "$REAL_USER" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$USER_UID/bus" "$@"; }
runu gnome-extensions enable "$EXT_UUID" 2>/dev/null || true
# `gnome-extensions enable` no-ops if the running shell hasn't scanned a freshly
# installed extension, so also write the enabled-extensions list directly — the
# shell honors it on the next login (Wayland can't hot-reload extensions).
cur="$(runu gsettings get org.gnome.shell enabled-extensions 2>/dev/null || echo '@as []')"
if grep -Fq "'$EXT_UUID'" <<<"$cur"; then
  echo "   enabled"
else
  if [[ "$cur" == "@as []" || "$cur" == "[]" ]]; then cur="['$EXT_UUID']"
  else cur="${cur%]}, '$EXT_UUID']"; fi
  runu gsettings set org.gnome.shell enabled-extensions "$cur" 2>/dev/null \
    && echo "   queued for next login" \
    || echo "   (enable manually: gnome-extensions enable $EXT_UUID)"
fi

# 7. verify perms
echo "-- verifying"
verify() { local got; got="$(stat -c '%a' "$1" 2>/dev/null || echo '?')"
  [[ "$got" == "$2" ]] && echo "   OK   $1 ($got)" || echo "   WARN $1 is $got, expected $2"; }
verify "$BINDIR/coldspotd" 755
verify /etc/sudoers.d/coldspot 440

cat <<EOF

== coldspot ${VERSION} installed ==
  coldspot status            see the meter
  coldspot budget 500        cap this session at 500 MB
  coldspot siege             only the active task on the wire
  coldspot flows             per-destination breakdown (needs the bpf core)
  coldspot update [--check]  pull newer releases (auto-checked daily)
  Remove:  curl -fsSL https://raw.githubusercontent.com/${REPO}/main/uninstall.sh | bash

per-app talkers without the bpf core need systemd accounting:
  sudo sed -i 's/^#\\?DefaultIPAccounting=.*/DefaultIPAccounting=yes/' /etc/systemd/system.conf && sudo systemctl daemon-reexec

>>> log out/in once to load the GNOME pill (Wayland can't hot-reload extensions). <<<
EOF
