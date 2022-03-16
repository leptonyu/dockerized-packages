FROM linuxserver/code-server:4.1.0

RUN apt update \
 && apt install -y --no-install-recommends git gcc make gcc-multilib \
 && rm -rf /var/lib/apt/lists/*
