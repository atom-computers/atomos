# Automatic variables for ISO build system

# Build directory
BUILD?=build/$(DISTRO_CODE)/$(DISTRO_VERSION)/$(DISTRO_ARCH)

# ISO file path
ISO=$(BUILD)/$(ISO_NAME).iso

# TAR file path (optional)
TAR=$(BUILD)/$(ISO_NAME).tar

# Casper path (for live filesystem)
CASPER_PATH=casper

# SED substitution for template files
SED=\
	s|DISTRO_NAME|$(DISTRO_NAME)|g; \
	s|DISTRO_CODE|$(DISTRO_CODE)|g; \
	s|DISTRO_VERSION|$(DISTRO_VERSION)|g; \
	s|DISTRO_ARCH|$(DISTRO_ARCH)|g; \
	s|DISTRO_EPOCH|$(DISTRO_EPOCH)|g; \
	s|DISTRO_DATE|$(DISTRO_DATE)|g; \
	s|DISTRO_PARAMS|$(DISTRO_PARAMS)|g; \
	s|DISTRO_VOLUME_LABEL|$(DISTRO_VOLUME_LABEL)|g; \
	s|UBUNTU_CODE|$(UBUNTU_CODE)|g; \
	s|UBUNTU_VERSION|$(UBUNTU_VERSION)|g;
