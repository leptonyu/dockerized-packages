FROM alpine:3.10
RUN apk --no-cache add dnsmasq
VOLUME /etc/dnsmasq
EXPOSE 53 53/udp
ENTRYPOINT ["dnsmas", "-k"]
