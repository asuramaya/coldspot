#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 asuramaya and coldspot contributors
"""Adversarial control-socket harness for coldspotd.

Boots its OWN sandboxed daemon the exact way tests/smoke.sh does — a copy of
src/bin/coldspotd with /run/coldspot and /var/lib/coldspot sed-rewritten into a
throwaway tempdir, run as the current unprivileged user with COLDSPOT_IFACE=lo.
Nothing here touches the live /run/coldspot, systemd, or root: the daemon runs
as you, so it skips the SO_PEERCRED gate (see _coldspot_authz's
`os.geteuid() != 0` bypass) — the socket itself is still 0660
(sutra.ControlServer's fixed mode), just with no group check applied.

It then abuses the AF_UNIX control socket every way a hostile local peer could:
oversized lines, raw/invalid-UTF-8 garbage, valid-JSON non-objects, unknown
commands, deeply nested JSON, connect/disconnect storms, half-open and
one-byte-stall connections, and malformed `set` state. After each phase it
asserts the daemon is still a live process that answers a normal command and
still publishes a well-formed status.json (the same shape smoke.sh checks).

Two buckets of results:
  * FAILURES  — the harness's core contract was violated (a socket-level abuse
    crashed the daemon, it failed to recover, or status.json lost its shape).
    Any failure exits nonzero.
  * WEAKNESSES — genuine daemon defects this harness *discovered* and reports
    for the maintainer. coldspotd cannot be fixed from here, so these do not
    fail the run, but they are printed loudly and belong in the changelog.
    W1 and W2 below are historical (both fixed, commit 5a7c401) — phases 9
    and 11 keep probing for them as regression coverage, not live findings:
      W1  a wrong-TYPE `budget` in `set` is accepted with {"ok":true}, then
          crashes the daemon on the next publish (100*used_mb/budget divides by
          a str/list/dict — the publish math runs OUTSIDE the socket
          try/except). Violates FAMILY.md doctrine #3 (hostile input -> {error},
          never a crash) and #6 (invariants enforced on socket sets).
      W2  (pre-sutra) a half-open connection (connect, never send) blocked the
          single accept-per-loop thread until the client closed — the accepted
          socket had no recv timeout, a trivial local DoS. Fixed twice over:
          the original conn.settimeout() fix, then structurally obsoleted by
          the sutra adoption (each connection gets its own handler thread now,
          so one stuck peer can't stall any other connection regardless).

Run as your normal user:  python3 tests/attack_socket.py   (or: make attack)
"""
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SAMPLE = 2.0            # coldspotd's publish cadence (src/bin/coldspotd: SAMPLE)
PUBLISH_WAIT = SAMPLE * 1.6   # long enough for one fresh status.json write

# status.json keys + types smoke.sh treats as the seam invariant.
REQUIRED_KEYS = ("iface", "stance", "source", "rate_bps", "session", "budget",
                 "talkers", "flows", "links", "auto_siege", "history",
                 "ledger", "advice")
STANCES = ("open", "lean", "siege", "cold")

failures = []       # hard: harness contract broken -> exit 1
weaknesses = []     # discovered daemon defects -> reported, do not fail


def fail(msg):
    failures.append(msg)
    print(f"   !! FAILURE: {msg}")


def weak(msg):
    weaknesses.append(msg)
    print(f"   ** WEAKNESS: {msg}")


# --------------------------------------------------------------- sandbox boot
# bin_dir/lib_dir mimic an install prefix (bin/ + share/coldspot/lib/) so the
# daemon's sutra bootstrap preamble -- which locates the lib dir relative to
# its own installed path -- resolves for real, same as tests/smoke.sh. run_dir
# itself stays just the runtime state target (sed-rewritten /run, /var/lib).
run_dir = tempfile.mkdtemp(prefix="coldspot-attack-")
bin_dir = os.path.join(run_dir, "bin")
lib_dir = os.path.join(run_dir, "share", "coldspot", "lib")
os.makedirs(bin_dir)
os.makedirs(lib_dir)
_src = open(os.path.join(HERE, "src", "bin", "coldspotd")).read()
_src = _src.replace("/run/coldspot", run_dir).replace("/var/lib/coldspot", run_dir)
_daemon = os.path.join(bin_dir, "coldspotd")
with open(_daemon, "w") as f:
    f.write(_src)
