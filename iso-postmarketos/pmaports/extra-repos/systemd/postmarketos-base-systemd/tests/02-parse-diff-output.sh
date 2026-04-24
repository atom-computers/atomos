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
# Basic diff parsing
start_test "Basic diff parsing - added and removed files"
create_test_root
TEST_ROOT="$(pwd)"
export SYSTEMD_APK_ROOT="$TEST_ROOT"

# shellcheck disable=SC1091
. "$srcdir/rootfs-usr-libexec-systemd-apk-trigger"

# Create mock diff output
diff_output="--- old
+++ new
@@ -1,3 +1,4 @@
-/usr/lib/systemd/system/removed.service type=file mtime=123
+/usr/lib/systemd/system/added.service type=file mtime=456
+/usr/lib/systemd/system/another-added.service type=file mtime=789
 /usr/lib/systemd/system/unchanged.service type=file mtime=999"

added_result=""
removed_result=""
parse_diff_output "$diff_output" "added_result" "removed_result"

assert_contains "$added_result" "/usr/lib/systemd/system/added.service"
assert_contains "$added_result" "/usr/lib/systemd/system/another-added.service"
assert_contains "$removed_result" "/usr/lib/systemd/system/removed.service"

cleanup_test_root
end_test

### Test 2 ###
# Directory filtering
start_test "Directory filtering - directories excluded from results"
create_test_root
TEST_ROOT="$(pwd)"
export SYSTEMD_APK_ROOT="$TEST_ROOT"

# shellcheck disable=SC1091
. "$srcdir/rootfs-usr-libexec-systemd-apk-trigger"

# Create mock diff with directories
dir_diff="--- old
+++ new
@@ -1,2 +1,3 @@
-/usr/lib/systemd/system/some.service type=file mtime=123
+/usr/lib/systemd/system/target.wants type=dir mtime=456
+/usr/lib/systemd/system/new.service type=file mtime=789"

dir_added=""
dir_removed=""
parse_diff_output "$dir_diff" "dir_added" "dir_removed"

# Directory should not be included
assert_not_contains "$dir_added" "/usr/lib/systemd/system/target.wants"

# File should be included
assert_contains "$dir_added" "/usr/lib/systemd/system/new.service"
assert_contains "$dir_removed" "/usr/lib/systemd/system/some.service"

cleanup_test_root
end_test

end_testsuite
