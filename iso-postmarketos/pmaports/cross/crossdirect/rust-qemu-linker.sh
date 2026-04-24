#!/bin/sh -e
# This wrapper gets called from the native rustc, and runs the qemu gcc for
# linking, with LD_LIBRARY_PATH reset so it does not point to /native anymore.
# It isn't possible to use the native cross compiler's linker with crossdirect
# currently (pmaports#233).

LD_LIBRARY_PATH=/lib:/usr/lib \
	gcc "$@"
