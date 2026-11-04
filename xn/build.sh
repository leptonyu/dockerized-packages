#!/usr/bin/env bash
#
# xn 模块：编译 PGO+BOLT 优化的 x86_64 GNU xn，并挂到 xn 版本号对应的 release tag。
#
# 上游仓库：git@github.com:leptonyu/xn.git
#
# 本脚本**不打包**：打包已经交给上游 release.sh 的 `--tuned --pack`（runtime 包 +
# trace 包 + SHA256SUMS 都落在 target/<triple>/release/）。这里只负责：
#   1) 取上游源码、跑 `release.sh --tuned --target <triple> --pack`；
#   2) 把 build.log / build-info.txt 交给它收进 trace 包（--pack-log / --pack-info）；
#   3) 校验产物、复制到 --out-dir；
#   4) 额外把 cidr / xn-tui 单独打好（不调优，见下）；
#   5) 需要时 gh release upload（逐资产上传；5xx / 网络抖动自动退避重试）。
#
# 发布不是原子操作：GitHub 的 release asset API 偶发 502/503/504，一个资产失败
# 不该连累其余的。所以上传是**逐个文件**做的（runtime/trace 的 .sha256sum 排最后），
# 每个文件单独重试；传完再按 *.sha256sum + asset digest 自检，不一致才整体重传一次。
#
# 产物（target/<triple>/release/，本脚本再复制到 --out-dir）：
#   xn.<triple>.tuned.tar.xz        runtime：xn / LICENSE / docs/configuration.md / THIRD-PARTY-NOTICES.txt
#   xn.<triple>.tuned.trace.tar.xz  trace：trace-files.txt 列出的诊断文件 + xn.tuned.env
#   （上游 release.sh 产出的名字带 flavor（Linux 是 pgo-bolt、macOS 是 pgo），
#    发布前统一改名成 .tuned.）
#                                      + 两份清单 + build.log / build-info.txt
#   SHA256SUMS                         两行 sha256 filename（本地校验用，不发布）
#   *.tar.xz.sha256sum                 每个包自己的校验和（发布用）
# 另外（同样 release.sh --pack，不调优；老版本才回退手工打）：
#   cidr.<triple>.tar.xz / xn-tui.<triple>.tar.xz（各带 .sha256sum）
#
# 为什么必须原生 Linux x86_64：BOLT 需要 --emit-relocs 的重定位节，zig 交叉档
# （macOS / musl 容器）拿不到。macOS 只能用 PGO-only（flavor 会变成 pgo）。
#
# 典型用法：
#   ./xn/build.sh                     # 构建 + 打包（不发布）
#   ./xn/build.sh --publish           # 发布到 v<Cargo.toml version>
#   ./xn/build.sh --tag v6.1.0 --publish
#   ./xn/build.sh --check             # 只检查工具链
#   ./xn/build.sh --dry-run           # 只打印命令
#   ./xn/build.sh --package-only --publish   # 不重编，拿现成产物重传
#
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
self="$root/build.sh"

repo="${XN_REPO:-git@github.com:leptonyu/xn.git}"
ref="${XN_REF:-main}"
ref_explicit=false
src="${XN_SRC:-}"
out_dir="${XN_OUT_DIR:-$root/dist}"
release_repo="${XN_RELEASE_REPO:-}"
tag="${XN_TAG:-}"
features="${XN_FEATURES:-}"
event="${XN_EVENT:-}"
freq="${XN_FREQ:-}"
icf="${XN_ICF:-}"
workload="${XN_WORKLOAD:-}"
publish=false
package_only=false
dry_run=false
check=false
force=false
tests=true
locked=true
prune_legacy=true
# 额外单独打包、**不做 PGO/BOLT** 的 bin（上游 bin 名：cidr <- xn-cidr-bin、
# xn-tui <- xn-tui-bin）。它们不在 xn 的热路径上，普通 release 构建就够。
extras="${XN_EXTRAS-cidr xn-tui}"
extra_assets=()

target="x86_64-unknown-linux-gnu"

die() { echo "xn/build.sh: $*" >&2; exit 2; }
note() { echo "==> $*" >&2; }
warn() { echo "xn/build.sh: 警告：$*" >&2; }

