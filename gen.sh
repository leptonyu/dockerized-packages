#!/bin/bash

# DNS, IPv4 223.5.5.5 和 223.6.6.6 添加到 AdGuard，添加到 AdGuard VPN
# DNS, IPv6 2400:3200::1 和 2400:3200:baba::1  添加到 AdGuard，添加到 AdGuard VPN
# DNS-over-HTTPS  https://dns.alidns.com/dns-query  添加到 AdGuard，添加到 AdGuard VPN
# DNS-over-TLS  tls://dns.alidns.com  添加到 AdGuard，添加到 AdGuard VPN
# DNS-over-QUIC quic://dns.alidns.com:853 添加到 AdGuard, 添加到 AdGuard VPN
# 官方编译好的 dlc.dat（作为基准，保留 dlc 全部列表/域名/类型/属性）
DLCDAT_URL="https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat"
# 固定走国内 DNS 的自有域名（不在 dnsmasq / v2fly 任何列表里）
CN_FORCED="sdxpass.com"
OUT="${1:-all}"

# 临时缓存目录：存放展开后的列表集合 / 国内域名全集。
# 用文件而不是变量，因为这两个函数会在管道和命令替换的子 shell 里被调用，变量缓存传不出来
CACHE_DIR="$(mktemp -d)"
trap 'rm -rf "${CACHE_DIR:?}"' EXIT

# 前置检查：缺任何一份上游数据都直接失败，避免静默生成残缺配置
[ -r domain.txt ] || { echo "gen.sh: 缺少 domain.txt" >&2; exit 1; }
[ -d domain-list-community/data ] || { echo "gen.sh: 缺少 domain-list-community/data" >&2; exit 1; }
for f in dnsmasq-china-list/accelerated-domains.china.conf \
         dnsmasq-china-list/google.china.conf \
         dnsmasq-china-list/apple.china.conf; do
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

# 全部国内域名：data 列表 / domain.txt 里 @cn 的 + dnsmasq 三份中国列表里的。
# 只给 dlc 的 CN 一路用（gen_dlc）。dnsmasq 三份必须算进来：accelerated-domains 里的
# 域名在 v2fly data 里没有 @cn 标签，漏了它们就补不进 CN。
gen_cn_domains(){
	local cache="$CACHE_DIR/cn-domains"
	if [ ! -s "$cache" ]; then
		{
			gen_fake
			# linkedin 系域名（accelerated-domains 里有，如 linkedin-event.com）强制走 fake，
			# 与 data/linkedin 的非 @cn 部分保持一致
			awk '-F[/]' 'NF { print $2 }' \
			  dnsmasq-china-list/accelerated-domains.china.conf \
			  dnsmasq-china-list/google.china.conf \
			  dnsmasq-china-list/apple.china.conf \
			  | grep -v linkedin
		} | sort -u > "$cache"
	fi
	cat "$cache"
}

gen_apple(){
  awk -F/ '{print $2}' dnsmasq-china-list/apple.china.conf
}

# 名单 -> 真正要读的列表集合：逐层展开 include 直到不再出现新列表
# include 目标先剥掉 @属性 和 # 注释
# $1 = keep-cn 时保留 *-cn 列表（gen_cn_only_lists 用：CN 侧的 -cn 列表本来就该读），
#      否则排除（gen_fake_lists 用：-cn 列表交给 gen_cn_only_lists 那一遍处理）
# （旧实现只展开一层，amp / cursor / bytedance-ai-!cn 这类深层列表会被整个漏掉）
gen_fake_includes(){
  local keep_cn="$1" queue name files seen targets
  seen=" "
  queue="$(cat | tr -s '[:space:]' '\n' | sed '/^$/d')"
  while :; do
    files=""
    for name in $queue; do
      case "$seen" in *" $name "*) continue ;; esac
      seen="$seen$name "
      if [ -e "domain-list-community/data/$name" ]; then
        echo "$name"
        files="$files domain-list-community/data/$name"
      else
        echo "gen.sh: 警告：列表 $name 不存在，已跳过" >&2
      fi
    done
    [ -n "$files" ] || break
    # 下一层：本轮所有新列表一次性抽出 include 目标
    targets="$(sed -n 's/^include:\([^[:space:]#]*\).*/\1/p' $files)"
    if [ "$keep_cn" = "keep-cn" ]; then
      queue="$targets"
    else
      queue="$(printf '%s\n' "$targets" | grep -v -- '-cn$')"
    fi
  done
}

