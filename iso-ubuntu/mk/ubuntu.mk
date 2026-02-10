# Ubuntu-specific variables

# Ubuntu version and codename
UBUNTU_VERSION=24.04
UBUNTU_CODE=noble

# Ubuntu repositories
UBUNTU_MIRROR?=http://archive.ubuntu.com/ubuntu
UBUNTU_SECURITY?=http://security.ubuntu.com/ubuntu

# Ubuntu keyring
UBUNTU_KEYRING=/usr/share/keyrings/ubuntu-archive-keyring.gpg

# Debootstrap variant
DEBOOTSTRAP_VARIANT?=minbase

# Architecture-specific settings
ifeq ($(DISTRO_ARCH),arm64)
UBUNTU_MIRROR=http://ports.ubuntu.com/ubuntu-ports
UBUNTU_SECURITY=http://ports.ubuntu.com/ubuntu-ports
endif
