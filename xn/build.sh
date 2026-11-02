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
# 这里只负责：取上游源码、跑这条命令、打包、创建/追加 v<Cargo.toml version> release。
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
release_repo="${XN_RELEASE_REPO:-leptonyu/xn}"
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

target="x86_64-unknown-linux-gnu"
base="xn.${target}.pgo-bolt"

die() { echo "xn/build.sh: $*" >&2; exit 2; }
note() { echo "==> $*" >&2; }
warn() { echo "xn/build.sh: 警告：$*" >&2; }

usage() {
	sed -n '2,22p' "$self" | sed 's/^# \{0,1\}//'
	cat <<'EOF'

选项（环境变量同名，带 XN_ 前缀）：
  --src DIR            本地 xn checkout（CI 里由 actions/checkout 提供；给了就不再 clone）
  --repo URL           上游仓库，默认 git@github.com:leptonyu/xn.git
  --ref REF            分支 / tag / commit，默认 main（须包含 release.sh --tuned）
  --out-dir DIR        产物目录，默认 xn/dist
  --release-repo R     release 所在仓库，默认 leptonyu/xn
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
  --package-only       不构建，只打包 target/<triple>/release/xn + xn.tuned.env
  --publish            通过 gh 发布到 --tag；release 不存在时新建（默认上游 xn）
  --check              只检查工具链与 release.sh 能力，不构建
  --dry-run            只打印命令，不 clone / 不构建 / 不上传
  -h, --help           本帮助

产物（也即上传的资产）：
  xn.x86_64-unknown-linux-gnu.pgo-bolt.tar.xz
  xn.x86_64-unknown-linux-gnu.pgo-bolt.tar.xz.sha256sum
  xn.x86_64-unknown-linux-gnu.pgo-bolt.env
  xn.x86_64-unknown-linux-gnu.pgo-bolt.build-info.txt
  xn.x86_64-unknown-linux-gnu.pgo-bolt.manifest.tsv    （若上游 run 目录里有）
  xn.x86_64-unknown-linux-gnu.pgo-bolt.bolt.env        （若上游 run 目录里有）
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

# 源码准备好后确定版本与默认 tag：v<workspace version>。
prepare_version() {
	version="$(xn_version "$src")" || die "读不到 xn 版本（$src/Cargo.toml）"
	[[ -n "$tag" ]] || tag="v$version"
	note "xn 版本：${version}（发布 tag：${tag}）"
}

# 发布出去的环境文件不要带本地路径 / 主机名：run_dir、workload、host、uname 一律脱敏。
sanitize_env() { # $1=输入 $2=输出
	awk '
		/^run_dir=/ { print "run_dir=<redacted>"; next }
		/^workload=/ { print "workload=<redacted>"; next }
		/^host=/ { print "host=<redacted>"; next }
		/^uname=/ { print "uname=<redacted>"; next }
		{ print }
	' "$1" > "$2"
}

# manifest 第 3 列是绝对构建路径；换成 <产物名>，保留 build-id/size/sha。
sanitize_manifest() { # $1=输入 $2=输出
	awk -F'\t' 'BEGIN { OFS="\t" } NR == 1 { print; next } { $3 = "<" $2 ">"; print }' "$1" > "$2"
}

# bolt.env 里的 binary/perf/工具路径与主机信息脱敏，保留版本、icf、build-id、size、sha。
sanitize_bolt_env() { # $1=输入 $2=输出
	awk -F= '
		/^(host|uname|binary|perf|perf2bolt|llvm_bolt|llvm_strip|readelf)=/ { print $1 "=<redacted>"; next }
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

resolve_ref() { # $1=src $2=ref -> commit
	local r="$1" x="$2" c
	for c in "refs/tags/$x" "refs/remotes/origin/$x" "$x"; do
		if c="$(git -C "$r" rev-parse --verify --quiet "$c^{commit}" 2>/dev/null)"; then
			printf '%s\n' "$c"
			return 0
		fi
	done
	return 1
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
		note "clone $repo → $src"
		mkdir -p "$(dirname "$src")"
		git clone "$repo" "$src" || die "clone 失败；CI 里可用 --src 指向 actions/checkout 的目录"
	fi
	note "fetch ${repo}（tags）"
	git -C "$src" fetch --tags --force origin || die "fetch 失败（私有仓库需要 SSH key / token）"
	commit="$(resolve_ref "$src" "$ref")" || die "在 $src 找不到 ref：$ref"
	note "checkout ${ref}（${commit:0:12}）"
	git -C "$src" checkout --force --detach "$commit" >/dev/null || die "checkout 失败：$commit"
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
		printf '+ git clone %q %q\n' "$repo" "$s"
		printf '+ git -C %q fetch --tags --force origin\n' "$s"
		printf '+ git -C %q checkout --force --detach %q\n' "$s" "$ref"
	fi
	if $package_only; then
		echo "# --package-only：跳过构建，直接打包"
	else
		printf '+ (cd %q && ./release.sh' "$s"
		printf ' %q' "${rargs[@]}"
		printf ')\n'
	fi
	printf '+ 打包 %s.tar.xz（xn / LICENSE / xn.tuned.env / THIRD-PARTY-NOTICES.txt）\n' "$base"
	if $publish; then
		if [[ -n "$tag" ]]; then
			printf '+ gh release create/upload %q --repo %q --clobber %q/*\n' "$tag" "$release_repo" "$out_dir"
		else
			printf '+ gh release create/upload v<Cargo.toml version> --repo %q --clobber %q/*\n' "$release_repo" "$out_dir"
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

# ---------------------------------------------------------------- package
if $publish; then
	note "目标 release：${release_repo}@${tag}（版本 ${version}）"
fi

stage="$out_dir/.stage-$base"
rm -rf "$stage"
mkdir -p "$stage"
cp "$bin" "$stage/xn"
chmod +x "$stage/xn"
cp "$src/LICENSE" "$stage/LICENSE"
sanitize_env "$envf" "$stage/xn.tuned.env"

files=(xn LICENSE xn.tuned.env)
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

command -v xz >/dev/null 2>&1 || die "找不到 xz"
tar -C "$stage" -cJf "$out_dir/$base.tar.xz" "${files[@]}"
sha="$(sha256_file "$out_dir/$base.tar.xz")"
printf '%s  %s\n' "$sha" "$base.tar.xz" > "$out_dir/$base.tar.xz.sha256sum"

# 上游 release.sh 已经写好的元数据；发布前脱敏，避免带出本地路径 / 主机名。
sanitize_env "$envf" "$out_dir/$base.env"
run_dir="$(sed -n 's/^run_dir=//p' "$envf" | head -n1)"
if [[ -n "$run_dir" && -f "$run_dir/manifest.tsv" ]]; then
	sanitize_manifest "$run_dir/manifest.tsv" "$out_dir/$base.manifest.tsv"
fi
if [[ -n "$run_dir" && -f "$run_dir/03-bolt/bolt.env" ]]; then
	sanitize_bolt_env "$run_dir/03-bolt/bolt.env" "$out_dir/$base.bolt.env"
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
	printf 'tarball=%s\n' "$base.tar.xz"
	printf 'tarball_sha256=%s\n' "$sha"
	printf 'release_repo=%s\n' "$release_repo"
	printf 'release_tag=%s\n' "${tag:-<none>}"
	printf 'metadata_note=本地路径 / 主机名已脱敏\n'
} > "$out_dir/$base.build-info.txt"

rm -rf "$stage"

# ---------------------------------------------------------------- publish
assets=(
	"$out_dir/$base.tar.xz"
	"$out_dir/$base.tar.xz.sha256sum"
	"$out_dir/$base.env"
	"$out_dir/$base.build-info.txt"
)
[[ -f "$out_dir/$base.manifest.tsv" ]] && assets+=("$out_dir/$base.manifest.tsv")
[[ -f "$out_dir/$base.bolt.env" ]] && assets+=("$out_dir/$base.bolt.env")

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
			--notes "PGO+BOLT x86_64 GNU build of xn $version from ${commit:0:12}."
	fi
	note "上传 ${#assets[@]} 个资产到 $release_repo@$tag"
	gh release upload "$tag" --repo "$release_repo" --clobber "${assets[@]}"
	echo "https://github.com/$release_repo/releases/tag/$tag"
else
	note "未加 --publish；产物在 $out_dir"
fi

note "完成：$out_dir/$base.tar.xz（sha256 ${sha:0:16}…）"
