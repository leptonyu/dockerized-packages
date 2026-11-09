#!/usr/bin/env bash
#
# pgo.compare：拿**本次已经编好的**两个 bin（普通包 / tuned 包）做同机 A/B，不再重编。
#
#   ./xn/compare.sh                                  # x86_64-unknown-linux-gnu，xn/dist 里的两份 bin
#   ./xn/compare.sh --target aarch64-apple-darwin --size-only
#   ./xn/compare.sh --plain A --tuned B --rounds 4
#
# 为什么这么绕：上游 `scripts/test/pgo/compare-ci.sh` 的 `--no-build` 只认 build-tuned 的
# run 目录（`02-optimize/xn.control` + `xn.tuned`），所以这里把 build.sh 保存的两个 bin
# 摆成同样的目录结构再交给它 —— 控制组 = 普通编译的 xn，优化组 = tuned 的 xn：
#   <src>/target/tune/prebuilt-<UTC>/02-optimize/xn.control  ← xn.<triple>.release.bin
#   <src>/target/tune/prebuilt-<UTC>/02-optimize/xn.tuned    ← xn.<triple>.tuned.bin
# 之后还是上游那套：能力探测（root/TUN/ip）→ `pgo.compare` 走
# `scripts/perf/run.sh run t1 --binary 控制 --binary-b 优化`；跑不了 rig（macOS 的 Mach-O、
# 没有 root）自动退 `pgo.compare.size`，只比 bin 大小。报告落在上游的 target/pgo/、
# target/test-runs/。
#
# 依赖：build.sh 已经跑过（`xn/dist/xn.<triple>.{release,tuned}.bin` 在），上游 checkout
# 在 --src（CI 就是 .cache/xn-src）。
#
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
src="${XN_SRC:-$root/.cache/xn-src}"
out_dir="${XN_OUT_DIR:-$root/dist}"
target="${XN_TARGET:-x86_64-unknown-linux-gnu}"
rounds="${XN_PGO_ROUNDS:-4}"
plain="${XN_PLAIN_BIN:-}"
tuned="${XN_TUNED_BIN:-}"
size_only=false
run_dir=""

die() { echo "xn/compare.sh: $*" >&2; exit 2; }
note() { echo "==> $*" >&2; }

usage() {
	awk 'NR > 1 { if ($0 ~ /^#/) { sub(/^# ?/, ""); print; next } exit }' "$0"
	cat <<'T'

选项（环境变量同名，带 XN_ 前缀）：
  --src DIR            上游 xn checkout（默认 .cache/xn-src）
  --out-dir DIR        build.sh 的产物目录（默认 xn/dist）
  --target TRIPLE      目标 triple（默认 x86_64-unknown-linux-gnu）
  --plain FILE         普通档的 xn 二进制（默认 <out-dir>/xn.<triple>.release.bin）
  --tuned FILE         tuned 档的 xn 二进制（默认 <out-dir>/xn.<triple>.tuned.bin）
  --rounds N           同机 A/B 轮次（默认 4，偶数；A,B,B,A 轮转）
  --size-only          只比 bin 大小（macOS 自动这样）
  --run-dir DIR        直接用现成的 build-tuned run 目录（跳过 --plain/--tuned）
  -h, --help           本帮助
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
		--plain) plain="$2"; shift 2 ;;
		--plain=*) plain="${1#*=}"; shift ;;
		--tuned) tuned="$2"; shift 2 ;;
		--tuned=*) tuned="${1#*=}"; shift ;;
		--rounds) rounds="$2"; shift 2 ;;
		--rounds=*) rounds="${1#*=}"; shift ;;
		--size-only) size_only=true; shift ;;
		--run-dir) run_dir="$2"; shift 2 ;;
		--run-dir=*) run_dir="${1#*=}"; shift ;;
		-h|--help) usage; exit 0 ;;
		*) die "未知参数 $1（用 -h 看用法）" ;;
	esac
done

[[ -d "$src" ]] || die "找不到上游 checkout：${src}（用 --src 指定）"
[[ -f "$src/scripts/test/pgo/compare-ci.sh" ]] || die "$src 里没有 scripts/test/pgo/compare-ci.sh"

# macOS 的产物是 Mach-O，跑不了 Linux perf rig；直接退到只比大小，和上游能力探测一致。
if [[ "$(uname -s)" == Darwin ]]; then
	size_only=true
fi

if [[ -z "$run_dir" ]]; then
	plain="${plain:-$out_dir/xn.$target.release.bin}"
	tuned="${tuned:-$out_dir/xn.$target.tuned.bin}"
	# 只要求文件存在，不要求可执行：CI 里 bin 是 actions/upload-artifact 上下载的，
	# 下载后权限统一变成 644（upload-artifact 的已知限制），-x 会把「拿到了」误判成
	# 「没找到」。下面复制进 run dir 时再统一 chmod +x。
	[[ -f "$plain" ]] || die "找不到普通档的 xn：${plain}（先跑 ./xn/build.sh，或 --plain 指定）"
	[[ -f "$tuned" ]] || die "找不到 tuned 档的 xn：${tuned}（先跑 ./xn/build.sh --flavors tuned，或 --tuned 指定）"
	run_dir="$src/target/tune/prebuilt-$(date -u +%Y%m%dT%H%M%SZ)"
	mkdir -p "$run_dir/02-optimize"
	cp -p "$plain" "$run_dir/02-optimize/xn.control"
	cp -p "$tuned" "$run_dir/02-optimize/xn.tuned"
	chmod +x "$run_dir/02-optimize/xn.control" "$run_dir/02-optimize/xn.tuned" 2>/dev/null || true
	note "控制组（普通 bin）：$plain"
	note "优化组（tuned bin）：$tuned"
	note "run dir：$run_dir"
fi

args=(--no-build --run-dir "$run_dir" --rounds "$rounds")
$size_only && args+=(--size-only)
note "compare-ci.sh ${args[*]}（用本次编好的 bin，不重编）"
cd "$src"
exec ./scripts/test/pgo/compare-ci.sh "${args[@]}"
