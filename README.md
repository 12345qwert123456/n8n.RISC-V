# n8n on RISC-V (riscv64)

Unofficial [n8n](https://github.com/n8n-io/n8n) builds for `linux/riscv64`. Built from the published `n8n` npm package, no patches applied.

![platform](https://img.shields.io/badge/platform-linux%2Friscv64-blue)

## Quick start

```bash
docker run -d --name n8n --restart unless-stopped \
  -p 5678:5678 \
  -v n8n_data:/home/node/.n8n \
  12345qwert123456/n8n-riscv64:latest
```

Then open <http://localhost:5678>. The first start runs the database migrations and is slow on small boards.

```yaml
services:
  n8n:
    image: 12345qwert123456/n8n-riscv64:latest
    restart: unless-stopped
    ports:
      - "5678:5678"
    environment:
      - GENERIC_TIMEZONE=Europe/Moscow
      - TZ=Europe/Moscow
    volumes:
      - n8n_data:/home/node/.n8n

volumes:
  n8n_data:
```

Tags: `<version>` (for example `2.46.7`) and `latest`. Every build also gets a GitHub Release named `<version>-riscv64`.

Configuration is the same as for the official image, see the [n8n docs](https://docs.n8n.io/hosting/configuration/environment-variables/). The container runs as `node` (uid 1000), data lives in `/home/node/.n8n`.

## How it works

| Stage | Base | What it does |
|---|---|---|
| `node` | `debian:trixie-slim` (build host) | Downloads the Node.js riscv64 build from `unofficial-builds.nodejs.org` and checks its SHA-256. |
| `deps` | `node:<major>-trixie-slim` (build host) | `npm install -g n8n@<version> --os=linux --cpu=riscv64 --ignore-scripts`. Resolves and downloads the whole dependency tree natively, npm picks the riscv64 variants of platform packages. |
| `builder` | `debian:trixie-slim` (riscv64) | Runs `npm rebuild` so the native addons (`sqlite3`, `isolated-vm`, `@confluentinc/kafka-javascript` with its bundled librdkafka 2.14, `@parcel/watcher`, Sentry profilers) are compiled with node-gyp. |
| final | `debian:trixie-slim` (riscv64) | Runtime packages (`tini`, `graphicsmagick`, `openssh-client`, `git`, ...), Node.js and n8n copied over, entrypoint taken from upstream. |

A daily workflow checks `npm`'s `latest` for `n8n`. If no release `<version>-riscv64` exists yet, it builds the image, runs smoke tests and publishes. The Node.js major is read from the package's `engines` field.

Smoke tests: image architecture, `n8n --version`, all compiled addons load and are RISC-V ELF files, a workflow with a Code node (JS task runner) runs and returns the expected result, and a real container reaches `/healthz/readiness`.

Node 24's V8 can crash under some qemu-user versions: with QEMU 11.1.2 its Sparkplug baseline compiler segfaults (`node -e 1` dies, even `npm` does). The workflow probes the emulator and runs every Node process of the tests through a wrapper that adds `--no-sparkplug` when needed. `--jitless` is the last resort; it disables WebAssembly, which n8n needs at startup, so the start tests are skipped then. None of this affects the image: on real riscv64 hardware Node runs normally.

## Why not upstream

- `docker.io/node` has no riscv64 variant, and the official n8n images are built on Alpine/DHI for amd64 and arm64 only.
- `sqlite3`, `isolated-vm`, `@confluentinc/kafka-javascript` and `@parcel/watcher` ship no riscv64 binaries and are compiled during the build.

## Limitations

- No external task runner image (`n8nio/runners`). The built-in (internal) task runner uses the bundled Node.js.
- `cpu-features` (an optional speed-up for `ssh2`) does not support riscv64 and is removed; `ssh2` works without it.
- Node.js comes from the unofficial riscv64 builds, which are not covered by upstream support.

## Build locally

On a riscv64 machine, or on any host with QEMU user emulation (`qemu-user-static` / `binfmt`):

```bash
docker buildx build --platform linux/riscv64 --load \
  --build-arg N8N_VERSION=2.46.7 --build-arg NODE_VERSION=24.22.2 \
  -t n8n:riscv64 .
```

Under emulation this takes a long time (compiling `isolated-vm` and librdkafka dominates). With a QEMU whose V8 JIT crashes, the build stage runs Node with `--jitless` (`BUILD_NODE_OPTIONS`); on a native riscv64 machine pass `--build-arg BUILD_NODE_OPTIONS=--max-old-space-size=4096`. Rootless podman forwards the host's `HTTP_PROXY` variables into the build; add `--http-proxy=false` if they point to `127.0.0.1`. `NODE_VERSION` must exist as `node-v<version>-linux-riscv64.tar.xz` on [unofficial-builds.nodejs.org](https://unofficial-builds.nodejs.org/download/release/).

## CI setup

Settings of the GitHub repository:

- variable `DOCKERHUB_USERNAME`
- secret `DOCKERHUB_TOKEN`

Without `DOCKERHUB_USERNAME` the image is built and tested, but not pushed. The workflow can be started manually with `force`, `version` and `runner` (for example the label of a self-hosted riscv64 runner for a native build).

## License

The build files in this repository are MIT licensed. n8n itself is distributed under the [Sustainable Use License](https://github.com/n8n-io/n8n/blob/master/LICENSE.md).
