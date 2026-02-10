# AtomOS Ubuntu 24.04 Configuration

DISTRO_NAME=AtomOS Ubuntu
DISTRO_VOLUME_LABEL=$(DISTRO_NAME) $(DISTRO_VERSION) $(DISTRO_ARCH)

# Show splash screen
DISTRO_PARAMS+=quiet splash

# Repositories to be present in installed system
RELEASE_URI:=$(UBUNTU_MIRROR)
SECURITY_URI:=$(UBUNTU_SECURITY)

# COSMIC DE repository (Pop!_OS release repository)
COSMIC_REPO_URL:=http://apt.pop-os.org/release

# Base packages to install
DISTRO_PKGS=\
	systemd \
	linux-generic \
	ubuntu-minimal \
	network-manager \
	sudo \
	wget \
	git \
	gnupg \
	build-essential \
	grub-efi

ifeq ($(DISTRO_ARCH),amd64)
DISTRO_PKGS+=\
	grub-pc-bin \
	grub-efi-amd64-bin
else
DISTRO_PKGS+=\
	grub-efi-arm64-bin
endif

# COSMIC Desktop Environment packages
COSMIC_PKGS=\
	cosmic-session \
	cosmic-greeter \
	cosmic-comp \
	cosmic-panel \
	cosmic-launcher \
	cosmic-applets \
	cosmic-settings \
	cosmic-files \
	cosmic-term \
	cosmic-edit \
	pop-fonts

# Development tools for building custom packages
BUILD_PKGS=\
	cargo \
	rustc \
	python3 \
	python3-pip \
	python3-venv \
	postgresql-client \
	libpq-dev \
	pkg-config \
	libssl-dev \
	just

# Live ISO packages
LIVE_PKGS=\
	casper \
	discover \
	laptop-detect \
	os-prober

# Packages to remove from installed system
RM_PKGS=\
	snapd \
	ubuntu-advantage-tools

# All packages combined
ALL_PKGS=$(DISTRO_PKGS) $(COSMIC_PKGS) $(BUILD_PKGS) $(LIVE_PKGS)
