# Architecture

coldspot is two halves behind one `status.json` seam: a **meter** that measures and attributes
traffic, and an **enforcer** that acts on a stance. The CLI and the GNOME pill only ever read
that seam or send a command over the control socket; neither one knows anything about cgroups,
BPF maps, or nftables.

## Repo map

```
src/bin/          coldspot (CLI), coldspotd (daemon), coldspot-stance, coldspot-bpf (BPF loader),
                   coldspot-update, coldspot-pill (per-account installer), coldspot-healthcheck
src/bpf/          coldspot.bpf.c, coldspot_helpers.h, vmlinux.h (generated, not committed logic)
src/data/config/  coldspot.conf defaults
src/share/coldspot/lib/   vendored sutra*.py (private per-pill dir; a checkout's own analog of
                   $SHAREDIR/lib -- see Conventions, below, for why it has to sit here)
src/data/systemd/system/  coldspotd.service, coldspot-update.timer/.service
src/data/man/     coldspot.1, coldspotd.8
src/extension/    the GNOME Shell pill (coldspot@asuramaya)
packaging/        deploy.sh, sync-signers.sh, packages.txt, VERSION (the one version constant)
packaging/release-signing/  allowed_signers (the SSH-signature trust anchor)
tests/            smoke.sh, attack_socket.py, test_units.py, test_signing.py
docs/             this file, USAGE.md, RELEASING.md, RELEASE-SIGNING.md, CHANGELOG.md
```

## Meter: measuring and attributing

`coldspotd` (root) is the only privileged actor on the machine. It attributes bytes one of two
ways:

- **v1, the eBPF core** (`src/bpf/coldspot.bpf.c`): a `cgroup/skb` program that accounts per-app
  and per-destination bytes and enforces the stance verdict in the *same* kernel pass. This is
  the preferred source when it's loaded; see **The BPF core** below.
- **v0, the fallback**: `/proc/net/dev` plus systemd IP accounting, used when the core isn't
  loaded (no `clang`/`bpftool`, no kernel BTF, or a load failure). Coarser (no per-destination
  breakdown, weaker per-app resolution) but requires nothing beyond what `systemd` already
  ships.

The daemon also keeps an hourly SQLite time-series, watches the NetworkManager connection to
auto-govern on roam, and forecasts/flags anomalies against each app's own baseline.

## The BPF core

`coldspot.bpf.c` is a single `cgroup/skb` program that meters per-app bytes **and** enforces
the stance verdict in one pass. Attribution and enforcement share an attach point, unlike
OpenSnitch, which keeps them separate. Attribution is passive: apps already live in per-app
cgroups (`app.slice/app-*.scope`), so there's nothing to launch or move just to *measure*.
Cgroups are only touched to *enforce* siege (the `coldspot.slice` allowlist). Ingress has no
pid (it runs in softirq context), but the cgroup id still identifies the app, so RX attribution
survives where pid-based tools lose it.

**Maps** (the userspace API):

| map | dir | meaning |
|-----|-----|---------|
| `usage` | kernel → user | `cgroup_id → {rx, tx}` per-cgroup accountant |
| `proc_usage` | kernel → user | `comm → {rx, tx}` per-process (the preferred talker source) |
| `sk_proc` | internal | socket cookie → `{pid, comm}`, written by the connect hooks |
| `flows` | kernel → user | LRU `{cgroup, family, ip(16B), port, proto} → {rx, tx}` per destination (IPv4 + IPv6) |
| `dns` / `dns_head` | kernel → user | ring of captured DNS response payloads; userspace parses A/AAAA → IP→host |
| `policy` | user → kernel | one slot: `0 open / 1 lean / 2 siege / 3 cold` |
| `siege` | user → kernel | `{cgid, level}`, the survivor/warmed subtree; siege keeps (and cold un-throttles) any cgroup whose ancestor at `level` is `cgid`, so `coldspot.slice` and all its scopes |
| `throttle` | user → kernel | cold-stance egress token bucket `{tokens, last_ns, rate, burst}`; `rate` is the floor, `rate==0` fails open |
| `critical` | user → kernel | `cgroup_id → 1` for connectivity-critical services (NetworkManager, resolved, coldspot-update, etc.); cold never throttles these, plus DNS/DHCP/NTP by port |
| `cfg` | user → kernel | metered ifindex; when nonzero, accounting and siege/cold apply only to that link |

Programs: `cgroup_skb/egress` + `/ingress` (meter + verdict), `cgroup/connect4` + `connect6`
(record socket→process). The ingress program also captures DNS before the verdict runs, on
every interface (the loopback resolver-stub responses carry the records), while accounting
and siege/cold themselves are gated to the metered link via `cfg`.

**Cold** (the metered default) is siege's gentler sibling. Instead of dropping everything
outside the warmed subtree, it runs non-warmed **egress** through the `throttle` token bucket
(the floor) and passes the warmed subtree, loopback, and DNS at full speed. Ingress is never
dropped under cold: those bytes already crossed the metered link, so dropping them only causes
retransmits. `coldspot allow`/`run` warm a task under cold exactly as they spare one under
siege, because both stances key off the same `siege` map target.

