# network — xn 的八份 CIDR 名单

从 `machine/modules/network/` 迁过来的 CIDR 生成目录。数据源、ASN、scanner
（`source: file`）和全部 ops 都在 [`cidr.yaml`](cidr.yaml)；[`gen.sh`](gen.sh)
只负责准备 `.cache/scanners/all.txt`、跑 pipeline、自检并写 checksum。CI 用
Git LFS 里的 [`bin/cidr`](bin/README.md)（Linux x86_64）生成，不再需要本地提交
名单快照。

| 产物 | 用途（xn 配置里的落点） | 内容 |
| --- | --- | --- |
| `xn_block.txt` | `ebpf.firewall.cidr_file`：VPS 公网入口源地址 blocklist | `shrink(xn_block_all)` 再精确 subtract `non_public`，仅公网（当前 3,795 条） |
| `xn_block_orig.txt` | 原来的 `xn_block`（不含 scanner） | `block_raw` 精确 subtract `non_public`（当前 1,665 条） |
| `xn_block_all.txt` | 全量扫描器封禁（原始版本） | `block_raw` + OpenFilters/internet-scanners 的 active `cidr/`（当前 93 个文件，17,567 条） |
| `xn_cn.txt` | CN 侧路由/旧 policy 的 `xn_cn` | `cn ∩ us` |
| `xn_fake.txt` | fake DNS / split 用 | `198.18.0.0/15`、`fc00::/18` |
| `xn_us.txt` | `ebpf.split[].cidr_file`：eBPF split 表 | `us_public`（`us` 精确 subtract `non_public`）+ fake |
| `xn_vpn.txt` | 旧 policy / 路由表 | `xn_us` + `192.160.0.0/11` + `10.78.0.0/15` |
| `xn_allow.txt` | `inbound_jail.allow_cidrs_file`：入站 jail 来源白名单 | Cloudflare + CloudFront `CLOUDFRONT_ORIGIN_FACING`，已合并去重（新增） |

`xn_block_orig` / `xn_cn` / `xn_fake` / `xn_us` / `xn_vpn` 与 machine 当前同名文件
逐字节一致（当前源里没有额外的非公网条目，所以过滤后条数不变）；`xn_allow` 与
`cf.txt + cft.txt` 的并集一致。`xn_block` 和 `xn_block_all` 是新增的两种口径。

## block 的三种口径

- `xn_block_orig.txt`：原来的 plain `xn_block`，`block_raw` 精确去掉 `non_public`，
  **不含** scanner。对应 machine 现有的 `xn_block.txt`。
- `xn_block_all.txt`：pipeline `block_all` = `block_raw` + `scanners`（`source: file`）
  的**原始合并**，不 shrink、不做公网过滤。
- `xn_block.txt`：pipeline `block` = `block_all` 先 `shrink_small_nets`，再精确
  `subtract non_public`，是给 eBPF 的版本；当前 3,795 条，覆盖 `xn_block_all` 的
  全部条目。

> eBPF `ebpf.firewall` 的 inline + `cidr_file` 合计上限是 **16,384 条**
> （`docs/ebpf.md`，超限启动校验会报错）。`xn_block`（3,795）在限制内；
> `xn_block_all`（17,567）超限，不能直接给 eBPF，用于 ipset/nftables 等更大的
> 消费者。

`shrink` 用 `cidr --shrink-small-nets` 默认阈值；它会把密集的 `/32` 聚合到
`/24`/`/16`（v6 到 `/48`/`/32`），所以 `xn_block` 是**覆盖** scanner 网段，
不是逐 IP 精确列表。

## 公共 IP 过滤

- `non_public` = 内置 `private_ranges`（RFC1918、loopback、link-local、CGNAT、文档段、
  benchmark、multicast、reserved、ULA、v6 link-local/multicast）+ IANA IPv6
  special-purpose（NAT64、Teredo、6to4、ORCHID、discard、documentation 等）。
