#!/bin/sh

# Parse arguments
builddir=$1
pkgdir=$2
_carch=$3
_flavor=$4
_outdir=$5

if [ -z "$builddir" ] || [ -z "$pkgdir" ] || [ -z "$_carch" ] ||
	[ -z "$_flavor" ]; then
	echo "ERROR: missing argument!"
	echo "Please call downstreamkernel_package() with \$builddir, \$pkgdir,"
	echo "\$_carch, \$_flavor (and optionally \$_outdir) as arguments."
	exit 1
fi

# kernel.release
install -D "$builddir/$_outdir/include/config/kernel.release" \
	"$pkgdir/usr/share/kernel/$_flavor/kernel.release"

# zImage (find the right one)
# shellcheck disable=SC2164
cd "$builddir/$_outdir/arch/$_carch/boot"
_target="$pkgdir/boot/vmlinuz"

if [ -n "$KERNEL_IMAGE_NAME" ]; then
	if ! [ -e "$KERNEL_IMAGE_NAME" ]; then
		echo "Could not find \$KERNEL_IMAGE_NAME in $PWD!"
		exit 1
	else
		echo "NOTE: using $KERNEL_IMAGE_NAME as kernel image."
		install -Dm644 "$KERNEL_IMAGE_NAME" "$_target"
	fi
else
	for _zimg in zImage-dtb Image.gz-dtb *zImage Image; do
		[ -e "$_zimg" ] || continue
		echo "zImage found: $_zimg"
		install -Dm644 "$_zimg" "$_target"
		break
	done
	if ! [ -e "$_target" ]; then
		echo "Could not find zImage in $PWD!"
		exit 1
	fi
fi
