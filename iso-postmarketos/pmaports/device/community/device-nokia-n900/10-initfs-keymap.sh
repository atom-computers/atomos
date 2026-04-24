#!/bin/sh

echo "Loading keymap..."
gunzip -c /usr/share/bkeymaps/us/rx51_us.bmap.gz | loadkmap
