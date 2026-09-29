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
OUT="${1:-all}"

# cn 域名统一走 DNS_CN，upstream / xndns 共用
gen_cn_rules(){
	gen_fake "cn" | sort -u | awk '-F[ \r]' -v dns="$DNS_CN" '/^[a-z0-9]/{print "[/"$1"/]"dns}'
	awk '-F[/]' -v dns="$DNS_CN" '{print "[/"$2"/]"dns}' \
	  dnsmasq-china-list/accelerated-domains.china.conf \
	  dnsmasq-china-list/google.china.conf \
	  dnsmasq-china-list/apple.china.conf \
	  | grep -v linkedin | sort -u
}

gen_upstream(){
	cat <<-EOF
$DNS_US
[/cluster.local/]$DNS_INTERNAL
[/sdxpass.com/]$DNS_CN
EOF
	gen_fake "!cn" | sort -u | awk '-F[ \r]' -v dns="$DNS_FAKE" '/^[a-z0-9]/{print "[/"$1"/]"dns}'
	gen_cn_rules
}

# 与 upstream 相同，区别：默认上游是 fake，且不再单独列出 !cn→FAKE 的域名组
gen_xndns(){
	cat <<-EOF
$DNS_FAKE
[/cluster.local/]$DNS_INTERNAL
[/sdxpass.com/]$DNS_CN
EOF
	gen_cn_rules
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
	# 原样保留 filter.txt 的格式（AdGuard 过滤规则）
	local urls=(
		"https://adguardteam.github.io/HostlistsRegistry/assets/filter_49.txt"
	)
	local names=(
		"filter_49"
	)
	for i in "${!urls[@]}"; do
		local name="${names[$i]}"
		curl -fsSL "${urls[$i]}" -o "${name}.txt" || { echo "failed to download ${urls[$i]}" >&2; exit 1; }
		[ -s "${name}.txt" ] || { echo "empty blocklist ${name}.txt" >&2; exit 1; }
		tar -Jcf "${name}.tar.xz" "${name}.txt"
		sha256sum "${name}.tar.xz" > "${name}.tar.xz.sha256sum"
	done
}

emit_upstream(){
	gen_upstream > upstream.conf
	tar -Jcf upstream.tar.xz upstream.conf
	sha256sum upstream.conf > upstream.conf.sha256sum
	sha256sum upstream.tar.xz > upstream.tar.xz.sha256sum
}

emit_xndns(){
	gen_xndns > xndns.conf
	tar -Jcf xndns.tar.xz xndns.conf
	sha256sum xndns.conf > xndns.conf.sha256sum
	sha256sum xndns.tar.xz > xndns.tar.xz.sha256sum
}

emit_apple(){
	gen_apple > apple.conf
	tar -Jcf apple.tar.xz apple.conf
	sha256sum apple.conf > apple.conf.sha256sum
}

emit_block(){
	gen_blocklist
}

case "$OUT" in
  all)
    emit_upstream
    emit_xndns
    emit_apple
    emit_block
    ;;
  upstream|upstream.conf|adguard)
    emit_upstream
    ;;
  xndns|xndns.conf)
    emit_xndns
    ;;
  apple|apple.conf)
    emit_apple
    ;;
  block|blocklist)
    emit_block
    ;;
  *)
    echo "usage: $0 [all|upstream|xndns|apple|block]" >&2
    exit 1
    ;;
esac
