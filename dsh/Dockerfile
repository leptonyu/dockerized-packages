# dsh — the DeepSeek Harness Web GUI (`dsh web`) as a container.
#
# This line is the image version's single source of truth: a dsh release tag
# without its `dsh-v` prefix. Renovate reads it (see ../renovate.json) and takes
# `dsh-v0.1.7-rc.1` while refusing `dsh-v0.1.7-alpha.2`.
ARG DSH_VERSION=0.1.7-rc.1

FROM node:24-trixie-slim AS installer

ARG DSH_VERSION

# Every native piece of the runtime — node-pty, koffi, the system addon, and
# ripgrep — ships a prebuilt binary for linux/amd64 and linux/arm64 inside its
# own published package, so no toolchain is needed here to install or run it.
RUN npm install --global --prefix /opt/dsh --no-fund --no-audit \
      "@deepseek-ai/dsh@${DSH_VERSION}" \
 && npm cache clean --force

# Renovate tracks this tag like every other base image in this repository.
FROM rust:1.98.1-slim-trixie AS rust

FROM node:24-trixie-slim

ARG DSH_VERSION

# The harness shell and the agent's own commands expect these on PATH, and Rust
# needs a linker: gcc + libc6-dev is exactly what the upstream rust image
# installs for it, plus pkg-config for the `*-sys` crates that probe with it.
# `ripgrep` is deliberately absent: @vscode/ripgrep brings its own binary.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash \
      ca-certificates \
      curl \
      gcc \
      git \
      jq \
      less \
      libc6-dev \
      pkg-config \
      procps \
      python3 \
      tini \
 && rm -rf /var/lib/apt/lists/*

# The global install is self-contained, so the runtime stage is only that tree.
COPY --from=installer /opt/dsh /opt/dsh

# The upstream toolchain in its own layout. It installs the minimal profile and
# marks both trees world-writable, so the unprivileged `node` user can fetch
# crates and run `rustup component add rustfmt clippy`.
COPY --from=rust /usr/local/rustup /usr/local/rustup
COPY --from=rust /usr/local/cargo /usr/local/cargo

# Overlays the ENTRYPOINT (container.patch.yml) and an operator (hardened.patch.yml)
# can apply. `dsh web` composes the Web server on 127.0.0.1 and refuses
# `--host 0.0.0.0`; the first rebinds that one row so a published container port
# reaches the GUI. The second locks the file policy against widening.
COPY container.patch.yml hardened.patch.yml /usr/local/share/dsh/

ENV DSH_VERSION=${DSH_VERSION}
ENV DSH_HOME=/home/node/.dsh
ENV RUSTUP_HOME=/usr/local/rustup
ENV CARGO_HOME=/usr/local/cargo
ENV PATH=/opt/dsh/bin:/usr/local/cargo/bin:$PATH

# `$DSH_HOME` is explicit, so `--user` overrides still resolve the harness home.
RUN mkdir -p /workspace "${DSH_HOME}" \
 && chown -R node:node /workspace "${DSH_HOME}"

USER node
WORKDIR /workspace

EXPOSE 3080

# tini reaps the children the agent's shell and PTYs leave behind.
ENTRYPOINT ["tini", "--", "dsh", "web", "--patch", "/usr/local/share/dsh/container.patch.yml"]
CMD ["--no-open"]
