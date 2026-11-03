#!/bin/bash

# DNS / AdGuard 产物的生成入口（原仓库根目录的 gen.sh）。
# 输入：仓库根目录的 dnsmasq-china-list/、domain-list-community/（CI 在 checkout 后 clone），
#       以及本目录的 domain.txt / dlc_dat.py。
# 产物：写到本目录（apple.conf / apple.tar.xz、filter_49.txt / filter_49.tar.xz、
#       dlc.dat / dlc.dat.xz 及各自 .sha256sum），由 adguard.yml 的 dns job 发布。

# DNS, IPv4 223.5.5.5 和 223.6.6.6 添加到 AdGuard，添加到 AdGuard VPN
# DNS, IPv6 2400:3200::1 和 2400:3200:baba::1  添加到 AdGuard，添加到 AdGuard VPN
# DNS-over-HTTPS  https://dns.alidns.com/dns-query  添加到 AdGuard，添加到 AdGuard VPN
# DNS-over-TLS  tls://dns.alidns.com  添加到 AdGuard，添加到 AdGuard VPN
# DNS-over-QUIC quic://dns.alidns.com:853 添加到 AdGuard, 添加到 AdGuard VPN
# 官方编译好的 dlc.dat（作为基准，保留 dlc 全部列表/域名/类型/属性）
DLCDAT_URL="https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat"
# 固定走国内 DNS 的域名：自有域名 sdxpass.com，以及上游没标 @cn 的 googleapis.cn。
# domain.txt 只放 fake 域名，不再混 @cn 条目。
CN_FORCED="sdxpass.com googleapis.cn"
OUT="${1:-all}"

# 脚本在本目录生成产物；上游两个 checkout 在仓库根目录（CI 在仓库根 clone）。
# 这样从任意工作目录调用都可以，root 也不再需要放着这个脚本。
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$(cd "$HERE/../.." && pwd)"
cd "$HERE"

# 临时缓存目录：国内域名全集 / 拦截域名全集。
# 用文件而不是变量，因为这些函数会在管道和命令替换的子 shell 里被调用，变量缓存传不出来
CACHE_DIR="$(mktemp -d)"
trap 'rm -rf "${CACHE_DIR:?}"' EXIT

# 前置检查：缺任何一份上游数据都直接失败，避免静默生成残缺配置
[ -r domain.txt ] || { echo "gen.sh: 缺少 $HERE/domain.txt" >&2; exit 1; }
[ -d "$SRC/domain-list-community/data" ] || { echo "gen.sh: 缺少 $SRC/domain-list-community/data" >&2; exit 1; }
for f in "$SRC/dnsmasq-china-list/accelerated-domains.china.conf" \
         "$SRC/dnsmasq-china-list/google.china.conf" \
         "$SRC/dnsmasq-china-list/apple.china.conf"; do
	[ -r "$f" ] || { echo "gen.sh: 缺少 $f" >&2; exit 1; }
done

# 产物自检：行数低于下限说明列表没读到，宁可失败也不发一份残缺配置
check_output(){
	local file="$1" min="$2" n
	n="$(wc -l < "$file" | tr -d ' ')"
	n="${n:-0}"
	if [ "$n" -lt "$min" ]; then
		echo "gen.sh: ${file} 只生成了 ${n} 行（下限 ${min}），疑似上游列表缺失" >&2
		# 变量一律写成 ${x}：macOS 自带 bash 3.2 下 "$x）" 这种紧跟中文标点的写法
		# 会丢掉展开值并吃掉该标点的首字节
		exit 1
	fi
}

# 全部国内域名：dnsmasq 三份中国列表（+ CN_FORCED 在 gen_dlc 里补）。
# v2fly 的 @cn 标签官方 dlc 自带，生成侧不再逐层展开列表补 CN；消费端（machine）
# 自己按 DLC 列表名映射 fake_tags。
gen_cn_domains(){
	local cache="$CACHE_DIR/cn-domains"
	if [ ! -s "$cache" ]; then
		{
			# linkedin 系域名（accelerated-domains 里有，如 linkedin-event.com）强制走 fake，
			# 与 data/linkedin 的非 @cn 部分保持一致
			awk '-F[/]' 'NF { print $2 }' \
			  "$SRC/dnsmasq-china-list/accelerated-domains.china.conf" \
			  "$SRC/dnsmasq-china-list/google.china.conf" \
			  "$SRC/dnsmasq-china-list/apple.china.conf" \
			  | grep -v linkedin
		} | sort -u > "$cache"
	fi
	cat "$cache"
}

gen_apple(){
  awk -F/ '{print $2}' "$SRC/dnsmasq-china-list/apple.china.conf"
}

