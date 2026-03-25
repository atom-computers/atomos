FROM alpine:3.20

RUN apk add --no-cache \
    alpine-sdk \
    bash \
    ca-certificates \
    cmake \
    clang \
    coreutils \
    curl \
    dbus-dev \
    dosfstools \
    e2fsprogs \
    findutils \
    git \
    lld \
    linux-headers \
    openssl-dev \
    parted \
    pkgconf \
    python3 \
    qemu-img \
    qemu-system-aarch64 \
    rsync \
    sed \
    tar \
    util-linux \
    xz \
    zstd

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable && \
    . "$HOME/.cargo/env" && \
    rustup target add aarch64-unknown-linux-musl

# rust-lld + self-contained is for minimal apk/bootstrap use. It breaks proc-macro linking on Alpine
# (-lgcc_s/-lc). For full Rust cross-builds with GNU linkers, use docker/pmbootstrap.Dockerfile instead.
RUN mkdir -p /root/.cargo && \
    printf '[target.aarch64-unknown-linux-musl]\nlinker = "rust-lld"\nrustflags = ["-Clink-self-contained=yes"]\n' \
    >> /root/.cargo/config.toml

ENV PATH="/root/.cargo/bin:${PATH}"

WORKDIR /work
