#!/usr/bin/env bash
# 离线自测「发布 XN」的镜像发布约定：
#   1) 用**上游**的 Dockerfile / Dockerfile.armv7 构建 amd64 + arm/v7，推到 ghcr.io/leptonyu/xn；
#   2) 两个都是运行镜像：二进制**都从发布包取**（amd64 是 gnu 档、armv7 是 musl 静态档，
#      只为满足 Dockerfile.armv7 写死的 gnueabihf COPY 路径），镜像 job 里不再现编；
#      dlc.dat.xz 按上游 fixtures.lock.toml 钉的版本取 —— 摆到 Dockerfile COPY 的路径上；
#   3) 镜像里是私有上游的产物，所以和 cache / artifact 一样不能外流：
#      不落 per-arch tag、不用 buildx 的 gha 缓存、不开 provenance/sbom、不写上游 revision；
#   4) 只在「本轮真的编了普通档」时推，且普通档有失败时整档跳过（不发布半个 manifest）。
#
#   ./xn/tests/workflow-docker.test.sh
#
# 只做静态检查（grep yml），不联网、不跑 action；改 workflow 时当回归网。
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
wf="$here/../../.github/workflows/xn.yml"

[[ -f "$wf" ]] || { echo "找不到 $wf" >&2; exit 2; }

# 只看真正的配置/脚本，不看注释：文件头会解释「为什么不用 type=gha / 不写 revision」，
# 按整篇 grep 会把这些说明当成违规。
stripped="$(mktemp)"
trap 'rm -f "$stripped"' EXIT
sed -E '/^[[:space:]]*#/d' "$wf" > "$stripped"

# docker job 自己的片段（到下一个 job 键为止，和 job 顺序无关）。
docker_job="$(awk '/^  docker:$/ { f = 1 } f && /^  [a-z][a-z0-9_-]*:$/ && $0 != "  docker:" { exit } f' "$stripped")"
[[ -n "$docker_job" ]] || { echo "找不到 docker job（$wf）" >&2; exit 2; }

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
	check "$1" grep -qF -- "$2" "$stripped"
}
absent() { # absent <描述> <必须不出现的字面串>
	local what="$1" pat="$2"
	if grep -qF -- "$pat" "$stripped"; then
		printf '  FAIL %s（workflow 里还有：%s）\n' "$what" "$pat" >&2
		fail=1
	else
		printf '  ok   %s\n' "$what"
	fi
}
in_job() { # in_job <描述> <docker job 里必须出现的字面串>
	local what="$1" pat="$2"
	if printf '%s\n' "$docker_job" | grep -qF -- "$pat"; then
		printf '  ok   %s\n' "$what"
	else
		printf '  FAIL %s（docker job 里没有：%s）\n' "$what" "$pat" >&2
		fail=1
	fi
}
not_in_job() { # not_in_job <描述> <docker job 里必须不出现的字面串>
	local what="$1" pat="$2"
	if printf '%s\n' "$docker_job" | grep -qF -- "$pat"; then
		printf '  FAIL %s（docker job 里还有：%s）\n' "$what" "$pat" >&2
		fail=1
	else
		printf '  ok   %s\n' "$what"
	fi
}

printf '== 1) 镜像目标：ghcr.io/leptonyu/xn\n'
check "有 docker job" grep -qx '  docker:' "$stripped"
in_job "镜像名是 ghcr.io/leptonyu/xn" 'IMAGE: ghcr.io/leptonyu/xn'
in_job "job 有 packages: write" 'packages: write'
in_job "用 GITHUB_TOKEN 登录 ghcr" 'password: ${{ secrets.GITHUB_TOKEN }}'
in_job "login 走 ghcr.io registry" 'registry: ghcr.io'

printf '\n== 2) 用上游 Dockerfile，按平台各建一档\n'
in_job "amd64 用上游 Dockerfile" 'DOCKERFILE_X86: Dockerfile'
in_job "armv7 用上游 Dockerfile.armv7" 'DOCKERFILE_ARM: Dockerfile.armv7'
in_job "amd64 平台" 'PLATFORM_X86: linux/amd64'
in_job "armv7 平台" 'PLATFORM_ARM: linux/arm/v7'
in_job "有 QEMU（arm 层要在 amd64 runner 上展开）" 'docker/setup-qemu-action@'
in_job "上游 checkout 供 Dockerfile/源码使用" 'repository: leptonyu/xn'
in_job "Dockerfile 找不到就报错（布局变了不会静默跳过）" '镜像构建入口'