# 瞬时故障重试：GitHub API 偶发 502/503/504，或网络抖动。
#   retry <描述> <命令...>
# 4xx（408 / 429 除外）不重试 —— token 没权限、release 不存在这类错误直接失败，
# 不白等 4 轮；5xx / 超时 / 连接重置才退避重试。
# 环境变量：XN_RETRIES（尝试次数，默认 4）、XN_RETRY_DELAY（首次退避秒数，默认 3，翻倍至 30）。
retry() {
	local what="$1"; shift
	local attempts="${XN_RETRIES:-4}" delay="${XN_RETRY_DELAY:-3}"
	local tmp rc=0 i
	((attempts > 0)) || attempts=1
	tmp="$(mktemp)"
	for ((i = 1; i <= attempts; i++)); do
		rc=0
		"$@" 2>&1 | tee "$tmp" || rc=$?
		if ((rc == 0)); then
			rm -f "$tmp"
			return 0
		fi
		# 输出里有 4xx 且不是 408/429：重试也没用。
		if grep -Eq 'HTTP 4(0[0-9]|1[0-9])' "$tmp" && ! grep -Eq 'HTTP 4(08|29)' "$tmp"; then
			warn "${what}：HTTP 4xx（不可重试），放弃"
			rm -f "$tmp"
			return "$rc"
		fi
		if ((i == attempts)); then break; fi
		warn "$what 失败（第 ${i}/${attempts} 次）：$(tail -n 1 "$tmp")；${delay}s 后重试"
		sleep "$delay"
		delay=$((delay * 2 > 30 ? 30 : delay * 2))
	done
	warn "$what 失败（已重试 ${attempts} 次）"
	rm -f "$tmp"
	return "$rc"
}

usage() {
	sed -n '2,39p' "$self" | sed 's/^# \{0,1\}//'
	cat <<'EOF'

选项（环境变量同名，带 XN_ 前缀）：
  --src DIR            本地 xn checkout（CI 里由 actions/checkout 提供；给了就不再 clone）
  --repo URL           上游仓库，默认 git@github.com:leptonyu/xn.git
  --ref REF            分支 / tag / commit，默认 main（须包含 release.sh --tuned --pack）
  --out-dir DIR        产物目录，默认 xn/dist
  --release-repo R     release 所在仓库；默认 = --repo / XN_REPO 的 owner/repo
  --tag TAG            目标 release tag；默认直接读 Cargo.toml 的 v<version>
  --features LIST      cargo features，默认不加（需要时传 quic 等）
  --event EVENT        BOLT stage2 的 perf 事件，默认用 release.sh 的默认值；
                       GitHub 托管 runner 用 cpu-clock:u
  --freq N             perf 采样频率，透传给 release.sh
  --icf MODE           BOLT ICF：safe / all / none
  --workload CMD       自定义 PGO/BOLT 负载，透传给 release.sh
  --no-tests           PGO 采样只跑 loopback 套件，不跑 nextest
  --no-locked          不向 cargo 传 --locked
  --force              让 build-tuned 重做已有 run 目录
  --extras "A B"       额外单独打包的 bin（上游 bin 名，默认 "cidr xn-tui"）：
                       只做普通 release 构建，不跑 PGO/BOLT
  --no-extras          不打包这些额外 bin
  --keep-legacy        发布时不删除旧版单独上传的 .env / .build-info 等
  --package-only       不构建，只拿 target/<triple>/release/ 里现成的产物去发布
  --publish            通过 gh 发布到 --tag；release 不存在时新建（默认上游 xn）
  --check              只检查工具链与 release.sh 能力，不构建
  --dry-run            只打印命令，不 clone / 不构建 / 不上传
  -h, --help           本帮助

打包由上游 release.sh 完成（`--tuned --pack`），本脚本只上传：
  xn.<triple>.tuned.tar.xz / xn.<triple>.tuned.trace.tar.xz（各带 .sha256sum）
  外加 cidr.<triple>.tar.xz / xn-tui.<triple>.tar.xz（也是 release.sh --pack，不调优）
EOF
}

# 带值选项的“下一个参数”解析：--opt value 与 --opt=value 都认。
need_value() { # $1=选项名 $2=剩余参数个数
	(($2 >= 2)) || die "$1 缺少参数"
}