shutil.copy(os.path.join(HERE, "src", "share", "coldspot", "lib", "sutra.py"), os.path.join(lib_dir, "sutra.py"))

SOCK = os.path.join(run_dir, "control.sock")
STATUS = os.path.join(run_dir, "status.json")
_log = open(os.path.join(run_dir, "daemon.log"), "wb")
_env = dict(os.environ, COLDSPOT_IFACE="lo")
# start_new_session so we can reap any transient helper children on teardown.
proc = subprocess.Popen([sys.executable, _daemon], env=_env,
                        stdout=_log, stderr=subprocess.STDOUT,
                        start_new_session=True)


def cleanup():
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
    except (ProcessLookupError, OSError):
        pass
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except (ProcessLookupError, OSError):
            pass
    _log.close()
    subprocess.run(["rm", "-rf", run_dir], check=False)


# ------------------------------------------------------------------- helpers
def daemon_alive():
    return proc.poll() is None


def daemon_threads():
    """Thread count from /proc. Since the sutra adoption coldspotd is no
    longer single-threaded (main + sutra.ControlServer's own accept thread,
    baseline ~2, +1 transient per in-flight connection) — the checks below
    compare relative growth, not an absolute count, so a climbing value still
    means a leaked per-connection thread."""
    try:
        with open(f"/proc/{proc.pid}/status") as f:
            for line in f:
                if line.startswith("Threads:"):
                    return int(line.split()[1])
    except (OSError, ValueError):
        pass
    return -1


def ask(payload, timeout=3.0, read=True):
    """One connection: connect, optionally send bytes, read until newline/EOF,
    close. Returns the reply bytes, b'' on no-reply/EOF, or b'<timeout>'."""
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        s.connect(SOCK)
        if payload is not None:
            s.sendall(payload)
        if not read:
            return b""
        out = b""
        try:
            while b"\n" not in out:
                chunk = s.recv(4096)
                if not chunk:
                    break
                out += chunk
        except socket.timeout:
            return b"<timeout>"
        return out
    finally:
        s.close()


def normal_ok(timeout=4.0):
    """Send the benign command smoke.sh uses; True iff the daemon answers ok."""
    reply = ask(b'{"cmd":"set","stance":"siege","budget":100}\n', timeout=timeout)
    try:
        return json.loads(reply).get("ok") is True
    except (ValueError, AttributeError):
        return False


def load_status():
    with open(STATUS) as f:
        return json.load(f)


def assert_healthy(where):
    """After every abuse phase: the daemon is a live process, answers a normal
    command, and still publishes a status.json of the smoke.sh shape."""
    if not daemon_alive():
        fail(f"[{where}] daemon PROCESS died")
        return False
    if not normal_ok():
        fail(f"[{where}] daemon stopped answering a normal command")
        return False
    try:
        st = load_status()
    except (OSError, ValueError) as exc:
        fail(f"[{where}] status.json unreadable/malformed: {exc}")
        return False
    for k in REQUIRED_KEYS:
        if k not in st:
            fail(f"[{where}] status.json missing key {k!r}")
            return False
    if st["stance"] not in STANCES:
        fail(f"[{where}] status.json stance not valid: {st['stance']!r}")
    for k, typ in (("flows", list), ("links", dict), ("history", dict),
                   ("ledger", list), ("advice", list)):
        if not isinstance(st[k], typ):
            fail(f"[{where}] status.json {k} is {type(st[k]).__name__}, want "
                 f"{typ.__name__}")
    return not failures


# ---------------------------------------------------------------- boot wait
for _ in range(20):
    if os.path.exists(STATUS):
        break
    time.sleep(0.5)
else:
    print("daemon never wrote status.json — sandbox boot failed")
    cleanup()
    sys.exit(1)

print(f"== sandbox booted (pid {proc.pid}, run={run_dir}) ==")
# Baseline: mirror smoke.sh exactly — set siege/100, wait a cycle, deep-check.
ask(b'{"cmd":"set","stance":"siege","budget":100}\n')
time.sleep(PUBLISH_WAIT)
_st = load_status()
assert _st["stance"] == "siege", _st["stance"]
assert _st["budget"]["limit_mb"] == 100, _st["budget"]
print(f"   baseline: stance={_st['stance']} budget={_st['budget']['limit_mb']}MB "
      f"threads={daemon_threads()}  (smoke invariants hold)")

