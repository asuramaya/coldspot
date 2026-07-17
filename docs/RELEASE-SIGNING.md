# Release signing

Status: **mechanism built, not yet enforcing.** `release-signing/allowed_signers`
(and its `install.sh`-embedded twin, `RELEASE_ALLOWED_SIGNERS`) are currently
empty — no signing key has been provisioned. Until one is: `install.sh`'s
curl-pipe-bash bootstrap degrades to sha256-only with a printed warning;
`coldspot-update` (the unattended daily auto-updater) refuses to install
anything at all. The moment a real key exists in both places and a release
ships a matching `coldspot.tar.gz.sha256.sig`, verification becomes mandatory
and fail-closed automatically — no further code changes needed.

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

## One-time setup (maintainer, needs the FIDO2 key attached)

```sh
# Sign with the fleet's already-enrolled master identity (release-signing/
# id_ra_master_N.pub from rotten-apple) rather than minting a coldspot-only
# key — one hardware ceremony, reused everywhere. Populate the trust anchor
# that ships in the repo and gets pinned on every install:
echo "coldspot-release $(cat /path/to/id_ra_master_N.pub)" \
  > release-signing/allowed_signers

# install.sh's curl-pipe-bash bootstrap only ever fetches ONE file (itself),
# so it can't read the sibling allowed_signers file — the same line has to be
# embedded directly in install.sh's RELEASE_ALLOWED_SIGNERS constant too. Keep
# both in sync on every rotation.
sed -i "s|^RELEASE_ALLOWED_SIGNERS=.*|RELEASE_ALLOWED_SIGNERS=\"$(cat release-signing/allowed_signers)\"|" \
  install.sh
```

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
ssh-keygen -Y verify -f release-signing/allowed_signers \
  -I coldspot-release -n coldspot-release \
  -s coldspot.tar.gz.sha256.sig < coldspot.tar.gz.sha256
```

Exit 0 = valid signature from the pinned principal, over exactly those
checksum bytes. Anything else is a hard failure. Both `bin/coldspot-update`
and `install.sh`'s bootstrap:

1. Check whether `release-signing/allowed_signers` (or, for install.sh, the
   embedded `RELEASE_ALLOWED_SIGNERS`) has any real key line — blank/absent
   means no key has been provisioned yet; each path follows its own policy
   above.
2. If a real key is present: require a `coldspot.tar.gz.sha256.sig` asset on
   the release. Missing asset, or a signature that doesn't verify against the
   pinned principal → abort, no install.
3. Independently, the sha256 in the (now-authenticated) manifest must still
   match the downloaded tarball — the signature covers the manifest, this
   step binds the manifest to the actual bytes being installed.
