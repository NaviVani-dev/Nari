FROM ubuntu:22.04

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        python3 \
        scons \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*
