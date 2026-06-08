#!/bin/sh
docker run --rm --platform linux/arm64 alpine:edge sh -c '
    apk add --no-cache bash readline >/dev/null 2>&1
    mkdir -p /target/usr/lib /target/lib /target/bin
    cp /bin/bash /target/bin/
    cp /lib/ld-musl-aarch64.so.1 /target/lib/
    cp -a /usr/lib/libreadline* /target/usr/lib/
    cp -a /usr/lib/libncurses* /target/usr/lib/
    apk del readline ncurses-libs ncurses-terminfo-base >/dev/null 2>&1 || true
    rm -f /usr/lib/libreadline* /usr/lib/libncurses*

    _atomos_target_libpath=/target/usr/lib:/target/lib
    mkdir -p /tmp/bin
    echo "#!/bin/sh" > /tmp/bin/bash
    echo "/target/lib/ld-musl-aarch64.so.1 --library-path \"$_atomos_target_libpath\" /target/bin/bash \"\$@\"" >> /tmp/bin/bash
    chmod +x /tmp/bin/bash
    atomos_bash() {
        PATH=/tmp/bin:/usr/bin:/bin:/usr/sbin:/sbin:/target/usr/bin:/target/bin \
        /tmp/bin/bash "$@"
    }
    
    # Simulate a script that calls bash
    echo "bash -c \"echo hello from inner bash\"" > /tmp/test-script.sh
    atomos_bash /tmp/test-script.sh
'
