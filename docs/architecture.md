# How it works

## Overview

1. The launcher parses its own options, one optional workspace, and the exact arguments following `--`.
2. It resolves the workspace, config files, and mirrored container identity.
3. It selects a profile using CLI `--tool` > `SANDBOX_TOOL` > workspace `tool` > user `tool` > Claude.
4. The profile chooses its npm package, host-derived or pinned version, autonomy flag, optional API key, and read/write config binds.
5. The launcher assembles conditional read-only git-config binds, identity overrides, and an optional generated read-only policy bind.
6. When startup progress is enabled (the default), it first runs a non-interactive warm-up container (`npx <package> --version`) that fetches the tool package into the npm cache inside the `ai-agent-home` volume. A self-erasing progress line covers preparation; the warm-up then names the package and shows Docker and npm diagnostics. A failed warm-up is reported and the interactive run retries as before.
7. In normal mode it runs `docker compose run --rm`, starting a fresh `ai-agent` container in the per-UID Compose project; with the cache warm, `npx` starts the selected agent from cache. `serve start` instead runs an OpenCode (v1 or v2) server in a named detached container, while `serve attach` and `serve stop` target that container.
8. The root entrypoint creates the mirrored user/group when needed, configures push protection, drops privileges, and execs the selected coding agent.
9. The selected coding agent works in the bind-mounted workspace under the git wrapper policy. Normal interactive containers are removed on exit; a detached server container is removed by `serve stop`. Named volumes persist.
10. When enabled and applicable, a one-shot `cleanup` container removes empty mount-point parent stubs; the generated policy file is removed by the launcher exit trap.

Claude receives `--dangerously-skip-permissions`; Codex receives `--dangerously-bypass-approvals-and-sandbox`. The container limits the blast radius while the selected coding agent operates autonomously.

Multiple sessions can run in parallel. Per-user project naming (`ai-sandbox-${SANDBOX_UID}`) isolates different host UIDs; Claude and Codex sessions for one UID share the same `ai-agent-home` named volume. An OpenCode server is named by UID and workspace path. Generated policy and MCP mount files for a detached server remain in the user's state directory until `serve stop` removes them.

## Runtime backends

The launcher builds one set of mount (`-v HOST:CONT[:FLAGS]`) and environment (`-e NAME=VALUE`) specification arrays and dispatches the interactive run to a backend:

- **docker** (default): the arrays become the `docker compose run` invocation described above. Unchanged.
- **bwrap**: a host-integrated backend. The specification arrays are translated into `bwrap` bind/setenv flags, and additional bwrap-only mounts are prepared: `--unshare-all --share-net` namespaces, a read-only system allowlist (`/usr`, `/bin`, `/etc`, ...), `--proc`, `--dev`, a tmpfs `/tmp`, the workspace read-write, and a persistent per-workspace `$HOME` layer. The selected agent runs from the host's own installation (no image, no `npx` download). Generated files that must not be written into the read-only system binds (the git wrapper at `/run/ai-sandbox/bin/git`, a system gitconfig at `/run/ai-sandbox/gitconfig`, the git policy file, and the browser MCP config) live under the writable `/run/ai-sandbox`, with `PATH`, `GIT_CONFIG_SYSTEM`, and `GIT_POLICY_FILE` pointing at them. The host `/etc/localtime` and `/etc/timezone` need no dedicated mount (the `/etc` bind is already read-only). `IS_SANDBOX=1` is set.

The cache warm-up, the cleanup container, the per-UID `ai-agent-home` volume, and root-user mode are docker-only. Version pins do not apply under bwrap. `serve` and `openchamber` work under both backends — see "Serve and OpenChamber under bwrap".

### bwrap filesystem model

Binds are applied in order (later wins):

1. System toolchain read-only.
2. `$HOME` bound to the persistent per-workspace layer (writes never touch the real home).
3. Per-user toolchain directories (`.nvm`, `.cargo`, ...) and configured `bwrap.passthrough` paths read-only (or `:rw`).
4. Tool-config passthrough directories read-write (the same arrays the Docker backend mounts).
5. The workspace read-write.
6. `mounts.extra` / auto-detected mounts.
7. Secret `bwrap.deny` paths shadowed (read-home mode only).

With `--read-home`, step 2 is an overlayfs whose lower layer is the real home and whose upper is the same layer, so the real home is readable but writes still land in the layer. The home layer lives under `${XDG_STATE_HOME:-~/.local/state}/ai-sandbox/runtime/bwrap/<hash>/home`.

### Serve and OpenChamber under bwrap

`serve start|stop|attach` and `openchamber start|stop` work under both backends; the Docker path is unchanged. Under bwrap the server runs the **host's** OpenCode inside a detached sandbox:

