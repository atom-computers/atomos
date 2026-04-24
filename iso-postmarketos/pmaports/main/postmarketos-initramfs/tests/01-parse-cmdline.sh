#!/bin/sh

srcdir="$(dirname "$(realpath $0)")/.."
testlib_path="$1"
shift
# Used by testlib.sh
# shellcheck disable=SC2034
results_dir="$1"
shift

# All arguments have to be consumed before sourcing testlib!
# shellcheck disable=SC1090
. "$testlib_path"

### Test 1 ###

start_test "Ensure all boolean variables can be set"
. "$srcdir/init_functions.sh"

# busybox ash supports process substitution
# shellcheck disable=SC3001
parse_cmdline < <(echo \
pmos.bootchart2 pmos.debug-shell pmos.force-partition-resize \
pmos.nosplash pmos.stowaway rd.info \
)

assert_equal "bootchart2" "y"
assert_equal "debug_shell" "y"
assert_equal "force_partition_resize" "y"
assert_equal "nosplash" "y"
assert_equal "log_info" "y"
end_test

### Test 2 ###

start_test "Ensure non-boolean variables can be set"
. $srcdir/init_functions.sh

# busybox ash supports process substitution
# shellcheck disable=SC3001
parse_cmdline < <(echo \
pmos.boot_uuid=xyz-789 pmos.root_uuid=abc-123 \
pmos.usb-storage=/dev/sdc \
pmos.boot=/dev/mapper/userdata1 \
pmos.root=/dev/disk/by-partlabel/userdata \
pmos.rootfsopts=default
)

assert_equal "boot_uuid" "xyz-789"
assert_equal "root_uuid" "abc-123"
assert_equal "usb_storage" "/dev/sdc"
assert_equal "boot_path" "/dev/mapper/userdata1"
assert_equal "root_path" "/dev/disk/by-partlabel/userdata"
assert_equal "rootfsopts" ",default"

test_info "Checking other variables are unset"
assert_unset debug_shell
assert_unset nosplash
assert_unset bootchart2
end_test

### Test 3 ###

start_test "Test info loglevel"
. $srcdir/init_functions.sh

assert_unset log_info
assert_unset "(info hello world)"
logeval parse_cmdline_item "rd.info"
assert_equal "(info hello world)" "hello world"
end_test

end_testsuite
