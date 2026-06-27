# coldspot BPF core (v1)

`coldspot.bpf.c` is the kernel half of v1: a single `cgroup/skb` program that
meters per-app bytes **and** enforces the siege verdict in one pass. It replaces
the systemd-IPAccounting reader in `bin/coldspotd`; everything above the
`status.json` seam (CLI, panel) is untouched.

## Why this shape
- **Attribution + enforcement are the same program.** `verdict()` increments the
  per-cgroup counter, then (in siege) returns `0` to drop anything not in the
  allowlist. OpenSnitch keeps verdict and accounting separate; here they share
  one attach point.
- **cgroup id == app identity.** Apps already live in per-app cgroups
  (`app.slice/app-*.scope`), so attribution is passive — nothing to launch or move
  for *measuring*. Cgroups are only touched to *enforce* siege (`coldspot.slice`).
- **Ingress has no pid (softirq); cgroup id still identifies the app**, so RX
  attribution survives where pid-based tools lose it.

## Maps (the userspace API)
| map | dir | meaning |
|-----|-----|---------|
| `usage`  | kernel → user | `cgroup_id → {rx, tx}` live accountant |
| `flows`  | kernel → user | LRU `(cgroup_id, remote ip, port, proto) → {rx, tx}` per-destination |
| `policy` | user → kernel | one slot: `0 open / 1 lean / 2 siege` |
| `allow`  | user → kernel | `cgroup_id → 1` permitted in siege |

`flows` is parsed from IPv4 + TCP/UDP via `bpf_skb_load_bytes` (runtime offsets,
no direct-access bounds checks). The remote endpoint is `daddr:dport` on egress,
`saddr:sport` on ingress, so both directions land on one key. IPv6 is a TODO;
naming the IPs needs the DNS-answer snoop (next tier).

`coldspotd` polls `usage`, resolves `cgroup_id` to a name via the cgroupfs inode
(`app-gnome-firefox-1234.scope` → `firefox`), writes `status.json`; on
`coldspot stance siege` it sets `policy[0]=2` and fills `allow` from
`coldspot.slice`.

## Build + load — only `clang` + `bpftool`, no Go, no libbpf-dev
The core vendors its handful of helpers (`coldspot_helpers.h`, IDs pulled from
`vmlinux.h`), so it builds with just clang and the kernel's own BTF. The loader
is `bin/coldspot-bpf`, which drives the whole lifecycle through `bpftool` —
nothing to compile or download beyond the object itself.

```sh
coldspot-bpf build     # bpftool dumps local BTF -> vmlinux.h; clang -> coldspot.bpf.o
sudo coldspot-bpf load # loadall + pin under /sys/fs/bpf/coldspot, attach to cgroup root (multi)
```

`coldspotd` then reads the pinned `usage` map via `bpftool map dump -j`, and
`coldspot stance siege` writes `policy`/`allow` via `bpftool map update`. The
`multi` attach lets coldspot coexist with systemd's own cgroup accounting
program instead of replacing it.

A Go (cilium/ebpf) or C (libbpf-skeleton) loader remains an option if you later
want ring buffers or per-packet events, but it is not required and would add a
toolchain/download the bpftool path avoids.

## Known edges
- `docker0`/DNAT attributes to the container's cgroup, not the process inside it.
- Per-destination ("what is firefox talking to") needs a second `flows` map keyed
  by `(cgroup_id, dst, port)` plus a DNS-answer snoop to turn IPs into hostnames.
- Loader needs `CAP_BPF` + `CAP_NET_ADMIN`; it runs as the root system service.
