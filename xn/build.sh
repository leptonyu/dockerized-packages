#!/usr/bin/env bash
#
# xn 模块：编译 PGO+BOLT 优化的 x86_64 GNU xn，并挂到 xn 版本号对应的 release tag。
#
# 上游仓库：git@github.com:leptonyu/xn.git
#
# 本脚本**不打包**：打包交给上游 release.sh（runtime 包 + trace 包 + SHA256SUMS 落在
# target/<triple>/release/；host 的普通档落在 target/release/）。这里只负责：
#   1) 取上游源码、按档位跑 `release.sh --pack`（tuned 档加 `--tuned`）；
#   2) 把 build.log / build-info.txt 交给 tuned 构建收进 trace 包（--pack-log / --pack-info）；
#   3) 校验产物、改成稳定的发布名、复制到 --out-dir；
#   4) 需要时 gh release upload（逐资产上传；5xx / 网络抖动自动退避重试）。
#
# 发布不是原子操作：GitHub 的 release asset API 偶发 502/503/504，一个资产失败
# 不该连累其余的。所以上传是**逐个文件**做的（所有 .sha256sum 排最后），
# 每个文件单独重试；传完再按 *.sha256sum + asset digest 自检，不一致才整体重传一次。
#
# 交付档位（`--flavors`，同一 release 里合并发布）：
#   release  xn.<triple>.tar.xz           普通 release 编译（所有目标都出）
#            **一次 workspace 构建**，包里带全部交付 bin：xn / cidr / xn-tui / xns
#   tuned    xn.<triple>.tuned.tar.xz     PGO/BOLT（gnu / macOS），只带 xn
#            xn.<triple>.tuned.trace.tar.xz  构建 trace + xn.tuned.env + 清单 + build.log
# 每个包配一个 <asset>.sha256sum（发布用，最后传）；SHA256SUMS 只做本地校验，不发布。
#
# 平台（`--target`，默认 x86_64-unknown-linux-gnu）：
#   * x86_64-unknown-linux-gnu：原生；BOLT 要 --emit-relocs，zig 交叉档拿不到。
#   * aarch64-apple-darwin：在 macOS runner 上原生跑，PGO-only（flavor 变成 pgo）。
#   * armv7-unknown-linux-musleabihf：交叉，**只出 release 档**：armv7 二进制在 x86 runner
#     上跑不起来，采不了 PGO 样本；`release.sh --target armv7-... --pack` 走
#     cargo-zigbuild，它会去掉 rustc 的 self-contained crt*.o，避免和 zig 自带的 crt1.o
#     撞 `_start`。显式给 `--profile` + `--flavors tuned` 才走 pgo.sh use 的 PGO 交叉路径。
#
# 典型用法：
#   ./xn/build.sh                     # 构建 + 打包（不发布）
#   ./xn/build.sh --flavors release   # 只编普通档（不发 tuned）
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
target="${XN_TARGET:-x86_64-unknown-linux-gnu}"
profile_file="${XN_PGO_PROFILE:-}"
host_triple=""
cross=false
# 交付档位（逗号分隔）：release = 普通 release 编译；tuned = PGO/BOLT。
# 空 = 按目标取默认：gnu / macOS 出 release,tuned（普通包和 tuned 包各自发布），
# armv7 只出 release。--package-only 时按 target/release/ 与 target/<triple>/release/
# 里现成的产物自动识别。
flavors="${XN_FLAVORS:-}"

die() { echo "xn/build.sh: $*" >&2; exit 2; }
note() { echo "==> $*" >&2; }
warn() { echo "xn/build.sh: 警告：$*" >&2; }

# 默认档位：gnu / macOS 两种都出（普通 release + tuned 各自成包），armv7 只出普通档。
default_flavors() {
	if [[ "$target" == armv7-unknown-linux-musleabihf ]]; then
		if [[ -n "$profile_file" ]]; then printf 'tuned\n'; else printf 'release\n'; fi
	else
		printf 'release,tuned\n'
	fi
}

