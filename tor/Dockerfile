FROM alpine:3.20

ARG TZ='Asia/Shanghai'

ENV TZ ${TZ}

RUN apk add --no-cache tor privoxy bash tzdata su-exec \
 && ln -sf /dev/stdout /var/log/tor/notices.log \
 && ln -sf /usr/share/zoneinfo/${TZ} /etc/localtime \
 && echo "${TZ}" > /etc/timezone

COPY torrc /etc/tor/torrc

ENTRYPOINT [ "su-exec", "tor", "tor" ]
