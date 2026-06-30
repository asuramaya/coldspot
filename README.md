# coldspot

Keep a hotspot cold. coldspot meters your metered link, attributes every byte to
the app that spent it, and — when you ask — drops everything on the wire except
the one task you actually care about.

It's the network sibling of [phanspeed](https://github.com/asuramaya/phanspeed):
a daemon that owns the truth, a verb CLI over it, and a GNOME pill on top. Where
phanspeed dials watts and EPP, coldspot dials a **data budget** and a **stance**.

```
coldspot status            # MB used, budget, stance, top talkers
coldspot budget 500        # cap this session at 500 MB; the pill heats up as you near it
coldspot siege             # only the active task talks; everything else is dropped
coldspot run -- rsync ...  # launch a job as *the* active task
coldspot limit 1mbps       # hard system-wide egress cap; spend the trickle wisely
coldspot uncap firefox     # warm a task: full speed even while everything's cold
coldspot open              # panic release — lift all throttling/siege
coldspot top               # live per-app ↑/↓ view (what's burning data right now)
coldspot history           # per-connection usage: Brick vs home, today + this month
coldspot report month      # deep breakdown by connection + app (today|week|month)
coldspot ledger            # what ate today's data (persists across core reloads)
coldspot advise            # proactive nudges, e.g. "transmission is seeding to 37 peers"
coldspot stance open       # back to normal
```

## Stances
| stance | what it does |
|--------|--------------|
| `open`  | normal; relies only on the NetworkManager metered flag |
| `lean`  | pause the known hogs (updates, snap, tailscale), keep browsing |
| `cold`  | **the metered default (auto).** Caps total egress to a smooth pipe (CAKE) and gives warmed tasks + DNS priority *within* it — so the app you care about stays responsive while a runaway pull/website/swarm gets only the leftover, and **nothing can exceed the cap**. The cap protects the budget; priority protects your task. Critical connectivity (NetworkManager/DNS/DHCP/NTP/updates) is never throttled. |
| `siege` | nftables default-drop + cgroup allowlist — only `coldspot.slice` survives |

On a metered link coldspot enters `cold` automatically. Warm the task you're
protecting — `coldspot uncap claude` / `coldspot run -- <cmd>` — and it rides the
priority lane; `coldspot open` lifts everything.

## How it works
Two halves behind one `status.json` seam:

- **Meter** (`coldspotd`) — measures and attributes. **v0** reads `/proc/net/dev`
  for the interface total and systemd per-unit IP accounting for per-app bytes —
  zero exotic deps. **v1** loads a `cgroup/skb` eBPF program
  (`bpf/coldspot.bpf.c`) that meters *and* enforces siege in one in-kernel pass;
  the daemon reads its `usage` map and prefers it over systemd automatically.
  The core builds and loads with only `clang` + `bpftool` (vendored helpers, no
  libbpf-dev, no Go) — see `bin/coldspot-bpf` and `bpf/README.md`.
- **Enforce** (`coldspot-stance`, root) — the only privileged piece: the nft
  table, the `coldspot.slice` cgroup, the metered flag, the hog pausing.

The CLI and the GNOME pill only ever read `status.json`, so the v0→v1 kernel
swap is invisible above the seam. See `bpf/README.md` for the kernel core.

## Why not just use OpenSnitch / vnstat?
coldspot takes OpenSnitch's *shape* — per-app, kernel-sourced attribution — but
fuses it with budget accounting and a hotspot-survival framing nothing on Linux
ships together. vnstat meters but can't attribute or block; OpenSnitch attributes
and blocks but has no budget; Android has the framing but isn't Linux. coldspot
is the union, in one pill. The novelty is the integration, not the primitives.

## Install
One line (verified release tarball, falls back to main with a warning) — the
same install/update/uninstall shape as kast and phanspeed:
```sh
curl -fsSL https://raw.githubusercontent.com/asuramaya/coldspot/main/install.sh | bash
```
Or from a checkout: `make install` (or `./install.sh`). It installs the daemon +
GNOME pill, builds the eBPF core from the local kernel BTF, and enables a daily
auto-update timer.

```sh
coldspot status              # the meter
coldspot update [--check]    # pull newer releases (also checked daily)
curl -fsSL https://raw.githubusercontent.com/asuramaya/coldspot/main/uninstall.sh | bash
```
Per-app talkers in v0 need systemd IP accounting (the installer prints the
one-liner). The v1 BPF core is built at install time — see `bpf/README.md`.

## Status
v0.1.0 — meter + budget + stance enforcement runnable; live rate + daily
rollover; budget auto-escalation to siege (`auto_siege` in `/etc/coldspot.conf`).
BPF core compiles against the running kernel and loads via `bpftool`; the daemon
reads its `usage` map (per-app) and `flows` map (per-destination, `coldspot
flows`) when present. Now also: per-connection history + a persistent per-app
ledger (`coldspot history`/`ledger`), and an advisor that flags P2P-seeding-style
sustained upload (`coldspot advise`). Roadmap: per-app intensity within `lean`;
surface history/ledger/advice in the pill.

## Develop
```sh
make check     # CI-equivalent static checks (lint, parse, unit + contract tests)
make smoke     # boot the daemon against a fake iface, assert status.json shape
make deploy    # smoke-test, then push bins+bpf+daemon into place and reload (sudo)
```
`make deploy` is the local-iteration ritual: it runs the smoke test first, then
installs the binaries (the loader included), rebuilds the eBPF object, and
reloads the core in the one order that makes new programs actually attach — only
restarting pieces that were already running. The unit suite includes a
BPF↔daemon map-layout contract test, so a change to the `flow_key` struct that
isn't mirrored in the decoder fails in `make check` rather than on your machine.

## License
GPL-3.0-or-later.
