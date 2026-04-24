echo Entering user script:

echo Loading DTB overlay
load mmc ${mmc_bootdev}:1 ${fdtoverlay_addr_r} pinephone-vccq-mod.dtbo

echo Applying DTB overlay
fdt apply ${fdtoverlay_addr_r}

echo Exiting user script:
