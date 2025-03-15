FROM ghcr.io/coder/code-server:4.98.2

USER root

RUN apt update \
 && apt install -y --no-install-recommends \
  gcc \
  cmake \
  make \
  clang \
  pkg-config \
  build-essential \
  net-tools \
  musl-tools \
  protobuf-compiler \
  curl \
  netcat-openbsd \
  libffi-dev \
  libgmp-dev \
  libgmp10 \
  libncurses-dev \
  libncurses5 \
  libtinfo5 \
  jq
