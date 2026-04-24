#!/bin/sh
# The verbose feature is actually implemented in postmarketos-mkinitfs itself
# since it needs to be enabled before hooks are run. /init checks if this file
# exists and runs "set -x" if so.
echo "verbose-initfs is enabled. All initramfs shell commands are printed to the console."