while (($#)); do
	case "$1" in
		--src) need_value "$1" "$#"; src="$2"; shift 2 ;;
		--src=*) src="${1#*=}"; shift ;;
		--repo) need_value "$1" "$#"; repo="$2"; shift 2 ;;
		--repo=*) repo="${1#*=}"; shift ;;
		--ref) need_value "$1" "$#"; ref="$2"; ref_explicit=true; shift 2 ;;
		--ref=*) ref="${1#*=}"; ref_explicit=true; shift ;;
		--out-dir) need_value "$1" "$#"; out_dir="$2"; shift 2 ;;
		--out-dir=*) out_dir="${1#*=}"; shift ;;
		--release-repo) need_value "$1" "$#"; release_repo="$2"; shift 2 ;;
		--release-repo=*) release_repo="${1#*=}"; shift ;;
		--tag) need_value "$1" "$#"; tag="$2"; shift 2 ;;
		--tag=*) tag="${1#*=}"; shift ;;
		--features) need_value "$1" "$#"; features="$2"; shift 2 ;;
		--features=*) features="${1#*=}"; shift ;;
		--event) need_value "$1" "$#"; event="$2"; shift 2 ;;
		--event=*) event="${1#*=}"; shift ;;
		--freq) need_value "$1" "$#"; freq="$2"; shift 2 ;;
		--freq=*) freq="${1#*=}"; shift ;;
		--icf) need_value "$1" "$#"; icf="$2"; shift 2 ;;
		--icf=*) icf="${1#*=}"; shift ;;
		--workload) need_value "$1" "$#"; workload="$2"; shift 2 ;;
		--workload=*) workload="${1#*=}"; shift ;;
		--no-tests) tests=false; shift ;;
		--no-locked) locked=false; shift ;;
		--extras) need_value "$1" "$#"; extras="$2"; shift 2 ;;
		--extras=*) extras="${1#*=}"; shift ;;
		--no-extras) extras=""; shift ;;
		--keep-legacy) prune_legacy=false; shift ;;
		--force) force=true; shift ;;
		--package-only) package_only=true; shift ;;
		--publish) publish=true; shift ;;
		--check) check=true; shift ;;
		--dry-run) dry_run=true; shift ;;
		-h|--help) usage; exit 0 ;;
		*) die "未知参数 $1（用 -h 看用法）" ;;
	esac
done

