# syntax=docker/dockerfile:1.7
# check=skip=FromPlatformFlagConstDisallowed
#
# n8n for linux/riscv64 on Alpine, with Alpine's own Node.js. Upstream publishes no riscv64
# image (the official n8n images are built on Alpine/DHI for amd64 and arm64). Alpine's Node.js
# is used because the unofficial-builds Node 24 on Debian crashed at random with SIGSEGV on real
# hardware (V8 Runtime_CompileLazy, SpacemiT K1 board), while this one runs stable.
#
# The JS dependency tree is resolved on the build host and only the native addon compile runs
# as riscv64 (npm under qemu-user is slow and crashes).
ARG N8N_VERSION=2.47.4
ARG NODE_MAJOR=24
ARG ALPINE_VERSION=3.24

# Resolve and download the whole dependency tree on the build host. npm picks the
# riscv64 / musl variants of optional platform packages; install scripts run in the
# riscv64 stage below.
FROM --platform=$BUILDPLATFORM node:${NODE_MAJOR}-alpine AS deps
ARG N8N_VERSION
ENV npm_config_fund=false \
    npm_config_audit=false \
    npm_config_update_notifier=false \
    PUPPETEER_SKIP_DOWNLOAD=1 \
    PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
RUN npm install -g --prefix /opt/n8n --omit=dev --ignore-scripts \
        --os=linux --cpu=riscv64 --libc=musl "n8n@${N8N_VERSION}"

# riscv64 from here on (QEMU unless run on a native riscv64 machine).
FROM --platform=linux/riscv64 alpine:${ALPINE_VERSION} AS builder
ARG N8N_VERSION
# V8's JIT segfaults under qemu-user, only the build stage needs the workaround. On a native
# riscv64 machine pass --build-arg BUILD_NODE_OPTIONS=--max-old-space-size=4096.
ARG BUILD_NODE_OPTIONS="--max-old-space-size=4096 --jitless"

RUN apk add --no-cache \
        nodejs nodejs-dev npm build-base python3 py3-setuptools git bash perl linux-headers pkgconf \
        openssl-dev cyrus-sasl-dev zstd-dev lz4-dev curl-dev zlib-dev \
        ada-dev simdjson-dev simdutf-dev sqlite-dev icu-dev
# The last line: Alpine builds Node.js against shared system libraries and the headers in
# nodejs-dev make every addon link with them (-lada -lsimdjson -lsimdutf -lsqlite3 -licuuc ...).

# nodedir: node-gyp uses the headers from nodejs-dev (/usr/include/node), no download needed.
# CKJS_LINKING=dynamic makes @confluentinc/kafka-javascript use the system libssl/zlib/zstd.
ENV npm_config_nodedir=/usr \
    npm_config_jobs=4 \
    CKJS_LINKING=dynamic \
    npm_config_fund=false \
    npm_config_audit=false \
    npm_config_update_notifier=false \
    PUPPETEER_SKIP_DOWNLOAD=1 \
    PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 \
    NODE_OPTIONS=${BUILD_NODE_OPTIONS}

COPY --from=deps /opt/n8n/ /usr/local/

WORKDIR /usr/local/lib/node_modules/n8n
# kafka-javascript's gyp rules race under `make -j`, run its configure step first.
RUN cd node_modules/@confluentinc/kafka-javascript && node util/configure
# cpu-features (optional dependency of ssh2) has no riscv64 support; ssh2 requires it inside
# try/catch, so it is dropped instead of failing the rebuild.
RUN find node_modules -type d -name cpu-features -path '*node_modules/cpu-features' -prune -exec rm -rf {} + \
    && grep -n "cpu-features" node_modules/ssh2/lib/protocol/constants.js
RUN npm rebuild --foreground-scripts

# @parcel/watcher has no riscv64 prebuilt package and only compiles with build_from_source,
# so build it explicitly.
RUN NODEGYP="$(find /usr/lib/node_modules/npm -path '*node-gyp/bin/node-gyp.js' | head -n1)" \
    && test -n "$NODEGYP" \
    && cd node_modules/@parcel/watcher \
    && node "$NODEGYP" rebuild --release -j 4 \
    && ls -la build/Release/watcher.node

# Drop isolated-vm prebuilds so only the freshly built addon loads, and build leftovers.
RUN find /usr/local/lib/node_modules/n8n -type d -name prebuilds -path '*isolated-vm*' -prune -exec rm -rf {} + ; \
    find /usr/local/lib/node_modules/n8n -type d \( -name obj.target -o -name .deps \) -prune -exec rm -rf {} + ; \
    rm -rf /root/.npm /root/.cache /root/.node-gyp /tmp/*

FROM --platform=linux/riscv64 alpine:${ALPINE_VERSION}

ARG N8N_VERSION

RUN apk add --no-cache \
        nodejs ca-certificates curl fontconfig git graphicsmagick openssh-client-default \
        openssl tini tzdata libstdc++ libcurl libsasl lz4-libs zstd-libs zlib \
    && addgroup -g 1000 node \
    && adduser -u 1000 -G node -s /bin/sh -D node

ENV NODE_ENV=production \
    N8N_RELEASE_TYPE=stable \
    SHELL=/bin/sh \
    NODE_PATH=/usr/local/lib/node_modules \
    MAGICK_CODER_STABILITY=PRIMARY \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

COPY --from=builder /usr/local /usr/local
COPY docker-entrypoint.sh /docker-entrypoint.sh

# V8 flags that make Node.js usable on riscv64 hardware and under qemu-user. Other than a short
# list they cannot go through NODE_OPTIONS, so a wrapper sits ahead of the real binary in PATH:
# n8n's `#!/usr/bin/env node` shebang and the task runner's spawn('node') both resolve through
# PATH, so the main process and the runner get the flags.
#  --no-sparkplug              Sparkplug baseline compiler segfaults (qemu-user, and on hardware)
#  --disable-wasm-trap-handler V8 otherwise reserves ~10 GiB of address space per WebAssembly
#                              memory; Sv39 boards have 256 GiB in total, so n8n runs out
#                              ("Cannot allocate Wasm memory") and crashes
RUN mkdir -p /usr/local/sbin \
    && printf '#!/bin/sh\nexec /usr/bin/node --no-sparkplug --disable-wasm-trap-handler "$@"\n' > /usr/local/sbin/node \
    && chmod +x /usr/local/sbin/node

WORKDIR /home/node
RUN mkdir -p /home/node/.n8n /home/node/.cache && chown -R node:node /home/node

EXPOSE 5678/tcp
USER node
ENTRYPOINT ["tini", "--", "/docker-entrypoint.sh"]
HEALTHCHECK --start-period=120s --interval=60s --timeout=10s \
    CMD curl -fsS -o /dev/null http://127.0.0.1:5678/healthz || exit 1

LABEL org.opencontainers.image.title="n8n (riscv64, Alpine)" \
      org.opencontainers.image.description="Unofficial n8n build for linux/riscv64 on Alpine" \
      org.opencontainers.image.source="https://github.com/n8n-io/n8n" \
      org.opencontainers.image.url="https://n8n.io" \
      org.opencontainers.image.version="${N8N_VERSION}"
