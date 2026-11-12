# syntax=docker/dockerfile:1.7
# check=skip=FromPlatformFlagConstDisallowed
#
# n8n for linux/riscv64. Upstream publishes no riscv64 image: docker.io/node has
# no riscv64 variant and the n8n images are built on Alpine/DHI (amd64, arm64).
# This installs the published `n8n` npm package on Debian trixie with the
# unofficial Node.js riscv64 build and compiles the native addons in place.
# The JS dependency tree is resolved and fetched on the build host (npm under
# qemu-user is slow and crashes); only the native addon compile runs as riscv64.
#
# The ARG defaults only serve plain local builds; CI passes the real values.
ARG N8N_VERSION=2.46.7
ARG NODE_VERSION=24.22.2
ARG NODE_MAJOR=24

# Fetch Node.js on the build host: no riscv64 code runs in this stage.
FROM --platform=$BUILDPLATFORM debian:trixie-slim AS node
ARG NODE_VERSION
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl xz-utils \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /dl
RUN set -eu; \
    base="https://unofficial-builds.nodejs.org/download/release/v${NODE_VERSION}"; \
    tarball="node-v${NODE_VERSION}-linux-riscv64.tar.xz"; \
    curl -fsSL --retry 5 -O "${base}/${tarball}"; \
    curl -fsSL --retry 5 -O "${base}/SHASUMS256.txt"; \
    grep " ${tarball}\$" SHASUMS256.txt | sha256sum -c -; \
    mkdir /node; \
    tar -xJf "${tarball}" -C /node --strip-components=1

# Resolve and download the whole dependency tree on the build host. npm picks the
# riscv64 variants of optional platform packages; install scripts are skipped here
# and run in the riscv64 stage below.
FROM --platform=$BUILDPLATFORM node:${NODE_MAJOR}-trixie-slim AS deps
ARG N8N_VERSION
ENV npm_config_fund=false \
    npm_config_audit=false \
    npm_config_update_notifier=false \
    PUPPETEER_SKIP_DOWNLOAD=1 \
    PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
RUN npm install -g --prefix /opt/n8n --omit=dev --ignore-scripts \
        --os=linux --cpu=riscv64 --libc=glibc "n8n@${N8N_VERSION}"

# riscv64 from here on (QEMU unless run on a native riscv64 machine).
FROM --platform=linux/riscv64 debian:trixie-slim AS builder
ARG N8N_VERSION
# V8's JIT segfaults under qemu-user (seen with QEMU 11.1.2, Node 24: `node -e 1` dies,
# `node --jitless -e 1` works). Only the build stage needs it, it is not copied to the final
# image. On a native riscv64 machine pass --build-arg BUILD_NODE_OPTIONS=--max-old-space-size=4096.
ARG BUILD_NODE_OPTIONS="--max-old-space-size=4096 --jitless"

# A single failed .deb download would otherwise kill a slow emulated stage.
RUN printf 'Acquire::Retries "10";\nAcquire::http::Pipeline-Depth "0";\nAcquire::ForceIPv4 "true";\n' \
    > /etc/apt/apt.conf.d/99-build-robust
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential python3 python3-setuptools git ca-certificates pkg-config \
        libssl-dev libsasl2-dev libzstd-dev liblz4-dev libcurl4-openssl-dev zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

COPY --from=node /node/ /usr/local/

# @confluentinc/kafka-javascript needs a newer librdkafka than Debian ships, so its
# bundled sources are compiled here. CKJS_LINKING=dynamic makes its configure use the
# system libssl/zlib/zstd instead of downloading and building them from source, and
# leaves librdkafka.so in the package's build/deps (found through an $ORIGIN rpath).
# nodedir: node-gyp uses the headers shipped in the tarball, no download needed.
# Browser downloads are skipped, n8n does not need them at install time.
ENV npm_config_nodedir=/usr/local \
    npm_config_jobs=4 \
    CKJS_LINKING=dynamic \
    npm_config_fund=false \
    npm_config_audit=false \
    npm_config_update_notifier=false \
    PUPPETEER_SKIP_DOWNLOAD=1 \
    PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 \
    NODE_OPTIONS=${BUILD_NODE_OPTIONS}

COPY --from=deps /opt/n8n/ /usr/local/

