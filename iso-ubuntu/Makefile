# AtomOS Ubuntu COSMIC ISO Build System
# Simplified Makefile for building Ubuntu 24.04 with COSMIC DE

# Configuration settings
DISTRO_CODE?=atomos-ubuntu
DISTRO_VERSION?=24.04
DISTRO_ARCH?=$(shell dpkg --print-architecture)

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
