FROM alpine:3.16

ARG TZ='Asia/Shanghai'

ENV TZ ${TZ}

RUN apk add privoxy \
 && ln -sf /usr/share/zoneinfo/${TZ} /etc/localtime \
 && echo "${TZ}" > /etc/timezone

COPY config /etc/privoxy/config

ENTRYPOINT ["privoxy", "--no-daemon", "/etc/privoxy/config"]