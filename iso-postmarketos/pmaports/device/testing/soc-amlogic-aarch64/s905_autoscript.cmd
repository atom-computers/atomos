if fatload mmc 0 0x1000000 u-boot.bin; then go 0x1000000; fi;
if fatload usb 0 0x1000000 u-boot.bin; then go 0x1000000; fi;
if ext4load mmc 0 0x1000000 u-boot.bin; then go 0x1000000; fi;
if ext4load usb 0 0x1000000 u-boot.bin; then go 0x1000000; fi;
setenv pmos_env_addr 0x1040000
setenv pmos_env_load 'fatload ${pmos_devtype} ${pmos_devnum} ${pmos_env_addr} uEnv.ini && env import -t ${pmos_env_addr} ${filesize}'
setenv pmos_try_uimage 'if fatload ${pmos_devtype} ${pmos_devnum} ${loadaddr} uImage; then fatload ${pmos_devtype} ${pmos_devnum} ${dtb_mem_addr} ${pmos_env_dtb} && bootm ${loadaddr} - ${dtb_mem_addr}; fi'
setenv pmos_try_fit 'if fatload ${pmos_devtype} ${pmos_devnum} ${loadaddr} boot-image.itb; then bootm ${loadaddr}; fi'
setenv pmos_try_boot 'run pmos_try_fit; run pmos_try_uimage'
setenv pmos_devtype usb
for pmos_devnum in 0 1 2 3 ; do run pmos_env_load && run pmos_try_boot ; done
setenv pmos_devtype mmc
for pmos_devnum in 0 1 2 3 ; do run pmos_env_load && run pmos_try_boot ; done
