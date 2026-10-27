#!/bin/bash
#
# 生成 xn 侧的主要 CIDR 名单（从 machine/modules/network 迁移）：
#
#   xn_block.txt       eBPF 用：shrink(xn_block_all) 再精确去掉 non_public
#   xn_block_orig.txt  原来的 xn_block：block_raw 去掉 non_public（不含 scanner）
#   xn_block_all.txt   原始版本：block_raw + OpenFilters/internet-scanners 的 active cidr/
#   xn_cn.txt          cn ∩ us（原来的 xn_cn）
#   xn_fake.txt        fake/DNS 网段（原来的 xn_fake）
#   xn_us.txt          us_public + fake（原来的 xn_us，eBPF split 表）
#   xn_vpn.txt         xn_us + 192.160.0.0/11 + 10.78.0.0/15（原来的 xn_vpn）
#   xn_allow.txt       inbound_jail 白名单 = Cloudflare + CloudFront origin-facing（新增）
#
# 数据源、ASN、内联网段都在 cidr.yaml 里；scanner 列表由本脚本下载 tarball、
# 解压并把 active cidr/*.txt 拼到 .cache/scanners/all.txt，pipeline 的
# source: file (name: scanners) 读入后完成 block_all 合并和 block shrink。
#
# 用法：
#   ./gen.sh                # 生成八份
#   ./gen.sh block          # xn_block.txt + xn_block_orig.txt + xn_block_all.txt
#   ./gen.sh block_all      # 同上（block_all 依赖内部 xn_block_raw）
#   ./gen.sh cn|fake|us|vpn|allow
#   ./gen.sh check          # 生成到临时目录并与工作区逐字节对比
#   CIDR=/path/to/cidr ./gen.sh all
#   IPINFO_TOKEN=xxx ./gen.sh all   # 首次/缓存过期时需要
#   SCANNERS_TARBALL=/path/to/internet-scanners.tar.gz ./gen.sh block  # 离线
#
# cidr 是 rust/xn 的 xn-cidr-bin 二进制；CI 用 Git LFS 里的 network/bin/cidr
# （Linux x86_64），本地用 PATH 里的 cidr 或 CIDR=... 指定。

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

CIDR="${CIDR:-cidr}"
PIPELINE="${PIPELINE:-$ROOT/cidr.yaml}"
SCANNERS_URL="${SCANNERS_URL:-https://codeload.github.com/OpenFilters/internet-scanners/tar.gz/refs/heads/main}"
TARGET="${1:-all}"

# 下限只用来发现「源没拉到 / 生成空了」这类事故，不追求贴近当前条数
XN_BLOCK_MIN=1000
XN_BLOCK_ORIG_MIN=1000
XN_BLOCK_ALL_MIN=1000
XN_BLOCK_MAX=16384
XN_CN_MIN=1000
XN_FAKE_MIN=2
XN_US_MIN=1000
XN_VPN_MIN=1000
XN_ALLOW_MIN=50

WORK=""
cleanup() {
	if [ -n "${WORK:-}" ]; then
		rm -rf "$WORK"
	fi
}
trap cleanup EXIT

new_work() {
	if [ -z "${WORK:-}" ]; then
		WORK="$(mktemp -d)"
	fi
}

die() {
	echo "gen.sh: $*" >&2
	exit 1
}