# 档位列表校验：只认 release / tuned。
resolve_flavors() {
	local f want=""
	[[ -n "$flavors" ]] || flavors="$(default_flavors)"
	for f in ${flavors//,/ }; do
		case "$f" in
			release|tuned) ;;
			*) die "未知 flavor：${f}（只支持 release / tuned）" ;;
		esac
	done
	# 规范成「先 release 后 tuned」并去重：asset 顺序稳定，tuned 失败也不影响普通包。
	for f in release tuned; do
		case ",$flavors," in
			*",$f,"*) want="${want:+$want,}$f" ;;
		esac
	done
	flavors="$want"
}

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
	# 文件头的注释块（到第一条非注释行为止），不用维护行号。
	awk 'NR > 1 { if ($0 ~ /^#/) { sub(/^# ?/, ""); print; next } exit }' "$self"
	cat <<'EOF'

选项（环境变量同名，带 XN_ 前缀）：
  --src DIR            本地 xn checkout（CI 里由 actions/checkout 提供；给了就不再 clone）
  --repo URL           上游仓库，默认 git@github.com:leptonyu/xn.git
  --ref REF            分支 / tag / commit，默认 main（须包含 release.sh --tuned --pack）
  --target TRIPLE      构建目标，默认 x86_64-unknown-linux-gnu；macOS 用
                       aarch64-apple-darwin，交叉 armv7 用 armv7-unknown-linux-musleabihf
  --profile FILE       只给交叉档的 tuned 用：显式指定 merged.profdata 才走 pgo.sh use
                       的 PGO 交叉路径（armv7 默认不需要，普通 release 编译就够）
  --flavors LIST       release,tuned（默认，gnu/macOS）/ release / tuned；
                       release = 普通编译包，tuned = PGO/BOLT 包，两者各自发布
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
  --keep-legacy        发布时不删除旧版单独上传的 .env / .build-info 等
  --package-only       不构建，只拿 target/{release,<triple>/release}/ 里现成的产物去发布
  --publish            通过 gh 发布到 --tag；release 不存在时新建（默认上游 xn）
  --check              只检查工具链与 release.sh 能力，不构建
  --dry-run            只打印命令，不 clone / 不构建 / 不上传
  -h, --help           本帮助

