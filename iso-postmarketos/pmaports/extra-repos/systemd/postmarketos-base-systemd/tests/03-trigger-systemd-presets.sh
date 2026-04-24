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
# New installable units should be preset
start_test "New installable units should be preset"
create_test_root
TEST_ROOT="$(pwd)"
export SYSTEMD_APK_ROOT="$TEST_ROOT"

# shellcheck disable=SC1091
. "$srcdir/rootfs-usr-libexec-systemd-apk-trigger"

mkdir -p usr/lib/systemd/system usr/lib/systemd/user

# Create unit with [Install] section
cat > "usr/lib/systemd/system/installable.service" <<-EOF
[Unit]
Description=Test service

[Service]
Type=simple

[Install]
WantedBy=multi-user.target
EOF

# Create user unit with [Install]
cat > "usr/lib/systemd/user/user-installable.service" <<-EOF
[Unit]
Description=User test service

[Service]
Type=simple

[Install]
WantedBy=default.target
EOF

# Create unit without [Install] section
cat > "usr/lib/systemd/system/not-installable.service" <<-EOF
[Unit]
Description=Test service

[Service]
Type=simple
EOF

test_output=$(trigger_systemd_presets "$TEST_ROOT/usr/lib/systemd/system/installable.service $TEST_ROOT/usr/lib/systemd/user/user-installable.service $TEST_ROOT/usr/lib/systemd/system/not-installable.service" "" 2>&1)

assert_contains "$test_output" "systemctl --no-reload preset installable.service"
assert_contains "$test_output" "systemctl --no-reload preset --global user-installable.service"
assert_not_contains "$test_output" "not-installable.service"

cleanup_test_root
end_test

### Test 2 ###
# Modified files should be skipped
start_test "Modified files (added and removed) should be skipped"
create_test_root
TEST_ROOT="$(pwd)"
export SYSTEMD_APK_ROOT="$TEST_ROOT"

# shellcheck disable=SC1091
. "$srcdir/rootfs-usr-libexec-systemd-apk-trigger"

mkdir -p usr/lib/systemd/system

# Create unit with [Install] section
cat > "usr/lib/systemd/system/installable.service" <<-EOF
[Unit]
Description=Test service

[Service]
Type=simple

[Install]
WantedBy=multi-user.target
EOF

# Test with file in both added and removed (modified)
modified_output=$(trigger_systemd_presets "$TEST_ROOT/usr/lib/systemd/system/installable.service" "$TEST_ROOT/usr/lib/systemd/system/installable.service" 2>&1)

assert_not_contains "$modified_output" "installable.service"

cleanup_test_root
end_test

end_testsuite