printf '\n== 3) 运行镜像要的产物：两档都来自发布包 + dlc\n'
in_job "amd64 二进制取自发布包" 'asset="xn.$TRIPLE_X86.tar.xz"'
in_job "armv7 二进制取自发布包（musleabihf）" 'TRIPLE_ARM_PKG: armv7-unknown-linux-musleabihf'
in_job "armv7 发布包路径" 'asset="xn.$TRIPLE_ARM_PKG.tar.xz"'
in_job "发布包先校验 sha256" 'sha256sum -c'
in_job "amd64 二进制摆到 Dockerfile COPY 的路径" '"$src/target/$TRIPLE_X86/release/xn"'
in_job "armv7 二进制摆到 Dockerfile.armv7 COPY 的路径" '"$src/target/$TRIPLE_ARM/release/xn"'
in_job "随附第三方声明也摆好" '"$src/target/THIRD-PARTY-NOTICES.txt"'
in_job "发布包里缺 notices 时明确报错" '里没有 $f（Dockerfile 要 COPY 它'
in_job "dlc.dat.xz 按上游锁文件取" 'fixtures.lock.toml'
in_job "dlc 也校验 sha256" "printf '%s  dlc.dat.xz\\n'"
in_job "锁文件取不到/校验不过时退回最新 release" \
	'https://github.com/leptonyu/dockerized-packages/releases/latest/download/dlc.dat.xz'
in_job "退回时打 warning（不是静默换源）" '::warning::锁文件那份 dlc.dat.xz 取不到或校验不过'

printf '\n== 4) 不现编 armv7（省一次交叉编译）\n'
not_in_job "不装编译依赖（apt-get）" 'apt-get install'
not_in_job "不装 Rust（rustup）" 'rustup'
not_in_job "不调上游 release.sh 现编" 'release.sh'
not_in_job "不装 cargo-zigbuild / zig" 'cargo-zigbuild'
in_job "timeout 按「只取包 + COPY」收紧到 60" 'timeout-minutes: 60'

printf '\n== 5) 私有产物不外流\n'
in_job "按 digest 推送，不落 per-arch tag" 'push-by-digest=true'
not_in_job "不用 buildx 的 gha 缓存" 'type=gha'
not_in_job "不打 provenance（attestation 会写 VCS 来源）" '--provenance=true'
not_in_job "不开 sbom" '--sbom=true'
in_job "显式关掉 provenance" '--provenance=false'
in_job "显式关掉 sbom" '--sbom=false'
not_in_job "不把上游 revision 写进镜像标签" 'org.opencontainers.image.revision'
not_in_job "不上传 public artifact" 'uses: actions/upload-artifact'
in_job "查一次 ghcr 包可见性" 'visibility='

printf '\n== 6) 合并 manifest：v<version> 必有，latest 只在两档齐时\n'
in_job "用 imagetools 合并 digest" 'docker buildx imagetools create'
in_job "v<version> 进 tag 列表" 'names=("$IMAGE:$VERSION_TAG")'
in_job "两档都齐才加 latest" 'if [[ -n "$X86_DIGEST" && -n "$ARM_DIGEST" ]]; then'
in_job "latest 的 tag" 'names+=("$IMAGE:latest")'
in_job "版本从上游 Cargo.toml 读" 'workspace.package'

printf '\n== 7) 只在真编了普通档时推，且普通档失败就整档跳过\n'
has "depends on 两个普通档" 'needs: [check, linux-x86_64, linux-armv7]'
has "至少一个普通档真编了" \
	"(needs.linux-x86_64.result == 'success' || needs.linux-armv7.result == 'success')"
has "x86_64 失败时不推" "(needs.linux-x86_64.result == 'success' || needs.linux-x86_64.result == 'skipped')"
has "armv7 失败时不推" "(needs.linux-armv7.result == 'success' || needs.linux-armv7.result == 'skipped')"
has "compare=only 不推镜像" "inputs.compare != 'only'"
in_job "target=all 时两档都建（哪怕这轮跳过已构建的那档）" \
	"needs.linux-armv7.result == 'success' || needs.check.outputs.target == 'all'"
check "docker job 不写已构建标记（跳过判定仍只看 build job）" \
	test "$(grep -c 'xn-built-.*-docker' "$stripped")" -eq 0

if ((fail)); then
	printf '\n失败：workflow 的镜像发布不满足上面的约定\n' >&2
	exit 1
fi
printf '\n通过：镜像发布走上游 Dockerfile、推 ghcr.io，且没有把私有产物放进公开存储\n'