打包由上游 release.sh 完成（`--pack`；tuned 档加 `--tuned`），本脚本只上传：
  xn.<triple>.tar.xz                 普通档：xn / cidr / xn-tui / xns（一次构建，所有目标）
  xn.<triple>.tuned.tar.xz           tuned 档：只带 xn（PGO/BOLT，gnu/macOS）
  xn.<triple>.tuned.trace.tar.xz     构建 trace（仅 tuned）
  每个包一份同名 .sha256sum
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
		--target) need_value "$1" "$#"; target="$2"; shift 2 ;;
		--target=*) target="${1#*=}"; shift ;;
		--profile) need_value "$1" "$#"; profile_file="$2"; shift 2 ;;
		--profile=*) profile_file="${1#*=}"; shift ;;
		--flavors) need_value "$1" "$#"; flavors="$2"; shift 2 ;;
		--flavors=*) flavors="${1#*=}"; shift ;;
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
resolve_flavors

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
	command -v rustc >/dev/null 2>&1 || die "找不到 rustc"
	host_triple="$(rustc -vV 2>/dev/null | sed -n 's/^host: //p')"
	[[ -n "$host_triple" ]] || die "拿不到 rustc host"
	if [[ "$target" != "$host_triple" ]]; then
		# 交叉：目前只支持 x86_64 Linux 宿主 → armv7 Linux musl（其它目标没有采样来源）。
		cross=true
		[[ "$host_triple" == x86_64-unknown-linux-gnu ]] \
			|| die "交叉构建目前只支持 x86_64 Linux 宿主（当前 ${host_triple}）"
		[[ "$target" == armv7-unknown-linux-musleabihf ]] \
			|| die "交叉构建目前只支持 armv7-unknown-linux-musleabihf（当前 ${target}）"
		return 0
	fi
	cross=false
	# 原生。只有 tuned 档才要 perf（采 PGO 样本 / BOLT）；普通编译不查，省得为了发个
	# 普通包还去装 perf。macOS 走 PGO-only，PGO 不需要 perf，只在 BOLT 时要。
	if [[ "$flavors" == *tuned* ]] && [[ "$(uname -s)" == Linux ]]; then
		command -v perf >/dev/null 2>&1 \
			|| die "找不到 perf（BOLT 采样要用）；Ubuntu 跑 ./xn/install-perf.sh，不要装 linux-tools-generic（archive 滞后会报 broken packages）"
		perf --version >/dev/null 2>&1 \
			|| die "perf 在 PATH 里但跑不起来（多半是 linux-tools-common 的包装脚本没找到对应内核的 perf）；跑 ./xn/install-perf.sh 把它链到 /usr/local/bin/perf"
		if [[ -r /proc/sys/kernel/perf_event_paranoid ]]; then
			local p
			p="$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo '?')"
			if [[ "$p" =~ ^[0-9]+$ ]] && ((p > 2)); then
				die "kernel.perf_event_paranoid=${p}，perf record 会被拒绝；先 sudo sysctl kernel.perf_event_paranoid=1"
			fi
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
		echo "# --package-only：跳过构建，直接用 $s/target/{release,$target/release}/ 里的产物（档位 ${flavors}）"
	else
		for flavor in ${flavors//,/ }; do
			case "$flavor" in
				release)
					printf '+ (cd %q && ./release.sh --target %q --pack' "$s" "$target"
					[[ -n "$features" ]] && printf ' --features %q' "$features"
					$locked && printf ' --locked'
					printf ')\n'
					;;
				tuned)
					if [[ -n "$profile_file" ]]; then
						printf '+ (cd %q && ./scripts/pgo.sh use --target %q --cargo-profile release --profile %q)\n' \
							"$s" "$target" "$profile_file"
						printf '+ (cd %q && ./scripts/pack-release.sh --release-dir target/%s/release --target %q --bin xn --flavor tuned)\n' \
							"$s" "$target" "$target"
					else
						printf '+ (cd %q && ./release.sh' "$s"
						printf ' %s' "${rargs[@]}"
						printf ')\n'
					fi
					;;
			esac
		done
	fi
	printf '+ 校验并复制 %s/target/{release,%s/release}/{xn.*.tar.xz, SHA256SUMS} → %s\n' "$s" "$target" "$out_dir"
	printf '+ 发布名：xn.%s.tar.xz（release）' "$target"
	[[ "$flavors" == *tuned* ]] && printf ' + xn.%s.tuned[.trace].tar.xz（tuned）' "$target"
	printf '\n'
	if $publish; then
		if [[ -n "$tag" ]]; then
			printf '+ gh release create/upload %q --repo %q --clobber <包 + 各自的 .sha256sum>\n' "$tag" "$release_repo"
		else
			printf '+ gh release create/upload v<Cargo.toml version> --repo %q --clobber <包 + 各自的 .sha256sum>\n' "$release_repo"
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
	echo "==> 档位：${flavors}"
	cross_target=false
	[[ "$target" == armv7-unknown-linux-musleabihf ]] && cross_target=true
	if [[ "$flavors" == *release* ]]; then
		( cd "$src" && ./release.sh --target "$target" --dry-run )
	fi
	if [[ "$flavors" == *tuned* ]]; then
		if $cross_target; then
			echo "交叉档的 tuned 走 pgo.sh use；需要 --profile FILE"
		else
			( cd "$src" && ./release.sh --tuned --dry-run )
		fi
	fi
	echo
	local_doctor=0
	if [[ "$flavors" == *tuned* ]] && ! $cross_target; then
		( cd "$src" && ./scripts/build-tuned.sh doctor --target "$target" --require bolt ) || local_doctor=$?
	fi
	if $tests && [[ "$flavors" == *tuned* ]] && ! command -v cargo-nextest >/dev/null 2>&1; then
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

