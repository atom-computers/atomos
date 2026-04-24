#!/bin/sh -e
# Description: check various bad patterns with grep
# https://postmarketos.org/pmb-ci

exit_code=0

if [ "$(id -u)" = 0 ]; then
	set -x
	apk -q add git grep
	exec su "${TESTUSER:-build}" -c "sh -e $0"
fi

# Find CHANGEMEs in APKBUILDs
if grep -qr '(CHANGEME!)' -- *; then
	echo "ERROR: Please replace '(CHANGEME!)' in the following files:"
	grep --color=always -r '(CHANGEME!)' -- *
	exit_code=1
fi

# DTBs installed to /usr/share/db
# shellcheck disable=SC2016
if grep -qr 'INSTALL_DTBS_PATH="$pkgdir"/usr/share/dtb' device/; then
	echo 'ERROR: Please do not install dtbs to /usr/share/dtb!'
	echo 'ERROR: Unless you have a good reason not to, please put them in /boot/dtbs'
	echo 'ERROR: Files that need fixing:'
	# shellcheck disable=SC2016
	grep --color=always -r 'INSTALL_DTBS_PATH="$pkgdir"/usr/share/dtb' device/
	exit_code=1
fi


# Find old mkinitfs paths (pre mkinitfs 2.0)
if grep -qr '/etc/postmarketos-mkinitfs' -- *; then
	echo "ERROR: Please replace '/etc/postmarketos-mkinitfs' with '/usr/share/mkinitfs' in the following files:"
	grep --color=always -r '/etc/postmarketos-mkinitfs' -- *
	exit_code=1
fi
if grep -qr '/usr/share/postmarketos-mkinitfs' -- *; then
	echo "ERROR: Please replace '/usr/share/postmarketos-mkinitfs' with '/usr/share/mkinitfs' in the following files:"
	grep --color=always -r '/usr/share/postmarketos-mkinitfs' -- *
	exit_code=1
fi

# Direct sourcing of deviceinfo
if grep --exclude='source_deviceinfo' -qEr 'source /etc/deviceinfo|\. /etc/deviceinfo' -- *; then
	echo 'ERROR: Please source the source_deviceinfo script instead of sourcing deviceinfo directly!'
	grep --color=always --exclude='rootfs-usr-share-misc-source_deviceinfo' -Er 'source /etc/deviceinfo|\. /etc/deviceinfo' -- *
	exit_code=1
fi

# Removed deviceinfo variable
if grep -qr 'deviceinfo_modules_initfs' -- *; then
	echo 'ERROR: deviceinfo_modules_initfs variable has been removed. Use "modules-initfs" file instead.'
	grep --color=always -r 'deviceinfo_modules_initfs' -- *
	exit_code=1
fi

POSTMARKETOS_WALLPAPER_PATH='/usr/share/wallpapers/postmarketos.jpg'
# The excluded devices are "grandfathered in". New devices should not be added here.
# See https://gitlab.postmarketos.org/postmarketOS/pmaports/-/issues/2529
if grep -qr $POSTMARKETOS_WALLPAPER_PATH \
	--exclude-dir='device-pine64-pinetab' \
	--exclude-dir='device-oneplus-kebab' \
	--exclude-dir='device-xiaomi-willow' \
	-- device; then
	echo "ERROR: Please don't include configuration files that set the default wallpaper in device-specific packages!"
	grep --color=always -r $POSTMARKETOS_WALLPAPER_PATH \
		--exclude-dir='device-pine64-pinetab' \
		--exclude-dir='device-oneplus-kebab' \
		--exclude-dir='device-xiaomi-willow' \
		-- device
	exit_code=1
fi

OPENRC_SERVICE_FILES=$(find . -name '*.initd')
# shellcheck disable=SC2086
if grep -q 'before wpa_supplicant' $OPENRC_SERVICE_FILES; then
	echo "ERROR: Please use 'before wlan' in OpenRC service files! This ensures compatibility with both wpa_supplicant and iwd."
	grep --color=always 'before wpa_supplicant' $OPENRC_SERVICE_FILES
	exit_code=1
