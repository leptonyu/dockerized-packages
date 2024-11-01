#!/bin/bash

DNS="tcp://8.8.8.8:53"
DNS_CN="119.29.29.29"
#DNS_CN="223.5.5.5"

gen(){
cat <<-EOF
$DNS
[/cluster.local/]10.96.0.10
[/gacjie.cn/]$DNS
EOF
awk '-F[/]' -v dns="$DNS_CN" '{print "[/"$2"/]"dns}' \
  dnsmasq-china-list/accelerated-domains.china.conf \
  dnsmasq-china-list/google.china.conf \
  dnsmasq-china-list/apple.china.conf \
  | grep -v linkedin 
}

gen > upstream.conf

DAT=${1:?date not set}

tar -zcf upstream-$DAT.tar.gz upstream.conf