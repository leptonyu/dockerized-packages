#!/usr/bin/env bash
#
# 仓库级测试入口：先给所有 shell 脚本做语法检查，再跑各模块的离线测试。
#
#   ./xn/tests/run-all.sh              # 全部
#   ./xn/tests/run-all.sh publish      # 只跑路径里含 publish 的测试
#
# 约定：任何模块的 `tests/*.test.sh` 都是离线、可独立运行、失败返回非 0 的脚本；
# 新增测试直接放进对应模块的 tests/，本脚本和 CI workflow 都不用改。测试统一以
# 仓库根为 cwd 运行，需要的数据/临时目录自己准备（参见 xn/tests/publish-retry.test.sh）。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
	echo "xn/tests/run-all.sh: 需要在 git 工作区里运行（用 git ls-files 发现目录和测试）" >&2
	exit 2
fi

filter="${1:-}"
fail=0

# 只看仓库跟踪的文件：本地 checkout 的 dnsmasq-china-list / domain-list-community
# 等上游目录、xn/.cache 里的上游源码都不属于本仓库的测试套件。
#
# 用显式计数器而不是 ${#arr[@]}：macOS 自带的 bash 3.2 在 set -u 下对空数组
# 做长度展开会直接报 unbound variable。
tests=()
tests_count=0
while IFS= read -r f; do
	[[ -n "$f" ]] || continue
	# 工作区里已删除、但删除还没提交：git ls-files 仍会列出，跳过。
	[[ -f "$f" ]] || continue
	tests[tests_count]="$f"
	tests_count=$((tests_count + 1))
done < <(git ls-files -- '*.test.sh' | sort)

scripts=()
scripts_count=0
while IFS= read -r f; do
	[[ -n "$f" ]] || continue
	[[ -f "$f" ]] || continue
	scripts[scripts_count]="$f"
	scripts_count=$((scripts_count + 1))
done < <(git ls-files -- '*.sh' | sort)

# ---------------------------------------------------------------- 1) 语法检查
# 只做 bash -n：不执行、不联网。脚本都声明了 bash，用 bash 解析即可。
syntax_failed=0
printf '== 语法检查（%d 个脚本）\n' "$scripts_count"
for ((i = 0; i < scripts_count; i++)); do
	s="${scripts[i]}"
	if bash -n "$s"; then
		printf '  ok   %s\n' "$s"
	else
		printf '  FAIL %s\n' "$s" >&2
		syntax_failed=$((syntax_failed + 1))
		fail=1
	fi
done

# ---------------------------------------------------------------- 2) 离线测试
selected=()
selected_count=0
for ((i = 0; i < tests_count; i++)); do
	t="${tests[i]}"
	if [[ -n "$filter" && "$t" != *"$filter"* ]]; then
		continue
	fi
	selected[selected_count]="$t"
	selected_count=$((selected_count + 1))
done

printf '\n== 离线测试（%d 个）\n' "$selected_count"
if ((selected_count == 0)); then
	printf '  （没有匹配的测试）\n'
	if [[ -z "$filter" ]]; then
		printf 'xn/tests/run-all.sh: 没有发现任何 *.test.sh\n' >&2
		exit 1
	fi
fi

ran=0
test_failed=0
for ((i = 0; i < selected_count; i++)); do
	t="${selected[i]}"
	ran=$((ran + 1))
	printf -- '\n---- [%d/%d] %s\n' "$ran" "$selected_count" "$t"
	if bash "$t"; then
		printf -- '---- 通过 %s\n' "$t"
	else
		printf -- '---- 失败 %s\n' "$t" >&2
		test_failed=$((test_failed + 1))
		fail=1
	fi
done

# ---------------------------------------------------------------- 3) 汇总
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
	{
		echo '### 仓库测试套件'
		echo ''
		echo '| 项目 | 失败 / 总数 |'
		echo '| --- | --- |'
		echo "| shell 语法检查 | ${syntax_failed} / ${scripts_count} |"
		echo "| 离线测试 | ${test_failed} / ${ran} |"
	} >>"$GITHUB_STEP_SUMMARY"
fi

if ((fail)); then
	printf '\n测试套件失败：语法 %d 个失败，测试 %d/%d 个失败\n' \
		"$syntax_failed" "$test_failed" "$ran" >&2
	exit 1
fi
printf '\n测试套件通过：%d 个脚本、%d 个测试\n' "$scripts_count" "$ran"