**Build and load: only `clang` and `bpftool`, no Go, no `libbpf-dev`.** The core vendors its
own handful of helpers (`coldspot_helpers.h`, IDs pulled from `vmlinux.h`), so it builds with
just clang and the kernel's own BTF:

```sh
coldspot-bpf build      # bpftool dumps local BTF -> vmlinux.h; clang -> coldspot.bpf.o
sudo coldspot-bpf load  # loadall + pin under /sys/fs/bpf/coldspot, attach to cgroup root (multi)
```

`coldspotd` reads the pinned `usage` map via `bpftool map dump -j`; `coldspot stance siege`
writes `policy`/`allow` via `bpftool map update`. The `multi` attach type lets coldspot coexist
with systemd's own cgroup accounting program instead of replacing it. `coldspotd.service` runs
`coldspot-bpf load` as a non-fatal `ExecStartPre` on every start, boot and restart alike, since
bpffs pins never survive either. A missing toolchain or a load failure just leaves the core
unloaded, and the daemon falls back to v0.

**Known edges:** `docker0`/DNAT attributes to the container's cgroup, not the process inside
it. Per-destination naming needs the DNS-answer snoop (above) to turn IPs into hostnames; IPv6
flow parsing is a TODO. The loader needs `CAP_BPF` + `CAP_NET_ADMIN`; it runs as the root
system service, not a capability-dropped one (see **Standard exemptions**).

## Enforce

`coldspot-stance` drives three things per stance: the **CAKE** shaper (the smooth speed cap
under `cold`), the nft DSCP marking that gives warmed tasks the priority tin, and the
`coldspot.slice` cgroup that holds warmed tasks. `siege` additionally flips nftables to
default-drop with a cgroup allowlist. The daemon is the only thing that ever calls it; the
unprivileged CLI never invokes `coldspot-stance` or any privileged helper directly.

## The control socket: the group-socket model

The CLI never uses `sudo`. It sends a JSON command over the daemon's control socket, and the
daemon performs the operation:

- The socket is `root:coldspot`, mode `0660` (via `sutra.ControlServer`'s `socket_owner`).
  Anything not root and not a member of the `coldspot` group can't even connect.
- Every accepted connection is authorized again at the application layer via `SO_PEERCRED`:
  `_coldspot_authz(uid, gid)` allows root, allows a peer whose primary group is `coldspot`, and
  **default-denies** anyone it can't positively verify. There is no group it trusts by lookup
  failure.
- State files (`status.json`, the ledger, the SQLite time-series) are written `root:coldspot`,
  mode `0640`, group-readable so the CLI and pill can read them without a socket round trip,
  never world-readable (an earlier version of this had a browsing-profile leak; see
  [.github/SECURITY.md](../.github/SECURITY.md)).
- `install.sh` creates the `coldspot` group and adds the installing user to it. There is no
  passwordless-root grant anywhere in the install; the daemon is the only privileged actor,
  full stop.

`coldspotd.service` sandboxes what it can (`NoNewPrivileges`, `ProtectHome=read-only`,
`PrivateTmp`, `RestrictSUIDSGID`, `RestrictAddressFamilies`, `RestrictRealtime`,
`LockPersonality`) but deliberately **not** `ProtectSystem=strict`, because the daemon has to
write `/sys/fs/bpf`, `/run/coldspot`, and `/var/lib/coldspot`, and stronger confinement
(`ProtectKernelModules`, `MemoryDenyWriteExecute`, `RestrictNamespaces`, etc.) breaks either
the BPF core or the privileged helpers it shells out to (`bpftool`/`nft`/`tc`/`nmcli`/`iw`/`curl`).

## Network memory: coldspot owns the policy

"Metered" is the wrong word for a link that's free but fragile (weak public wifi). That's a
*quality* problem (`stabilize`), not an *economic* one (`cold`). coldspot doesn't just react to
NetworkManager's metered flag; it keeps its own persistent, per-network policy keyed by SSID.
A network it hasn't seen is **seeded** from two independent axes (NM-metered → `cold`, weak
signal → `stabilize`, else `open`), then remembered, so the NM flag is one seed, never the
master. The daemon owns the truth, including the policy; the CLI and pill just read it.
Attacker-controlled SSIDs are sanitized before they're stored or displayed: anything on the
air can advertise whatever name it likes.

## Why not just use OpenSnitch or vnstat?

coldspot takes OpenSnitch's shape, per-app, kernel-sourced attribution, but fuses it with
budget accounting and a hotspot-survival framing nothing else on Linux ships together. vnstat
meters but can't attribute or block; OpenSnitch attributes and blocks but has no budget;
Android has the framing but isn't Linux. coldspot is the union, in one pill. The novelty is the
integration, not the primitives.

## Conventions worth knowing before you edit

