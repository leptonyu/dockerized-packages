#!/usr/bin/env bash
#
# xn 模块：编译 PGO+BOLT 优化的 x86_64 GNU xn，并挂到 xn 版本号对应的 release tag。
#
# 上游仓库：git@github.com:leptonyu/xn.git
#
# 本脚本**不重复实现**调优链：直接调用上游 repo 里的
#   ./release.sh --tuned --target x86_64-unknown-linux-gnu
# 由它完成 PGO 采集（loopback 套件 + 常规 nextest）→ profile 重建 → BOLT，
# 产物固定写 target/x86_64-unknown-linux-gnu/release/xn 与 xn.tuned.env。
# 这里只负责：取上游源码、跑这条命令、打两个包、创建/追加 v<Cargo.toml version> release。
#
# 只打两个包（每个包配一个 .sha256sum，release 上共 4 个资产）：
#   xn.<target>.pgo-bolt.tar.xz        二进制包：xn / LICENSE / docs/configuration.md / THIRD-PARTY-NOTICES.txt
#   xn.<target>.pgo-bolt.trace.tar.xz  全过程包：build.log / build-info.txt / xn.tuned.env /
#                                      run/（上游各步骤日志、perf.data、manifest.tsv、bolt.env）
#   run/ 取自上游 target/tune/<run>/：01-collect / 02-optimize / 03-bolt（bolt.env、
#   hot-functions.tsv、xn.fdata…）/ logs / manifest.tsv。上游 xn.tuned.env 没写 run_dir 时
#   按产物 sha256 匹配，再退到该 target/profile 下最新的一份；也可用 --run-dir 指定。
# 两个包各生成一个 .sha256sum；不再单独发布 .env / .build-info.txt / .manifest.tsv / .bolt.env，
# 这些元数据都在 trace 包内（build-info.txt 记录二进制包的 sha256）。
#
# 为什么必须原生 Linux x86_64：BOLT 需要 --emit-relocs 的重定位节，zig 交叉档
# （macOS / musl 容器）拿不到。后续扩展见 README.md 的 Roadmap。
#
# 典型用法：
#   ./xn/build.sh                                      # 构建 + 打包（不发布）
#   ./xn/build.sh --publish                            # 发布到 v<Cargo.toml version>
#   ./xn/build.sh --tag v6.1.0 --publish               # 指定 release tag
#   ./xn/build.sh --check                              # 只检查工具链
#   ./xn/build.sh --dry-run                            # 只打印命令
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
notices=true
locked=true
perf_data=true
perf_xz_level="${XN_PERF_XZ_LEVEL:-3}"
prune_legacy=true
run_dir_opt="${XN_TUNE_RUN_DIR:-}"
allow_missing_run=false

target="x86_64-unknown-linux-gnu"
base="xn.${target}.pgo-bolt"
trace_base="${base}.trace"

die() { echo "xn/build.sh: $*" >&2; exit 2; }
note() { echo "==> $*" >&2; }
warn() { echo "xn/build.sh: 警告：$*" >&2; }

