#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Unit test for coldspot-update's release-signing verification
# (docs/RELEASE-SIGNING.md). Generates a throwaway (non-hardware) ed25519 key
# to prove the ssh-keygen -Y sign/verify roundtrip itself is wired correctly —
# verification doesn't care what backed the real signing key, only that a
# valid signature exists, so this is a faithful test of the mechanism the real
# FIDO2 key will use. Skips (not fails) if ssh-keygen is unavailable.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd)"

if ! command -v ssh-keygen >/dev/null 2>&1; then
  echo "ssh-keygen not found — skipping signing tests"
  exit 0
fi

fail() { echo "FAIL: $1" >&2; exit 1; }

# --- the shipped placeholder must be empty: no key provisioned yet ----------
[[ -s "$HERE/release-signing/allowed_signers" ]] \
  && fail "release-signing/allowed_signers must ship empty until a real key is provisioned — see docs/RELEASE-SIGNING.md"
echo "shipped allowed_signers is the empty placeholder OK"

# --- load coldspot-update's functions without running an update -------------
COLDSPOT_UPDATE_SOURCED=1 source "$HERE/bin/coldspot-update"

td="$(mktemp -d)"
trap 'rm -rf "$td"' EXIT

# --- has_signing_key() -------------------------------------------------------
: > "$td/empty"
has_signing_key "$td/empty" && fail "empty file must not count as a provisioned key"

printf '\n\n   \n' > "$td/blank"
has_signing_key "$td/blank" && fail "whitespace-only file must not count as a provisioned key"

has_signing_key "$td/does-not-exist" && fail "a missing file must not count as a provisioned key"
echo "has_signing_key() OK"

# --- verify_signature(): real roundtrip -------------------------------------
NS="coldspot-release"
keyfile="$td/id_test"
ssh-keygen -t ed25519 -N "" -C test -f "$keyfile" >/dev/null 2>&1

signers="$td/allowed_signers"
printf '%s %s\n' "$NS" "$(cat "$keyfile.pub")" > "$signers"

data="$td/data"
printf 'the exact bytes a checksum manifest would contain\n' > "$data"
ssh-keygen -Y sign -f "$keyfile.pub" -n "$NS" "$data" >/dev/null 2>&1
sig="$data.sig"

verify_signature "$data" "$sig" "$signers" "$NS" \
  || fail "a valid signature from the pinned key must verify"
echo "verify_signature(): valid signature accepted OK"

# tampered data must fail
tampered="$td/tampered"
printf 'the exact bytes a checksum manifest would contain\nEXTRA\n' > "$tampered"
verify_signature "$tampered" "$sig" "$signers" "$NS" \
  && fail "a signature over different bytes must not verify"
echo "verify_signature(): tampered data rejected OK"

# signature from a DIFFERENT (untrusted) key must fail against this allowed_signers
otherkey="$td/id_other"
ssh-keygen -t ed25519 -N "" -C other -f "$otherkey" >/dev/null 2>&1
otherdata="$td/data2"
printf 'the exact bytes a checksum manifest would contain\n' > "$otherdata"
ssh-keygen -Y sign -f "$otherkey.pub" -n "$NS" "$otherdata" >/dev/null 2>&1
othersig="$otherdata.sig"
verify_signature "$data" "$othersig" "$signers" "$NS" \
  && fail "a signature from an untrusted key must not verify"
echo "verify_signature(): untrusted key rejected OK"

# wrong namespace must fail (binds the signature to its intended use)
verify_signature "$data" "$sig" "$signers" "some-other-namespace" \
  && fail "a namespace mismatch must not verify"
echo "verify_signature(): namespace mismatch rejected OK"

echo "release-signing verification OK"
