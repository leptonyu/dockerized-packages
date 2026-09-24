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
| `/usr/local/share/dsh/hardened.patch.yml` | the opt-in overlay that stops a session widening its own file policy |

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

## Locking the sandbox down

`SandboxMode` governs **file effects only** — `read-only`, `workspace-write`, and
the bypass `danger-full-access`. Reads, network use, and process visibility are
deliberately outside that vocabulary. So "no escape" is two layers: the file
policy inside the process, and the container around it.

Two shipped policy paths let a session leave its file policy on its own:

- the **Permissions selector** offers a `danger-full-access` preset that switches
  the session's sandbox mode off;
- a denied bash call or fs `write`/`edit` may carry `sandbox_permissions` for a
  one-shot wider retry, and the plugin manager asks before every install. Every
  one of those asks resolves through `ctx.approval`.

`hardened.patch.yml` closes both:

```sh
docker run --rm -it \
  -p 127.0.0.1:3080:3080 \
  --cap-drop ALL --security-opt no-new-privileges \
  --pids-limit 2048 --memory 8g \
  -v "$PWD:/workspace" -v "$HOME/.dsh:/home/node/.dsh" \
  icymint/dsh:v0.1.7-rc.1 \
  --patch /usr/local/share/dsh/hardened.patch.yml --no-open
```

Add `--read-only --tmpfs /tmp:rw,noexec,nosuid,size=2g` when the workload never
needs to persist outside its mounts — but then Cargo needs a writable home, so
pair it with `-v dsh-cargo:/home/node/.cargo -e CARGO_HOME=/home/node/.cargo`.
The `cargo` on `PATH` is only the toolchain shim under `/usr/local/cargo/bin`,
which reads `$RUSTUP_HOME` and nothing else writable.

| Overlay row | Composed value | Effect |
| :--- | :--- | :--- |
| `sandbox-policy` | `mode: workspace-write` | pins the standing mode, so no `DSH_PERMISSION_MODE` value can widen it |
| `approval` | `policy: never` | every widening ask resolves `rejected` without dispatching an answerer |
| `permission` | presets `read-only`, `workspace-write` | drops the `danger-full-access` entry from the selector table |

Why that holds, rather than merely greying out a button:

- `permission-presets` is the only caller of the sandbox-mode write path
  (`setSandboxMode`), and `set()` resolves the requested name against the
  configured table, throwing `permission: unknown preset "danger-full-access"`.
  Removing the entry removes the path.
- `never` is the strict unattended stance: an `allowed-once` grant is the only
  outcome that widens anything, and `never` can never produce one. Ordinary work
  inside the standing mode asks for nothing, so it keeps running.
- The agent cannot rewrite the policy: the `workspace-write` roots are only
  `/workspace` and the temp area, so `$DSH_HOME` (profiles and settings) and
  `/usr/local/share/dsh` (these overlays) stay unwritable.
- The plugin manager needs `pnpm` to install anything, and this image has none.

The container still has to bound what the policy cannot see:

- **Reads are unconfined.** Anything readable by uid 1000 is readable by the
  agent, including `$DSH_HOME/.credentials.yaml`. Mount nothing you would not
  hand to the agent, and use a scoped or disposable model key.
- **Network is unconfined.** Neither runner restricts it; use a network policy,
  an egress proxy, or `--network none` when the task needs no model calls.
- **Process visibility** depends on the rung. Landlock shares the host PID
  namespace; `bwrap` does not.
- **The Web token is remote code execution by design.** Keep the publish on
  `127.0.0.1`, avoid a broad `--trusted-host`, and prefer an SSH tunnel.

Verify it end to end by asking the agent to write outside `/workspace`: the call
is denied with an escalation hint, and the follow-up escalation comes back
`rejected`.

### The stronger rung (optional)

The Linux chain prefers `bwrap` — read-only host root, fresh `/dev`, private PID
namespace, ephemeral `/tmp` — and falls back to Landlock, which is what runs
here because the image ships no `bwrap`. To get the stronger rung, add it and
let the container create the user namespaces it needs:

```dockerfile
FROM icymint/dsh:v0.1.7-rc.1
USER root
RUN apt-get update && apt-get install -y --no-install-recommends bubblewrap
USER node
```

```sh
docker run … --security-opt seccomp=unconfined …
```

That is a deliberate trade: the default seccomp profile denies `clone` with the
namespace flags, so `seccomp=unconfined` widens the container's syscall surface —
which `--cap-drop ALL` and `--no-new-privileges` then bound. Both rungs are
probed functionally and the backend fails closed (`SANDBOX_UNAVAILABLE`, the
command never runs) when neither is usable, so a `bwrap` that cannot create its
namespaces is skipped rather than silently running unconfined.

## Notes

- `dsh web` binds loopback and rejects `--host 0.0.0.0`; `container.patch.yml`
  rebinds the composed `webserver` row instead, so `-p 3080:3080` works. Map a
  different host port only if you replace the port in the printed URL by hand.
- The command sandbox runs under Landlock on Linux, which needs kernel 5.13+ and
  a seccomp profile that permits its syscalls. Docker's default profile does; if
  the launcher probes unusable anyway, pass
  `--security-opt seccomp=unconfined`.
- `DSH_PERMISSION_MODE` overrides the `workspace-write` default, and
  `danger-full-access` removes file confinement — for a throwaway container. See
  [Locking the sandbox down](#locking-the-sandbox-down) to close that off.
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