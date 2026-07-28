#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 asuramaya and coldspot contributors
# coldspot uninstaller. Keeps /var/lib/coldspot usage history and /etc/coldspot.conf
# unless --purge is given. Root-only, and never self-elevates — see install.sh
# for why. Doesn't touch any per-account GNOME pill install (it never guesses
# whose home to reach into) — this script REMOVES the coldspot-pill binary
# below, so run it first if you want the tidy version: `coldspot-pill remove`
# as yourself, on each account that installed it. Missed that step? The
# manual fallback always works regardless: rm -rf
# ~/.local/share/gnome-shell/extensions/coldspot@asuramaya
set -uo pipefail

PREFIX="${PREFIX:-/usr/local}"
BINDIR="$PREFIX/bin"
SHAREDIR="$PREFIX/share/coldspot"
UNITDIR="/etc/systemd/system"
PURGE=0

for a in "$@"; do
  case "$a" in
    --purge) PURGE=1 ;;
    -h|--help) echo "usage: ./uninstall.sh [--purge]"; exit 0 ;;
    *) echo "unknown argument: $a" >&2; exit 1 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "coldspot uninstaller needs root — run: sudo ./uninstall.sh" >&2
  exit 1
fi

echo "== coldspot uninstaller =="
echo "-- before this removes the coldspot-pill binary: if you want your GNOME"
echo "   pill cleaned up too, run 'coldspot-pill remove' as yourself first"
echo "   (or anytime later: rm -rf ~/.local/share/gnome-shell/extensions/coldspot@asuramaya)"

echo "-- stopping services + timer"
systemctl disable --now coldspotd.service coldspot-update.timer coldspot-update.service 2>/dev/null || true

echo "-- detaching bpf core + dropping siege table"
"$BINDIR/coldspot-bpf" unload 2>/dev/null || true
nft delete table inet coldspot 2>/dev/null || true

echo "-- removing files"
for b in coldspot coldspotd coldspot-stance coldspot-bpf coldspot-update coldspot-pill; do
  rm -f "$BINDIR/$b"
done
# $SHAREDIR/lib (the current vendor location) is covered by the rm -rf below.
# An install from before the private-lib-dir move (ruling 3e44bd95) may still
# have left copies beside the binaries — nothing else on the machine cleans
# those up, so a plain uninstall must still catch them.
rm -f "$BINDIR"/sutra*.py "$BINDIR"/sutra*.version "$BINDIR"/sutra*.commit
rm -f "$UNITDIR/coldspotd.service" "$UNITDIR/coldspot-update.service" "$UNITDIR/coldspot-update.timer"
rm -f "$PREFIX/share/man/man1/coldspot.1" "$PREFIX/share/man/man8/coldspotd.8"
rm -f /etc/sudoers.d/coldspot
rm -rf "$SHAREDIR"
systemctl daemon-reload

if [[ "$PURGE" -eq 1 ]]; then
  echo "-- purging config + usage history"
  rm -f /etc/coldspot.conf
  rm -rf /var/lib/coldspot
  # Drop the privilege-gating group only on purge — a plain uninstall keeps it so
  # a reinstall doesn't strip the user's membership (which needs a re-login).
  groupdel coldspot 2>/dev/null || true
  echo "coldspot fully removed."
else
  echo "coldspot removed. (kept /etc/coldspot.conf and /var/lib/coldspot — use --purge to drop them.)"
fi
