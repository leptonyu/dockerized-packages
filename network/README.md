# network — xn 的七份 CIDR 名单

从 `machine/modules/network/` 迁过来的 CIDR 生成目录。数据源、ASN、内联网段都在
[`cidr.yaml`](cidr.yaml)；[`gen.sh`](gen.sh) 负责跑 pipeline、合并 `xn_block_all`
的 scanner 部分、自检并写 checksum。CI 用 Git LFS 里的 [`bin/cidr`](bin/README.md)
（Linux x86_64）生成，不再需要本地提交名单快照。

| 产物 | 用途（xn 配置里的落点） | 内容 |
| --- | --- | --- |
| `xn_block.txt` | `ebpf.firewall.cidr_file`：VPS 公网入口源地址 blocklist | `block_raw` 精确 subtract `non_public`，仅公网 IP（当前 1,665 条） |
| `xn_block_all.txt` | 全量扫描器封禁（原始版本，eBPF 容量见下） | `block_raw` + OpenFilters/internet-scanners 的 active `cidr/`（当前 93 个文件，17,567 条） |
| `xn_cn.txt` | CN 侧路由/旧 policy 的 `xn_cn` | `cn ∩ us` |
| `xn_fake.txt` | fake DNS / split 用 | `198.18.0.0/15`、`fc00::/18` |
| `xn_us.txt` | `ebpf.split[].cidr_file`：eBPF split 表 | `us_public`（`us` 精确 subtract `non_public`）+ fake |
| `xn_vpn.txt` | 旧 policy / 路由表 | `xn_us` + `192.160.0.0/11` + `10.78.0.0/15` |
| `xn_allow.txt` | `inbound_jail.allow_cidrs_file`：入站 jail 来源白名单 | Cloudflare + CloudFront `CLOUDFRONT_ORIGIN_FACING`，已合并去重（新增） |

`xn_block` / `xn_cn` / `xn_fake` / `xn_us` / `xn_vpn` 与 machine 当前同名文件逐字节
一致（当前源里没有额外的非公网条目，所以过滤后条数不变）；`xn_allow` 与
`cf.txt + cft.txt` 的并集一致。`xn_block_all` 是新增的、**未过滤**的原始合并结果。

## 公共 IP 过滤

- `non_public` = 内置 `private_ranges`（RFC1918、loopback、link-local、CGNAT、文档段、
  benchmark、multicast、reserved、ULA、v6 link-local/multicast）+ IANA IPv6
  special-purpose（NAT64、Teredo、6to4、ORCHID、discard、documentation 等）。
- `xn_block`：`block_raw` 用 **`subtract`**（精确减法）去掉 `non_public`，所以 eBPF
  侧只看到公网地址。
- `xn_us`：过滤放在中间层 `us_public`（`us` 用 `subtract` 去掉 `non_public`），
  然后 `xn_us` 直接并 `fake`。`198.18.0.0/15` / `fc00::/18` 是 fake DNS 段，虽然
  不是公网，但必须保留，所以不能在 `xn_us` 之后再过滤。
- `xn_block_all`：用 `block_raw` + scanner，**不做** `non_public` 过滤，保持原始版本。
- `xn_cn`：仍用过滤前的 `us`，与 machine 当前 `xn_cn` 逐字节一致。
- `block_raw` / `xn_block_raw.txt` 和 `us_public` 是内部中间层，不发布；`gen.sh` 合并完
  `xn_block_all` 后会删掉 `xn_block_raw.txt`。

> pipeline 语义（见 `rust/xn/xn-cidr`）：`execute_output_pipeline` 会缓存 post-ops
> 结果；`subtract_merge` 会把稀疏减法区间合并成更大的 complement 块，适合路由表，
> 但用于「只保留公网」会过度放行。因此过滤用 `subtract`，只有 `us` 对 `cn` 的原语义
> 保留 `subtract_merge` + `shrink_small_nets`。

## xn_block_all 与 scanner 列表

- 上游：<https://github.com/OpenFilters/internet-scanners/tree/main/cidr>，只取 active
  的 `cidr/*_v4.txt` / `*_v6.txt`（当前 93 个）；`inactive/cidr/` 是已停用扫描器的
  归档快照，不并进来。
- 合并：`cat xn_block_raw.txt cidr/*.txt | cidr`。默认只做 merge / 去重 / 相邻聚合，
  **不**做 `shrink-small-nets`，所以不会把零散 `/32` 扩成整段；也不做公网过滤。
- 当前 17,567 行（IPv4 15,570 + IPv6 1,997）。

