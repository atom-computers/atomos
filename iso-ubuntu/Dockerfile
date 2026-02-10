FROM ubuntu:24.04

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install build dependencies
# Note: Architecture-specific GRUB packages will be installed in the target chroot
RUN apt-get update && apt-get install -y \
    debootstrap \
    squashfs-tools \
    xorriso \
    grub2-common \
    grub-common \
    # grub-pc-bin \
    grub-efi \
    # grub-efi-amd64-bin \
    grub-efi-arm64-bin \
    mtools \
    dosfstools \
    isolinux \
    zsync \
    gpg \
    wget \
    curl \
    git \
    make \
    rsync \
    ca-certificates \
    gnupg \
    lsb-release \
    software-properties-common \
    sudo \
    && rm -rf /var/lib/apt/lists/*

# Create build user with sudo access
RUN useradd -m -s /bin/bash builder && \
    echo "builder ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# Set working directory
WORKDIR /build

# Switch to builder user
USER builder

# Default command
CMD ["/bin/bash"]