usage() {
	cat <<'EOF'
usage: ./gen.sh [all|block|block_all|cn|fake|us|vpn|allow|check]

  all        生成 xn_block / xn_block_orig / xn_block_all / xn_cn / xn_fake / xn_us / xn_vpn / xn_allow（默认）
  block      xn_block.txt + xn_block_orig.txt + xn_block_all.txt
  block_all  同 block（block_all 依赖内部 xn_block_raw）
  cn         xn_cn.txt
  fake       xn_fake.txt
  us         xn_us.txt
  vpn        xn_vpn.txt
  allow      xn_allow.txt
  check      生成到临时目录，与当前文件逐字节 + checksum diff（不改工作区）

环境变量：
  CIDR              cidr CLI 的路径或命令名（默认 cidr）
  PIPELINE          pipeline yaml（默认本目录 cidr.yaml）
  IPINFO_TOKEN      ipinfo 的 token；country_asn 缓存不存在/过期时需要
  XDG_CACHE_HOME    cidr 缓存根目录（默认 ~/.cache；不可写时退回 ./.cache）
  SCANNERS_URL      internet-scanners 的 tarball URL（默认 codeload 的 main）
  SCANNERS_TARBALL  本地 tarball；设置后不再下载（离线/固定快照用）
EOF
}

