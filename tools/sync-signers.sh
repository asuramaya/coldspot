#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# `make sync-signers` — rebuild release-signing/allowed_signers AND
# install.sh's embedded RELEASE_ALLOWED_SIGNERS twin from the fleet's
# canonical pubkeys (rotten-apple/release-signing/*.pub), per
# ~/code/REPOS/RELEASE.md's sync-signers doctrine.
#
# ALWAYS a full rebuild, never an append: RA's first ceremony left 3 of 4
# keys unpinned across other repos by appending one key at a time. Refuses to
# run unless it finds exactly 4 canonical keys, so a partial/broken rotten-
# apple checkout can't silently produce a partial anchor.
#
# SEQUENCING: this populates the anchor. Per RELEASE.md, run it ONLY in the
# same act as cutting the operator's first signed coldspot release — arming
# release-signing/allowed_signers any earlier bricks coldspot-update against
# every existing unsigned release. CI's sync-signers check re-runs this and
# diffs; while the anchor is meant to stay empty, that diff should be empty
# too (no canonical source configured / not yet time to arm).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd)"
PRINCIPAL="coldspot"
NAMESPACES="coldspot-release,pills-tag"

# Canonical source: explicit override, else common sibling layouts.
RA_DIR=""
for cand in "${ROTTEN_APPLE_DIR:-}" \
            "$HERE/../rotten-apple" \
            "$HERE/../../rotten-apple" \
            "$HOME/code/rotten-apple"; do
  [[ -n "$cand" && -d "$cand/release-signing" ]] && { RA_DIR="$cand"; break; }
done
if [[ -z "$RA_DIR" ]]; then
  echo "ERROR: can't find a rotten-apple checkout (release-signing/*.pub)." >&2
  echo "       Set ROTTEN_APPLE_DIR=/path/to/rotten-apple and retry." >&2
  exit 1
fi

mapfile -t pubs < <(find "$RA_DIR/release-signing" -maxdepth 1 -name '*.pub' | LC_ALL=C sort)
if [[ "${#pubs[@]}" -ne 4 ]]; then
  echo "ERROR: expected exactly 4 canonical pubkeys in $RA_DIR/release-signing, found ${#pubs[@]}." >&2
  echo "       Never partially sync — see RELEASE.md's sync-signers section." >&2
  exit 1
fi

anchor="$HERE/release-signing/allowed_signers"
tmp="$(mktemp)"
for p in "${pubs[@]}"; do
  printf '%s namespaces="%s" %s\n' "$PRINCIPAL" "$NAMESPACES" "$(cat "$p")"
done > "$tmp"
mv "$tmp" "$anchor"
echo "rebuilt $anchor from ${#pubs[@]} canonical keys ($RA_DIR)"

# install.sh's curl-pipe-bash bootstrap fetches only itself over the network,
# so it can't read the sibling allowed_signers file at that point — the same
# content is embedded directly. RELEASE_ALLOWED_SIGNERS is single-quoted
# (install.sh) specifically so this can span multiple lines with no escaping.
content="$(cat "$anchor")"
python3 - "$HERE/install.sh" "$content" <<'PYEOF'
import re
import sys

path, content = sys.argv[1], sys.argv[2]
src = open(path).read()
if "'" in content:
    sys.exit("ERROR: canonical key content contains a literal single quote — "
              "can't safely embed it in install.sh's single-quoted constant.")
new, n = re.subn(r"RELEASE_ALLOWED_SIGNERS='.*?'", f"RELEASE_ALLOWED_SIGNERS='{content}'",
                  src, count=1, flags=re.DOTALL)
if n != 1:
    sys.exit("ERROR: RELEASE_ALLOWED_SIGNERS='...' not found in install.sh")
open(path, 'w').write(new)
PYEOF
echo "synced install.sh's embedded RELEASE_ALLOWED_SIGNERS"
