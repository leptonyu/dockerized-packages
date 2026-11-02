# xn — PGO+BOLT 的 x86_64 GNU 构建

上游：[`leptonyu/xn`](https://github.com/leptonyu/xn)。本模块不复制调优实现，直接调用上游的：

```bash
./release.sh --tuned --target x86_64-unknown-linux-gnu
```

默认**不加** cargo features（`tun` + `ebpf` 的默认档）；需要 `quic` 等时显式传
`--features quic`。上游内部走 `scripts/build-tuned.sh all --profile pgo --bolt`：
loopback 功能套件 + 常规 nextest 采样 → PGO profile 重建 → BOLT，最后固定写：

```text
target/x86_64-unknown-linux-gnu/release/xn
target/x86_64-unknown-linux-gnu/release/xn.tuned.env
```

[`build.sh`](build.sh) 只负责取源码、跑这条命令、打包，并把资产追加到**当前的每日
release tag**（`vYYYYMMDD`，由 [`adguard.yml`](../.github/workflows/adguard.yml) 创建）。
不新建 tag、不新建 release；目标 release 不存在时直接报错。

## 快速开始

```bash
# 只构建 + 打包（不发布）
./xn/build.sh

# 构建并追加到最新一个 vYYYYMMDD release
./xn/build.sh --publish

# 明确指定每日 tag
./xn/build.sh --tag v20261102 --publish

# 只检查工具链 / 只打印命令
./xn/build.sh --check
./xn/build.sh --dry-run

# 构建成功后上传失败：不重编，直接重传
./xn/build.sh --package-only --tag v20261102 --publish

# 需要 quic 时
./xn/build.sh --features quic --publish
```

不给 `--src` 时，脚本把上游 clone/fetch 到 `xn/.cache/xn-src`，并按 `--ref`（默认
`main`）checkout。`--tuned` 还没进 `main` 时用：

```bash
./xn/build.sh --ref <分支或提交>
```

CI 用 `actions/checkout` 把上游放到指定目录，再 `--src` 传进来，避免在脚本里塞 token。

## 依赖

必须是**原生 Linux x86_64**：BOLT 需要链接期 `--emit-relocs` 的重定位节，zig 交叉档
（macOS、musl 容器）拿不到；`release.sh --tuned` 也会提前拒绝非原生 Linux。

Ubuntu 24.04 / Debian 13 一套（与上游
[`docs/dev-environment.md`](https://github.com/leptonyu/xn/blob/main/docs/dev-environment.md)
一致）：

```bash
sudo apt-get update
sudo apt-get install -y build-essential pkg-config cmake perl nasm \
  clang lld linux-tools-common linux-tools-generic \
  libclang-dev libssl-dev zlib1g-dev liblzma-dev \
  curl git xz-utils file binutils python3 openssl lsb-release

curl -fsSL https://apt.llvm.org/llvm.sh -o /tmp/llvm.sh && chmod +x /tmp/llvm.sh
sudo /tmp/llvm.sh 23
sudo apt-get install -y llvm-23 llvm-23-tools bolt-23 lld-23 clang-23

# perf：generic 包装不在 PATH 时补一条
for p in /usr/lib/linux-tools/*/perf; do [ -x "$p" ] && sudo ln -sf "$p" /usr/local/bin/perf && break; done
echo 'kernel.perf_event_paranoid=1' | sudo tee /etc/sysctl.d/99-xn-perf.conf >/dev/null
sudo sysctl --system

# Rust stable + release.sh --tuned 的两件 cargo 工具
rustup toolchain install stable --profile minimal
cargo install --locked cargo-nextest
cargo install --locked cargo-deny   # 只有生成 THIRD-PARTY-NOTICES.txt 时需要
```

`release.sh --tuned` 默认跑 `pgo.sh tests`（release 档 nextest）；没有 `cargo-nextest`
时加 `--no-tests` 只跑 loopback 套件。`--no-notices` 可跳过第三方声明生成，但发布产物
默认应带 `THIRD-PARTY-NOTICES.txt`。

GitHub 托管 runner 没有 PMU/LBR，CI 用 software event：

```bash
--event cpu-clock:u --freq 999
```

## 产物

打包根目录（tar 内）：

```text
xn
LICENSE
xn.tuned.env
THIRD-PARTY-NOTICES.txt
```

上传到 release 的资产：

```text
xn.x86_64-unknown-linux-gnu.pgo-bolt.tar.xz
xn.x86_64-unknown-linux-gnu.pgo-bolt.tar.xz.sha256sum
xn.x86_64-unknown-linux-gnu.pgo-bolt.env              # 上游 xn.tuned.env
xn.x86_64-unknown-linux-gnu.pgo-bolt.build-info.txt   # 源码 commit / 参数 / tag
xn.x86_64-unknown-linux-gnu.pgo-bolt.manifest.tsv     # 上游 run 目录有就带
xn.x86_64-unknown-linux-gnu.pgo-bolt.bolt.env         # 上游 run 目录有就带
```

`xn.tuned.env` 里已有 `build_id`、`size`、`sha256`、工具版本；`build-info.txt`
额外记录完整源码 commit 与目标 release。发布前会脱敏：`run_dir` / `workload` /
`host` / `uname` 置为 `<redacted>`，`manifest.tsv` 的绝对路径换成产物名，`bolt.env`
里的二进制 / perf / 工具路径同样脱敏。

## 独立 workflow

[`xn.yml`](../.github/workflows/xn.yml) 是独立 workflow，不跟每日 release 的 schedule
绑定：

- **不按天编译**：每小时（`:17`）只解析一次上游 `leptonyu/xn` 的 `main` SHA，只有 SHA
  变化才跑 PGO+BOLT；没有变化时 check job 几秒结束。
- 已构建的 main SHA 记在仓库变量 **`XN_LAST_MAIN_SHA`**（并用 `actions/cache` 的
  `xn-main-sha-<sha>` 标记兜底）；只在发布成功后更新，失败/取消不会记账，下一轮会重试。
- 支持上游主动触发：`repository_dispatch`，`event_type: xn-main-updated`，
  `client_payload.sha` 可选；没有 dispatch 时最多晚一小时发现更新。
- 手动 `workflow_dispatch` 可覆盖 `ref`（默认 `main`）、`tag`（默认最新 `vYYYYMMDD`）、
  `event`（默认 `cpu-clock:u`）、`features`（默认空 = 不加 quic），`force=true` 可强制重编。手动指定非 `main` 的 `ref` 不会
  改写 `XN_LAST_MAIN_SHA`。
- 目标 release 在构建前先校验存在，避免跑完 60–90 分钟才在 `gh release upload` 失败；
  留空 `tag` 时取最新一个 `vYYYYMMDD`。
- `ubuntu-latest` + software event `cpu-clock:u`，不依赖 runner PMU；安装 LLVM 23 /
  `bolt-23` / perf / nextest / cargo-deny 与上游 tag release 同口径。
- 私有上游需要仓库 secret **`XN_REPO_TOKEN`**（对 `leptonyu/xn` 至少 `contents: read`）；
  本仓库上传用 workflow 自带的 `GITHUB_TOKEN`（`contents: write`）。
- 默认**不加** cargo features；需要时在手动触发的 `features` 输入或本地 `build.sh --features quic` 里加。

`xn` workflow 失败不会影响 DNS/network 的每日 release；两个 workflow 相互独立。

## 与上游的关系

- 只读上游：不修改 `release.sh`、`scripts/`、`Cargo.toml`；`--patch-all` 等上游开关不碰。
- `--tuned` 是上游唯一的 PGO+BOLT 入口；本模块的版本门槛是
  `release.sh` 里出现 `--tuned`。上游改成新入口时，先改这里，不复制逻辑。
- 产物是**候选**：`--tuned` 的采样是合成 loopback 负载 + 测试套件，不等于线上流量；
  D-96 的同机同轮 A/B 仍要另做，脚本不声称吞吐/CPU 收益。

## Roadmap（后续扩展）

- **Docker / musl**：容器里跑 `x86_64-unknown-linux-musl`；BOLT 仍需要原生 Linux +
  `--emit-relocs`，musl 档能否保留重定位要单独验证。当前 `release.sh --tuned` 只做
  target == host 的 gnu 档，容器化时复用同一 `build.sh` 的打包/发布段。
- **macOS**：只能做 PGO 的 collect/optimize（zig 交叉），BOLT 不可用；届时增加
  `--no-bolt` 分支，产物命名区分 `.pgo.`，不覆盖本模块的 `.pgo-bolt.` 资产。
- **发布目标**：`--release-repo` 已可切到 `leptonyu/xn`；等每日 tag 不再是唯一消费面时，
  再加 xn repo 的 tag/release 创建逻辑。

## 注意

- `--publish` 只追加资产，不创建 release。目标 release 不存在时先等
  `adguard.yml` 的 `dns` job 建好，或显式 `--tag` 指向已存在的 tag。
- 每日 release 会被 [`delete-releases.yml`](../.github/workflows/delete-releases.yml)
  按保留策略清理；tuned xn 只保证在当前每日 tag 上可取。
- `--package-only` 不重跑构建，但会重新生成 sha256、build-info 和 tarball；用于上传重试。
