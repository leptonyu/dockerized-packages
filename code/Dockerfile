FROM linuxserver/code-server:4.0.2

RUN apt update \
 && apt install -y --no-install-recommends git gcc \
 && rm -rf /var/lib/apt/lists/*
