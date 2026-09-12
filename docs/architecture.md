# How it works

## Overview

1. The launcher parses its own options, one optional workspace, and the exact arguments following `--`.
2. It resolves the workspace, config files, and mirrored container identity.
3. It selects a profile using CLI `--tool` > `SANDBOX_TOOL` > workspace `tool` > user `tool` > Claude.
4. The profile chooses its npm package, host-derived or pinned version, autonomy flag, optional API key, and read/write config binds.
5. The launcher assembles conditional read-only git-config binds, identity overrides, and an optional generated read-only policy bind.
6. It runs `docker compose run --rm`, starting a fresh `ai-agent` container in the per-UID Compose project.
7. The root entrypoint creates the mirrored user/group when needed, configures push protection, drops privileges, and execs the selected coding agent.
8. The selected coding agent works in the bind-mounted workspace under the git wrapper policy. The container is removed on exit; named volumes persist.
9. When enabled and applicable, a one-shot `cleanup` container removes empty mount-point parent stubs; the generated policy file is removed by the launcher exit trap.

Claude receives `--dangerously-skip-permissions`; Codex receives `--dangerously-bypass-approvals-and-sandbox`. The container limits the blast radius while the selected coding agent operates autonomously.

Multiple sessions can run in parallel. Per-user project naming (`claude-sandboxed-${SANDBOX_UID}`) isolates different host UIDs; Claude and Codex sessions for one UID share the same `claude-agent-home` named volume.

## Network isolation

**Current status: no network isolation.** The container uses `network_mode: host`, meaning it shares the host's network namespace. This was chosen for simplicity and allows the container to reach host-local services such as a proxy at `127.0.0.1:1080`.

Host networking provides reachability but does not copy host proxy settings or force traffic through a proxy. The launcher separately builds `PROXY_ENV_ARGS` from non-empty standard host proxy variables when `proxy.env_passthrough` is enabled, then passes those arguments to `docker compose run` before `npx` starts.

Improving network isolation is a planned future goal. The current focus is on filesystem and git-level sandboxing.

### On-host browser service (optional)

A selected agent does not get a browser inside the container. Instead, browser automation is served *from the host*: a Playwright MCP server (`@playwright/mcp`, see `install-playwright-systemd`) listens on `127.0.0.1` on the host. Because the container uses host networking, the agent reaches it at `http://127.0.0.1:<port>/mcp`. The browser runs on the host as the host user, is headed by default (the user sees and can interact with it), and is only launched when the agent first drives a `browser_*` tool. The launcher wires this up when `browser.enabled` is true: it passes `PLAYWRIGHT_MCP_URL`, and for Claude registers the remote MCP server via a generated read-only `--mcp-config` mounted at `/etc/claude-sandboxed/mcp-config.json`. No state from the sandbox reaches the browser; the browser's profile lives under the host user's `~/.cache/ms-playwright`.

## Volume layout and lifecycle

| Mount | Scope | Lifecycle |
|---|---|---|
| Workspace bind | Selected project | Host files persist; container is ephemeral |
| `claude-agent-home` named volume | Host UID | Shared across tools/workspaces/sessions until Docker removal |
| Tool-config bind | Host user by default; configurable per workspace | Host files persist; read/write |
| Git-config bind | Host user | Host files persist; read-only in container |
| Generated policy bind | One launcher invocation | Temporary host file removed by exit trap; read-only |
| Git-wrapper bind | Package installation | Persists with installation; read-only |

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

Proxy environment passthrough is tool-neutral and defaults to enabled. `SANDBOX_PROXY_ENV_PASSTHROUGH` / `proxy.env_passthrough` can disable it. Uppercase and lowercase forms are independent and values are forwarded unchanged; proxy URLs are not stored in YAML.

## Root user mode

When `SANDBOX_UID=0` the entrypoint skips user and group creation and does not call `runuser` — the selected coding agent runs directly as root inside the container. This is mainly useful for CI environments where the container already runs as root.

## Git config inheritance

The host user's `~/.gitconfig` and `~/.config/git/` are bind-mounted into the container at the corresponding paths under `$SANDBOX_HOME`, read-only. Mounts are conditional: if the host path does not exist, the mount is skipped (git uses defaults). Read-only prevents the selected coding agent from modifying the host's git config.

Git config precedence is system < global, so a user's `~/.gitconfig` could override `core.sshCommand` set via `git config --system`. This is acceptable because `git push` is blocked at the wrapper level (see below), and the threat model is accidental damage, not adversarial bypass.

## Git operation policy

A wrapper script at `share/claude-sandboxed/git-wrapper` is bind-mounted to `/usr/local/bin/git` in the container (read-only). The `node:22-bookworm` image's default `PATH` has `/usr/local/bin` before `/usr/bin`, so `git` invocations hit the wrapper. The wrapper parses argv, applies a blocklist of destructive subcommands plus flag-level checks on allowed subcommands, then `exec`s `/usr/bin/git` for allowed commands.

The wrapper does **not** strip user-supplied `-c` flags or `GIT_CONFIG_*` env vars. The defense is that push is blocked at the subcommand level, and `~/.gitconfig` is read-only.

**Bypass via `/usr/bin/git` directly is a known limitation.** See `docs/tradeoffs.md`.

### Blocked operations

- **Fully blocked subcommands:** `push`, `reset`, `rebase`, `filter-branch`, `filter-repo`, `clean`, `config`
- **Conditionally blocked:** `reflog expire|delete`, `notes remove|prune`, `worktree remove|prune`, `stash drop|clear`, `branch -D|--delete --force` (force delete; safe `-d`/`--delete` allowed), `tag -f|--force` (force; safe `-d`/`--delete` allowed)
- **Flag-level blocks:** `commit --amend|--reset-author`, `checkout -B|-f|--force|-- <pathspec>`, `switch -C|--discard-changes`, `restore --worktree|-W`, `rm` (without `--cached`), `gc --prune`

### Defense in depth

Two independent layers block `git push`:

1. Entrypoint sets `git config --system core.sshCommand ...` and `url.insteadOf` rules (existing).
2. Wrapper blocks `git push` at the subcommand level (new).

Either failing leaves the other working.
