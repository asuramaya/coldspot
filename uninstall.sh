#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 asuramaya and coldspot contributors
# coldspot uninstaller. Keeps /var/lib/coldspot usage history and /etc/coldspot.conf
# unless --purge is given.
set -uo pipefail

PREFIX="${PREFIX:-/usr/local}"
BINDIR="$PREFIX/bin"
SHAREDIR="$PREFIX/share/coldspot"
UNITDIR="/etc/systemd/system"
EXT_UUID="coldspot@asuramaya"
PURGE=0

for a in "$@"; do
  case "$a" in
    --purge) PURGE=1 ;;
    -h|--help) echo "usage: ./uninstall.sh [--purge]"; exit 0 ;;
    *) echo "unknown argument: $a" >&2; exit 1 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "Re-running with sudo..."
  exec sudo -E bash "$0" "$@"
fi
REAL_USER="${SUDO_USER:-$USER}"
USER_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
EXT_DIR="$USER_HOME/.local/share/gnome-shell/extensions/$EXT_UUID"

echo "== coldspot uninstaller =="

echo "-- stopping services + timer"
systemctl disable --now coldspotd.service coldspot-update.timer coldspot-update.service 2>/dev/null || true

echo "-- detaching bpf core + dropping siege table"
"$BINDIR/coldspot-bpf" unload 2>/dev/null || true
nft delete table inet coldspot 2>/dev/null || true

echo "-- removing files"
for b in coldspot coldspotd coldspot-stance coldspot-bpf coldspot-update; do
  rm -f "$BINDIR/$b"
done
rm -f "$UNITDIR/coldspotd.service" "$UNITDIR/coldspot-update.service" "$UNITDIR/coldspot-update.timer"
rm -f /etc/sudoers.d/coldspot
rm -rf "$SHAREDIR"
rm -rf "$EXT_DIR"
systemctl daemon-reload

if [[ "$PURGE" -eq 1 ]]; then
  echo "-- purging config + usage history"
  rm -f /etc/coldspot.conf
  rm -rf /var/lib/coldspot
  echo "coldspot fully removed."
else
  echo "coldspot removed. (kept /etc/coldspot.conf and /var/lib/coldspot — use --purge to drop them.)"
fi
