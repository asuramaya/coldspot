# Changelog

## 0.1.26
- Auto-govern (raichu phase B, task #17) — the cold-by-default payoff. The daemon
  now automatically enters `cold` whenever the active connection is metered and
  releases to `open` when it isn't, reusing the roam signal. A manual stance
  (including `coldspot open`) pauses auto-govern until the next roam; the safety
  floor (critical services + DNS/DHCP/NTP, v0.1.25) keeps connectivity alive
  throughout. ON by default (`auto_govern`), matching "cripple almost, only
  explicit uncapping." status.json gains `auto_govern` + `governed`; `coldspot
  status` shows the govern line. Validated live: on an unmetered link it stays
  open (governed=false) and does not throttle — the metered→cold engage will show
  on the next hotspot visit. Warm a task to keep it full-speed: `coldspot run` /
  `allow` (friendlier `uncap` next).

## 0.1.25
- Critical-traffic safety floor + panic open (raichu phase B, task #16) — the
  guardrail that must exist before cold can auto-engage. Cold now never throttles
  (a) DNS/DHCP/NTP by destination port, or (b) connectivity-critical *services*
  (NetworkManager, systemd-resolved, timesyncd, coldspotd, coldspot-update…)
  matched by cgroup id via a new BPF `critical` map the daemon fills each tick.
  So governance can't sever the machine's own connectivity or block its updates.
  Added `coldspot open` — a panic release that lifts all throttling/siege,
  enforce-first so it works even if the daemon is down. Verifier-validated on
  load; the critical map populates live (5 service cgroups registered on this
  box). Unit suite 30 -> 31.

## 0.1.24
- Forecast + learned anomaly detection (raichu phase D, task #24) — completes the
  analysis pillar. The daemon now projects a budget **cap ETA** at your session-
  average pace (status.json `budget.eta`; `coldspot status` shows
  "forecast: cap ~Tue 06:05"), and runs **learned anomaly detection** off the
  time-series: an app using far more today than its own daily baseline is flagged
  (e.g. "claude has used 1400 MB today — about 8x its usual 180 MB/day"),
  generalizing the seeding advisor. Needs a few days of history before it fires,
  so a fresh DB raises nothing. Tunable: `anomaly`, `anomaly_factor`,
  `anomaly_floor_mb`. Unit suite 27 -> 30.

## 0.1.23
- `coldspot report [today|week|month]` (raichu phase D, task #23) — the deep
  breakdown the time-series was built for. Reads the SQLite store (read-only) and
  rolls it up by connection and by app with the ↑/↓ split, so "where did the month
  go on Brick" is one command (claude ↑1800 MB, etc.). `--json` for scripting.
  Pure userspace over the DB the daemon fills. Verified end-to-end (daemon writer
  → CLI reader).

## 0.1.22
- Persistent time-series store (raichu phase D, task #21). The JSON ledger answers
  "today" but is shallow (14 days, no connection, no hour). The daemon now also
  writes an hourly per-(connection, app) rx/tx series to a SQLite DB
  (/var/lib/coldspot/coldspot.db) — the deep store `coldspot report` (next) will
  query for "where did the month go on Brick" and "what did claude upload last
  Tuesday". Per-app deltas now come from one shared `proc_deltas()` feeding both
  the JSON ledger and the series; the old JSON ledger is imported once on first
  run. 120-day retention, pruned on day rollover. Fully additive — the JSON path
  still powers status.json, and telemetry failures never take the daemon down.
  Unit suite 24 -> 27.

## 0.1.21
- `coldspot top` — a live, refreshing per-app ↑/↓ view (raichu phase D, task #22).
  The one-command answer to "what's burning my data right now" that had to be
  hand-rolled with ss + BPF sampling today. The daemon now computes per-app
  rx_bps/tx_bps (byte delta since the last attribution) and adds them to each
  talker in status.json; `coldspot top` sorts by live rate and shows ↑rate/↓rate
  next to ↑/↓ totals, refreshing every 2s (--once for a single frame). Pure
  userspace, reads the existing status seam. Unit suite 23 -> 24.

## 0.1.20
- NEW `cold` stance — the governance core (raichu phase B, task #15). Where siege
  drops everything outside the warmed task, cold *throttles* it: non-warmed egress
  runs through a BPF token bucket (the floor, default ~32 KiB/s, `cold_floor_bps`
  in the conf), while the warmed subtree (`coldspot allow`/`run`, the same target
  siege uses), loopback, and DNS stay full-speed. Egress only — an ingress packet
  has already crossed the metered link, so dropping it just causes retransmits.
  `coldspot cold` / `coldspot stance cold`. Falls open if the floor is unset (no
  black-holing on half-setup), and an nft `limit rate` fallback covers the
  no-bpf-core case.
  NOTE: this ships the *mechanism*; it does NOT auto-engage yet. The critical-
  traffic safety floor + panic open (task #16) lands before auto-govern (#17) is
  allowed to apply cold automatically on metered links. Verifier-validated on
  load (`make deploy`); built + compiled clean here.

## 0.1.19
- Direction split ↑/↓ end-to-end (raichu phase A, task #14). The BPF maps always
  tracked rx/tx separately but the daemon collapsed them into one number — so
  today's "is this upload or download?" needed a manual dig. Now talkers, the
  ledger, per-connection history, the systemd fallback, and status.json all carry
  rx_mb/tx_mb alongside the combined mb, and `coldspot status`/`ledger`/`history`
  render ↑up / ↓down. (claude reads as ↑1740 ↓66 at a glance.) The pre-split
  ledger schema still decodes. `mb` is retained everywhere for older pill builds.
  Unit suite 22 -> 23.

## 0.1.18
- Name connections that predate the core load (v0.2.0 "raichu" phase A, task #12).
  The connect hook only fires on NEW connections, so anything already open when
  the eBPF core loads had no owner and showed as `?` in `coldspot flows` — exactly
  what forced a manual `ss` hunt to pin a 7 GB upload on `claude`. The daemon now
  resolves `?` flows the way `ss` does: remote tuple -> socket inode
  (/proc/net/{tcp,udp}{,6}) -> pid (/proc/*/fd) -> process name. The /proc scan is
  lazy (only when something is actually unknown). Verified live: the prior
  `? [2607:6bc0::10]:443` resolves to `claude`. Unit suite 18 -> 22.

## 0.1.17
- Advisor: coldspot now proactively flags data-hungry patterns instead of only
  reporting after the fact. The headline one is P2P seeding — a single app fanning
  sustained *upload* out to many distinct peers (the Transmission ~11 GB pattern
  caught live), which unlike a big download is usually unintended on a hotspot.
  Surfaced as a `⚠ advice` line in `coldspot status`, a new `coldspot advise`
  verb, and an `advice` array in status.json. It never changes your stance on its
  own; it suggests `coldspot siege`. Tunable in `/etc/coldspot.conf` (`advise`,
  `advise_tx_mb`, `advise_peers`).
- `flows` entries now carry `tx_mb` (upload alone) alongside `mb` (rx+tx), so the
  advisor can separate seeding from downloading. Unit suite 15 -> 18 tests.

## 0.1.16
- Per-connection history. The daemon now attributes every interface delta to the
  active NetworkManager connection and keeps daily + monthly rollups per network,
  so `coldspot history` answers "Brick vs home, today and this month" (metered
  links flagged). The budget still counts only the metered link. Persisted to
  `/var/lib/coldspot/history.json` (90 days / 24 months, pruned).
- Persistent attribution ledger. Live talkers/flows reset on every roam and core
  reload, so "what ate today's data" was unanswerable after the fact. The daemon
  now delta-accumulates per-app bytes from `proc_usage` into a daily ledger that
  survives both — `coldspot ledger` shows today's top apps. Resets (a cleared
  map after a roam) are counted as a fresh delta, never negative; the first read
  after start/roam primes the baseline instead of back-filling. Persisted to
  `/var/lib/coldspot/ledger.json` (14 days, pruned).
- status.json gains `history` (per-connection today/month) and `ledger` (today's
  top apps); the smoke test locks both into the seam. Unit suite 11 -> 15 tests
  (ledger delta/reset, prune bounds, history summary).

## 0.1.15
- Reconcile attribution on roam. The BPF core gates by ifindex, but metered-ness
  is per-CONNECTION and the same wifi adapter carries both Brick (metered) and
  home (unmetered) — so after roaming, talkers/flows kept showing the previous
  network's bytes and disagreed with the connection-gated session/day totals.
  The daemon now watches the NetworkManager connection and, on a change, clears
  the attribution maps (usage, proc_usage, flows) so per-app/per-dest bytes track
  only the current connection. policy/siege/cfg/dns are left intact. This settles
  the "some of that was actually on the other wifi" confusion and is the footing
  for per-connection history.

## 0.1.14
- Tooling: `make deploy` is now the single local-iteration ritual — it runs the
  smoke test FIRST, then installs the binaries (loader included), rebuilds the
  eBPF object, and reloads the core in the order that makes new programs attach,
  only restarting pieces that were already running. Codifies the deploy steps
  that were easy to half-do by hand (a stale loader silently never attaches the
  new programs; a daemon shipped without smoke crashes).
- Tests: added a BPF↔daemon map-layout contract test. It parses the `flow_key`
  struct out of `coldspot.bpf.c` and round-trips a synthetic `flows` row through
  the daemon's real decoder (v4 + v6), so an offset drift between the kernel
  struct and `read_flows()` fails in `make check` instead of decoding garbage on
  the user's machine. Unit suite is 7 -> 10 tests.

## 0.1.13
- Pill now supports GNOME Shell 49 and 50. The metadata only claimed 45-48, so on
  GNOME 50 the shell marked the extension OUT OF DATE and never loaded it (the
  pill never appeared after login). The extension API is unchanged since 45.

## 0.1.12
- Meter by metered CONNECTION, not interface. The same wifi adapter carries both
  Brick (metered) and home/other (unmetered) networks, so the per-interface
  counter lumped them together (a big unmetered download inflated the "metered"
  total). The daemon now re-reads NetworkManager's metered flag live and only
  accumulates session/day/budget while the active connection is metered; status
  shows the connection name. Also fixes the stale `metered False` display.

## 0.1.11
- DNS name cache now expires (task 6): IP->host entries drop after 30 min if not
  re-seen, so a recycled IP can't keep a stale hostname.
- `lean` stance pauses a fuller default hog set (packagekit, snapd, fwupd-refresh,
  unattended-upgrades), overridable via `lean_hogs` in /etc/coldspot.conf.
- Deferred (need provisioning/decision): GPG-signed releases (releases are
  sha256-over-HTTPS today) and optional .deb packaging.

## 0.1.10
- Per-process flows (task 5): flows are keyed by process (comm) instead of
  cgroup now — `curl -> github.com:443`, `chronyd -> ...:123/udp` — reusing the
  socket-cookie->comm map. Unconnected UDP (STUN etc.) is attributed via new
  cgroup/sendmsg4+6 hooks. Connections that predate the core load show as `?`
  (no connect hook fired); DNS-over-IPv6 transport capture is a known remainder.

## 0.1.9
- Accounting + siege now apply only to the metered link (task 2). The daemon
  writes the metered ifindex into a `cfg` BPF map; the core ignores and passes
  traffic on other interfaces, so talkers/flows match the budget instead of
  counting docker/ethernet/loopback. DNS capture stays global (it needs the
  loopback resolver-stub responses). Falls back to all-interfaces if unset.

## 0.1.8
- Fix siege (was broken end-to-end, now verified). Three bugs:
  1. The BPF allow-list matched the exact cgroup id of `coldspot.slice`, but
     `coldspot run` puts tasks in child scopes (`coldspot.slice/run-*.scope`)
     with different ids — so siege dropped the very task it should permit. Now
     matches by ANCESTOR id (`bpf_skb_ancestor_cgroup_id` at the slice's level),
     covering the whole subtree (run scopes + the `loose` cgroup for `allow`).
  2. The control socket was `0660 root:root`, so the user-run CLI got EACCES and
     `coldspot stance/budget/reset` silently failed. Socket is now `0666`
     (benign local toggles; enforcement still goes through the sudo helper).
  3. `coldspot stance` updated the meter before enforcing and exited if the
     daemon was unreachable — so enforcement never ran. Now enforces first,
     updates the meter best-effort.
- Verified live: a task in coldspot.slice keeps the network through siege while
  everything else is dropped; clean revert.

## 0.1.7
- Per-process attribution (thread 3): connect4/connect6 hooks record which
  process owns each socket (by cookie, in process context); `cgroup_skb` looks it
  up in both directions and sums bytes per process name into a `proc_usage` map.
  Talkers now split catch-all cgroups — the session's `org.gnome.Shell` service
  (60+ processes) resolves to the actual culprits (curl, chrome, …). `status`
  source shows `proc`, falling back to per-cgroup then systemd.
- Loader attaches the new connect hooks; unload detaches them.

## 0.1.6
- IPv6 flows (thread 2): the BPF flow parser handles IPv6 as well as IPv4. The
  flow key now holds a 16-byte address + family; `account_flow` parses the fixed
  40-byte v6 header (TCP/UDP; packets with extension headers are skipped). The
  daemon decodes both families and `coldspot flows` brackets bare IPv6
  (`[2606:4700::]:443`). AAAA records from the DNS snoop name v6 destinations too.

## 0.1.5
- Flows show hostnames, not just IPs (thread 1): the BPF ingress path captures
  DNS responses (UDP sport 53) into a ring map, and the daemon parses them —
  A/AAAA records, name-compression pointers — into an IP→host cache. Fully
  passive: zero extra DNS queries. `coldspot flows` now prints e.g.
  `github.com:443/tcp` where a name is known.
- `coldspot flows` shows only external destinations — loopback/private/multicast
  don't traverse the metered link, so they're filtered out as noise.
- BPF verifier note: the DNS capture length is masked (not clamped) so the
  compiler keeps the `> 0` guard the verifier requires for `bpf_skb_load_bytes`.

## 0.1.4
- Fix: the installer enabled the GNOME pill only via `gnome-extensions enable`,
  which silently no-ops when the running shell hasn't scanned a freshly installed
  extension — so the pill never appeared after the next login. Now also writes
  the `enabled-extensions` gsettings list directly (kast's approach), so it
  reliably turns on at next login.

## 0.1.3
- Pill is now an interactive control, not just a readout: live ↓/↑ rate in the
  header, a one-click stance switcher (open/lean/siege, current one dotted),
  top-5 talkers, and a reset-session action. Stances apply via the `coldspot`
  CLI (NOPASSWD helper / bpf policy).
- Daemon un-escapes systemd cgroup names (`hector\x2dvector` -> `hector-vector`)
  so app/talker names read cleanly in `status`, `flows`, and the pill.

## 0.1.2
- Fix: the installer's sudoers step used `install -m 0440 /dev/stdin ...`, which
  fails under sudo (`install: No such file or directory`) and aborted the install
  before the systemd/pill steps. Now writes the file directly, validates it with
  `visudo -cf`, then moves it into place — a malformed sudoers can never land.
- Perf: `coldspotd` no longer spawns `systemctl show` per running unit every few
  seconds when systemd IP accounting is off (the default). It checks once and
  skips — cutting idle CPU/battery cost. (BPF and enabled-accounting paths
  unchanged.)

## 0.1.1
- Fix: `coldspot-bpf` ignored the installer's `COLDSPOT_BPF_DIR`, so the eBPF
  core failed to build during install (`clang: no such file or directory:
  'coldspot.bpf.c'`). Source-dir resolution now honors the env var first, then
  falls back to the repo and installed layouts. v0 metering was unaffected; this
  restores the per-app/flows/fused-siege core and the `coldspot-bpf load` path.

## 0.1.0
First scaffold.

- `coldspotd`: v0 meter — `/proc/net/dev` interface total + systemd per-unit IP
  accounting for per-app talkers; control socket; atomic `status.json`.
- `coldspot`: verb CLI (`status`, `stance`, `siege`, `budget`, `allow`, `run`,
  `reset`) over the socket and the root helper.
- `coldspot-stance`: privileged enforcement — nft default-drop + cgroup-v2
  allowlist (`coldspot.slice`), hog pausing, metered/tailscale toggles.
- `bpf/coldspot.bpf.c` + `coldspot_helpers.h`: v1 kernel core — one `cgroup/skb`
  program metering and enforcing siege in a single pass. Vendored helpers so it
  builds with only clang + kernel BTF (no libbpf-dev). Verified to compile
  against the running kernel.
- `bin/coldspot-bpf`: bpftool-driven loader (build/load/unload/stance/allow) —
  no Go, no libbpf-dev. Pins maps+progs under bpffs, attaches `multi` to coexist
  with systemd's cgroup accounting.
- `coldspotd` reads the BPF `usage` map (preferred) and falls back to systemd;
  added live rx/tx rate and daily rollover to `status.json`.
- `coldspot-stance` bridges to the BPF core: siege flips the in-kernel `policy`
  slot and allowlists `coldspot.slice` when the core is loaded, else uses nft.
- Per-destination `flows` tier: BPF core parses IPv4 + TCP/UDP into an LRU
  `flows` map keyed by (cgroup, remote ip, port, proto); `coldspotd` decodes it
  and `coldspot flows` shows the per-app destination breakdown.
- Budget auto-escalation: `/etc/coldspot.conf` `auto_siege = on` makes the daemon
  drop to siege once when the session budget is exceeded; the latch clears on any
  manual stance/budget/reset. Config hot-reloads on those commands.
- GNOME panel pill, system service, install/uninstall, smoke test.
- Standardized install/update with kast + phanspeed: `curl | bash` bootstrap that
  fetches a checksum-verified release tarball (falls back to main with a warning),
  sudo re-exec, real-user GNOME pill install, version marker, permission verify.
- Auto-update: `bin/coldspot-update` (`--check`/`--json`) re-runs the verified
  installer in place; `coldspot-update.timer` checks daily; `coldspot update` /
  `coldspot check-update` verbs. `release.yml` publishes `coldspot.tar.gz` +
  `.sha256` on `v*` tags; `Makefile` + `.gitattributes` added.
