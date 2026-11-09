#!/bin/bash
#
# network/ 的 CI 入口：拿到 cidr（默认从 xn 的 latest release 下载 **普通包**
# xn.x86_64-unknown-linux-gnu.tar.xz 里解出来，也可以用 CIDR=... 指定本地二进制），
# 生成八份名单，校验后逐份 xz。
# .github/workflows/adguard.yml 的 network job 负责缓存 + 调本脚本 + 发布。
#
# 本地也可以直接跑：
#   CIDR=$(command -v cidr) SCANNERS_TARBALL=/tmp/internet-scanners.tar.gz ./network/ci.sh
#
# 下载规则：
#   - 配了 XN_REPO_TOKEN（CI 就是这种）：gh release download 拉最新 release，
#     不传 tag，等价于 latest；
#   - 没配 token（公开仓库）：curl GitHub 的 latest 地址
#     https://github.com/<XN_REPO>/releases/latest/download/<asset>；
#   - 私有仓库的网页下载地址
#     （releases/download/<tag>/<asset>，以及 releases/latest/download/<asset>）
#     不接受 token，带 Authorization 也是 404，必须走 API，所以配 token 时用 gh。

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

# 仓库不再提交 cidr 二进制（原来的 network/bin/cidr + Git LFS 已移除）。
# xn 的 release 不再单独发 cidr 包：cidr 跟着 **普通包**（xn.<triple>.tar.xz，
# 非 PGO 那一档）一起发，所以这里下载普通包再解出 cidr；和 CI 用同一份产物。
CIDR="${CIDR:-}"
XN_REPO="${XN_REPO:-leptonyu/xn}"
CIDR_ASSET="${CIDR_ASSET:-xn.x86_64-unknown-linux-gnu.tar.xz}"
CIDR_TAG="${CIDR_TAG:-}" # 空 = 最新 release；也可以填具体 tag
CIDR_URL="${CIDR_URL:-}" # 显式 URL：用 curl 下（公开仓库 / 镜像 / 固定 tag）
# xn 是私有仓库，下载 release 资产需要只读 token；仓库公开后留空即可。
XN_REPO_TOKEN="${XN_REPO_TOKEN:-}"
# 可选：固定包的 sha256（不设就只信 gh / HTTPS）
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

verify_archive() {
	local archive="$1" got

	[ -n "$CIDR_SHA256" ] || return 0
	got="$(sha256_file "$archive")"
	[ "$got" = "$CIDR_SHA256" ] ||
		die "cidr 包 sha256 不匹配：期望 ${CIDR_SHA256}，实际 $got"
}

# 直接 curl 一个 URL：显式 CIDR_URL、镜像，或没配 token 时的公开仓库 latest 地址。
fetch_cidr_url() {
	local url="$1" archive="$2" auth=()

	command -v curl >/dev/null 2>&1 || die "找不到 curl"
	if [ -n "$XN_REPO_TOKEN" ]; then
		auth=(-H "Authorization: Bearer $XN_REPO_TOKEN")
	fi

	echo "ci.sh: 下载 ${url} ..." >&2
	curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 300 \
		"${auth[@]+"${auth[@]}"}" "$url" -o "$archive.part" ||
		die "下载 cidr 失败：${url}（私有仓库的网页下载地址不接受 token，用 gh + XN_REPO_TOKEN，见 README）"
	mv "$archive.part" "$archive"
}

# 配了 token：gh release download 走 GitHub API（私有仓库下载资产的唯一可靠方式）。
# 不传 tag 就是最新 release，等价于 latest。
fetch_cidr_gh() {
	local dir="$1" archive="$2" gh_cmd=(env "GH_TOKEN=$XN_REPO_TOKEN" gh) args=(release download)

	command -v gh >/dev/null 2>&1 ||
		die "下载私有 release 需要 gh CLI（ubuntu-latest 自带）；或者用 CIDR=/path/to/cidr 指定"
	[ -n "$CIDR_TAG" ] && args+=("$CIDR_TAG")
	args+=(--repo "$XN_REPO" --pattern "$CIDR_ASSET" --dir "$dir" --clobber)

	echo "ci.sh: gh release download ${CIDR_TAG:-latest} ${CIDR_ASSET}（${XN_REPO}）..." >&2
	"${gh_cmd[@]}" "${args[@]}" ||
		die "下载普通包失败：确认 $XN_REPO 的 release 里有 ${CIDR_ASSET}（私有仓库需要 XN_REPO_TOKEN）"
	[ -f "$archive" ] || die "gh 没有把 $CIDR_ASSET 下到 $dir"
}

fetch_cidr() {
	local dir="$ROOT/.cache/cidr-bin" archive

	command -v tar >/dev/null 2>&1 || die "找不到 tar"
	mkdir -p "$dir" || die "缓存目录不可写：$dir"
	archive="$dir/$CIDR_ASSET"

	if [ -n "$CIDR_URL" ]; then
		fetch_cidr_url "$CIDR_URL" "$archive"
	elif [ -n "$XN_REPO_TOKEN" ]; then
		fetch_cidr_gh "$dir" "$archive"
	elif [ -n "$CIDR_TAG" ]; then
		fetch_cidr_url \
			"https://github.com/$XN_REPO/releases/download/$CIDR_TAG/$CIDR_ASSET" "$archive"
	else
		# 公开仓库（没配 token）：GitHub 的 latest release 下载地址
		fetch_cidr_url \
			"https://github.com/$XN_REPO/releases/latest/download/$CIDR_ASSET" "$archive"
	fi
	verify_archive "$archive"

	rm -rf "$dir/extract"
	mkdir -p "$dir/extract"
	tar -xJf "$archive" -C "$dir/extract" || die "解压普通包失败（${archive}）"
	CIDR="$(find "$dir/extract" -type f -name cidr -print -quit)"
	[ -n "$CIDR" ] || die "普通包里找不到 cidr 可执行文件（上游打包内容变了？）"
	chmod +x "$CIDR" 2>/dev/null || true
	[ -x "$CIDR" ] || die "cidr 不可执行：$CIDR"
}

if [ -n "$CIDR" ]; then
	resolve_cidr
else
	# 本地（非 Linux）默认包跑不起来，直接给条明确的路
	[ "$(uname -s)" = "Linux" ] ||
		die "默认下载的是 Linux x86_64 包；本机请用 CIDR=\$(command -v cidr) ./network/ci.sh"
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
