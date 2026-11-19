#!/usr/bin/env bash
# 离线自测「测试 XN」workflow（.github/workflows/xn-tests.yml）：
#   1) suite 菜单与上游 `../rust/xn` 的 test.yml 一致（all + 4 tier + 6 category）；
#   2) 调用上游统一入口 `run.sh`（check / doctor / list / run），不是旧的 `all.sh`；
#   3) 全套口径有硬检查（Detect full test suite / Verify full-suite coverage）；
#   4) pgo suite 先编 build-tuned 再跑；报告 / artifact 步骤齐全。
#
#   ./xn/tests/workflow-tests.test.sh
#
# 只做静态检查（grep yml），不联网、不跑 action；改 workflow 时的回归网。
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
wf="$here/../../.github/workflows/xn-tests.yml"

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
has() { # has <描述> <必须出现的字面串>
	check "$1" grep -qF -- "$2" "$wf"
}
absent() { # absent <描述> <必须不出现的字面串>
	local what="$1" pat="$2"
	if grep -qF -- "$pat" "$wf"; then
		printf '  FAIL %s（workflow 里还有：%s）\n' "$what" "$pat" >&2
		fail=1
	else
		printf '  ok   %s\n' "$what"
	fi
}

[[ -f "$wf" ]] || { echo "找不到 $wf" >&2; exit 2; }

printf '== 1) suite 菜单与上游 test.yml 对齐\n'
# options 是 YAML 里唯一的「裸列表项」；matrix include 是 JSON，不会被这条 sed 选中。
opts="$(sed -n 's/^ *- \([a-z][a-z0-9]*\)$/\1/p' "$wf" | sort | tr '\n' ' ')"
check "11 个 suite 选项（all + 4 tier + 6 category）" \
	test "$opts" = "all bench e2e manual nightly perf pgo pr release smoke unit "
has "suite 是 choice" 'type: choice'
has "默认 suite=all" 'default: all'
has "keep_going 开关" 'keep_going:'
has "keep_going 默认 true" 'default: true'
# 唯一入口是手动 dispatch：上游 test.yml 也把自动触发全关了。
absent "没有 push 自动触发" '  push:'
absent "没有 pull_request 自动触发" '  pull_request:'
absent "没有 schedule 自动触发" '  schedule:'
absent "旧 mode 菜单已删除" 'inputs.mode'
absent "不再调旧的 all.sh" 'scripts/test/all.sh'

printf '\n== 2) 调上游统一入口 run.sh\n'
has "registry / catalog 自检" 'scripts/test/run.sh check'
has "本机可跑性清单" 'scripts/test/run.sh doctor'
has "全量清点（--json）" 'scripts/test/run.sh list --json'
has "统一执行入口" 'scripts/test/run.sh run "${args[@]}"'
has "all → --all" 'all) args+=(--all) ;;'
has "tier → --tier" 'pr|nightly|release|manual) args+=(--tier "$suite") ;;'
has "category → --category" 'unit|smoke|e2e|bench|perf|pgo) args+=(--category "$suite") ;;'
has "按锁取 dlc（--fetch）" 'args+=(--fetch)'
has "hosted 缺环境记 skip" 'args+=(--skip-env-error)'
has "keep_going 透传" 'args+=(--keep-going)'

printf '\n== 3) hosted runner 的 root / 架构口径\n'
has "Linux 腿 sudo 跑 unified" 'sudo -E env "PATH=$PATH"'
has "按 RUNNER_OS 区分" 'if [[ "$RUNNER_OS" == "Linux" ]]'
has "smoke / pgo 只起 Linux 腿" "inputs.suite == 'smoke' || inputs.suite == 'pgo'"
# matrix.include 要数组；表达式本身返回 JSON 字符串，少了 fromJSON 会在展开 job 图时
# 直接失败（44483912654：repo tests 正常、upstream job 没被创建）。
has "matrix include 用 fromJSON 解成数组" \
	"include: \${{ fromJSON((inputs.suite == 'smoke' || inputs.suite == 'pgo')"
has "hosted 6h 上限（不是上游 1440）" 'timeout-minutes: 360'
absent "没有照抄 self-hosted 的 1440" 'timeout-minutes: 1440'
absent "没有照抄 self-hosted runner 标签" 'runs-on: [self-hosted'
has "本仓库离线测试仍跑" 'xn/tests/run-all.sh'

printf '\n== 4) pgo suite 先编再跑\n'
has "build-tuned 编 control + 优化产物" \
	'scripts/build-tuned.sh all --profile pgo --no-bolt --control'
has "run 目录交给 pgo.compare" 'XN_PGO_RUN_DIR'
has "pgo 只在 Linux 上跑（matrix 已限制）" "inputs.suite == 'pgo'"

printf '\n== 5) 全套口径的两道硬检查\n'
has "清点上游 registry 的 category / tier" 'name: Detect full test suite'
has "category 清单" 'want_cats = ["unit", "smoke", "e2e", "bench", "perf", "pgo"]'
has "tier 清单" 'want_tiers = ["pr", "nightly", "release", "manual"]'
has "菜单漂移直接红" '上游 registry 与本 workflow 的 suite 菜单不一致'
has "结果覆盖校验" 'name: Verify full-suite coverage'
has "缺失条目直接红" 'msg = "以下条目被选中却没有 result.json："'
has "unified 失败时只告警（不掩盖首错）" 'RUN_OUTCOME: ${{ steps.unified.outcome }}'

printf '\n== 6) 报告与 artifact\n'
has "汇总原文进 job 日志" 'target/test-runs/last-report.md'
has "汇总打包再传" 'xn-test-logs-${{ inputs.suite }}-${{ matrix.arch }}.tar.gz'
has "上传 artifact" 'uses: actions/upload-artifact'

if [[ "$fail" -ne 0 ]]; then
	printf '\nworkflow-tests: 有检查失败\n' >&2
	exit 1
fi
printf '\nworkflow-tests: 全部通过\n'
