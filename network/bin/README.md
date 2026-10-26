# cidr（Linux x86_64）

`network/bin/cidr` 是 `rust/xn` 里 `xn-cidr-bin` 产出的 `cidr` CLI（v6.0.0，
2026-10-26 构建，sha256 `cd5e8fb627c820fb200efb1d8c086121d6c84163f406d433bb8486d694e0a629`），
给 GitHub Actions 的 `ubuntu-latest` 用。它是大文件，走 Git LFS：

```bash
git lfs install
git lfs pull        # checkout 时也可以 actions/checkout 的 lfs: true
file network/bin/cidr
# network/bin/cidr: ELF 64-bit LSB pie executable, x86-64 ...
```

## 重新构建

在 `rust/xn` 检出里（macOS 用 zig 交叉编译）：

```bash
cargo zigbuild --release --locked -p xn-cidr-bin \
  --target x86_64-unknown-linux-gnu.2.17
cp target/x86_64-unknown-linux-gnu/release/cidr \
  /path/to/dockerized-packages/network/bin/cidr
chmod +x /path/to/dockerized-packages/network/bin/cidr
```

`cidr.yaml` 用到 `subtract_merge` / `shrink_small_nets` / `pipeline` 等 v6 行为；
升级 `rust/xn` 后重新构建并提交这个二进制，避免 CI 与本地 `cidr` 版本漂移。

## 提交

`network/.gitattributes` 已把 `bin/cidr` 标成 LFS。首次提交时先加属性再加二进制，
确保走 LFS 而不是普通 blob：

```bash
git add network/.gitattributes
git add network/bin/cidr
git lfs status
```