- `xn_block_orig`：`block_raw` 用 **`subtract`**（精确减法）去掉 `non_public`。
- `xn_block`：pipeline 里先对 `block_all` 做 `shrink_small_nets`，再
  `subtract non_public`；过滤放在 shrink 之后，保证聚合结果也不含非公网段。
- `xn_us`：过滤放在中间层 `us_public`（`us` 用 `subtract` 去掉 `non_public`），
  然后 `xn_us` 直接并 `fake`。`198.18.0.0/15` / `fc00::/18` 是 fake DNS 段，虽然
  不是公网，但必须保留，所以不能在 `xn_us` 之后再过滤。
- `xn_block_all`：用 `block_raw` + scanner，**不做** shrink / `non_public` 过滤，
  保持原始版本。
- `xn_cn`：仍用过滤前的 `us`，与 machine 当前 `xn_cn` 逐字节一致。
- `scanners` 是 `cidr.yaml` 里的 `source: file`，指向 `gen.sh` 准备好的
  `.cache/scanners/all.txt`；`block_raw` / `non_public` / `us_public` 是内部
  source/pipeline，不落文件、不发布。

> pipeline 语义（见 `rust/xn/xn-cidr`）：`execute_output_pipeline` 会缓存 post-ops
> 结果；`subtract_merge` 会把稀疏减法区间合并成更大的 complement 块，适合路由表，
> 但用于「只保留公网」会过度放行。因此过滤用 `subtract`，只有 `us` 对 `cn` 的原语义
> 保留 `subtract_merge` + `shrink_small_nets`。

## 生成

依赖 `cidr`（`xn-cidr-bin` 的 CLI）。CI 用 LFS 里的 Linux 二进制；本地可以放到
`PATH`，或用 `CIDR=/path/to/cidr` 指定：

```bash
cd network
./gen.sh                 # 生成八份 + 各自 .sha256sum
./gen.sh block           # xn_block.txt + xn_block_orig.txt + xn_block_all.txt
./gen.sh block_all       # 同上
./gen.sh cn              # xn_cn.txt
./gen.sh fake            # xn_fake.txt
./gen.sh us              # xn_us.txt
./gen.sh vpn             # xn_vpn.txt
./gen.sh allow           # xn_allow.txt
./gen.sh check           # 重新生成到临时目录，与工作区逐字节 + checksum diff（不落盘）
```

`country_asn` 源来自 ipinfo，首次运行或缓存超过 12h 时需要 token。
`cidr` 直接读环境变量 `IPINFO_TOKEN`，不需要写进 `cidr.yaml`：

```bash
IPINFO_TOKEN=... ./gen.sh all
```

`xn_block_all` 需要访问 GitHub；离线或固定上游快照时用本地 tarball：

```bash
SCANNERS_TARBALL=/path/to/internet-scanners.tar.gz ./gen.sh block
```

`scanners` 是 `source: file`：每次运行全量重读 `.cache/scanners/all.txt`，不参与
`cache_max_age` 的 12h 缓存；scanner tarball 本身每次由 `gen.sh` 下载（或从
`SCANNERS_TARBALL` 复制）。

`cidr` 把源缓存在 `~/.cache/cidr/`，TTL 由 [`cidr.yaml`](cidr.yaml) 的
`cache_max_age: 12h` 决定（只看文件 mtime，没有 ETag/If-Modified-Since）。本机
`~/.cache` 不可写（例如沙箱）时，`gen.sh` 会退回 `network/.cache/`；也可以用
`XDG_CACHE_HOME` 显式指定。这个回退目录已在 `.gitignore` 里。

## CI

`.github/workflows/adguard.yml` 的每日 release 现在有两个 job：