- The server is launched with `setsid bwrap …` and `--die-with-parent` omitted (it must outlive the launcher); its process-group id is recorded. `serve stop` signals that group (SIGTERM, then SIGKILL), which reaches the sandboxed server even under `--unshare-all` PID isolation.
- A bwrap-only record, `serve.state`, is written under the per-user state dir (`…/ai-sandbox/serve/<name>/serve.state`) with `runtime`, `package`, `port`, `hostname`, `pgid`, and `pw_var`. Its **presence marks a bwrap server**; when it is absent, `stop`/`attach` use the Docker container labels exactly as before, so `asb serve stop` (with the default `--runtime docker`) still stops a bwrap server.
- The server password is written to a `0600` file in the state dir, bound read-only, and read into the environment by an inner `sh -c` immediately before `exec` — `bwrap --setenv` would otherwise expose the value in the monitor's argv. The Docker path keeps forwarding by name (`-e NAME`); in both, the value never appears in argv.
- The readiness probe runs on the host against loopback (the server shares the host network), using Node with the password from the environment, or `curl --netrc-file` as a fallback.
- `serve attach` opens a TUI in a second sandbox sharing the same workspace and home layer. Generated files for a detached server (`gitconfig`, credential file, `server.log`, `server.pgid`) live in the state dir so `serve stop` removes them.
- Version pins are ignored (the host tool is used), matching interactive bwrap; the v1/v2 command and health shape follow the installed version, and OpenCode's own log (`<data-dir>/log/opencode.log`) is the server log.

## Network isolation

**Current status: no network isolation.** The container uses `network_mode: host`, meaning it shares the host's network namespace. This was chosen for simplicity and allows the container to reach host-local services such as a proxy at `127.0.0.1:1080`.

Host networking provides reachability but does not copy host proxy settings or force traffic through a proxy. The launcher separately builds `PROXY_ENV_ARGS` from non-empty standard host proxy variables when `proxy.env_passthrough` is enabled, then passes those arguments to `docker compose run` before `npx` starts.

Improving network isolation is a planned future goal. The current focus is on filesystem and git-level sandboxing.

### On-host browser service (optional)

A selected agent does not get a browser inside the container. Instead, browser automation is served *from the host*: a Playwright MCP server (the `playwright-mcp` package, shipped as the systemd user unit `ai-sandbox-playwright.service`) listens on `127.0.0.1` on the host. Because the container uses host networking, the agent reaches it at `http://127.0.0.1:<port>/mcp`. The browser runs on the host as the host user, is headed by default (the user sees and can interact with it), and is only launched when the agent first drives a `browser_*` tool. The launcher wires this up when `browser.enabled` is true: it passes `PLAYWRIGHT_MCP_URL`, and for Claude registers the remote MCP server via a generated read-only `--mcp-config` mounted at `/etc/ai-sandbox/mcp-config.json`. No state from the sandbox reaches the browser. The unit's launcher (`/usr/share/ai-sandbox/playwright-mcp`, install.sh: `/usr/local/share/ai-sandbox`) picks a browser and detects the display (Wayland vs X11): it prefers an existing *system* browser (chromium/chrome, then firefox) so the user's normal profile/logins are used — no Playwright browser build is downloaded in that case — and falls back to Playwright's own bundled chromium (auto-installed on first need) when no usable system browser is present.

### OpenChamber UI (optional)

`asb openchamber start` starts the detached OpenCode server (as `serve start` does) and then the OpenChamber web UI **on the host**, attached to that server through `OPENCODE_HOST` + `OPENCODE_SKIP_START=true` + `OPENCODE_PASSWORD`. It adds no container mount or environment variable: the UI is an ordinary host process, reachable by the browser over the host network, and it shares the host network namespace the server already uses. The launcher records the UI port next to the server's state and `stop` targets that one port (`openchamber stop --port`), so a shared OpenChamber data directory with another instance is not disturbed. Because the UI runs on the host, its own terminal and Project Actions (git/GitHub, worktrees, previews) execute on the host — the sandbox bounds the agent's operations, not the UI's host-side tooling.

## Volume layout and lifecycle

| Mount | Scope | Lifecycle |
|---|---|---|
| Workspace bind | Selected project | Host files persist; container is ephemeral |
| `ai-agent-home` named volume | Host UID | Shared across tools/workspaces/sessions until Docker removal |
| Tool-config bind | Host user by default; configurable per workspace | Host files persist; read/write |
| Git-config bind | Host user | Host files persist; read-only in container |
| Generated policy bind | One launcher invocation | Temporary host file removed by exit trap; read-only |
| Git-wrapper bind | Package installation | Persists with installation; read-only |
| Host `/etc/localtime` bind | Host system timezone, when the file exists | Read-only for each agent container |
| Host `/etc/timezone` bind | Host timezone name, when the file exists | Read-only for each agent container |
| Extra/auto passthrough bind | Host paths from `mounts.extra` / `mounts.auto` | Host files persist; read-only by default (manual `:rw` opts in; auto git-worktree is read-write) |

The tool-config bind targets `${SANDBOX_HOME}/.claude` and `${SANDBOX_HOME}/.claude.json` for Claude, or `${SANDBOX_HOME}/.codex` for Codex. Each can be disabled independently. Bind mounts follow their host files' lifecycle; unlike them, the Docker-managed named volume outlives each ephemeral container.

## Container environment

The sandbox marker is always set. The selected profile's API key and enabled generic proxy variables are forwarded only when present:

