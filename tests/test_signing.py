#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Unit test for coldspot's release-signing wiring (docs/RELEASE-SIGNING.md).

coldspot-update is now a thin wrapper over the vendored sutra_update.py
(UNIFY.md Wave A #1) -- the trust-chain edge cases (tampered artifact,
unsigned-fails-closed, unarmed-degrades-hash-only) are exhaustively covered
once, in sutra's own tests/unit_update.py, not re-derived per pill. What
THIS test pins is coldspot-specific: the shipped anchor's shape, and that
pill="coldspot" actually produces the right principal/namespace
("coldspot"/"coldspot-release") when it reaches ssh-keygen -- a real
throwaway (non-hardware) ed25519 key proves the roundtrip. Skips (not
fails) if ssh-keygen is unavailable. Exit 0 = pass.
"""
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(HERE, "src", "share", "coldspot", "lib"))
import sutra_update as su  # noqa: E402

PILL = "coldspot"
NS = f"{PILL}-release"

if subprocess.run(["ssh-keygen", "-Y", "sign"], capture_output=True).returncode == 127:
    print("ssh-keygen not found — skipping signing tests")
    sys.exit(0)

# --- the shipped anchor is either the empty placeholder OR a well-formed,
# armed 4-key set — never partial, never malformed. Mirrors the shape check
# in .github/workflows/signing-sync.yml; this can't confirm the keys are the
# operator's actual canonical set (this test can't reach
# ~/.ssh/asuramaya-master), only that the anchor's shape is sane either way.
with open(os.path.join(HERE, "packaging", "release-signing", "allowed_signers")) as f:
    anchor_content = f.read()
if anchor_content.strip():
    anchor_lines = [ln for ln in anchor_content.split("\n") if ln.strip()]
    assert len(anchor_lines) == 4, (
        f"packaging/release-signing/allowed_signers is armed but has "
        f"{len(anchor_lines)} lines, expected exactly 4")
    print("shipped allowed_signers is armed with 4 keys OK")
else:
    print("shipped allowed_signers is the empty placeholder OK")

assert su.armed(os.path.join(HERE, "packaging", "release-signing", "allowed_signers")) == \
    bool(anchor_content.strip()), "sutra_update.armed() disagrees with the shape check above"
print("sutra_update.armed() agrees with the shipped anchor's state OK")

# --- roundtrip: pill="coldspot" must produce principal="coldspot",
# namespace="coldspot-release" all the way through verify_dir(). This is
# the one thing genuinely coldspot's own to pin -- the trust chain itself
# (tampered/unsigned/unarmed) is sutra's tests/unit_update.py's job.
with tempfile.TemporaryDirectory() as td:
    key = os.path.join(td, "k")
    subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C",
                    "test", "-f", key], check=True)
    with open(key + ".pub") as f:
        kt, blob, _ = f.read().split(None, 2)
    anchor = os.path.join(td, "allowed_signers")
    with open(anchor, "w") as a:
        a.write(f'{PILL} namespaces="{NS},pills-tag" {kt} {blob} test\n')

    work = os.path.join(td, "work")
    os.makedirs(work)
    art = os.path.join(work, f"{PILL}.tar.gz")
    with open(art, "wb") as f:
        f.write(b"artifact bytes")
    digest = subprocess.run(["sha256sum", art], capture_output=True,
                            text=True, check=True).stdout.split()[0]
    man = os.path.join(work, "SHA256SUMS")
    with open(man, "w") as f:
        f.write(f"{digest}  {PILL}.tar.gz\n")
    subprocess.run(["ssh-keygen", "-Y", "sign", "-n", NS, "-f", key, man],
                   check=True, capture_output=True)

    ok, why = su.verify_dir(work, "SHA256SUMS", "SHA256SUMS.sig", anchor, PILL, True)
    assert ok and "signature" in why, f"expected pass, got ({ok}, {why!r})"
    print("verify_dir(): coldspot principal/namespace roundtrip accepted OK")

    # wrong namespace must fail -- catches a typo'd pill= wiring mistake,
    # not a re-test of ssh-keygen's own enforcement
    ok, why = su.verify_dir(work, "SHA256SUMS", "SHA256SUMS.sig", anchor,
                            "not-coldspot", True)
    assert not ok, f"expected principal mismatch to fail, got ({ok}, {why!r})"
    print("verify_dir(): wrong principal rejected OK")

print("release-signing verification OK")
