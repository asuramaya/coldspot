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
#define STANCE_COLD  3   // metered default: throttle egress to a floor, warm tasks exempt

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
  char  comm[16];  // owning process (empty if unknown, e.g. unconnected UDP)
  __u8  ip[16];    // remote address: IPv4 in [0:4] (rest 0), or full IPv6
  __u16 port;      // remote service port, host order
  __u16 proto;     // IPPROTO_TCP / IPPROTO_UDP
  __u8  family;    // 4 or 6
  __u8  _pad[3];
};
struct {
  __uint(type, BPF_MAP_TYPE_LRU_HASH);
  __uint(max_entries, 8192);
  __type(key, struct flow_key);
  __type(value, struct bytes);
} flows SEC(".maps");

// Per-process attribution: a connect hook (process context) records which
// process owns each socket by its cookie; cgroup_skb (both directions) looks it
// up by cookie and sums bytes per process name. This splits catch-all cgroups
// (e.g. the session's org.gnome.Shell service holding 60+ processes).
struct procinfo { __u32 pid; char comm[16]; };
struct {
  __uint(type, BPF_MAP_TYPE_LRU_HASH);
  __uint(max_entries, 16384);
  __type(key, __u64);            // socket cookie
  __type(value, struct procinfo);
} sk_proc SEC(".maps");
struct {
  __uint(type, BPF_MAP_TYPE_HASH);
  __uint(max_entries, 4096);
  __type(key, char[16]);         // process comm
  __type(value, struct bytes);
} proc_usage SEC(".maps");

static __always_inline void record_proc(void *ctx) {
  __u64 cookie = bpf_get_socket_cookie(ctx);
  if (!cookie) return;
  struct procinfo pi = {};
  pi.pid = bpf_get_current_pid_tgid() >> 32;
  bpf_get_current_comm(pi.comm, sizeof(pi.comm));
  bpf_map_update_elem(&sk_proc, &cookie, &pi, BPF_ANY);
}

SEC("cgroup/connect4")
int coldspot_connect4(struct bpf_sock_addr *ctx) { record_proc(ctx); return 1; }
SEC("cgroup/connect6")
int coldspot_connect6(struct bpf_sock_addr *ctx) { record_proc(ctx); return 1; }
// unconnected UDP (sendto without connect — STUN, some DNS/QUIC) never hits
// connect4/6, so also record the owner on sendmsg.
SEC("cgroup/sendmsg4")
int coldspot_sendmsg4(struct bpf_sock_addr *ctx) { record_proc(ctx); return 1; }
SEC("cgroup/sendmsg6")
int coldspot_sendmsg6(struct bpf_sock_addr *ctx) { record_proc(ctx); return 1; }

static __always_inline void account_proc(struct __sk_buff *skb, int egress) {
  __u64 cookie = bpf_get_socket_cookie(skb);
  if (!cookie) return;
  struct procinfo *pi = bpf_map_lookup_elem(&sk_proc, &cookie);
  if (!pi) return;
  struct bytes *b = bpf_map_lookup_elem(&proc_usage, pi->comm);
  struct bytes z = {};
  if (!b) {
    bpf_map_update_elem(&proc_usage, pi->comm, &z, BPF_NOEXIST);
    b = bpf_map_lookup_elem(&proc_usage, pi->comm);
    if (!b) return;
  }
  if (egress) __sync_fetch_and_add(&b->tx, skb->len);
  else        __sync_fetch_and_add(&b->rx, skb->len);
}

// DNS capture ring — raw response payloads (UDP sport 53, ingress) for the
// daemon to parse in userspace and turn IPs into hostnames. Lossy by design
// (overwrites oldest); naming is best-effort. Parsing DNS in-kernel is painful,
// so we only copy bytes here.
#define DNS_SLOTS 64      // power of two (masked index)
#define DNS_CAP   512     // bytes captured per packet (power of two; classic DNS UDP)
struct dns_slot { __u32 len; __u8 data[DNS_CAP]; };
struct {
  __uint(type, BPF_MAP_TYPE_ARRAY);
  __uint(max_entries, DNS_SLOTS);
  __type(key, __u32);
  __type(value, struct dns_slot);
} dns SEC(".maps");
struct {
  __uint(type, BPF_MAP_TYPE_ARRAY);
  __uint(max_entries, 1);
  __type(key, __u32);
  __type(value, __u32);
} dns_head SEC(".maps");