usage() {
	sed -n '2,28p' "$self" | sed 's/^# \{0,1\}//'
	cat <<'EOF'

选项（环境变量同名，带 XN_ 前缀）：
  --src DIR            本地 xn checkout（CI 里由 actions/checkout 提供；给了就不再 clone）
  --repo URL           上游仓库，默认 git@github.com:leptonyu/xn.git
  --ref REF            分支 / tag / commit，默认 main（须包含 release.sh --tuned）
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
  --no-notices         不生成 THIRD-PARTY-NOTICES.txt（只用于本地排查）
  --no-locked          不向 cargo 传 --locked
  --force              让 build-tuned 重做已有 run 目录
  --no-perf-data       trace 包不带 perf.data（只保留各步骤日志）
  --perf-xz-level N    trace 包的 xz 级别 0-9，默认 3（perf.data 很大，0 最快）
  --run-dir DIR        指定上游 run 目录（默认取 xn.tuned.env 的 run_dir；没有就按产物
                       sha256 在 target/tune/* 里匹配，再退到最新的同 target/profile run）
  --allow-missing-run  找不到 run 目录也照打（trace 包只剩日志与环境；默认直接报错）
  --keep-legacy        发布时不删除旧版单独上传的 .env / .build-info 等
  --package-only       不构建，只重新打两个包（二进制包 + 全过程包）
  --publish            通过 gh 发布到 --tag；release 不存在时新建（默认上游 xn）
  --check              只检查工具链与 release.sh 能力，不构建
  --dry-run            只打印命令，不 clone / 不构建 / 不上传
  -h, --help           本帮助

产物（release 上 2 个包 + 各自的 .sha256sum）：
  xn.x86_64-unknown-linux-gnu.pgo-bolt.tar.xz
      二进制包：xn / LICENSE / docs/configuration.md / THIRD-PARTY-NOTICES.txt
  xn.x86_64-unknown-linux-gnu.pgo-bolt.tar.xz.sha256sum
  xn.x86_64-unknown-linux-gnu.pgo-bolt.trace.tar.xz
      全过程包：build.log / build-info.txt / xn.tuned.env / run/
      （run/ 是上游 run 目录：各步骤日志、perf.data、manifest.tsv、bolt.env）
  xn.x86_64-unknown-linux-gnu.pgo-bolt.trace.tar.xz.sha256sum
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
		--no-notices) notices=false; shift ;;
		--no-locked) locked=false; shift ;;
		--no-perf-data) perf_data=false; shift ;;
		--perf-xz-level) need_value "$1" "$#"; perf_xz_level="$2"; shift 2 ;;
		--perf-xz-level=*) perf_xz_level="${1#*=}"; shift ;;
		--run-dir) need_value "$1" "$#"; run_dir_opt="$2"; shift 2 ;;
		--run-dir=*) run_dir_opt="${1#*=}"; shift ;;
		--allow-missing-run) allow_missing_run=true; shift ;;
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

[[ "$perf_xz_level" =~ ^[0-9]$ ]] || die "--perf-xz-level 需要 0-9：$perf_xz_level"

# 路径统一成绝对路径；--src 相对当前目录。
abs_dir() { # $1=path $2=默认目录（不存在则相对它）
	local p="$1"
	if [[ "$p" != /* ]]; then p="$PWD/$p"; fi
	mkdir -p "$p"
	(cd "$p" && pwd)
}

out_dir="$(abs_dir "$out_dir")"
if [[ -n "$src" ]]; then
	src="$(cd "$src" 2>/dev/null && pwd)" || die "--src 不存在：$src"
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

# 在 <src>/target/tune/ 里挑与本次产物对得上的 run 目录（trace 包的主体）。
# 上游到 commit 0920e81 那份 release.sh 的 xn.tuned.env 里**没有 run_dir 字段**，
# 只 sed env 会让 trace 包悄悄少掉整个 run/（v6.0.0 的 trace 就只有 3 个文件）。
# 输出「来源<TAB>绝对路径」：
#   sha256 = <run>/03-bolt/xn.final 的 sha256 与 xn.tuned.env 的 sha256 相同（最可靠）；
#   newest = 该 target/profile 下最新的一份（并提示是按时间猜的）。
# 都找不到返回 1。
xn_pick_run_dir() { # $1=xn.tuned.env 里的 sha256（可空）
	local want="${1:-}" d sha best="" matches=0
	local -a cands=()
	for d in "$src"/target/tune/*/; do
		[[ -d "$d" ]] || continue
		d="${d%/}"
		[[ -f "$d/run.env" || -f "$d/manifest.tsv" ]] || continue
		case "$(basename "$d")" in
			*"-${target}-"*) ;;
			*) continue ;;
		esac
		cands+=("$d")
	done
	((${#cands[@]})) || return 1
	if [[ -n "$want" ]]; then
		for d in ${cands[@]+"${cands[@]}"}; do
			[[ -f "$d/03-bolt/xn.final" ]] || continue
			sha="$(sha256_file "$d/03-bolt/xn.final" 2>/dev/null || true)"
			if [[ "$sha" == "$want" ]]; then
				best="$d"
				matches=$((matches + 1))
			fi
		done
	fi
	if [[ -n "$best" ]]; then
		if ((matches > 1)); then
			warn "有 ${matches} 个 run 的 03-bolt/xn.final 都等于产物 sha256，取最后一个：$best"
		fi
		printf 'sha256\t%s\n' "$best"
		return 0
	fi
	best="$(printf '%s\n' ${cands[@]+"${cands[@]}"} | sort -r | head -n1)"
	[[ -n "$best" ]] || return 1
	warn "xn.tuned.env 没有 run_dir，也没有 run 的 03-bolt/xn.final 对得上产物 sha256；取最新的 run：$best"
	printf 'newest\t%s\n' "$best"
}

have_tuned() { # $1=src
	[[ -f "$1/release.sh" ]] && grep -q -- '--tuned' "$1/release.sh"
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

# 发布出去的环境文件不要带本地路径 / 主机名：run_dir、workload、host、uname 脱敏。
# trace 包里的 run_dir 换成相对路径 run（run/ 就在同一个包内），其余照旧脱敏。
sanitize_env() { # $1=输入 $2=输出 [$3=run_dir 的替换值，默认 <redacted>]
	local rd="${3:-<redacted>}"
	awk -v rd="$rd" '
		/^run_dir=/ { print "run_dir=" rd; next }
		/^workload=/ { print "workload=<redacted>"; next }
		/^host=/ { print "host=<redacted>"; next }
		/^uname=/ { print "uname=<redacted>"; next }
		{ print }
	' "$1" > "$2"
}

require_platform() {
	is_linux_x86_64 || die "当前只支持原生 Linux x86_64（BOLT 需要 --emit-relocs）；本机 $(uname -s)/$(uname -m)。
                     macOS 只能用上游 build-tuned.sh 跑到 optimize，不能用 --tuned。"
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
	prepare_version
}

# ---------------------------------------------------------------- dry-run
# 只打印计划，不 clone、不建目录、不跑 doctor；在 macOS 上也能用。
print_plan() {
	local s="${src:-$root/.cache/xn-src}"
	local rargs=(--tuned --target "$target")
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
		echo "# --package-only：跳过构建，直接打包"
	else
		printf '+ (cd %q && ./release.sh' "$s"
		printf ' %q' "${rargs[@]}"
		printf ')\n'
	fi
	printf '+ 打包 %s.tar.xz（xn / LICENSE / docs/configuration.md / THIRD-PARTY-NOTICES.txt）\n' "$base"
	printf '+ 生成 %s.tar.xz.sha256sum\n' "$base"
	if $perf_data; then
		printf '+ 打包 %s.tar.xz（build.log / build-info.txt / xn.tuned.env / run/，含 perf.data；xz -T0 -%s）\n' "$trace_base" "$perf_xz_level"
	else
		printf '+ 打包 %s.tar.xz（build.log / build-info.txt / xn.tuned.env / run/，不含 perf.data；xz -T0 -%s）\n' "$trace_base" "$perf_xz_level"
	fi
	printf '+ 生成 %s.tar.xz.sha256sum\n' "$trace_base"
	if $publish; then
		if [[ -n "$tag" ]]; then
			printf '+ gh release create/upload %q --repo %q --clobber <两个包 + 两个 .sha256sum>\n' "$tag" "$release_repo"
		else
			printf '+ gh release create/upload v<Cargo.toml version> --repo %q --clobber <两个包 + 两个 .sha256sum>\n' "$release_repo"
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

	echo "==> 上游：${src}（${commit:0:12}，ref=${ref_label}）"
	build_args=(--tuned --target "$target")
	[[ -n "$features" ]] && build_args+=(--features "$features")
	[[ -n "$workload" ]] && build_args+=(--workload "$workload")
	[[ -n "$freq" ]] && build_args+=(--freq "$freq")
	[[ -n "$event" ]] && build_args+=(--event "$event")
	[[ -n "$icf" ]] && build_args+=(--icf "$icf")
	$force && build_args+=(--force)
	$tests || build_args+=(--no-tests)
	$locked && build_args+=(--locked)

	# release.sh --tuned 固定写这两个路径；不另造中间产物。
	note "release.sh ${build_args[*]}"
	( cd "$src" && ./release.sh "${build_args[@]}" ) 2>&1 | tee "$out_dir/build.log"
else
	# --package-only 不构建，但仍要有源码来拿 LICENSE / 元数据。
	# 没给 --src 时只认已存在的托管 checkout，不 clone/fetch/checkout，避免换掉产物对应的代码。
	if [[ -z "$src" ]]; then
		src="${XN_SRC_CACHE:-$root/.cache/xn-src}"
		[[ -d "$src/.git" ]] || die "--package-only 需要 --src 或已存在的 $src"
	fi
	prepare_source
	note "package-only：使用现有产物，不重新构建"
fi

bin="$src/target/$target/release/xn"
envf="$src/target/$target/release/xn.tuned.env"
[[ -x "$bin" ]] || die "缺产物：${bin}（--tuned 是否成功？）"
[[ -f "$envf" ]] || die "缺元数据：$envf"

# 产物必须真能跑（release.sh 已验一次；这里再挡一次，避免拿到被别的步骤覆盖的二进制）。
smoke_dir="$(mktemp -d)"
if ! ( cd "$smoke_dir" && "$bin" --version >/dev/null 2>&1 ); then
	rm -rf "$smoke_dir"
	die "产物无法执行：$bin"
fi
rm -rf "$smoke_dir"

# ---------------------------------------------------------------- run 目录
# trace 包真正的主体是上游 run 目录：01-collect / 02-optimize / 03-bolt（bolt.env、
# hot-functions.tsv、xn.fdata、xn.final）/ logs / manifest.tsv / run.env。
# 上游早期 release.sh 写 xn.tuned.env 时**没有 run_dir 字段**（v6.0.0 就是这样），
# 只读 env 会让 trace 包悄悄少掉整个 run/，所以按优先级找：
#   --run-dir / XN_TUNE_RUN_DIR > env 的 run_dir > 产物 sha256 匹配 > 该 target 最新一份。
env_sha="$(sed -n 's/^sha256=//p' "$envf" | head -n1 | sed 's/[[:space:]]*$//')"
run_dir=""
run_dir_source="none"
if [[ -n "$run_dir_opt" ]]; then
	run_dir="$run_dir_opt"
	run_dir_source="explicit"
	[[ "$run_dir" == /* ]] || run_dir="$PWD/$run_dir"
else
	run_dir="$(sed -n 's/^run_dir=//p' "$envf" | head -n1 | sed 's/[[:space:]]*$//')"
	if [[ -n "$run_dir" ]]; then
		run_dir_source="env"
		[[ "$run_dir" == /* ]] || run_dir="$src/$run_dir"
	fi
fi
if [[ -n "$run_dir" && ! -d "$run_dir" ]]; then
	warn "run 目录不存在：${run_dir}（来源 ${run_dir_source}）"
	run_dir=""
	run_dir_source="none"
fi
if [[ -z "$run_dir" ]]; then
	pick="$(xn_pick_run_dir "$env_sha")" || pick=""
	if [[ -n "$pick" ]]; then
		run_dir_source="${pick%%$'\t'*}"
		run_dir="${pick#*$'\t'}"
	fi
fi
if [[ -z "$run_dir" ]]; then
	if $allow_missing_run; then
		warn "找不到上游 run 目录（$src/target/tune/*）：trace 包只有日志与环境"
	else
		die "找不到上游 run 目录（$src/target/tune/*）：trace 包会缺掉所有步骤文件。
                     构建用的 run 已被清掉？用 --run-dir 指过去，或加 --allow-missing-run 只打日志。"
	fi
fi

# ---------------------------------------------------------------- package
# 只打两个包：二进制包 + 全过程包（上游 run 目录里的所有步骤与 perf.data）。
if $publish; then
	note "目标 release：${release_repo}@${tag}（版本 ${version}）"
fi

command -v xz >/dev/null 2>&1 || die "找不到 xz"

# 1) 二进制包：xn / LICENSE / docs/configuration.md / THIRD-PARTY-NOTICES.txt。
#    不带 xn.tuned.env；构建元数据只在过程包里。
stage="$out_dir/.stage-$base"
rm -rf "$stage"
mkdir -p "$stage/docs"
cp "$bin" "$stage/xn"
chmod +x "$stage/xn"
cp "$src/LICENSE" "$stage/LICENSE"

# 上游配置文档随包发布，路径保持不变（docs/configuration.md）。
docs_file="$src/docs/configuration.md"
[[ -f "$docs_file" ]] || die "缺文档：${docs_file}（上游 docs/configuration.md 不存在）"
cp "$docs_file" "$stage/docs/configuration.md"

files=(xn LICENSE docs/configuration.md)
if $notices; then
	notices_file="$src/target/THIRD-PARTY-NOTICES.txt"
	if [[ ! -s "$notices_file" ]]; then
		note "生成 THIRD-PARTY-NOTICES.txt（需要 cargo-deny；失败可加 --no-notices）"
		( cd "$src" && bash scripts/patch-deps.sh && cargo fetch && \
			bash scripts/gen-notices.sh "$notices_file" ) 2>&1 | tee -a "$out_dir/build.log"
	fi
	[[ -s "$notices_file" ]] || die "没有生成 ${notices_file}；装 cargo-deny 或加 --no-notices"
	cp "$notices_file" "$stage/THIRD-PARTY-NOTICES.txt"
	files+=(THIRD-PARTY-NOTICES.txt)
else
	warn "按 --no-notices 跳过第三方声明文件"
fi

note "打包 $base.tar.xz（${files[*]}）"
tar -C "$stage" -cJf "$out_dir/$base.tar.xz" "${files[@]}"
sha="$(sha256_file "$out_dir/$base.tar.xz")"
rm -rf "$stage"

# 2) 全过程包：上游 run 目录（各步骤日志 / perf.data / manifest.tsv / bolt.env）
#    + 本脚本的 build.log / build-info.txt / 脱敏的 xn.tuned.env。
#    run_dir 在打包前就已经定位好（见上面的「run 目录」段）。
trace_stage="$out_dir/.stage-$trace_base"
rm -rf "$trace_stage"
mkdir -p "$trace_stage"
if [[ -f "$out_dir/build.log" ]]; then
	cp "$out_dir/build.log" "$trace_stage/build.log"
else
	note "没有 $out_dir/build.log（--package-only 且本目录没构建过），trace 包不含构建日志"
fi
sanitize_env "$envf" "$trace_stage/xn.tuned.env" "run"
# 早期 xn.tuned.env 本来就没有 run_dir 字段：补上包内相对路径，别让读的人以为没收录。
if [[ -n "$run_dir" ]] && ! grep -q '^run_dir=' "$trace_stage/xn.tuned.env"; then
	printf 'run_dir=run\n' >> "$trace_stage/xn.tuned.env"
fi

if [[ -n "$run_dir" ]]; then
	run_dir="$(cd "$run_dir" && pwd -P)"
	note "收集上游 run 目录：${run_dir}（来源 ${run_dir_source}）"
	cp -R -p "$run_dir" "$trace_stage/run"
	if [[ ! -f "$trace_stage/run/manifest.tsv" ]]; then
		warn "run/ 里没有 manifest.tsv（run 目录不完整？）"
	fi
	if [[ ! -f "$trace_stage/run/03-bolt/bolt.env" ]]; then
		warn "run/ 里没有 03-bolt/bolt.env（BOLT 步骤没跑完？）"
	fi
fi

perf_count=0
perf_total=0
if [[ -d "$trace_stage/run" ]]; then
	perf_total="$(find "$trace_stage/run" -type f -name 'perf.data*' -print 2>/dev/null | wc -l | tr -d '[:space:]')" || perf_total=0
	if $perf_data; then
		perf_count="$perf_total"
	else
		# 只去掉 perf.data*；各步骤日志、perf.fdata、perf.bolt.yaml 等仍保留。
		find "$trace_stage/run" -type f -name 'perf.data*' -delete 2>/dev/null || true
	fi
	note "run 目录：$(du -sh "$trace_stage/run" | awk '{print $1}')（源 perf.data ${perf_total} 个，收录 ${perf_count} 个）"
fi

run_file_count=0
run_steps=""
if [[ -d "$trace_stage/run" ]]; then
	run_file_count="$(find "$trace_stage/run" -type f 2>/dev/null | wc -l | tr -d '[:space:]')" || run_file_count=0
	run_steps="$(cd "$trace_stage/run" && ls -1 | paste -sd, -)"
	note "run 步骤：${run_steps:-<空>}（${run_file_count} 个文件）"
fi

{
	printf 'format=1\n'
	printf 'packaged_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	printf 'source_repo=%s\n' "$repo"
	printf 'source_ref=%s\n' "$ref_label"
	printf 'source_commit=%s\n' "$commit"
	printf 'version=%s\n' "$version"
	printf 'target=%s\n' "$target"
	printf 'profile=pgo+bolt\n'
	printf 'features=%s\n' "${features:-<default>}"
	printf 'tests=%s\n' "$tests"
	printf 'notices=%s\n' "$notices"
	printf 'event=%s\n' "${event:-<release.sh default>}"
	printf 'freq=%s\n' "${freq:-<release.sh default>}"
	printf 'icf=%s\n' "${icf:-all}"
	printf 'run_dir=run\n'
	printf 'run_dir_source=%s\n' "$run_dir_source"
	printf 'run_steps=%s\n' "${run_steps:-<none>}"
	printf 'run_files=%s\n' "$run_file_count"
	printf 'tarball=%s\n' "$base.tar.xz"
	printf 'tarball_sha256=%s\n' "$sha"
	printf 'trace_tarball=%s\n' "$trace_base.tar.xz"
	printf 'perf_data=%s\n' "$perf_data"
	printf 'perf_data_files=%s\n' "$perf_count"
	printf 'perf_data_files_source=%s\n' "$perf_total"
	printf 'release_repo=%s\n' "$release_repo"
	printf 'release_tag=%s\n' "${tag:-<none>}"
	printf 'trace_note=上游 run 目录按来源 %s 收录（%s）；run_dir / host / uname / workload 已脱敏\n' "$run_dir_source" "${run_steps:-<none>}"
} > "$trace_stage/build-info.txt"

note "打包 $trace_base.tar.xz（xz -T0 -${perf_xz_level}，perf.data 大时较慢）"
tar -C "$trace_stage" -cf - . | xz -T0 "-$perf_xz_level" > "$out_dir/$trace_base.tar.xz"
rm -rf "$trace_stage"

bytes_of() { wc -c < "$1" | tr -d '[:space:]'; }
bin_bytes="$(bytes_of "$out_dir/$base.tar.xz")"
trace_bytes="$(bytes_of "$out_dir/$trace_base.tar.xz")"
trace_sha="$(sha256_file "$out_dir/$trace_base.tar.xz")"

# 校验和随包发布：每个包一个 .sha256sum（与 sha256sum 默认格式一致）。
printf '%s  %s\n' "$sha" "$base.tar.xz" > "$out_dir/$base.tar.xz.sha256sum"
printf '%s  %s\n' "$trace_sha" "$trace_base.tar.xz" > "$out_dir/$trace_base.tar.xz.sha256sum"

note "二进制包：$base.tar.xz（${bin_bytes} 字节，sha256 ${sha:0:16}…）"
note "过程包：$trace_base.tar.xz（${trace_bytes} 字节，sha256 ${trace_sha:0:16}…，perf.data ${perf_count} 个）"
if ((trace_bytes > 2 * 1024 * 1024 * 1024)); then
	warn "过程包超过 GitHub release 单资产 2 GiB 上限；用 --no-perf-data 或更高的 --perf-xz-level 再试"
fi

# ---------------------------------------------------------------- publish
# release 上放：两个包 + 各自的 .sha256sum（共 4 个资产）；
# env / build-info / manifest / bolt.env 不再单独上传，都在过程包里。
assets=(
	"$out_dir/$base.tar.xz"
	"$out_dir/$base.tar.xz.sha256sum"
	"$out_dir/$trace_base.tar.xz"
	"$out_dir/$trace_base.tar.xz.sha256sum"
)

if $publish; then
	command -v gh >/dev/null 2>&1 || die "--publish 需要 gh CLI"
	if [[ -z "${GH_TOKEN:-}" && -z "${GITHUB_TOKEN:-}" ]]; then
		gh auth status >/dev/null 2>&1 || die "gh 未登录；设 GH_TOKEN（contents:write）或 gh auth login"
	fi
	# 默认 tag 是 v<Cargo.toml version>：没有 release 就新建（目标 commit = 本次构建的上游 commit）。
	if ! gh release view "$tag" --repo "$release_repo" >/dev/null 2>&1; then
		slug="$(repo_slug || true)"
		[[ -n "$slug" && "$release_repo" == "$slug" ]] \
			|| die "release $release_repo@$tag 不存在；只有上游 $slug 会自动创建（其他仓库请先建 release 或用 --tag）"
		note "新建 release ${release_repo}@${tag}（target ${commit:0:12}）"
		gh release create "$tag" --repo "$release_repo" --target "$commit" \
			--title "xn $version" \
			--notes "PGO+BOLT x86_64 GNU build of xn $version from ${commit:0:12}.

- \`${base}.tar.xz\`: binary package (xn / LICENSE / docs/configuration.md / THIRD-PARTY-NOTICES.txt)
- \`${base}.tar.xz.sha256sum\`: SHA-256 of the binary package
- \`${trace_base}.tar.xz\`: full build trace (all stages, logs, manifest, bolt.env, perf.data)
- \`${trace_base}.tar.xz.sha256sum\`: SHA-256 of the trace package"
	fi
	note "上传 ${#assets[@]} 个资产到 $release_repo@$tag"
	gh release upload "$tag" --repo "$release_repo" --clobber "${assets[@]}"
	# 旧版曾把 env / build-info / manifest / bolt.env 单独发布；默认清掉，
	# 保持 release 上只有两个包与各自的 .sha256sum。--keep-legacy 可保留（跨版本对比用）。
	if $prune_legacy; then
		legacy=(
			"$base.env"
			"$base.build-info.txt"
			"$base.manifest.tsv"
			"$base.bolt.env"
		)
		names="$(gh release view "$tag" --repo "$release_repo" --json assets --jq '.assets[].name' 2>/dev/null || true)"
		for name in "${legacy[@]}"; do
			if grep -qxF -- "$name" <<<"$names"; then
				note "删除旧版遗留资产 $name"
				gh release delete-asset "$tag" "$name" --repo "$release_repo" --yes \
					|| warn "删除 $name 失败（gh 版本过旧？）"
			fi
		done
	fi
	echo "https://github.com/$release_repo/releases/tag/$tag"
else
	note "未加 --publish；产物在 $out_dir"
fi

note "完成：$out_dir/$base.tar.xz 与 $out_dir/$trace_base.tar.xz（各带 .sha256sum）"
