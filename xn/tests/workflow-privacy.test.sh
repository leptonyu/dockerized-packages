#!/usr/bin/env bash
# 离线自测「发布 XN」workflow 的隐私约束：本仓库 public、上游 leptonyu/xn private，
# 所以 workflow 里**不能**出现从上游派生的 cache / artifact。
#
#   ./xn/tests/workflow-privacy.test.sh
#
# 只做静态检查（grep yml），不联网、不跑 action。改 workflow 时如果又加回
# `actions/upload-artifact` 或把上游 checkout 塞进 `actions/cache` 的 path，这里会红。
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

printf '== 1) public artifact 不再上传/下载私有产物\n'
absent "没有 actions/upload-artifact" 'uses: actions/upload-artifact'
absent "没有 actions/download-artifact" 'uses: actions/download-artifact'

printf '\n== 2) actions/cache 只承载匿名化的「已构建」标记\n'
# 取每个 actions/cache 步骤里的 path:，必须全是 .xn-built-sha
# （actions/checkout 也有 path: .cache/xn-src，所以不能只 grep 整篇文件）。
cache_paths="$(awk '
	/^[[:space:]]*uses: actions\/cache/ { want = 1; n++; next }
	/^[[:space:]]*- name:/ { want = 0 }
	want && /^[[:space:]]*path:/ {
		sub(/^[[:space:]]*path:[[:space:]]*/, ""); print; want = 0
	}
	END { printf "#%d\n", n }
' "$wf")"
cache_steps="${cache_paths##*#}"
cache_paths="${cache_paths%#*}"
# 5 个 build job：check 里各一次 lookup + job 成功后各存一次（标记按 job 分开）。
check "10 个 actions/cache 步骤（5 restore + 5 save）" test "$cache_steps" -eq 10
check "只有 check 做 restore（5 个）" \
	test "$(grep -c 'uses: actions/cache/restore' "$wf")" -eq 5
check "只有 build job 做 save（5 个）" \
	test "$(grep -c 'uses: actions/cache/save' "$wf")" -eq 5
check "cache 的 path 全是 .xn-built-sha（没有上游 checkout）" \
	test "$(printf '%s\n' "$cache_paths" | sed '/^$/d' | grep -cv '^\.xn-built-sha$')" -eq 0
absent "cache key 不带上游 SHA" 'key: xn-main-sha-'
check "标记 key 用摘要 + job 名：xn-built-<sha256>-<job>" \
	grep -qF 'key: xn-built-${{ needs.check.outputs.cache_key }}-' "$wf"
check "标记内容只写 built" \
	grep -qF "printf 'built" "$wf"

printf '\n== 3) bin 中转走私有 release，而不是公开存储\n'
check "compare 从私有 release 取 bin" \
	grep -qF 'gh release download xn-ci' "$wf"
check "build job 把 bin 传到私有 release" \
	grep -qF 'gh release upload xn-ci' "$wf"

printf '\n== 4) 镜像（docker job）也不把私有层/元数据放进 public 存储\n'
# 只看真正的配置：文件头的注释会解释「为什么不用 type=gha / 不开 provenance」。
stripped="$(mktemp)"
trap 'rm -f "$stripped"' EXIT
sed -E '/^[[:space:]]*#/d' "$wf" > "$stripped"
no_code() { # no_code <描述> <必须不出现的字面串>
	local what="$1" pat="$2"
	if grep -qF -- "$pat" "$stripped"; then
		printf '  FAIL %s（workflow 里还有：%s）\n' "$what" "$pat" >&2
		fail=1
	else
		printf '  ok   %s\n' "$what"
	fi
}
no_code "不用 buildx 的 gha 缓存（层就是私有编译产物）" 'type=gha'
no_code "不打 provenance（attestation 会写 VCS 来源）" '--provenance=true'
no_code "不把上游 revision 写进镜像标签" 'org.opencontainers.image.revision'

if ((fail)); then
	printf '\n失败：workflow 违反了「不缓存/不上传上游派生内容」的约束\n' >&2
	exit 1
fi
printf '\n通过：workflow 没有把上游派生的内容放进 public cache / artifact\n'
