#!/bin/sh
#
# Add or remove paths from musl dynamic linker
# path file (/etc/ld-musl-$ARCH.path)
#
# usage example:
# $ ldpath.sh add /usr/lib/libdrm-grate

default_ld_paths() {
	echo "/lib:/usr/local/lib:/usr/lib"
}

###############################################
# Processor arch in the convention used  by the
# musl dynamic linker.
#   See musl source code: ldso/dynlink.c
# Arguments:
#   kernel machine hardware name (uname -m)
# Returns:
#   musl ldso processor arch
###############################################
kernel_arch_to_ldso_arch() {
	local karch=$1
	local ld_arch=""
	case "$karch" in
		armv7l)
			ld_arch=armhf
			;;
		*)
			ld_arch="$karch"
			;;
	esac
	echo "$ld_arch"
}

default_ld_musl_file() {
	local ld_arch
	ld_arch=$(kernel_arch_to_ldso_arch "$(uname -m)")
	echo "/etc/ld-musl-${ld_arch}.path"
}

###############################################
# Prepend a path to dynamic linker path file
# Arguments:
#   Shared library directory
#   ld musl path file
###############################################
add_path() {
	local ld_library_path=$1
	local ld_musl_file=$2

	# Don't allow duplicates
	if [ -f "$ld_musl_file" ]; then
		if grep -q "$ld_library_path" "$ld_musl_file"; then
			return 0
		fi
	fi

	if [ -f "$ld_musl_file" ]; then
		echo "${ld_library_path}:$(cat "$ld_musl_file")" > \
			"$ld_musl_file"
	else
		echo "${ld_library_path}:$(default_ld_paths)" > "$ld_musl_file"
	fi
}

###############################################
# Remove a path from dynamic linker path file
# Arguments:
#   Shared library directory
#   ld musl path file
###############################################
remove_path() {
	local ld_library_path=$1
	local ld_musl_file=$2
	local conf

	if [ ! -f "$ld_musl_file" ]; then
		return 0
	fi

	# Don't remove default paths
	if default_ld_paths | grep -q "$ld_library_path"; then
		return 0
	fi

	conf=$(awk -v ld_path="$ld_library_path" '{n=split($0, array, ":")} END {
		for (i in array) {
			if (array[i]!=ld_path) {
				printf array[i]
				if (i<n)
					printf ":"
			}
		}
	}' < "$ld_musl_file")
	echo "$conf" > "$ld_musl_file"
}

print_usage() {
	local ld_arch
	ld_arch=$(kernel_arch_to_ldso_arch "$(uname -m)")
	echo "usage: $(basename "$1") [-h] [-f FILE] {add,remove} LD_LIBRARY_PATH"
	echo ""
	echo "Add or remove LD_LIBRARY_PATH in $(default_ld_musl_file)"
	echo ""
	echo "optional arguments:"
	echo "  -h, --help            show this help message and exit"
	echo "  -f, --file            override ld musl path file"
}

parse_args() {
	local have_file_arg=""
	while [ "${1:-}" != "" ]; do
		case $1 in
		add|remove)
			ldpath_func="$1"
			ldpath_arg="$2"
			shift
			shift
			;;
		-f|--file)
			have_file_arg="1"
			ld_musl_file="$2"
			shift
			shift
			;;
		-h|--help)
			shift
			return 0
			;;
		*)
			echo "Invalid argument: $1"
			shift
			return 0
			;;
		esac
	done

	if [ -z "$ldpath_func" ] || [ -z "$ldpath_arg" ]; then
		return 0
	fi

	if [ "$have_file_arg" = "1" ] &&
		[ -z "$ld_musl_file" ]; then
		return 0
	fi

	return 1
}

main() {
	if [ -z "$ld_musl_file" ]; then
		ld_musl_file=$(default_ld_musl_file)
	fi

	if [ "$ldpath_func" = "add" ]; then
		add_path "$ldpath_arg" "$ld_musl_file"
	elif [ "$ldpath_func" = "remove" ]; then
		remove_path "$ldpath_arg" "$ld_musl_file"
	fi
}

if parse_args "$@"; then
	print_usage "$0"
	return 1
fi

main "$0"
