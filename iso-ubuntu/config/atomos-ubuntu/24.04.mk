# AtomOS Ubuntu 24.04 Configuration

DISTRO_NAME=AtomOS Ubuntu
DISTRO_VOLUME_LABEL=$(DISTRO_NAME) $(DISTRO_VERSION) $(DISTRO_ARCH)

# Show splash screen
DISTRO_PARAMS+=quiet splash

# Repositories to be present in installed system
RELEASE_URI:=$(UBUNTU_MIRROR)
SECURITY_URI:=$(UBUNTU_SECURITY)

# COSMIC DE repository (AtomOS release repository)
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
	grub-efi \
	policykit-1 \
	efibootmgr \
	fwupd-signed \
	mokutil \
	shim-signed \
	btrfs-progs \
	dosfstools \
	ntfs-3g \
	xfsprogs \
	e2fsprogs \
	libcom-err2 \
	libext2fs2t64 \
	libss2 \
	logsave \
	cryptsetup \
	cryptsetup-bin \
	lvm2


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
	just \
	meson \
	ninja-build \
	valac \
	libgtk-3-dev \
	libgee-0.8-dev \
	libgranite-dev \
	libjson-glib-dev \
	libxml2-dev \
	libgnomekbd-dev \
	libpwquality-dev \
	libdistinst-dev \
	desktop-file-utils

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

# Packages not installed, but that may need to be discovered by the installer
ifeq ($(DISTRO_ARCH),amd64)
MAIN_POOL=\
	at \
	btrfs-progs \
	cryptsetup \
	cryptsetup-bin \
	dosfstools \
	e2fsprogs \
	efibootmgr \
	ethtool \
	fwupd-signed \
	grub-efi-amd64 \
	grub-efi-amd64-bin \
	grub-efi-amd64-signed \
	grub-gfxpayload-lists \
	grub-pc \
	grub-pc-bin \
	hdparm \
	kernelstub \
	libcom-err2 \
	libext2fs2t64 \
	libfl2 \
	libss2 \
	lm-sensors \
	logsave \
	lvm2 \
	mokutil \
	ntfs-3g \
	pm-utils \
	postfix \
	powermgmt-base \
	python3-debian \
	python3-distro \
	python3-evdev \
	python3-systemd \
	shim-signed \
	xbacklight \
	xfsprogs
else ifeq ($(DISTRO_ARCH),arm64)
MAIN_POOL=\
	at \
	btrfs-progs \
	cryptsetup \
	cryptsetup-bin \
	dosfstools \
	e2fsprogs \
	efibootmgr \
	ethtool \
	fwupd-signed \
	grub-efi-arm64 \
	grub-efi-arm64-bin \
	grub-efi-arm64-signed \
	hdparm \
	kernelstub \
	libcom-err2 \
	libext2fs2t64 \
	libfl2 \
	libss2 \
	lm-sensors \
	logsave \
	lvm2 \
	mokutil \
	ntfs-3g \
	pm-utils \
	postfix \
	powermgmt-base \
	python3-debian \
	python3-distro \
	python3-evdev \
	python3-systemd \
	shim-signed \
	xbacklight \
	xfsprogs
endif

# Additional pool packages from the restricted set of packages
ifeq ($(DISTRO_ARCH),amd64)
RESTRICTED_POOL=\
	amd64-microcode \
	intel-microcode \
	iucode-tool
else
RESTRICTED_POOL=
endif

# Extra packages to install in the pool for use by iso creation
POOL_PKGS=\
	grub-efi-$(DISTRO_ARCH)-bin \
	grub-efi-$(DISTRO_ARCH)-signed \
	shim-signed

