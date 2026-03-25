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
	ripgrep \
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
	lvm2 \
	snapd \
	kernelstub \
	udisks2 \
	spice-vdagent \
	qemu-guest-agent \
	openssh-server \
	netplan.io \
	avahi-autoipd \
	avahi-daemon \
	libnss-mdns \
	libnss-myhostname \
	net-tools \
	iputils-ping \
	iputils-tracepath \
	curl \
	ufw \
	dkms \
	gvfs \
	gvfs-backends \
	gvfs-fuse \
	ubuntu-standard \
	adduser \
	adwaita-icon-theme-full \
	alsa-base \
	apt \
	apt-transport-https \
	baobab \
	base-files \
	base-passwd \
	bash \
	bash-completion \
	bluez \
	bluez-cups \
	brltty \
	bsdutils \
	busybox-static \
	chrome-gnome-shell \
	command-not-found \
	coreutils \
	cups \
	cups-bsd \
	dash \
	dbus-broker \
	dbus-user-session \
	debconf \
	debianutils \
	diffutils \
	dpkg \
	eog \
	evince \
	file-roller \
	findutils \
	flatpak \
	fonts-dejavu-core \
	fonts-freefont-ttf \
	fonts-liberation \
	fonts-noto-color-emoji \
	friendly-recovery \
	ftp \
	fwupd \
	fwupdate \
	gcc-12-base \
	gdm3 \
	geary \
	gedit \
	ghostscript-x \
	glib-networking \
	gnome-bluetooth \
	gnome-calculator \
	gnome-calendar \
	gnome-contacts \
	gnome-control-center \
	gnome-disk-utility \
	gnome-font-viewer \
	gnome-menus \
	gnome-power-manager \
	gnome-remote-desktop \
	gnome-shell \
	gnome-shell-extension-prefs \
	gnome-system-monitor \
	gnome-terminal \
	gnome-video-effects \
	gnome-weather \
	gpgv \
	grep \
	gstreamer1.0-alsa \
	gstreamer1.0-plugins-base-apps \
	gstreamer1.0-vaapi \
	gucharmap \
	gzip \
	hidpi-daemon \
	hostname \
	ibus-table \
	ibus-table-emoji \
	ifupdown \
	info \
	init-system-helpers \
	inputattach \
	language-selector-gnome \
	libacl1 \
	libapt-pkg6.0 \
	libasound2-plugins \
	libatk-adaptor \
	libattr1 \
	libaudit-common \
	libaudit1 \
	libblkid1 \
	libbz2-1.0 \
	libc-bin \
	libc6 \
	libcanberra-gtk-module \
	libcap-ng0 \
	libcap2 \
	libcrypt1 \
	libdb5.3 \
	libdebconfclient0 \
	libegl-mesa0 \
	libext2fs2 \
	libffi8 \
	libfreeaptx0 \
	libfuse2 \
	libgcc-s1 \
	libgcrypt20 \
	libglib2.0-bin \
	libgmp10 \
	libgnutls30 \
	libgpg-error0 \
	libgssapi-krb5-2 \
	libhogweed6 \
	libidn2-0 \
	libk5crypto3 \
	libkeyutils1 \
	libkrb5-3 \
	libkrb5support0 \
	libldacbt-abr2 \
	libldacbt-enc2 \
	liblz4-1 \
	liblzma5 \
	libmount1 \
	libncurses6 \
	libncursesw6 \
	libnettle8 \
	libnsl2 \
	libp11-kit0 \
	libpam-gnome-keyring \
	libpam-modules \
	libpam-modules-bin \
	libpam-runtime \
	libpam0g \
	libpcre2-8-0 \
	libpcre3 \
	libproxy1-plugin-gsettings \
	libproxy1-plugin-networkmanager \
	libreoffice-calc \
	libreoffice-gnome \
	libreoffice-impress \
	libreoffice-ogltrans \
	libreoffice-writer \
	libseccomp2 \
	libselinux1 \
	libsemanage-common \
	libsemanage2 \
	libsepol2 \
	libsmartcols1 \
	libspa-0.2-bluetooth \
	libspa-0.2-jack \
	libssl3 \
	libstdc++6 \
	libsystemd0 \
	libtasn1-6 \
	libtinfo6 \
	libtirpc-common \
	libtirpc3 \
	libudev1 \
	libuuid1 \
	libvdpau-va-gl1 \
	libxxhash0 \
	libzstd1 \
	linux-system76 \
	login \
	lsb-base \
	lshw \
	man-db \
	mawk \
	mesa-va-drivers \
	mesa-vulkan-drivers \
	mount \
	mtr-tiny \
	nano \
	nautilus \
	nautilus-sendto \
	ncurses-base \
	ncurses-bin \
	network-manager-config-connectivity-pop \
	network-manager-openvpn-gnome \
	network-manager-pptp-gnome \
	openprinting-ppds \
	passwd \
	pcmciautils \
	perl-base \
	pipewire \
	pipewire-alsa \
	pipewire-jack \
	pipewire-pulse \
	policykit-desktop-privileges \
	pop-keyring \
	popsicle \
	popsicle-gtk \
	printer-driver-all \
	procps \
	rfkill \
	seahorse \
	sed \
	sensible-utils \
	sessioninstaller \
	simple-scan \
	sound-theme-freedesktop \
	strace \
	system76-scheduler \
	systemd-resolvconf \
	systemd-sysv \
	sysvinit-utils \
	tar \
	tcpdump \
	telnet \
	time \
	tnftp \
	totem \
	touchegg \
	ubuntu-drivers-common \
	ubuntu-keyring \
	util-linux \
	vdpau-driver-all \
	wireless-tools \
	wireplumber \
	xdg-desktop-portal-gnome \
	xdg-user-dirs-gtk \
	xdg-utils \
	xorg \
	yelp \
	zlib1g


ifeq ($(DISTRO_ARCH),amd64)
DISTRO_PKGS+=\
	grub-pc-bin \
	grub-efi-amd64-bin \
	virtualbox-guest-utils \
	virtualbox-guest-x11
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
	chromium-browser \
	pop-fonts \
	tmux


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
	protobuf-compiler \
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
	ubuntu-advantage-tools

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
	systemd-boot \
	systemd-boot-efi \
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
	systemd-boot \
	systemd-boot-efi \
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

