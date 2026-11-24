# dockerized-packages
Dockerfiles

- `network/` — 每日 release 的生成目录（CI 生成，见 [network/README.md](network/README.md)）：
  - `network/dns/` — DNS / AdGuard 制品：`gen.sh` 生成 `dlc.dat(.xz)`（DNS 分流 / 广告拦截 DLC）、`apple.conf`、`filter_49`；`domain.txt` 只维护手工 fake 域名
  - `network/xn_*` — xn 的 xn_block / xn_block_orig / xn_block_all / xn_cn / xn_fake / xn_us / xn_vpn / xn_allow CIDR 名单
- `xn/` — 上游 [leptonyu/xn](https://github.com/leptonyu/xn) 的构建：复用上游 `./release.sh --pack`（tuned 档加 `--tuned`），独立 workflow 跟踪上游 `main`，有更新才编译；每个平台出**普通包 + tuned 包**（`xn.<triple>.tar.xz` / `xn.<triple>.tuned[.trace].tar.xz`，tuned 含 PGO/BOLT 与 perf.data 全过程），armv7 只出普通包；全部合并发布回 `XN_REPO`（默认 `leptonyu/xn`）的 `v<Cargo.toml version>` release。x86_64 普通包发出去后自动触发上游 `leptonyu/xn` 的 `docker.yml`（`repository_dispatch`），重建 `ghcr.io/leptonyu/xn` / `ghcr.io/leptonyu/xn-web` 镜像，见 [xn/README.md](xn/README.md)
  - `xn/tests/run-all.sh` — 仓库级离线测试入口：对全部 shell 脚本做 `bash -n`，并自动运行各模块 `tests/*.test.sh`；`.github/workflows/xn-tests.yml`（Actions 里的 **测试 XN**）是上游 `leptonyu/xn` 统一测试入口 `test.yml` 的镜像，手动触发：`suite` 选 `all`（默认，上游全部 active 条目，不含 pgo）/ `nightly` / `pr` / `release` / `manual` / `unit` / `smoke` / `e2e` / `bench` / `perf` / `pgo`（先编 PGO 再比），另有 `keep_going` 开关；配置与触发规则见 [xn/README.md](xn/README.md) 的「手动测试（测试 XN）」