# 展开列表：只取带 @cn 的条目，统一只留域名
# 先把列表名换成文件列表，一次 grep 处理完（逐个 spawn 会慢一个数量级）
gen_fake_expand(){
  local files name
  files=""
  while read -r name || [ -n "$name" ]; do
    [ -e "domain-list-community/data/$name" ] && files="$files domain-list-community/data/$name"
  done
  [ -n "$files" ] || return 0
  grep -h -v '^\(regexp:\|include:\|#\|$\)' $files \
    | grep '..*@cn' \
    | sed 's/^full://g' \
    | awk 'NF { print $1 }'
}

# 要展开的上游列表名单（v2fly/domain-list-community/data 下的名字）
gen_fake_base(){
  cat <<EOF
anthropic
apple
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
category-antivirus
category-cas
category-cdn-!cn
category-communication
category-companies
category-cryptocurrency
category-dev
category-ecommerce
category-forums
category-games-!cn
category-media
category-scholar-!cn
category-social-media-!cn
category-vpnservices
cloudflare
connectivity-check
EOF
}

# 名单 + 逐层 include 展开后的列表集合（结果缓存，避免同一次运行里重复展开）
gen_fake_lists(){
  local cache="$CACHE_DIR/fake-lists"
  [ -s "$cache" ] || gen_fake_base | gen_fake_includes > "$cache"
  cat "$cache"
}

# 只参与 CN 侧的列表：这些列表里"无标签"的条目本身就是中国域名
# （12306.cn、10086.cn、alibaba.com 之类），但这里只取它们带 @cn 的条目。
# 父列表（gen_fake_base）与它们分开，靠 gen_fake_includes 的 keep-cn 区分
gen_cn_only_base(){
  cat <<EOF
category-cdn-cn
category-ip-geo-detect
geolocation-cn
EOF
}

gen_cn_only_lists(){
  local cache="$CACHE_DIR/cn-only-lists"
  # CN 侧保留 *-cn 列表：cloudflare-cn / aws-cn / category-ntp-cn 就在这一层
  [ -s "$cache" ] || gen_cn_only_base | gen_fake_includes keep-cn > "$cache"
  cat "$cache"
}

# domain.txt -> 纯域名：$1 为空取带 @cn 的条目，$1=-v 取不带 @cn 的条目
gen_domain_txt(){
  grep -v '^\(regexp:\|include:\|#\|$\)' domain.txt | grep $1 '..*@cn' | sed 's/^full://g' | awk 'NF { print $1 }'
}

# CN 域名：父列表里带 @cn 的条目 + CN-only 列表 + domain.txt 里带 @cn 的条目
gen_fake(){
  {
    gen_fake_lists | gen_fake_expand
    gen_cn_only_lists | gen_fake_expand
    gen_domain_txt ""
  }
}

# 只给 dlc 补的 fake 域名：domain.txt 里手工维护的非 @cn 条目（约 80 条）。
# !cn 全集（约 11 万条）不再进 dlc：未标注条目的 fake 语义由消费方的默认处理承担，
# 再全量打一遍 @fake 属性只是把同一份信息写两遍。这份人工例外才是 dlc 需要额外带的。
gen_fake_manual(){
  gen_domain_txt "-v"
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
			grep -rh '@ads' domain-list-community/data/ \
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
# fake 这一路只喂 gen_fake_manual（domain.txt 里手工维护的几条），不展开 !cn 全集。
# 实际的编解码与自检在 dlc_dat.py 里（含官方 dat 的字节级往返校验）。
gen_dlc(){
	local base="dlc-official.dat" sets="$CACHE_DIR"
	[ -s "$base" ] || curl -fsSL "$DLCDAT_URL" -o "$base" \
	  || { echo "gen.sh: 下载 $DLCDAT_URL 失败" >&2; exit 1; }
	[ -s "$base" ] || { echo "gen.sh: $base 为空" >&2; exit 1; }

	gen_blocked_domains > "$sets/ads.txt"
	{ gen_cn_domains; for d in $CN_FORCED; do echo "$d"; done; } | LC_ALL=C sort -u > "$sets/cn.txt"
	gen_fake_manual | LC_ALL=C sort -u > "$sets/fake.txt"

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
