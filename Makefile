# Atom OS Wrapper Makefile
# This Makefile wraps the Redox build system to provide a convenient interface
# from the root of the repository.

# Configuration
ARCH ?= aarch64
CONFIG_NAME ?= atom
REDOX_DIR = redox
REDOX_BUILD = redox-build
CONFIG_SRC = config/atom.toml
CONFIG_DEST = $(REDOX_BUILD)/config/$(ARCH)/$(CONFIG_NAME).toml

.PHONY: all qemu sync help setup-build

# Default target
all: setup-build sync
	@echo "Building Atom OS for $(ARCH)..."
	@echo "Building Atom OS for $(ARCH)..."
	@if ! podman image exists redox-base; then \
		echo "Building Podman image..."; \
		sed s/_UID_/`id -u`/ config/containerfile | podman build --file - --tag redox-base; \
	fi
	@if [ ! -d "$(REDOX_BUILD)/build/podman_home/.cargo" ]; then \
		echo "Installing Rust in Podman container..."; \
		podman run --privileged --rm -v $$(pwd)/$(REDOX_BUILD)/build:/data debian:bookworm-slim sh -c "chown -R $$(id -u):$$(id -g) /data/podman_home || true; rm -rf /data/podman_home"; \
		rm -rf $(REDOX_BUILD)/build/podman_home; \
		mkdir -p $(REDOX_BUILD)/build/podman_home; \
		chmod 777 $(REDOX_BUILD)/build/podman_home; \
		podman run --rm --workdir /mnt/redox \
			--userns keep-id --user $$(id -u) \
			-v $$(pwd)/$(REDOX_BUILD):/mnt/redox:Z \
			-v $$(pwd)/$(REDOX_BUILD)/build/podman_home:/home:Z \
			--env PATH=/home/poduser/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
			redox-base bash -e podman/rustinstall.sh; \
	fi
	podman run --rm --workdir /mnt/redox \
		--userns keep-id --user $$(id -u) \
		-v $$(pwd)/$(REDOX_BUILD):/mnt/redox:Z \
		-v $$(pwd)/$(REDOX_BUILD)/build/podman_home:/home:Z \
		--env ARCH=$(ARCH) \
		--env CONFIG_NAME=$(CONFIG_NAME) \
		--env PODMAN_BUILD=0 \
		--env PATH=/home/poduser/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
		redox-base \
		make all ARCH=$(ARCH) CONFIG_NAME=$(CONFIG_NAME)

# Run in QEMU
qemu: all
	@echo "Running Atom OS in QEMU (on host)..."
	$(MAKE) -C $(REDOX_BUILD) qemu ARCH=$(ARCH) CONFIG_NAME=$(CONFIG_NAME) PODMAN_BUILD=0 SKIP_CHECK_TOOLS=1 live=no disk=nvme \
		-o build/$(ARCH)/$(CONFIG_NAME)/harddrive.img \
		-o build/$(ARCH)/$(CONFIG_NAME)/repo.tag \
		-o prefix

# Setup build directory and patch sources
setup-build:
	@echo "Setting up build directory..."
	@mkdir -p $(REDOX_BUILD)
	@rsync -a --exclude='source.tmp' --exclude='target' --exclude='/build' --exclude='mk/prefix.mk' $(REDOX_DIR)/ $(REDOX_BUILD)/
	@mkdir -p $(REDOX_BUILD)/mk
	@# Generate patched prefix.mk and only update the file if it changed to prevent unnecessary rebuilds
	@sed 's/`$$(NPROC)`/1/g' $(REDOX_DIR)/mk/prefix.mk > $(REDOX_BUILD)/mk/prefix.mk.tmp
	@if ! cmp -s $(REDOX_BUILD)/mk/prefix.mk.tmp $(REDOX_BUILD)/mk/prefix.mk; then \
		mv $(REDOX_BUILD)/mk/prefix.mk.tmp $(REDOX_BUILD)/mk/prefix.mk; \
		echo "Updated mk/prefix.mk"; \
	else \
		rm $(REDOX_BUILD)/mk/prefix.mk.tmp; \
	fi


# Sync configuration
sync:
	@echo "Syncing configuration..."
	@mkdir -p $(dir $(CONFIG_DEST))
	@rm -f $(abspath $(CONFIG_DEST))
	@cp $(abspath $(CONFIG_SRC)) $(abspath $(CONFIG_DEST))
	@echo "Configuration copied: $(CONFIG_SRC) -> $(CONFIG_DEST)"
	@if [ -d "config/files" ]; then \
		echo "Syncing files..."; \
		mkdir -p $(REDOX_BUILD)/config/$(ARCH)/files; \
		rsync -av config/files/ $(REDOX_BUILD)/config/$(ARCH)/files/; \
	fi
	@if [ -d "config/recipes" ]; then \
		echo "Syncing recipes..."; \
		mkdir -p $(REDOX_BUILD)/cookbook/recipes; \
		rsync -av config/recipes/ $(REDOX_BUILD)/cookbook/recipes/; \
	fi

# Clean the redox build
# Clean the redox build
clean:
	rm -rf $(REDOX_BUILD)

# Help
help:
	@echo "Atom OS Build System"
	@echo ""
	@echo "Available targets:"
	@echo "  all    - Build the Atom OS image (wraps 'make all' in redox-build/)"
	@echo "  qemu   - Run Atom OS in QEMU (wraps 'make qemu' in redox-build/)"
	@echo "  sync   - Symlink config to redox-build/config/"
	@echo "  clean  - Clean the build artifacts"
