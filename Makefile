ARCH ?= amd64
SUITE ?= trixie
VERSION ?= $(shell git describe --tags --always 2>/dev/null || echo "dev")

QCAR = output/veilbox-cloud-$(SUITE)-amd64.qcow2
QCAR_ARM = output/veilbox-cloud-$(SUITE)-arm64.qcow2

.PHONY: all build-amd64 build-arm64 release clean test

all: build-amd64 build-arm64

build-amd64:
	sudo bash build.sh 2>&1 | tee build-amd64.log

build-arm64:
	sudo ARCH=arm64 bash build.sh 2>&1 | tee build-arm64.log

release-amd64: build-amd64
	gh release view v$(VERSION) --repo Shreyas0047/veilbox-cloud &>/dev/null || \
		gh release create v$(VERSION) --repo Shreyas0047/veilbox-cloud --title "v$(VERSION)"
	gh release upload v$(VERSION) $(QCAR) --repo Shreyas0047/veilbox-cloud --clobber

release-arm64: build-arm64
	gh release view v$(VERSION)-arm64 --repo Shreyas0047/veilbox-cloud &>/dev/null || \
		gh release create v$(VERSION)-arm64 --repo Shreyas0047/veilbox-cloud --title "v$(VERSION) (ARM64)"
	gh release upload v$(VERSION)-arm64 $(QCAR_ARM) --repo Shreyas0047/veilbox-cloud --clobber

release: release-amd64 release-arm64

clean:
	sudo rm -rf /tmp/rootfs /tmp/mnt-image output/

test:
	@echo "Run smoke tests:"
	@echo "  sudo QEMU_IMAGE=$(QCAR) bash tests/smoke.sh"
