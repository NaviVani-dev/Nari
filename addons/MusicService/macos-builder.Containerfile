FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential clang lld llvm-dev libclang-dev cmake git patch xz-utils cpio bzip2 \
        libssl-dev libxml2-dev zlib1g-dev uuid-dev libbz2-dev liblzma-dev \
        pkg-config python3 python3-pip python3-venv ca-certificates curl nasm \
    && rm -rf /var/lib/apt/lists/* \
    && python3 -m venv /opt/scons && /opt/scons/bin/pip install --no-cache-dir scons \
    && ln -s /opt/scons/bin/scons /usr/local/bin/scons

COPY MacOSX14.5.sdk.tar.xz /tmp/sdk/
RUN git clone --depth 1 https://github.com/tpoechtrager/osxcross /opt/osxcross \
    && mv /tmp/sdk/MacOSX14.5.sdk.tar.xz /opt/osxcross/tarballs/ \
    && cd /opt/osxcross && UNATTENDED=1 TARGET_DIR=/opt/osxcross/target ./build.sh \
    && rm -rf /opt/osxcross/build /opt/osxcross/tarballs/*

ENV RUSTUP_HOME=/opt/rustup CARGO_HOME_BASE=/opt/cargo
RUN curl -fsSL https://sh.rustup.rs | CARGO_HOME=/opt/cargo sh -s -- -y --profile minimal \
        -t aarch64-apple-darwin -t x86_64-apple-darwin \
    && chmod -R a+rX /opt/rustup /opt/cargo

ENV OSXCROSS_ROOT=/opt/osxcross PATH=/opt/osxcross/target/bin:/opt/cargo/bin:$PATH

RUN rm -f /opt/osxcross/target/SDK/MacOSX*.sdk/usr/include/libxml/module.modulemap

RUN apt-get update && apt-get install -y --no-install-recommends gnupg lsb-release software-properties-common wget \
    && curl -fsSL https://apt.llvm.org/llvm.sh -o /tmp/llvm.sh && bash /tmp/llvm.sh 20 \
    && apt-get install -y --no-install-recommends clang-20 lld-20 libclang-20-dev \
    && rm -rf /var/lib/apt/lists/*
ENV PATH=/usr/lib/llvm-20/bin:$PATH

RUN cd /opt/osxcross && ENABLE_COMPILER_RT_INSTALL=1 DISABLE_PARALLEL_ARCH_BUILD=1 JOBS=4 ./build_compiler_rt.sh \
    && rm -rf /opt/osxcross/build