static __always_inline void capture_dns(struct __sk_buff *skb) {
  if (skb->protocol != bpf_htons(ETH_P_IP)) return;
  __u8 vihl = 0, proto = 0;
  bpf_skb_load_bytes(skb, 0, &vihl, 1);
  __u32 ihl = (vihl & 0x0F) * 4;
  if (ihl < 20) return;
  bpf_skb_load_bytes(skb, 9, &proto, 1);
  if (proto != IPPROTO_UDP) return;
  __u16 sport = 0;
  bpf_skb_load_bytes(skb, ihl, &sport, 2);
  if (bpf_ntohs(sport) != 53) return;        // DNS responses only

  __u32 off = ihl + 8;                        // UDP payload = DNS message
  if (off >= skb->len) return;
  // Mask (not clamp) the length: bounds it for the verifier AND hides that it's
  // derived from skb->len, so the compiler keeps the > 0 check the verifier needs.
  __u32 plen = (skb->len - off) & (DNS_CAP - 1);
  if (plen == 0) return;

  __u32 zero = 0;
  __u32 *head = bpf_map_lookup_elem(&dns_head, &zero);
  if (!head) return;
  __u32 idx = *head & (DNS_SLOTS - 1);
  __sync_fetch_and_add(head, 1);
  struct dns_slot *slot = bpf_map_lookup_elem(&dns, &idx);
  if (!slot) return;
  slot->len = plen;
  bpf_skb_load_bytes(skb, off, slot->data, plen);
}

// single-slot stance, written by userspace on `coldspot stance ...`
struct {
  __uint(type, BPF_MAP_TYPE_ARRAY);
  __uint(max_entries, 1);
  __type(key, __u32);
  __type(value, __u32);
} policy SEC(".maps");

// siege survivor: the cgroup subtree that stays on the wire. Matching by
// ancestor id (not exact id) so descendant scopes — coldspot.slice/run-*.scope
// from `coldspot run`, coldspot.slice/loose from `coldspot allow` — all survive.
struct siege_cfg { __u64 cgid; __u32 level; };
struct {
  __uint(type, BPF_MAP_TYPE_ARRAY);
  __uint(max_entries, 1);
  __type(key, __u32);
  __type(value, struct siege_cfg);
} siege SEC(".maps");

// metered interface ifindex (set by the daemon). When nonzero, accounting and
// siege apply only to that link — other interfaces don't cost hotspot data.
struct {
  __uint(type, BPF_MAP_TYPE_ARRAY);
  __uint(max_entries, 1);
  __type(key, __u32);
  __type(value, __u32);
} cfg SEC(".maps");

// cold-stance egress throttle: a token bucket (bytes). Userspace writes `rate`
// (bytes/sec floor) and `burst` (max tokens); tokens/last_ns are kernel state.
// rate==0 means "not configured" -> fail OPEN (never black-hole on half-setup).
struct throttle_state { __u64 tokens; __u64 last_ns; __u64 rate; __u64 burst; };
struct {
  __uint(type, BPF_MAP_TYPE_ARRAY);
  __uint(max_entries, 1);
  __type(key, __u32);
  __type(value, struct throttle_state);
} throttle SEC(".maps");

// Is this an egress DNS packet (dport 53)? Kept flowing even under cold so name
// resolution never stalls. (The fuller critical-traffic set lands in task #16.)
static __always_inline int is_dns_egress(struct __sk_buff *skb) {
  __u16 dport = 0;
  if (skb->protocol == bpf_htons(ETH_P_IP)) {
    __u8 vihl = 0, proto = 0;
    bpf_skb_load_bytes(skb, 0, &vihl, 1);
    __u32 ihl = (vihl & 0x0F) * 4;
    if (ihl < 20) return 0;
    bpf_skb_load_bytes(skb, 9, &proto, 1);
    if (proto != IPPROTO_UDP && proto != IPPROTO_TCP) return 0;
    bpf_skb_load_bytes(skb, ihl + 2, &dport, 2);
  } else if (skb->protocol == bpf_htons(ETH_P_IPV6)) {
    __u8 nh = 0;
    bpf_skb_load_bytes(skb, 6, &nh, 1);
    if (nh != IPPROTO_UDP && nh != IPPROTO_TCP) return 0;
    bpf_skb_load_bytes(skb, 42, &dport, 2);   // 40-byte v6 header + 2
  } else {
    return 0;
  }
  return bpf_ntohs(dport) == 53;
}

// Token-bucket gate for one egress packet. Returns 1 (pass) or 0 (drop). We
// throttle EGRESS only: an ingress packet has already crossed the metered link
// (the bytes are spent), and dropping it just triggers retransmits.
static __always_inline int throttle_egress(struct __sk_buff *skb) {
  __u32 z = 0;
  struct throttle_state *t = bpf_map_lookup_elem(&throttle, &z);
  if (!t || t->rate == 0) return 1;            // unconfigured -> fail open
  __u64 now = bpf_ktime_get_ns();
  __u64 last = t->last_ns;
  if (now > last) {                            // replenish since last packet
    __u64 add = (t->rate * (now - last)) / 1000000000ULL;
    if (add) {
      __u64 tok = t->tokens + add;
      t->tokens = tok > t->burst ? t->burst : tok;
      t->last_ns = now;
    }
  }
  if (t->tokens >= skb->len) {                 // enough budget -> send
    t->tokens -= skb->len;
    return 1;
  }
  return 0;                                     // crippled to the floor
}

