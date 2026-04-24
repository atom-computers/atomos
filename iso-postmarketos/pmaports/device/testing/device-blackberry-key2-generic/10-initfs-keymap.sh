#!/bin/sh

echo "Loading stmpe_keypad module..."
modprobe -a stmpe_keypad

echo "Loading keymap..."
gunzip -c /usr/share/bkeymaps/us/us-key2.bmap.gz | loadkmap
