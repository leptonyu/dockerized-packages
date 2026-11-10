#!/usr/bin/env bash
# 离线自测 xn/fetch-bin.sh：从 release 的两档 runtime 包里解出 xn，写成 compare.sh
# 认的 xn.<triple>.{release,tuned}.bin；用假 gh 模拟下载，不联网。
#
#   ./xn/tests/fetch-bin.test.sh
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fetch="$here/../fetch-bin.sh"
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
fixtures="$work/fixtures"
mkdir -p "$fixtures"

# Linux 的 coreutils 是 sha256sum，macOS 默认只有 shasum；测试两边都能跑。
sha256_of() { # <file>
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1"
	else
		shasum -a 256 "$1"
	fi
}

# 两档包：包内是 xn-<version>/xn（故意放子目录，验证脚本靠文件名找 xn）。
make_pkg() { # <file> <payload>
	local file="$1" payload="$2" d
	d="$(mktemp -d "$work/pkg.XXXXXX")"
	mkdir -p "$d/xn-1.2.3"
	printf '%s\n' "$payload" >"$d/xn-1.2.3/xn"
	chmod +x "$d/xn-1.2.3/xn"
	tar -cJf "$fixtures/$file" -C "$d" xn-1.2.3
	rm -rf "$d"
}
make_pkg "xn.$target.tar.xz" plain-bin
make_pkg "xn.$target.tuned.tar.xz" tuned-bin
( cd "$fixtures" && sha256_of "xn.$target.tar.xz" >"xn.$target.tar.xz.sha256sum" )
( cd "$fixtures" && sha256_of "xn.$target.tuned.tar.xz" >"xn.$target.tuned.tar.xz.sha256sum" )

# 假 gh：只处理 `release download TAG --repo R --pattern P --dir D --clobber`。
mkdir -p "$work/bin"
cat >"$work/bin/gh" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-} ${2:-}" = "release download" ]] || { echo "fake gh: 不认识的命令 $*" >&2; exit 1; }
printf '%s\n' "$*" >>"${FAKE_GH_LOG:?}"
pat="" dir=""
shift 2
while (($#)); do
	case "$1" in
		--pattern) pat="$2"; shift 2 ;;
		--dir) dir="$2"; shift 2 ;;
		--repo|--tag) shift 2 ;;
		--clobber) shift ;;
		*) shift ;;
	esac
done
[[ -n "$pat" && -n "$dir" ]] || { echo "fake gh: 缺 --pattern / --dir" >&2; exit 1; }
src="${FIXTURES:?}/$pat"
[[ -f "$src" ]] || { echo "fake gh: release 里没有 $pat" >&2; exit 1; }
cp "$src" "$dir/$pat"
FAKE
chmod +x "$work/bin/gh"

src="$work/src"
mkdir -p "$src"
cat >"$src/Cargo.toml" <<'TOML'
[workspace]
members = ["xn"]

[workspace.package]
version = "1.2.3"
TOML

run_fetch() { # <out-dir> [extra args...]
	local out="$1"; shift
	PATH="$work/bin:$PATH" FIXTURES="$fixtures" FAKE_GH_LOG="$work/gh.log" \
		bash "$fetch" --src "$src" --out-dir "$out" --target "$target" "$@" \
		>"$work/log" 2>&1
}
log_has() { grep -qF -- "$1" "$work/log"; }

printf '== 1) 默认 tag = v<Cargo.toml version>，解出两档 bin\n'
out="$work/out1"
run_fetch "$out"
rc=$?
check "退出码 0（实际 ${rc}）" test "$rc" -eq 0
check "普通 bin 在 xn/dist 默认命名" test -f "$out/xn.$target.release.bin"
check "tuned bin 在 xn/dist 默认命名" test -f "$out/xn.$target.tuned.bin"
check "普通 bin 内容来自普通包" grep -qx 'plain-bin' "$out/xn.$target.release.bin"
check "tuned bin 内容来自 tuned 包" grep -qx 'tuned-bin' "$out/xn.$target.tuned.bin"
check "bin 有执行位" test -x "$out/xn.$target.release.bin"
check "用了 v1.2.3 tag" grep -qF 'release download v1.2.3' "$work/gh.log"
check "校验和在下载目录里跑过" log_has "xn.$target.tar.xz: OK"

printf '== 2) --tag 覆盖默认 tag\n'
: >"$work/gh.log"
out="$work/out2"
run_fetch "$out" --tag v9.9.9
rc=$?
check "退出码 0（实际 ${rc}）" test "$rc" -eq 0
check "下载用 v9.9.9" grep -qF 'release download v9.9.9' "$work/gh.log"
check "没有再推导 v1.2.3" test -z "$(grep -F 'v1.2.3' "$work/gh.log" || true)"

printf '== 3) 缺 tuned 包直接报错，不留下半套产物\n'
rm -f "$fixtures/xn.$target.tuned.tar.xz"
out="$work/out3"
run_fetch "$out"
rc=$?
check "退出码非 0（实际 ${rc}）" test "$rc" -ne 0
check "报错提到 tuned 包" grep -qF "xn.$target.tuned.tar.xz" "$work/log"

printf '== 4) 校验和不一致时失败\n'
make_pkg "xn.$target.tuned.tar.xz" tuned-bin
( cd "$fixtures" && sha256_of "xn.$target.tuned.tar.xz" >"xn.$target.tuned.tar.xz.sha256sum" )
printf 'tampered\n' >>"$fixtures/xn.$target.tuned.tar.xz"
out="$work/out4"
run_fetch "$out"
rc=$?
check "退出码非 0（实际 ${rc}）" test "$rc" -ne 0
check "报错来自校验和检查" grep -qi 'FAILED\|checksum\|校验' "$work/log"

printf '== 5) 没有 Cargo.toml 且没给 --tag 时明确报错\n'
src2="$work/empty-src"
mkdir -p "$src2"
PATH="$work/bin:$PATH" FIXTURES="$fixtures" FAKE_GH_LOG="$work/gh.log" \
	bash "$fetch" --src "$src2" --out-dir "$work/out5" --target "$target" \
	>"$work/log5" 2>&1
rc=$?
check "退出码 2（实际 ${rc}）" test "$rc" -eq 2
check "提示缺 Cargo.toml / --tag" grep -qF 'Cargo.toml' "$work/log5"

if ((fail)); then
	printf '\n失败：fetch-bin.sh 没通过离线测试\n' >&2
	exit 1
fi
printf '\n通过：fetch-bin.sh 能从发布包解出两档 bin\n'
