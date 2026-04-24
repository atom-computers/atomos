setenv bootargs console=ttyS0,115200n8 root=/dev/mmcblk0p2 rootwait verbose cma=48M video=HDMI-A-1:1920x1080-32@60
ext4load mmc 0 0x1000000 /uImage
ext4load mmc 0 0x2000000 /uInitrd
bootm 0x1000000 0x2000000
