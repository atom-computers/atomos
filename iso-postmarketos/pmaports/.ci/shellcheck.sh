#!/bin/sh -e
# Copyright 2023 Oliver Smith
# SPDX-License-Identifier: GPL-3.0-or-later
# Description: lint all shell scripts
# https://postmarketos.org/pmb-ci

DIR="$(cd "$(dirname "$0")/.." && pwd -P)"

if [ "$(id -u)" = 0 ]; then
	set -x
	apk -q add shellcheck
	exec su "${TESTUSER:-build}" -c "sh -e $0"
fi

# Shell: shellcheck
sh_files="
	./main/mdss-fb-init-hack/mdss-fb-init-hack.sh
	./main/postmarketos-base-ui/rootfs-usr-lib-NetworkManager-dispatcher.d-50-dns-filter.sh
	./main/postmarketos-duranium/rootfs-usr-bin-duranium-set-channel
	./main/postmarketos-duranium/rootfs-usr-libexec-duranium-first-boot
	./main/postmarketos-duranium/rootfs-usr-libexec-duranium-mount-subpartitions
	./main/postmarketos-duranium/rootfs-usr-libexec-duranium-usb-gadget-setup
	./main/postmarketos-installkernel/installkernel-pmos
	./main/postmarketos-initramfs/init.sh
	./main/postmarketos-initramfs/init_functions.sh
	./main/postmarketos-mkinitfs-hook/00-apx.sh
	./main/postmarketos-mkinitfs-hook/00-kernel-panic.sh
	./main/postmarketos-mkinitfs-hook/00-maximum-attention.sh
	./main/postmarketos-mkinitfs-hook/00-netboot.sh
	./main/postmarketos-mkinitfs-hook/05-ci.sh
	./main/postmarketos-mkinitfs-hook/10-verbose-initfs.sh
	./main/postmarketos-ui-os-installer/rootfs-usr-bin-pmos_setup.sh
	./main/postmarketos-usb-moded/rootfs-usr-lib-systemd-system-generators-umtprd-config-generator
	./main/ttyescape/*.post-install
	./main/unl0kr/unlock.sh
	./device/community/soc-qcom/call_audio_idle_suspend_workaround.sh
	./device/testing/device-apple-mac-aarch64/*.sh
	./extra-repos/systemd/postmarketos-base-systemd/rootfs-usr-libexec-systemd-apk-trigger

	$(find . -path './main/postmarketos-ui-*/*.sh')
	$(find . -path './main/postmarketos-ui-*/*.pre-install')
	$(find . -path './main/postmarketos-ui-*/*.post-install')
	$(find . -path './main/postmarketos-ui-*/*.pre-upgrade')
	$(find . -path './main/postmarketos-ui-*/*.post-upgrade')
	$(find . -path './main/postmarketos-ui-*/*.pre-deinstall')
	$(find . -path './main/postmarketos-ui-*/*.post-deinstall')

	$(find . -name '*.trigger')
	$(find . -path './main/devicepkg-dev/*.sh')

	$(find . -path './.ci/**.sh')
	$(find . -path '**/tests/*.sh')
"

for file in $sh_files; do
	echo "Test with shellcheck: $file"
	cd "$DIR/$(dirname "$file")"
	shellcheck -S warning -e SC1008 -e SC3043 -x "$(basename "$file")"
done
