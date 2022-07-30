FROM codecom/code-server:4.5.1

RUN apt update \
 && apt install -y --no-install-recommends git gcc make gcc-multilib \
 && rm -rf /var/lib/apt/lists/*
