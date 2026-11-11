#!/usr/bin/env bash
# 离线自测 .github/scripts/apt-install.sh：镜像兜底、源改写、失败汇总。
#
#   ./xn/tests/apt-install.test.sh
#
# 不联网、不碰 /etc：apt-get 用 PATH 里的桩，sudo 关掉（SUDO=），
# 镜像文件 / sources / lists 全指向临时目录。
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$here/../.."
script="$root/.github/scripts/apt-install.sh"

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
has_line() { # has_line <描述> <文件> <字面串>
	check "$1" grep -qxF -- "$3" "$2"
}

[[ -f "$script" ]] || { echo "找不到 $script" >&2; exit 2; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# ---------------------------------------------------------------- apt-get 桩
# $1=update 让前 N 次 update 失败；$2=install 非 0 时 install 失败。
# 每个调用一行写进 APT_STUB_LOG，方便断言调用顺序。
stub="$tmp/bin"
mkdir -p "$stub"
cat >"$stub/apt-get" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$APT_STUB_LOG"
case "$1" in
update)
	n=$(cat "$APT_STUB_COUNT" 2>/dev/null || echo 0)
	n=$((n + 1))
	echo "$n" >"$APT_STUB_COUNT"
	(( n <= ${APT_STUB_UPDATE_FAILS:-0} )) && exit 1
	exit 0
	;;
install)
	(( ${APT_STUB_INSTALL_FAILS:-0} )) && exit 1
	exit 0
	;;
esac
exit 0
STUB
chmod +x "$stub/apt-get"

export PATH="$stub:$PATH"
export SUDO=""
export APT_SOURCES_LIST="$tmp/sources.list"
export APT_SOURCES_DIR="$tmp/sources.list.d"
mkdir -p "$APT_SOURCES_DIR"

new_case() { # new_case <名字>
	local d="$tmp/$1"
	mkdir -p "$d/lists"
	export APT_MIRRORS_FILE="$d/apt-mirrors.txt"
	export APT_LISTS_DIR="$d/lists"
	export APT_STUB_LOG="$d/apt.log"
	export APT_STUB_COUNT="$d/apt.count"
	: >"$APT_STUB_LOG"
	: >"$APT_STUB_COUNT"
	printf 'http://azure.archive.ubuntu.com/ubuntu/\n' >"$APT_MIRRORS_FILE"
}

run_script() { ( cd "$root" && bash "$script" "$@" ); }

# ---------------------------------------------------------------- 1) 前两个镜像 update 失败
new_case failover
export APT_MIRRORS="http://m1.example/ubuntu/ http://m2.example/ubuntu/ http://m3.example/ubuntu/"
export APT_STUB_UPDATE_FAILS=2
unset APT_STUB_INSTALL_FAILS

printf '== 1) 镜像兜底：前两个 update 失败，换到第三个\n'
if run_script curl git >"$tmp/1.out" 2>&1; then
	check "脚本最终成功" true
else
	check "脚本最终成功" false
	sed 's/^/    /' "$tmp/1.out" >&2
fi
has_line "mirror 文件停在第三个镜像" "$APT_MIRRORS_FILE" "http://m3.example/ubuntu/"
check "update 试了三次" test "$(grep -c '^update' "$APT_STUB_LOG")" = 3
check "install 只成功一次" test "$(grep -c '^install' "$APT_STUB_LOG")" = 1
check "install 带上全部包名" grep -q 'install -y -o Acquire::Retries=3 .* curl git$' "$APT_STUB_LOG"

# ---------------------------------------------------------------- 2) 所有镜像都失败
new_case all-fail
export APT_MIRRORS="http://m1.example/ubuntu/ http://m2.example/ubuntu/"
export APT_STUB_UPDATE_FAILS=99
unset APT_STUB_INSTALL_FAILS

printf '\n== 2) 全部镜像失败：非 0 退出，不装包，报错清楚\n'
if run_script curl >"$tmp/2.out" 2>&1; then
	check "全部失败时退出非 0" false
else
	check "全部失败时退出非 0" true
fi
check "没有调用 install" test "$(grep -c '^install' "$APT_STUB_LOG")" = 0
check "打出 ::error::" grep -q '::error::所有候选 apt 镜像都失败' "$tmp/2.out"

# ---------------------------------------------------------------- 3) 写死 azure 的 sources 也改掉
new_case rewrite
export APT_MIRRORS="http://archive.ubuntu.com/ubuntu/"
unset APT_STUB_UPDATE_FAILS APT_STUB_INSTALL_FAILS
# http / https 两种写法都要换掉；mirror 文件故意不存在，脚本要自己补出来。
rm -f "$APT_MIRRORS_FILE"
printf 'Types: deb\nURIs: http://azure.archive.ubuntu.com/ubuntu/\nSuites: noble\n' \
	>"$APT_SOURCES_DIR/ubuntu.sources"
printf 'deb https://azure.archive.ubuntu.com/ubuntu/ noble main\n' \
	>"$APT_SOURCES_DIR/azure-extra.list"

printf '\n== 3) 把写死 azure 的 sources 也替换（含 https），并补出 mirror 文件\n'
if run_script cmake >"$tmp/3.out" 2>&1; then
	check "脚本成功" true
else
	check "脚本成功" false
	sed 's/^/    /' "$tmp/3.out" >&2
fi
has_line "sources 换成主源" "$APT_SOURCES_DIR/ubuntu.sources" "URIs: http://archive.ubuntu.com/ubuntu/"
check "sources 里不再有 azure" bash -c "! grep -q azure '$APT_SOURCES_DIR/ubuntu.sources'"
check "https 的 .list 也换成主源" grep -qF 'deb http://archive.ubuntu.com/ubuntu/ noble main' "$APT_SOURCES_DIR/azure-extra.list"
has_line "mirror 文件被补出来" "$APT_MIRRORS_FILE" "http://archive.ubuntu.com/ubuntu/"
check "没有留下 sed 备份" bash -c "! ls '$APT_SOURCES_DIR'/*.bak >/dev/null 2>&1"

# ---------------------------------------------------------------- 4) 没给包名
new_case no-args
printf '\n== 4) 没给包名：用法错误退出 2\n'
run_script >"$tmp/4.out" 2>&1
rc=$?
check "退出码 2" test "$rc" = 2
check "打出用法" grep -q '^用法:' "$tmp/4.out"

printf '\n'
if ((fail)); then
	echo "apt-install.test.sh: 失败" >&2
	exit 1
fi
echo "apt-install.test.sh: 通过"
