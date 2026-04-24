if test ${mmc_bootdev} -eq 0 ; then
	echo "Booting from SD";
	setenv bootdev 0;
else
	echo "Booting from eMMC";
	setenv bootdev 2;
fi;

# This is close to the max env size, https://unix.stackexchange.com/questions/530762/max-line-length-for-u-boot-setenv
setenv bootargs init=/init.sh rw console=tty0 console=ttyS0,115200 earlycon=uart,mmio32,0x01c28000 panic=10 consoleblank=0 loglevel=1 fbcon=rotate:1 PMOS_FORCE_PARTITION_RESIZE pmos_boot=/dev/mmcblk${bootdev}p1 pmos_root=/dev/mmcblk${bootdev}p2

printenv

echo Loading DTB
load mmc ${mmc_bootdev}:1 ${fdt_addr_r} ${pinetabfdt}

echo Loading Initramfs
load mmc ${mmc_bootdev}:1 ${ramdisk_addr_r} uInitrd

echo Loading Kernel
load mmc ${mmc_bootdev}:1 ${kernel_addr_r} vmlinuz

echo Resizing FDT
fdt addr ${fdt_addr_r}
fdt resize

echo Booting kernel
booti ${kernel_addr_r} ${ramdisk_addr_r} ${fdt_addr_r}
