#!/bin/sh

log() {
	logger -p daemon.info -t firmware "$@"
}

load_error() {
	log "Failed to load $FIRMWARE for $DEVPATH"
	echo "-1" > "/sys$DEVPATH/loading"
}

load_blockdev() {
	local blockdev length offset dd_args
	blockdev=$1
	length=$2
	offset=$3
	dd_args="status=none bs=512"

	if [ -n "$length" ]; then
		dd_args="$dd_args count=$((length / 512))"
	fi

	if [ -n "$offset" ]; then
		dd_args="$dd_args skip=$((offset / 512))"
	fi

	log "Loading firmware from $blockdev"

	if [ ! -e "$blockdev" ]; then
		load_error
	else
		echo 1 > "/sys$DEVPATH/loading"
		dd if="$blockdev" of="/sys$DEVPATH/data" $dd_args
		echo 0 > "/sys$DEVPATH/loading"

		log "Loading firmware complete"
	fi
}

load_partition() {
	local blockdev
	blockdev=/dev/disk/by-partlabel/$1
	shift
	load_blockdev $blockdev "$@"
}

load_zeros() {
	load_blockdev /dev/zero $1
}

log "Attempting to load firmware $FIRMWARE for $DEVPATH"

if [ -e "/sys$DEVPATH/loading" ]; then
	case "$FIRMWARE" in
		sprd/l_modem.bin)
			load_partition l_modem_a 0x1380000
			;;
		sprd/l_deltanv.bin)
			load_partition l_deltanv_a 0x20000
			;;
		sprd/l_fixnv.bin)
			load_partition l_fixnv2_a 0x100000 0x200
			;;
		sprd/l_runtimenv.bin)
			# Do not actually load the NV. The modem generates a valid
			# NV if one does not exist. This script is only used to load
			# the NV if /lib/firmware/sprd/l_runtimenv.bin is missing,
			# which can be created by the NV item daemon after the modem
			# generates the NV.
			load_zeros 0x120000
			;;
		sprd/l_gdsp.bin)
			load_partition l_gdsp_a 0x440000
			;;
		sprd/l_ldsp.bin)
			load_partition l_ldsp_a 0xb00000
			;;
		sprd/pm_sys.bin)
			load_partition pm_sys_a
			;;
		*)
			load_error
			;;
	esac
fi
