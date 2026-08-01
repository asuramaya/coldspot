# coldspot — common tasks. Run `make help` for the list.
EXT := src/extension/coldspot@asuramaya
# Exclusions are passed as flags, not via an rc file: shellcheck only grew
# --rcfile in 0.11.0, and ubuntu-latest's runner has shipped older builds
# that reject the flag outright. Every exclusion here is a deliberate,
# harmless pattern the real CI runner flags that this repo's own shellcheck
# doesn't: SC2015 (`A && B || true` as a best-effort compound, not a real
# if-then-else — the C branch is always a no-op), SC2119/SC2120
# (has_signing_key()'s optional arg is genuinely optional, called both ways).
SHELLCHECK_EXCLUDES = SC2015,SC2119,SC2120

# The family's shared recipe layer (sutra.mk, vendored like code under its
# own .version/.commit anchor -- see docs/BOOTSTRAP.md in the sutra repo and
# ruling 3e44bd95). Supplies check-sutra (integrity+freshness for the three
# vendored .py modules, plus pill.js via SUTRA_EXT_DIR below), SUTRA_ROOT_ROWS
# (the canonical tracked-files row count check-repo uses), and
# check-vendored-path[-all] (the checkout-run resolution guard) -- replacing
# ~130 lines coldspot used to hand-maintain for the same three things. PILL
# must be set before the include; everything else in sutra.mk resolves
# relative to its own vendored location, never this Makefile's.
PILL := coldspot
include src/share/coldspot/lib/sutra.mk

# coldspot vendors pill.js too (sutra.mk's own check-sutra loops only the
# three .py modules by default; this opts pill.js into the same
# integrity+freshness check via sutra.mk's own escape hatch). coldspot was
# confirmed the only pill in the family with an ungated pill.js before this
# (Alfred, msg 2817) -- pill.version/pill.commit were already vendored and
# tracked, just never checked.
SUTRA_EXT_DIR := $(EXT)

# sutra.mk's check-vendored-path validates one binary per call; coldspot
# carries the bootstrap preamble in all four of its binaries, so
# check-vendored-path-all loops it. coldspot-update binds sutra_update, not
# sutra -- the ":sutra_update" form checks that one against the right
# attribute; the other three take sutra.mk's own default
# (SUTRA_CHECK_MODULE=sutra).
SUTRA_CHECK_BINS := src/bin/coldspot src/bin/coldspotd src/bin/coldspot-healthcheck src/bin/coldspot-update:sutra_update

# SUTRA_CHECK_ARGS deliberately left unset: check-vendored-path's resolution
# check is safe against any binary regardless of argument parsing and needs
# no subprocess call to prove it (0.11.0's RAMstein incident -- a generic
# --help default fell through a hand-rolled arg parser into a real socket
# call against the live daemon; sutra.mk's SUTRA_CHECK_ARGS has no default
# for exactly this reason).

.PHONY: help install pill deploy uninstall check lint lint-ruff lint-shell pycheck bpf smoke attack sync-signers check-repo clean

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
	@echo "  make check-sutra   verify the vendored src/share/coldspot/lib/sutra*.py wasn't hand-edited (+ freshness if canon is checked out)"
	@echo "  make check-repo    verify the repo matches REPO-STANDARD.md's structural gate"
	@echo "  make sync-signers  rebuild packaging/release-signing/allowed_signers from the canonical keys (see docs/RELEASE-SIGNING.md — do NOT run casually)"
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
	COLDSPOT_EXT_DIR="$(EXT)" ./src/bin/coldspot-pill install

pill-remove:
	./src/bin/coldspot-pill remove

# Fast local iteration: smoke FIRST, then atomically push the moving parts into
# their installed locations and reload (loader before object, so new programs
# attach). Re-exec's itself with sudo for the install half.
deploy:
	bash packaging/deploy.sh

uninstall:
	./uninstall.sh

# Split into two so CI can report each separately (a named step per target,
# REPO-STANDARD.md's ruling: ci.yml calls Makefile targets, never carries its
# own copy of the command behind one) -- shellcheck now also runs natively
# inside pill-ci.yml's shared job via shellcheck-files, this stays for local
# `make lint`/`make check` and CI's ruff-only step (no pill-ci.yml input
# covers ruff; RAMstein, the adoption reference, doesn't use it at all).
lint-ruff:
	-ruff check src/bin/coldspot src/bin/coldspotd src/bin/coldspot-update src/bin/coldspot-healthcheck 2>/dev/null || true

lint-shell:
	shellcheck -e $(SHELLCHECK_EXCLUDES) install.sh uninstall.sh src/bin/coldspot-stance src/bin/coldspot-bpf src/bin/coldspot-pill packaging/deploy.sh packaging/sync-signers.sh

lint: lint-ruff lint-shell

# Kept as its own target (not just a line inside `check`) so ci.yml can call
# it directly: REPO-STANDARD.md's rule is that ci.yml invokes make targets,
# never hand-copies a file list that can drift from this one (the exact
# failure phanspeed hit -- a shellcheck/py_compile list hand-duplicated into
# ci.yml silently fell out of sync with the Makefile after Wave A).
pycheck:
	python3 -m py_compile src/bin/coldspotd src/bin/coldspot src/bin/coldspot-update src/bin/coldspot-healthcheck \
	    src/share/coldspot/lib/sutra.py src/share/coldspot/lib/sutra_update.py src/share/coldspot/lib/sutra_xen.py

