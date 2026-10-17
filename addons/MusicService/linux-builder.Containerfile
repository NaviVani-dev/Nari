FROM ubuntu:22.04

RUN dpkg --add-architecture arm64 \
    && sed -i 's/^deb /deb [arch=amd64] /' /etc/apt/sources.list \
    && printf 'deb [arch=arm64] http://ports.ubuntu.com/ubuntu-ports jammy main universe\ndeb [arch=arm64] http://ports.ubuntu.com/ubuntu-ports jammy-updates main universe\n' \
        > /etc/apt/sources.list.d/arm64.list

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        gcc-aarch64-linux-gnu \
        g++-aarch64-linux-gnu \
        libasound2-dev:arm64 \
        pkg-config \
        libasound2-dev \
        clang \
        libclang-dev \
        curl \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN apt-get update && apt-get install -y --no-install-recommends \
        libgtk-3-dev \
        libwebkit2gtk-4.1-dev \
        libgtk-3-dev:arm64 \
        libsoup-3.0-0:arm64 \
        libwebkit2gtk-4.1-0:arm64 \
        libjavascriptcoregtk-4.1-0:arm64 \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /opt/arm64-pkgconfig \
    && for pc in /usr/lib/x86_64-linux-gnu/pkgconfig/*.pc; do \
        [ -e /usr/lib/aarch64-linux-gnu/pkgconfig/$(basename $pc) ] \
            || sed 's/x86_64-linux-gnu/aarch64-linux-gnu/g' $pc > /opt/arm64-pkgconfig/$(basename $pc); \
    done \
    && for lib in webkit2gtk-4.1 javascriptcoregtk-4.1 soup-3.0; do \
        ln -s lib$lib.so.0 /usr/lib/aarch64-linux-gnu/lib$lib.so; \
    done

ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:$PATH

RUN curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable \
    && rustup target add aarch64-unknown-linux-gnu \
    && chmod -R a+rwX /usr/local/rustup /usr/local/cargo

RUN apt-get update && apt-get install -y --no-install-recommends python3 \
    && rm -rf /var/lib/apt/lists/*
