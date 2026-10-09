# How it works

## Overview

1. The launcher parses its own options, one optional workspace, and the exact arguments following `--`.
2. It resolves the workspace, config files, and mirrored container identity.
3. It selects a profile using CLI `--tool` > `SANDBOX_TOOL` > workspace `tool` > user `tool` > Claude.
4. The profile chooses its npm package, host-derived or pinned version, autonomy flag, optional API key, and read/write config binds.
5. The launcher assembles conditional read-only git-config binds, identity overrides, and an optional generated read-only policy bind.
6. When startup progress is enabled (the default), it first runs a non-interactive warm-up container (`npx <package> --version`) that fetches the tool package into the npm cache inside the `ai-agent-home` volume. A self-erasing progress line covers preparation; the warm-up then names the package and shows Docker and npm diagnostics. A failed warm-up is reported and the interactive run retries as before.
7. In normal mode it runs `docker compose run --rm`, starting a fresh `ai-agent` container in the per-UID Compose project; with the cache warm, `npx` starts the selected agent from cache. `serve start` instead runs an OpenCode v1 web server in a named detached container, while `serve attach` and `serve stop` target that container.
8. The root entrypoint creates the mirrored user/group when needed, configures push protection, drops privileges, and execs the selected coding agent.
9. The selected coding agent works in the bind-mounted workspace under the git wrapper policy. Normal interactive containers are removed on exit; a detached server container is removed by `serve stop`. Named volumes persist.
10. When enabled and applicable, a one-shot `cleanup` container removes empty mount-point parent stubs; the generated policy file is removed by the launcher exit trap.

Claude receives `--dangerously-skip-permissions`; Codex receives `--dangerously-bypass-approvals-and-sandbox`. The container limits the blast radius while the selected coding agent operates autonomously.

Multiple sessions can run in parallel. Per-user project naming (`ai-sandbox-${SANDBOX_UID}`) isolates different host UIDs; Claude and Codex sessions for one UID share the same `ai-agent-home` named volume. An OpenCode v1 server is named by UID and workspace path. Generated policy and MCP mount files for a detached server remain in the user's state directory until `serve stop` removes them.

## Network isolation

**Current status: no network isolation.** The container uses `network_mode: host`, meaning it shares the host's network namespace. This was chosen for simplicity and allows the container to reach host-local services such as a proxy at `127.0.0.1:1080`.

Host networking provides reachability but does not copy host proxy settings or force traffic through a proxy. The launcher separately builds `PROXY_ENV_ARGS` from non-empty standard host proxy variables when `proxy.env_passthrough` is enabled, then passes those arguments to `docker compose run` before `npx` starts.

Improving network isolation is a planned future goal. The current focus is on filesystem and git-level sandboxing.

### On-host browser service (optional)

A selected agent does not get a browser inside the container. Instead, browser automation is served *from the host*: a Playwright MCP server (the `playwright-mcp` package, shipped as the systemd user unit `ai-sandbox-playwright.service`) listens on `127.0.0.1` on the host. Because the container uses host networking, the agent reaches it at `http://127.0.0.1:<port>/mcp`. The browser runs on the host as the host user, is headed by default (the user sees and can interact with it), and is only launched when the agent first drives a `browser_*` tool. The launcher wires this up when `browser.enabled` is true: it passes `PLAYWRIGHT_MCP_URL`, and for Claude registers the remote MCP server via a generated read-only `--mcp-config` mounted at `/etc/ai-sandbox/mcp-config.json`. No state from the sandbox reaches the browser. The unit's launcher (`/usr/share/ai-sandbox/playwright-mcp`, install.sh: `/usr/local/share/ai-sandbox`) picks a browser and detects the display (Wayland vs X11): it prefers an existing *system* browser (chromium/chrome, then firefox) so the user's normal profile/logins are used — no Playwright browser build is downloaded in that case — and falls back to Playwright's own bundled chromium (auto-installed on first need) when no usable system browser is present.

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
