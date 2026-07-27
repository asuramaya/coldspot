# Security Policy

## Supported versions

coldspot is pre-1.0. Only the latest release receives fixes.

## Reporting a vulnerability

Please **do not** open a public issue for security problems. Use GitHub's private
vulnerability reporting instead: go to the repo's **Security** tab, then **Report a
vulnerability**.

You'll get an acknowledgement, and a fix or mitigation will be coordinated before any public
disclosure.

## What coldspot is, from a security point of view

coldspot runs a privileged root daemon and an eBPF core on your machine, so it has a wider
threat model than a purely userspace tool. What follows is a list of properties worth
understanding, because most were chosen deliberately and a few are honest limitations rather
than defences.

**The daemon is the only privileged actor, and there is no other path to root.** `coldspotd`
runs as root; the CLI and the GNOME pill never do, and never carry a `sudo` or passwordless-root
grant. The CLI talks to the daemon only over the control socket. If you find a code path that
lets the CLI or the pill act with elevated privilege outside that socket, it's a bug.

**The control socket is group-gated, not just filesystem-gated.** It's `root:coldspot`, mode
`0660`, so only root or a member of the `coldspot` group can connect at all. Every accepted
connection is checked again via `SO_PEERCRED`: a peer whose primary group is `coldspot` is
allowed, and anything else is a **default deny**. There's no fallback that trusts a peer it
couldn't positively verify.

**State files carry sensitive data and are never world-readable.** `status.json`, the ledger
and the SQLite time-series carry SSIDs, egress IPs, per-app usage and DNS-snooped hostnames.
They're written `root:coldspot`, mode `0640`. An earlier version of coldspot left these
world-readable, which amounted to a browsing-profile leak to any local user; that's now closed
and covered by a regression test.

**The daemon runs fully as root, not capability-scoped, and that's an open gap, not a hidden
one.** The v1 eBPF core's loader needs `CAP_BPF` and `CAP_NET_ADMIN`, and coldspot hasn't yet
split a capability-scoped worker off the main daemon to shed the rest of root. The systemd unit
sandboxes what it safely can (`NoNewPrivileges`, `ProtectHome=read-only`, `PrivateTmp`,
`RestrictSUIDSGID`, `RestrictAddressFamilies`, `RestrictRealtime`, `LockPersonality`) but
deliberately **not** `ProtectSystem=strict`, because the daemon has to write `/sys/fs/bpf`,
`/run/coldspot` and `/var/lib/coldspot`, and stronger confinement
(`ProtectKernelModules`/`MemoryDenyWriteExecute`/`RestrictNamespaces`) would break either the
BPF core or the privileged helpers it shells out to (`bpftool`/`nft`/`tc`/`nmcli`/`iw`/`curl`).
See [docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md) for the full sandboxing rationale.

**Names that come off the network are attacker-controlled, and only ever reach displays as
text.** Wi-Fi SSIDs are sanitized before they're stored or shown. DNS-snooped hostnames (the
BPF core captures DNS response payloads; userspace parses them into IP→host labels) are
**display-only**: a hostile access point can spoof a DNS answer to mislabel a destination in
`coldspot report`, but nothing in coldspotd makes an enforcement decision based on a hostname.
Enforcement is IP/cgroup/policy-based throughout.

**Installs and updates verify before they install.** `install.sh` and `coldspot update` fetch
over HTTPS and check the download against the release's published checksum manifest and that
manifest's SSH signature. A mismatch aborts. There is no fallback to the unreviewed `main`
branch on a fetch failure: a transient network hiccup, or an attacker interfering with the
release-asset request, fails closed with a clear message rather than quietly installing
something unverified as root.

**CI cannot sign a release.** The signing key is FIDO2 hardware in the maintainer's hand and
never enters GitHub Actions in any form. Releases are published unsigned and signed afterwards
by hand. If the workflow could sign, compromising the workflow or the account would be enough
to sign anything. See [docs/RELEASE-SIGNING.md](../docs/RELEASE-SIGNING.md).

**The trust anchor is fail-closed once armed, and coldspot has been armed since v0.5.0.** Every
release since has needed a valid signature; there is no flag to turn verification back off.

**Auto-update is opt-in.** It's a root process running unattended, so it stays off until you
explicitly set `auto_update = on` in `/etc/coldspot.conf` and enable the timer.

## Out of scope

`bpftool`, `nft`, `tc`, `nmcli` and `iw` are upstream-maintained; please report issues in those
tools to their own projects. The kernel's own eBPF verifier is the backstop against a malformed
`coldspot.bpf.c` object, not something coldspot re-implements.
