# Changelog

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
