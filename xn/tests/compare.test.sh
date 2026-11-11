#!/usr/bin/env bash
# 离线自测 xn/compare.sh：确认它把「本次编好的普通 bin / tuned bin」摆成上游
# build-tuned 的 run 目录，并用 compare-ci.sh --no-build 调（不重编）。
#
#   ./xn/tests/compare.test.sh
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
compare="$here/../compare.sh"
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

target="x86_64-unknown-linux-gnu"
src="$work/src"; out="$work/out"
mkdir -p "$src/scripts/test/pgo" "$out"

# 假 compare-ci.sh：只把参数（和 XN_PGO_GATE）记下来
cat >"$src/scripts/test/pgo/compare-ci.sh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >"${FAKE_ARGS:?}"
[[ -n "${FAKE_ENV:-}" ]] && printf '%s' "${XN_PGO_GATE:-}" >"$FAKE_ENV"
exit 0
FAKE
chmod +x "$src/scripts/test/pgo/compare-ci.sh"

# 假 compare-gate.sh：哨兵 —— xn/compare.sh **不该**自己调它（gate 由上游
# scripts/test/pgo/compare.sh 认 XN_PGO_GATE=1 之后跑），调到了就留文件。
cat >"$src/scripts/test/pgo/compare-gate.sh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >"${FAKE_GATE_ARGS:?}"
exit 0
FAKE
chmod +x "$src/scripts/test/pgo/compare-gate.sh"

printf '#!/bin/sh\necho plain\n' >"$out/xn.$target.release.bin"
printf '#!/bin/sh\necho tuned\n' >"$out/xn.$target.tuned.bin"
chmod +x "$out/xn.$target.release.bin" "$out/xn.$target.tuned.bin"

printf '== 1) 用现成 bin 跑，不重编\n'
FAKE_ARGS="$work/args.txt" bash "$compare" --src "$src" --out-dir "$out" --target "$target" \
	--rounds 4 --size-only >"$work/out.log" 2>"$work/err.log"
rc=$?
check "退出码 0（实际 ${rc}）" test "$rc" -eq 0
check "compare-ci 收到 --no-build" grep -q -- '--no-build' "$work/args.txt"
check "compare-ci 收到 --size-only 和 --rounds 4" grep -q -- '--size-only' "$work/args.txt"
check "compare-ci 收到 --rounds 4" grep -q -- '--rounds 4' "$work/args.txt"
run_dir="$(sed -n 's/.*--run-dir \([^ ]*\).*/\1/p' "$work/args.txt")"
check "run dir 里有 02-optimize/xn.control" test -f "$run_dir/02-optimize/xn.control"
check "run dir 里有 02-optimize/xn.tuned" test -f "$run_dir/02-optimize/xn.tuned"
check "control 就是普通 bin" cmp -s "$run_dir/02-optimize/xn.control" "$out/xn.$target.release.bin"
check "tuned 就是 tuned bin" cmp -s "$run_dir/02-optimize/xn.tuned" "$out/xn.$target.tuned.bin"

printf '== 2) 下载来的 bin 没有执行位（release 下载同样如此）也能用\n'
rm -f "$out/xn.$target.release.bin" "$out/xn.$target.tuned.bin"
printf '#!/bin/sh\necho plain\n' >"$out/xn.$target.release.bin"
printf '#!/bin/sh\necho tuned\n' >"$out/xn.$target.tuned.bin"
chmod 644 "$out/xn.$target.release.bin" "$out/xn.$target.tuned.bin"
FAKE_ARGS="$work/args-dl.txt" bash "$compare" --src "$src" --out-dir "$out" --target "$target" \
	--rounds 4 --size-only >"$work/out-dl.log" 2>"$work/err-dl.log"
