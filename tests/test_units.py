#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Unit tests for coldspotd's pure parsers: DNS response parsing (the tricky bit —
# name-compression pointers, A/AAAA), the external-IP filter, and byte decode.
# Loaded directly from the extensionless daemon script.
import importlib.machinery
import importlib.util
import os
import socket
import struct

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_loader = importlib.machinery.SourceFileLoader(
    "coldspotd", os.path.join(HERE, "bin", "coldspotd"))
_spec = importlib.util.spec_from_loader("coldspotd", _loader)
d = importlib.util.module_from_spec(_spec)
_loader.exec_module(d)


def _name(n):
    out = b""
    for part in n.split("."):
        out += bytes([len(part)]) + part.encode()
    return out + b"\x00"


def _response(qname, answers, flags=0x8180):
    """answers: list of (rrtype, rdata). Each answer points back to the question
    name with a 0xC00C compression pointer (offset 12)."""
    hdr = struct.pack(">HHHHHH", 0x1234, flags, 1, len(answers), 0, 0)
    body = _name(qname) + struct.pack(">HH", 1, 1)  # qtype A, qclass IN
    for rrtype, rdata in answers:
        body += b"\xc0\x0c" + struct.pack(">HHIH", rrtype, 1, 300, len(rdata)) + rdata
    return hdr + body


def test_dns_a():
    pkt = _response("example.com", [(1, bytes([93, 184, 216, 34]))])
    assert ("example.com", "93.184.216.34") in d._parse_dns(pkt), d._parse_dns(pkt)


def test_dns_aaaa():
    ip6 = socket.inet_pton(socket.AF_INET6, "2606:2800:220:1:248:1893:25c8:1946")
    pairs = d._parse_dns(_response("example.com", [(28, ip6)]))
    assert ("example.com", "2606:2800:220:1:248:1893:25c8:1946") in pairs, pairs


def test_dns_cname_then_a():
    # a CNAME (type 5) answer followed by an A — the A still maps to the qname
    cname = _name("cdn.example.net")
    pkt = _response("www.example.com", [(5, cname), (1, bytes([1, 2, 3, 4]))])
    assert ("www.example.com", "1.2.3.4") in d._parse_dns(pkt), d._parse_dns(pkt)


def test_dns_query_ignored():
    # a query (no response bit) yields nothing
    assert d._parse_dns(_response("x.com", [(1, b"\x01\x02\x03\x04")],
                                  flags=0x0100)) == []


def test_dns_garbage():
    assert d._parse_dns(b"\x00\x01") == []
    assert d._parse_dns(b"") == []


def test_external():
    for ip in ("8.8.8.8", "172.32.0.1", "2606:4700::1111"):
        assert d._external(ip), ip
    for ip in ("127.0.0.1", "10.1.2.3", "192.168.1.1", "172.16.0.1",
               "169.254.1.1", "224.0.0.1", "::1", "fe80::1", "fd00::1"):
        assert not d._external(ip), ip


def test_le():
    assert d._le(["0x39", "0x30"]) == 0x3039
    assert d._le(["0x01", "0x00", "0x00", "0x00"]) == 1


# ---- BPF<->daemon map-layout contract --------------------------------------
# flow_key's byte offsets are hand-counted in TWO places: the C struct in
# bpf/coldspot.bpf.c and read_flows()'s raw-key slicing in coldspotd. They must
# agree or `coldspot flows` silently decodes garbage. These tests parse the C
# struct and round-trip a synthetic row through the *real* decoder, so drift in
# either half fails here instead of on the user's machine.
import json   # noqa: E402  (kept local to the contract block)

_C_TYPE_SIZE = {"char": 1, "__u8": 1, "__s8": 1, "__u16": 2, "__u32": 4,
                "__u64": 8, "__s16": 2, "__s32": 4, "__s64": 8}


