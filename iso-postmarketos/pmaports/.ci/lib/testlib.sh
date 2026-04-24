#!/bin/sh
# Unit testing framework for shell scripts
# Invoke with the path to a tests/ subdir of a package and the
# package name as arguments. Or source it with the following
# variables set:
# * results_dir - second argument to the test script

set -e

# Colors :D
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
BOLDBLUE="\e[1;34m"
RESET="\e[0m"

testlib_path="$(realpath "$0")"

_test_assert_failed=""
_test_testn=1
_test_passedn=0
_test_failedn=0
_test_current_test=""
_test_statefile="$(mktemp)"
_test_original_pwd=""
_test_temp_root=""
# Set by each test
results_dir="${results_dir:-}"

test_log() {
	# ash supports echo -e
	# shellcheck disable=SC3037
	echo -e "$*" >&2
}

test_info() {
	# shellcheck disable=SC3037
	echo -e "${BLUE}$*${RESET}" >&2
}

test_debug() {
	# shellcheck disable=SC3037
	echo -e "${YELLOW}$*${RESET}" >&2
}

create_test_root() {
	_test_original_pwd="$(pwd)"
	_test_temp_root="$(mktemp -d)"
	cd "$_test_temp_root"
}

cleanup_test_root() {
	if [ -n "$_test_original_pwd" ]; then
		cd "$_test_original_pwd"
	fi
	if [ -n "$_test_temp_root" ] && [ -d "$_test_temp_root" ]; then
		rm -rf "$_test_temp_root"
	fi
	_test_original_pwd=""
	_test_temp_root=""
}

assert_strequal() {
	# $1: first string
	# $2: second string
	if [ -z "$1" ] || [ -z "$2" ]; then
		test_log "ERROR: assert_equal: not enough arguments given"
		exit 1
	fi
	if [ "$1" != "$2" ]; then
		_test_assert_failed="$1 != $2"
		test_log "    ❌ $_test_assert_failed"
		return
	fi
	test_log "    ✅ $1 == $2"
}

assert_equal() {
	# $1: name of variable
	# $2: value to compare
	if [ -z "$1" ] || [ -z "$2" ]; then
		test_log "ERROR: assert_equal: not enough arguments given"
		exit 1
	fi
	val="$(eval echo "\$$1")"
	if [ "$val" != "$2" ]; then
		_test_assert_failed="\$$1 != $2 (got $val)"
		test_log "    ❌ $_test_assert_failed"
		return
	fi
	test_log "    ✅ \$$1 == $2"
}

assert_unset() {
	if [ -z "$1" ]; then
		test_log "ERROR: assert_unset: not enough arguments given"
		exit 1
	fi
	val="$(eval echo \$"$1")"
	if [ -n "$val" ]; then
		_test_assert_failed="\$$1 should be unset (has value '$val')"
		test_log "    ❌ $_test_assert_failed"
		return
	fi
	test_log "    ✅ \$$1 is unset"
}

assert_exists() {
	# $1: filename to test
	if [ -z "$1" ]; then
		test_log "ERROR: assert_exists: not enough arguments given"
		exit 1
	fi
	if ! [ -e "$1" ]; then
		_test_assert_failed="\$$1 should exist but does not"
		test_log "    ❌ $_test_assert_failed"
		return
	fi
	test_log "    ✅ \$$1 exists"
}

assert_not_exists() {
	if [ -z "$1" ]; then
		test_log "ERROR: assert_not_exists: not enough arguments given"
		exit 1
	fi
	if [ -e "$1" ]; then
		_test_assert_failed="\$$1 should NOT exist but does"
		test_log "    ❌ $_test_assert_failed"
		return
	fi
	test_log "    ✅ \$$1 does not exist"
}

assert_contains() {
	# $1: string to search in
	# $2: substring to find
	if [ -z "$1" ] || [ -z "$2" ]; then
		test_log "ERROR: assert_contains: not enough arguments given"
		exit 1
	fi
	case "$1" in
		*"$2"*)
			test_log "    ✅ '$2' found in '$1'"
			;;
		*)
			_test_assert_failed="'$2' not found in '$1'"
			test_log "    ❌ $_test_assert_failed"
			return
			;;
	esac
}

