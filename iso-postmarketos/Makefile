SHELL := /bin/bash
ROOT_DIR := $(CURDIR)
DEFAULT_PROFILE := config/fairphone-fp4.env
QEMU_PROFILE := config/arm64-virt.env

.PHONY: help build build-qemu qemu qemu-pmb

help:
	@echo "Single-path image build:"
	@echo "  make build        # Fairphone FP4 profile"
	@echo "  make build-qemu   # ARM64 QEMU profile"
	@echo "  make qemu         # Boot exported image via qemu-system-aarch64"
	@echo "  make qemu-pmb     # Boot QEMU profile via pmbootstrap (fallback)"
	@echo ""
	@echo "SSH:"
	@echo "  Device (USB): 172.16.42.1 — after make build + USB developer mode"
	@echo "  QEMU (make qemu): ssh -p 2222 user@127.0.0.1 — user networking, not bridge100"
	@echo ""
	@echo "Build output:"
	@echo "  build/host-export-fairphone-fp4/boot.img"
	@echo "  build/host-export-fairphone-fp4/fairphone-fp4.img"
	@echo "  build/host-export-arm64-virt/boot.img (optional)"
	@echo "  build/host-export-arm64-virt/arm64-virt.img"

build:
	@bash "$(ROOT_DIR)/scripts/build-image.sh" "$(DEFAULT_PROFILE)"

build-qemu:
	@bash "$(ROOT_DIR)/scripts/build-image.sh" "$(QEMU_PROFILE)"

qemu:
	@bash "$(ROOT_DIR)/scripts/qemu/run-local-qemu.sh" "$(QEMU_PROFILE)"

qemu-pmb:
	@bash "$(ROOT_DIR)/scripts/pmb/pmb.sh" "$(QEMU_PROFILE)" qemu
