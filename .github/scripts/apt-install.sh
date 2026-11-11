#!/usr/bin/env bash
# 换掉 Ubuntu cloud image 的 `mirror+file:/etc/apt/apt-mirrors.txt` 源，并带镜像兜底重试。
#
# GitHub 托管的 ubuntu-latest 用的是 cloud image 的源：sources 里写的是
#   URIs: mirror+file:/etc/apt/apt-mirrors.txt
# 而 /etc/apt/apt-mirrors.txt 只有一行 azure.archive.ubuntu.com。这个域名偶发 DNS
# 解析失败（E: Failed to fetch ... Temporary failure resolving
# 'azure.archive.ubuntu.com'），一次就拖死整个 job。
#
# 这里按候选镜像依次改源、apt-get update + apt-get install <包>，失败就换下一个；
# 全部失败才退出非 0（并打 ::error::）。装包语义与直接跑 apt-get install -y 一致。
#
#   bash .github/scripts/apt-install.sh build-essential pkg-config cmake
#
# 路径/命令都能用环境变量覆盖（自测用，见 xn/tests/apt-install.test.sh）：
#   SUDO（空串=不加 sudo）、APT_MIRRORS（空格分隔的镜像列表）、
#   APT_MIRRORS_FILE、APT_SOURCES_LIST、APT_SOURCES_DIR、APT_LISTS_DIR。
set -euo pipefail

if (( $# == 0 )); then
	echo "用法: $0 <apt 包>..." >&2
	exit 2
fi

SUDO="${SUDO-sudo}"
APT_MIRRORS_FILE="${APT_MIRRORS_FILE:-/etc/apt/apt-mirrors.txt}"
APT_SOURCES_LIST="${APT_SOURCES_LIST:-/etc/apt/sources.list}"
APT_SOURCES_DIR="${APT_SOURCES_DIR:-/etc/apt/sources.list.d}"
APT_LISTS_DIR="${APT_LISTS_DIR:-/var/lib/apt/lists}"

# 候选镜像：archive.ubuntu.com 是官方主源（走 CDN，DNS 也稳）；azure 留在第二，
# 它是 runner 同机房、正常情况下最快。后面几个是兜底，DNS 更不容易一起挂。
mirrors=(
	http://archive.ubuntu.com/ubuntu/
	http://azure.archive.ubuntu.com/ubuntu/
	https://mirrors.edge.kernel.org/ubuntu/
	https://mirrors.aliyun.com/ubuntu/
	https://mirrors.tuna.tsinghua.edu.cn/ubuntu/
)
if [[ -n "${APT_MIRRORS:-}" ]]; then
	read -r -a mirrors <<<"$APT_MIRRORS"
fi

apt_opts=(
	-o Acquire::Retries=3
	-o Acquire::http::Timeout=30
	-o Acquire::https::Timeout=30
)

run() { # 生产环境走 sudo；自测时 SUDO= 直接跑 PATH 里的桩
	if [[ -n "$SUDO" ]]; then
		sudo "$@"
	else
		"$@"
	fi
}

# 把「所有会走到 azure 的地方」都改掉：mirror 文件，以及直接把 azure 写死的
# sources（老镜像 / 手动加的源）。sed -i.bak 是 BSD/GNU 都能用的写法。
configure_mirror() {
	local mirror="$1" f
	# mirror+file 指向的文件不存在时 apt 会直接失败；只要目录在就补一份。
	if [[ -d "$(dirname "$APT_MIRRORS_FILE")" ]]; then
		printf '%s\n' "$mirror" | run tee "$APT_MIRRORS_FILE" >/dev/null
	fi
	for f in "$APT_SOURCES_LIST" "$APT_SOURCES_DIR"/*.sources "$APT_SOURCES_DIR"/*.list; do
		[[ -f "$f" ]] || continue
		grep -q 'azure\.archive\.ubuntu\.com' "$f" || continue
		run sed -E -i.bak "s|https?://azure\.archive\.ubuntu\.com/ubuntu/|$mirror|g" "$f"
		run rm -f "$f.bak"
	done
}

for mirror in "${mirrors[@]}"; do
	echo "::group::apt 源: $mirror"
	configure_mirror "$mirror"

	if ! run apt-get update "${apt_opts[@]}"; then
		echo "::warning::$mirror 上 apt-get update 失败，换下一个镜像"
		# 清掉可能来自上一个镜像的半套索引，避免 hash 校验互相打架。
		run rm -rf "${APT_LISTS_DIR:?}"/*
		echo "::endgroup::"
		continue
	fi

	if run apt-get install -y "${apt_opts[@]}" "$@"; then
		echo "::endgroup::"
		exit 0
	fi

	echo "::warning::$mirror 上 apt-get install 失败，换下一个镜像"
	run apt-get clean
	echo "::endgroup::"
done

echo "::error::所有候选 apt 镜像都失败：$*"
exit 1
