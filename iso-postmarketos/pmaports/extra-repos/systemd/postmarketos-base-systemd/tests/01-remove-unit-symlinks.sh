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
# Direct absolute symlinks
start_test "Removing direct absolute symlinks"
create_test_root
TEST_ROOT="$(pwd)"
export SYSTEMD_APK_ROOT="$TEST_ROOT"

# shellcheck disable=SC1091
. "$srcdir/rootfs-usr-libexec-systemd-apk-trigger"

mkdir -p etc/systemd/system etc/systemd/user usr/lib/systemd/system usr/lib/systemd/user
ln -s "$TEST_ROOT/usr/lib/systemd/system/removed.service" "etc/systemd/system/direct-system.service"
ln -s "$TEST_ROOT/usr/lib/systemd/user/removed-user.service" "etc/systemd/user/direct-user.service"

test_info "Running remove_unit_symlinks for system units..."
remove_unit_symlinks "/usr/lib/systemd/system/removed.service"
test_info "Running remove_unit_symlinks for user units..."
remove_unit_symlinks "/usr/lib/systemd/user/removed-user.service"

assert_not_exists "$TEST_ROOT/etc/systemd/system/direct-system.service"
assert_not_exists "$TEST_ROOT/etc/systemd/user/direct-user.service"

cleanup_test_root
end_test

### Test 2 ###
# Relative symlinks
start_test "Removing relative symlinks"
create_test_root
TEST_ROOT="$(pwd)"
export SYSTEMD_APK_ROOT="$TEST_ROOT"

# shellcheck disable=SC1091
. "$srcdir/rootfs-usr-libexec-systemd-apk-trigger"

mkdir -p etc/systemd/system etc/systemd/user usr/lib/systemd/system usr/lib/systemd/user
ln -s "../../../usr/lib/systemd/system/removed.service" "etc/systemd/system/relative-system.service"
ln -s "../../../usr/lib/systemd/user/removed-user.service" "etc/systemd/user/relative-user.service"

test_info "Running remove_unit_symlinks for system units..."
remove_unit_symlinks "/usr/lib/systemd/system/removed.service"
test_info "Running remove_unit_symlinks for user units..."
remove_unit_symlinks "/usr/lib/systemd/user/removed-user.service"

assert_not_exists "$TEST_ROOT/etc/systemd/system/relative-system.service"
assert_not_exists "$TEST_ROOT/etc/systemd/user/relative-user.service"

cleanup_test_root
end_test

### Test 3 ###
# Chain symlinks (intermediate -> removed unit, final -> intermediate)
start_test "Removing chained symlinks"
create_test_root
TEST_ROOT="$(pwd)"
export SYSTEMD_APK_ROOT="$TEST_ROOT"

# shellcheck disable=SC1091
. "$srcdir/rootfs-usr-libexec-systemd-apk-trigger"

mkdir -p etc/systemd/system etc/systemd/user usr/lib/systemd/system usr/lib/systemd/user
ln -s "$TEST_ROOT/usr/lib/systemd/system/removed.service" "etc/systemd/system/intermediate-system.service"
ln -s "intermediate-system.service" "etc/systemd/system/chain-system.service"

test_info "Running remove_unit_symlinks for system units..."
remove_unit_symlinks "/usr/lib/systemd/system/removed.service"

assert_not_exists "$TEST_ROOT/etc/systemd/system/intermediate-system.service"
assert_not_exists "$TEST_ROOT/etc/systemd/system/chain-system.service"

cleanup_test_root
end_test

### Test 4 ###
# Existing symlinks
start_test "Keeping existing units/symlinks"
create_test_root
TEST_ROOT="$(pwd)"
export SYSTEMD_APK_ROOT="$TEST_ROOT"

# shellcheck disable=SC1091
. "$srcdir/rootfs-usr-libexec-systemd-apk-trigger"

mkdir -p etc/systemd/system etc/systemd/user usr/lib/systemd/system usr/lib/systemd/user
touch "usr/lib/systemd/system/kept.service"
touch "usr/lib/systemd/user/kept-user.service"
ln -s "$TEST_ROOT/usr/lib/systemd/system/kept.service" "etc/systemd/system/control-system.service"
ln -s "$TEST_ROOT/usr/lib/systemd/user/kept-user.service" "etc/systemd/user/control-user.service"
ln -s "$TEST_ROOT/usr/lib/systemd/system/removed.service" "etc/systemd/system/direct-system.service"
ln -s "$TEST_ROOT/usr/lib/systemd/user/removed-user.service" "etc/systemd/user/direct-user.service"

test_info "Running remove_unit_symlinks for system units..."
remove_unit_symlinks "/usr/lib/systemd/system/removed.service"
test_info "Running remove_unit_symlinks for user units..."
remove_unit_symlinks "/usr/lib/systemd/user/removed-user.service"

assert_exists "$TEST_ROOT/etc/systemd/system/control-system.service"
assert_exists "$TEST_ROOT/etc/systemd/user/control-user.service"
assert_exists "$TEST_ROOT/usr/lib/systemd/system/kept.service"
assert_exists "$TEST_ROOT/usr/lib/systemd/user/kept-user.service"

cleanup_test_root
end_test

end_testsuite
