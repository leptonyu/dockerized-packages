# dockerized-packages
Dockerfiles

- `network/` — xn 的 xn_block / xn_block_orig / xn_block_all / xn_cn / xn_fake / xn_us / xn_vpn / xn_allow CIDR 名单（CI 生成，见 [network/README.md](network/README.md)）
- `xn/` — 上游 [leptonyu/xn](https://github.com/leptonyu/xn) 的 PGO+BOLT x86_64 GNU 构建：复用上游 `./release.sh --tuned`，独立 workflow 跟踪上游 `main`，有更新才编译，产物发布回 `XN_REPO`（默认 `leptonyu/xn`）的 `v<Cargo.toml version>` release，见 [xn/README.md](xn/README.md)