> ⚠️ eBPF `ebpf.firewall` 的 inline + `cidr_file` 合计上限是 **16,384 条**
> （`docs/ebpf.md`，超限启动校验会报错）。`xn_block_all.txt` 不能直接当 eBPF
> firewall 文件用：eBPF 用已过滤的 `xn_block.txt`（1,665 条）；`xn_block_all` 用于
> ipset / nftables 等容量更大的消费者，或先 `XN_BLOCK_SHRINK=1 ./gen.sh block` 生成
> 聚合版（当前约 3,795 行）再下发。

## 生成

依赖 `cidr`（`xn-cidr-bin` 的 CLI）。CI 用 LFS 里的 Linux 二进制；本地可以放到
`PATH`，或用 `CIDR=/path/to/cidr` 指定：

```bash
cd network
./gen.sh                 # 生成七份 + 各自 .sha256sum
./gen.sh block           # xn_block.txt + xn_block_all.txt
./gen.sh block_all       # 同上
./gen.sh cn              # xn_cn.txt
./gen.sh fake            # xn_fake.txt
./gen.sh us              # xn_us.txt
./gen.sh vpn             # xn_vpn.txt
./gen.sh allow           # xn_allow.txt
./gen.sh check           # 重新生成到临时目录，与工作区逐字节 + checksum diff（不落盘）
```

`country_asn` 源来自 ipinfo，首次运行或缓存超过 24h 时需要 token：

```bash
IPINFO_TOKEN=... ./gen.sh all
```

`xn_block_all` 需要访问 GitHub；离线或固定上游快照时用本地 tarball：

```bash
SCANNERS_TARBALL=/path/to/internet-scanners.tar.gz ./gen.sh block
```

`cidr` 默认把源缓存在 `~/.cache/cidr/`。本机 `~/.cache` 不可写（例如沙箱）时，
`gen.sh` 会退回 `network/.cache/`；也可以用 `XDG_CACHE_HOME` 显式指定。这个回退
目录已在 `.gitignore` 里。

## CI

`.github/workflows/adguard.yml` 的每日 release 现在有两个 job：

1. `dns`：生成 DNS/AdGuard 制品，建当天 tag/release 并上传 DNS 资产；
2. `network`（`needs: dns`）：`checkout` 带 `lfs: true` 拿到 `network/bin/cidr`，
   `actions/cache` 缓存 `~/.cache/cidr`（key 按天滚动、`restore-keys` 命中前一天），
   用 `secrets.IPINFO_TOKEN` 跑 [`ci.sh`](ci.sh)，然后把七份 `.txt` + `.sha256sum`
   追加到同一个 `vYYYYMMDD` release。

network job 失败不会撤回已经发布的 DNS 制品，但整个 run 会标红。生成、校验、LFS
属性和忽略规则都在 `network/` 里；workflow 只是 release 编排。

需要让 `xn_block_all` 直接适配 eBPF 16,384 上限时，在仓库 Variables 里加
`XN_BLOCK_SHRINK=1`（等价于本地 `XN_BLOCK_SHRINK=1 ./gen.sh all`）。

生成物不入 git（本目录的 `.gitignore` 已挡 `xn_*.txt*`）；`network/` 里只放
`cidr.yaml`、`gen.sh`、`ci.sh`、`bin/cidr`、`.gitattributes` 和文档。

> CI 首次运行需要仓库 secret `IPINFO_TOKEN`；没有缓存又没有 token 时，
> `country_asn` 源会失败。之后的运行即使 token 暂时缺失，也可以靠缓存完成。

## 与 machine 的对应关系

| machine `modules/network/` | 这里 |
| --- | --- |
| `block.txt`（2026-06 旧快照，1716 行） | 不再对应 |
| `xn_block.txt`（block pipeline，1665 行） | `xn_block.txt`（逐字节一致） |
| —（外部 scanner 列表，原来没有） | `xn_block_all.txt` |
| `xn_cn.txt` | `xn_cn.txt` |
| `xn_fake.txt` | `xn_fake.txt` |
| `xn_us.txt` | `xn_us.txt` |
| `xn_vpn.txt` | `xn_vpn.txt` |
| `cf.txt` + `cft.txt`（Ansible 合并） | `xn_allow.txt` |

迁移时的取舍：`cn` 是 `us` 的减法源，`fake` 是 `xn_us` 的附加段；`us` 本身不落文件。
`block_all` 拆成独立文件 `xn_block_all.txt`，`xn_block.txt` 保持原来的 plain 语义。