assert_not_contains() {
	# $1: string to search in
	# $2: substring that should not be found
	if [ -z "$1" ] || [ -z "$2" ]; then
		test_log "ERROR: assert_not_contains: not enough arguments given"
		exit 1
	fi
	case "$1" in
		*"$2"*)
			_test_assert_failed="'$2' found in '$1' but should not be"
			test_log "    ❌ $_test_assert_failed"
			return
			;;
		*)
			test_log "    ✅ '$2' not found in '$1'"
			;;
	esac
}

# Log some expression and evaluate it
logeval() {
	eval "$*"
	test_log "${YELLOW}+ $*${RESET}"
}

# Start a test. Shell scripts involved in the test should be sourced AFTER calling this function!
start_test() {
	if [ -n "$_test_current_test" ]; then
		test_log "ERROR: multiple calls to start_test without calling end_test first!"
		test_log "Current test: $_test_current_test"
		exit 1
	fi
	test_log "==> Test $_test_testn: $1"
	_test_current_test="$1"
	set > "$_test_statefile"
}

# End a test and reset the environment.
end_test() {
	local msg
	local save_assert_failed

	# Restore environment
	save_assert_failed="$_test_assert_failed"

	# Splitting is intentional
	# shellcheck disable=SC2046
	unset $(set | grep "='" | cut -d= -f1 | grep -vE "(PATH|IFS|TERM|LANG|HOME|PWD|SHELL|USER|save_assert_failed|_test_statefile)" )

	# shellcheck disable=SC1090
	. "$_test_statefile"
	_test_assert_failed="$save_assert_failed"

	if [ -n "$_test_assert_failed" ]; then
		msg="${RED}Failed! ❌ ${_test_assert_failed}${RESET}"
		echo "Test $_test_testn: $_test_assert_failed" >> "$results_dir/failed"
		_test_failedn=$((_test_failedn+1))
		echo "$_test_failedn" > "$results_dir/failedn"
		unset _test_assert_failed
	else
		msg="${GREEN}Passed!${RESET}"
		_test_passedn=$((_test_passedn+1))
		echo "$_test_passedn" > "$results_dir/passedn"
	fi
	test_log "<== Test $_test_testn: $msg $_test_current_test\n"
	_test_testn=$((_test_testn+1))
	_test_current_test=""
}

# Call at the end of each testsuite shell script
end_testsuite() {
	if [ -n "$_test_current_test" ]; then
		test_log "${RED}ERROR: end_testsuite called without calling end_test first!${RESET}"
		test_log "${RED}Current test: $_test_current_test${RESET}"
		exit 1
	fi
	if [ -f "$results_dir/failed" ]; then
		exit 1
	fi

	exit 0
}

run_tests() {
	local failed test_results_base
	local test name total passedn failedn t_passed t_failed

	test_results_base="$(mktemp -d)"
	test_log "Running tests for $2"

	# FIXME: yeah this isn't quite the best way to iterate the files
	# shellcheck disable=SC2010
	for name in $(ls "$1" | grep "\.sh$"); do
		test="$1/$name"
		mkdir "$test_results_base/$name"
		echo 0 > "$test_results_base/$name/passedn"
		echo 0 > "$test_results_base/$name/failedn"
		test_log
		test_log "${BOLDBLUE}# Test suite ${name}${RESET}"
		$test "$testlib_path" "$test_results_base/$name" || failed="$failed $name"
		t_passed=$(cat "$test_results_base/$name/passedn")
		t_failed=$(cat "$test_results_base/$name/failedn")
		passedn=$((passedn+t_passed))
		failedn=$((failedn+t_failed))
		total=$((total+t_passed+t_failed))
	done
	if [ -n "$failed" ]; then
		test_log
		test_log "Some tests failed:"
		for test in $failed; do
			test_log "❌ $test"
			test_log "    ${RED}$(cat "$test_results_base/$test/failed")${RESET}"
		done
	fi

	if [ $passedn -lt $total ]; then
		test_log "[${RED}$passedn/$total tests passed${RESET}]"
	else
		test_log "[${GREEN}$passedn/$total tests passed!${RESET}]"
	fi
	test_log

	if [ -n "$failed" ]; then exit 1; else exit 0; fi
}

# FIXME: probably not the best way to determine if this was sourced
if [ $# -gt 0 ]; then
	run_tests "$1" "$2"
fi
