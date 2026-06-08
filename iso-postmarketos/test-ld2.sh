#!/bin/sh
docker run --rm --platform linux/arm64 alpine:edge sh -c '
    apk add --no-cache bash readline >/dev/null 2>&1
    mkdir -p /target/usr/lib /target/lib /target/bin
    cp /bin/bash /target/bin/
    cp /lib/ld-musl-aarch64.so.1 /target/lib/
    cp -a /usr/lib/libreadline* /target/usr/lib/
    cp -a /usr/lib/libncurses* /target/usr/lib/
    # REMOVE them from the host container so ld-musl MUST use --library-path
    apk del readline ncurses-libs ncurses-terminfo-base >/dev/null 2>&1 || true
    rm -f /usr/lib/libreadline* /usr/lib/libncurses*
    /target/lib/ld-musl-aarch64.so.1 --library-path "/target/usr/lib:/target/lib" /target/bin/bash -c "echo hello"
'