1. `dns`：生成 DNS/AdGuard 制品，建当天 tag/release 并上传 DNS 资产；
2. `network`（`needs: dns`）：`checkout` 带 `lfs: true` 拿到 `network/bin/cidr`，
   `actions/cache` 缓存 `~/.cache/cidr`，用 `secrets.IPINFO_TOKEN` 跑
   [`ci.sh`](ci.sh)；`ci.sh` 把每份 `.txt` 单独压成 `.xz`，release 上传八份
   `.txt.xz` 和各自的 `.txt.xz.sha256sum`（不打包 tar）。

缓存和 `cidr.yaml` 的 `cache_max_age: 12h` 对齐：key 是 **UTC 日期 + 12h 桶**，
`restore-keys: cidr-src-` 取最近一份。同桶重跑命中缓存、不重复下载；隔天/换桶
的那次缓存已超过 12h，会重下并刷新 mtime，所以列表每天都是新的。

network job 失败不会撤回已经发布的 DNS 制品，但整个 run 会标红。生成、校验、LFS
属性和忽略规则都在 `network/` 里；workflow 只是 release 编排。

发布资产：

```text
xn_block.txt.xz          xn_block.txt.xz.sha256sum
xn_block_orig.txt.xz     xn_block_orig.txt.xz.sha256sum
xn_block_all.txt.xz      xn_block_all.txt.xz.sha256sum
xn_cn.txt.xz             xn_cn.txt.xz.sha256sum
xn_fake.txt.xz           xn_fake.txt.xz.sha256sum
xn_us.txt.xz             xn_us.txt.xz.sha256sum
xn_vpn.txt.xz            xn_vpn.txt.xz.sha256sum
xn_allow.txt.xz          xn_allow.txt.xz.sha256sum
```

解压（release 只放 `.xz`，不再放 plain `.txt`）：

```bash
xz -d xn_block.txt.xz              # 输出 xn_block.txt
xz -dc xn_block.txt.xz > out.txt   # 不想覆盖/改名时
xz -df xn_block.txt.xz             # 同目录已有旧 xn_block.txt 时强制覆盖
```

旧 release 里可能还留着早期 workflow 的 plain `.txt` 和 `.txt.sha256sum`；
network job 会先用 `gh release delete-asset` 清掉它们，再上传新的 `.xz`。在清理
生效前，把 release 全下到同一目录再 `xz -d` 会因为「输出文件已存在」失败，这不是
压缩包损坏；用 `xz -df` 或 `xz -dc` 即可。

生成物不入 git（本目录的 `.gitignore` 已挡 `xn_*.txt*` 和 `xn_*.txt.xz*`）；
`network/` 里只放 `cidr.yaml`、`gen.sh`、`ci.sh`、`bin/cidr`、`.gitattributes`
和文档。

> CI 首次运行需要仓库 secret `IPINFO_TOKEN`；没有缓存又没有 token 时，
> `country_asn` 源会失败。之后的运行即使 token 暂时缺失，也可以靠缓存完成。

## 与 machine 的对应关系

| machine `modules/network/` | 这里 |
| --- | --- |
| `block.txt`（2026-06 旧快照，1716 行） | 不再对应 |
| `xn_block.txt`（block pipeline，1665 行） | `xn_block_orig.txt`（逐字节一致） |
| —（外部 scanner 列表，原来没有） | `xn_block_all.txt`（原始合并） |
| —（eBPF 用的 shrink 版，原来没有） | `xn_block.txt` |
| `xn_cn.txt` | `xn_cn.txt` |
| `xn_fake.txt` | `xn_fake.txt` |
| `xn_us.txt` | `xn_us.txt` |
| `xn_vpn.txt` | `xn_vpn.txt` |
| `cf.txt` + `cft.txt`（Ansible 合并） | `xn_allow.txt` |

迁移时的取舍：`cn` 是 `us` 的减法源，`fake` 是 `xn_us` 的附加段；`us` 本身不落文件。
原来的 plain block 保留为 `xn_block_orig.txt`，新的 `xn_block.txt` 是
`shrink(xn_block_all)` 的公网版本。
