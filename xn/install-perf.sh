#!/usr/bin/env bash
#
# 装一个能用的 perf，给上游 BOLT 的 stage2 采样用（Ubuntu 24.04 / Debian 13）。
#
# 为什么不直接 `apt-get install linux-tools-generic`：它是 metapackage，按
# `uname -r` 依赖 `linux-tools-<ver>-<flavor>`。Ubuntu archive 的 metapackage
# 偶尔领先于具体包（pocket 同步滞后），apt 就会整体失败：
#
#   linux-tools-generic : Depends: linux-tools-6.8.0-149-generic but it is not installable
#   E: Unable to correct problems, you have held broken packages.
#
# 见 Launchpad #2140491。这里不碰 metapackage，按「确实存在的具体包」挨个试：
#   1) perf 已经能用 → 什么都不做
#   2) linux-tools-$(uname -r)        和内核同版（带 flavor：generic / azure / kvm …）
#   3) linux-tools-<ver>              同版但不带 flavor
#   4) linux-tools-<ver>（archive 里最新的几个）  内核比 archive 的 tools 还新时
#   5) linux-perf                     Debian 的包名，perf 直接在 /usr/bin/perf
# 装完把对应的 perf 链到 /usr/local/bin/perf（linux-tools-common 的 /usr/bin/perf
# 包装脚本只认 uname -r 那一份，版本对不上时不能用）。
#
# 用法：./xn/install-perf.sh
# 需要 apt-get；非 root 时用 sudo。

set -euo pipefail

die() { printf 'install-perf: %s\n' "$*" >&2; exit 1; }
note() { printf '==> %s\n' "$*" >&2; }

maybe_sudo() {
	if [ "$(id -u)" -eq 0 ]; then
		"$@"
	else
		command -v sudo >/dev/null 2>&1 || die "不是 root，也没有 sudo"
		sudo "$@"
	fi
}

perf_ok() {
	command -v perf >/dev/null 2>&1 && perf --version >/dev/null 2>&1
}

# 装一个包；失败时把 apt 的关键报错捞出来（否则连续试几个包时看不出原因）。
install_pkg() { # $1=包名
	local log out
	log="$(mktemp)"
	if maybe_sudo env DEBIAN_FRONTEND=noninteractive \
		apt-get install -y --no-install-recommends "$1" >"$log" 2>&1; then
		rm -f "$log"
		return 0
	fi
	out="$(grep -m1 -E 'but it is not installable|^E: ' "$log" || tail -n1 "$log")"
	rm -f "$log"
	printf 'install-perf: %s 装不上：%s\n' "$1" "${out:-见 apt 输出}" >&2
	return 1
}

# 把 $1 这个包里的 perf 链到 /usr/local/bin（$1 形如 linux-tools-6.8.0-148-generic）。
link_perf() {
	local ver="${1#linux-tools-}" bin=""
	if [ -x "/usr/lib/linux-tools/$ver/perf" ]; then
		bin="/usr/lib/linux-tools/$ver/perf"
	else
		# Debian 等布局：退到版本最高的那个目录。
		bin="$(ls -d /usr/lib/linux-tools/*/perf 2>/dev/null | sort -V | tail -n1 || true)"
	fi
	[ -n "$bin" ] && [ -x "$bin" ] || return 1
	maybe_sudo ln -sf "$bin" /usr/local/bin/perf
	hash -r 2>/dev/null || true
	note "perf -> ${bin}（来自 $1）"
}

command -v apt-get >/dev/null 2>&1 || die "没有 apt-get；本脚本只处理 Ubuntu / Debian 系"

if perf_ok; then
	note "已有可用 perf：$(command -v perf)（$(perf --version 2>&1 | head -n1)）"
	exit 0
fi

note "apt-get update"
maybe_sudo apt-get update -qq
# Debian 没有 linux-tools-common（perf 直接在 linux-perf 里），有才装。
if apt-cache show linux-tools-common >/dev/null 2>&1; then
	install_pkg linux-tools-common || true
fi

kernel="$(uname -r)"
note "内核：$kernel"
cands=()
seen=" "
add_cand() { # $1=包名；去重后追加
	[ -n "$1" ] || return 0
	case "$seen" in *" $1 "*) return 0 ;; esac
	seen="$seen$1 "
	cands+=("$1")
}
add_cand "linux-tools-$kernel"
add_cand "linux-tools-${kernel%-*}"

# archive 里已发布的最新几个具体版（不带 flavor，便于按版本排序）。
while IFS= read -r p; do
	add_cand "$p"
done < <(
	apt-cache pkgnames linux-tools- 2>/dev/null \
		| grep -E '^linux-tools-[0-9][0-9.]*-[0-9]+$' \
		| sort -Vr | head -n 3 || true
)

# Debian 的 perf 不按内核版本拆包，装完 /usr/bin/perf 就能用。
if apt-cache show linux-perf >/dev/null 2>&1; then
	cands+=(linux-perf)
fi

for pkg in "${cands[@]}"; do
	note "尝试 $pkg"
	install_pkg "$pkg" || continue
	link_perf "$pkg" || true
	if perf_ok; then
		note "perf 就绪：$(command -v perf)（$(perf --version 2>&1 | head -n1)）"
		exit 0
	fi
done

die "装不上 perf（试过 linux-tools-${kernel}、同版无 flavor、archive 最新版）；见 xn/README.md 的依赖段"
