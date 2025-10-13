#!/bin/bash

DNS_US="dns.google"
DNS_FAKE="198.18.0.0:5333"
# DNS, IPv4 223.5.5.5 和 223.6.6.6 添加到 AdGuard，添加到 AdGuard VPN
# DNS, IPv6 2400:3200::1 和 2400:3200:baba::1  添加到 AdGuard，添加到 AdGuard VPN
# DNS-over-HTTPS  https://dns.alidns.com/dns-query  添加到 AdGuard，添加到 AdGuard VPN
# DNS-over-TLS  tls://dns.alidns.com  添加到 AdGuard，添加到 AdGuard VPN
# DNS-over-QUIC quic://dns.alidns.com:853 添加到 AdGuard, 添加到 AdGuard VPN
DNS_CN="quic://dns.alidns.com:853"

gen(){
cat <<-EOF
$DNS_US
[/cluster.local/]10.96.0.10
[/sdxpass.com/]$DNS_CN
EOF
gen_fake | sort -u | awk '-F[ \r]' -v dns="$DNS_FAKE" '/^[a-z]/{print "[/"$1"/]"dns}'
awk '-F[/]' -v dns="$DNS_CN" '{print "[/"$2"/]"dns}' \
  dnsmasq-china-list/accelerated-domains.china.conf \
  dnsmasq-china-list/google.china.conf \
  dnsmasq-china-list/apple.china.conf \
  | grep -v linkedin | sort -u
}

gen_apple(){
  awk -F/ '{print $2}' dnsmasq-china-list/apple.china.conf
}

gen_fake_includes(){
  while read line; do
    FILE=domain-list-community/data/$line
    if [ -e "$FILE" ]; then
      echo $line
      awk -F: '/^include:/{if ($2 !~ /-cn$/) print $2}' $FILE
    fi
  done | sort -u
}

gen_fake_expand(){
  while read line; do
    FILE=domain-list-community/data/$line
    if [ -e "$FILE" ]; then
      grep -v '^\(regexp:\|include:\|..*@cn\|#\|$\)' $FILE | sed s/^full://g
    fi
  done
}

gen_fake(){
  cat <<EOF | gen_fake_includes | gen_fake_expand
apple-intelligence
discord
disney
github
google
hbo
hsbc
jetbrains
jetbrains-ai
linkedin
linux
medium
netflix
nintendo
openai
oreilly
paypal
pccw
reddit
spotify
stripe
telegram
tvb
twitter
wikimedia
wise
x
youtube
category-ai-chat-!cn
category-anticensorship
category-communication
category-cryptocurrency
category-dev
category-forums
category-scholar-!cn
category-social-media-!cn
category-vpnservices
EOF
grep -v '^\(regexp:\|include:\|..*@cn\|#\|$\)' domain.txt
}

gen > upstream.conf
tar -Jcf upstream.tar.xz upstream.conf 
sha256sum upstream.conf > upstream.conf.sha256sum

gen_apple > apple.conf
tar -Jcf apple.tar.xz apple.conf
sha256sum apple.conf > apple.conf.sha256sum
