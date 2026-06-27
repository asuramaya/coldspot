// SPDX-License-Identifier: GPL-3.0-or-later
// coldspot.bpf.c — the v1 kernel core: one cgroup/skb program that BOTH meters
// per-app bytes AND enforces the siege verdict in a single pass.
//
// Attach (userspace, e.g. cilium/ebpf or libbpf):
//   coldspot_egress  -> BPF_CGROUP_INET_EGRESS  on the cgroup-v2 root
//   coldspot_ingress -> BPF_CGROUP_INET_INGRESS on the cgroup-v2 root
//   coldspot_connect -> BPF_CGROUP_INET4_CONNECT (names cgroups by comm)
//
// Userspace reads `usage` (per-cgroup rx/tx), writes `policy` (stance) and
// `allow` (cgroup -> permitted). This file is the v1 source of truth that
// replaces coldspotd's systemd-accounting reader; the status.json seam above
// it is unchanged. Build is wired in bpf/README.md.
#include <vmlinux.h>
#include "coldspot_helpers.h"  // vendored: builds without libbpf-dev

#define STANCE_OPEN  0
#define STANCE_LEAN  1
#define STANCE_SIEGE 2

struct bytes { __u64 rx; __u64 tx; };

// per-cgroup byte accountant — keyed by cgroup id (== cgroupfs inode)
struct {
  __uint(type, BPF_MAP_TYPE_HASH);
  __uint(max_entries, 4096);
  __type(key, __u64);
  __type(value, struct bytes);
} usage SEC(".maps");

// per-destination breakdown — "which app talked to which remote endpoint".
// LRU so it self-evicts; 16-byte key, no padding holes (stable for lookups).
struct flow_key {
  __u64 cg;     // cgroup id (the app)
  __u32 ip;     // remote IPv4, network byte order (as on the wire)
  __u16 port;   // remote service port, host order
  __u16 proto;  // IPPROTO_TCP / IPPROTO_UDP
};
struct {
  __uint(type, BPF_MAP_TYPE_LRU_HASH);
  __uint(max_entries, 8192);
  __type(key, struct flow_key);
  __type(value, struct bytes);
} flows SEC(".maps");

// single-slot stance, written by userspace on `coldspot stance ...`
struct {
  __uint(type, BPF_MAP_TYPE_ARRAY);
  __uint(max_entries, 1);
  __type(key, __u32);
  __type(value, __u32);
} policy SEC(".maps");

// allowlist for siege: cgroup id -> 1. Userspace populates from coldspot.slice.
struct {
  __uint(type, BPF_MAP_TYPE_HASH);
  __uint(max_entries, 1024);
  __type(key, __u64);
  __type(value, __u8);
} allow SEC(".maps");

// per-destination accounting: parse IPv4 + TCP/UDP via skb_load_bytes (runtime
// offsets are fine through the helper — no direct-access bounds gymnastics).
static __always_inline void account_flow(struct __sk_buff *skb, __u64 cg,
                                         int egress) {
  if (skb->protocol != bpf_htons(ETH_P_IP)) return;  // IPv4 only (v2)
  __u8 vihl = 0, proto = 0;
  bpf_skb_load_bytes(skb, 0, &vihl, 1);
  __u32 ihl = (vihl & 0x0F) * 4;
  if (ihl < 20) return;
  bpf_skb_load_bytes(skb, 9, &proto, 1);
  if (proto != IPPROTO_TCP && proto != IPPROTO_UDP) return;

  __u32 saddr = 0, daddr = 0;
  __u16 sport = 0, dport = 0;
  bpf_skb_load_bytes(skb, 12, &saddr, 4);
  bpf_skb_load_bytes(skb, 16, &daddr, 4);
  bpf_skb_load_bytes(skb, ihl, &sport, 2);
  bpf_skb_load_bytes(skb, ihl + 2, &dport, 2);

  struct flow_key k = {.cg = cg, .proto = proto};
  k.ip   = egress ? daddr : saddr;                   // the remote endpoint
  k.port = egress ? bpf_ntohs(dport) : bpf_ntohs(sport);

  struct bytes *f = bpf_map_lookup_elem(&flows, &k);
  struct bytes z = {};
  if (!f) {
    bpf_map_update_elem(&flows, &k, &z, BPF_ANY);
    f = bpf_map_lookup_elem(&flows, &k);
    if (!f) return;
  }
  if (egress) __sync_fetch_and_add(&f->tx, skb->len);
  else        __sync_fetch_and_add(&f->rx, skb->len);
}

static __always_inline int verdict(struct __sk_buff *skb, int egress) {
  __u64 cg = bpf_skb_cgroup_id(skb);

  // account first — we want truth even for packets we are about to drop
  struct bytes *b = bpf_map_lookup_elem(&usage, &cg);
  struct bytes init = {};
  if (!b) {
    bpf_map_update_elem(&usage, &cg, &init, BPF_NOEXIST);
    b = bpf_map_lookup_elem(&usage, &cg);
    if (!b) return 1;
  }
  if (egress) __sync_fetch_and_add(&b->tx, skb->len);
  else        __sync_fetch_and_add(&b->rx, skb->len);
  account_flow(skb, cg, egress);

  // enforce: siege drops anything not in the allowlist (and not loopback)
  __u32 k = 0, *st = bpf_map_lookup_elem(&policy, &k);
  if (st && *st == STANCE_SIEGE) {
    if (skb->ifindex == 1) return 1;            // loopback
    __u8 *ok = bpf_map_lookup_elem(&allow, &cg);
    if (!ok) return 0;                          // drop: not the active task
  }
  return 1;
}

SEC("cgroup_skb/egress")
int coldspot_egress(struct __sk_buff *skb) { return verdict(skb, 1); }

SEC("cgroup_skb/ingress")
int coldspot_ingress(struct __sk_buff *skb) { return verdict(skb, 0); }

char LICENSE[] SEC("license") = "GPL";
