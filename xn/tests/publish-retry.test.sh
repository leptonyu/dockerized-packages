#!/usr/bin/env bash
# 离线自测 build.sh 的发布路径（不碰真 GitHub，不构建）。
#
#   ./xn/tests/publish-retry.test.sh
#
# 覆盖：
#   1) 某资产连续两次 HTTP 502 → 自动退避重试后成功；8 个资产齐全，.sha256sum 最后传；
#   2) HTTP 403 → 判定不可重试，1 次就失败，不浪费 4 轮等待；
#   3) 远端 .sha256sum 与本次构建不一致 → 自检发现后整体重传一次（16 次 upload）；
#   4) 普通包 + tuned 包合并发布（同 release、各自 .sha256sum、校验和最后传）；
#   5) 两步发布：先普通包、再 tuned（workflow 里就是两段 publish）；
#   6) --dry-run / --help。
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
build="$here/../build.sh"
target="x86_64-unknown-linux-gnu"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail=0
check() { # check <描述> <命令...>
	local what="$1"; shift
	if "$@"; then
		printf '  ok   %s\n' "$what"
	else
		printf '  FAIL %s\n' "$what" >&2
		fail=1
	fi
}

sha() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	else
		shasum -a 256 "$1" | awk '{print $1}'
	fi
}