* Bash runs under `set -euo pipefail` and stays ShellCheck-clean. Exclusions are passed as
  `-e SC…` flags in the lint recipe, not an rc file: `--rcfile` only exists from shellcheck
  0.11.0, and ubuntu-latest ships older.
* One version constant: `packaging/VERSION`. Nothing else carries a literal version string.
* The daemon owns the truth. The CLI and pill only read `status.json` or send a socket command;
  neither one grows logic that belongs in `coldspotd`.
* Names that come off the network or a raw `/proc` read (SSIDs, `comm` strings) are untrusted
  and reach displays/logs as sanitized text only.
* `src/share/coldspot/lib/sutra*.py` are vendored byte-identical from the `sutra` repo, into a private
  per-pill dir rather than the shared bin dir (two pills vendoring identically-named files into
  the same `/usr/local/bin` make each other uninstallable; ruling `3e44bd95`). `make check-sutra`
  proves each copy: integrity is a hard failure, freshness is three-way (match, lag-warns, or
  drift-fails against canonical history) — the recipe itself is `sutra.mk` (vendored the same way
  as the code, under `src/share/coldspot/lib/sutra.mk` + its own `.version`/`.commit` anchor),
  `include`d from the root `Makefile`, not hand-maintained here; `check-vendored-path-all` (same
  file) proves the checkout-run resolution across all four sutra-importing binaries.
  `SUTRA_EXT_DIR` opts `pill.js` into the same integrity+freshness check as the `.py` modules.
  Every binary that imports sutra carries the canonical
  bootstrap preamble (see `sutra`'s `BOOTSTRAP.md`) right before the `import sutra` line, which
  locates the lib dir as `dirname(dirname(realpath(__file__)))/share/coldspot/lib` — relative to
  the binary's own location, never told a prefix. That is why the vendored copy has to live at
  `src/share/coldspot/lib/` and not somewhere more "natural" like `src/data/`: a binary run
  straight from the checkout sits at `src/bin/`, so `dirname(dirname(...))` lands on `src/`, not
  the repo root — the checkout's own analog of `$PREFIX` is `src/`, not `.`. Any other path here
  silently breaks `python3 src/bin/coldspot` run uninstalled, exactly the way it did the first
  time this moved (caught by CI reading green over a broken checkout — the staged-prefix test
  harnesses proved the layout resolves in general, not that the repo as it actually sits on disk
  does; `tests/smoke.sh`'s first check now runs a binary from the checkout in place to catch this
  class directly). Never hand-derive the path, re-vendor with `--bootstrap=coldspot` instead.
  `coldspotd` uses `sutra` directly: `ControlServer` is the control socket, `write_status()` is
  every atomic state write.
* `coldspot-healthcheck` (thin wrapper over `sutra.check_health`) proves what `check-sutra` can't:
  the vendored modules as actually INSTALLED at `$SHAREDIR/lib`, against their own installed
  `.version` anchors, plus status.json freshness and a control-socket ping. `check-sutra` only ever
  reads the dev-tree copy under `src/share/coldspot/lib/`; the machine runs whatever got installed,
  and an anchorless install dir is exactly how a mixed-version `sutra` sat undetected on a real
  machine before this check existed (`BOOTSTRAP.md`, ruling `3e44bd95`). A missing anchor means an
  install predating this check, not tampering — that's a third state, not a failure. Passive by
  design: it diagnoses and reports, never restarts anything (`coldspotd.service` already has
  `Restart=on-failure`).

## Standard exemptions

coldspot's declared departures from the family repo standard. Anything the standard asks for
and coldspot doesn't have is listed here. A gap that isn't in this table is a bug, not a
choice.

| Item | Why |
|---|---|
| daemon runs fully as root, not capability-dropped | the v1 BPF core and its loader need `CAP_BPF`/`CAP_NET_ADMIN`, and coldspot hasn't yet split a capability-scoped worker off the daemon. Tracked as future work, not a rejected idea; see the commented `AmbientCapabilities` line in `src/data/systemd/system/coldspotd.service` |
| `src/share/coldspot/lib/sutra_xen.py` is vendored but unused | no coldspot integration point yet -- `coldspot-update` adopted `sutra_update.py` (Pass 4), `sutra_xen.py` is Xen guest-surface specific and coldspot has no guest-surface concern |
| `extension.js` keeps `pill.js`'s `UpdateSurface`/`StatusWatcher`/`sendCmd`/menu-row helpers unadopted, using its own status-read + subprocess-CLI + polling shape instead | `PALETTE`/`CHIP`/`CHIP_ON`/`dataRow` collapsed to the vendored copy (Pass 4); adopting the rest is a real behavioral change (event-driven status watching, socket commands instead of CLI subprocess calls, an update-row UI addition) deliberately out of scope for a same-behavior dedup pass |
| no `.deb` yet | owed under a standing ruling, sized as its own milestone; a new artifact type needs its own verification and shouldn't ride a doc/CI/tree pass |
