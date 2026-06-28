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


if __name__ == "__main__":
    n = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn()
            n += 1
    print(f"units: ok ({n} tests)")
