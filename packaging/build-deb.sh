#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build a coldspot .deb from the repo with dpkg-deb (no debhelper needed).
# Output: dist/coldspot_<version>_all.deb  +  dist/SHA256SUMS
# Reference shape: phanspeed's packaging/build-deb.sh (operator ruling
# 0d38a1f9, "phanspeed v0.30.1 is the reference shape"), extended for
# coldspot's own pieces: the eBPF core (sources only -- built on the target
# machine by postinst, never prebuilt here), and the group-gated privilege
# model (no sibling deb has this; every other pill is uid-gated).
set -euo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd)"
VER="$(tr -d '[:space:]' < "$SRC/packaging/VERSION")"
PKG="coldspot"
DIST="$SRC/dist"
BUILD="$(mktemp -d)"
ROOT="$BUILD/${PKG}_${VER}"
trap 'rm -rf "$BUILD"' EXIT

echo "== building ${PKG} ${VER} =="

install -d "$ROOT/DEBIAN" \
          "$ROOT/usr/bin" \
          "$ROOT/lib/systemd/system" \
          "$ROOT/usr/share/gnome-shell/extensions/coldspot@asuramaya" \
          "$ROOT/usr/share/coldspot/lib" \
          "$ROOT/usr/share/coldspot/bpf" \
          "$ROOT/usr/share/man/man1" \
          "$ROOT/usr/share/man/man8" \
          "$ROOT/etc"

# binaries -> /usr/bin
for b in coldspot coldspotd coldspot-stance coldspot-bpf coldspot-update coldspot-pill coldspot-healthcheck; do
    install -m 0755 "$SRC/src/bin/$b" "$ROOT/usr/bin/$b"
done

# vendored sutra backbone (+ sutra.mk, the recipe layer) -> a PRIVATE
# per-pill dir under /usr/share, found via the bootstrap preamble pasted at
# the top of every binary that imports it -- never /usr/bin, where two
# pills vendoring identically-named sutra.py would make dpkg refuse the
# second package outright (BOOTSTRAP.md, ruling 3e44bd95). This is the
# exact layout the family's three-pill co-install proof exercises.
for f in "$SRC"/src/share/coldspot/lib/*; do
    [ -f "$f" ] || continue   # skip __pycache__ etc. left by a local py_compile
    install -m 0644 "$f" "$ROOT/usr/share/coldspot/lib/$(basename "$f")"
done

# man pages
install -m 0644 "$SRC/src/data/man/man1/coldspot.1"  "$ROOT/usr/share/man/man1/coldspot.1"
install -m 0644 "$SRC/src/data/man/man8/coldspotd.8" "$ROOT/usr/share/man/man8/coldspotd.8"

# v1 eBPF core: SOURCE only, never a prebuilt object -- a .bpf.o is specific
# to the kernel BTF it was compiled against, so this repo builds it on the
# TARGET machine (postinst, conditional on clang+bpftool being present),
# exactly like install.sh already does for a source install. Shipping a
# prebuilt object here would silently work on the build runner's kernel and
# nowhere else.
install -m 0644 "$SRC/src/bpf/coldspot.bpf.c"     "$ROOT/usr/share/coldspot/bpf/coldspot.bpf.c"
install -m 0644 "$SRC/src/bpf/coldspot_helpers.h" "$ROOT/usr/share/coldspot/bpf/coldspot_helpers.h"

# systemd units -> /lib/systemd/system, rewriting /usr/local/bin -> /usr/bin
# (install.sh's units hardcode the source-install prefix; the deb installs
# under /usr, not /usr/local)
for u in coldspotd.service coldspot-update.service coldspot-update.timer; do
    sed 's#/usr/local/bin#/usr/bin#g' "$SRC/src/data/systemd/system/$u" \
        > "$ROOT/lib/systemd/system/$u"
done

# GNOME extension source -> system-wide staging (per-account activation is
# still `gnome-extensions enable`, same as a source install's coldspot-pill)
install -m 0644 "$SRC/src/extension/coldspot@asuramaya/metadata.json" \
        "$ROOT/usr/share/gnome-shell/extensions/coldspot@asuramaya/metadata.json"
install -m 0644 "$SRC/src/extension/coldspot@asuramaya/extension.js" \
        "$ROOT/usr/share/gnome-shell/extensions/coldspot@asuramaya/extension.js"
install -m 0644 "$SRC/src/extension/coldspot@asuramaya/pill.js" \
        "$ROOT/usr/share/gnome-shell/extensions/coldspot@asuramaya/pill.js"

# version marker (coldspot-update's dpkg-query fallback) + default config.
# /etc/coldspot.conf is a dpkg conffile (DEBIAN/conffiles below) -- shipped
# here as the real default, dpkg itself preserves local edits across
# upgrades, no manual [[ -f ]] guard needed the way install.sh needs one.
echo "$VER" > "$ROOT/usr/share/coldspot/VERSION"
install -m 0644 "$SRC/src/data/config/coldspot.conf.example" "$ROOT/etc/coldspot.conf"

# release-signing trust anchor (docs/RELEASE-SIGNING.md) -- coldspot-update's
# installed-anchor candidate; empty until a key is provisioned, degrades to
# sha256-only until it isn't (same as install.sh's own bootstrap anchor)
install -m 0644 "$SRC/packaging/release-signing/allowed_signers" \
        "$ROOT/usr/share/coldspot/allowed_signers"

# control + maintainer scripts
sed "s/@VERSION@/$VER/" "$SRC/packaging/debian/control" > "$ROOT/DEBIAN/control"
install -m 0644 "$SRC/packaging/debian/conffiles" "$ROOT/DEBIAN/conffiles"
for s in postinst prerm postrm; do
    install -m 0755 "$SRC/packaging/debian/$s" "$ROOT/DEBIAN/$s"
done

mkdir -p "$DIST"
DEB="$DIST/${PKG}_${VER}_all.deb"
dpkg-deb --root-owner-group --build "$ROOT" "$DEB"

# checksums for the release (coldspot-update verifies the .deb against this)
( cd "$DIST" && sha256sum "$(basename "$DEB")" > SHA256SUMS )

echo "built: $DEB"
echo "sums : $DIST/SHA256SUMS"
dpkg-deb --info "$DEB" | sed -n '1,3p;/Description/p'
