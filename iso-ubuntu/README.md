# AtomOS Ubuntu ISO Build System

This directory contains a simplified ISO build system for creating Ubuntu 24.04 with COSMIC Desktop Environment.

## Features

- **Base**: Ubuntu 24.04 LTS (Noble)
- **Desktop**: COSMIC Desktop Environment
- **Custom Packages**:
  - PostgreSQL 18
  - SurrealDB
  - cocoindex (document indexing)
  - AtomOS sync service
  - cosmic-ext-applet-ollama

## Building with Podman (Recommended for macOS)

If you're on macOS or prefer containerized builds:

```bash
# Install Podman (macOS)
brew install podman

# Build the ISO in a container
./build-with-podman.sh

# Or use interactive shell for debugging
./podman-shell.sh
```

The Podman build automatically:
- Creates an Ubuntu 24.04 build environment
- Mounts all required dependencies (sync, cocoindex, cosmic-ext-applet-ollama)
- Runs the build with proper privileges
- Outputs the ISO to `build/` directory

See [PODMAN.md](PODMAN.md) for detailed Podman build documentation.

## Building Natively (Ubuntu/Debian)

### Prerequisites

Install the required build tools:

```bash
sudo apt-get install -y \
    debootstrap \
    squashfs-tools \
    xorriso \
    grub-pc-bin \
    grub-efi-amd64-bin \
    mtools \
    dosfstools \
    isolinux \
    syslinux-utils \
    zsync \
    gpg
```

### Building the ISO

```bash
# Build the ISO
make iso

# Build with all checksums and signatures
make all

# Clean build artifacts
make clean
```

## Testing

```bash
# Test in QEMU with KVM
make qemu

# Test in QEMU with UEFI
make qemu-uefi

# Test in QEMU with BIOS
make qemu-bios
```

## Build Targets

- `iso` - Build the ISO image
- `all` - Build ISO with zsync, SHA256SUMS, and GPG signature
- `chroot` - Build the chroot environment only
- `live` - Build the live filesystem only
- `clean` - Remove all build artifacts
- `qemu` - Test ISO in QEMU

## Directory Structure

```
iso-ubuntu/
├── Makefile                      # Main build file
├── Dockerfile                    # Podman/Docker build container
├── build-with-podman.sh         # Automated Podman build
├── podman-shell.sh              # Interactive Podman shell
├── config/                       # Distribution configurations
│   └── atomos-ubuntu/
│       └── 24.04.mk             # Ubuntu 24.04 config
├── mk/                           # Modular makefiles
│   ├── automatic.mk             # Automatic variables
│   ├── ubuntu.mk                # Ubuntu settings
│   ├── chroot.mk                # Chroot build
│   ├── iso.mk                   # ISO creation
│   ├── clean.mk                 # Cleanup targets
│   └── qemu.mk                  # Testing targets
├── scripts/                      # Installation scripts
│   ├── install-postgresql.sh
│   ├── install-surrealdb.sh
│   ├── install-cocoindex.sh
│   ├── install-sync.sh
│   └── install-ollama-applet.sh
└── data/                         # Data files
    ├── grub/                    # GRUB configuration
    └── disk/                    # Disk metadata
```

## Build Process

1. **Bootstrap**: Create base Ubuntu system with debootstrap
2. **Package Installation**: Install COSMIC DE and dependencies
3. **Custom Packages**: Run installation scripts for custom software
4. **Live System**: Create live filesystem from chroot
5. **Squashfs**: Compress live filesystem
6. **ISO Assembly**: Create bootable ISO with GRUB

## Configuration

Edit `config/atomos-ubuntu/24.04.mk` to customize:
- Package lists
- Kernel parameters
- Volume label
- Repository URLs

## Notes

- The build process requires root privileges (sudo)
- First build will take significant time to download packages
- Subsequent builds reuse the chroot if available
- Custom packages are built from source during chroot phase
