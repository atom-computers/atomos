#!/bin/sh

CRYPTTAB_SOURCE="$1" CRYPTTAB_TRIED="$2" unl0kr | cryptsetup --perf-no_read_workqueue --perf-no_write_workqueue open "$1" root -