fi

if grep -qEr 'PMOS_NO_OUTPUT_REDIRECT' -- *; then
	echo "ERROR: PMOS_NO_OUTPUT_REDIRECT is deprecated and doesn't do anything."
	echo "Please remove it from the following files:"
	grep --color=always -Er 'PMOS_NO_OUTPUT_REDIRECT' -- *
	exit_code=1
fi

if grep -qEr '^deviceinfo_kernel_cmdline.*[\"\s]console=null' -- device/; then
	echo "ERROR: Do not use console=null in the kernel command line."
	echo "Use these params to quiet console on boot: quiet loglevel=2"
	echo "For more information, see: https://gitlab.postmarketos.org/postmarketOS/pmaports/-/issues/2989"
	exit_code=1
fi

# Disallow installation of files to /etc/modules-load.d and /etc/modprobe.d
if grep -qr '/etc/modules-load.d' --exclude-dir='device-samsung-golden-downstream' -- *; then
	echo "ERROR: Please replace '/etc/modules-load.d' with '/usr/lib/modules-load.d' in the following files:"
	grep --color=always -r '/etc/modules-load.d' --exclude-dir='device-samsung-golden-downstream' -- *
	exit_code=1
fi
# n900 is excluded because the string is in a comment linking to a repo.
# No other non-archived devices should be excluded.
if grep -qr '/etc/modprobe.d' --exclude-dir='archived' \
		--exclude-dir='device-nokia-n900' -- *; then
			echo "ERROR: Please replace '/etc/modprobe.d' with '/usr/lib/modprobe.d' in the following files:"
			grep --color=always -r '/etc/modprobe.d' --exclude-dir='device-nokia-n900' \
				--exclude-dir='archived' -- *
	exit_code=1
fi

# Disallow maintainer comments.
if grep -qr '# Maintainer:' -- *; then
	echo 'ERROR: Please use maintainer variables of the form maintainer="..." instead of maintainer comments of the form # Maintainer: ...'
	grep --color=always -r '# Maintainer:' -- *
	exit_code=1
fi

if [ -n "$CI_MERGE_REQUEST_DIFF_BASE_SHA" ]; then
	# Find all moved or new kernel APKBUILDs in main, community or testing
	MOVED_OR_NEW_MAINLINE_KERNEL_PACKAGES=$(git show --pretty="" --name-only --diff-filter=AR "$CI_MERGE_REQUEST_DIFF_BASE_SHA"..HEAD | grep "device/\(main\|community\|testing\)/linux-.*/APKBUILD" || true)

	if [ -n "$MOVED_OR_NEW_MAINLINE_KERNEL_PACKAGES" ]; then
		if [ -n "$(grep -L LLVM=1 $MOVED_OR_NEW_MAINLINE_KERNEL_PACKAGES || true)" ]; then
			echo "ERROR: An added or moved close-to-mainline kernel package is not being built with LLVM."
			echo "See https://postmarketos.org/edge/2025/11/11/kernels-llvm/ for more details"
			grep --color=always -L LLVM=1 $MOVED_OR_NEW_MAINLINE_KERNEL_PACKAGES
			exit_code=1
		fi
	fi

	# Disallow adding packages without a maintainer set
	NEW_APKBUILDS=$(git show --pretty="" --name-only --diff-filter=A "$CI_MERGE_REQUEST_DIFF_BASE_SHA"..HEAD | grep APKBUILD || true)

	if [ -n "$NEW_APKBUILDS" ]; then
		if [ -n "$(grep -L '^maintainer="[^"]\+"$' $NEW_APKBUILDS || true)" ]; then
			echo "ERROR: A new package does not have a maintainer set."
			grep --color=always -L '^maintainer="[^"]\+"$' $NEW_APKBUILDS
			exit_code=1
		fi
	fi
fi

exit "$exit_code"
