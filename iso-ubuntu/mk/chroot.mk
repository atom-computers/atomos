# Chroot build targets
# Note: These targets assume running as root (required for debootstrap and chroot)

# Dependency source paths
# Detect if running in container with /build-deps mounts (Podman/Docker)
ifneq ($(wildcard /build-deps/sync),)
	SYNC_SRC := /build-deps/sync
else
	SYNC_SRC := ../sync
endif

ifneq ($(wildcard /build-deps/cosmic-ext-applet-ollama),)
	APPLET_SRC := /build-deps/cosmic-ext-applet-ollama
else
	APPLET_SRC := ../cosmic-ext-applet-ollama
endif

ifneq ($(wildcard /build-deps/cocoindex),)
	COCOINDEX_SRC := /build-deps/cocoindex
else
	COCOINDEX_SRC := ../cocoindex
endif

ifneq ($(wildcard /build-deps/atom-installer),)
	ATOM_INSTALLER_SRC := /build-deps/atom-installer
else
	ATOM_INSTALLER_SRC := ../atom-installer
endif

$(BUILD)/pool: $(BUILD)/chroot
	# Unmount chroot if mounted
	scripts/unmount.sh "$@.partial"

	# Remove old chroot
	sudo rm -rf "$@" "$@.partial"

	# Copy chroot
	sudo cp -a "$<" "$@.partial"

	# Make temp directory for modifications
	sudo rm -rf "$@.partial/iso"
	sudo mkdir -p "$@.partial/iso"

	# Create pool directory
	sudo mkdir -p "$@.partial/iso/pool"

	# Copy chroot script
	sudo cp "scripts/install-pool.sh" "$@.partial/iso/install-pool.sh"

	# Mount chroot
	"scripts/mount.sh" "$@.partial"

	# Run chroot script
	sudo chroot "$@.partial" /bin/bash -e -c \
		"MAIN_POOL=\"$(MAIN_POOL)\" \
		RESTRICTED_POOL=\"$(RESTRICTED_POOL)\" \
		clean=1 \
		/iso/install-pool.sh"

	# Unmount chroot
	"scripts/unmount.sh" "$@.partial"

	# Save package pool
	sudo mv "$@.partial/iso/pool" "$@.partial/pool"

	# Remove temp directory for modifications
	sudo rm -rf "$@.partial/iso"

	sudo touch "$@.partial"
	sudo mv "$@.partial" "$@"

