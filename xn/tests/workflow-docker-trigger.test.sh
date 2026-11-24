#!/usr/bin/env bash
# 离线自测「发布 XN」workflow 到上游镜像发布的接力：
#   x86_64 普通包发出去之后，`trigger-docker` 用 `repository_dispatch` 触发上游
#   `leptonyu/xn` 的 `docker.yml`（event_type: xn-release，client_payload.tag）。
#
#   ./xn/tests/workflow-docker-trigger.test.sh
#
# 只做静态检查（grep yml），不联网、不跑 action；改 workflow 时的回归网。
# 上游 docker.yml 那一侧（接收 repository_dispatch）不在本仓库，这里不检查。
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
wf="$here/../../.github/workflows/xn.yml"

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

[[ -f "$wf" ]] || { echo "找不到 $wf" >&2; exit 2; }

printf '== 1) trigger-docker 只在 x86_64 普通包发出去之后跑\n'
has "有 trigger-docker job" 'trigger-docker:'
has "依赖 check + linux-x86_64" 'needs: [check, linux-x86_64]'
has "check 成功" "needs.check.result == 'success'"
has "linux-x86_64 成功（skipped 不重按）" "needs.linux-x86_64.result == 'success'"
has "trigger-docker 的 tag 来自 check 的 release_tag" \
	'TAG: ${{ needs.check.outputs.release_tag }}'
# 触发条件只认这两个 need：tuned / armv7 / macOS 不进镜像，不能出现在这个 job 的
# 可执行部分（注释里提到它们是说明文字，剥掉再查）。
job_block="$(awk '/^  trigger-docker:$/ { want = 1 } want' "$wf")"
job_code="$(sed '/^[[:space:]]*#/d' <<<"$job_block")"
check "提取到 trigger-docker job" test -n "$job_block"
check "条件只有两条（check / linux-x86_64）" \
	test "$(grep -c "needs\..*\.result == 'success'" <<<"$job_code")" -eq 2
check "不碰 tuned 档" \
	test "$(grep -ci 'tuned' <<<"$job_code")" -eq 0
check "不碰 armv7 / macOS" \
	test "$(grep -ciE 'armv7|macos' <<<"$job_code")" -eq 0

printf '\n== 2) 走 repository_dispatch（不是 workflow_dispatch）\n'
has "调 create-a-repository-dispatch-event" \
	'gh api --method POST repos/leptonyu/xn/dispatches'
has "event_type 是 xn-release" 'event_type:"xn-release"'
has "payload 带 tag" 'client_payload:{tag:$tag}'
has "用已有 PAT（GITHUB_TOKEN 跨仓库无效）" \
	'GH_TOKEN: ${{ secrets.XN_REPO_TOKEN }}'
check "没有用 workflow_dispatch 端点" \
	test "$(grep -c 'actions/workflows/.*/dispatches' "$wf")" -eq 0

printf '\n== 3) 失败不静默：重试 + 变红\n'
has "重试 3 次" 'for i in 1 2 3; do'
has "重试间隔" 'sleep $((i * 5))'
has "最终失败打 ::error:: 并退出非 0" \
	'触发 leptonyu/xn 的 docker workflow 失败'
has "失败时给出手动补的口子" \
	'https://github.com/leptonyu/xn/actions/workflows/docker.yml'

printf '\n== 4) release tag 每轮都解析（不只 compare=only）\n'
has "解析步骤在" 'name: Resolve release tag'
has "check 仍输出 release_tag" 'release_tag: ${{ steps.release.outputs.tag }}'
# 只剩「清点 compare 用的发布包」那一步还挂 compare=only；解析步骤不能再被它挡住，
# 否则定时触发的 trigger-docker 拿不到 tag。
check "compare=only 的守卫只剩 1 处" \
	test "$(grep -cF "if: \${{ inputs.compare == 'only' }}" "$wf")" -eq 1
step_block="$(awk '
	/^[[:space:]]*- name: Resolve release tag$/ { want = 1 }
	want && /^[[:space:]]*- name:/ && !/Resolve release tag/ { want = 0 }
	want { print }
' "$wf")"
check "解析步骤的块里有 id: release" \
	grep -qF 'id: release' <<<"$step_block"
check "解析步骤不再挂 compare=only" \
	test "$(grep -cF "inputs.compare == 'only'" <<<"$step_block")" -eq 0

if ((fail)); then
	printf '\n失败：x86_64 普通包发布后不再自动触发上游 docker.yml\n' >&2
	exit 1
fi
printf '\n通过：x86_64 普通包发布后会触发上游 docker.yml\n'
