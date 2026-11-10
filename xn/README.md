# xn — 普通包 + PGO+BOLT 的 xn 构建

上游：[`leptonyu/xn`](https://github.com/leptonyu/xn)。本模块不复制构建/调优实现，直接调用上游的：

```bash
./release.sh --target <triple> --pack            # 普通包（所有目标都出）
./release.sh --tuned --target <triple> --pack    # tuned 包（PGO/BOLT，gnu / macOS）
```

`--pack` 会把 runtime 包、trace 包、`SHA256SUMS` 一起生成到 `target/<triple>/release/`；
本模块**不再自己打包**，只调用、校验、上传。两个档位各自成包、发到同一个 release：
`xn.<triple>.tar.xz`（普通）和 `xn.<triple>.tuned.tar.xz`（PGO/BOLT），互不覆盖。

> **现状**：`--bolt` 暂不启用（`x86_64-unknown-linux-gnu` 目前只跑 PGO）；`perf` /
> `bolt-23` 这些 BOLT 依赖照常安装，后续要启用时直接加 `--bolt`，不用再改环境。

默认**不加** cargo features（`tun` + `ebpf` 的默认档）；需要 `quic` 等时显式传
`--features quic`。上游内部走 `scripts/build-tuned.sh all --profile pgo`：
loopback 功能套件 + 常规 nextest 采样 → PGO profile 重建（加 `--bolt` 时才接 BOLT），
最后固定写：

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

Ubuntu 24.04 / Debian 13 一套，大体照上游
[`docs/dev-environment.md`](https://github.com/leptonyu/xn/blob/main/docs/dev-environment.md)，
只有 perf 的装法不同（见下）：

```bash
sudo apt-get update
sudo apt-get install -y build-essential pkg-config cmake perl nasm \
  clang lld \
  libclang-dev libssl-dev zlib1g-dev liblzma-dev \
  curl git xz-utils file binutils python3 openssl lsb-release

# perf：**不要**装 linux-tools-generic —— 它是 metapackage，按 uname -r 依赖
# linux-tools-<ver>-<flavor>；Ubuntu archive 的 metapackage 偶尔领先于具体包
# （pocket 同步滞后），apt 会整体失败：
#   linux-tools-generic : Depends: linux-tools-6.8.0-149-generic but it is not installable
#   E: Unable to correct problems, you have held broken packages.
# 见 Launchpad #2140491。脚本按「内核同版 → 同版不带 flavor → archive 最新版」
# 挑一个确实存在的具体包（Debian 用 linux-perf），链到 /usr/local/bin/perf。
./xn/install-perf.sh

curl -fsSL https://apt.llvm.org/llvm.sh -o /tmp/llvm.sh && chmod +x /tmp/llvm.sh
sudo /tmp/llvm.sh 23
sudo apt-get install -y llvm-23 llvm-23-tools bolt-23 lld-23 clang-23

echo 'kernel.perf_event_paranoid=1' | sudo tee /etc/sysctl.d/99-xn-perf.conf >/dev/null
sudo sysctl --system

# Rust stable + release.sh --tuned 的两件 cargo 工具
rustup toolchain install stable --profile minimal
cargo install --locked cargo-nextest
cargo install --locked cargo-deny   # 只有生成 THIRD-PARTY-NOTICES.txt 时需要
cargo install --locked sccache      # 可选：上游脚本探测到就 RUSTC_WRAPPER=sccache（缓存 target/sccache）
```

[`install-perf.sh`](install-perf.sh) 可以单独重跑；装完会打印最终选中的 perf 与版本。
`build.sh` 在编译前也会检查 `perf`，装不上就直接退出，不会等一小时才在 BOLT
stage2 里失败。内核比 `linux-tools` 包新的时候（archive 还没同步）perf 会略旧于内核，
software event 采样不受影响。

`release.sh --tuned` 默认跑 `pgo.sh tests`（release 档 nextest）；没有 `cargo-nextest`
时加 `--no-tests` 只跑 loopback 套件。`--no-notices` 可跳过第三方声明生成，但发布产物
默认应带 `THIRD-PARTY-NOTICES.txt`。

BOLT 启用时，GitHub 托管 runner 没有 PMU/LBR，用 software event（未启用 BOLT 时
`--event` 会被上游忽略，构建日志里会提示「本次未加 --bolt」）：

```bash
--event cpu-clock:u --freq 999
```

## 产物

打包由上游 `release.sh --pack`（tuned 档加 `--tuned`）完成，本模块只调用、校验、上传。
`build.sh --flavors` 决定编哪几档：`release,tuned`（gnu / macOS 默认）、`release`、`tuned`。
产物落在 `target/<triple>/release/`（**host 的普通档落在 `target/release/`** —— 上游 host 构建
不传 `--target`），`build.sh` 两处都扫，再改名复制到 `--out-dir`（默认 `xn/dist/`）：

```text
xn.x86_64-unknown-linux-gnu.tar.xz                # 普通 runtime 包（xn/cidr/xn-tui/xns，所有目标）
xn.x86_64-unknown-linux-gnu.tar.xz.sha256sum
xn.x86_64-unknown-linux-gnu.tuned.tar.xz          # tuned runtime 包（PGO/BOLT）
xn.x86_64-unknown-linux-gnu.tuned.tar.xz.sha256sum
xn.x86_64-unknown-linux-gnu.tuned.trace.tar.xz    # tuned 的 trace 包
xn.x86_64-unknown-linux-gnu.tuned.trace.tar.xz.sha256sum
SHA256SUMS                                        # 上游生成的汇总，只做本地校验，不发布
```

- **普通 runtime 包**：`xn` / `cidr` / `xn-tui` / `xns` / `LICENSE` / `docs/configuration.md` /
  `THIRD-PARTY-NOTICES.txt`（一次 workspace 构建，四个 bin 全在里面；不再单独发
  `cidr.*` / `xn-tui.*` 包）。
- **tuned runtime 包**：只有 `xn`（上游 `--tuned` 只编 xn）+ 同样的 LICENSE / docs / notices。
- **PGO 覆盖全部 crate（full PGO）**：tuned 档不传任何 PGO 范围开关，依赖也吃
  `-Cprofile-use`。只给 `xn` crate 加 profile-use（上游的 `--xn-only`）会让体积几乎不缩
  （实测 +0.099%），也没有可复现的吞吐收益（GOAL-094）；full PGO 才能拿回体积/数据面收益
  （2026-11-04 NUC：18.46MB → 15.88MB）。代价是客户端 CPU/GB 有已知回退（GOAL-094），
  发版前用 `pgo.compare` 留同机 A/B 证据。
- **采样只采数据面（GOAL-117）**：tuned 默认 `--no-tests`，nextest 只做正确性门禁、不 merge；
  上游默认 workload 是 `tune-workload.sh --coverage --dns`。server/client profraw 必须落盘，
  profile 形状不合格（ws/tunnel 全 0）会在 optimize 前失败。
- **trace 包**：`trace-files.txt` 列出的诊断文件（各步骤日志、`manifest.tsv`、`bolt.env`、
  `hot-functions.tsv`、`xn.fdata` 等）+ `xn.tuned.env` + 两份清单 +（可选）`build.log` /
  `build-info.txt`。`trace-replay-files.txt` 里列的 `perf.data` / `xn.stage2` **只留清单、
  不打进包**；需要逐字节重放 BOLT 时另收。
- **校验和**：每个包一个同名的 `<asset>.sha256sum`（发布的就是这个），
  `(cd xn/dist && shasum -a 256 -c xn.x86_64-unknown-linux-gnu.tuned.tar.xz.sha256sum)`；
  上游生成的 `SHA256SUMS` 只用于本地校验，不再上传。
- flavor：上游产出的文件名带 flavor（Linux 是 `pgo-bolt`，macOS PGO-only 是 `pgo`，
  普通包不带 flavor）。`build.sh` 用 `xn.*.tar.xz` glob 认产物、按名字分辨档位，
  **发布时统一改名**：tuned 档 → `xn.<triple>.tuned[.trace].tar.xz`，普通档 →
  `xn.<triple>.tar.xz`；旧名字的资产会在发布时清掉。
- 发布时每个包 + 自己的 `.sha256sum` 一起上传（不再发汇总的 `SHA256SUMS`）；
  `build.sh` 还会把 `trace-files.txt` / `trace-replay-files.txt`
  的生成交给上游（`release.sh --pack`），不在本地做任何裁剪。
- **上传是逐资产做的**：每个文件单独调 `gh release upload`，`.sha256sum` 排最后；
  单个资产遇到 5xx（GitHub 的 asset API 偶发 502/503/504）或网络抖动会退避重试
  （`XN_RETRIES` 默认 4 次，`XN_RETRY_DELAY` 默认 3 秒起、翻倍至 30 秒），4xx
  （token 没权限 / release 不存在）直接失败不重试。一个资产失败不会连累其余，
  也不会把半小时的构建白等在一个 502 上。
- 上传后自检：重新下载 `*.sha256sum` 比对内容，并按 `digest` 核对每个资产；
  不一致才整体重传一次，仍不一致就让 job 失败。

**普通包里的二进制**：`release.sh --target <triple> --pack` 一次 workspace 构建就把四个交付
bin 全编出来（`xn` / `cidr` / `xn-tui` / `xns`），打进**同一个** `xn.<triple>.tar.xz`，
不再单独发 `cidr.*` / `xn-tui.*` 包（`network/ci.sh` 就是从普通包里解 `cidr` 的）。
tuned 档只带 `xn`（上游 `--tuned` 只编 xn）。

## 独立 workflow

[`xn.yml`](../.github/workflows/xn.yml) 是独立 workflow，不与 `adguard.yml` 的每日
schedule 绑定：

- **不按天编译**：每小时（`:17`）只解析一次上游 `leptonyu/xn` 的 `main` SHA，只有 SHA
  变化才跑构建；没有变化时 check job 几秒结束。（x86_64 / macOS 是 PGO，armv7 普通编译。）
- **一个档位一个 job，全部并发**：`linux-x86_64`（普通）/ `linux-x86_64-tuned`（PGO）/
  `linux-armv7` / `macos-aarch64`（普通）/ `macos-aarch64-tuned`（PGO）都只依赖 `check`，
  `check` 一过同时开跑。普通包走轻量依赖（装完就编、编完就发），PGO job 才装
  LLVM/perf/BOLT，所以普通包比之前早一大截；tuned 挂了也不影响普通包。
- **普通包和 tuned 包进同一个 release，资产名不重叠**：`xn.<triple>.tar.xz`（普通档，
  含 xn / cidr / xn-tui / xns）和 `xn.<triple>.tuned[.trace].tar.xz`（PGO/BOLT，只含 xn）。两个 job 并发往同一个 release 追加，
  `gh release create` 的竞态由 `build.sh` 兜住（已存在就继续追加）。
- **armv7 是普通编译，没有 PGO**：armv7 二进制在 x86 runner 上跑不起来，采不了 PGO
  样本，所以交叉档直接走 `release.sh --target armv7-unknown-linux-musleabihf --pack`
  （cargo-zigbuild 交叉），只出 runtime 包，发布名是
  `xn.armv7-unknown-linux-musleabihf.tar.xz`（没调优就不叫 `.tuned.`）。
  `build.sh --profile FILE` 仍保留 `pgo.sh use` 的 PGO 交叉路径，仅本地手动用。
  注意别用 `pgo.sh use` 直接当 zig 调交叉链接：它会和 rustc 的 self-contained
  `crt*.o` 撞 `_start`（duplicate symbol），普通 `release.sh --target` 不会。
- **禁止缓存上游任何东西**（本仓库 public，`leptonyu/xn` private）：上游 checkout 每轮
  `actions/checkout` 现拉，不进 cache；sccache 不跨 run 缓存（编译产物里带私有代码的
  metadata），只在单轮 job 内复用（见下一条）。
  已构建标记按 build job 各存一份：**`actions/cache` 的
  `xn-built-<sha256(上游SHA)>-<job>`**（GITHUB_TOKEN 能写）。`check` 逐个 lookup，识别
  **哪个子任务已经完成**：完成的 job 跳过、只编缺的那些（同一 SHA 下 x86_64 编过、
  macOS 没编，就只跑 macOS）。key 里只有摘要 + job 名，标记文件内容固定写 `built`，
  公开 cache 里看不到上游 SHA/源码。`force=true` / 非 `main` 的 `ref` 会忽略标记、
  一律重编。
  仓库变量 **`XN_LAST_MAIN_SHA`** 只是「最近一次三个普通档齐全」的记录，不参与跳过判定：
  Actions Variables 的 API **不接受 GITHUB_TOKEN**（`actions: write` 也 403）。更新顺序：
  secret **`XN_VARS_TOKEN`**（fine-grained PAT，Repository permissions → Variables:
  Read and write）→ 否则复用 **`XN_REPO_TOKEN`**（只有 classic PAT / `repo` scope 才能写
  本仓库变量；只授了 `leptonyu/xn` 的 fine-grained token 会 403）。都写不了只打
  `::warning::`，不影响记账。
  **记账只看普通档**：`all` 时 x86_64 / armv7 / macOS 三个普通 job 都是 `success` 或
  `skipped`（之前已编过）才记，tuned 不参与 —— PGO 挂了整轮仍算成功；没完成的 job
  下一轮 check 会接着补，不必等上游新提交。
- 支持上游主动触发：`repository_dispatch`，`event_type: xn-main-updated`，
  `client_payload.sha` 可选；没有 dispatch 时最多晚一小时发现更新。
- 默认跟踪 `main`；需要临时从别的分支构建时，用手动 `workflow_dispatch` 的 `ref` 输入。
- 手动 `workflow_dispatch` 可覆盖 `ref`（默认 `main`）、`tag`（默认 `v<Cargo.toml version>`）、
  `features`（默认空 = 不加 quic）、`compare`（`true` 跟本轮构建跑对比、`only` 不构建，
  直接从已发布 runtime 包解出 bin 跑），`force=true` 可强制重编。手动指定非 `main` 的
  `ref` 不会改写 `XN_LAST_MAIN_SHA`。
- 留空 `tag` 时直接读上游 `Cargo.toml` 的版本（`v<version>`）；release 不存在时由
  `build.sh` 新建，`--target` 是本次构建的上游 commit；存在时只追加资产。
- `ubuntu-latest`；依赖分两段装，**普通包先发**：基础编译依赖（clang / bindgen /
  pkg-config …）→ 普通编译并上传 → 再装 tuned 才要的 LLVM 23 / `bolt-23` / perf /
  nextest（perf 走 `install-perf.sh`，原因见上），然后 PGO/BOLT。这样普通包早几分钟
  可用，普通编译挂了也不用白装 LLVM。BOLT 默认不开，装好只确认 perf / llvm-bolt 能跑、
  不跑 `perf record`；后续要开 `--bolt` 不用再改环境。
- `build.sh` 的 `require_platform` 只在 `flavors` 含 `tuned` 时才检查 perf——
  只发普通包时不需要 perf。
- **sccache 只在本轮 job 内用，不跨 run 缓存**：上游 `scripts/cargo-env.sh` 按
  `PATH` → `$CARGO_HOME/bin` → `~/.cargo/bin` 探测 sccache，找不到只打一行提示（不是错误）。
  workflow 仍用 `taiki-e/install-action@sccache` 装（PGO 三阶段共享依赖编译，省得多编两遍），
  但**不再**用 `actions/cache` restore/save 那个 `target/sccache`：曾经按
  `<os>-<档位>` + `Cargo.lock` 哈希跨 run 复用（~1.8 GiB），而缓存里是私有上游的编译产物
  （rlib/rmeta 带代码 metadata），本仓库 public，等于把私有代码 metadata 放进公开 cache。
  runner 结束目录即销毁；要完全不用 sccache 就 `XN_SCCACHE=off`（armv7 交叉档就是这么设的）。
- 私有上游需要仓库 secret **`XN_REPO_TOKEN`**（对 `leptonyu/xn` **`contents: write`**：
  既要 checkout，也要创建/更新 release）。如果它是 **classic PAT（`repo` scope）**，顺带就能
  写本仓库的变量 `XN_LAST_MAIN_SHA`；只有 fine-grained（仅授 `leptonyu/xn`）时不行，这时
  可选配 **`XN_VARS_TOKEN`**（fine-grained，本仓库 **Variables: read/write**）。都不配也能跑，
  已构建标记走 `actions/cache`。
  - fine-grained 的具体 scope（Repository access 只选 `leptonyu/xn`）：
    **Contents: Read and write**（checkout、读 `Cargo.toml`、`gh release create/upload/delete-asset`
    都靠它），**Metadata: Read**（自动带上）。**不需要** Actions / Workflows / Packages / Variables。
    classic PAT 用 `repo` scope 即可。
  - `docker` job 只 checkout 上游（`contents: read` 就够），**复用同一个 `XN_REPO_TOKEN`**，
    不用新 secret；ghcr 推送走本仓库的 `GITHUB_TOKEN`（`packages: write`），跟上游 token 无关。
  - token **不会**传进镜像构建（checkout 是 `persist-credentials: false`，也没有 `--secret` /
    `--build-arg`）：如果上游 Dockerfile 里自己 `git clone` 私库，会 403；那种情况要么改成用
    context 里的源码，要么用 buildkit secret（`--secret id=…`），**别塞 build-arg**（会留在镜像历史里）。
- 默认**不加** cargo features；需要时在手动触发的 `features` 输入或本地 `build.sh --features quic` 里加。
- **没有 public artifact**：构建产物（`xn/dist/*.tar.xz` / `*.sha256sum` / `*.bin`）不再
  `upload-artifact` —— 本仓库 public，artifact 对所有人可下载，而这些是私有上游的产物。
  包只发私有上游 release（发布时已逐资产上传 + 重试）；compare 要的 `.bin` 见下节。
- 发布上传逐资产 + 自动重试（见上），GitHub 偶发的 502 不再让 job 停在
  「8 个资产传到一半」；每个 build job 成功后都会落自己的标记，最终失败的那档
  下一轮会重编重传。
- **release 说明每次发布后自动刷新**：按 release 上**实际存在**的资产生成（普通包 /
  tuned 包 / trace / 校验和各自的用途），`gh release edit --notes` 覆盖。所以两个档位
  并发发到同一个 release、谁先建都行；老 tag 重传也会把说明补上。

- **镜像发 ghcr.io**：普通档编完后，`docker` job 用**上游自带的运行镜像** `Dockerfile` /
  `Dockerfile.armv7` 构建 amd64 + arm/v7 两档镜像（两档的二进制都**直接取自发布包**，
  不再现编），按 digest 推到 `ghcr.io/leptonyu/xn`，再合并成一个
  多架构 manifest（`v<version>`，两档齐了才加 `latest`）。镜像同样属于私有产物：ghcr 包
  保持 private、不用 buildx 缓存、不打 provenance。见下节「容器镜像」。

`xn` workflow 与 DNS/network 的每日 release 相互独立；它失败不会撤回其它 workflow 的资产。

## 容器镜像（ghcr.io）

`xn.yml` 里 `docker` job 在普通档编完之后用**上游仓库自带的运行镜像**出镜像，推到
`ghcr.io/leptonyu/xn`：

| 平台 | Dockerfile | `FROM` | buildx `--platform` | 二进制来源 |
| --- | --- | --- | --- | --- |
| amd64 | `Dockerfile` | `debian:trixie-slim`（glibc） | `linux/amd64` | 发布包 `xn.x86_64-unknown-linux-gnu.tar.xz` |
| armv7 | `Dockerfile.armv7` | `arm32v7/debian:trixie-slim` | `linux/arm/v7` | 发布包 `xn.armv7-unknown-linux-musleabihf.tar.xz`（musl 静态） |

两个 Dockerfile 都是**运行镜像**（只 `COPY` 产物、不编译），`COPY` 的路径由上游定死：
`target/<triple>/release/xn`、`target/THIRD-PARTY-NOTICES.txt`、`entry.sh`、`LICENSE`，
x86 那份还要 `dlc.dat.xz`。所以 `docker` job 先把这些摆进上游 checkout 再 build：

- **amd64**：`gh release download` 取发布包（校验 `.sha256sum`），解出 `xn` 与
  `THIRD-PARTY-NOTICES.txt` —— 镜像里的二进制与 release **逐字节一致**。
- **armv7**：同样从发布包取（校验 `.sha256sum`），用的是 `musleabihf` 的 **musl 静态**
  二进制，镜像 job 里**不再另编 gnu 档**。`Dockerfile.armv7` 里 `COPY` 的路径写的是
  `target/armv7-unknown-linux-gnueabihf/release/xn` —— 那只是个 COPY 路径，musl 静态
  二进制在 `arm32v7/debian` 上照样跑。
  **代价**：musl 分配器在高 churn 下只涨不还（上游 `docs/datapath-perf.md §2.30`，当年
  正是因为它在容器里 OOM 才把镜像换成 glibc）；要换回去就把这一步改成
  `release.sh --target armv7-unknown-linux-gnueabihf`（多一次交叉编译）。
- **`dlc.dat.xz`**：优先按上游 `scripts/test/fixtures.lock.toml` 的 `[dlc]` 钉的
  dockerized-packages release 制品取，并校验 sha256；那个 tag 会被本仓库的
  `delete-releases.yml` 按保留策略删掉（取不到 404），所以取不到 / 校验不过时退回
  dockerized-packages 最新 release（与运行时默认同一源），并打一条 `::warning::`。

发布方式：

- **两档各按 digest 推，最后合并**：每个平台 `buildx build --output
  type=image,push-by-digest=true`，只留 digest；再 `docker buildx imagetools create`
  合成一个 manifest，打 `v<版本>`（版本仍取上游 `Cargo.toml`，与 release tag 一致；手动
  指定 `tag` 输入时用那个 tag），**两档都在时**才额外打 `latest`。所以同一个 tag 下
  `linux/amd64` / `linux/arm/v7` 是两个 entry，ghcr 里不会堆 `-amd64` / `-armv7` 中间 tag。
- **只在「本轮真的编了普通档」时推**：`needs` 是 `check` + `linux-x86_64` + `linux-armv7`；
  两档都 skipped（已构建标记命中）或 `compare=only` 不跑。要重推已发布版本的镜像，
  手动 dispatch `force=true`。
- **普通档有失败就整档不推**：宁可这轮没有镜像，也不把「只有一半」的 manifest 盖到
  已发布的 `v<版本>` / `latest` 上。
- `target=all`（默认）时两档都建 —— 哪怕其中一档这轮被标记跳过（两档都是「从发布包取
  二进制」，不依赖本轮产物）—— 保证 manifest 完整；`target` 只点名一个平台时只推那一档。
- armv7 那档要 QEMU/binfmt（`docker/setup-qemu-action` 装 `arm`），镜像本身不编译，
  装 binfmt 只是为了展开 arm32 的层；整个 job 不再装编译依赖，`timeout-minutes: 60`。

**私有产物**（和 cache / artifact 同一条底线）：镜像是私有上游编出来的 xn，所以

- ghcr 包**必须保持 private**（新建默认就是 private）；job 末尾用
  `gh api /user/packages/container/xn` 查一次可见性，`public` 打 `::warning::`。
  workflow 只查不改 —— 要改可见性去包的设置页。
- 不用 buildx 缓存（`type=gha` 的层就是私有源码的编译产物），不跨 run 复用；
- 不开 provenance / sbom（attestation 会写 VCS 来源 = 上游仓库和提交 SHA），也不写
  `org.opencontainers.image.revision`；
- 推送只用 `secrets.GITHUB_TOKEN` + `packages: write`，不需要额外的 PAT（也不需要上游 token
  带 Packages 权限）；checkout 上游仍复用 `XN_REPO_TOKEN`（这一档只要 `contents: read`），
  token 不会进镜像构建。
- 万一推送 403（`denied: permission_denied`）：通常不是 token scope 的问题，而是包 `xn`
  已经存在且**没链接到本仓库**（比如早先由上游仓库自己的 CI 建过）——在包设置里给
  `leptonyu/dockerized-packages` 加 Write，或者改用带 **Packages: write** 的 PAT
  （那会是另一个 secret，不是 `XN_REPO_TOKEN`）。

本地复现（需要有 `leptonyu/xn` 读权限的 token）：

```bash
# 上游 checkout（任意目录）
SRC=~/src/xn

# 从发布包解出二进制和 notices，摆到两个 Dockerfile 要的位置
tar -xJf xn.x86_64-unknown-linux-gnu.tar.xz -C /tmp/pkg-x86
tar -xJf xn.armv7-unknown-linux-musleabihf.tar.xz -C /tmp/pkg-arm
mkdir -p "$SRC/target/x86_64-unknown-linux-gnu/release" "$SRC/target/armv7-unknown-linux-gnueabihf/release"
cp /tmp/pkg-x86/xn "$SRC/target/x86_64-unknown-linux-gnu/release/xn"
cp /tmp/pkg-arm/xn "$SRC/target/armv7-unknown-linux-gnueabihf/release/xn"
chmod 0755 "$SRC/target/x86_64-unknown-linux-gnu/release/xn" "$SRC/target/armv7-unknown-linux-gnueabihf/release/xn"
cp /tmp/pkg-x86/THIRD-PARTY-NOTICES.txt "$SRC/target/THIRD-PARTY-NOTICES.txt"
# dlc.dat.xz 放到 $SRC/dlc.dat.xz（按 fixtures.lock.toml 的 [dlc] 取）

# amd64
docker buildx build --file "$SRC/Dockerfile" --platform linux/amd64 "$SRC"
# armv7（amd64 机器上要先装 binfmt）
docker run --privileged --rm tonistiigi/binfmt --install arm
docker buildx build --file "$SRC/Dockerfile.armv7" --platform linux/arm/v7 "$SRC"
```

## 对比测试（pgo.compare）

`build.sh` 会把两档的 xn 二进制留在 `xn/dist/xn.<triple>.{release,tuned}.bin`。`compare=true`
时，每个 build job 成功后把这两份 bin 传到**私有上游仓库的固定 prerelease `xn-ci`**
（`gh release upload --clobber`，单 tag 不累积），compare job 再从那里取回。

`compare=only` 不依赖 `xn-ci`，也不需要本轮构建：它直接下载已发布 tag（默认
`v<Cargo.toml version>`，可用 `tag` 输入覆盖）里的两档 runtime 包
`xn.<triple>.tar.xz` / `xn.<triple>.tuned.tar.xz`，用 [`fetch-bin.sh`](fetch-bin.sh)
解出 `xn`，写成 compare 认的 `xn.<triple>.{release,tuned}.bin`。所以只要发布包在，
即使 `xn-ci` 里没有 bin（例如那一轮没开 compare，或 bin 上传失败）也能补对比。

`pgo.compare` 是一个独立 job，把两份 bin 交给 [`compare.sh`](compare.sh)，后者再摆成上游
`build-tuned` 的 run 目录，交给上游 `scripts/test/pgo/compare-ci.sh --no-build`：

```text
target/tune/prebuilt-<UTC>/02-optimize/xn.control  ← 普通包里的 xn（控制组）
target/tune/prebuilt-<UTC>/02-optimize/xn.tuned    ← tuned 包里的 xn（优化组）
```

于是 `pgo.compare` 就是拿这两个 bin 做同机 A/B（`scripts/perf/run.sh run t1
--binary control --binary-b tuned`，A,B,B,A 轮转），macOS 的产物是 Mach-O，自动退
`pgo.compare.size` 只比大小。报告落在上游 checkout 的 `target/pgo/`、`target/test-runs/`，
workflow 打包成 `compare-<triple>.tar.gz` 传到 `xn-ci` release（报告里有私有符号名，
不进 public artifact）。

手动 dispatch 的 `compare` 下拉：

| 取值 | 行为 |
| --- | --- |
| `false`（默认） | 不跑 compare |
| `true` | 本轮两档构建都成功（或命中已构建标记、skipped）后跑；skipped 的档用 `xn-ci` 里上次的 bin，bin 不全就报错（`force=true` 重编那一档） |
| `only` | **完全跳过构建**，从已发布 `v<version>` 的两档 runtime 包解出 bin 单独跑；`target=all` 时只跑包齐的那档，点名单个平台却缺包会在 `check` 里直接报错 |

`compare=only` 适合构建已经完成、当时却没开 compare 的场景，或单纯想重跑一次 A/B。
它用的是**发布 tag** 对应的 runtime 包；tag 默认由当前上游 SHA 的 `Cargo.toml` 版本推出来，
如果该版本发布包是更早提交发的，bin 不一定对应当前 `main` 的 SHA。要保证 bin 和源码对得上，
先跑一轮 `compare=true`（或 `force=true`）重新发布；也可以用 `tag` 输入指定一个已知 release。
`compare=true` 时某一档如果因为已构建标记跳过，就直接用它上次传的 `xn-ci` bin（同一 SHA）；
bin 上传失败时会把同名旧 bin 删掉，避免 compare 误用上一个 SHA 的 bin。上传失败只在
`compare=true` 时让 build job 红（对比要靠它），其余时候只告警、不影响发布。

```bash
./xn/build.sh                                   # 先编两档（产物 + bin 都在 xn/dist）
./xn/compare.sh --target x86_64-unknown-linux-gnu --rounds 4
./xn/compare.sh --target aarch64-apple-darwin --size-only

# compare=only 的取 bin 方式（本地也能用；默认 tag = v<Cargo.toml version>）
./xn/fetch-bin.sh --target x86_64-unknown-linux-gnu --tag v6.0.0
./xn/compare.sh --target x86_64-unknown-linux-gnu --rounds 4
```

## 手动测试（测试 XN）

[`xn-tests.yml`](../.github/workflows/xn-tests.yml) 是手动触发的测试入口，不在 push / PR
自动跑。Actions → **测试 XN** → **Run workflow** 的菜单配置：

| 输入 | 取值 | 含义 |
| --- | --- | --- |
| `mode` | `all`（默认） | 本仓库离线测试 + 上游全部 active 条目（数小时，不含 pgo）+ eBPF smoke |
| `mode` | `repo` | 只跑本仓库离线测试（`xn/tests/run-all.sh`，几秒） |
| `mode` | `smoke` | 只跑上游 eBPF smoke 矩阵（GOAL-112 的 5 条 `smoke.ebpf.*`） |
| `mode` | `nightly` | 上游 nightly 档（unit + e2e）+ eBPF smoke |

触发规则：

- `mode=repo` 不 checkout 上游、不需要 `XN_REPO_TOKEN`。
- 架构固定为 x86_64 Linux + aarch64 macOS（`mode=smoke` 只在 Linux 上跑，eBPF
  本来就只支持 Linux，macOS 那条腿只会白起一台 runner）；上游 ref 固定 `main`。
- `mode=all` / `nightly` 先跑 `scripts/test/all.sh`（默认 keep-going，只认
  `--fail-fast`），再跑 eBPF smoke。unified 以非 root 跑，会跳过 `smoke.ebpf.*`
  等 root/VM 条目，eBPF 步骤用特权容器补上；eBPF 放在最后，`last-report.md` 是
  eBPF 的结果，unified 的汇总另存 `last-report-unified.md`。
- unified 整类都因环境跳过时脚本退 2，workflow 只告警；退 2 但输出里不是「全部
  跳过」（例如参数/用法错误）仍按失败处理，避免一条没跑却显示绿色。
- `mode=smoke` 只跑 eBPF 步骤（`scripts/test/ci-ebpf.sh --category smoke`），不再
  跑 unified —— 避免同一批 5 条被非 root 的 unified 再选一次（全部 skip），并让
  `last-report.md` 保持 eBPF 的结果。
- `all` / `nightly` 按上游口径**不含 pgo**（`run --all` 会过滤掉 pgo 类目）；PGO
  构建 + `pgo.compare` 不在这个 workflow 里，入口是发布链路 `xn.yml` 的
  `compare` 下拉（`true` 跟构建，`only` 从已发布 runtime 包解出 bin 单独跑）。
- eBPF 步骤始终要求环境（root / docker / BTF）可用；缺环境直接失败而不是跳过。

## 与上游的关系

- 只读上游：不在本仓库改 `release.sh` / `scripts/` / `Cargo.toml`；需要的上游改动以补丁形式
  放在 `patches/`，由人工在上游仓库 `git apply`（目前没有待应用的补丁；`--xn-only`
  不再用于发布链路）。
- `--tuned` 是上游唯一的 PGO+BOLT 入口；本模块的版本门槛是
  `release.sh` 里出现 `--tuned`。上游改成新入口时，先改这里，不复制逻辑。
- 产物是**候选**：`--tuned` 的采样是合成 loopback 负载 + 测试套件，不等于线上流量；
  D-96 的同机同轮 A/B 仍要另做，脚本不声称吞吐/CPU 收益。

## Roadmap（后续扩展）

- **Docker / musl**：容器里跑 `x86_64-unknown-linux-musl`；BOLT 仍需要原生 Linux +
  `--emit-relocs`，musl 档能否保留重定位要单独验证。当前 `release.sh --tuned` 只做
  target == host 的 gnu 档，容器化时复用同一 `build.sh` 的打包/发布段。
- **macOS**：只能做 PGO 的 collect/optimize（zig 交叉），BOLT 不可用；届时增加
  `--no-bolt` 分支，产物命名区分 `.pgo.`，不覆盖本模块的 `.tuned.` 资产。
- **发布目标**：默认回到 `XN_REPO` / `--repo` 的 `v<version>` release；其他仓库用
  `--release-repo` 指定（不会自动在其上创建 release）。

## 注意

- `--publish` 默认在 `XN_REPO` 上发 `v<Cargo.toml version>`：不存在就新建 release，
  存在就追加/覆盖同名资产（`--clobber`）。上游仓库的 tag 若已存在但 release 不存在，
  会在该 tag 上补建 release。
- **同一版本重建 hash 会变**：PGO+BOLT 不可复现，`v<version>` 的 tar 每次重建都不同。
  发布按包上传 `<asset>.sha256sum`（校验和最后传），上传后从 API 自检校验和内容与
  asset digest，不一致就重传一次、还不对就让 job 失败；期间遇到 5xx 会先自动退避重试，
  不会因为一个 502 就把「传到一半」的 release 留在那里。但消费端不要跨构建 pin hash，
  要稳定就按具体构建钉（tag 带构建号目前还没做）。旧的汇总 `SHA256SUMS` 资产会被删掉。
- 发布路径有离线自测：`./xn/tests/publish-retry.test.sh`（临时假 `gh`，不联网、不构建），
  覆盖 502 重试、4xx 快速失败、自检发现不一致后重传。仓库级入口是
  `./xn/tests/run-all.sh`（顺带 `bash -n` 全仓脚本），新增 `*/tests/*.test.sh` 会被
  自动发现。手动测试入口与菜单配置见上面的「手动测试（测试 XN）」。
- `--release-repo` 指向非上游仓库时，只追加到已有 release，不会在别的仓库自动建 tag。
- `--package-only` 不重跑构建，直接用 `target/<triple>/release/` 里现成的三个文件重传；
  缺文件就报错（先跑一次完整构建）。
- 打包内容（收哪些文件、perf.data 收不收）完全由上游 `trace-files.txt` /
  `trace-replay-files.txt` 决定，本模块不再有 `--perf-data` / `--trace-exclude` 这类裁剪开关。
