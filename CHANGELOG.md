# Changelog

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