resolve_cidr() {
	local found
	found="$(command -v "$CIDR" 2>/dev/null || true)"
	[ -n "$found" ] || die "找不到 cidr（xn-cidr-bin 的 CLI）。把它放进 PATH，或用 CIDR=/path/to/cidr 指定。"
	# 用绝对路径：check 模式会在临时目录里执行，相对的 ./cidr 会解析不到
	case "$found" in
		*/*) CIDR="$(cd "$(dirname "$found")" && pwd)/$(basename "$found")" ;;
		*) CIDR="$found" ;;
	esac
}

resolve_pipeline() {
	case "$PIPELINE" in
		/*) ;;
		*) PIPELINE="$ROOT/$PIPELINE" ;;
	esac
	[ -r "$PIPELINE" ] || die "读不到 pipeline：$PIPELINE"
}

setup_cache() {
	local want fallback="$ROOT/.cache"

	# 显式给了 XDG_CACHE_HOME 就优先用它；不可写再退回工作区
	if [ -n "${XDG_CACHE_HOME:-}" ]; then
		want="$XDG_CACHE_HOME"
	else
		want="${HOME:-}/.cache"
	fi

	if [ -n "${want:-}" ] && mkdir -p "$want/cidr" 2>/dev/null && [ -w "$want/cidr" ]; then
		XDG_CACHE_HOME="$want"
	else
		XDG_CACHE_HOME="$fallback"
		mkdir -p "$XDG_CACHE_HOME/cidr" || die "缓存目录不可写：$XDG_CACHE_HOME"
	fi
	export XDG_CACHE_HOME

	if [ -z "${IPINFO_TOKEN:-}" ]; then
		echo "gen.sh: 未设置 IPINFO_TOKEN；若 country_asn 缓存不存在或已超过 12h，cidr 会失败" >&2
	fi
}

run_cidr() {
	local dir="$1" outputs="$2"
	(
		cd "$dir"
		"$CIDR" --pipeline="$PIPELINE" --pipeline-output="$outputs" --verbose
	)
}

min_for() {
	case "$1" in
		xn_block.txt) echo "$XN_BLOCK_MIN" ;;
		xn_block_orig.txt) echo "$XN_BLOCK_ORIG_MIN" ;;
		xn_block_all.txt) echo "$XN_BLOCK_ALL_MIN" ;;
		xn_cn.txt) echo "$XN_CN_MIN" ;;
		xn_fake.txt) echo "$XN_FAKE_MIN" ;;
		xn_us.txt) echo "$XN_US_MIN" ;;
		xn_vpn.txt) echo "$XN_VPN_MIN" ;;
		xn_allow.txt) echo "$XN_ALLOW_MIN" ;;
		*) echo 1 ;;
	esac
}

check_file() {
	local file="$1" min n bad

	[ -f "$file" ] || die "缺少 $file"
	[ -s "$file" ] || die "$file 为空"
	min="$(min_for "$(basename "$file")")"
	n="$(wc -l <"$file" | tr -d ' ')"
	[ "$n" -ge "$min" ] || die "$file 只有 ${n} 行（下限 ${min}），疑似源没拉到"

	# 只允许 CIDR 字面量：没有注释、空行、端口扩展；端口扩展会改变 xn 的解析语义
	bad="$(grep -nEv '^[0-9A-Fa-f:.]+/[0-9]{1,3}$' "$file" | head -1 || true)"
	[ -z "$bad" ] || die "$file 有不符合 CIDR 的行：$bad"

	bad="$(sort "$file" | uniq -d | head -1 || true)"
	[ -z "$bad" ] || die "$file 有重复行：$bad"

	case "$(basename "$file")" in
		xn_fake.txt)
			[ "$n" -eq 2 ] || die "xn_fake.txt 应该只有 2 条，实际 ${n} 条"
			grep -qx '198.18.0.0/15' "$file" || die "xn_fake.txt 缺少 198.18.0.0/15"
			grep -qx 'fc00::/18' "$file" || die "xn_fake.txt 缺少 fc00::/18"
			;;
		xn_us.txt | xn_vpn.txt)
			# fake DNS 段必须在：home 的 split 依赖它覆盖 198.18.0.0/15
			grep -qx '198.18.0.0/15' "$file" || die "$(basename "$file") 缺少 fake 段 198.18.0.0/15"
			grep -qx 'fc00::/18' "$file" || die "$(basename "$file") 缺少 fake 段 fc00::/18"
			;;
		xn_allow.txt | xn_cn.txt | xn_block.txt | xn_block_orig.txt | xn_block_all.txt)
			grep -q '\.' "$file" || die "$(basename "$file") 没有 IPv4 条目"
			grep -q ':' "$file" || die "$(basename "$file") 没有 IPv6 条目"
			;;
	esac

	if [ "$(basename "$file")" = "xn_block.txt" ] && [ "$n" -gt "$XN_BLOCK_MAX" ]; then
		die "xn_block 有 ${n} 条，超过 eBPF 的 ${XN_BLOCK_MAX} 上限"
	fi
}

hash_file() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1"
	else
		shasum -a 256 "$1"
	fi
}

write_checksums() {
	local f
	for f in "$@"; do
		hash_file "$f" >"$f.sha256sum"
	done
}

# 下载/解压 scanner tarball，把 active cidr/*.txt 拼到 <target>/.cache/scanners/all.txt。
# cidr.yaml 的 source: scanners (ty: file) 从这里取数；文件源每次重读、不进缓存。
prepare_scanners() {
	local target="$1" archive scanner_dir files dest

	command -v tar >/dev/null 2>&1 || die "找不到 tar"
	new_work
	rm -rf "$WORK/scan"
	mkdir -p "$WORK/scan"
	archive="$WORK/scan/internet-scanners.tar.gz"

	if [ -n "${SCANNERS_TARBALL:-}" ]; then
		[ -r "$SCANNERS_TARBALL" ] || die "读不到 SCANNERS_TARBALL：$SCANNERS_TARBALL"
		cp "$SCANNERS_TARBALL" "$archive"
	else
		command -v curl >/dev/null 2>&1 || die "找不到 curl"
		echo "gen.sh: 下载 ${SCANNERS_URL} ..." >&2
		curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 120 \
			"$SCANNERS_URL" -o "$archive" || die "下载 scanner cidr 失败：$SCANNERS_URL"
	fi
	tar -xzf "$archive" -C "$WORK/scan" || die "解压 scanner tarball 失败"

	scanner_dir="$(find "$WORK/scan" -type d -name cidr ! -path '*/inactive/*' -print -quit)"
	[ -n "$scanner_dir" ] || die "tarball 里找不到 cidr/ 目录"
	files="$(find "$scanner_dir" -maxdepth 1 -type f -name '*.txt' | wc -l | tr -d ' ')"
	[ "$files" -ge 50 ] || die "scanner cidr 只找到 ${files} 个文件，疑似上游结构变了"

  curl -L -o $scanner_dir/ci-badguys.txt https://cinsscore.com/list/ci-badguys.txt 

	dest="$target/.cache/scanners/all.txt"
	mkdir -p "$(dirname "$dest")"
	find "$scanner_dir" -maxdepth 1 -type f -name '*.txt' -exec cat {} + >"$dest" \
		|| die "拼接 scanner cidr 失败"
	[ -s "$dest" ] || die "scanner 清单为空"
	echo "gen.sh: scanners = ${files} 个 active cidr 文件 → $dest" >&2
}

do_check() {
	local out rc=0 f
	new_work
	out="$WORK/out"
	mkdir -p "$out"

	echo "gen.sh: 在 $out 重新生成并对比" >&2
	prepare_scanners "$out"
	run_cidr "$out" "block_all,block_orig,block,cn_us,fake,xn_us,xn_vpn,allow"

	for f in xn_block.txt xn_block_orig.txt xn_block_all.txt xn_cn.txt xn_fake.txt xn_us.txt xn_vpn.txt xn_allow.txt; do
		check_file "$out/$f"
		if [ ! -f "$ROOT/$f" ]; then
			echo "gen.sh: 工作区缺少 $f" >&2
			rc=1
		elif ! diff -u "$ROOT/$f" "$out/$f"; then
			rc=1
		fi
		if [ ! -f "$ROOT/$f.sha256sum" ]; then
			echo "gen.sh: 工作区缺少 $f.sha256sum" >&2
			rc=1
		elif ! (cd "$out" && hash_file "$f") | diff -u "$ROOT/$f.sha256sum" -; then
			rc=1
		fi
	done

	if [ "$rc" -eq 0 ]; then
		echo "gen.sh: 八份名单与 pipeline / scanner 源一致"
	else
		echo "gen.sh: 名单与源不一致；跑 ./gen.sh all 重新生成并提交" >&2
	fi
	exit "$rc"
}

case "$TARGET" in
	-h | --help | help)
		usage
		exit 0
		;;
	all)
		OUTPUTS="block_all,block_orig,block,cn_us,fake,xn_us,xn_vpn,allow"
		FILES=(xn_block.txt xn_block_orig.txt xn_block_all.txt xn_cn.txt xn_fake.txt xn_us.txt xn_vpn.txt xn_allow.txt)
		NEED_SCANNERS=1
		;;
	block | block_all)
		OUTPUTS="block_all,block_orig,block"
		FILES=(xn_block.txt xn_block_orig.txt xn_block_all.txt)
		NEED_SCANNERS=1
		;;
	cn)
		OUTPUTS="cn_us"
		FILES=(xn_cn.txt)
		NEED_SCANNERS=0
		;;
	fake)
		OUTPUTS="fake"
		FILES=(xn_fake.txt)
		NEED_SCANNERS=0
		;;
	us)
		OUTPUTS="xn_us"
		FILES=(xn_us.txt)
		NEED_SCANNERS=0
		;;
	vpn)
		OUTPUTS="xn_vpn"
		FILES=(xn_vpn.txt)
		NEED_SCANNERS=0
		;;
	allow)
		OUTPUTS="allow"
		FILES=(xn_allow.txt)
		NEED_SCANNERS=0
		;;
	check)
		resolve_cidr
		resolve_pipeline
		setup_cache
		do_check
		;;
	*)
		usage >&2
		exit 2
		;;
esac

resolve_cidr
resolve_pipeline
setup_cache

if [ "$NEED_SCANNERS" -eq 1 ]; then
	prepare_scanners "$ROOT"
fi

run_cidr "$ROOT" "$OUTPUTS"

for f in "${FILES[@]}"; do
	check_file "$ROOT/$f"
done
write_checksums "${FILES[@]}"

echo
echo "生成完成："
for f in "${FILES[@]}"; do
	printf '  %-18s %6s 行  %s\n' "$f" "$(wc -l <"$f" | tr -d ' ')" "$(cut -d' ' -f1 "$f.sha256sum")"
done
