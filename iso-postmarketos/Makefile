SHELL := /bin/bash
ROOT_DIR := $(CURDIR)
DEFAULT_PROFILE := config/fairphone-fp4.env
QEMU_PROFILE := config/arm64-virt.env
BUILD_IMAGE_SCRIPT := $(ROOT_DIR)/scripts/build-image.sh
BUILD_IMAGE_FLAGS :=

ifneq (,$(filter without-overview-chat-ui,$(MAKECMDGOALS)))
BUILD_IMAGE_FLAGS += --without-overview-chat-ui
endif
ifeq ($(WITHOUT_OVERVIEW_CHAT_UI),1)
BUILD_IMAGE_FLAGS += --without-overview-chat-ui
endif
ifneq ($(strip $(BUILD_IMAGE_ARGS)),)
BUILD_IMAGE_FLAGS += $(BUILD_IMAGE_ARGS)
endif

.PHONY: help build build-qemu qemu qemu-pmb without-overview-chat-ui

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
	@ATOMOS_FRESH_ROOTFS_IMAGES="$${ATOMOS_FRESH_ROOTFS_IMAGES:-1}" \
		ATOMOS_ENABLE_VENDOR_PHOSH="$${ATOMOS_ENABLE_VENDOR_PHOSH:-1}" \
		ATOMOS_SKIP_VENDOR_PHOSH_BUILD="$${ATOMOS_SKIP_VENDOR_PHOSH_BUILD:-0}" \
		bash "$(BUILD_IMAGE_SCRIPT)" "$(DEFAULT_PROFILE)" $(BUILD_IMAGE_FLAGS)

build-qemu:
	@ATOMOS_FRESH_ROOTFS_IMAGES="$${ATOMOS_FRESH_ROOTFS_IMAGES:-1}" \
		ATOMOS_ENABLE_VENDOR_PHOSH="$${ATOMOS_ENABLE_VENDOR_PHOSH:-1}" \
		ATOMOS_SKIP_VENDOR_PHOSH_BUILD="$${ATOMOS_SKIP_VENDOR_PHOSH_BUILD:-0}" \
		bash "$(BUILD_IMAGE_SCRIPT)" "$(QEMU_PROFILE)" $(BUILD_IMAGE_FLAGS)

qemu:
	@bash "$(ROOT_DIR)/scripts/qemu/run-local-qemu.sh" "$(QEMU_PROFILE)"

qemu-pmb:
	@bash "$(ROOT_DIR)/scripts/pmb/pmb.sh" "$(QEMU_PROFILE)" qemu
