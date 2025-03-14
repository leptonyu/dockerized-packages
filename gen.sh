#!/bin/bash

DNS_FAKE="192.168.5.5:5333"
DNS_US="8.8.8.8 8.8.4.4"
DNS_CN="tcp://223.5.5.5:53 119.29.29.29"

gen(){
cat <<-EOF
$DNS_FAKE
[/cluster.local/]10.96.0.10
[/arpa/]$DNS_US
EOF
# awk '-F[/]' -v dns="$DNS_FAKE" '{print "[/"$1"/]"dns}' domain.txt
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
