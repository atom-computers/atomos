textout 0 -1 \"Preparing to boot from SD card...\" FFF000
setenv memtotal 447M
setenv mbsize 56M
setenv mmcid 0
setenv bootargs mem=${memtotal} root=/dev/mmcblk0p2 rootwait console=tty1 init=/sbin/init rootfstype=ext4
fatload mmc 0 0 uImage-tokio-techbook
textout -1 -1 \"BOOTING!!\" 00FF00
bootm 0