// per-destination accounting: parse IPv4 + TCP/UDP via skb_load_bytes (runtime
// offsets are fine through the helper — no direct-access bounds gymnastics).
static __always_inline void account_flow(struct __sk_buff *skb, int egress) {
  struct flow_key k = {};
  __u64 cookie = bpf_get_socket_cookie(skb);     // owning process, via the
  if (cookie) {                                  // connect-hook cookie map
    struct procinfo *pi = bpf_map_lookup_elem(&sk_proc, &cookie);
    if (pi)
      __builtin_memcpy(k.comm, pi->comm, sizeof(k.comm));
  }
  __u16 sport = 0, dport = 0;

  if (skb->protocol == bpf_htons(ETH_P_IP)) {
    __u8 vihl = 0, proto = 0;
    bpf_skb_load_bytes(skb, 0, &vihl, 1);
    __u32 ihl = (vihl & 0x0F) * 4;
    if (ihl < 20) return;
    bpf_skb_load_bytes(skb, 9, &proto, 1);
    if (proto != IPPROTO_TCP && proto != IPPROTO_UDP) return;
    __u32 saddr = 0, daddr = 0;
    bpf_skb_load_bytes(skb, 12, &saddr, 4);
    bpf_skb_load_bytes(skb, 16, &daddr, 4);
    bpf_skb_load_bytes(skb, ihl, &sport, 2);
    bpf_skb_load_bytes(skb, ihl + 2, &dport, 2);
    k.family = 4;
    k.proto = proto;
    __builtin_memcpy(k.ip, egress ? &daddr : &saddr, 4);
  } else if (skb->protocol == bpf_htons(ETH_P_IPV6)) {
    __u8 nh = 0;                                      // next header
    bpf_skb_load_bytes(skb, 6, &nh, 1);
    if (nh != IPPROTO_TCP && nh != IPPROTO_UDP) return;  // skip ext-header pkts
    __u8 saddr[16] = {}, daddr[16] = {};
    bpf_skb_load_bytes(skb, 8, saddr, 16);           // fixed 40-byte v6 header
    bpf_skb_load_bytes(skb, 24, daddr, 16);
    bpf_skb_load_bytes(skb, 40, &sport, 2);
    bpf_skb_load_bytes(skb, 42, &dport, 2);
    k.family = 6;
    k.proto = nh;
    __builtin_memcpy(k.ip, egress ? daddr : saddr, 16);
  } else {
    return;
  }
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
  // accounting + siege apply only to the metered link (if the daemon set one);
  // traffic on other interfaces is ignored and passed (it costs no hotspot data)
  __u32 k0 = 0, *mif = bpf_map_lookup_elem(&cfg, &k0);
  if (mif && *mif && skb->ifindex != *mif) return 1;

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
  account_flow(skb, egress);
  account_proc(skb, egress);

  // enforce: siege drops anything outside the survivor subtree (and not loopback)
  __u32 k = 0, *st = bpf_map_lookup_elem(&policy, &k);
  if (st && *st == STANCE_SIEGE) {
    if (skb->ifindex == 1) return 1;            // loopback
    struct siege_cfg *s = bpf_map_lookup_elem(&siege, &k);
    if (s && s->cgid &&
        bpf_skb_ancestor_cgroup_id(skb, s->level) == s->cgid)
      return 1;                                 // the survivor subtree
    return 0;                                   // drop everything else
  }
  // cold: the metered default. Cripple egress to a floor; warmed tasks (the
  // siege survivor subtree, set by `allow`/`run`) and DNS keep full speed.
  // Ingress is always passed — those bytes are already spent.
  if (st && *st == STANCE_COLD) {
    if (!egress) return 1;
    if (skb->ifindex == 1) return 1;            // loopback
    if (is_dns_egress(skb)) return 1;           // keep name resolution alive
    struct siege_cfg *s = bpf_map_lookup_elem(&siege, &k);
    if (s && s->cgid &&
        bpf_skb_ancestor_cgroup_id(skb, s->level) == s->cgid)
      return 1;                                 // explicitly uncapped (warm)
    return throttle_egress(skb);                // everyone else -> the floor
  }
  return 1;
}

SEC("cgroup_skb/egress")
int coldspot_egress(struct __sk_buff *skb) { return verdict(skb, 1); }

SEC("cgroup_skb/ingress")
int coldspot_ingress(struct __sk_buff *skb) {
  capture_dns(skb);
  return verdict(skb, 0);
}

char LICENSE[] SEC("license") = "GPL";