# prebuild-install finds no riscv64 binary for sqlite3 / isolated-vm and falls
# back to node-gyp, which is the compile this stage is for.
WORKDIR /usr/local/lib/node_modules/n8n
# Run kafka-javascript's configure step first: its gyp rules race under `make -j` (the
# librdkafka build can start before config.h exists, "No rule to make target config.h").
RUN cd node_modules/@confluentinc/kafka-javascript && node util/configure
# cpu-features (optional dependency of ssh2) has no riscv64 support and fails to compile;
# ssh2 requires it inside try/catch, so it is dropped instead of failing the rebuild.
RUN find node_modules -type d -name cpu-features -path '*node_modules/cpu-features' -prune -exec rm -rf {} + \
    && grep -n "cpu-features" node_modules/ssh2/lib/protocol/constants.js
RUN npm rebuild --foreground-scripts

# @parcel/watcher is a direct dependency of n8n. There is no riscv64 prebuilt package, and its
# install script only compiles when npm_config_build_from_source=true, so build it explicitly.
RUN cd node_modules/@parcel/watcher \
    && node /usr/local/lib/node_modules/npm/node_modules/node-gyp/bin/node-gyp.js rebuild --release -j 4 \
    && ls -la build/Release/watcher.node

# Official image drops isolated-vm prebuilds so only the freshly built addon loads.
RUN find /usr/local/lib/node_modules/n8n -type d -name prebuilds -path '*isolated-vm*' -prune -exec rm -rf {} + ; \
    # Build leftovers; the compiled .node files live in build/Release.
    find /usr/local/lib/node_modules/n8n -type d \( -name obj.target -o -name .deps \) -prune -exec rm -rf {} + ; \
    rm -rf /root/.npm /root/.cache /root/.node-gyp /tmp/* /usr/local/include /usr/local/share/doc

FROM --platform=linux/riscv64 debian:trixie-slim

ARG N8N_VERSION

RUN printf 'Acquire::Retries "10";\nAcquire::http::Pipeline-Depth "0";\nAcquire::ForceIPv4 "true";\n' \
        > /etc/apt/apt.conf.d/99-build-robust \
    && apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl fontconfig git graphicsmagick libcurl4t64 liblz4-1 libsasl2-2 libzstd1 openssh-client openssl tini tzdata zlib1g \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 1000 node \
    && useradd --uid 1000 --gid node --shell /bin/sh --create-home node

ENV NODE_ENV=production \
    N8N_RELEASE_TYPE=stable \
    SHELL=/bin/sh \
    NODE_PATH=/usr/local/lib/node_modules \
    MAGICK_CODER_STABILITY=PRIMARY \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

COPY --from=builder /usr/local /usr/local
COPY docker-entrypoint.sh /docker-entrypoint.sh

# This Node.js build segfaults at startup in V8's Sparkplug baseline compiler (exit 139, no
# output): seen under qemu-user and on real riscv64 hardware. --no-sparkplug fixes it, but V8
# flags other than a short list cannot go through NODE_OPTIONS. So a wrapper sits ahead of the
# real binary in PATH: n8n's `#!/usr/bin/env node` shebang and the task runner's spawn('node')
# both resolve through PATH, so the main process and the runner get the flag. The real binary
# stays in /usr/local/bin because n8n derives the npm location from process.execPath.
#   --disable-wasm-trap-handler: V8 otherwise reserves ~10 GiB of address space per WebAssembly
#   memory; boards with Sv39 (SpacemiT K1 and most others) have 256 GiB in total, so n8n runs
#   out ("Cannot allocate Wasm memory") and crashes with SIGSEGV.
RUN printf '#!/bin/sh\nexec /usr/local/bin/node --no-sparkplug --disable-wasm-trap-handler "$@"\n' > /usr/local/sbin/node \
    && chmod +x /usr/local/sbin/node \
    && node -v

WORKDIR /home/node
RUN mkdir -p /home/node/.n8n && chown -R node:node /home/node

EXPOSE 5678/tcp
USER node
ENTRYPOINT ["tini", "--", "/docker-entrypoint.sh"]
HEALTHCHECK --start-period=120s --interval=60s --timeout=10s \
    CMD curl -fsS -o /dev/null http://127.0.0.1:5678/healthz || exit 1

LABEL org.opencontainers.image.title="n8n (riscv64)" \
      org.opencontainers.image.description="Unofficial n8n build for linux/riscv64" \
      org.opencontainers.image.source="https://github.com/n8n-io/n8n" \
      org.opencontainers.image.url="https://n8n.io" \
      org.opencontainers.image.version="${N8N_VERSION}"
