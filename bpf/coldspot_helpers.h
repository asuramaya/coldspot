// SPDX-License-Identifier: GPL-3.0-or-later
// coldspot_helpers.h — the handful of BPF helpers coldspot.bpf.c needs, vendored
// so the core builds with only clang + kernel BTF (no libbpf-dev). Helper IDs are
// taken symbolically from vmlinux.h's `enum bpf_func_id`, so they stay correct
// across kernels. Include AFTER vmlinux.h.
#ifndef COLDSPOT_HELPERS_H
#define COLDSPOT_HELPERS_H

#define SEC(name) __attribute__((section(name), used))
#define __always_inline inline __attribute__((always_inline))
#define __uint(name, val) int (*name)[val]
#define __type(name, val) typeof(val) *name

static void *(*bpf_map_lookup_elem)(void *map, const void *key) =
    (void *)BPF_FUNC_map_lookup_elem;
static long (*bpf_map_update_elem)(void *map, const void *key,
                                   const void *value, __u64 flags) =
    (void *)BPF_FUNC_map_update_elem;
static __u64 (*bpf_skb_cgroup_id)(struct __sk_buff *skb) =
    (void *)BPF_FUNC_skb_cgroup_id;
static long (*bpf_skb_load_bytes)(const void *skb, __u32 off, void *to,
                                  __u32 len) = (void *)BPF_FUNC_skb_load_bytes;

#define bpf_htons(x) __builtin_bswap16(x)
#define bpf_ntohs(x) __builtin_bswap16(x)

#define ETH_P_IP     0x0800
#define IPPROTO_TCP  6
#define IPPROTO_UDP  17

#endif /* COLDSPOT_HELPERS_H */
