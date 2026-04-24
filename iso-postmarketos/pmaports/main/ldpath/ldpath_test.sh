#!/bin/sh

testdir=$(mktemp -d)
ld_musl_file="${testdir}/ld-musl-test.path"

lib_path="/usr/lib/foo"
lib_path2="/usr/lib/bar"

# Create ldso config file and add a path to it.
sh ldpath.sh -f "$ld_musl_file" add "$lib_path"

if ! grep -q "$lib_path" "$ld_musl_file"; then
	echo "ERROR: Did not find $lib_path in newly created config file."
	exit 1
fi

# Add another path to config file.
sh ldpath.sh -f "$ld_musl_file" add "$lib_path2"
if ! grep -q "$lib_path2" "$ld_musl_file"; then
	echo "ERROR: Did not find $lib_path2 in config file."
	exit 1
fi

# Check that first path is still present
if ! grep -q "$lib_path" "$ld_musl_file"; then
	echo "ERROR: Did not find $lib_path in config file."
	exit 1
fi

# Remove the first path
sh ldpath.sh -f "$ld_musl_file" remove "$lib_path"
if grep -q "$lib_path" "$ld_musl_file"; then
	echo "ERROR: $lib_path was not removed from config file."
	exit 1
fi

# Check that second path is still present
if ! grep -q "$lib_path2" "$ld_musl_file"; then
	echo "ERROR: $lib_path2 should not have been removed."
	exit 1
fi

# Remove the second path
sh ldpath.sh -f "$ld_musl_file" remove "$lib_path2"
if grep -q "$lib_path2" "$ld_musl_file"; then
	echo "ERROR: $lib_path2 was not removed from config file."
	exit 1
fi

# Don't allow removal of default paths
_default_paths="/lib /usr/local/lib /usr/lib"
for _path in $_default_paths
do
	sh ldpath.sh -f "$ld_musl_file" remove "$_path"
	if ! grep -q "$_path" "$ld_musl_file"; then
		echo "ERROR: Default path $_path should not have been removed."
		exit 1
	fi
done

# Don't allow duplicates
sh ldpath.sh -f "$ld_musl_file" add "$lib_path"
sh ldpath.sh -f "$ld_musl_file" add "$lib_path"
_count=$(grep -o "$lib_path" "$ld_musl_file" | wc -l)
if [ "$_count" -ne 1 ]; then
	echo "ERROR: Multiple entries of $lib_path."
	exit 1
fi

# Cleanup
rm -r "$testdir"

exit 0
