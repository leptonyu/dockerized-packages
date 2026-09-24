# dsh

The [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) Web GUI,
installed from the published [`@deepseek-ai/dsh`](https://www.npmjs.com/package/@deepseek-ai/dsh)
package and started as `dsh web`.

## Run

```sh
docker run --rm -it \
  -p 3080:3080 \
  -v "$PWD:/workspace" \
  -v "$HOME/.dsh:/home/node/.dsh" \
  icymint/dsh:v0.1.7-rc.1
```

The server prints the URL that carries the one-time login token; open it:

```text
dsh web: http://127.0.0.1:3080/?token=...
```

Add `--trusted-host <host[:port]>` to reach the GUI by another authority, for
example over the LAN:

```sh
docker run --rm -it -p 3080:3080 -v "$PWD:/workspace" icymint/dsh:v0.1.7-rc.1 --trusted-host my-box
```

## Layout

| Path | Purpose |
| :--- | :--- |
| `/workspace` | working directory, and the `workspace-write` boundary of the file sandbox |
| `/home/node/.dsh` (`$DSH_HOME`) | profiles, settings, model credentials, session data |
| `/usr/local/cargo` (`$CARGO_HOME`) | Rust toolchain shims and the writable crate registry |
| `/usr/local/rustup` (`$RUSTUP_HOME`) | Rust toolchains, writable so `rustup component add` works |
| `/usr/local/share/dsh/container.patch.yml` | the overlay that rebinds the Web server to `0.0.0.0` |

Mount `$HOME/.dsh` to keep model configuration and sessions across runs. The
container user is uid 1000, so on Linux a mounted directory owned by another uid
does not work as `/home/node/.dsh`; either point the home somewhere the run can
write, `-e DSH_HOME=/tmp/dsh-home`, or combine
`--user "$(id -u):$(id -g)"` with a `DSH_HOME` inside a directory you own.

The image ships the CLI, the Rust toolchain from `rust:1.98.1-slim-trixie`, and
a small base toolset (`gcc`, `git`, `curl`, `jq`, `python3`). Extend it for
anything else the agent should have:

```dockerfile
FROM icymint/dsh:v0.1.7-rc.1
USER root
RUN apt-get update && apt-get install -y --no-install-recommends golang
USER node
```

## Notes

- `dsh web` binds loopback and rejects `--host 0.0.0.0`; `container.patch.yml`
  rebinds the composed `webserver` row instead, so `-p 3080:3080` works. Map a
  different host port only if you replace the port in the printed URL by hand.
- The command sandbox runs under Landlock on Linux, which needs kernel 5.13+ and
  a seccomp profile that permits its syscalls. Docker's default profile does; if
  the launcher probes unusable anyway, pass
  `--security-opt seccomp=unconfined`.
- `DSH_PERMISSION_MODE` overrides the `workspace-write` default; `danger-full-access`
  removes file confinement for a throwaway container.
- Rust is the official image's minimal profile — `cargo`, `rustc`, and the
  standard library — plus `gcc`, `libc6-dev`, and `pkg-config` so it can link.
  `rustfmt` and `clippy` are not part of that profile; add them with
  `rustup component add rustfmt clippy`, since `$RUSTUP_HOME` is writable by the
  `node` user.
- Settings → Plugins installs a bundle with `pnpm`, which the published
  `@deepseek-ai/dsh` package does not carry — the same limitation as running
  `npx @deepseek-ai/dsh web`. Add it in a derived image when you need that page:

  ```dockerfile
  FROM icymint/dsh:v0.1.7-rc.1
  USER root
  RUN npm install --global --prefix /opt/dsh pnpm@11
  USER node
  ```

- The image version tracks the `deepseek-ai/deepseek-harness` release tags, and
  Renovate accepts `-rc.N` candidates while refusing `-alpha.N` pre-releases.
