# coldspot — common tasks. Run `make help` for the list.
EXT := extension/coldspot@asuramaya

.PHONY: help install pill deploy uninstall check lint bpf smoke attack sync-signers check-sutra clean

help:
	@echo "coldspot targets:"
	@echo "  make install       install daemon + auto-update timer (needs sudo)"
	@echo "  make pill          add the GNOME pill to YOUR account (no sudo, run after install)"
	@echo "  make deploy        smoke-test, then push bins+bpf+daemon and reload (sudo)"
	@echo "  make uninstall     remove everything except your GNOME pill (sudo; see make pill-remove)"
	@echo "  make check         run all static checks (CI-equivalent)"
	@echo "  make lint          ruff + shellcheck"
	@echo "  make bpf           build the eBPF core from local kernel BTF"
	@echo "  make smoke         run the no-root smoke test"
	@echo "  make attack        fuzz the control socket adversarially (no root)"
	@echo "  make check-sutra   verify the vendored bin/sutra.py wasn't hand-edited (+ freshness if canon is checked out)"
	@echo "  make sync-signers  rebuild release-signing/allowed_signers from the canonical keys (see docs/RELEASE-SIGNING.md — do NOT run casually)"
	@echo "  make clean         remove build artifacts"

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
	shellcheck install.sh uninstall.sh bin/coldspot-stance bin/coldspot-bpf bin/coldspot-update bin/coldspot-pill tools/deploy.sh tools/sync-signers.sh tests/test_signing.sh

check: lint check-sutra
	python3 -m py_compile bin/coldspotd bin/coldspot bin/sutra.py
	bash -n install.sh uninstall.sh bin/coldspot-stance bin/coldspot-bpf bin/coldspot-update bin/coldspot-pill tools/deploy.sh tools/sync-signers.sh
	node --check $(EXT)/extension.js
	python3 -c "import json; json.load(open('$(EXT)/metadata.json'))"
	python3 tests/test_units.py
	bash tests/test_signing.sh
	@echo "all static checks passed"

# Drift guard for the vendored sutra copy. Integrity (hash matches what
# vendor.sh recorded, so the copy wasn't hand-edited) is a hard failure and
# always runs. Freshness, when the canonical checkout is present (normally
# isn't in CI), is three-way: compared against sutra.py's OWN last-modifying
# commit in canonical, never canonical repo HEAD (decision 325b1969, sutra
# 0.7.3: comparing against repo HEAD false-positives LAG on every commit
# canonical ships, including ones that never touch sutra.py). Recorded at or
# after that commit -> fresh. A strict ancestor of it -> LAG, a real vendor
# gap, warn only. Not in canonical's history at all -> DRIFT, hard fail.
check-sutra:
	@ver=$$(cut -d' ' -f1 bin/sutra.version); \
	sha=$$(awk '{print $$NF}' bin/sutra.version); \
	actual=$$(sha256sum bin/sutra.py | cut -d' ' -f1); \
	if [ "$$sha" != "$$actual" ]; then \
	    echo "check-sutra FAIL: bin/sutra.py doesn't match bin/sutra.version" \
	         "(hand-edited? re-vendor: bash ~/code/REPOS/sutra/vendor.sh bin)"; \
	    exit 1; \
	fi; \
	echo "check-sutra: integrity ok (sutra $$ver, sha256 $$sha)"; \
	canon="$$HOME/code/REPOS/sutra"; \
	if [ -d "$$canon/.git" ]; then \
	    if [ ! -f bin/sutra.commit ]; then \
	        echo "check-sutra: freshness unknown (no bin/sutra.commit anchor, an older vendor)"; \
	    else \
	        recorded=$$(cat bin/sutra.commit); \
	        filehead=$$(git -C "$$canon" log -1 --format=%H -- sutra.py); \
	        if git -C "$$canon" merge-base --is-ancestor "$$filehead" "$$recorded" 2>/dev/null; then \
	            echo "check-sutra: freshness ok (vendored from $$recorded, at or after sutra.py's own head $$filehead)"; \
	        elif git -C "$$canon" merge-base --is-ancestor "$$recorded" "$$filehead" 2>/dev/null; then \
	            echo "check-sutra: LAG (vendored from $$recorded, sutra.py has since moved to $$filehead) -- warn, not a failure"; \
	        else \
	            echo "check-sutra FAIL: DRIFT (vendored commit $$recorded is not in canonical's history at $$canon) -- re-vendor"; \
	            exit 1; \
	        fi; \
	    fi; \
	else \
	    echo "check-sutra: canonical sutra checkout not present, freshness skipped"; \
	fi

bpf:
	cd bpf && bpftool btf dump file /sys/kernel/btf/vmlinux format c > vmlinux.h
	cd bpf && clang -O2 -g -target bpf -D__TARGET_ARCH_x86 -Wno-missing-declarations \
		-I. -c coldspot.bpf.c -o coldspot.bpf.o

smoke:
	bash tests/smoke.sh

attack:
	python3 tests/attack_socket.py

# Populates the trust anchor — see docs/RELEASE-SIGNING.md's sequencing rule.
# Only run this in the same act as cutting the operator's first signed
# release; it is NOT part of `make check` or day-to-day dev.
sync-signers:
	bash tools/sync-signers.sh

clean:
	rm -rf bpf/vmlinux.h bpf/*.o dist __pycache__ bin/__pycache__
