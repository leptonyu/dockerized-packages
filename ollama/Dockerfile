FROM ollama/ollama:0.3.13

RUN apt update \
 && apt install -y curl ca-certificates gpg-agent software-properties-common \
 && curl -s https://apt.repos.intel.com/intel-gpg-keys/GPG-PUB-KEY-INTEL-SW-PRODUCTS.PUB | gpg --dearmor > /usr/share/keyrings/oneapi-archive-keyring.gpg \
 && echo "deb [signed-by=/usr/share/keyrings/oneapi-archive-keyring.gpg] https://apt.repos.intel.com/oneapi all main" > /etc/apt/sources.list.d/oneAPI.list \
 && curl -fsSL https://repositories.intel.com/gpu/intel-graphics.key | gpg --dearmor | tee /usr/share/keyrings/intel-graphics-archive-keyring.gpg \
 && echo "deb [signed-by=/usr/share/keyrings/intel-graphics-archive-keyring.gpg arch=amd64] https://repositories.intel.com/gpu/ubuntu jammy/lts/2350 unified" > /etc/apt/sources.list.d/intel-graphics.list \
 && apt update \
 && apt install -y intel-basekit intel-opencl-icd intel-level-zero-gpu level-zero level-zero-dev \
 && rm -rf /var/lib/apt/lists/*

