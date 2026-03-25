SHELL := /bin/bash
ROOT_DIR := $(CURDIR)

.PHONY: help build

help:
	@echo "Single-path image build:"
	@echo "  make build"
	@echo ""
	@echo "Build output:"
	@echo "  build/host-export-fairphone-fp4/boot.img"
	@echo "  build/host-export-fairphone-fp4/fairphone-fp4.img"

build:
	@bash "$(ROOT_DIR)/scripts/build-image.sh"
