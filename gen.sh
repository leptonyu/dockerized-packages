#!/bin/bash

DNS_US="8.8.8.8"
DNS_FAKE="198.18.0.0:5333"
# DNS, IPv4 223.5.5.5 和 223.6.6.6 添加到 AdGuard，添加到 AdGuard VPN
# DNS, IPv6 2400:3200::1 和 2400:3200:baba::1  添加到 AdGuard，添加到 AdGuard VPN
# DNS-over-HTTPS  https://dns.alidns.com/dns-query  添加到 AdGuard，添加到 AdGuard VPN
# DNS-over-TLS  tls://dns.alidns.com  添加到 AdGuard，添加到 AdGuard VPN
# DNS-over-QUIC quic://dns.alidns.com:853 添加到 AdGuard, 添加到 AdGuard VPN
DNS_CN="223.5.5.5"
DNS_INTERNAL="10.96.0.10"
OUT="${1:-adguard}"

gen_adguard(){
	cat <<-EOF
$DNS_US
[/cluster.local/]$DNS_INTERNAL
[/sdxpass.com/]$DNS_CN
EOF
	gen_fake "!cn" | sort -u | awk '-F[ \r]' -v dns="$DNS_FAKE" '/^[a-z0-9]/{print "[/"$1"/]"dns}'
	gen_fake "cn" | sort -u | awk '-F[ \r]' -v dns="$DNS_CN" '/^[a-z0-9]/{print "[/"$1"/]"dns}'
	awk '-F[/]' -v dns="$DNS_CN" '{print "[/"$2"/]"dns}' \
	  dnsmasq-china-list/accelerated-domains.china.conf \
	  dnsmasq-china-list/google.china.conf \
	  dnsmasq-china-list/apple.china.conf \
	  | grep -v linkedin | sort -u
}

gen_smartdns(){
	cat <<-EOF
bind [::]:5334
bind-tcp [::]:5334
cache-size 4096
force-qtype-SOA 65
log-level info

server $DNS_US

server $DNS_INTERNAL -group internal
server $DNS_CN -group cn
server $DNS_FAKE -group proxy

nameserver /cluster.local/internal
nameserver /sdxpass.com/cn

domain-set -name blocklist -file smartdns-block-domains.txt
address /domain-set:blocklist/#

EOF
	gen_fake "!cn" | sort -u | awk '-F[ \r]' '/^[a-z0-9]/{print "nameserver /"$1"/proxy"}'
	gen_fake "cn" | sort -u | awk '-F[ \r]' '/^[a-z0-9]/{print "nameserver /"$1"/cn"}'
	awk '-F[/]' '{print "nameserver /"$2"/cn"}' \
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
      grep -v '^\(regexp:\|include:\|#\|$\)' $FILE | grep ${1} '..*@cn' | sed s/^full://g | sed 's/\s\+@cn$//g'
    fi
  done
}

gen_fake(){
  local OPT="-v"
  if [ "$1" = "cn" ]; then
    OPT=""
  fi
  cat <<EOF | gen_fake_includes | gen_fake_expand "$OPT"
agilebits
anthropic
apple-intelligence
archive
discord
disney
github
google
hbo
hsbc
huggingface
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
pixiv
reddit
sentry
spotify
stripe
telegram
tesla
tiktok
tvb
twitch
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
cloudflare
EOF
	grep -v '^\(regexp:\|include:\|#\|$\)' domain.txt | grep $OPT '..*@cn'
}

gen_blocklist(){
	local urls=(
		"https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt"
		"https://anti-ad.net/easylist.txt"
		"https://adguardteam.github.io/HostlistsRegistry/assets/filter_29.txt"
		"https://adguardteam.github.io/HostlistsRegistry/assets/filter_44.txt"
	)
	local names=(
		"adguard-sdns-filter"
		"anti-ad-easylist"
		"filter_29"
		"filter_44"
	)
	for i in "${!urls[@]}"; do
		curl -sL "${urls[$i]}" | grep '^\|\|' | grep -v '^@@' | sed 's/^||//;s/\^.*$//' | grep -E '^[a-z0-9]' | grep -v '[/]' | grep -F '.' | sort -u > "/tmp/blocklist-${names[$i]}.txt"
	done
	cat /tmp/blocklist-*.txt | sort -u > smartdns-block-domains.txt
	rm -f /tmp/blocklist-*.txt
}

case "$OUT" in
  smartdns|smartdns.conf)
    gen_blocklist
    gen_smartdns > smartdns.conf
    tar -Jcf smartdns.tar.xz smartdns.conf smartdns-block-domains.txt
    sha256sum smartdns.conf > smartdns.conf.sha256sum
    ;;
  adguard|upstream.conf|'')
    gen_adguard > upstream.conf
    tar -Jcf upstream.tar.xz upstream.conf
    sha256sum upstream.conf > upstream.conf.sha256sum
    ;;
  all)
    gen_adguard > upstream.conf
    tar -Jcf upstream.tar.xz upstream.conf
    sha256sum upstream.conf > upstream.conf.sha256sum

    gen_blocklist
    gen_smartdns > smartdns.conf
    tar -Jcf smartdns.tar.xz smartdns.conf smartdns-block-domains.txt
    sha256sum smartdns.conf > smartdns.conf.sha256sum
    ;;
esac

gen_apple > apple.conf
tar -Jcf apple.tar.xz apple.conf
sha256sum apple.conf > apple.conf.sha256sum
