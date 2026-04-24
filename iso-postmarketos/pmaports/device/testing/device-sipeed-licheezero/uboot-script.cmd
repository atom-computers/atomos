setenv bootargs init=/init.sh rw console=tty0 console=ttyS0,115200 panic=10 consoleblank=0 loglevel=1 PMOS_FORCE_PARTITION_RESIZE

printenv

echo Loading DTB ${fdtfile}
load mmc 0:1 ${fdt_addr_r} dtbs-stable/${fdtfile}

echo Loading Initramfs
load mmc 0:1 ${ramdisk_addr_r} initramfs
setenv ramdisk_size ${filesize}

echo Loading Kernel
load mmc 0:1 ${kernel_addr_r} vmlinuz-stable


echo Resizing FDT
fdt addr ${fdt_addr_r}
fdt resize

echo Loading user config
setexpr fdtoverlay_addr_r ${fdt_addr_r} + F0000
if load mmc 0:1 ${fdtoverlay_addr_r} overlay.txt && env import -t ${fdtoverlay_addr_r} ${filesize} && test -n ${overlay}; then
	echo Loaded overlay.txt: ${overlay}
	for ov in ${overlay}; do
		echo Load ${ov}.dtbo
		load mmc 0:1 ${fdtoverlay_addr_r} overlay/${ov}.dtbo && fdt apply ${fdtoverlay_addr_r}
	done
	echo Loaded all overlays
fi

echo Booting kernel
bootz ${kernel_addr_r} ${ramdisk_addr_r}:${ramdisk_size} ${fdt_addr_r}
