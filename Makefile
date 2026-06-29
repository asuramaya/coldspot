# coldspot — common tasks. Run `make help` for the list.
EXT := extension/coldspot@asuramaya

.PHONY: help install deploy uninstall check lint bpf smoke clean

help:
	@echo "coldspot targets:"
	@echo "  make install    install daemon + pill + auto-update timer (sudo)"
	@echo "  make deploy     smoke-test, then push bins+bpf+daemon and reload (sudo)"
	@echo "  make uninstall  remove everything (sudo)"
	@echo "  make check      run all static checks (CI-equivalent)"
	@echo "  make lint       ruff + shellcheck"
	@echo "  make bpf        build the eBPF core from local kernel BTF"
	@echo "  make smoke      run the no-root smoke test"
	@echo "  make clean      remove build artifacts"

install:
	sudo ./install.sh

# Fast local iteration: smoke FIRST, then atomically push the moving parts into
# their installed locations and reload (loader before object, so new programs
# attach). Re-exec's itself with sudo for the install half.
deploy:
	bash tools/deploy.sh

uninstall:
	sudo ./uninstall.sh

lint:
	-ruff check bin/coldspot bin/coldspotd 2>/dev/null || true
	shellcheck install.sh uninstall.sh bin/coldspot-stance bin/coldspot-bpf bin/coldspot-update tools/deploy.sh

check: lint
	python3 -m py_compile bin/coldspotd bin/coldspot
	bash -n install.sh uninstall.sh bin/coldspot-stance bin/coldspot-bpf bin/coldspot-update tools/deploy.sh
	node --check $(EXT)/extension.js
	python3 -c "import json; json.load(open('$(EXT)/metadata.json'))"
	python3 tests/test_units.py
	@echo "all static checks passed"

bpf:
	cd bpf && bpftool btf dump file /sys/kernel/btf/vmlinux format c > vmlinux.h
	cd bpf && clang -O2 -g -target bpf -D__TARGET_ARCH_x86 -Wno-missing-declarations \
		-I. -c coldspot.bpf.c -o coldspot.bpf.o

smoke:
	bash tests/smoke.sh

clean:
	rm -rf bpf/vmlinux.h bpf/*.o dist __pycache__ bin/__pycache__
