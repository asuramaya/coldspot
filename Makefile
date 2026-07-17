# coldspot — common tasks. Run `make help` for the list.
EXT := extension/coldspot@asuramaya

.PHONY: help install pill deploy uninstall check lint bpf smoke attack clean

help:
	@echo "coldspot targets:"
	@echo "  make install    install daemon + auto-update timer (needs sudo)"
	@echo "  make pill       add the GNOME pill to YOUR account (no sudo, run after install)"
	@echo "  make deploy     smoke-test, then push bins+bpf+daemon and reload (sudo)"
	@echo "  make uninstall  remove everything except your GNOME pill (sudo; see make pill-remove)"
	@echo "  make check      run all static checks (CI-equivalent)"
	@echo "  make lint       ruff + shellcheck"
	@echo "  make bpf        build the eBPF core from local kernel BTF"
	@echo "  make smoke      run the no-root smoke test"
	@echo "  make attack     fuzz the control socket adversarially (no root)"
	@echo "  make clean      remove build artifacts"

# install.sh is root-only and never self-elevates (see its header comment for
# why) — it fails with a clear message if you forget sudo, rather than quietly
# re-invoking itself. So `make install` needs YOU to type sudo, same as the
# script directly: `sudo make install` / `sudo ./install.sh` are equivalent.
install:
	./install.sh

# The GNOME pill never needed root — it only writes into your own $HOME and
# your own gnome-shell session. Deliberately separate from `install`: run this
# as yourself, NOT with sudo, any time after `make install` has staged the
# extension source. Works per-account, so every user on a shared box self-serves.
pill:
	COLDSPOT_EXT_DIR="$(EXT)" ./bin/coldspot-pill install

pill-remove:
	./bin/coldspot-pill remove

# Fast local iteration: smoke FIRST, then atomically push the moving parts into
# their installed locations and reload (loader before object, so new programs
# attach). Re-exec's itself with sudo for the install half.
deploy:
	bash tools/deploy.sh

uninstall:
	./uninstall.sh

lint:
	-ruff check bin/coldspot bin/coldspotd 2>/dev/null || true
	shellcheck install.sh uninstall.sh bin/coldspot-stance bin/coldspot-bpf bin/coldspot-update bin/coldspot-pill tools/deploy.sh tests/test_signing.sh

check: lint
	python3 -m py_compile bin/coldspotd bin/coldspot
	bash -n install.sh uninstall.sh bin/coldspot-stance bin/coldspot-bpf bin/coldspot-update bin/coldspot-pill tools/deploy.sh
	node --check $(EXT)/extension.js
	python3 -c "import json; json.load(open('$(EXT)/metadata.json'))"
	python3 tests/test_units.py
	bash tests/test_signing.sh
	@echo "all static checks passed"

bpf:
	cd bpf && bpftool btf dump file /sys/kernel/btf/vmlinux format c > vmlinux.h
	cd bpf && clang -O2 -g -target bpf -D__TARGET_ARCH_x86 -Wno-missing-declarations \
		-I. -c coldspot.bpf.c -o coldspot.bpf.o

smoke:
	bash tests/smoke.sh

attack:
	python3 tests/attack_socket.py

clean:
	rm -rf bpf/vmlinux.h bpf/*.o dist __pycache__ bin/__pycache__