# ---------------------------------------------------------------- 假 gh
# 只实现 build.sh 用到的子命令：release view/upload/download/create/delete-asset、api。
# FAKE_STATE=状态目录；FAKE_FAIL_ASSET=资产名；FAKE_FAIL_TIMES=N；FAKE_FAIL_CODE=502/403。
mkdir -p "$work/bin" "$work/state"
cat >"$work/bin/gh" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
state="${FAKE_STATE:?}"
mkdir -p "$state/remote" "$state/count"
printf 'gh %s\n' "$*" >>"$state/calls.log"
sha() {
	if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
	else shasum -a 256 "$1" | awk '{print $1}'; fi
}
cmd="$1"; shift || true
case "$cmd" in
	release)
		sub="${1:-}"; shift || true
		case "$sub" in
			view) exit 0 ;;
			upload)
				file=""
				for a in "$@"; do case "$a" in /*) file="$a" ;; esac; done
				[[ -n "$file" ]] || { echo "fake gh: upload 缺文件" >&2; exit 1; }
				name="$(basename "$file")"
				n=0
				[[ -f "$state/count/$name" ]] && n="$(cat "$state/count/$name")"
				if [[ "$name" == "${FAKE_FAIL_ASSET:-}" ]] && ((n < ${FAKE_FAIL_TIMES:-0})); then
					printf '%s\n' "$((n + 1))" >"$state/count/$name"
					echo "HTTP ${FAKE_FAIL_CODE:-502}: Server Error (https://api.github.com/repos/leptonyu/xn/releases/assets/708740599)" >&2
					exit 1
				fi
				# 模拟「传成功了但内容对不上」：只坏第一次，用来触发 verify + 重传。
				if [[ "$name" == "${FAKE_CORRUPT_ASSET:-}" ]] && ((n == 0)); then
					printf '1\n' >"$state/count/$name"
					printf 'corrupted\n' >"$state/remote/$name"
					exit 0
				fi
				cp "$file" "$state/remote/$name"
				exit 0
				;;
			download)
				dir=""; prev=""
				for a in "$@"; do
					[[ "$prev" == "--dir" ]] && dir="$a"
					prev="$a"
				done
				[[ -n "$dir" ]] || { echo "fake gh: download 缺 --dir" >&2; exit 1; }
				for f in "$state/remote"/*.sha256sum; do
					[[ -f "$f" ]] || continue
					cp "$f" "$dir/"
				done
				exit 0
				;;
			create|delete-asset) exit 0 ;;
		esac
		;;
	api)
		if [[ "$*" == *".assets[]"* ]]; then
			for f in "$state/remote"/*; do
				[[ -f "$f" ]] || continue
				printf '%s sha256:%s\n' "$(basename "$f")" "$(sha "$f")"
			done
		fi
		exit 0
		;;
	auth) exit 0 ;;
esac
exit 0
FAKE
chmod +x "$work/bin/gh"

# ---------------------------------------------------------------- 假上游产物
make_src() { # make_src <dir>
	local src="$1" rel="$1/target/$target/release"
	mkdir -p "$rel"
	printf '[workspace.package]\nversion = "9.9.9"\n' >"$src/Cargo.toml"
	printf '#!/bin/sh\n# --tuned --pack\n' >"$src/release.sh"
	chmod +x "$src/release.sh"
	printf 'runtime-%s' "$RANDOM" >"$rel/xn.$target.pgo-bolt.tar.xz"
	printf 'trace-%s' "$RANDOM" >"$rel/xn.$target.pgo-bolt.trace.tar.xz"
	(
		cd "$rel"
		if command -v sha256sum >/dev/null 2>&1; then
			sha256sum "xn.$target.pgo-bolt.tar.xz" "xn.$target.pgo-bolt.trace.tar.xz" >SHA256SUMS
		else
			shasum -a 256 "xn.$target.pgo-bolt.tar.xz" "xn.$target.pgo-bolt.trace.tar.xz" >SHA256SUMS
		fi
	)
	for b in cidr xn-tui; do
		printf '%s-%s' "$b" "$RANDOM" >"$rel/$b.$target.tar.xz"
		printf '%s  %s\n' "$(sha "$rel/$b.$target.tar.xz")" "$b.$target.tar.xz" \
			>"$rel/$b.$target.tar.xz.sha256sum"
	done
}

run_publish() { # run_publish <状态目录> <src> <out> [ENV=VAL...]
	local state="$1" src="$2" out="$3"
	shift 3
	mkdir -p "$state/remote" "$out"
	env PATH="$work/bin:$PATH" FAKE_STATE="$state" GH_TOKEN=dummy \
		XN_RETRY_DELAY=0 XN_RETRIES=4 "$@" \
		bash "$build" --src "$src" --package-only --publish \
		--release-repo leptonyu/xn --tag v9.9.9 --out-dir "$out" \
		>"$state/stdout.log" 2>"$state/stderr.log"
}

# ---------------------------------------------------------------- 1) 502 重试
printf '== 1) 502 两次后重试成功\n'
src="$work/src1"; state="$work/state1"; out="$work/out1"
make_src "$src"
run_publish "$state" "$src" "$out" FAKE_FAIL_ASSET=xn-tui.$target.tar.xz FAKE_FAIL_TIMES=2
rc=$?
check "退出码 0（实际 ${rc}）" test "$rc" -eq 0
check "重试 2 次后成功" test "$(cat "$state/count/xn-tui.$target.tar.xz" 2>/dev/null)" = "2"
check "8 个资产都在远端" test "$(ls "$state/remote" | wc -l | tr -d ' ')" = "8"
check "runtime/trace 的 .sha256sum 已上传" test -f "$state/remote/xn.$target.tuned.tar.xz.sha256sum" -a -f "$state/remote/xn.$target.tuned.trace.tar.xz.sha256sum"
check "上传顺序：.sha256sum 在最后" test "$(grep 'release upload' "$state/calls.log" | awk '{print $NF}' | tail -2 | while read -r p; do basename "$p"; done | tr '\n' ' ')" = "xn.$target.tuned.tar.xz.sha256sum xn.$target.tuned.trace.tar.xz.sha256sum "
check "自检通过" grep -q 'release 资产自检通过' "$state/stderr.log"
check "日志里能看到 502 与重试" grep -q '502' "$state/stderr.log"

# ---------------------------------------------------------------- 2) 403 不重试
printf '== 2) 403 不重试，1 次就失败\n'
src="$work/src2"; state="$work/state2"; out="$work/out2"
make_src "$src"
run_publish "$state" "$src" "$out" FAKE_FAIL_ASSET=cidr.$target.tar.xz FAKE_FAIL_TIMES=99 FAKE_FAIL_CODE=403
rc=$?
check "退出码非 0（实际 ${rc}）" test "$rc" -ne 0
check "只尝试 1 次" test "$(cat "$state/count/cidr.$target.tar.xz" 2>/dev/null)" = "1"
check "提示不可重试" grep -q '不可重试' "$state/stderr.log"
check "没上传 .sha256sum（失败即止）" test ! -f "$state/remote/xn.$target.tuned.tar.xz.sha256sum"

# ---------------------------------------------------------------- 3) 自检后重传
printf '== 3) 远端内容不一致 → 自检后整体重传\n'
src="$work/src3"; state="$work/state3"; out="$work/out3"
make_src "$src"
run_publish "$state" "$src" "$out" FAKE_CORRUPT_ASSET=xn.$target.tuned.tar.xz.sha256sum
rc=$?
check "退出码 0（实际 ${rc}）" test "$rc" -eq 0
check "共 16 次 upload（1 轮 + 重传 1 轮）" test "$(grep -c 'release upload' "$state/calls.log")" = "16"
check "重传后自检通过" grep -q 'release 资产自检通过' "$state/stderr.log"
check "重传前的告警" grep -q '不一致，重传一次' "$state/stderr.log"

# ---------------------------------------------------------------- 5) 合并发布：普通 + tuned
printf '== 4) 普通包 + tuned 包合并发布（同 release）\n'
src="$work/src5"; state="$work/state5"; out="$work/out5"
make_src "$src"
rel="$src/target/$target/release"
printf 'plain-%s' "$RANDOM" >"$rel/xn.$target.tar.xz"
printf '%s  %s\n' "$(sha "$rel/xn.$target.tar.xz")" "xn.$target.tar.xz" >>"$rel/SHA256SUMS"
run_publish "$state" "$src" "$out"
rc=$?
check "退出码 0（实际 ${rc}）" test "$rc" -eq 0
check "10 个资产（5 包 + 5 校验和）" test "$(ls "$state/remote" | wc -l | tr -d ' ')" = "10"
check "普通包和 tuned 包都在远端" test -f "$state/remote/xn.$target.tar.xz" -a -f "$state/remote/xn.$target.tuned.tar.xz"
check "普通包也有自己的 .sha256sum" test -f "$state/remote/xn.$target.tar.xz.sha256sum"
check "校验和最后传（tuned 然后 trace）" test "$(grep 'release upload' "$state/calls.log" | awk '{print $NF}' | tail -2 | while read -r p; do basename "$p"; done | tr '\n' ' ')" = "xn.$target.tuned.tar.xz.sha256sum xn.$target.tuned.trace.tar.xz.sha256sum "

# ---------------------------------------------------------------- 5) 两步发布
printf '== 5) 两步发布：先普通包，再 tuned（同一个 release）\n'
src="$work/src6"; state="$work/state6"; out="$work/out6"
make_src "$src"
rel="$src/target/$target/release"
printf 'plain-%s' "$RANDOM" >"$rel/xn.$target.tar.xz"
printf '%s  %s\n' "$(sha "$rel/xn.$target.tar.xz")" "xn.$target.tar.xz" >>"$rel/SHA256SUMS"
run_publish "$state" "$src" "$out" XN_FLAVORS=release
rc=$?
check "第一步（普通包）退出码 0（实际 ${rc}）" test "$rc" -eq 0
check "第一步后 6 个资产（普通包 + extras + 校验和）" test "$(ls "$state/remote" | wc -l | tr -d ' ')" = "6"
check "第一步只有普通包，没有 tuned" test -f "$state/remote/xn.$target.tar.xz" -a ! -f "$state/remote/xn.$target.tuned.tar.xz"
run_publish "$state" "$src" "$out" XN_FLAVORS=tuned
rc=$?
check "第二步（tuned）退出码 0（实际 ${rc}）" test "$rc" -eq 0
check "第二步后 10 个资产" test "$(ls "$state/remote" | wc -l | tr -d ' ')" = "10"
check "普通包和它的 .sha256sum 没被 tuned 那步清掉" test -f "$state/remote/xn.$target.tar.xz" -a -f "$state/remote/xn.$target.tar.xz.sha256sum"
check "tuned 包和 trace 都在" test -f "$state/remote/xn.$target.tuned.tar.xz" -a -f "$state/remote/xn.$target.tuned.trace.tar.xz"

# ---------------------------------------------------------------- 6) dry-run / help
printf '== 6) dry-run / help\n'
check "dry-run 退出码 0" bash "$build" --dry-run
check "dry-run 打印上传计划" bash -c "bash '$build' --dry-run --publish 2>&1 | grep -q 'gh release create/upload'"
check "help 退出码 0" bash "$build" --help

if ((fail)); then
	printf '\n有失败项\n' >&2
	exit 1
fi
printf '\n全部通过\n'