$(BUILD)/chroot.tag: $(BUILD)/iso-key.gpg $(BUILD)/iso-pub.gpg
	# Remove old chroot
	rm -rf "$(BUILD)/chroot"
	
	# Create build directory
	mkdir -p "$(BUILD)"
	
	# Bootstrap base system
	debootstrap \
		--arch=$(DISTRO_ARCH) \
		--variant=$(DEBOOTSTRAP_VARIANT) \
		--components=main,restricted,universe,multiverse \
		--extractor=dpkg-deb \
		--verbose \
		$(UBUNTU_CODE) \
		"$(BUILD)/chroot" \
		$(UBUNTU_MIRROR)
	
	# Mount necessary filesystems for chroot operations
	mount --bind /dev "$(BUILD)/chroot/dev"
	mount --bind /proc "$(BUILD)/chroot/proc"
	mount --bind /sys "$(BUILD)/chroot/sys"
	
	# Remove legacy apt keyring file that triggers apt-key
	# The trusted.gpg FILE is created by debootstrap and causes apt-key to be called
	# which fails in containerized environments. Keep the DIRECTORY for our own keys.
	rm -f "$(BUILD)/chroot/etc/apt/trusted.gpg"
	mkdir -p "$(BUILD)/chroot/etc/apt/trusted.gpg.d"
	
	# Configure APT sources with signed-by to use modern GPG verification
	# This uses the Ubuntu keyring that was installed by debootstrap
	echo "deb [signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] $(UBUNTU_MIRROR) $(UBUNTU_CODE) main restricted universe multiverse" | tee "$(BUILD)/chroot/etc/apt/sources.list"
	echo "deb [signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] $(UBUNTU_MIRROR) $(UBUNTU_CODE)-updates main restricted universe multiverse" | tee -a "$(BUILD)/chroot/etc/apt/sources.list"
	echo "deb [signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] $(UBUNTU_SECURITY) $(UBUNTU_CODE)-security main restricted universe multiverse" | tee -a "$(BUILD)/chroot/etc/apt/sources.list"
	
	# Update package lists - APT will use gpgv directly via signed-by, not apt-key
	chroot "$(BUILD)/chroot" apt-get update
	
	# Fetch and install Pop!_OS signing key for COSMIC packages
	# Mirroring reference implementation in iso/deps.sh and iso/mk/chroot.mk
	gpg --keyserver keyserver.ubuntu.com --recv-keys 204DD8AEC33A7AFF || \
		gpg --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys 204DD8AEC33A7AFF
	gpg --batch --yes --export "204DD8AEC33A7AFF" > "$(BUILD)/chroot/usr/share/keyrings/pop-archive-keyring.gpg"
	
	# Configure COSMIC repository using direct URL
	# Add System76/Pop!_OS release repository with COSMIC packages
	echo "deb [signed-by=/usr/share/keyrings/pop-archive-keyring.gpg] $(COSMIC_REPO_URL) $(UBUNTU_CODE) main" | tee "$(BUILD)/chroot/etc/apt/sources.list.d/cosmic.list"
	
	# Update package lists
	chroot "$(BUILD)/chroot" apt-get update
	
	# Prevent Pop!_OS linux-firmware from being installed as it causes build failures
	# and conflicts with Ubuntu kernel packages in this context
	printf "Package: linux-firmware\nPin: release o=pop-os-release\nPin-Priority: -1\n" > "$(BUILD)/chroot/etc/apt/preferences.d/pin-pop-os"

	
	# Install packages
	chroot "$(BUILD)/chroot" apt-get install -y $(ALL_PKGS)
	
	# Copy custom installation scripts
	mkdir -p "$(BUILD)/chroot/tmp/atomos-install"
	cp scripts/*.sh "$(BUILD)/chroot/tmp/atomos-install/"
	chmod +x "$(BUILD)/chroot/tmp/atomos-install/"*.sh
	

	# Copy sync service files
	# Use rsync to exclude build artifacts (target, node_modules) which cause I/O errors on shared mounts
	rsync -a --no-owner --no-group \
		--exclude='target' --exclude='node_modules' --exclude='.git' --exclude='.venv' --exclude='__pycache__' \
		"$(SYNC_SRC)/" "$(BUILD)/chroot/tmp/atomos-install/sync/"

	# Copy cosmic-ext-applet-ollama
	rsync -a --no-owner --no-group \
		--exclude='target' --exclude='node_modules' --exclude='.git' \
		"$(APPLET_SRC)/" "$(BUILD)/chroot/tmp/atomos-install/cosmic-ext-applet-ollama/"
	
	# Copy cocoindex
	rsync -a --no-owner --no-group \
		--exclude='target' --exclude='node_modules' --exclude='.git' --exclude='uv.lock' \
		"$(COCOINDEX_SRC)/" "$(BUILD)/chroot/tmp/atomos-install/cocoindex/"
	
	# Copy atom-installer
	rsync -a --no-owner --no-group \
		--exclude='target' --exclude='.git' \
		"$(ATOM_INSTALLER_SRC)/" "$(BUILD)/chroot/tmp/atomos-install/atom-installer/"
	
	# Run custom installation scripts
	chroot "$(BUILD)/chroot" /tmp/atomos-install/install-postgresql.sh
	chroot "$(BUILD)/chroot" /tmp/atomos-install/install-surrealdb.sh
	chroot "$(BUILD)/chroot" /tmp/atomos-install/install-cocoindex.sh
	chroot "$(BUILD)/chroot" /tmp/atomos-install/install-sync.sh
	chroot "$(BUILD)/chroot" /tmp/atomos-install/install-ollama-applet.sh
	chroot "$(BUILD)/chroot" /tmp/atomos-install/install-atom-installer.sh
	chroot "$(BUILD)/chroot" /tmp/atomos-install/install-distinst-custom.sh
	chroot "$(BUILD)/chroot" /tmp/atomos-install/install-live-config.sh

	# Clean up
	chroot "$(BUILD)/chroot" apt-get clean
	rm -rf "$(BUILD)/chroot/tmp/atomos-install"
	
	# Unmount filesystems
	umount "$(BUILD)/chroot/dev" || true
	umount "$(BUILD)/chroot/proc" || true
	umount "$(BUILD)/chroot/sys" || true
	
	# Create manifest
	chroot "$(BUILD)/chroot" dpkg-query -W --showformat='$${Package}\t$${Version}\n' > "$(BUILD)/chroot.tag"

	# Install GPG key for CD-ROM verification (required by distinst's apt-cdrom add)
	mkdir -p "$(BUILD)/chroot/etc/apt/trusted.gpg.d"
	cp "$(BUILD)/iso-pub.gpg" "$(BUILD)/chroot/etc/apt/trusted.gpg.d/atomos-builder.gpg"

	touch "$@"

$(BUILD)/live.tag: $(BUILD)/chroot.tag
	# Remove old live system
	rm -rf "$(BUILD)/live"
	
	# Copy chroot to live
	cp -a "$(BUILD)/chroot" "$(BUILD)/live"
	
	# Remove packages from live system
	chroot "$(BUILD)/live" apt-get purge -y $(RM_PKGS) || true
	chroot "$(BUILD)/live" apt-get autoremove -y
	chroot "$(BUILD)/live" apt-get clean
	
	# Remove apt lists to prevent installer from trying to access network mirrors
	# or seeing package versions that are not on the ISO
	rm -rf "$(BUILD)/live/var/lib/apt/lists/"*
	
	# Create live manifest
	chroot "$(BUILD)/live" dpkg-query -W --showformat='$${Package}\t$${Version}\n' > "$(BUILD)/live.tag"
	
	touch "$@"


.PHONY: chroot live
chroot: $(BUILD)/chroot.tag
live: $(BUILD)/live.tag
