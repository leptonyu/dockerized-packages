#!/bin/bash

DNS="tcp://8.8.8.8:53"
#DNS="tcp://209.244.0.3:53"
#DNS_CN="119.29.29.29"
DNS_CN="tcp://223.5.5.5:53 119.29.29.29"
DNS_FAKE="192.168.5.5"

gen(){
cat <<-EOF
$DNS
[/cluster.local/]10.96.0.10
[/gacjie.cn/]$DNS
[/github.com/]$DNS_FAKE
EOF
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
