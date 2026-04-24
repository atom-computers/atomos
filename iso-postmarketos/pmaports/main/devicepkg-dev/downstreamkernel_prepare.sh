#!/bin/sh

# Replace compiler-gcc.h with one that works with newer GCC versions.
# Set REPLACE_GCCH=0 to avoid replacing an existing compiler-gcc.h file.
install_gcc_h() {
	# shellcheck disable=SC2154
	_gcch="$builddir/include/linux/compiler-gcc.h"
	if [ -f "$_gcch" ]; then
		if [ "$REPLACE_GCCH" = "0" ]; then
			echo "NOTE: *not* replacing $_gcch, because of REPLACE_GCCH=0"
			return
		else
			echo "NOTE: replacing $_gcch! If your build breaks with 'Please"
			echo "don't include <linux/compiler-gcc.h> directly' or a similar"
			echo "compiler-gcc.h related error, then set"
			echo "  REPLACE_GCCH=0"
			echo "in your kernel APKBUILD at the start of the"
			echo "downstreamkernel_prepare.sh line."
		fi
	fi

	cp -v "/usr/share/devicepkg-dev/compiler-gcc.h" "$_gcch"
}

if [ "$#" -ne 0 ]; then
	echo "ERROR: downstreamkernel_prepare should be sourced in APKBUILDs."
	echo "Related: https://postmarketos.org/downstreamkernel-prepare"
	exit 1
fi

# Set _outdir to "." if not set
if [ -z "$_outdir" ]; then
	_outdir="."
fi

# Set _hostcc when HOSTCC is set
[ -z "$HOSTCC" ] || _hostcc="HOSTCC=$HOSTCC"

[ -z "$LLVM" ] || _llvm="LLVM=$LLVM"

# Support newer GCC versions
install_gcc_h

# Remove -Werror from all makefiles
makefiles="$(find "$builddir" -type f -name Makefile)
	$(find "$builddir" -type f -name Makefile.common)
	$(find "$builddir" -type f -name Kbuild)"
for i in $makefiles; do
	sed -i 's/-Werror-/-W/g' "$i"
	sed -i 's/-Werror=/-W/g' "$i"
	sed -i 's/-Werror//g' "$i"
done

# Prepare kernel config ('yes ""' for kernels lacking olddefconfig)
mkdir -p "$builddir/$_outdir"
# shellcheck disable=SC2154
cp "$srcdir/$_config" "$builddir"/"$_outdir"/.config
# shellcheck disable=SC2086,SC2154
yes "" | make -C "$builddir" ARCH="$_carch" O="$_outdir" \
	$_hostcc $_llvm oldconfig
