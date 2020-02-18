FROM alpine:3.10
RUN apk --no-cache add dnsmasq-dnssec
VOLUME /etc/dnsmasq
EXPOSE 53 53/udp
ENTRYPOINT ["dnsmasq", "-k"]
