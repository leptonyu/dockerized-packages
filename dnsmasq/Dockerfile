FROM alpine:3.12.1
RUN apk --no-cache add dnsmasq-dnssec
VOLUME /etc/dnsmasq
EXPOSE 53 53/udp
ENTRYPOINT ["dnsmasq", "-k"]
