# Releasing coldspot

How a version becomes a signed release. The trust chain itself is described in
[RELEASE-SIGNING.md](RELEASE-SIGNING.md); this is the running order.

Two people are involved and only one of them can finish it. A maintainer prepares and tags.
The operator signs, by hand, with a physical FIDO2 key. No automation can stand in for that
step, and the signing key never goes near CI.

## 1. Prepare

Bump `packaging/VERSION`. It's the one version constant; `release.yml` asserts it matches the tag.

Write the `CHANGELOG.md` entry for the release. Small, focused releases are easier to sign off
on than a pile of unrelated changes.

Run the checks:

```bash
make check          # lint, py_compile, node --check, unit + contract tests
make check-sutra     # the vendored sutra spine matches canonical, byte for byte
make smoke           # boot the daemon against a fake iface, assert status.json shape
make attack          # fuzz the control socket adversarially (no root)
```

`check-sutra` failing on freshness means the shared spine moved and coldspot hasn't caught up.
Re-vendor before releasing rather than after.

## 2. Tag and publish

```bash
git tag vX.Y.Z && git push origin vX.Y.Z
```

CI then builds `coldspot.tar.gz` and `coldspot.tar.gz.sha256`, and publishes them unsigned. It
signs nothing, and that's deliberate: if CI could sign, then anyone who compromised the workflow
or the account could sign whatever they pushed, and the anchor would be protecting nothing.

coldspot has been armed since v0.5.0, so **every release from here on must be sealed before
anyone relies on it**. An armed client refuses an unsigned release outright, and it's right
to. Don't tag unless the operator is available to sign shortly after.

## 3. The operator seals it

The operator verifies the published bytes, signs the checksum manifest offline with the FIDO2
key, and uploads the detached signature:

```bash
ssh-keygen -Y sign -f /path/to/id_ra_master_N.pub -n coldspot-release coldspot.tar.gz.sha256
gh release upload vX.Y.Z coldspot.tar.gz.sha256.sig
```

This runs through the family's seal desk in practice, which derives its queue from published
releases and shows anything published without a `.sig` as awaiting the seal.

## Rules that don't bend

* **A sealed release is never re-cut.** If something is wrong with it, the fix is the next
  version. Re-cutting breaks every copy that already verified it.
* **The signing key never enters CI**, in any form, for any reason.
* **`make sync-signers` is not part of day-to-day dev.** It rebuilds the trust anchor from the
  canonical keys and is only ever run in the same act as a signing ceremony. See the
  sequencing rule in [RELEASE-SIGNING.md](RELEASE-SIGNING.md).

## When it goes wrong

**The tag assertion fails** means `packaging/VERSION` and the tag disagree. Fix it, delete the
tag, tag again.

**A client reports "armed but release is unsigned"** means the release was published and never
sealed. Nothing is broken in the artifact; it needs the operator's signature uploading.