check: lint check-sutra check-vendored-path-all pycheck
	bash -n install.sh uninstall.sh src/bin/coldspot-stance src/bin/coldspot-bpf src/bin/coldspot-pill packaging/deploy.sh packaging/sync-signers.sh
	node --check $(EXT)/extension.js
	python3 -c "import json; json.load(open('$(EXT)/metadata.json'))"
	python3 tests/test_units.py
	python3 tests/test_signing.py
	@echo "all static checks passed"

# check-sutra (integrity+freshness of the three vendored .py modules and,
# via SUTRA_EXT_DIR above, pill.js) and check-vendored-path[-all] (the
# checkout-run resolution guard across all four sutra-importing binaries)
# both now come from sutra.mk, included above -- was ~90 hand-maintained
# lines here before Pass 5 (2026-08-01), same recipe every sibling pill
# used to hand-copy independently and drift from.

bpf:
	cd src/bpf && bpftool btf dump file /sys/kernel/btf/vmlinux format c > vmlinux.h
	cd src/bpf && clang -O2 -g -target bpf -D__TARGET_ARCH_x86 -Wno-missing-declarations \
		-I. -c coldspot.bpf.c -o coldspot.bpf.o

smoke:
	bash tests/smoke.sh

attack:
	python3 tests/attack_socket.py

# Populates the trust anchor — see docs/RELEASE-SIGNING.md's sequencing rule.
# Only run this in the same act as cutting the operator's first signed
# release; it is NOT part of `make check` or day-to-day dev.
sync-signers:
	bash packaging/sync-signers.sh

# The family's structural gate (REPO-STANDARD.md §5), mechanical only: it
# cannot judge whether a document is any good, only that the shape it's
# supposed to have is actually there and nothing contradicts it. coldspot is
# the first repo in the family to land this target; kast reached the
# twelve-row shape first but has no gate of its own yet.
check-repo:
	@fail=0; \
	for f in README.md LICENSE Makefile install.sh uninstall.sh .gitignore .gitattributes \
	         docs/USAGE.md docs/ARCHITECTURE.md docs/RELEASING.md; do \
	    if [ ! -e "$$f" ]; then echo "check-repo FAIL: missing $$f"; fail=1; fi; \
	done; \
	if [ ! -e src/data/man/man1/coldspot.1 ] && ! grep -q 'man1/coldspot.1' docs/ARCHITECTURE.md 2>/dev/null; then \
	    echo "check-repo FAIL: no src/data/man/man1/coldspot.1 and no exemption for it"; fail=1; \
	fi; \
	rows=$(SUTRA_ROOT_ROWS); \
	if [ "$$rows" -gt 12 ]; then \
	    echo "check-repo FAIL: root has $$rows rows, standard caps it at 12"; fail=1; \
	else \
	    echo "check-repo: root row count ok ($$rows)"; \
	fi; \
	if ! grep -q '^## Map' README.md 2>/dev/null; then \
	    echo "check-repo FAIL: README.md has no navigation block (## Map)"; fail=1; \
	fi; \
	for h in Troubleshooting "Repo Layout"; do \
	    if grep -q "^## $$h" README.md 2>/dev/null; then \
	        echo "check-repo FAIL: README.md carries a post-install heading ('$$h') that belongs in docs/USAGE.md"; fail=1; \
	    fi; \
	done; \
	if [ ! -f packaging/VERSION ]; then \
	    echo "check-repo FAIL: no packaging/VERSION"; fail=1; \
	fi; \
	if grep -rn "VERSION[[:space:]]*=[[:space:]]*['\"][0-9]" \
	    src/bin/coldspot src/bin/coldspotd src/bin/coldspot-stance src/bin/coldspot-bpf \
	    src/bin/coldspot-update src/bin/coldspot-pill src/bin/coldspot-healthcheck install.sh uninstall.sh \
	    packaging/deploy.sh packaging/sync-signers.sh "$(EXT)/extension.js" 2>/dev/null; then \
	    echo "check-repo FAIL: a literal version string exists outside packaging/VERSION"; fail=1; \
	fi; \
	if grep -v '^[[:space:]]*#' .github/workflows/release.yml 2>/dev/null | grep -q -- '--generate-notes'; then \
	    echo "check-repo FAIL: release.yml still uses --generate-notes, not --notes-file"; fail=1; \
	fi; \
	stray=$$(find docs -name '*.md' -not -path '*/.*' | while read -r f; do git ls-files --error-unmatch "$$f" >/dev/null 2>&1 || echo "$$f"; done); \
	if [ -n "$$stray" ]; then \
	    echo "check-repo FAIL: untracked *.md under docs/: $$stray"; fail=1; \
	fi; \
	spec=$$(find . -name '*-SPEC.md' -not -path './.git/*'); \
	if [ -n "$$spec" ]; then \
	    echo "check-repo FAIL: *-SPEC.md left in the repo (specs belong in the seat's office): $$spec"; fail=1; \
	fi; \
	if [ -f docs/ARCHITECTURE.md ] && grep -q '^## Standard exemptions' docs/ARCHITECTURE.md; then \
	    bad=$$(awk '/^## Standard exemptions/{f=1;next} f && /^\|/ && !/^\| *Item *\|/ && !/^\|---/{ n=gsub(/\|/,"|"); if (n<3) print }' docs/ARCHITECTURE.md); \
	    if [ -n "$$bad" ]; then echo "check-repo FAIL: exemptions table has a row missing a column"; fail=1; fi; \
	fi; \
	if [ "$$fail" -eq 0 ]; then echo "check-repo: all mechanical checks passed"; else exit 1; fi

clean:
	rm -rf src/bpf/vmlinux.h src/bpf/*.o dist __pycache__ src/bin/__pycache__
