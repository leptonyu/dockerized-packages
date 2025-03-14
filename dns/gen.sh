#!/bin/bash

DNS_FAKE="198.18.0.0:5333 8.8.4.4 1.1.1.1"
DNS_US="tcp://8.8.8.8:53"
DNS_CN="tcp://223.5.5.5:53 tcp://223.6.6.6:53 119.29.29.29"

gen(){
cat <<-EOF
$DNS_US
[/cluster.local/]10.96.0.10
EOF
awk '-F[/]' -v dns="$DNS_FAKE" '{print "[/"$1"/]"dns}' domain.txt
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

