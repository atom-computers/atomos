#!/bin/sh

echo "==> Amending boot.img for Amazon signature verification exploit"
SOHO_HEADER_DATA='\x50\x03\x00\x00\x00\x25\xe4\x00'
SOHO_HEADER_SIZE=848
SOHO_HEADER_OFFSET=52
tempfile=$(mktemp)
bootimgfile=$(echo "${1}" | sed 's/initramfs/boot.img/g')
dd if=/dev/zero of="${tempfile}" bs=$SOHO_HEADER_SIZE count=1
printf "%b" $SOHO_HEADER_DATA | dd of="${tempfile}" bs=$SOHO_HEADER_OFFSET seek=1 conv=notrunc
cat "${bootimgfile}" >> "${tempfile}"
mv "${tempfile}" "${bootimgfile}"
