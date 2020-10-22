FROM ubuntu:20.04

RUN apt update \
 && apt install -y build-essential git make libelf-dev clang strace tar bpfcc-tools gcc-multilib \
 && wget --no-check-certificate -c https://cdn.kernel.org/pub/linux/kernel/v5.x/linux-5.0.9.tar.gz -O - | tar -xz \
 && mv /linux-5.0.9 /kernel-src \
 && cd /kernel-src/tools/lib/bpf \
 && make && make install prefix=/ \
 && cp /lib64/libbpf.* /lib/x86_64-linux-gnu/ \
 && rm -rf /kernel-src \
 && apt autoremove \
 && mount -t debugfs none /sys/kernel/debug \
 && cd / \
 && git clone https://github.com/bpftools/linux-observability-with-bpf.git \
 && mv /linux-observability-with-bpf /code

WORKDIR /code