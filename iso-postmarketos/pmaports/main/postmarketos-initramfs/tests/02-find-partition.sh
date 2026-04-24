#!/bin/sh

srcdir="$(dirname "$(realpath "$0")")/.."
testlib_path="$1"
shift
# Used by testlib.sh
# shellcheck disable=SC2034
results_dir="$1"
shift

# All arguments have to be consumed before sourcing testlib!
# shellcheck disable=SC1090
. "$testlib_path"

# Mock blkid that produces a path for all expected arguments
# except for --label if the label isn't "pmOS_valid"
blkid_mock_find_all() {
	local fail
	test_debug "+ blkid $*"
	case "$1" in
		--uuid)
			case "$2" in
				"abcd-1234")
					echo "/dev/sda2"
					;;
				"deaf-5678")
					echo "/dev/sda1"
					;;
				*)
					fail="Unexpected arguments to blkid: $*"
					assert_unset fail
					;;
			esac
			;;
		--label)
			if [ "$2" = "pmOS_valid" ]; then
				echo "/dev/disk/by-label/pmOS_root"
			fi
			return
			;;
		--match-token)
			assert_strequal "$2" "TYPE=crypto_LUKS"
			echo "/dev/sda17"
			;;
		*)
			fail="Unexpected arguments to blkid: $*"
			assert_unset fail
			;;
	esac
}

### Test 1 ###

start_test "Test find_partition happy paths"
. "$srcdir/init_functions.sh"

# For this we need to mock a few things
pretty_dm_path() {
	echo "$1"
}

blkid() {
	# Splitting is intentional
	# shellcheck disable=SC2068
	blkid_mock_find_all $@
}

# Test all the happy paths, for all of these we assume that blkid would succeed
test_info "A) Valid UUID (ideal case)"
logeval 'found="$(find_partition abcd-1234 /dev/null pmOS_root "TYPE=crypto_LUKS")"'
assert_equal found /dev/sda2

test_info
test_info "B) No UUID but valid path from pmos.root="
logeval 'found="$(find_partition "" /dev/null pmOS_root "TYPE=crypto_LUKS")"'
assert_equal found /dev/null

test_info
test_info "C) No UUID or path, rely on the label"
logeval 'found="$(find_partition "" "" pmOS_valid "TYPE=crypto_LUKS")"'
assert_equal found /dev/disk/by-label/pmOS_root

test_info
test_info "D) No UUID, path, and missing label (FDE case)"
logeval 'found="$(find_partition "" "" pmOS_invalid "TYPE=crypto_LUKS")"'
assert_equal found /dev/sda17

end_test

### Test 2 ###

start_test "Test find_partition sad paths"
. $srcdir/init_functions.sh


# For this we need to mock a few things
pretty_dm_path() {
	echo "$1"
}

test_info "A) Partition with given UUID doesn't exist, no other lookup is done"
# Returns nothing when called with --uuid, fails for any other
# arguments. This simulates a partition with the given UUID
# not existing AND that we never call with blkid to look up
# by label or match token.
blkid() {
	test_debug "blkid $*"
	case "$1" in
		--uuid)
			assert_strequal "$2" "abcd-1234"
			return
			;;
		*)
			fail="Unexpected arguments to blkid: $*"
			assert_unset fail
			;;
	esac
}

logeval 'found="$(find_partition abcd-1234 /dev/null pmOS_root "TYPE=crypto_LUKS")"'
assert_unset found

test_info "B) No UUID, partition with given path doesn't exist, no other lookup is done"
logeval 'found="$(find_partition "" /dev/notablockdev pmOS_root "TYPE=crypto_LUKS")"'
assert_unset found

test_info "C) No UUID, no path, label and match token not found"
# Returns nothing, errors if not called with --uuid,
# --label, or --match-token
blkid() {
	test_debug "blkid $*"
	case "$1" in
		--uuid)
			assert_strequal "$2" "abcd-1234"
			return
			;;
		--label)
			assert_strequal "$2" "pmOS_root"
			return
			;;
		--match-token)
			assert_strequal "$2" "TYPE=crypto_LUKS"
			return
			;;
		*)
			fail="Unexpected arguments to blkid: $*"
			assert_unset fail
			;;
	esac
}
logeval 'found="$(find_partition "" "" pmOS_root "TYPE=crypto_LUKS")"'
assert_unset found

end_test

### Test 3 ###

start_test "Test find_root_partition and find_boot_partition"
. $srcdir/init_functions.sh

# Mocks
pretty_dm_path() {
	echo "$1"
}

blkid() {
	# Splitting is intentional
	# shellcheck disable=SC2068
	blkid_mock_find_all $@
}

test_info "A) Valid UUID, result is cached"
logeval 'root_uuid=abcd-1234'
logeval 'boot_uuid=deaf-5678'

logeval 'find_root_partition found'
assert_equal found /dev/sda2
logeval 'find_boot_partition found'
assert_equal found /dev/sda1

blkid() {
	local fail
	# fail is used indirectly
	# shellcheck disable=SC2034
	fail="blkid called when expecting cached result"
	assert_unset fail
}

logeval 'find_root_partition found'
assert_equal found /dev/sda2
logeval 'find_boot_partition found'
assert_equal found /dev/sda1

end_test

end_testsuite
