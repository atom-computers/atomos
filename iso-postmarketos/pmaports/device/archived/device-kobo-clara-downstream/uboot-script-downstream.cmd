setenv bootargs console=ttymxc0,115200

# This must be called first, otherwise bootz does not work correctly.
# The actual kernel is loaded over this below.
load_ntxkernel

echo Loading kernel
load mmc 0:1 0x80800000 vmlinuz

echo Loading DTB
load mmc 0:1 0x83000000 imx6sll-e60k02.dtb

echo Loading initrd
load mmc 0:1 0x85000000 uInitrd

echo Booting kernel
bootz 0x80800000 0x85000000 0x83000000