# ---------------------------------------------------------------- collect
# 把某个档位在上游产物目录里产出的包复制到 out_dir，改成稳定的发布名，并按上游写的
# SHA256SUMS 校验一遍：
#   release 档 -> xn.<triple>.tar.xz
#   tuned 档   -> xn.<triple>.tuned.tar.xz（+ .tuned.trace.tar.xz）
# 上游的 flavor 名（pgo-bolt / pgo / release …）只用来分辨档位，不暴露给消费端。
runtime_assets=()
trace_assets=()
seen_bases=()

collect_flavor() { # $1 = release | tuned
	# 上游 release.sh 的落点：host 普通档在 target/release（cargo build 不传 --target），
	# tuned / 交叉档在 target/<triple>/release。两处都扫，按包名去重。
	local flavor="$1" d f b out want got is_trace is_tuned any=false seen=" "
	local files=() dirs=("$src/target/$target/release" "$src/target/release")
	for d in "${dirs[@]}"; do
		[[ -d "$d" ]] || continue
		shopt -s nullglob
		files=("$d"/xn.*.tar.xz)
		shopt -u nullglob
		for f in ${files[@]+"${files[@]}"}; do
			b="$(basename "$f")"
			case "$seen" in *" $b "*) continue ;; esac
			seen="$seen$b "
			is_trace=false
			is_tuned=false
			case "$b" in *.trace.tar.xz) is_trace=true ;; esac
			case "$b" in *pgo*|*bolt*|*tuned*) is_tuned=true ;; esac
			if [[ "$flavor" == tuned ]]; then
				[[ "$is_tuned" == true ]] || continue
			else
				[[ "$is_tuned" == true || "$is_trace" == true ]] && continue
			fi
			if [[ "$flavor" == tuned ]]; then
				if $is_trace; then
					out="$out_dir/xn.$target.tuned.trace.tar.xz"
				else
					out="$out_dir/xn.$target.tuned.tar.xz"
				fi
			else
				out="$out_dir/xn.$target.tar.xz"
			fi
			want="$(awk -v n="$b" '$2 == n { print $1; exit }' "$d/SHA256SUMS" 2>/dev/null || true)"
			got="$(sha256_file "$f")"
			if [[ -n "$want" ]]; then
				[[ "$got" == "$want" ]] || die "${b} 与 SHA256SUMS 不一致（期望 ${want}，实际 ${got}）"
			elif $package_only; then
				warn "SHA256SUMS 里没有 ${b}，跳过校验（--package-only）"
			else
				die "SHA256SUMS 里没有 ${b}（$d/SHA256SUMS）"
			fi
			cp -p "$f" "$out"
			note "产物（${flavor}）：${b} → $(basename "$out")（$(human_bytes "$(bytes_of "$out")")）"
			seen_bases+=("$b")
			if $is_trace; then
				trace_assets+=("$out")
			else
				runtime_assets+=("$out")
			fi
			any=true
		done
	done
	$any || die "缺 ${flavor} 档的包：${dirs[0]}/xn.*.tar.xz 或 ${dirs[1]}/xn.*.tar.xz（release.sh --pack 是否成功？）"
}

