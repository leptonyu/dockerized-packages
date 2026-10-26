#!/bin/bash
#
# 生成 xn 侧的主要 CIDR 名单（从 machine/modules/network 迁移）：
#
#   xn_block.txt       eBPF 用：xn_block_raw 精确去掉 non_public（仅公网 IP）
#   xn_block_all.txt   原始版本：xn_block_raw + OpenFilters/internet-scanners 的 active cidr/
#   xn_cn.txt          cn ∩ us（原来的 xn_cn）
#   xn_fake.txt        fake/DNS 网段（原来的 xn_fake）
#   xn_us.txt          us_public + fake（原来的 xn_us，eBPF split 表）
#   xn_vpn.txt         xn_us + 192.160.0.0/11 + 10.78.0.0/15（原来的 xn_vpn）
#   xn_allow.txt       inbound_jail 白名单 = Cloudflare + CloudFront origin-facing（新增）
#
# 数据源、ASN、内联网段在 cidr.yaml 里；xn_block_all 的 scanner 部分是例外：
# 上游是一个目录（90+ 个 *_v4.txt / *_v6.txt），不是单条 URL，所以由本脚本
# 下 tarball 后把 cidr/*.txt 与 xn_block_raw 一起喂给 cidr 的 stdin 模式合并。
#
# 用法：
#   ./gen.sh                # 生成七份
#   ./gen.sh block          # xn_block.txt + xn_block_all.txt
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
XN_BLOCK_ALL_MIN=1000
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

  all        生成 xn_block / xn_block_all / xn_cn / xn_fake / xn_us / xn_vpn / xn_allow（默认）
  block      xn_block.txt + xn_block_all.txt
  block_all  同 block（block_all 依赖 xn_block.txt）
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
  XN_BLOCK_SHRINK   设为 1 时对 xn_block_all 做 --shrink-small-nets（适配 eBPF 16,384 上限）
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
		echo "gen.sh: 未设置 IPINFO_TOKEN；若 country_asn 缓存不存在或已超过 24h，cidr 会失败" >&2
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
		xn_allow.txt | xn_cn.txt | xn_block.txt | xn_block_all.txt)
			grep -q '\.' "$file" || die "$(basename "$file") 没有 IPv4 条目"
			grep -q ':' "$file" || die "$(basename "$file") 没有 IPv6 条目"
			;;
	esac
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

# xn_block_all = xn_block ∪ internet-scanners/cidr/*.txt
# 只取 active 的 cidr/；inactive/cidr 是已停用扫描器的归档快照，不并进来。
merge_block() {
	local block="$1" out="$2" archive scanner_dir files n block_n targets shrink

	[ -s "$block" ] || die "缺少 $block，无法生成 xn_block_all"
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

	# 默认只 merge；XN_BLOCK_SHRINK=1 时再做小子网聚合，用来适配 eBPF 的 16,384 上限
	shrink=""
	if [ "${XN_BLOCK_SHRINK:-${BLOCK_ALL_SHRINK:-0}}" = "1" ]; then
		shrink="--shrink-small-nets"
	fi
	block_n="$(wc -l <"$block" | tr -d ' ')"
	{
		cat "$block"
		find "$scanner_dir" -maxdepth 1 -type f -name '*.txt' -exec cat {} +
	} | "$CIDR" $shrink >"$WORK/xn_block_all.tmp" || die "cidr 合并 xn_block_all 失败"
	[ -s "$WORK/xn_block_all.tmp" ] || die "xn_block_all 为空"

	# xn_block 里的每个网段都必须仍被 xn_block_all 覆盖（合并只会变大，不会丢）
	targets="$(paste -sd, "$block")"
	"$CIDR" --test="$targets" <"$WORK/xn_block_all.tmp" >/dev/null 2>&1 \
		|| die "xn_block_all 没有覆盖 block_raw 的全部网段"

	mv "$WORK/xn_block_all.tmp" "$out"
	n="$(wc -l <"$out" | tr -d ' ')"
	[ "$n" -gt "$block_n" ] || die "xn_block_all 没有比 block_raw 多出条目（scanner 源为空？）"
	echo "gen.sh: xn_block_all = xn_block_raw + ${files} 个 scanner cidr 文件，共 ${n} 条${shrink:+（已 shrink）}" >&2
	if [ "$n" -gt 16384 ]; then
		echo "gen.sh: 警告：xn_block_all 有 ${n} 条，超过 eBPF 的 16,384 上限；" >&2
		echo "        eBPF 用 xn_block.txt，或 XN_BLOCK_SHRINK=1 ./gen.sh block" >&2
	fi
}

do_check() {
	local out rc=0 f
	new_work
	out="$WORK/out"
	mkdir -p "$out"

	echo "gen.sh: 在 $out 重新生成并对比" >&2
	run_cidr "$out" "block_raw,block,cn_us,fake,xn_us,xn_vpn,allow"
	merge_block "$out/xn_block_raw.txt" "$out/xn_block_all.txt"

	for f in xn_block.txt xn_block_all.txt xn_cn.txt xn_fake.txt xn_us.txt xn_vpn.txt xn_allow.txt; do
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
		echo "gen.sh: 七份名单与 pipeline / scanner 源一致"
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
		OUTPUTS="block_raw,block,cn_us,fake,xn_us,xn_vpn,allow"
		FILES=(xn_block.txt xn_block_all.txt xn_cn.txt xn_fake.txt xn_us.txt xn_vpn.txt xn_allow.txt)
		NEED_BLOCK_MERGE=1
		;;
	block | block_all)
		OUTPUTS="block_raw,block"
		FILES=(xn_block.txt xn_block_all.txt)
		NEED_BLOCK_MERGE=1
		;;
	cn)
		OUTPUTS="cn_us"
		FILES=(xn_cn.txt)
		NEED_BLOCK_MERGE=0
		;;
	fake)
		OUTPUTS="fake"
		FILES=(xn_fake.txt)
		NEED_BLOCK_MERGE=0
		;;
	us)
		OUTPUTS="xn_us"
		FILES=(xn_us.txt)
		NEED_BLOCK_MERGE=0
		;;
	vpn)
		OUTPUTS="xn_vpn"
		FILES=(xn_vpn.txt)
		NEED_BLOCK_MERGE=0
		;;
	allow)
		OUTPUTS="allow"
		FILES=(xn_allow.txt)
		NEED_BLOCK_MERGE=0
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

run_cidr "$ROOT" "$OUTPUTS"

if [ "$NEED_BLOCK_MERGE" -eq 1 ]; then
	merge_block "$ROOT/xn_block_raw.txt" "$ROOT/xn_block_all.txt"
	rm -f "$ROOT/xn_block_raw.txt"
fi

for f in "${FILES[@]}"; do
	check_file "$ROOT/$f"
done
write_checksums "${FILES[@]}"

echo
echo "生成完成："
for f in "${FILES[@]}"; do
	printf '  %-18s %6s 行  %s\n' "$f" "$(wc -l <"$f" | tr -d ' ')" "$(cut -d' ' -f1 "$f.sha256sum")"
done
