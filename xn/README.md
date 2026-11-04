# xn — PGO+BOLT 的 x86_64 GNU 构建

上游：[`leptonyu/xn`](https://github.com/leptonyu/xn)。本模块不复制调优实现，直接调用上游的：

```bash
./release.sh --tuned --target x86_64-unknown-linux-gnu --pack
```

`--pack` 会把 runtime 包、trace 包、`SHA256SUMS` 一起生成到 `target/<triple>/release/`；
本模块**不再自己打包**，只调用、校验、上传。

默认**不加** cargo features（`tun` + `ebpf` 的默认档）；需要 `quic` 等时显式传
`--features quic`。上游内部走 `scripts/build-tuned.sh all --profile pgo --bolt`：
loopback 功能套件 + 常规 nextest 采样 → PGO profile 重建 → BOLT，最后固定写：

```text
target/x86_64-unknown-linux-gnu/release/xn
target/x86_64-unknown-linux-gnu/release/xn.tuned.env
```

[`build.sh`](build.sh) 只负责取源码、跑这条命令、校验产物、复制到 `xn/dist/`，外加把
`cidr` / `xn-tui` 单独打成不调优的小包，
并发布回 **`XN_REPO`（默认 `leptonyu/xn`）的 `v<Cargo.toml version>` release**。tag
直接从上游 `Cargo.toml` 的 workspace 版本读取（当前会得到 `v6.0.0`）；release 不存在
就新建，存在就追加资产。

## 快速开始

```bash
# 只构建 + 打包（不发布）
./xn/build.sh

# 构建并发布到 v<Cargo.toml version>（release 不存在会自动新建）
./xn/build.sh --publish

# 明确指定 release tag
./xn/build.sh --tag v6.1.0 --publish

# 只检查工具链 / 只打印命令
./xn/build.sh --check
./xn/build.sh --dry-run

# 构建成功后上传失败：不重编，直接用 target/<triple>/release/ 里现成的产物重传
./xn/build.sh --package-only --tag v6.0.0 --publish

# 不想要 extras（cidr / xn-tui）
./xn/build.sh --no-extras --publish

# 需要 quic 时
./xn/build.sh --features quic --publish
```

不给 `--src` 时，脚本用 `git clone --depth 1 --single-branch --branch <ref>` 把上游
放到 `xn/.cache/xn-src`，只取 `--ref`（默认 `main`）这一个提交，不拉全历史/tags；已有
checkout 时用 `git fetch --depth 1 origin <ref>`。`--tuned` 还没进 `main` 时用：

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

打包由上游 `release.sh --tuned --pack` 完成，本模块只调用、校验、上传。产物落在
`target/x86_64-unknown-linux-gnu/release/`，`build.sh` 再复制到 `--out-dir`（默认 `xn/dist/`）：

```text
xn.x86_64-unknown-linux-gnu.pgo-bolt.tar.xz        # runtime 包
xn.x86_64-unknown-linux-gnu.pgo-bolt.trace.tar.xz  # trace 包
SHA256SUMS                                         # 两行 sha256 filename
```

- **runtime 包**：`xn` / `LICENSE` / `docs/configuration.md` / `THIRD-PARTY-NOTICES.txt`。
- **trace 包**：`trace-files.txt` 列出的诊断文件（各步骤日志、`manifest.tsv`、`bolt.env`、
  `hot-functions.tsv`、`xn.fdata` 等）+ `xn.tuned.env` + 两份清单 +（可选）`build.log` /
  `build-info.txt`。`trace-replay-files.txt` 里列的 `perf.data` / `xn.stage2` **只留清单、
  不打进包**；需要逐字节重放 BOLT 时另收。
- **SHA256SUMS**：`(cd xn/dist && shasum -a 256 -c SHA256SUMS)`。
- flavor：Linux 上是 `pgo-bolt`，macOS PGO-only 自动变 `pgo`。`build.sh` 用
  `xn.*.tar.xz` / `xn.*.trace.tar.xz` glob 认产物，不写死 flavor。
- 发布时上传的就是这三份；`build.sh` 还会把 `trace-files.txt` / `trace-replay-files.txt`
  的生成交给上游（`release.sh --pack`），不在本地做任何裁剪。

**额外二进制 `cidr` / `xn-tui`（不调优，`build.sh` 自己打）**：

```text
cidr.x86_64-unknown-linux-gnu.tar.xz      (+ .sha256sum)   # cidr / LICENSE / THIRD-PARTY-NOTICES.txt
xn-tui.x86_64-unknown-linux-gnu.tar.xz    (+ .sha256sum)   # xn-tui / LICENSE / THIRD-PARTY-NOTICES.txt
```

- 上游 package 分别是 `xn-cidr-bin` / `xn-tui-bin`（交付的 bin 名才是 `cidr` / `xn-tui`）；
  它们不在 xn 的热路径上，所以只做普通 `release` 构建，不跑 PGO/BOLT。
- 构建走上游 `./release.sh cidr xn-tui --target <triple>`：上游逐包单独调 cargo
  （一次写多个 `-p` 会做 feature 合并，`xn` 的 reqwest/rustls 会被带进 `xn-tui`，白胖 2 MB）。
- `--extras "cidr xn-tui"` 换/加列表，`--no-extras` 全关；`--package-only` 不编译，
  `target[/<triple>]/release/` 里没有就报错（要跳过用 `--no-extras`）。

## 独立 workflow

[`xn.yml`](../.github/workflows/xn.yml) 是独立 workflow，不与 `adguard.yml` 的每日
schedule 绑定：

- **不按天编译**：每小时（`:17`）只解析一次上游 `leptonyu/xn` 的 `main` SHA，只有 SHA
  变化才跑 PGO+BOLT；没有变化时 check job 几秒结束。
- 已构建的 main SHA 记在仓库变量 **`XN_LAST_MAIN_SHA`**（并用 `actions/cache` 的
  `xn-main-sha-<sha>` 标记兜底）；只在发布成功后更新，失败/取消不会记账，下一轮会重试。
- 支持上游主动触发：`repository_dispatch`，`event_type: xn-main-updated`，
  `client_payload.sha` 可选；没有 dispatch 时最多晚一小时发现更新。
- 默认跟踪 `main`；需要临时从别的分支构建时，用手动 `workflow_dispatch` 的 `ref` 输入。
- 手动 `workflow_dispatch` 可覆盖 `ref`（默认 `main`）、`tag`（默认 `v<Cargo.toml version>`）、
  `event`（默认 `cpu-clock:u`）、`features`（默认空 = 不加 quic），`force=true` 可强制重编。手动指定非 `main` 的 `ref` 不会
  改写 `XN_LAST_MAIN_SHA`。
- 留空 `tag` 时直接读上游 `Cargo.toml` 的版本（`v<version>`）；release 不存在时由
  `build.sh` 新建，`--target` 是本次构建的上游 commit；存在时只追加资产。
- `ubuntu-latest` + software event `cpu-clock:u`，不依赖 runner PMU；安装 LLVM 23 /
  `bolt-23` / perf / nextest / cargo-deny 与上游 tag release 同口径。
- 私有上游需要仓库 secret **`XN_REPO_TOKEN`**（对 `leptonyu/xn` **`contents: write`**：
  既要 checkout，也要创建/更新 release）；本仓库只用它自己的 `GITHUB_TOKEN` 更新
  `XN_LAST_MAIN_SHA`（`actions: write`）。
- 默认**不加** cargo features；需要时在手动触发的 `features` 输入或本地 `build.sh --features quic` 里加。
- `Upload build outputs` 收集 `xn/dist/*.tar.xz`、`xn/dist/*.sha256sum` 和
  `xn/dist/SHA256SUMS`（runtime + trace + 校验和，加 extras 两个包），`build.log` 已经在
  trace 包里，不再单独上传。

`xn` workflow 与 DNS/network 的每日 release 相互独立；它失败不会撤回其它 workflow 的资产。

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
- **发布目标**：默认回到 `XN_REPO` / `--repo` 的 `v<version>` release；其他仓库用
  `--release-repo` 指定（不会自动在其上创建 release）。

## 注意

- `--publish` 默认在 `XN_REPO` 上发 `v<Cargo.toml version>`：不存在就新建 release，
  存在就追加/覆盖同名资产（`--clobber`）。上游仓库的 tag 若已存在但 release 不存在，
  会在该 tag 上补建 release。
- `--release-repo` 指向非上游仓库时，只追加到已有 release，不会在别的仓库自动建 tag。
- `--package-only` 不重跑构建，直接用 `target/<triple>/release/` 里现成的三个文件重传；
  缺文件就报错（先跑一次完整构建），也不编译 extras（缺就用 `--no-extras`）。
- 打包内容（收哪些文件、perf.data 收不收）完全由上游 `trace-files.txt` /
  `trace-replay-files.txt` 决定，本模块不再有 `--perf-data` / `--trace-exclude` 这类裁剪开关。
