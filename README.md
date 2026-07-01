# coldspot

Keep a hotspot cold. A metered link is **cold by default**: coldspot caps total
speed to a smooth pipe, gives the task you care about priority *within* it, and
attributes every byte to the app that spent it — so one bad pull, heavy page, or
runaway agent swarm can't blow your data budget. It's protection against your own
sloppy usage, applied automatically the moment you're on a metered network.

It's the network sibling of [phanspeed](https://github.com/asuramaya/phanspeed):
a daemon that owns the truth, a verb CLI over it, and a GNOME pill on top. Where
phanspeed dials watts and EPP, coldspot governs **bandwidth**, a **data budget**,
and a **stance** — and tells you, in depth, where the data went.

```
coldspot status            # MB used, budget, stance, top talkers
coldspot budget 500        # cap this session at 500 MB; the pill heats up as you near it
coldspot siege             # only the active task talks; everything else is dropped
coldspot run -- rsync ...  # launch a job as *the* active task
coldspot limit 1mbps       # hard system-wide egress cap; spend the trickle wisely
coldspot uncap firefox     # warm a task: full speed even while everything's cold
coldspot open              # panic release — lift all throttling/siege
coldspot link              # per-interface link health: signal, rate, channel, loss
coldspot aim wlan0         # live signal meter for positioning an antenna
coldspot stabilize auto    # smooth a weak/lossy link (ack-filter + download AQM)
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

## Link health — the second axis
A link betrays you two ways: it can be **scarce** (metered, capped) or **bad**
(weak, lossy, fading). `cold` governs the first; **`stabilize`** handles the
second. coldspot senses layer 1/2 — signal, PHY rate, channel, loss, fades — per
wifi interface:

| verb | what it does |
|------|--------------|
| `coldspot link` | per-interface board: signal + bar, band/channel, PHY rate, loss %, power-save, health score, and which link is active |
| `coldspot aim [iface]` | live signal meter (dBm + rate, ~2×/s) for positioning an antenna — move it, watch `best` climb, tape it down |
| `coldspot stabilize auto` | cap just under the link's *measured* ceiling, thin ACKs, shape the download (IFB + CAKE) so it stops collapsing into multi-second latency under load; power-save off. `auto` sizes the cap from the live PHY rate so it never cripples a healthy link |

`coldspot report` also keeps a per-connection reliability history — average/min
signal and how often each link *dropped* — so a snapshot ("this link is stronger")
can be checked against the truth ("...but it fades 20× as often").

## How it works
Two halves behind one `status.json` seam:

- **Meter** (`coldspotd`) — measures and attributes via a `cgroup/skb` eBPF core
  (`bpf/coldspot.bpf.c`) that accounts per-app/per-destination and enforces the
  verdict in one in-kernel pass; it falls back to `/proc/net/dev` + systemd IP
  accounting when the core isn't loaded. It also keeps an hourly SQLite
  time-series, watches the NetworkManager connection to auto-govern on roam, and
  forecasts/flags anomalies. The core builds with only `clang` + `bpftool`
  (vendored helpers, no libbpf-dev, no Go).
- **Enforce** (`coldspot-stance`, root) — the only privileged piece: the **CAKE**
  shaper (the smooth speed cap), the nft DSCP marking that gives warmed tasks the
  priority tin, the eBPF `cold`/`siege` verdict + `critical` safe-list, and the
  `coldspot.slice` cgroup that holds warmed tasks.

Cold is a capped pipe with priority inside it: warmed tasks (`uncap`/`run`) + DNS
ride CAKE's latency tin, bulk gets the leftover, connectivity-critical services
are never throttled, and nothing exceeds the cap. The CLI and GNOME pill only
read `status.json`, so the kernel details stay below the seam.

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
**v0.3.0 — the link-aware axis** adds layer-1/2 sensing on top of v0.2.0: `coldspot
link` / `aim` / `stabilize`, a per-connection signal + fade history, and an
adaptive shaper that follows the RF. The v0.2.0 governance + analysis stack:

- **Govern** — `cold` auto-engages on metered links: a smooth CAKE speed cap with
  warmed tasks + DNS prioritized inside it, a never-throttle floor for critical
  connectivity, and a panic `coldspot open`. `coldspot limit <rate>` sets a hard
  cap by hand; `coldspot uncap <app>` warms a task into the priority lane.
- **Attribute** — per-app *and* per-destination, with the ↑/↓ split, pre-existing
  connections resolved by name (no more `?`), and hostnames from a passive DNS
  snoop.
- **Analyse** — `coldspot top` (live ↑/↓), `coldspot report` (by connection/app
  over day/week/month, from a SQLite time-series), `coldspot history`/`ledger`, a
  budget **cap-ETA forecast**, and **learned anomaly detection** that flags an app
  blowing past its own baseline.
- **Cockpit** — the GNOME pill surfaces all of it and is tappable: stance, warm a
  task, set a cap, and desktop notifications when the link goes cold or an app
  misbehaves.

Deferred: explicit per-app `cap <app> <rate>` and a hard ingress download cap.

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