# tuned 必须是 PGO 优化版本：`xn.tuned.env`（profile/size）与二进制自己的
# `-V` / `-h` 版本行（`(commit, tuned)`）互相印证。CI 的环境预检保证工具齐备；
# 这里再做最后一道一致性校验，旧产物 / 拿错二进制 / 非 PGO 产物一律拒绝。
require_tuned_bin() { # $1 = 候选二进制
	local bin="$1" env="$src/target/$target/release/xn.tuned.env" profile want size
	[[ -f "$env" ]] \
		|| die "tuned：缺 ${env}；上游没有产出 PGO 版本（构建链路异常；环境预检 / --require-tuned 本应更早失败）"
	profile="$(awk -F= '$1 == "profile" { print $2; exit }' "$env")"
	case "$profile" in
		pgo | pgo+bolt) ;;
		*) die "tuned：${env} 的 profile=${profile:-<空>}，不是 PGO 优化版本" ;;
	esac
	want="$(awk -F= '$1 == "size" { print $2; exit }' "$env")"
	size="$(bytes_of "$bin")"
	if [[ -n "$want" && "$want" != "$size" ]]; then
		die "tuned：${env} 记的 size=${want} 与实际 ${size} 不一致（env 与二进制不是同一份）"
	fi
	# 二进制自证：`release.sh --tuned` 的 optimize 阶段注入 XN_TUNED=1，
	# `-V` / `-h` 的版本行必须是 `(commit, tuned)`；空目录避免加载仓库根的 app.yaml。
	local smoke ver
	smoke="$(mktemp -d)" || die "tuned：mktemp 失败"
	if ! ver="$(cd "$smoke" && "$bin" --version 2>&1)"; then
		rm -rf "$smoke"
		die "tuned：${bin} --version 执行失败：${ver}"
	fi
	rm -rf "$smoke"
	case "$ver" in
		*", tuned)"*) ;;
		*) die "tuned：${bin} --version 没有 ', tuned' 标记（实际：${ver}）" ;;
	esac
}

# 把本次编出来的 xn 二进制留一份到 out-dir：`xn/compare.sh` 直接拿它和另一档做
# 同机 A/B，不用让上游 compare 再重编一遍。
keep_bin() { # $1 = release | tuned
	# host 的普通档走 cargo build（不传 --target），产物在 target/release；
	# tuned / 交叉档在 target/<triple>/release。按档位定优先顺序。
	local flavor="$1" out="$out_dir/xn.$target.$flavor.bin" bin="" c
	local cands=()
	if [[ "$flavor" == tuned ]]; then
		# 原生 tuned 只认本 target 的产物；`target/release/xn` 可能是 host 的普通档，
		# 拿它兜底会把错架构 / 错档位的二进制当成 tuned 上传。
		cands=("$src/target/$target/release/xn")
		# 交叉 tuned 走 pgo.sh use，没有 xn.tuned.env；仍允许 target 产物。
		$cross && cands+=("$src/target/release/xn")
	else
		cands=("$src/target/release/xn" "$src/target/$target/release/xn")
	fi
	for c in "${cands[@]}"; do
		if [[ -x "$c" ]]; then bin="$c"; break; fi
	done
	if [[ -z "$bin" ]]; then
		if [[ "$flavor" == tuned ]]; then
			die "没找到 tuned 档的 xn 二进制（试过：${cands[*]}）"
		fi
		warn "没找到 ${flavor} 档的 xn 二进制（试过：${cands[*]}）；compare 会缺这一组"
		return 0
	fi
	if [[ "$flavor" == tuned ]] && ! $cross; then
		require_tuned_bin "$bin"
	fi
	cp -p "$bin" "$out"
	chmod +x "$out" 2>/dev/null || true
	note "二进制（${flavor}）：$(basename "$out")（$(human_bytes "$(bytes_of "$out")")）"
}

# 交叉档的 tuned：pgo.sh use + pack-release.sh（本地手动路径，需要 --profile）。
pack_cross_tuned() { # $1 = profile 文件
	local prof="$1"
	note "交叉构建（tuned/PGO）：pgo.sh use --target ${target}（profile=${prof}）"
	use_args=(--target "$target" --cargo-profile release --profile "$prof")
	[[ -n "$features" ]] && use_args+=(--features "$features")
	$locked && use_args+=(--locked)
	( cd "$src" && env XN_TUNED=1 ./scripts/pgo.sh use "${use_args[@]}" ) 2>&1 | tee -a "$out_dir/build.log"
	note "交叉打包：pack-release.sh（runtime 包，无 trace）"
	pack_args=(--release-dir "target/$target/release" --target "$target" --bin xn --flavor tuned)
	( cd "$src" && ./scripts/pack-release.sh "${pack_args[@]}" ) 2>&1 | tee -a "$out_dir/build.log"
}

