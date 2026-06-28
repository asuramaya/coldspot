# Changelog

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
