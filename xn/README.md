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

[`build.sh`](build.sh) 只负责取源码、跑这条命令、打两个包（二进制包 + 全过程包），
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

# 构建成功后上传失败：不重编，直接重传（会重新生成两个包）
./xn/build.sh --package-only --tag v6.0.0 --publish

# 过程包不带 perf.data（只保留各步骤日志）
./xn/build.sh --package-only --no-perf-data --publish

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

release 上只有两个包（不再单独发布 `.sha256sum` / `.env` / `.build-info.txt` /
`.manifest.tsv` / `.bolt.env`）。

**二进制包** `xn.x86_64-unknown-linux-gnu.pgo-bolt.tar.xz`（tar 内，不带 `xn.tuned.env`）：

```text
xn
LICENSE
docs/configuration.md
THIRD-PARTY-NOTICES.txt
```

**全过程包** `xn.x86_64-unknown-linux-gnu.pgo-bolt.trace.tar.xz`：

```text
build.log          # 本次 release.sh --tuned 的完整输出
build-info.txt     # 源码 commit / 参数 / tag / 二进制包 sha256
xn.tuned.env       # 上游 xn.tuned.env（run_dir / host / uname / workload 脱敏）
run/               # 上游 run 目录原样收录，即“所有步骤”：
  manifest.tsv     #   各步骤产物清单（build-id / size / sha256）
  <step>/...       #   每个步骤的日志与产物
  **/perf.data     #   PGO / BOLT 的 perf 采样原始数据
  **/perf.fdata、03-bolt/bolt.env、perf.bolt.yaml 等
```

- 二进制包随包带上游 `docs/configuration.md`（路径不变）；`xn.tuned.env` 只留在过程包里，
  构建元数据（`build_id`、`size`、`sha256`、工具版本）都可在那里查到。
- 二进制包的 sha256 记录在 `build-info.txt` 的 `tarball_sha256`。
- `run/` 原样收录（含 `manifest.tsv` 的绝对构建路径与各步骤日志），便于复现/排查；
  `xn.tuned.env` 里的 `run_dir` 改成包内相对路径 `run`，`host` / `uname` / `workload`
  置为 `<redacted>`。
- perf.data 很大：`--perf-xz-level N` 控制过程包的 xz 级别（默认 3，`0` 最快）；只想留
  日志时用 `--no-perf-data`。过程包超过 GitHub release 单资产 2 GiB 上限时脚本会警告。
- `--publish` 时会顺手删掉旧版本单独发布的 `.sha256sum` / `.env` / `.build-info.txt` /
  `.manifest.tsv` / `.bolt.env`，保证 release 上只有两个包；要保留加 `--keep-legacy`。

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
- `Upload build outputs` 只收集 `xn/dist/*.tar.xz`（二进制包 + 过程包），过程包里已经带着
  `build.log`，不再单独上传。

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
- `--package-only` 不重跑构建，但会重新生成两个包（sha256、build-info 都在过程包里）；用于上传重试。