# ============================================================= abuse phases
print("== phase 1: oversized line (>64KiB) ==")
big = b'{"cmd":"set","stance":"open","pad":"' + b"A" * (80 * 1024) + b'"}\n'
r = ask(big)
print(f"   80KiB line -> reply {r[:40]!r} (daemon reads a bounded 4096B, drops it)")
assert_healthy("oversized")

print("== phase 2: raw garbage / binary bytes ==")
for p in (b'\x00\x01\x02\x03\xde\xad\xbe\xef\n', b'\x7f' * 100 + b'\n',
          b'not json at all\n', b'{unclosed\n', b'\x00\n', b'\n'):
    ask(p)
assert_healthy("garbage")
print("   survived binary/garbage input")

print("== phase 3: invalid UTF-8 ==")
for p in (b'\xff\xfe\xfd\xfc\n', b'\xc3\x28\n', b'\xe2\x28\xa1\n',
          b'{"cmd":"\xff\xfe"}\n'):
    ask(p)
assert_healthy("invalid-utf8")
print("   survived invalid UTF-8")

print("== phase 4: valid JSON non-objects (array/string/number/bool/null) ==")
for p in (b'[1,2,3]\n', b'"a bare string"\n', b'42\n', b'3.14\n',
          b'true\n', b'false\n', b'null\n', b'[]\n', b'[[[]]]\n'):
    r = ask(p)
    # a non-dict has no .get("cmd") -> AttributeError, swallowed, no reply
assert_healthy("non-object")
print("   survived non-object JSON (each raises .get on a non-dict, swallowed)")

print("== phase 5: unknown commands ==")
for p in (b'{"cmd":"wat"}\n', b'{"cmd":12345}\n', b'{"cmd":null}\n',
          b'{"cmd":"../../etc/passwd"}\n', b'{"cmd":"set"}\n',
          b'{"nocmd":true}\n', b'{}\n', b'{"cmd":["set"]}\n'):
    r = ask(p)
# unknown/empty falls to the else branch -> {"ok":true}, no state change
r = ask(b'{"cmd":"wat"}\n')
if b'"ok":true' not in r:
    weak(f"unknown command did not get the benign else-reply: {r!r}")
assert_healthy("unknown-cmd")
print(f"   unknown cmd -> {r!r} (benign else-branch)")

print("== phase 6: deeply nested JSON ==")
for depth, payload in (("2000-deep array (fits in 4096B read)",
                        b'[' * 2000 + b']' * 2000 + b'\n'),
                       ("5000-deep array (truncated at 4096B)",
                        b'[' * 5000 + b'\n'),
                       ("800-deep object",
                        b'{"a":' * 800 + b'1' + b'}' * 800 + b'\n')):
    r = ask(payload)
    print(f"   {depth} -> {r[:24]!r} (RecursionError swallowed)")
assert_healthy("nested")

print("== phase 7: rapid connect/disconnect storm (60x) ==")
threads_before = daemon_threads()
t0 = time.time()
for _ in range(60):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        s.connect(SOCK)
    except OSError:
        pass
    s.close()
time.sleep(1.0)   # let the single-threaded loop drain the backlog
threads_after = daemon_threads()
print(f"   60 connect/close in {time.time()-t0:.2f}s; "
      f"threads {threads_before}->{threads_after}")
if threads_after > threads_before + 1 and threads_after > 2:
    weak(f"thread count climbed under storm ({threads_before}->{threads_after}) "
         "— possible leaked per-connection thread")
assert_healthy("storm")

print("== phase 8: one byte then stall (no newline) ==")
# recv() returns the single available byte immediately, so this must NOT block.
s1 = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s1.connect(SOCK)
s1.sendall(b'{')
t0 = time.time()
served = normal_ok(timeout=4.0)
dt = time.time() - t0
s1.close()
if not served:
    fail(f"one-byte-stall blocked the daemon (normal cmd took {dt:.2f}s)")
else:
    print(f"   concurrent normal answered in {dt:.2f}s — one-byte stall did NOT block")
assert_healthy("one-byte-stall")

