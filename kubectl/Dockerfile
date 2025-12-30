FROM alpine:3.23

ARG TZ='Asia/Shanghai'
ARG TARGETPLATFORM
ARG TARGETARCH
ARG TARGETVARIANT

ENV TZ=${TZ}

RUN apk add --no-cache bash tzdata curl jq \
 && ln -sf /usr/share/zoneinfo/${TZ} /etc/localtime \
 && echo "${TZ}" > /etc/timezone \
 && curl -L -o /usr/local/bin/kubectl "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/$TARGETARCH/kubectl" \
 && chmod +x /usr/local/bin/kubectl