rc=$?
check "退出码 0（实际 ${rc}）" test "$rc" -eq 0
run_dir="$(sed -n 's/.*--run-dir \([^ ]*\).*/\1/p' "$work/args-dl.txt")"
check "复制后补上普通 bin 的执行位" test -x "$run_dir/02-optimize/xn.control"
check "复制后补上 tuned bin 的执行位" test -x "$run_dir/02-optimize/xn.tuned"

printf '== 3) 缺 tuned bin 直接报错\n'
rm -f "$out/xn.$target.tuned.bin"
FAKE_ARGS="$work/args2.txt" bash "$compare" --src "$src" --out-dir "$out" --target "$target" \
	>"$work/out2.log" 2>"$work/err2.log"
rc=$?
check "退出码 2（实际 ${rc}）" test "$rc" -eq 2
check "提示缺 tuned bin" grep -q 'tuned' "$work/err2.log"
check "没有去调 compare-ci" test ! -e "$work/args2.txt"

printf '== 4) --run-dir 直接用现成目录\n'
mkdir -p "$work/run/02-optimize"
FAKE_ARGS="$work/args3.txt" bash "$compare" --src "$src" --run-dir "$work/run" --size-only \
	>"$work/out3.log" 2>&1
rc=$?
check "退出码 0（实际 ${rc}）" test "$rc" -eq 0
check "用了给定的 run dir" grep -q -- "--run-dir $work/run" "$work/args3.txt"

printf '== 5) XN_PGO_GATE=1 只透传给上游，不在本地重复跑 gate\n'
# gate 三拓扑 A/B 由上游 scripts/test/pgo/compare.sh 在 t1 之后自己跑（compare-ci 已经
# 以 root 重入过）；xn/compare.sh 再跑一遍会撞 root 拥有的 target/pgo/（Permission denied，
# run 42979842971 的原样故障），所以这里只验透传 + 哨兵没被触发。
printf '#!/bin/sh\necho tuned\n' >"$out/xn.$target.tuned.bin"
chmod +x "$out/xn.$target.tuned.bin"
rm -f "$work/gate-args.txt" "$work/gate-env.txt"
FAKE_ARGS="$work/args-gate.txt" FAKE_ENV="$work/gate-env.txt" FAKE_GATE_ARGS="$work/gate-args.txt" \
	XN_PGO_GATE=1 bash "$compare" --src "$src" --out-dir "$out" --target "$target" \
	--rounds 4 --size-only >"$work/out-gate.log" 2>"$work/err-gate.log"
rc=$?
check "退出码 0（实际 ${rc}）" test "$rc" -eq 0
check "t1 仍然先跑" grep -q -- '--no-build' "$work/args-gate.txt"
check "上游收到 XN_PGO_GATE=1" grep -qx 1 "$work/gate-env.txt"
check "本地没有再调 compare-gate" test ! -e "$work/gate-args.txt"
check "日志说明 gate 交给上游" grep -q '上游 pgo.compare' "$work/err-gate.log"

printf '== 6) 没设 XN_PGO_GATE 时不打开 gate\n'
rm -f "$work/gate-env-none.txt" "$work/gate-args-none.txt"
FAKE_ARGS="$work/args-none.txt" FAKE_ENV="$work/gate-env-none.txt" \
	FAKE_GATE_ARGS="$work/gate-args-none.txt" \
	bash "$compare" --src "$src" --out-dir "$out" --target "$target" --rounds 4 --size-only \
	>"$work/out-none.log" 2>"$work/err-none.log"
rc=$?
check "退出码 0（实际 ${rc}）" test "$rc" -eq 0
check "上游没收到 gate 开关" test ! -s "$work/gate-env-none.txt"
check "没有调用 compare-gate" test ! -e "$work/gate-args-none.txt"

printf '== 7) --help\n'
bash "$compare" --help >/dev/null 2>&1
check "help 退出码 0" test $? -eq 0

if ((fail)); then
	printf '\n有失败项\n' >&2
	exit 1
fi
printf '\n全部通过\n'
