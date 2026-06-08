#!/bin/sh
docker run --rm --platform linux/arm64 alpine:edge sh -c '
    apk add --no-cache bash readline >/dev/null 2>&1
    mkdir -p /target/usr/lib /target/lib /target/bin
    cp /bin/bash /target/bin/
    cp /lib/ld-musl-aarch64.so.1 /target/lib/
    cp /usr/lib/libreadline* /target/usr/lib/
    # do NOT copy libncursesw.so.6 to /target
    # and uninstall from container to simulate missing
    apk del ncurses-libs ncurses-terminfo-base >/dev/null 2>&1 || true
    /target/lib/ld-musl-aarch64.so.1 --library-path /target/usr/lib:/target/lib /target/bin/bash -c "echo hello"
'
