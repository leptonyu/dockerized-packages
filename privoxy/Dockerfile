FROM alpine:3.12

ARG TZ='Asia/Shanghai'

ENV TZ ${TZ}

RUN apk add privoxy \
 && ln -sf /usr/share/zoneinfo/${TZ} /etc/localtime \
 && echo "${TZ}" > /etc/timezone

ENTRYPOINT ["privoxy"]