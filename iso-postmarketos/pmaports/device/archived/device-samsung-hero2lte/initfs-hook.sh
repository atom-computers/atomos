# Set 16bpp fb mode and ensure size is set
echo 16 > /sys/class/graphics/fb0/bits_per_pixel
echo 1440,2560 > /sys/class/graphics/fb0/virtual_size

# Blank and unblank
echo 1 > /sys/class/graphics/fb0/blank
echo 0 > /sys/class/graphics/fb0/blank

