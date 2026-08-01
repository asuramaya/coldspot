# Using coldspot

Everything the CLI, the daemon and the GNOME pill can do. If you just installed coldspot, run
`coldspot status` first. For the short version, see the [README](../README.md).

## Everyday commands

```
coldspot status            # MB used, budget, stance, top talkers
coldspot budget 500        # cap this session at 500 MB; the pill heats up as you near it
coldspot siege             # only the active task talks; everything else is dropped
coldspot run -- rsync ...  # launch a job as *the* active task
coldspot limit 1mbps       # hard system-wide egress cap; spend the trickle wisely
coldspot uncap firefox     # warm a task: full speed even while everything's cold
coldspot open              # panic release; lift all throttling/siege
coldspot stance open       # back to normal
```

## Stances

| stance | what it does |
|--------|--------------|
| `open`  | normal; relies only on the NetworkManager metered flag |
| `lean`  | pause the known hogs (updates, snap, tailscale), keep browsing |
| `cold`  | **the metered default (auto).** Caps total egress to a smooth pipe (CAKE) and gives warmed tasks + DNS priority *within* it, so the app you care about stays responsive while a runaway pull/website/swarm gets only the leftover, and **nothing can exceed the cap**. The cap protects the budget; priority protects your task. Critical connectivity (NetworkManager/DNS/DHCP/NTP/updates) is never throttled. |
| `siege` | nftables default-drop + cgroup allowlist; only `coldspot.slice` survives |

On a metered link coldspot enters `cold` automatically. Warm the task you're protecting
(`coldspot uncap claude` / `coldspot run -- <cmd>`) and it rides the priority lane;
`coldspot open` lifts everything.

## Link health

A link betrays you two ways: it can be **scarce** (metered, capped) or **bad** (weak, lossy,
fading). `cold` governs the first; `stabilize` handles the second. coldspot senses layer 1/2
(signal, PHY rate, channel, loss, fades) per wifi interface:

| verb | what it does |
|------|--------------|
| `coldspot link` | per-interface board: signal + bar, band/channel, PHY rate, loss %, power-save, health score, and which link is active |
| `coldspot aim [iface]` | live signal meter (dBm + rate, ~2×/s) for positioning an antenna: move it, watch `best` climb, tape it down |
| `coldspot stabilize auto` | cap just under the link's *measured* ceiling, thin ACKs, shape the download (IFB + CAKE) so it stops collapsing into multi-second latency under load; power-save off. `auto` sizes the cap from the live PHY rate so it never cripples a healthy link |
| `coldspot steer auto` | make the healthiest radio primary (automatic by default) |
| `coldspot bond` | aggregate independent uplinks into one pipe (ECMP), health-gated |

`coldspot report` keeps a per-connection reliability history too: average/min signal and how
often each link *dropped*, so a snapshot ("this link is stronger") can be checked against the
truth ("...but it fades 20× as often").

## Network memory

```
coldspot policy                  # Brick → cold, xfinitywifi → stabilize, home → open
coldspot here stabilize          # set the policy for the network you're on
coldspot remember Brick cold     # set it for a named network
coldspot forget xfinitywifi      # drop it (re-seeds next time you're on it)
```

See [ARCHITECTURE.md](ARCHITECTURE.md#network-memory-coldspot-owns-the-policy) for how the
seed-then-remember reconciler decides a new network's starting policy.

## Analysis

```
coldspot top               # live per-app ↑/↓ view (what's burning data right now)
coldspot history            # per-connection usage: Brick vs home, today + this month
coldspot report month       # deep breakdown by connection + app (today|week|month)
coldspot ledger             # what ate today's data (persists across core reloads)
coldspot advise             # proactive nudges, e.g. "transmission is seeding to 37 peers"
```

## The GNOME pill

`coldspot-pill install` (as yourself, no `sudo`) adds a Quick Settings tile: stance, a live
↑/↓ per app, tap to uncap/cap/block, and desktop notifications when the link goes cold or an
app misbehaves. Wayland can't hot-reload a running shell's extension JS, so a fresh install or
update needs either a logout/login or `Extensions.ReloadExtension` over D-Bus. `coldspot-pill`
tries the latter automatically and tells you plainly which one actually happened.

## Updating

```
coldspot update [--check]   # pull a newer release now (manual; signature-verified)
```

Auto-update is **opt-in**: it's a root process running unattended, so it stays off until you
set `auto_update = on` in `/etc/coldspot.conf` and enable the timer
(`sudo systemctl enable --now coldspot-update.timer`). It refuses to install anything unless
the release's checksum manifest carries a valid SSH signature against the pinned principal.
See [RELEASE-SIGNING.md](RELEASE-SIGNING.md).

## Troubleshooting

**Per-app attribution shows nothing, or says "no per-app data, load the bpf core."** The v1
eBPF core needs `clang` + `bpftool` and a kernel with BTF; without it coldspot falls back to v0.
v0 itself has two tiers: systemd per-unit IP accounting (per-app rx/tx, needs
`DefaultIPAccounting=yes` in `/etc/systemd/system.conf`; `install.sh` prints the one-liner to
turn it on) falling back further to `/proc/net/dev` (interface total only, no per-app split, but
always works). `coldspot-bpf load` (root) loads the eBPF core by hand; `coldspotd.service` also
does this automatically on every start, so a restart usually recovers it on its own.

**The CLI can't reach the daemon.** The control socket is `root:coldspot`, mode `0660`: you
need to be in the `coldspot` group, which `install.sh` adds you to. Log out and back in (or
`newgrp coldspot`) after a fresh install to pick the membership up.

**The pill doesn't show the latest layout after an update.** See the GNOME pill note above:
this shell may not support live reload yet (`Extensions.ReloadExtension` is declared but not
always implemented), so log out and back in once.

**Something feels off and you want a one-line verdict.** `coldspot-healthcheck` checks status.json
freshness, a control-socket ping, and the installed sutra modules against their own installed
anchors — exit 0 and a summary line when healthy, nonzero and the specific reason when not.
Read-only: it never restarts anything (`coldspotd.service` already does that on its own).
