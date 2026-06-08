#!/bin/sh
docker run --rm alpine:edge /bin/sh -c "
    echo \"/target/lib/ld-musl-aarch64.so.1 --library-path \\\"\$_atomos_target_libpath\\\" /target/bin/bash \\\"\\\$@\\\"\" > /tmp/out
    cat /tmp/out
"
