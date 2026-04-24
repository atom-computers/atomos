setenv kernel-flavor postmarketos-allwinner

setenv bootargs init=/init.sh rw console=tty1 panic=10 consoleblank=0 loglevel=1 PMOS_FORCE_PARTITION_RESIZE pmos_boot=/dev/mmcblk0p1 pmos_root=/dev/mmcblk0p2

echo Loading DTB: dtbs/${fdtfile}
load mmc 0:1 ${fdt_addr_r} dtbs/${fdtfile}

echo Resizing FDT
fdt addr ${fdt_addr_r}
fdt resize

echo Loading Kernel: vmlinuz
load mmc 0:1 ${kernel_addr_r} vmlinuz

echo Loading Initramfs: initramfs
load mmc 0:1 ${ramdisk_addr_r} initramfs

echo Booting kernel
bootz ${kernel_addr_r} ${ramdisk_addr_r}:${filesize} ${fdt_addr_r}

sleep 10
