#!/usr/bin/env bash
#
# fetch-bin.sh：从 xn 的**发布包**里解出普通 / tuned 两档 xn，给 pgo.compare 用。
#
#   ./xn/fetch-bin.sh --target x86_64-unknown-linux-gnu
#   ./xn/fetch-bin.sh --target aarch64-apple-darwin --tag v6.0.0
#
# 为什么从发布包解：release 里只有 runtime 包（`xn.<triple>.tar.xz` /
# `xn.<triple>.tuned.tar.xz`），没有单独的 `.bin`。`compare=only` 要能对**已经发布**的
# 构建单独跑，就从包里把 `xn` 解出来，写成 compare.sh 认的
# `xn.<triple>.{release,tuned}.bin`；这样不再依赖 compare=true 那一轮往 `xn-ci` 传的 bin。
#
# 依赖：gh（私有仓库要 GH_TOKEN，只读足够）、tar（xz）、sha256sum 或 shasum。
#
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
src="${XN_SRC:-$root/.cache/xn-src}"
out_dir="${XN_OUT_DIR:-$root/dist}"
target="${XN_TARGET:-x86_64-unknown-linux-gnu}"
tag="${XN_TAG:-}"
repo="${XN_REPO:-leptonyu/xn}"
keep=false

die() { echo "xn/fetch-bin.sh: $*" >&2; exit 2; }
note() { echo "==> $*" >&2; }
warn() { echo "xn/fetch-bin.sh: $*" >&2; }

usage() {
	awk 'NR > 1 { if ($0 ~ /^#/) { sub(/^# ?/, ""); print; next } exit }' "$0"
	cat <<'T'

选项（环境变量同名，带 XN_ 前缀）：
  --src DIR          上游 xn checkout（读 Cargo.toml 版本；默认 .cache/xn-src）
  --out-dir DIR      输出的 bin 目录（默认 xn/dist）
  --target TRIPLE    目标 triple（默认 x86_64-unknown-linux-gnu）
  --tag TAG          发布 tag（默认 v<Cargo.toml version>）
  --repo OWNER/REPO  发布所在仓库（默认 leptonyu/xn）
  --keep             保留临时下载 / 解压目录（排错用）
  -h, --help         本帮助
T
}

while (($#)); do
	case "$1" in
		--src) src="$2"; shift 2 ;;
		--src=*) src="${1#*=}"; shift ;;
		--out-dir) out_dir="$2"; shift 2 ;;
		--out-dir=*) out_dir="${1#*=}"; shift ;;
		--target) target="$2"; shift 2 ;;
		--target=*) target="${1#*=}"; shift ;;
		--tag) tag="$2"; shift 2 ;;
		--tag=*) tag="${1#*=}"; shift ;;
		--repo) repo="$2"; shift 2 ;;
		--repo=*) repo="${1#*=}"; shift ;;
		--keep) keep=true; shift ;;
		-h|--help) usage; exit 0 ;;
		*) die "未知参数 $1（用 -h 看用法）" ;;
	esac
done

command -v gh >/dev/null 2>&1 || die "需要 gh CLI"
command -v tar >/dev/null 2>&1 || die "需要 tar"

# 直接从上游 Cargo.toml 读 xn 版本号（workspace.package，其次 package）。
xn_version() { # $1=src
	local f="$1/Cargo.toml" v
	[[ -f "$f" ]] || return 1
	v="$(awk '
		/^\[workspace.package\]/ { in_section = 1; next }
		in_section && /^\[/ { exit }
		in_section && /^[[:space:]]*version[[:space:]]*=/ {
			line = $0
			sub(/^[^=]*=[[:space:]]*/, "", line)
			gsub(/["[:space:]]/, "", line)
			print line
			exit
		}
	' "$f")"
	if [[ -z "$v" ]]; then
		v="$(awk '
			/^\[package\]/ { in_section = 1; next }
			in_section && /^\[/ { exit }
			in_section && /^[[:space:]]*version[[:space:]]*=/ {
				line = $0
				sub(/^[^=]*=[[:space:]]*/, "", line)
				gsub(/["[:space:]]/, "", line)
				print line
				exit
			}
		' "$f")"
	fi
	[[ -n "$v" ]] || return 1
	printf '%s\n' "$v"
}

if [[ -z "$tag" ]]; then
	[[ -f "$src/Cargo.toml" ]] \
		|| die "找不到 $src/Cargo.toml（用 --src 指定上游 checkout，或 --tag 指定发布 tag）"
	version="$(xn_version "$src")" || die "读不到 xn 版本（$src/Cargo.toml）"
	tag="v$version"
fi

work="$(mktemp -d)"
cleanup() {
	if $keep; then
		echo "xn/fetch-bin.sh: 临时目录保留在 $work" >&2
	else
		rm -rf "$work"
	fi
}
trap cleanup EXIT

dl="$work/dl"
mkdir -p "$dl" "$out_dir"
note "来源：${repo}@${tag}（target=${target}）"

sha_check() { # <sumfile>，在下载目录里按校验和文件检查
	local sum="$1"
	if command -v sha256sum >/dev/null 2>&1; then
		( cd "$dl" && sha256sum -c "$sum" )
	elif command -v shasum >/dev/null 2>&1; then
		( cd "$dl" && shasum -a 256 -c "$sum" )
	else
		warn "没有 sha256sum / shasum，跳过校验和检查"
	fi
}

fetch_bin() { # <flavor> <asset>
	local flavor="$1" asset="$2" dir bin out
	note "下载 $asset"
	gh release download "$tag" --repo "$repo" \
		--pattern "$asset" --dir "$dl" --clobber \
		|| die "下载 $repo@$tag 的 $asset 失败（私有仓库确认 GH_TOKEN 有读权限）"
	[[ -f "$dl/$asset" ]] || die "gh 没把 $asset 下到 $dl"

	if gh release download "$tag" --repo "$repo" \
		--pattern "$asset.sha256sum" --dir "$dl" --clobber 2>/dev/null; then
		sha_check "$asset.sha256sum"
	else
		warn "$asset 没有 .sha256sum，跳过校验"
	fi

	dir="$work/extract/$flavor"
	mkdir -p "$dir"
	tar -xf "$dl/$asset" -C "$dir" || die "解压 $asset 失败"
	bin="$(find "$dir" -type f -name xn -print -quit)"
	[[ -n "$bin" ]] || die "$asset 里找不到 xn 可执行文件（上游打包内容变了？）"

	out="$out_dir/xn.$target.$flavor.bin"
	cp -p "$bin" "$out"
	chmod +x "$out" 2>/dev/null || true
	note "解出 $out"
}

fetch_bin release "xn.$target.tar.xz"
fetch_bin tuned "xn.$target.tuned.tar.xz"

note "完成：$out_dir/xn.$target.release.bin + $out_dir/xn.$target.tuned.bin"
