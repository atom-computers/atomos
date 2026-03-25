FROM python:3.12-bookworm

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    dosfstools \
    e2fsprogs \
    gcc-aarch64-linux-gnu \
    git \
    kmod \
    kpartx \
    lld \
    openssl \
    parted \
    python3-venv \
    qemu-user-static \
    rsync \
    sudo \
    tar \
    udev \
    util-linux \
    xz-utils \
    && rm -rf /var/lib/apt/lists/*

RUN python3 -m pip install --no-cache-dir --upgrade pip && \
    python3 -m pip install --no-cache-dir "git+https://gitlab.postmarketos.org/postmarketOS/pmbootstrap.git"

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable && \
    . "$HOME/.cargo/env" && \
    rustup target add aarch64-unknown-linux-musl

ENV PATH="/root/.cargo/bin:${PATH}"

# Cross-linker config: Rust ships its own musl CRT objects for
# aarch64-unknown-linux-musl (passed via -nostartfiles + self-contained sysroot).
# We just need a linker that can emit aarch64 ELF — the GNU cross-gcc already
# installed above does this without needing a separate musl toolchain.
RUN mkdir -p /root/.cargo && \
    printf '[target.aarch64-unknown-linux-musl]\nlinker = "aarch64-linux-gnu-gcc"\n' \
    >> /root/.cargo/config.toml

WORKDIR /work
