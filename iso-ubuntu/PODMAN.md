# Podman Build Notes

## Overview

The Podman build system allows you to build the AtomOS Ubuntu ISO on macOS (or any system with Podman) without needing a native Linux environment.

## Files

- **Dockerfile**: Ubuntu 24.04 container with all build dependencies
- **build-with-podman.sh**: Automated build script
- **podman-shell.sh**: Interactive shell for debugging

## How It Works

1. **Container Image**: Based on Ubuntu 24.04 with all ISO build tools
2. **Volume Mounts**: 
   - `iso-ubuntu/` → `/build` (build directory)
   - `sync/` → `/build-deps/sync` (sync service)
   - `cosmic-ext-applet-ollama/` → `/build-deps/cosmic-ext-applet-ollama` (applet)
   - `cocoindex/` → `/build-deps/cocoindex` (indexing library)
3. **Privileged Mode**: Required for debootstrap and loop device mounting
4. **Build User**: Non-root user with sudo access for security

## Usage

### Quick Build

```bash
./build-with-podman.sh
```

### Interactive Development

```bash
./podman-shell.sh
# Inside container:
sudo make iso
```

### Clean Build

```bash
./podman-shell.sh
# Inside container:
sudo make clean
sudo make iso
```

## Troubleshooting

### Podman machine not running

```bash
podman machine init
podman machine start
```

### Permission issues

The build requires `--privileged` mode for:
- Creating loop devices
- Running debootstrap
- Mounting filesystems
- Building squashfs

### Volume mount issues

If files aren't visible in the container, check SELinux labels with `:z` suffix on volume mounts.

## Performance

- **First build**: ~30-60 minutes (downloads packages)
- **Subsequent builds**: ~10-20 minutes (reuses chroot)
- **Clean builds**: Same as first build

## Limitations

- Requires significant disk space (~10GB for build artifacts)
- Requires Podman machine on macOS (uses VM)
- Build artifacts owned by root (use `sudo` to clean)