# ---------------------------------------------------------------- build
if ! $package_only; then
	# 先定档位，require_platform 才知道要不要检查 perf/BOLT 工具链。
	resolve_flavors
	require_platform
	prepare_source
	: > "$out_dir/build.log"
	note "上游：${src}（${commit:0:12}，ref=${ref_label}）"
	note "档位：${flavors}（release = 普通编译；tuned = PGO/BOLT）"

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
		printf 'flavors=%s\n' "$flavors"
		printf 'features=%s\n' "${features:-<default>}"
		printf 'tests=%s\n' "$tests"
		printf 'event=%s\n' "${event:-<release.sh default>}"
		printf 'freq=%s\n' "${freq:-<release.sh default>}"
		printf 'icf=%s\n' "${icf:-all}"
		printf 'release_repo=%s\n' "$release_repo"
		printf 'release_tag=%s\n' "${tag:-<none>}"
		printf 'note=打包由上游 release.sh --pack 完成（tuned 档加 --tuned；交叉档普通编译无 PGO）\n'
	} > "$build_info"

	tuned_args=(--tuned --target "$target" --pack
		--pack-log "$out_dir/build.log"
		--pack-info "$build_info")
	# 缺 PGO/BOLT 工具时上游**默认降级普通 release 并成功退出**；CI 绝不能把普通档
	# 当 tuned 发出去。支持就硬失败；老 ref 不支持时仍由 require_tuned_bin 兜底。
	if grep -q -- '--require-tuned' "$src/release.sh"; then
		tuned_args+=(--require-tuned)
	else
		die "上游 release.sh 不支持 --require-tuned（${src}/release.sh）：tuned 必须是 PGO，缺工具不能降级"
	fi
	[[ -n "$features" ]] && tuned_args+=(--features "$features")
	[[ -n "$workload" ]] && tuned_args+=(--workload "$workload")
	[[ -n "$freq" ]] && tuned_args+=(--freq "$freq")
	[[ -n "$event" ]] && tuned_args+=(--event "$event")
	[[ -n "$icf" ]] && tuned_args+=(--icf "$icf")
	$force && tuned_args+=(--force)
	$tests || tuned_args+=(--no-tests)
	$locked && tuned_args+=(--locked)

	# tuned 不传任何 PGO 范围开关：走上游默认，让全部 crate 都吃 -Cprofile-use
	# （full PGO）。只给 xn crate 注入（--xn-only）时体积只差 ~0.1%，等于把 PGO 的
	# 收益关掉；发版前仍要用 pgo.compare 留同机 A/B 证据。

	release_args=(--target "$target" --pack)
	[[ -n "$features" ]] && release_args+=(--features "$features")
	$locked && release_args+=(--locked)

	# 档位依次构建、就地收集：每档一打完就把包改好名搬走，免得后一档覆盖 SHA256SUMS。
	# 先 release 后 tuned：tuned 挂了也不影响已经产出的普通包。
	for flavor in ${flavors//,/ }; do
		case "$flavor" in
			release)
				note "构建 release 档（普通编译，无 PGO）：release.sh ${release_args[*]}"
				( cd "$src" && ./release.sh "${release_args[@]}" ) 2>&1 | tee -a "$out_dir/build.log"
				keep_bin release
				collect_flavor release
				;;
			tuned)
				if $cross; then
					# 交叉档默认只出 release；要 tuned 得显式给 --profile（pgo.sh use 那条路
					# 直接把 zig 当 linker，会和 rustc 的 self-contained crt*.o 撞 _start）。
					[[ -n "$profile_file" ]] || die "交叉档编 tuned 需要 --profile FILE（armv7 默认只出 release 档）"
					[[ -f "$profile_file" ]] || die "--profile 指向的文件不存在：${profile_file}"
					pack_cross_tuned "$profile_file"
				else
					note "构建 tuned 档（PGO/BOLT）：release.sh ${tuned_args[*]}"
					( cd "$src" && ./release.sh "${tuned_args[@]}" ) 2>&1 | tee -a "$out_dir/build.log"
				fi
				keep_bin tuned
				collect_flavor tuned
				;;
		esac
	done
