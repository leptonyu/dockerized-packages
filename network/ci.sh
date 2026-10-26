#!/bin/bash
#
# network/ 的 CI 入口：用 bin/cidr（或 CIDR=...）生成八份名单，校验后逐份 xz。
# .github/workflows/adguard.yml 的 network job 负责 checkout(LFS) + 缓存 + 调本脚本 + 发布。
#
# 本地也可以直接跑：
#   CIDR=$(command -v cidr) SCANNERS_TARBALL=/tmp/internet-scanners.tar.gz ./network/ci.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

CIDR="${CIDR:-$ROOT/bin/cidr}"
export CIDR

if [ ! -f "$CIDR" ]; then
	echo "ci.sh: 找不到 cidr：$CIDR" >&2
	echo "       本地跑用 CIDR=\$(command -v cidr) ./network/ci.sh" >&2
	exit 1
fi
# LFS checkout 不保证可执行位，这里补一下
chmod +x "$CIDR" 2>/dev/null || true
[ -x "$CIDR" ] || {
	echo "ci.sh: cidr 不可执行：$CIDR" >&2
	exit 1
}

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
