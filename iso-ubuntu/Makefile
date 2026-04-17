# AtomOS Ubuntu COSMIC ISO Build System
# Simplified Makefile for building Ubuntu 24.04 with COSMIC DE

# Configuration settings
DISTRO_CODE?=atomos-ubuntu
DISTRO_VERSION?=24.04
DISTRO_ARCH?=$(shell if command -v dpkg >/dev/null 2>&1; then dpkg --print-architecture; else arch="$$(uname -m)"; if [ "$$arch" = "x86_64" ] || [ "$$arch" = "amd64" ]; then echo amd64; elif [ "$$arch" = "aarch64" ] || [ "$$arch" = "arm64" ]; then echo arm64; else echo unknown; fi; fi)

# Normalize common architecture aliases to Debian names used by package lists.
DISTRO_ARCH:=$(patsubst x86_64,amd64,$(DISTRO_ARCH))
DISTRO_ARCH:=$(patsubst aarch64,arm64,$(DISTRO_ARCH))

ifeq ($(DISTRO_ARCH),unknown)
$(error Unable to detect DISTRO_ARCH. Install dpkg or pass DISTRO_ARCH=amd64|arm64)
endif

DISTRO_EPOCH?=$(shell date +%s)
DISTRO_DATE?=$(shell date +%Y%m%d)

DISTRO_PARAMS?=

ISO_NAME?=$(DISTRO_CODE)_$(DISTRO_VERSION)_$(DISTRO_ARCH)_$(DISTRO_DATE)

GPG_NAME?=`id -un`

# Include automatic variables
include mk/automatic.mk

# Include Ubuntu definitions
include mk/ubuntu.mk

# Include configuration file
include config/$(DISTRO_CODE)/$(DISTRO_VERSION).mk

# Standard target - build the ISO
iso: $(ISO)

# Complete target - build zsync file, SHA256SUMS, and GPG signature
all: $(ISO) $(ISO).zsync $(BUILD)/SHA256SUMS $(BUILD)/SHA256SUMS.gpg

# Serve the built ISO over HTTP
serve: all
	cd $(BUILD) && python3 -m http.server 8909

# Clean target
include mk/clean.mk

# QEMU targets for testing
include mk/qemu.mk

# Chroot targets for building the system
include mk/chroot.mk

# GPG targets
include mk/gpg.mk

# ISO targets for creating the final image
include mk/iso.mk

# Force target
FORCE:

.PHONY: iso all serve clean FORCE