else
	# --package-only 不构建，但仍要有源码来拿产物与元数据。
	if [[ -z "$src" ]]; then
		src="${XN_SRC_CACHE:-$root/.cache/xn-src}"
		[[ -d "$src/.git" ]] || die "--package-only 需要 --src 或已存在的 $src"
	fi
	prepare_source
	if [[ -z "${XN_FLAVORS:-}" ]]; then
		# 没显式指定就按现成产物识别：普通包、tuned 包有哪个重传哪个（host / 交叉两处都看）。
		flavors=""
		shopt -s nullglob
		for f in "$src/target/$target/release"/xn.*.tar.xz "$src/target/release"/xn.*.tar.xz; do
			b="$(basename "$f")"
			case "$b" in *.trace.tar.xz) continue ;; esac
			case "$b" in
				*pgo*|*bolt*|*tuned*) flavors="${flavors:+$flavors,}tuned" ;;
				*) flavors="${flavors:+$flavors,}release" ;;
			esac
		done
		shopt -u nullglob
		[[ -n "$flavors" ]] || die "没有可发布的产物（target/release 或 target/$target/release 下没有 xn.*.tar.xz）"
	fi
	resolve_flavors
	note "package-only：使用现有产物，不重新构建（档位 ${flavors}）"
	for flavor in ${flavors//,/ }; do
		collect_flavor "$flavor"
	done
fi

# ---------------------------------------------------------------- publish
# release 上放：release / tuned / trace 各自一个包 + 同名的 <asset>.sha256sum。
# 不再发汇总的 SHA256SUMS：校验和与资产一一对应，消费端按 <asset>.sha256sum 校验。
# 顺序：所有包先传，所有 .sha256sum 最后传 —— 消费端最坏看到旧包 + 旧校验和，
# 不会出现「新校验和配旧包」。
runtime_names=()
for f in ${runtime_assets[@]+"${runtime_assets[@]}"}; do
	name="$(basename "$f")"
	printf '%s  %s\n' "$(sha256_file "$f")" "$name" > "$out_dir/$name.sha256sum"
	runtime_names+=("$name")
done
trace_names=()
for f in ${trace_assets[@]+"${trace_assets[@]}"}; do
	name="$(basename "$f")"
	printf '%s  %s\n' "$(sha256_file "$f")" "$name" > "$out_dir/$name.sha256sum"
	trace_names+=("$name")
done

assets=()
for f in ${runtime_assets[@]+"${runtime_assets[@]}"}; do assets+=("$f"); done
for f in ${trace_assets[@]+"${trace_assets[@]}"}; do assets+=("$f"); done
for n in ${runtime_names[@]+"${runtime_names[@]}"}; do assets+=("$out_dir/$n.sha256sum"); done
for n in ${trace_names[@]+"${trace_names[@]}"}; do assets+=("$out_dir/$n.sha256sum"); done

# 发布说明：按 release 上**实际存在的资产**生成。两档是两个 job 并发发的，谁先建
# release 都无所谓；已经在的 release（重传/老 tag）也会被补上说明。
release_notes_from() { # stdin: 资产名，每行一个
	local n
	while IFS= read -r n; do
		[[ -n "$n" ]] || continue
		case "$n" in
			*.sha256sum) continue ;;
			*.tuned.trace.tar.xz)
				printf -- '- `%s` — tuned 的构建 trace（trace-files.txt 列出的诊断文件 + xn.tuned.env + 清单 + build.log / build-info.txt）\n' "$n" ;;
			*.tuned.tar.xz)
				printf -- '- `%s` — PGO/BOLT 编译（xn / LICENSE / docs/configuration.md / THIRD-PARTY-NOTICES.txt）\n' "$n" ;;
			xn.*.tar.xz)
				printf -- '- `%s` — 普通 release 编译（xn / cidr / xn-tui / xns / LICENSE / docs/configuration.md / THIRD-PARTY-NOTICES.txt）\n' "$n" ;;
			*)
				printf -- '- `%s`\n' "$n" ;;
		esac
	done
}

