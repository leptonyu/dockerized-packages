#!/bin/bash

DNS_FAKE="198.18.0.0:5333"
DNS_US="tls://dns.google:853"
# DNS, IPv4 223.5.5.5 和 223.6.6.6 添加到 AdGuard，添加到 AdGuard VPN
# DNS, IPv6 2400:3200::1 和 2400:3200:baba::1  添加到 AdGuard，添加到 AdGuard VPN
# DNS-over-HTTPS  https://dns.alidns.com/dns-query  添加到 AdGuard，添加到 AdGuard VPN
# DNS-over-TLS  tls://dns.alidns.com  添加到 AdGuard，添加到 AdGuard VPN
# DNS-over-QUIC quic://dns.alidns.com:853 添加到 AdGuard, 添加到 AdGuard VPN
DNS_CN="quic://dns.alidns.com:853 2400:3200:baba::1 119.29.29.29"

gen(){
cat <<-EOF
$DNS_US
[/cluster.local/]10.96.0.10
[/ls.apple.com/]$DNS_CN
EOF
awk -v dns="$DNS_FAKE" '/^[a-z]/{print "[/"$1"/]"dns}' domain.txt | sort -u
awk '-F[/]' -v dns="$DNS_CN" '{print "[/"$2"/]"dns}' \
  dnsmasq-china-list/accelerated-domains.china.conf \
  dnsmasq-china-list/google.china.conf \
  dnsmasq-china-list/apple.china.conf \
  | grep -v linkedin 
}

gen_apple(){
  awk -F/ '{print $2}' dnsmasq-china-list/apple.china.conf
}

gen > upstream.conf
tar -Jcf upstream.tar.xz upstream.conf 
sha256sum upstream.conf > upstream.conf.sha256sum

gen_apple > apple.conf
tar -Jcf apple.tar.xz apple.conf
sha256sum apple.conf > apple.conf.sha256sum