def _flow_key_layout():
    """Parse `struct flow_key { ... }` from the BPF source into
    {field: (offset, size), '__sizeof__': total}. The struct is declared with
    no padding holes (its own comment guarantees it), so sequential packing is
    the on-wire layout bpftool dumps."""
    src = open(os.path.join(HERE, "bpf", "coldspot.bpf.c")).read()
    import re
    m = re.search(r"struct flow_key\s*\{(.*?)\}\s*;", src, re.S)
    assert m, "flow_key struct not found in coldspot.bpf.c"
    off, layout = 0, {}
    for raw in m.group(1).splitlines():
        line = raw.split("//")[0].strip().rstrip(";").strip()
        if not line:
            continue
        fm = re.match(r"(\w+)\s+(\w+)(?:\[(\d+)\])?$", line)
        assert fm, f"unparsed flow_key field: {raw!r}"
        ctype, name, count = fm.group(1), fm.group(2), fm.group(3)
        size = _C_TYPE_SIZE[ctype] * (int(count) if count else 1)
        layout[name] = (off, size)
        off += size
    layout["__sizeof__"] = off
    return layout


def test_flow_key_layout_matches_decoder():
    # The offsets read_flows() hard-codes when slicing the raw key. If the C
    # struct is reordered/resized, these stop matching and the test fails.
    L = _flow_key_layout()
    assert L["comm"] == (0, 16), L
    assert L["ip"] == (16, 16), L
    assert L["port"] == (32, 2), L
    assert L["proto"] == (34, 2), L
    assert L["family"] == (36, 1), L
    assert L["__sizeof__"] == 40, L


def _flow_row(L, comm, ipb, port, proto, fam, rx, tx):
    """Build one bpftool `map dump -j` row for flow_key/bytes, placing each field
    at the offset parsed from the C struct (little-endian, as x86 dumps)."""
    key = [0] * L["__sizeof__"]
    for i, b in enumerate(comm.encode()[:16]):
        key[L["comm"][0] + i] = b
    for i, b in enumerate(ipb[:16]):
        key[L["ip"][0] + i] = b
    po = L["port"][0]
    key[po], key[po + 1] = port & 0xFF, (port >> 8) & 0xFF
    pr = L["proto"][0]
    key[pr], key[pr + 1] = proto & 0xFF, (proto >> 8) & 0xFF
    key[L["family"][0]] = fam
    val = list(rx.to_bytes(8, "little")) + list(tx.to_bytes(8, "little"))
    return {"key": [f"0x{b:02x}" for b in key],
            "value": [f"0x{b:02x}" for b in val]}


def _decode_rows(rows, names=None):
    """Run read_flows() against synthetic rows, stubbing bpftool + the map path
    so it needs neither root nor a loaded core."""
    class _R:
        stdout = json.dumps(rows)
    real_run, real_exists = d.subprocess.run, d.os.path.exists
    d.subprocess.run = lambda *a, **k: _R()
    d.os.path.exists = lambda p: True
    try:
        return d.read_flows(names)
    finally:
        d.subprocess.run, d.os.path.exists = real_run, real_exists


def test_read_flows_roundtrip_v4():
    L = _flow_key_layout()
    ipb = bytes(int(x) for x in "1.2.3.4".split("."))
    row = _flow_row(L, "curl", ipb, 443, 6, 4, 1_000_000, 0)
    out = _decode_rows([row], names={"1.2.3.4": ("github.com", 0.0)})
    assert out and len(out) == 1, out
    f = out[0]
    assert (f["app"], f["dst"], f["port"], f["proto"], f["host"], f["mb"]) \
        == ("curl", "1.2.3.4", 443, "tcp", "github.com", 1.0), f


def test_read_flows_roundtrip_v6():
    L = _flow_key_layout()
    ipb = socket.inet_pton(socket.AF_INET6, "2606:4700::1111")
    row = _flow_row(L, "chrome", ipb, 443, 6, 6, 0, 2_500_000)
    out = _decode_rows([row])
    assert out and len(out) == 1, out
    f = out[0]
    assert (f["app"], f["dst"], f["port"], f["proto"], f["mb"]) \
        == ("chrome", "2606:4700::1111", 443, "tcp", 2.5), f


if __name__ == "__main__":
    n = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn()
            n += 1
    print(f"units: ok ({n} tests)")