# 路径统一成绝对路径；--src 相对当前目录。
abs_dir() { # $1=path $2=默认目录（不存在则相对它）
	local p="$1"
	if [[ "$p" != /* ]]; then p="$PWD/$p"; fi
	mkdir -p "$p"
	(cd "$p" && pwd)
}

out_dir="$(abs_dir "$out_dir")"
if [[ -n "$src" ]]; then
	src="$(cd "$src" 2>/dev/null && pwd -P)" || die "--src 不存在：$src"
fi

is_linux_x86_64() {
	[[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]]
}

sha256_file() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$1" | awk '{print $1}'
	else
		die "找不到 sha256sum / shasum"
	fi
}

# 文件字节数（日志里报「多大」用）。
bytes_of() { wc -c < "$1" | tr -d '[:space:]'; }

# 是否在本次要上传的资产列表里（verify_published 用）。
is_uploaded_asset() {
	local n="$1" a
	for a in "${assets[@]}"; do
		if [[ "$(basename "$a")" == "$n" ]]; then return 0; fi
	done
	return 1
}

# 字节数 → 人读。
human_bytes() { # $1=字节数
	awk -v b="${1:-0}" 'BEGIN {
		split("B K M G T", u, " ")
		i = 1
		while (b >= 1024 && i < 5) { b /= 1024; i++ }
		if (i == 1) printf "%d%s", b, u[i]
		else printf "%.1f%s", b, u[i]
	}'
}

have_tuned() { # $1=src
	[[ -f "$1/release.sh" ]] && grep -q -- '--tuned' "$1/release.sh"
}

have_pack() { # $1=src
	[[ -f "$1/release.sh" ]] && grep -q -- '--pack' "$1/release.sh"
}

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

# 上游 repo URL 的 owner/repo（用于判断能否在目标仓库自动建 release/tag）。
repo_slug() {
	case "$repo" in
		git@github.com:*) printf '%s\n' "${repo#git@github.com:}" | sed 's/\.git$//' ;;
		https://github.com/*) printf '%s\n' "${repo#https://github.com/}" | sed 's/\.git$//' ;;
		sh:*|git://*) printf '%s\n' "${repo#*github.com[:/]}" | sed 's/\.git$//' ;;
		*) return 1 ;;
	esac
}

# 没显式给 --release-repo 时，release 推回 XN_REPO / --repo 本身（owner/repo）。
if [[ -z "$release_repo" ]]; then
	if ! release_repo="$(repo_slug)"; then
		$publish && die "无法从 --repo / XN_REPO 解析 owner/repo；请显式用 --release-repo"
		release_repo="<none>"
	fi
fi

# 源码准备好后确定版本与默认 tag：v<workspace version>。
prepare_version() {
	version="$(xn_version "$src")" || die "读不到 xn 版本（$src/Cargo.toml）"
	[[ -n "$tag" ]] || tag="v$version"
	note "xn 版本：${version}（发布 tag：${tag}）"
}

require_platform() {
	is_linux_x86_64 || die "当前只支持原生 Linux x86_64（BOLT 需要 --emit-relocs）；本机 $(uname -s)/$(uname -m)。
                     macOS 只用上游 build-tuned.sh 跑 PGO-only，不走这个 workflow。"
	command -v rustc >/dev/null 2>&1 || die "找不到 rustc"
	local h
	h="$(rustc -vV 2>/dev/null | sed -n 's/^host: //p')"
	[[ "$h" == "$target" ]] || die "rustc host 是 ${h:-?}，需要 $target"
	if [[ -r /proc/sys/kernel/perf_event_paranoid ]]; then
		local p
		p="$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo '?')"
		if [[ "$p" =~ ^[0-9]+$ ]] && ((p > 2)); then
			die "kernel.perf_event_paranoid=${p}，perf record 会被拒绝；先 sudo sysctl kernel.perf_event_paranoid=1"
		fi
	fi
}

prepare_source() {
	if [[ -n "$src" ]]; then
		have_tuned "$src" || die "$src/release.sh 没有 --tuned；请换一个包含该提交的 --src，或用 --ref 指到对应分支"
		have_pack "$src" || die "$src/release.sh 没有 --pack（旧版？）；用 --ref 指向含 --pack 的提交"
		commit="$(git -C "$src" rev-parse HEAD 2>/dev/null || echo unknown)"
		ref_label="<local HEAD>"
		$ref_explicit && warn "--src 已指定，忽略 --ref=${ref}，使用当前 HEAD ${commit:0:12}"
		prepare_version
		return 0
	fi

	src="${XN_SRC_CACHE:-$root/.cache/xn-src}"
	if [[ ! -d "$src/.git" ]]; then
		# 只取一个 ref、depth=1：不拉全历史，也不拉 tags（版本号直接读 Cargo.toml）。
		[[ ! -e "$src" || -z "$(ls -A "$src" 2>/dev/null)" ]] \
			|| die "$src 已存在但不是 git 仓库；请移走或换 XN_SRC_CACHE"
		local tmp="${src}.tmp.$$"
		rm -rf "$tmp"
		mkdir -p "$(dirname "$src")"
		note "clone --depth 1 --single-branch --branch ${ref} ${repo} → ${src}"
		if ! git clone --depth 1 --single-branch --branch "$ref" "$repo" "$tmp"; then
			# --branch 只认分支/tag；给的是 commit 时退回 init + shallow fetch。
			rm -rf "$tmp"
			git init -q "$tmp" || die "git init 失败：$tmp"
			git -C "$tmp" remote add origin "$repo" || die "git remote add 失败：$repo"
			git -C "$tmp" fetch --depth 1 origin "$ref" || die "shallow fetch 失败：$ref"
			git -C "$tmp" checkout --force --detach FETCH_HEAD || die "checkout 失败：$ref"
		fi
		rm -rf "$src"
		mv "$tmp" "$src" || die "移动 clone 目录失败：$tmp → $src"
	else
		note "shallow fetch ${ref} → ${src}"
		git -C "$src" fetch --depth 1 origin "$ref" || die "shallow fetch 失败（私有仓库需要 SSH key / token）：$ref"
		git -C "$src" checkout --force --detach FETCH_HEAD || die "checkout 失败：$ref"
	fi
	commit="$(git -C "$src" rev-parse HEAD)"
	ref_label="$ref"
	have_tuned "$src" || die "$src 的 release.sh 没有 --tuned（$ref 太旧？）；用 --ref 指向含该提交的分支/tag"
	have_pack "$src" || die "$src 的 release.sh 没有 --pack；用 --ref 指向含 --pack 的提交"
	prepare_version
}

# 找 extras 的可执行文件（release.sh --pack 没出包时的回退路径要用）。
find_extra_bin() { # $1=bin 名 → stdout 路径，失败返回 1
	local b="$1" cand found=""
	for cand in "$src/target/$target/release/$b" "$src/target/release/$b"; do
		if [[ -x "$cand" ]]; then
			printf '%s\n' "$cand"
			return 0
		fi
	done
	found="$(find "$src/target" -maxdepth 3 -type f -name "$b" -perm -u+x 2>/dev/null | head -n1)"
	[[ -n "$found" ]] || return 1
	printf '%s\n' "$found"
}

# ---------------------------------------------------------------- dry-run
# 只打印计划，不 clone、不建目录、不跑 doctor；在 macOS 上也能用。
print_plan() {
	local s="${src:-$root/.cache/xn-src}"
	local rargs=(--tuned --target "$target" --pack
		--pack-log "<out-dir>/build.log" --pack-info "<out-dir>/build-info.txt")
	[[ -n "$features" ]] && rargs+=(--features "$features")
	[[ -n "$workload" ]] && rargs+=(--workload "$workload")
	[[ -n "$freq" ]] && rargs+=(--freq "$freq")
	[[ -n "$event" ]] && rargs+=(--event "$event")
	[[ -n "$icf" ]] && rargs+=(--icf "$icf")
	$force && rargs+=(--force)
	$tests || rargs+=(--no-tests)
	$locked && rargs+=(--locked)

	echo "# 需要原生 Linux x86_64；当前 $(uname -s)/$(uname -m)"
	if [[ -z "$src" ]]; then
		printf '+ git clone --depth 1 --single-branch --branch %q %q %q\n' "$ref" "$repo" "$s"
		printf '+ # 若 %q 不是分支/tag：git init + git fetch --depth 1 origin %q\n' "$ref" "$ref"
	fi
	if $package_only; then
		echo "# --package-only：跳过构建，直接用 $s/target/$target/release/ 里的产物"
	else
		printf '+ (cd %q && ./release.sh' "$s"
		printf ' %s' "${rargs[@]}"
		printf ')\n'
	fi
	printf '+ 校验并复制 %s/target/%s/release/{xn.*.tar.xz, SHA256SUMS} → %s\n' "$s" "$target" "$out_dir"
	printf '+ 打包 extras（不调优）：%s\n' "${extras:-<none>}"
	if $publish; then
		if [[ -n "$tag" ]]; then
			printf '+ gh release create/upload %q --repo %q --clobber <包 + 各自的 .sha256sum + extras>\n' "$tag" "$release_repo"
		else
			printf '+ gh release create/upload v<Cargo.toml version> --repo %q --clobber <包 + 各自的 .sha256sum + extras>\n' "$release_repo"
		fi
	fi
}
if $dry_run; then
	print_plan
	exit 0
fi

# ---------------------------------------------------------------- check
if $check; then
	prepare_source
	echo "==> 上游：${src}（${commit:0:12}）"
	( cd "$src" && ./release.sh --tuned --dry-run )
	echo
	local_doctor=0
	( cd "$src" && ./scripts/build-tuned.sh doctor --target "$target" --require bolt ) || local_doctor=$?
	if $tests && ! command -v cargo-nextest >/dev/null 2>&1; then
		warn "没有 cargo-nextest；release.sh --tuned 默认会跑 nextest，请安装或用 --no-tests"
	fi
	if $publish && ! command -v gh >/dev/null 2>&1; then
		warn "没有 gh；--publish 需要 gh"
	fi
	if ((local_doctor != 0)); then
		echo "BOLT 工具链不完整；见 xn/README.md 的依赖安装段" >&2
		exit "$local_doctor"
	fi
	exit 0
fi

# ---------------------------------------------------------------- build
if ! $package_only; then
	require_platform
	prepare_source
	note "上游：${src}（${commit:0:12}，ref=${ref_label}）"

	# 给 release.sh --pack 收进 trace 包的「外部 workflow 记录」。
	build_info="$out_dir/build-info.txt"
	{
		printf 'format=1\n'
		printf 'packaged_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		printf 'source_repo=%s\n' "$repo"
		printf 'source_ref=%s\n' "$ref_label"
		printf 'source_commit=%s\n' "$commit"
		printf 'version=%s\n' "$version"
		printf 'target=%s\n' "$target"
		printf 'features=%s\n' "${features:-<default>}"
		printf 'tests=%s\n' "$tests"
		printf 'event=%s\n' "${event:-<release.sh default>}"
		printf 'freq=%s\n' "${freq:-<release.sh default>}"
		printf 'icf=%s\n' "${icf:-all}"
		printf 'release_repo=%s\n' "$release_repo"
		printf 'release_tag=%s\n' "${tag:-<none>}"
		printf 'note=打包由上游 release.sh --tuned --pack 完成（runtime + trace + SHA256SUMS）\n'
	} > "$build_info"

	build_args=(--tuned --target "$target" --pack
		--pack-log "$out_dir/build.log"
		--pack-info "$build_info")
	[[ -n "$features" ]] && build_args+=(--features "$features")
	[[ -n "$workload" ]] && build_args+=(--workload "$workload")
	[[ -n "$freq" ]] && build_args+=(--freq "$freq")
	[[ -n "$event" ]] && build_args+=(--event "$event")
	[[ -n "$icf" ]] && build_args+=(--icf "$icf")
	$force && build_args+=(--force)
	$tests || build_args+=(--no-tests)
	$locked && build_args+=(--locked)

	# extras 先编：cidr / xn-tui **不做 PGO/BOLT**（不在 xn 热路径上，普通构建就够），
	# 而且**必须逐包单独调用** release.sh —— 一次写多个包（或用多个 -p）会做 feature
	# 合并：xn 的 reqwest/rustls 会被带进 xn-tui，白胖 2 MB，构建产物也不是同一套。
	if [[ -n "${extras// /}" ]]; then
		extra_args=(--target "$target" --pack)
		$locked && extra_args+=(--locked)
		for b in ${extras//,/ }; do
			note "构建 extras（不调优）：${b}（单独调用 release.sh --pack）"
			( cd "$src" && ./release.sh "$b" "${extra_args[@]}" ) 2>&1 | tee -a "$out_dir/build.log"
		done
	fi

	note "release.sh ${build_args[*]}"
	( cd "$src" && ./release.sh "${build_args[@]}" ) 2>&1 | tee "$out_dir/build.log"
else
	# --package-only 不构建，但仍要有源码来拿产物与元数据。
	if [[ -z "$src" ]]; then
		src="${XN_SRC_CACHE:-$root/.cache/xn-src}"
		[[ -d "$src/.git" ]] || die "--package-only 需要 --src 或已存在的 $src"
	fi
	prepare_source
	note "package-only：使用现有产物，不重新构建"
fi

# ---------------------------------------------------------------- collect
release_dir="$src/target/$target/release"
# release.sh --pack 把三个文件放在 target/<triple>/release/：
#   xn.<triple>.<flavor>.tar.xz / xn.<triple>.<flavor>.trace.tar.xz / SHA256SUMS
# flavor 在 Linux 上是 pgo-bolt，macOS PGO-only 是 pgo —— 用 glob 认，不写死。
runtime_tar=""
trace_tar=""
sums=""
shopt -s nullglob
for f in "$release_dir"/xn.*.tar.xz; do
	case "$f" in
		*.trace.tar.xz) trace_tar="$f" ;;
		*) runtime_tar="$f" ;;
	esac
done
shopt -u nullglob
[[ -f "$release_dir/SHA256SUMS" ]] && sums="$release_dir/SHA256SUMS"
[[ -n "$runtime_tar" ]] || die "缺 runtime 包：$release_dir/xn.*.tar.xz（release.sh --pack 是否成功？）"
[[ -n "$trace_tar" ]] || die "缺 trace 包：$release_dir/xn.*.trace.tar.xz"
[[ -n "$sums" ]] || die "缺 SHA256SUMS：$release_dir/SHA256SUMS"

runtime_base="$(basename "$runtime_tar")"
trace_base="$(basename "$trace_tar")"
runtime_out="$out_dir/xn.$target.tuned.tar.xz"
trace_out="$out_dir/xn.$target.tuned.trace.tar.xz"

note "产物：${runtime_base}（$(human_bytes "$(bytes_of "$runtime_tar")")）"
note "      ${trace_base}（$(human_bytes "$(bytes_of "$trace_tar")")）"
cp -p "$runtime_tar" "$trace_tar" "$sums" "$out_dir/"

# 校验和自检：只对两个 xn 包按 SHA256SUMS 里的行核对（extras 的 pack 若也写
# SHA256SUMS，行数/内容可能被动过，别让 extras 的行把 xn 的校验搞成假阴性）。
verify_sum() { # $1=文件
	local f="$1" base want got
	base="$(basename "$f")"
	want="$(awk -v n="$base" '$2 == n { print $1; exit }' "$out_dir/SHA256SUMS")"
	[[ -n "$want" ]] || die "SHA256SUMS 里没有 ${base} 的校验和（$out_dir/SHA256SUMS）"
	got="$(sha256_file "$f")"
	[[ "$got" == "$want" ]] || die "${base} 校验失败（期望 ${want}，实际 ${got}）"
}
verify_sum "$out_dir/$runtime_base"
verify_sum "$out_dir/$trace_base"
note "SHA256SUMS 校验通过（runtime + trace）"

# 发布名固定成 .tuned.：不把上游的 flavor（pgo-bolt / pgo）暴露给消费端。
# 本地校验在改名前已经做完，SHA256SUMS 只用于这一步。
if [[ "$out_dir/$runtime_base" != "$runtime_out" ]]; then
	mv -f "$out_dir/$runtime_base" "$runtime_out"
fi
if [[ "$out_dir/$trace_base" != "$trace_out" ]]; then
	mv -f "$out_dir/$trace_base" "$trace_out"
fi
runtime_tar="$runtime_out"
trace_tar="$trace_out"

# ---------------------------------------------------------------- extras package
# cidr / xn-tui 也支持 release.sh --pack：包直接落在 target/<triple>/release/，
# 名字是 <bin>.<triple>.tar.xz（可能有配套的 .sha256sum）。找不到才回退手工打。
extra_list=(${extras//,/ })
for eb in ${extra_list[@]+"${extra_list[@]}"}; do
	epkg=""
	shopt -s nullglob
	for f in "$release_dir/$eb".*.tar.xz; do
		case "$f" in
			*.trace.tar.xz) continue ;;
		esac
		epkg="$f"
		break
	done
	shopt -u nullglob
	if [[ -n "$epkg" ]]; then
		ename="$(basename "$epkg")"
		cp -p "$epkg" "$out_dir/"
		if [[ -f "$epkg.sha256sum" ]]; then
			cp -p "$epkg.sha256sum" "$out_dir/"
		else
			printf '%s  %s\n' "$(sha256_file "$out_dir/$ename")" "$ename" > "$out_dir/$ename.sha256sum"
		fi
		extra_assets+=("$out_dir/$ename" "$out_dir/$ename.sha256sum")
		note "extras 包：${ename}（release.sh --pack，$(human_bytes "$(bytes_of "$out_dir/$ename")")）"
		continue
	fi
	# 回退：老 release.sh 不带 --pack，或这步没编出包 —— 手工打 bin / LICENSE / NOTICES。
	ebin="$(find_extra_bin "$eb")" || die "缺 extras 产物：${eb}。找过：${src}/target/${target}/release/${eb}、${src}/target/release/${eb}，
                     以及 ${src}/target 下 3 层内的同名可执行文件；release.sh 也没给出 ${eb}.*.tar.xz。
                     --package-only 不编译；也可以加 --no-extras 跳过。"
	estage="$out_dir/.stage-$eb.$target"
	rm -rf "$estage"
	mkdir -p "$estage"
	cp "$ebin" "$estage/$eb"
	chmod +x "$estage/$eb"
	cp "$src/LICENSE" "$estage/LICENSE"
	efiles=("$eb" LICENSE)
	if [[ -s "$src/target/THIRD-PARTY-NOTICES.txt" ]]; then
		cp "$src/target/THIRD-PARTY-NOTICES.txt" "$estage/THIRD-PARTY-NOTICES.txt"
		efiles+=(THIRD-PARTY-NOTICES.txt)
	else
		warn "没有 THIRD-PARTY-NOTICES.txt：$eb.$target.tar.xz 不带许可清单"
	fi
	note "打包 $eb.$target.tar.xz（${efiles[*]}，不调优，手工回退）"
	tar -C "$estage" -cJf "$out_dir/$eb.$target.tar.xz" "${efiles[@]}"
	rm -rf "$estage"
	eb_sha="$(sha256_file "$out_dir/$eb.$target.tar.xz")"
	printf '%s  %s\n' "$eb_sha" "$eb.$target.tar.xz" > "$out_dir/$eb.$target.tar.xz.sha256sum"
	extra_assets+=("$out_dir/$eb.$target.tar.xz" "$out_dir/$eb.$target.tar.xz.sha256sum")
	note "extras 包：$eb.$target.tar.xz（$(human_bytes "$(bytes_of "$out_dir/$eb.$target.tar.xz")")）"
done

# ---------------------------------------------------------------- publish
# release 上放：runtime / trace / extras 各自一个包 + 同名的 <asset>.sha256sum。
# 不再发汇总的 SHA256SUMS：校验和与资产一一对应，消费端按 <asset>.sha256sum 校验。
for f in "$(basename "$runtime_tar")" "$(basename "$trace_tar")"; do
	printf '%s  %s\n' "$(sha256_file "$out_dir/$f")" "$f" > "$out_dir/$f.sha256sum"
done

assets=(
	"$out_dir/$(basename "$runtime_tar")"
	"$out_dir/$(basename "$trace_tar")"
	${extra_assets[@]+"${extra_assets[@]}"}
	# runtime/trace 的校验和最后传：消费端最坏看到旧包 + 旧校验和，不会新校验和配旧包
	"$out_dir/$(basename "$runtime_tar").sha256sum"
	"$out_dir/$(basename "$trace_tar").sha256sum"
)

# 逐个资产上传：一个文件 502 不该让后面的（尤其是排在最后的 .sha256sum）传不上去，
# 每个文件单独重试 + 退避。gh --clobber 会先删同名旧资产再传，重试是幂等的。
upload_assets() {
	local a name
	for a in "${assets[@]}"; do
		name="$(basename "$a")"
		note "上传 ${name}（$(human_bytes "$(bytes_of "$a")")）"
		retry "上传 $name" gh release upload "$tag" --repo "$release_repo" --clobber "$a" ||
			die "上传 $name 失败：$release_repo@${tag}（网络/API 抖动，可稍后重跑：--package-only --publish）"
	done
}

# release 资产是一个个传的，不是原子操作；传完从 API 再确认一遍，防止
# 「包换了、.sha256sum 还是旧的」这种半更新。一致返回 0。
verify_published() {
	local tmp a name digest want bad=0

	tmp="$(mktemp -d)"
	if ! retry "下载 *.sha256sum" gh release download "$tag" --repo "$release_repo" \
		--pattern '*.sha256sum' --dir "$tmp" --clobber >/dev/null; then
		rm -rf "$tmp"
		warn "release 上取不到 *.sha256sum"
		return 1
	fi
	for a in "${assets[@]}"; do
		case "$a" in
			*.sha256sum) ;;
			*) continue ;;
		esac
		name="$(basename "$a")"
		if [[ ! -f "$tmp/$name" ]]; then
			warn "release 上缺 $name"
			bad=1
		elif ! cmp -s "$tmp/$name" "$a"; then
			warn "release 上的 $name 与本次构建不一致"
			bad=1
		fi
	done
	rm -rf "$tmp"

	# GitHub 会给 release asset 记 sha256 digest；老 gh / 没有该字段时跳过。
	while read -r name digest; do
		[[ -n "$digest" && "$digest" != "null" ]] || continue
		is_uploaded_asset "$name" || continue
		want="$(sha256_file "$out_dir/$name")"
		if [[ "$digest" != "sha256:$want" ]]; then
			warn "release 上 $name 的 digest 对不上（$digest ≠ sha256:${want}）"
			bad=1
		fi
	done < <(gh api "repos/$release_repo/releases/tags/$tag" \
		--jq '.assets[] | "\(.name) \(.digest)"' 2>/dev/null || true)

	return "$bad"
}

if $publish; then
	command -v gh >/dev/null 2>&1 || die "--publish 需要 gh CLI"
	if [[ -z "${GH_TOKEN:-}" && -z "${GITHUB_TOKEN:-}" ]]; then
		gh auth status >/dev/null 2>&1 || die "gh 未登录；设 GH_TOKEN（contents:write）或 gh auth login"
	fi
	if ! gh release view "$tag" --repo "$release_repo" >/dev/null 2>&1; then
		slug="$(repo_slug || true)"
		[[ -n "$slug" && "$release_repo" == "$slug" ]] \
			|| die "release $release_repo@$tag 不存在；只有上游 $slug 会自动创建（其他仓库请先建 release 或用 --tag）"
		note "新建 release ${release_repo}@${tag}（target ${commit:0:12}）"
		retry "创建 release" gh release create "$tag" --repo "$release_repo" --target "$commit" \
			--title "xn $version" \
			--notes "PGO+BOLT x86_64 GNU build of xn $version from ${commit:0:12}.

- \`$(basename "$runtime_tar")\`: runtime package (xn / LICENSE / docs/configuration.md / THIRD-PARTY-NOTICES.txt)
- \`$(basename "$trace_tar")\`: build trace (trace-files.txt 列出的诊断文件 + xn.tuned.env + 清单 + build.log / build-info.txt)
- \`*.tar.xz.sha256sum\`: 每个包自己的校验和（\`shasum -a 256 -c <asset>.sha256sum\`）" || {
			# 502 时请求可能已经落地；再看一眼，别把建成功的 release 当失败。
			gh release view "$tag" --repo "$release_repo" >/dev/null 2>&1 ||
				die "创建 release ${release_repo}@${tag} 失败"
		}
	fi
	note "上传 ${#assets[@]} 个资产到 $release_repo@$tag"
	upload_assets
	if ! verify_published; then
		warn "release 资产与本次构建不一致，重传一次"
		upload_assets
		verify_published ||
			die "release 资产仍与本次构建不一致（是否有别的 workflow 在写 $release_repo@${tag}？）"
	fi
	note "release 资产自检通过（*.sha256sum + digest）"
	# 旧版曾把 env / build-info / manifest / bolt.env 单独发布；默认清掉。
	if $prune_legacy; then
		base_name="$(basename "$runtime_tar")"
		base_name="${base_name%.tar.xz}"
		legacy=(
			"SHA256SUMS" # 旧版汇总校验和，改成每个包一个 .sha256sum
			"$base_name.env"
			"$base_name.build-info.txt"
			"$base_name.manifest.tsv"
			"$base_name.bolt.env"
		)
		# 发布名从上游 flavor（pgo-bolt / pgo）统一改成 .tuned. 后，清掉旧名字。
		if [[ "$runtime_base" != "$(basename "$runtime_tar")" ]]; then
			legacy+=(
				"$runtime_base" "$runtime_base.sha256sum"
				"$trace_base" "$trace_base.sha256sum"
			)
		fi
		names="$(gh release view "$tag" --repo "$release_repo" --json assets --jq '.assets[].name' 2>/dev/null || true)"
		for name in "${legacy[@]}"; do
			if grep -qxF -- "$name" <<<"$names"; then
				note "删除旧版遗留资产 $name"
				retry "删除 $name" gh release delete-asset "$tag" "$name" --repo "$release_repo" --yes \
					|| warn "删除 $name 失败（gh 版本过旧？）"
			fi
		done
	fi
	echo "https://github.com/$release_repo/releases/tag/$tag"
else
	note "未加 --publish；产物在 $out_dir"
fi

note "完成：$(basename "$runtime_tar") / $(basename "$trace_tar") / *.sha256sum 在 $out_dir"
