# Release signing

Status: **armed, since v0.5.0.** `packaging/release-signing/allowed_signers` (and its
`install.sh`-embedded twin, `RELEASE_ALLOWED_SIGNERS`) carry all 4 canonical
`ra-master` hardware-key entries. Verification is mandatory and fail-closed for
every client installed from v0.5.0 onward: `install.sh`'s bootstrap and
`coldspot-update` both refuse to install anything whose release doesn't carry a
valid `coldspot.tar.gz.sha256.sig` from the pinned principal. There is no flag
to turn this back off; arming is one-way (see "Sequencing rule" below).

## Why this exists

The SHA256 check coldspot has always done proves a download wasn't corrupted
or truncated in transit. It proves nothing about *authenticity*: the checksum
comes from the same GitHub release it's checking, so a compromised release
asset carries its own "valid" checksum. Closing that gap needs a signature
from a key that lives outside GitHub's control entirely.

## Mechanism: SSH signatures, FIDO2 hardware key

Chosen over GPG/minisign: SSH signature verification (`ssh-keygen -Y sign` /
`-Y verify`) is already in every OpenSSH install, needs no new dependency on
either side, and — the reason for the FIDO2 requirement — supports **resident,
touch-required hardware keys** (`ecdsa-sk` / `ed25519-sk`). The private key
material never leaves the hardware token, and every signature needs a physical
touch. A compromised CI runner or build machine cannot forge a release; it
would need the physical key in hand. This is the same trust anchor the fleet's
`rotten-apple` master-identity ceremony established (Ra XVII, 2026-07-16) —
coldspot reuses that identity rather than minting its own.

**The signing key must never be provisioned into CI.** That's the whole point
— CI compromise is exactly the threat this defends against. Releases are
signed by hand, from the maintainer's machine, with the hardware key attached.

## Two enforcement policies, deliberately different

- **`install.sh`'s bootstrap** (`curl | sudo bash`, a one-time human-typed
  action): degrades to sha256-only with a warning while no key is provisioned.
  A first install already rests on the human's own choice to trust this repo
  right now over HTTPS — there's no standing trust to betray yet.
- **`coldspot-update`** (the daily, unattended, opt-in auto-update timer):
  refuses to install anything at all while no key is provisioned — "no
  signature, no key, or no ssh-keygen means no install," full stop. This path
  runs as root with nobody watching, which is exactly where a forged release
  would do the most damage, so it gets the stricter of the two policies.

## Identity vs role — principal is WHO, namespace is WHAT-FOR

Per `~/code/REPOS/RELEASE.md` (the fleet's release doctrine): **principal**
(`-I`) is the repo's stable identity (`coldspot`); **namespace** (`-n`) is
what a given signature authorizes (`coldspot-release`). Never pass the same
string for both — that welds identity to role and only works by accident.
`allowed_signers` line format (one line per key, exactly 4 when populated):

```
coldspot namespaces="coldspot-release,pills-tag" sk-ssh-ed25519@openssh.com <b64> ra-master-<n>
```

## One-time setup — `make sync-signers`, never hand-edit

```sh
make sync-signers
```

Rebuilds `packaging/release-signing/allowed_signers` **and** `install.sh`'s
embedded `RELEASE_ALLOWED_SIGNERS` twin from ALL 4 canonical pubkeys in
`~/.ssh/asuramaya-master/*.pub` (operator ruling 13ee52ce; set
`KEY_HOME=/path/to/asuramaya-master` to override). Always a full rebuild,
never an append — RA's first ceremony left 3 of 4 keys unpinned that way by
appending one at a time. Refuses to run unless it finds exactly 4 canonical
keys.

**Sequencing rule (do not skip):** `make sync-signers` populates the anchor.
Run it ONLY in the same act as cutting the maintainer's first signed release —
arming any earlier bricks `coldspot-update` against every existing unsigned
release. coldspot armed at v0.5.0; every release since has been signed. CI's
`sync-signers` check (`.github/workflows/signing-sync.yml`) now confirms the
anchor stays in sync with the canonical keys, not that it stays empty.

## Per-release signing (maintainer, needs the FIDO2 key attached + a touch)

```sh
# Sign the checksum manifest, not the tarball itself — coldspot.tar.gz.sha256
# already covers coldspot.tar.gz via its checksum entry, so signing it
# transitively covers the whole release, and it's tiny (one line).
ssh-keygen -Y sign -f /path/to/id_ra_master_N.pub -n coldspot-release \
  coldspot.tar.gz.sha256
# -> produces coldspot.tar.gz.sha256.sig

gh release upload vX.Y.Z coldspot.tar.gz.sha256.sig
```

## Verification (client side — already built)

```sh
ssh-keygen -Y verify -f packaging/release-signing/allowed_signers \
  -I coldspot -n coldspot-release \
  -s coldspot.tar.gz.sha256.sig < coldspot.tar.gz.sha256
```

Exit 0 = valid signature from the pinned principal, over exactly those
checksum bytes. Anything else is a hard failure. Both `src/bin/coldspot-update`
and `install.sh`'s bootstrap:

1. Check whether `packaging/release-signing/allowed_signers` (or, for install.sh, the
   embedded `RELEASE_ALLOWED_SIGNERS`) has any real key line — blank/absent
   means no key has been provisioned yet; each path follows its own policy
   above.
2. If a real key is present: require a `coldspot.tar.gz.sha256.sig` asset on
   the release. Missing asset, or a signature that doesn't verify against the
   pinned principal → abort, no install.
3. Independently, the sha256 in the (now-authenticated) manifest must still
   match the downloaded tarball — the signature covers the manifest, this
   step binds the manifest to the actual bytes being installed.