refresh_release_notes() {
	local names body
	names="$(gh release view "$tag" --repo "$release_repo" --json assets \
		--jq '.assets[].name' 2>/dev/null | LC_ALL=C sort)" || names=""
	if [[ -z "$names" ]]; then
		names="$(for a in ${assets[@]+"${assets[@]}"}; do basename "$a"; done | LC_ALL=C sort)"
	fi
	body="$(printf 'xn %s · 上游 `%s`\n\n' "$version" "${commit:0:12}")"
	body+="$(printf '%s\n' "$names" | release_notes_from)"
	body+=$'\n'
	body+="每个包配一个同名 \`.sha256sum\`：\`shasum -a 256 -c <asset>.sha256sum\`。"
	retry "更新 release 说明" gh release edit "$tag" --repo "$release_repo" --notes "$body" >/dev/null ||
		warn "release 说明没更新（不影响资产）"
}

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
		notes="$(printf 'xn %s from %s.\n\n' "$version" "${commit:0:12}")"
		for n in ${runtime_names[@]+"${runtime_names[@]}"}; do
			case "$n" in
				*.tuned.tar.xz) notes="$notes$(printf -- '- `%s`: PGO/BOLT 编译（xn / LICENSE / docs/configuration.md / THIRD-PARTY-NOTICES.txt）\n' "$n")" ;;
				*) notes="$notes$(printf -- '- `%s`: 普通 release 编译（xn / cidr / xn-tui / xns / LICENSE / docs/configuration.md / THIRD-PARTY-NOTICES.txt）\n' "$n")" ;;
			esac
		done
		for n in ${trace_names[@]+"${trace_names[@]}"}; do
			notes="$notes$(printf -- '- `%s`: 构建 trace（trace-files.txt 列出的诊断文件 + xn.tuned.env + 清单 + build.log / build-info.txt）\n' "$n")"
		done
		notes="$notes$(printf -- '- `*.tar.xz.sha256sum`: 每个包自己的校验和（`shasum -a 256 -c <asset>.sha256sum`）\n')"
		retry "创建 release" gh release create "$tag" --repo "$release_repo" --target "$commit" \
			--title "xn $version" \
			--notes "$notes" || {
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
		legacy=("SHA256SUMS") # 旧版汇总校验和，改成每个包一个 .sha256sum
		published=" "
		for n in ${runtime_names[@]+"${runtime_names[@]}"} ${trace_names[@]+"${trace_names[@]}"}; do
			stem="${n%.tar.xz}"
			legacy+=("$stem.env" "$stem.build-info.txt" "$stem.manifest.tsv" "$stem.bolt.env")
			published="$published$n "
		done
		# 上游 flavor 名（pgo-bolt / pgo / release）改成统一发布名后，清掉旧名字。
		for b in ${seen_bases[@]+"${seen_bases[@]}"}; do
			case "$published" in
				*" $b "*) ;;
				*) legacy+=("$b" "$b.sha256sum") ;;
			esac
		done
		names="$(gh release view "$tag" --repo "$release_repo" --json assets --jq '.assets[].name' 2>/dev/null || true)"
		for name in "${legacy[@]}"; do
			if grep -qxF -- "$name" <<<"$names"; then
				note "删除旧版遗留资产 $name"
				retry "删除 $name" gh release delete-asset "$tag" "$name" --repo "$release_repo" --yes \
					|| warn "删除 $name 失败（gh 版本过旧？）"
			fi
		done
	fi
	refresh_release_notes
	echo "https://github.com/$release_repo/releases/tag/$tag"
else
	note "未加 --publish；产物在 $out_dir"
fi

done_names=""
for n in ${runtime_names[@]+"${runtime_names[@]}"} ${trace_names[@]+"${trace_names[@]}"}; do
	done_names="${done_names:+$done_names, }$n"
done
note "完成：${done_names} + *.sha256sum 在 $out_dir"
