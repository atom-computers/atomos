setenv kernel_addr_r "0x40008000"
setenv initrd_addr_r "0x42000000"
setenv fdt_addr_r "0x44000000"
setenv kernel_image "vmlinuz"
setenv initrd_image "uInitrd"
setenv dtb_file "exynos5422-odroidhc1.dtb"

printenv

echo Setting bootargs
setenv bootargs init=/init.sh rw console=tty0 console=ttySAC2,115200 panic=10 consoleblank=0 loglevel=9 cma=256M initcall_blacklist=exynos_drm_init no_bL_switcher PMOS_FORCE_PARTITION_RESIZE

if test -e mmc ${mmcbootdev}:${mmcbootpart} ${kernel_image}; then
    echo Loading Kernel: vmlinuz
    load mmc ${mmcbootdev}:${mmcbootpart} ${kernel_addr_r} ${kernel_image};
fi

if test -e mmc ${mmcbootdev}:${mmcbootpart} ${kernel_image}-stable; then
    echo Loading Kernel: vmlinuz-stable
    load mmc ${mmcbootdev}:${mmcbootpart} ${kernel_addr_r} ${kernel_image}-stable
fi

if test -e mmc ${mmcbootdev}:${mmcbootpart} ${kernel_image}-edge; then
    echo Loading Kernel: vmlinuz-edge
    load mmc ${mmcbootdev}:${mmcbootpart} ${kernel_addr_r} ${kernel_image}-edge
fi

echo Loading Initramfs
load mmc ${mmcbootdev}:${mmcbootpart} ${initrd_addr_r} ${initrd_image}

echo Loading DTB
load mmc ${mmcbootdev}:${mmcbootpart} ${fdt_addr_r} ${dtb_file}

echo Resizing FDT
fdt addr ${fdt_addr_r}

echo Booting kernel
bootz ${kernel_addr_r} ${initrd_addr_r} ${fdt_addr_r}
