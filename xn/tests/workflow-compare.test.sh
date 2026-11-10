#!/usr/bin/env bash
# 离线自测「发布 XN」workflow 的两条约定：
#   1) pgo.compare 能单独跑（compare=only：不构建，直接从已发布 runtime 包解出 bin）；
#   2) check 按 build job 识别哪个子任务已经完成，跳过它、只编缺的那些。
#
#   ./xn/tests/workflow-compare.test.sh
#
# 只做静态检查（grep yml），不联网、不跑 action；逻辑用改 workflow 时的回归网。
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

printf '== 1) compare 下拉支持 only（单独跑，不构建）\n'
has "compare 有 only 选项" '- only'
has "compare 描述说明 only 不构建" 'only=完全不构建'
has "check 输出 release_tag" 'release_tag: ${{ steps.release.outputs.tag }}'
has "check 输出 bins_x86_64" 'bins_x86_64: ${{ steps.bins.outputs.x86_64 }}'
has "check 输出 bins_macos" 'bins_macos: ${{ steps.bins.outputs.macos }}'
has "only 从已发布 Cargo.toml 版本推 tag" 'tag="v$version"'
has "bins 从发布包清点" 'gh release view "$TAG"'
has "bins 检查普通 runtime 包" 'has "xn.x86_64-unknown-linux-gnu.tar.xz"'
has "bins 检查 tuned runtime 包" 'has "xn.x86_64-unknown-linux-gnu.tuned.tar.xz"'
has "compare=only 用 fetch-bin.sh 解包" './xn/fetch-bin.sh'
has "compare=true 仍从 xn-ci 取 bin" 'gh release download xn-ci'
has "x86_64 compare 只跑包齐的档" \
	"inputs.compare == 'only' && needs.check.outputs.bins_x86_64 == 'true'"
has "macOS compare 只跑包齐的档" \
	"inputs.compare == 'only' && needs.check.outputs.bins_macos == 'true'"
has "compare=only 时 build job 不跑（decide 里不看标记直接全 false）" \
	'if [ "$COMPARE" != "only" ]; then'
has "bin 每轮都传（不只 compare=true 才传）" \
	"continue-on-error: \${{ inputs.compare != 'true' }}"
has "compare=true 容忍一档已构建跳过" \
	"(needs.linux-x86_64.result == 'success' || needs.linux-x86_64.result == 'skipped')"

printf '\n== 2) check 按 build job 识别已完成的子任务\n'
for job in x86_64 x86_64_tuned armv7 macos macos_tuned; do
	has "build job ${job} 由 check 的 build_${job} 决定" \
		"if: needs.check.outputs.build_${job} == 'true'"
done
has "决定步骤忽略已完成标记" 'need() {'
has "force / 非 main ref 忽略标记" 'honor=false'
has "非 main ref 也会重编" '[ "$REF" != "main" ]'
has "check 恢复 5 个 per-job 标记" \
	'key: xn-built-${{ steps.marker.outputs.key }}-linux-x86_64'
has "check 恢复 macOS PGO 标记" \
	'key: xn-built-${{ steps.marker.outputs.key }}-macos-aarch64-tuned'

printf '\n== 3) 每个 build job 成功后才写自己的标记\n'
for job in linux-x86_64 linux-x86_64-tuned linux-armv7 macos-aarch64 macos-aarch64-tuned; do
	has "保存 ${job} 标记" \
		"key: xn-built-\${{ needs.check.outputs.cache_key }}-${job}"
done

printf '\n== 4) record 容忍跳过的普通档，但 compare=only 不记账\n'
has "record 认 skipped 的 x86_64" \
	"(needs.linux-x86_64.result == 'success' || needs.linux-x86_64.result == 'skipped')"
has "record 排除 compare=only" "inputs.compare != 'only'"
check "只有 record 看 changed" \
	test "$(grep -c "changed == 'true'" "$wf")" -eq 1

if ((fail)); then
	printf '\n失败：workflow 不再满足「compare 可单独跑 / check 按子任务跳过」的约定\n' >&2
	exit 1
fi
printf '\n通过：compare=only 与 per-job 已构建标记都在\n'
