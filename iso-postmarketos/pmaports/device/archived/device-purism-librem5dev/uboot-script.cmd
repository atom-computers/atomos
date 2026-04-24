setenv bootargs init=/init.sh rw console=ttymxc0,115200 cma=256M PMOS_FORCE_PARTITION_RESIZE
setenv mmcdev 0
setenv mmcpart 1

printenv
echo Loading DTB
ext2load mmc ${mmcdev}:${mmcpart} ${fdt_addr_r} imx8mq-librem5-devkit.dtb

echo Loading Initramfs
ext2load mmc ${mmcdev}:${mmcpart} ${ramdisk_addr_r} uInitrd

echo Loading Kernel
ext2load mmc ${mmcdev}:${mmcpart} ${kernel_addr_r} vmlinuz

echo Resizing FDT
fdt addr ${fdt_addr_r}
fdt resize

echo Booting kernel
booti ${kernel_addr_r} ${ramdisk_addr_r}:${filesize} ${fdt_addr_r}
