#!/usr/bin/env bash
# coldspot smoke test — no install, no root. Boots the daemon against a fake
# iface, pokes the control socket, and checks status.json shape.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export COLDSPOT_IFACE="lo"

python3 -c "import ast,sys; ast.parse(open('$HERE/bin/coldspotd').read()); \
            ast.parse(open('$HERE/bin/coldspot').read()); print('py parse: ok')"
bash -n "$HERE/bin/coldspot-stance" && echo "stance parse: ok"
bash -n "$HERE/install.sh" && bash -n "$HERE/uninstall.sh" && echo "install parse: ok"

# run the daemon in a throwaway runtime dir as the current user
RUN="$(mktemp -d)"; export RUN
sed "s#/run/coldspot#$RUN#; s#/var/lib/coldspot#$RUN#" "$HERE/bin/coldspotd" > "$RUN/d"
python3 "$RUN/d" & D=$!
trap 'kill $D 2>/dev/null || true; rm -rf "$RUN"' EXIT
for _ in $(seq 1 10); do [[ -e "$RUN/status.json" ]] && break; sleep 0.5; done

python3 - "$RUN" <<'PY'
import json, socket, sys, time
run = sys.argv[1]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.connect(run + "/control.sock")
s.sendall(b'{"cmd":"set","stance":"siege","budget":100}\n')
assert json.loads(s.recv(4096))["ok"]; s.close()
time.sleep(2.5)
st = json.load(open(run + "/status.json"))
for k in ("iface", "stance", "source", "rate_bps", "session", "budget",
          "talkers", "flows", "auto_siege", "history", "ledger", "advice"):
    assert k in st, f"missing {k}"
assert st["stance"] == "siege", st["stance"]
assert st["budget"]["limit_mb"] == 100, st["budget"]
assert isinstance(st["flows"], list), st["flows"]
assert isinstance(st["history"], dict), st["history"]
assert isinstance(st["ledger"], list), st["ledger"]
assert isinstance(st["advice"], list), st["advice"]
print("status.json shape: ok  ->", st["stance"], st["budget"]["limit_mb"],
      "MB cap, flows[]", "auto_siege", st["auto_siege"])
PY
echo "SMOKE OK"
