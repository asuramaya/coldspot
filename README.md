# coldspot

[![release](https://img.shields.io/github/v/release/asuramaya/coldspot?sort=semver)](https://github.com/asuramaya/coldspot/releases/latest)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

Keep a hotspot cold. A metered link is **cold by default**: coldspot caps total
speed to a smooth pipe, gives the task you care about priority *within* it, and
attributes every byte to the app that spent it, so one bad pull, heavy page, or
runaway agent swarm can't blow your data budget. It's protection against your own
sloppy usage, applied automatically the moment you're on a metered network.

It's the network sibling of [phanspeed](https://github.com/asuramaya/phanspeed):
a daemon that owns the truth, a verb CLI over it, and a GNOME pill on top. Where
phanspeed dials watts and EPP, coldspot governs **bandwidth**, a **data budget**,
and a **stance**, and tells you, in depth, where the data went.

## Stances

| stance | what it does |
|--------|--------------|
| `open`  | normal; relies only on the NetworkManager metered flag |
| `lean`  | pause the known hogs (updates, snap, tailscale), keep browsing |
| `cold`  | **the metered default (auto).** Caps total egress to a smooth pipe (CAKE) and gives warmed tasks + DNS priority *within* it, so the app you care about stays responsive while a runaway pull/website/swarm gets only the leftover, and **nothing can exceed the cap**. Critical connectivity is never throttled. |
| `siege` | nftables default-drop + cgroup allowlist; only `coldspot.slice` survives |

On a metered link coldspot enters `cold` automatically. Warm the task you're
protecting (`coldspot uncap claude` / `coldspot run -- <cmd>`) and it rides the
priority lane; `coldspot open` lifts everything. coldspot also senses layer-1/2
link quality (signal, PHY rate, fades) as a second, independent axis, and keeps
its own per-network policy memory keyed by SSID rather than just reacting to
NetworkManager's metered flag. See [docs/USAGE.md](docs/USAGE.md) for the full
verb reference.

## Map

| | |
|---|---|
| Use it | [docs/USAGE.md](docs/USAGE.md) |
| Change it | [.github/CONTRIBUTING.md](.github/CONTRIBUTING.md) |
| Understand how it's built | [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) |
| Cut a release | [docs/RELEASING.md](docs/RELEASING.md) |
| See what changed | [CHANGELOG.md](CHANGELOG.md) |
| Report a vulnerability | [.github/SECURITY.md](.github/SECURITY.md) |

## Install

Two steps, deliberately: one needs root, one never does.

```sh
curl -fsSL https://raw.githubusercontent.com/asuramaya/coldspot/main/install.sh | sudo bash
coldspot-pill install    # as yourself, no sudo: adds the GNOME pill to YOUR account
```

`install.sh` is root-only and says so plainly if you forget `sudo`. It never
re-invokes itself, so there's exactly one privilege hop, always, and no
ambiguity about which account it's acting on. It installs the daemon and root
helpers, builds the eBPF core from the local kernel BTF, creates a `coldspot`
group and adds you to it (**log out and back in once**, or `newgrp coldspot`,
to pick it up), and installs the daily update timer **disabled**. Auto-update
is opt-in, see [docs/USAGE.md](docs/USAGE.md#updating).

Or from a checkout: `sudo make install`, then `make pill`.

```sh
coldspot status              # the meter
coldspot update [--check]    # pull a newer release now (manual; signature-verified)
curl -fsSL https://raw.githubusercontent.com/asuramaya/coldspot/main/uninstall.sh | sudo bash
coldspot-pill remove         # as yourself: the uninstaller doesn't touch your home
```

## Why not just use OpenSnitch / vnstat?

coldspot takes OpenSnitch's *shape*, per-app, kernel-sourced attribution, but
fuses it with budget accounting and a hotspot-survival framing nothing on Linux
ships together. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full
comparison and how the eBPF core and the control socket are built.

coldspot belongs to a family of small GNOME utilities that share a runtime
backbone, an update spine and a signed-release chain.

## License

GPL-3.0-or-later.
