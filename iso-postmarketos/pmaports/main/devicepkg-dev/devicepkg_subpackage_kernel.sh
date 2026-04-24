#!/bin/sh
startdir=$1
pkgname=$2
subpkgname=$3

if [ -z "$startdir" ] || [ -z "$pkgname" ] || [ -z "$subpkgname" ]; then
	echo "ERROR: missing argument!"
	echo "Please call $0 with \$startdir \$pkgname \$subpkgname as arguments."
	exit 1
fi

srcdir="$startdir/src"
pkgdir="$startdir/pkg/$pkgname"
subpkgdir="$startdir/pkg/$subpkgname"

rm -fv "$pkgdir/usr/share/deviceinfo/$pkgname"
rm -fv "$pkgdir/usr/share/deviceinfo/deviceinfo"
rmdir -v "$pkgdir/usr/share/deviceinfo"

deviceinfo="$subpkgdir/usr/share/deviceinfo/$subpkgname"
install -Dm644 "$srcdir/deviceinfo" \
	"$deviceinfo"
ln -s "$subpkgname" "$subpkgdir/usr/share/deviceinfo/deviceinfo"

# Get the kernel type ("downstream", "mainline")
kernel=$(echo "$subpkgname" | sed -n "s/.*-kernel-\(.*\)/\1/p" | tr - _)

# All the installation paths for the modules conflict with those from
# devicepkg_package. It is not supported to have both a modules and
# a modules.$kernel file, it should instead be more than one modules.$kernel
# files, with different $kernel values. The conflict between the package and
# the subpackage aims to prevent the unsupported situation to slip through.
# For modules in initramfs-extra, specified in modules-extra-initfs.$kernel,
# they are handled by udev, so do not need to be specified in
# initramfs.load.
if [ -f "$srcdir/modules-initfs.$kernel" ]; then
	install -Dm644 "$srcdir/modules-initfs.$kernel" \
		"$subpkgdir/usr/share/mkinitfs/modules/00-$pkgname.modules"
	mkdir -p "$subpkgdir/usr/share/mkinitfs/files"
	echo "/usr/share/mkinitfs/modules/00-$pkgname.modules:/usr/lib/modules/initramfs.load" \
	     > "$subpkgdir/usr/share/mkinitfs/files/00-$pkgname-modules.files"
fi

if [ -f "$srcdir/kernel-cmdline.$kernel.conf" ]; then
	install -Dm644 "$srcdir/kernel-cmdline.$kernel.conf" \
		"$subpkgdir/usr/lib/kernel-cmdline.d/50-$pkgname.conf"
fi

# Iterate over deviceinfo variables that have the kernel type as suffix
# var looks like: deviceinfo_kernel_cmdline, ...
grep -E "(.+)_$kernel=.*" "$deviceinfo" | \
	sed "s/\(.\+\)_$kernel=.*/\1/g" | while IFS= read -r var
do
	if grep -Eq "$var=.*" "$deviceinfo"; then
		echo "ERROR: variable '$var' should contain a kernel subpackage suffix"
		exit 1
	fi

	# Remove the kernel suffix from the variable
	sed -i "s/$var\_$kernel/$var/g" "$deviceinfo"

	# Remove the variables with other kernel suffixes
	sed -i "/$var\_.*=.*/d" "$deviceinfo"
done
