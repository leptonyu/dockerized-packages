#!/bin/bash
#
# network/ 的 CI 入口：拿到 cidr（默认从 xn 的 release 下载 Linux x86_64 包，
# 也可以用 CIDR=... 指定本地二进制），生成八份名单，校验后逐份 xz。
# .github/workflows/adguard.yml 的 network job 负责缓存 + 调本脚本 + 发布。
#
# 本地也可以直接跑：
#   CIDR=$(command -v cidr) SCANNERS_TARBALL=/tmp/internet-scanners.tar.gz ./network/ci.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

# 仓库不再提交 cidr 二进制（原来的 network/bin/cidr + Git LFS 已移除）：
# 默认从 xn 的 release 下载，和 CI 用同一个包。
CIDR="${CIDR:-}"
CIDR_URL="${CIDR_URL:-https://github.com/leptonyu/xn/releases/download/latest/cidr.x86_64-unknown-linux-gnu.tar.xz}"
# xn 是私有仓库，下载 release 资产需要只读 token；仓库公开后留空即可。
XN_REPO_TOKEN="${XN_REPO_TOKEN:-}"
# 可选：固定包的 sha256（不设就只信 HTTPS）
CIDR_SHA256="${CIDR_SHA256:-}"

die() {
	echo "ci.sh: $*" >&2
	exit 1
}

sha256_file() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	else
		shasum -a 256 "$1" | awk '{print $1}'
	fi
}

resolve_cidr() {
	local found

	case "$CIDR" in
		*/*) [ -x "$CIDR" ] || die "cidr 不可执行：$CIDR" ;;
		*)
			found="$(command -v "$CIDR" 2>/dev/null || true)"
			[ -n "$found" ] || die "找不到 cidr：$CIDR"
			CIDR="$found"
			;;
	esac
}

fetch_cidr() {
	local dir="$ROOT/.cache/cidr-bin" name archive auth=()

	name="$(basename "${CIDR_URL%%\?*}")"
	[ -n "$name" ] || die "CIDR_URL 解析不出文件名：$CIDR_URL"
	command -v curl >/dev/null 2>&1 || die "找不到 curl"
	command -v tar >/dev/null 2>&1 || die "找不到 tar"
	mkdir -p "$dir" || die "缓存目录不可写：$dir"

	archive="$dir/$name"
	if [ -n "$XN_REPO_TOKEN" ]; then
		auth=(-H "Authorization: Bearer $XN_REPO_TOKEN")
	fi

	echo "ci.sh: 下载 $CIDR_URL ..." >&2
	curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 300 \
		"${auth[@]+"${auth[@]}"}" "$CIDR_URL" -o "$archive.part" ||
		die "下载 cidr 失败：${CIDR_URL}（xn 是私有仓库时设置 XN_REPO_TOKEN）"
	mv "$archive.part" "$archive"

	if [ -n "$CIDR_SHA256" ]; then
		local got
		got="$(sha256_file "$archive")"
		[ "$got" = "$CIDR_SHA256" ] ||
			die "cidr 包 sha256 不匹配：期望 ${CIDR_SHA256}，实际 $got"
	fi

	rm -rf "$dir/extract"
	mkdir -p "$dir/extract"
	tar -xJf "$archive" -C "$dir/extract" || die "解压 cidr 包失败（${archive}）"
	CIDR="$(find "$dir/extract" -type f -name cidr -print -quit)"
	[ -n "$CIDR" ] || die "cidr 包里找不到 cidr 可执行文件"
	chmod +x "$CIDR" 2>/dev/null || true
	[ -x "$CIDR" ] || die "cidr 不可执行：$CIDR"
}

if [ -n "$CIDR" ]; then
	resolve_cidr
else
	# 本地（非 Linux）默认包跑不起来，直接给条明确的路
	[ "$(uname -s)" = "Linux" ] ||
		die "默认的 CIDR_URL 只有 Linux x86_64 包；本机请用 CIDR=\$(command -v cidr) ./network/ci.sh"
	fetch_cidr
fi
export CIDR

if [ -z "${IPINFO_TOKEN:-}" ]; then
	echo "::warning::IPINFO_TOKEN 未设置；冷缓存时 country_asn 源会失败"
fi

./gen.sh all

sha256sum -c \
	xn_block.txt.sha256sum \
	xn_block_orig.txt.sha256sum \
	xn_block_all.txt.sha256sum \
	xn_cn.txt.sha256sum \
	xn_fake.txt.sha256sum \
	xn_us.txt.sha256sum \
	xn_vpn.txt.sha256sum \
	xn_allow.txt.sha256sum

# 发布用：每份 .txt 单独 xz，不打包 tar。保留 plain .txt 供本地校验。
command -v xz >/dev/null 2>&1 || {
	echo "ci.sh: 找不到 xz" >&2
	exit 1
}
for f in \
	xn_block.txt \
	xn_block_orig.txt \
	xn_block_all.txt \
	xn_cn.txt \
	xn_fake.txt \
	xn_us.txt \
	xn_vpn.txt \
	xn_allow.txt; do
	xz -c "$f" >"$f.xz"
	sha256sum "$f.xz" >"$f.xz.sha256sum"
done

sha256sum -c \
	xn_block.txt.xz.sha256sum \
	xn_block_orig.txt.xz.sha256sum \
	xn_block_all.txt.xz.sha256sum \
	xn_cn.txt.xz.sha256sum \
	xn_fake.txt.xz.sha256sum \
	xn_us.txt.xz.sha256sum \
	xn_vpn.txt.xz.sha256sum \
	xn_allow.txt.xz.sha256sum

# 再验一次 xz 流本身（sha256 只能证明字节没变，不证明能被 xz 解开）
xz -t *.txt.xz || {
	echo "ci.sh: xz 文件损坏" >&2
	exit 1
}

echo
echo "network CI 产物："
wc -l xn_block.txt xn_block_orig.txt xn_block_all.txt xn_cn.txt xn_fake.txt xn_us.txt xn_vpn.txt xn_allow.txt
ls -l *.txt.xz
