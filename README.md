# dockerized-packages
Dockerfiles

- `network/` — 每日 release 的生成目录（CI 生成，见 [network/README.md](network/README.md)）：
  - `network/dns/` — DNS / AdGuard 制品：`gen.sh` 生成 `dlc.dat(.xz)`（DNS 分流 / 广告拦截 DLC）、`apple.conf`、`filter_49`；`domain.txt` 只维护手工 fake 域名
  - `network/xn_*` — xn 的 xn_block / xn_block_orig / xn_block_all / xn_cn / xn_fake / xn_us / xn_vpn / xn_allow CIDR 名单
- `xn/` — 上游 [leptonyu/xn](https://github.com/leptonyu/xn) 的 PGO+BOLT x86_64 GNU 构建：复用上游 `./release.sh --tuned`，独立 workflow 跟踪上游 `main`，有更新才编译；只打两个包（`tuned.tar.xz` 二进制 + `tuned.trace.tar.xz` 全过程含 perf.data），发布回 `XN_REPO`（默认 `leptonyu/xn`）的 `v<Cargo.toml version>` release，见 [xn/README.md](xn/README.md)
  - `xn/tests/run-all.sh` — 仓库级离线测试入口：对全部 shell 脚本做 `bash -n`，并自动运行各模块 `tests/*.test.sh`；`.github/workflows/xn-tests.yml` 手动触发时先跑它，再 checkout 上游 `leptonyu/xn` 的最新 commit，用其 `scripts/test/all.sh` 跑完整测试套件（在 GitHub-hosted `ubuntu-latest` 上跑；需要 `XN_REPO_TOKEN`，缺 root/eBPF/VM 的条目默认 skip）