| Variable | Source | Purpose |
|---|---|---|
| `IS_SANDBOX=1` | Hard-coded | Signals that the selected coding agent runs inside the external sandbox |
| `ANTHROPIC_API_KEY` | Host environment (Claude, if set) | Authenticates Claude without host config |
| `OPENAI_API_KEY` | Host environment (Codex, if set) | Authenticates Codex without host config |
| `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY`, `NO_PROXY` | Host environment (if non-empty and passthrough enabled) | Configures uppercase-aware proxy clients |
| `http_proxy`, `https_proxy`, `all_proxy`, `no_proxy` | Host environment (if non-empty and passthrough enabled) | Configures lowercase-aware proxy clients |
| `TZ` | Host environment (if non-empty) | Overrides the mounted system timezone when set |
| `LANG`, `LANGUAGE`, standard `LC_*` | Host environment (if non-empty) | Carries the host locale preferences into the container |
| `SANDBOX_GIT_PRESET` | Launcher (`git.policy.preset` / `SANDBOX_GIT_PRESET` / `--git-preset`) | Selects the git-wrapper policy preset (`strict` \| `daily` \| `relaxed`; default `daily`, unknown → `strict`) |

Proxy environment passthrough is tool-neutral and defaults to enabled. `SANDBOX_PROXY_ENV_PASSTHROUGH` / `proxy.env_passthrough` can disable it. Uppercase and lowercase forms are independent and values are forwarded unchanged; proxy URLs are not stored in YAML.

The `/etc/localtime` and `/etc/timezone` mounts and time/locale environment apply to warm-up, interactive, and OpenCode server containers. Containers share the host's kernel clock through Docker; the mounts control how that time is displayed and named when `TZ` is unset. Locale variables select preferences, but the container image must provide a requested locale for programs that require installed locale definitions.

## Root user mode

When `SANDBOX_UID=0` the entrypoint skips user and group creation and does not call `runuser` — the selected coding agent runs directly as root inside the container. This is mainly useful for CI environments where the container already runs as root.

## Git config inheritance

The host user's `~/.gitconfig` and `~/.config/git/` are bind-mounted into the container at the corresponding paths under `$SANDBOX_HOME`, read-only. Mounts are conditional: if the host path does not exist, the mount is skipped (git uses defaults). Read-only prevents the selected coding agent from modifying the host's git config.

Git config precedence is system < global, so a user's `~/.gitconfig` could override `core.sshCommand` set via `git config --system`. This is acceptable because `git push` is blocked at the wrapper level (see below), and the threat model is accidental damage, not adversarial bypass.

## Git operation policy

A wrapper script at `share/ai-sandbox/git-wrapper` is bind-mounted to `/usr/local/bin/git` in the container (read-only). The `node:22-bookworm` image's default `PATH` has `/usr/local/bin` before `/usr/bin`, so `git` invocations hit the wrapper. The wrapper parses argv and applies a strict baseline blocklist, lifted only by the active preset's named relaxations, then `exec`s `/usr/bin/git` for allowed commands. The active preset is chosen by `git.policy.preset` / `SANDBOX_GIT_PRESET` / `--git-preset` (default `daily`; unknown names fall back to `strict`).

The wrapper does **not** strip user-supplied `-c` flags or `GIT_CONFIG_*` env vars. The defense is that push is blocked at the subcommand level, and `~/.gitconfig` is read-only.

**Bypass via `/usr/bin/git` directly is a known limitation.** See `docs/tradeoffs.md`.

### Blocked operations

The policy is a strict baseline plus a preset's named relaxations.

**Strict baseline (always applied, in every preset):**
- **Fully blocked subcommands:** `push`, `reset`, `rebase`, `filter-branch`, `filter-repo`, `config`, `commit-tree`, `update-ref`, `replace`, `fast-import`, `prune`, `symbolic-ref`
- **Conditionally blocked:** `reflog expire|delete`, `notes remove|prune`, `worktree prune`, `worktree remove -f|--force` (safe `remove` allowed: git itself refuses to remove a worktree with untracked or modified files unless forced)
- **Always-blocked flags:** `checkout -B`, `switch -C|--force-create`, `branch -f|--force` (force-move/reset), `gc --prune`

**Preset-gated relaxations:**
- `daily`: `commit --amend|--reset-author`, `checkout -f|--force|-- <pathspec>`, `switch --discard-changes|--discard`, `restore --worktree|-W`
- `relaxed` (daily plus): `branch -D|--delete --force`, `tag -f|--force`, `stash drop|clear`, `clean`, `rm` (without `--cached`)

`worktree prune` stays blocked even though it only deletes admin metadata: the sandbox does not mount other host worktrees' directories, so from inside the sandbox prune would consider them stale and delete their admin entries under `.git/worktrees`, breaking them on the host.

### Defense in depth

Two independent layers block `git push`:

1. Entrypoint sets `git config --system core.sshCommand ...` and `url.insteadOf` rules (existing).
2. Wrapper blocks `git push` at the subcommand level (new).

Either failing leaves the other working.
