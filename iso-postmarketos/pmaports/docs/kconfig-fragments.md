# Fragment-Based Kernel Configuration

Fragment-based configuration makes it easy to keep kernel packages up to date with distro requirements. When new requirements are added to kconfigcheck.toml, maintainers quickly and easily incorporate them into their kernel packages. Maintainers can also add package-specific requirements via custom fragments.

The kernel's build system will silently drop config if dependencies are unmet, which can be difficult to notice and debug. To counter this, the fragment sytem validates that all specified config from fragments is actually present in the final generated configuration.

## Overview

Fragment-based kernel packages in postmarketOS generate their final configuration using `pmbootstrap kconfig generate`, which pulls kernel configuration from multiple sources:

1. **defconfig**: base configuration from the kernel source tree
2. **kconfigcheck.toml**: distro-wide requirements, selected via `pmb:kconfigcheck-*` options in the APKBUILD
3. **custom fragments**: custom `.config` files in the kernel package directory

pmbootstrap combines these sources and validates that all specified options are present in the final configuration. If validation fails, it typically indicates missing dependencies that must be explicitly added to either `kconfigcheck.toml` or a custom fragment, depending on where the missing config is defined.

## Migration

To convert an existing kernel package to use fragments:

### APKBUILD Changes

Add custom `.config` fragment files to `sources=` and define which defconfig to use:

```bash
_defconfig="defconfig"
sources="
    $pkgname.config
    misc.config
"
```

Verify that `pmb:kconfigcheck-*` categories in the `options=` variable are correct, as these determine which `kconfigcheck.toml` sections are included.

### Creating Custom Fragments

If using a generic defconfig, device-specific drivers may not be enabled. Create a fragment explicitly listing required options, for example:

```
$ cat asahi.config
CONFIG_PCIE_APPLE=m
CONFIG_NVME_APPLE=m
CONFIG_ARM64_ACTLR_STATE=y
CONFIG_ARCH_APPLE=y
CONFIG_DRM=y
CONFIG_DRM_ASAHI=m
# CONFIG_ARM64_4K_PAGES is not set
CONFIG_ARM64_16K_PAGES=y
```

Fragments can be named `<name>.config` to apply to all architectures, or `<name>.$ARCH.config` to apply only to a specific architecture (e.g., `generic.aarch64.config`, `custom.x86_64.config`). pmbootstrap automatically selects the appropriate fragments based on the build architecture.

**Note:** Multiple custom fragments are supported. Do not name any fragment `pmos.config` or `pmos.$ARCH.config`, these filenames are reserved and will be overwritten by `pmbootstrap kconfig generate`.

## Maintenance

### Kernel Upgrades

Run `pmbootstrap kconfig generate` when upgrading the kernel. This automatically:

- Generates `pmos.config` fragment based on selected categories from `kconfigcheck.toml`
- Generates a full configuration for the kernel version using the APKBUILD's `$_defconfig`, `pmos.config`, and any fragments from the kernel package
- Validates the final configuration for anything that might be missing

Do not manually edit generated files, changes will be overwritten on the next `kconfig generate` run.

### Modifying Configuration

To create a new fragment:

```bash
$ pmbootstrap kconfig edit --fragment foo.config
```

Changes are saved to `foo.config`. If the fragment already exists, it will be overwritten.

To modify an existing fragment: edit it directly, or use `kconfig edit --fragment` with a new filename and merge the differences manually.