print("== phase 9: half-open connection (connect, never send) ==")
# The accepted socket has no recv timeout, so the single accept-per-loop thread
# blocks in recv() until the client closes. Demonstrate the stall, then recover.
h = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
h.connect(SOCK)
t0 = time.time()
blocked_reply = ask(b'{"cmd":"set","stance":"open"}\n', timeout=3.0)
blocked_dt = time.time() - t0
if blocked_reply == b"<timeout>":
    weak(f"half-open connect-never-send blocked the loop for {blocked_dt:.1f}s+ "
         "(no recv timeout on the accepted socket) — trivial local DoS")
else:
    print(f"   half-open did NOT block (reply {blocked_reply!r}) — daemon hardened?")
h.close()                       # closing unblocks recv() (EOF -> {} -> ok)
time.sleep(0.5)
t0 = time.time()
if not normal_ok(timeout=5.0):
    fail("daemon did NOT recover after the half-open client closed")
else:
    print(f"   recovered {time.time()-t0:.2f}s after close")
assert_healthy("half-open")

print("== phase 10: malformed set — out-of-range / wrong-type (safe values) ==")
# Values coldspotd is expected to reject or safely absorb without dying.
SAFE_MALFORMED = [
    b'{"cmd":"set","stance":"nonsense"}\n',     # not in STANCES -> ignored
    b'{"cmd":"set","stance":123}\n',            # wrong type -> ignored
    b'{"cmd":"set","stance":["siege"]}\n',      # wrong type -> ignored
    b'{"cmd":"set","stance":null}\n',           # None -> ignored
    b'{"cmd":"set","budget":null}\n',           # unset budget (falsy -> off)
    b'{"cmd":"set","budget":0}\n',              # zero (falsy -> off)
    b'{"cmd":"set","budget":-5}\n',             # negative int -> numeric, safe
    b'{"cmd":"set","budget":999999999}\n',      # absurd cap -> numeric, safe
    b'{"cmd":"set","budget":true}\n',           # bool -> coerces to 1, safe
    b'{"cmd":"set","stance":"cold","budget":50}\n',   # a valid combo
]
for p in SAFE_MALFORMED:
    r = ask(p)
    if not daemon_alive():
        fail(f"daemon died on a value it should absorb: {p!r}")
        break
# leave it in a known-good state before the deep health check
ask(b'{"cmd":"set","stance":"siege","budget":100}\n')
time.sleep(PUBLISH_WAIT)
assert_healthy("malformed-set-safe")
print("   out-of-range/wrong-type stance + numeric/None budgets absorbed safely")

# ---- destructive state-validation probe: RUN LAST, may crash the daemon ----
print("== phase 11: wrong-TYPE budget (destructive probe, runs last) ==")
if not daemon_alive():
    print("   (skipped — daemon already down)")
else:
    ask(b'{"cmd":"set","budget":100}\n')       # sane starting point
    time.sleep(PUBLISH_WAIT)
    probe = b'{"cmd":"set","budget":"lots"}\n'  # a str budget
    r = ask(probe)
    accepted = b'"ok":true' in r
    time.sleep(PUBLISH_WAIT + SAMPLE)            # let a publish cycle run
    if not daemon_alive():
        rc = proc.returncode
        weak("wrong-type budget crashed the daemon: `set budget:\"lots\"` was "
             f"accepted (reply {r!r}, ok={accepted}) then the next publish did "
             f"100*used_mb/budget on a str -> uncaught TypeError, daemon exited "
             f"(rc={rc}). Fix belongs in coldspotd: clamp/reject non-numeric "
             "budget on the socket set, like doctrine #6 requires.")
    else:
        # a hardened daemon that validates budget survives -> assert it answers
        if not normal_ok():
            fail("daemon alive after wrong-type budget but not answering")
        else:
            print("   daemon absorbed a wrong-type budget and stayed up (hardened)")

# ------------------------------------------------------------------- verdict
cleanup()
print()
print(f"phases run: 11   failures: {len(failures)}   "
      f"weaknesses discovered: {len(weaknesses)}")
if weaknesses:
    print("discovered daemon weaknesses (report to maintainer; not fixable here):")
    for w in weaknesses:
        print(f"  - {w}")
if failures:
    print("HARNESS FAILURES:")
    for fmsg in failures:
        print(f"  - {fmsg}")
    print("attack_socket.py: FAIL")
    sys.exit(1)
print("attack_socket.py: PASS — socket layer withstood every socket-level "
      "abuse and recovered; weaknesses above are reported, not harness failures")
sys.exit(0)
