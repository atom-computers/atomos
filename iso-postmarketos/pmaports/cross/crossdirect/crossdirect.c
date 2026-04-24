/* Copyright 2020 Zhuowei Zhang, Oliver Smith
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * This program gets built to a set of wrapper executables, which launch native
 * cross compilers inside foreign arch chroots. Speeds up cross compilation a
 * lot, compared to using just qemu user mode emulation or using the previous
 * distcc-based methods.
 *
 * How this program gets called:
 * - pmbootstrap creates one native arch chroot and one foreign arch chroot.
 * - The native chroot gets mounted as /native in the foreign chroot.
 * - When calling "abuild", pmbootstrap sets PATH to:
 *   /native/usr/lib/crossdirect/<ARCH>:$PATH
 * - That crossdirect directory contains a crossdirect-<ARCH> binary built with
 *   the matching HOSTSPEC (e.g. crossdirect-aarch64 binary with HOSTSPEC
 *   aarch64-alpine-linux-musl). This binary is symlinked to:
 *	- <HOSTSPEC>-c++
 *	- <HOSTSPEC>-cc
 *	- <HOSTSPEC>-clang
 *	- <HOSTSPEC>-clang++
 *	- <HOSTSPEC>-cpp
 *	- <HOSTSPEC>-g++
 *	- <HOSTSPEC>-gcc
 *	- c++
 *	- cc
 *	- clang
 *	- clang++
 *	- cpp
 *	- g++
 *	- gcc
 */

#include <errno.h>
#include <libgen.h>
#include <limits.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define NATIVE_BIN_DIR "/native/usr/lib/ccache/bin"

void exit_userfriendly()
{
	fprintf(stderr, "Please report this at: https://gitlab.postmarketos.org/postmarketOS/pmaports/issues\n");
	fprintf(stderr, "As a workaround, you can compile without crossdirect with options=\"!pmb:crossdirect\".\n");
	exit(1);
}

bool argv_has_arg(int argc, char **argv, const char *arg)
{
	size_t arg_len = strlen(arg);

	for (int i = 1; i < argc; i++) {
		if (strlen(argv[i]) < arg_len)
			continue;

		if (!memcmp(argv[i], arg, arg_len))
			return true;
	}
	return false;
}

int main(int argc, char **argv)
{
	// we have a max of four extra args ("-target", "HOSTSPEC", "--sysroot=/", "-Wl,-rpath-link=/lib:/usr/lib"), plus one ending null
	char *newargv[argc + 5];
	char *executableName = basename(argv[0]);
	char newExecutable[PATH_MAX];
	bool isClang = (strcmp(executableName, "clang") == 0 || strcmp(executableName, "clang++") == 0);
	bool startsWithHostSpec = (strncmp(HOSTSPEC, executableName, sizeof(HOSTSPEC) - 1) == 0);

	// linker is involved: just use qemu binary (to avoid broken cross-ld, pmaports#227)
	if (!argv_has_arg(argc, argv, "-c")) {
		snprintf(newExecutable, sizeof(newExecutable), "/usr/bin/%s", executableName);
		if (execv(newExecutable, argv) == -1) {
			fprintf(stderr, "ERROR: crossdirect: failed to execute %s: %s\n", newExecutable, strerror(errno));
			fprintf(stderr, "NOTE: this is a foreign arch binary that would run with qemu (linker is involved).\n");
			exit_userfriendly();
		}
	}

	// Translate "cc" to "gcc": /usr/bin/cc is a symlink to /usr/bin/gcc,
	// but there is no <HOSTSPEC>-cc symlink (pmaports#732)
	if (strcmp(executableName, "cc") == 0)
		executableName = "gcc";

	// prepend the HOSTSPEC to GCC binaries
	if (isClang || startsWithHostSpec) {
		snprintf(newExecutable, sizeof(newExecutable), NATIVE_BIN_DIR "/%s", executableName);
	} else {
		snprintf(newExecutable, sizeof(newExecutable), NATIVE_BIN_DIR "/" HOSTSPEC "-%s", executableName);
	}

	// prepare new arguments for GCC / clang
	char **newArgsPtr = newargv;
	*newArgsPtr++ = newExecutable;
	if (isClang) {
		// clang does not use a HOSTSPEC prefix for the cross compiler
		// binary, but instead have a -target argument
		*newArgsPtr++ = "-target";
		*newArgsPtr++ = HOSTSPEC;
	}
	*newArgsPtr++ = "--sysroot=/";

	// add all arguments passed to this executable to GCC / clang and set
	// the last arg in newargv to NULL to mark its end
	memcpy(newArgsPtr, argv + 1, sizeof(char *) * (argc - 1));
	newArgsPtr += (argc - 1);
	*newArgsPtr = NULL;

	// new arguments prepared; now setup environmental vars
	char *env[] = { "LD_PRELOAD=",
		"LD_LIBRARY_PATH=/native/lib:/native/usr/lib",
		"CCACHE_PATH=/native/usr/bin",
		NULL };
	char *ldPreload = getenv("LD_PRELOAD");
	if (ldPreload) {
		if (strstr(ldPreload, "libfakeroot.so")) {
			fprintf(stderr, "============================================================================================\n");
			fprintf(stderr, "ERROR: crossdirect was called with: LD_PRELOAD=%s\n", ldPreload);
			fprintf(stderr, "This means your package tried to run a compiler during package().\n");
			fprintf(stderr, "This is not supported by crossdirect, and usually not a good idea.\n");
			fprintf(stderr, "* Try to fix your APKBUILD so it does not run the compiler during package(), only in build()\n");
			fprintf(stderr, "  * If you're using 'meson install', try to add '--no-rebuild'\n");
			fprintf(stderr, "* If this is not possible, you can work around it by setting options=\"!pmb:crossdirect\"\n");
			fprintf(stderr, "  (compilation will be slower!)\n");
			fprintf(stderr, "============================================================================================\n");
			exit(1);
		}
	}

	// finally exec GCC / clang
	if (execve(newExecutable, newargv, env) == -1) {
		fprintf(stderr, "ERROR: crossdirect: failed to execute %s: %s\n", newExecutable, strerror(errno));
		fprintf(stderr, "Maybe the target arch is missing in the ccache-cross-symlinks package?\n");
		exit_userfriendly();
	}
	return 1;
}