# fake 域名：只有 domain.txt 里手工维护的少量境外域名（一行一个，# 注释）。
# 未标注条目的 fake 语义由消费方的默认处理承担，不再展开 !cn 全集。
gen_fake(){
  awk '!/^[[:space:]]*#/ && NF { print $1 }' domain.txt
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

# 需要拦截的域名：filter_49.txt 里的 ||domain^ + data 列表里标了 @ads 的条目
gen_blocked_domains(){
	local cache="$CACHE_DIR/blocked"
	if [ ! -s "$cache" ]; then
		{
			# AdGuard 规则 -> 纯域名。filter_49 全是 ||domain^ 形式，且末行没有换行符，
			# 所以用 awk 而不是 sed —— sed 会把末行跟下一段输出粘连成一个假域名
			awk '/^\|\|/ { d = $0; sub(/^\|\|/, "", d); sub(/\^?[ \t]*$/, "", d); if (d != "") print d }' \
			  filter_49.txt
			# v2fly 自带 @ads 标签的条目：去掉行内注释后要求 @ads 出现在标签位，
			# 并跳过 regexp: / include: / keyword: 这类不是域名的行
			grep -rh '@ads' "$SRC/domain-list-community/data/" \
				| awk '{ sub(/#.*/, "") }
				       /@ads/ {
				         sub(/^full:/, "")
				         n = split($0, a, /[ \t]+/)
				         if (a[1] == "" || a[1] ~ /[:|^\/]/) next
				         for (i = 2; i <= n; i++) if (a[i] ~ /@ads([,]|$)/) { print a[1]; break }
				       }'
		} | sort -u > "$cache"
	fi
	cat "$cache"
}

# dlc 清单：以官方 dlc.dat 为基准，保留 dlc 的全部列表 / 域名 / 类型 / 属性，
# 只追加 @ads / @cn / @fake 三种属性（优先级 ads > cn > fake）。
# dlc 里没有的域名：ads -> ADS 列表、cn -> 追加进已有 CN 列表、fake -> FAKE 列表，
# 统一用 Domain 型（后缀匹配）。
# fake 这一路只喂 gen_fake（domain.txt 里手工维护的少量域名），不展开 !cn 全集。
# 实际的编解码与自检在 dlc_dat.py 里（含官方 dat 的字节级往返校验）。
gen_dlc(){
	local base="dlc-official.dat" sets="$CACHE_DIR"
	[ -s "$base" ] || curl -fsSL "$DLCDAT_URL" -o "$base" \
	  || { echo "gen.sh: 下载 $DLCDAT_URL 失败" >&2; exit 1; }
	[ -s "$base" ] || { echo "gen.sh: $base 为空" >&2; exit 1; }

	gen_blocked_domains > "$sets/ads.txt"
	{ gen_cn_domains; for d in $CN_FORCED; do echo "$d"; done; } | LC_ALL=C sort -u > "$sets/cn.txt"
	gen_fake | LC_ALL=C sort -u > "$sets/fake.txt"

	python3 dlc_dat.py --base "$base" \
	  --ads "$sets/ads.txt" --cn "$sets/cn.txt" --fake "$sets/fake.txt" \
	  --out dlc.dat || { echo "gen.sh: dlc_dat.py 失败，dlc.dat 不可用" >&2; exit 1; }
}

emit_apple(){
	gen_apple > apple.conf
	check_output apple.conf 50
	tar -Jcf apple.tar.xz apple.conf
	sha256sum apple.conf > apple.conf.sha256sum
}

emit_block(){
	gen_blocklist
}

emit_dlc(){
	# @ads 依赖 filter_49.txt；单独跑 dlc 目标时若不存在就先下载
	[ -s filter_49.txt ] || gen_blocklist
	gen_dlc
	size="$(wc -c < dlc.dat | tr -d ' ')"
	[ "$size" -gt 5000000 ] || { echo "gen.sh: dlc.dat 只有 ${size} 字节，疑似生成失败" >&2; exit 1; }
	# 只发裸 xz（解压即 protobuf）：单成员 tar 的 dlc.tar.xz 已下线
	xz -c dlc.dat > dlc.dat.xz
	sha256sum dlc.dat > dlc.dat.sha256sum
	sha256sum dlc.dat.xz > dlc.dat.xz.sha256sum
}

case "$OUT" in
  all)
    emit_apple
    emit_block
    emit_dlc
    ;;
  apple|apple.conf)
    emit_apple
    ;;
  block|blocklist)
    emit_block
    ;;
  dlc|dlc.dat)
    emit_dlc
    ;;
  *)
    echo "usage: $0 [all|apple|block|dlc]" >&2
    exit 1
    ;;
esac
