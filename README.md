# ai-sandbox

Runs Claude Code, Codex CLI, or OpenCode inside a Docker sandbox with a shared workspace mount and git push protection. The command is `ai-sandbox` (short alias `asb`).

The main rationale of this project is to run Claude Code in autonomous mode (with `--dangerously-skip-permissions`) more safely, reducing harms to the user's machine / files. Whitebox protection is the main design, to provide deterministic guarantees (contrary to Anthrophic's probabilistic classifier).

> To be fully transparent: the whitebox protection is not always useful for every case, as it would be too complicated. But I'd prefer it because that provides accountability, something that probabilistic classifiers will not have.
> "What can go wrong will go wrong."

## Requirements

- Docker with the Compose plugin (`docker compose`)
- A valid session or API key for the selected tool (`~/.claude` / `ANTHROPIC_API_KEY`, `~/.codex` / `OPENAI_API_KEY`, or `~/.local/share/opencode` / `OPENAI_API_KEY` / `ANTHROPIC_API_KEY`)
- `yq` (only if using config files - see [Configuration](#configuration))

## Installation

You may directly run `bin/ai-sandbox`, but it may change. Proper installation is always preferred.

### Arch Linux

```sh
git clone <repo-url>
cd ai-sandbox/packaging
makepkg -si
```

### Any Unix (macOS, WSL, Linux) (To be tested)

```sh
git clone <repo-url>
cd ai-sandbox
sudo ./install.sh
```

Installs to `/usr/local` by default. Override with `PREFIX`:

```sh
PREFIX=~/.local ./install.sh   # no sudo needed here
```

Any standard `<prefix>/bin` + `<prefix>/share` layout works (Homebrew `/opt/homebrew`, `/usr/local`, `~/.local`, etc.).

## Usage

```sh
ai-sandbox
asb                      # short alias
ai-sandbox --tool codex
asb-codex                # per-tool alias, equivalent to: ai-sandbox --tool codex
asb-codex ~/projects/my-app -- --model gpt-5.4
ai-sandbox --tool opencode
ai-sandbox --tool opencode@v2.0.18           # pin a specific tool version
ai-sandbox ~/projects/my-app -- --resume
ai-sandbox --help         # full usage reference (options, aliases, examples)
ai-sandbox --version
```

Run `ai-sandbox --help` for the full option reference. In short: `--tool <claude|codex|opencode>` selects the tool (with an optional `@version` pin), `--allow-local-git` enables the git local-override mode, `serve start|stop|attach` manages an OpenCode server (v1 or v2), `-h/--help` and `-V/--version` print the help/version, one optional `WORKSPACE` directory may be given, and everything after `--` is passed unchanged to the selected tool in normal interactive mode.

Claude is the default. Tool selection precedence is CLI `--tool` (or the invoked `asb-claude`/`asb-codex`/`asb-opencode` name) > `SANDBOX_TOOL` > workspace `tool` > user `tool` > Claude. Supported tools: `claude`, `codex`, `opencode`. Arguments after `--` are passed unchanged to the selected tool.

A tool version can be bundled into the `--tool` spec (`ai-sandbox --tool codex@1.2.3`, `opencode@v1.29.11`, `claude@2.1.152`). A bundled `@version` is the highest-precedence pin, beating the version env vars, config, and host-version fallback; the leading `v` is optional. `--tool opencode@2.5.0` therefore selects opencode v2 directly.

Set `AI_SANDBOX_DIR` to override the directory containing `docker-compose.yml`.

Set `CLAUDE_VERSION`, `CODEX_VERSION`, or `OPENCODE_VERSION` to pin the selected tool version inside the container. Claude and Codex default to the corresponding host CLI version, or npm's latest when absent. OpenCode defaults to its host CLI version, or v1 when absent.

OpenCode v1 and v2 are separate npm packages: `1.x` runs `opencode-ai`, while `2.x` runs `@opencode/cli`. The launcher mirrors the installed host OpenCode version when one is available; without one or an explicit pin, it defaults to v1. Pin a version with `--tool opencode@2.0.18`, `OPENCODE_VERSION`, or `opencode.version`.

OpenCode v2 launches with `--standalone`, giving each TUI a private server and avoiding its managed background service's fixed port on the shared host network. The existing OpenCode config and data mounts remain shared with the host. Concurrent v2 sessions are available for testing, but shared OpenCode state may still cause contention; this launcher does not isolate v2's data store per workspace.

### OpenCode server for mobile access (v1 and v2)

`asb serve` keeps an OpenCode server running in a detached sandbox container, reachable from a phone or browser on the host's network. It supports both OpenCode v1 (`opencode-ai`) and v2 (`@opencode/cli`); the server shape differs between the two.

- **v1** runs `opencode web` by default (browser UI + API); `--headless` selects `opencode serve` for an API-only server. Clients log in with username `opencode` (or `OPENCODE_SERVER_USERNAME`) and the password from `OPENCODE_SERVER_PASSWORD`.
- **v2** runs a single `@opencode/cli serve`, which always serves both the web UI and the API; `--headless` is accepted but has no effect. The password comes from `OPENCODE_PASSWORD` or `OPENCODE_SERVER_PASSWORD`, and browser/app access uses one-time pairing links rather than a password login.

```sh
# Export a server password first. v1 reads OPENCODE_SERVER_PASSWORD; v2 reads
# OPENCODE_PASSWORD (or OPENCODE_SERVER_PASSWORD, which v2 also honors).
asb serve start --tool opencode ~/projects/my-app         # v1 (the default)
asb serve start --tool opencode@2.0.18 ~/projects/my-app  # v2
# v1: open http://<host-zerotier-ip>:4096 on your phone; username opencode + password.
# v2: pair a browser or app once via `opencode pair` (see below).
asb serve attach --tool opencode ~/projects/my-app
asb serve stop --tool opencode ~/projects/my-app
```

The server runs inside the same workspace and mount policy as the interactive sandbox. `attach` opens a TUI in that container; for v2 it connects with `opencode --server <url>`. Leaving the TUI keeps the server running. `stop` removes the server container. The command identifies a server by host user and canonical workspace path; `attach` also uses that path as its working directory. Specify the same workspace for all three actions, or run them from that workspace when omitting the path. `--tool opencode` can be omitted for `serve`.

Both network options are optional. `--port` defaults to `4096`, a stable port for phone bookmarks; OpenCode's bare `web`/`serve` command normally chooses a random port. `--hostname` defaults to `all`, meaning `0.0.0.0` (all host IPv4 interfaces). Because the container uses host networking, this includes host and sandbox loopback, ZeroTier, and Wi-Fi/LAN addresses. No Docker port mapping is needed. `--hostname lo` binds only `127.0.0.1`; `--hostname <specific-ip>` limits the listener to that address, so other addresses, including localhost, cannot reach it. `all` and `lo` are launcher shorthands; OpenCode itself accepts addresses. A single server does not bind to two selected IPs separately. Use a different port for each concurrent workspace server.

`start` waits for an authenticated health response (`GET /global/health` for v1, `GET /api/info` for v2) before reporting success. If the container exits or never becomes ready, it stays available for `docker logs <container-name>` inspection; run `asb serve stop` before trying again.

The server password is read from the environment, never from stdin, and is forwarded to Docker by name so its value never appears in command arguments (Docker administrators can still inspect a container's environment). OpenCode v1 requires `OPENCODE_SERVER_PASSWORD` and takes an optional `OPENCODE_SERVER_USERNAME`; OpenCode v2 accepts either `OPENCODE_PASSWORD` or `OPENCODE_SERVER_PASSWORD` with the fixed username `opencode`. To connect a phone or browser to a v2 server, pair it: run `opencode pair` (pointed at the server with `--server <url>`) and open the printed one-time link. The all-interface default also listens on any other host IPv4 interface; restrict the port to trusted networks with a host firewall if needed. ZeroTier encrypts traffic between its peers.

## Browser automation (on the host)

The sandbox can drive a browser that runs on the host, so the user sees and can interact with it. This is a one-time, scripted setup followed by a config flag:

```sh
# 1. One-time: enable the host-side Playwright MCP service (installed with the
#    package, into /usr/lib/systemd/user or ~/.local/share/systemd/user)
systemctl --user daemon-reload
systemctl --user enable --now ai-sandbox-playwright
```

```yaml
# 2. Per-project or user config: opt in
browser:
  enabled: true
```

When enabled, the launcher passes `PLAYWRIGHT_MCP_URL` into the sandbox and (for Claude) registers the MCP server automatically, so the agent can call `browser_navigate`, `browser_click`, `browser_snapshot`, etc. The browser window appears on the host and is only launched when the agent first drives it. See [docs/configuration.md](docs/configuration.md#browser-automation-of-a-visible-host-browser) for details.

## Configuration

Identity knobs can be set persistently via YAML config files instead of env vars. Two files are read, in priority order: `$WORKSPACE_DIR/.ai-sandbox.yaml` (per-project) and `${XDG_CONFIG_HOME:-~/.config}/ai-sandbox/config.yaml` (user defaults). Both are optional. Precedence per knob: env var > workspace config > user config > built-in default.

A commented template is installed at `<prefix>/share/ai-sandbox/config.example.yaml`. Copy it to get started:

```sh
mkdir -p ~/.config/ai-sandbox
cp /usr/local/share/ai-sandbox/config.example.yaml ~/.config/ai-sandbox/config.yaml
```

Requires `yq` on the host; config files are ignored (with a warning) when `yq` is missing.

See [docs/configuration.md](docs/configuration.md) for the full schema and per-knob reference: user identity, git identity, tool versions, Claude/Codex/OpenCode config passthrough, proxy env passthrough, cleanup, extra and auto-detected mountpoints, browser automation, startup progress, git policy config, local-override mode, and the git wrapper policy reference.

## Shell completion

The package ships bash and zsh tab-completion for `ai-sandbox` and its aliases (`asb`, `asb-claude`, `asb-codex`, `asb-opencode`).

How it works: when you press Tab, your shell runs a completion function that offers the launcher's options (`--tool`, `--help`, `--version`, `--allow-local-git`, `--`), the tool names after `--tool` (`claude`, `codex`, `opencode`), and directory names for the workspace argument. After a bare `--`, completion defers to the selected tool's own arguments (i.e. the shell's default).

Install places the files where the shells look automatically:

- **bash** — `<prefix>/share/bash-completion/completions/ai-sandbox` (plus symlinks for the aliases), loaded lazily by `bash-completion`.
- **zsh** — `<prefix>/share/zsh/site-functions/_ai-sandbox`, loaded by `compinit`.

If your prefix is not on your shell's completion search path (or you don't use those frameworks), source them manually:

```sh
# bash
source <prefix>/share/ai-sandbox/completions/ai-sandbox.bash
# zsh (before compinit, or re-run compinit afterwards)
fpath+=(<prefix>/share/ai-sandbox/completions)
```

## Features

- [x] **Sandboxed execution** - confines Claude Code to the target workspace, protecting the rest of your system from unintended changes
    - [x] **Workspace isolation** - only the target project directory is mounted; the rest of the host filesystem is unreachable inside the container
    - [x] **Isolated environment and cache** - packages and global tools install into a persistent container volume, never touching the host
    - [x] **Git operation policy** - a wrapper script blocks destructive git operations (push, reset, rebase, clean, commit --amend, branch -D, tag -f, worktree remove --force, worktree prune, etc.) and history-bypass plumbing (commit-tree, update-ref, replace, fast-import, prune, symbolic-ref) while allowing non-destructive and appending-only operations (commit, add, status, log, fetch, merge, branch -d, tag -d, worktree remove, etc.)
    - [x] **Git config inheritance** - the host user's `~/.gitconfig` and `~/.config/git/` are bind-mounted read-only so Claude commits with the host user's identity
    - [x] **Sandbox information** - The runtime can detect that it is in the sandbox
        - [x] Option 1: via `IS_SANDBOX=1`
        - [ ] Option 2: via system prompt
        - [ ] Option 3: via skill (which exposes multiple information, including some additional hints for sandbox-host interaction)
- [x] **Transparent isolation** - the sandbox boundary is invisible to Claude Code: it sees the same user identity, credentials, paths, and Claude settings as on the host, while the rest of the system stays out of reach
    - [x] **Claude config passthrough** - the entire `~/.claude` directory (credentials, skills, settings, etc.) and `ANTHROPIC_API_KEY` are forwarded automatically
    - [x] **Host identity mirroring** - Claude Code runs as your host user (same UID, GID, username, and home path), so file ownership is consistent
    - [x] **Host time and locale** - mounts the host's `/etc/localtime` and `/etc/timezone` read-only when available and forwards non-empty `TZ`, `LANG`, `LANGUAGE`, and standard `LC_*` variables to agent containers
    - [x] **Host network access** - the container shares the host network, so host-local services are reachable from inside (e.g. a proxy at `127.0.0.1:1080`, or a network-based MCP server running on the host)
    - [x] **On-host visible browser** - optional (`browser.enabled`) browser automation where the browser runs on the host (visible/interactive for the user) via a Playwright MCP server, driven from inside over host networking
    - [x] **Proxy environment passthrough** - standard uppercase and lowercase proxy variables are forwarded by default, with a global or per-workspace opt-out
    - [x] **Automatic cleanup** - the container is removed on exit
    - [x] **Additional mountpoints** - Additional paths to mount into the container
        - [x] Manual list (`mounts.extra`; read-only by default, e.g. CC Switch's own settings directory)
        - [x] Automatic-sensing for known cases: linked git worktree / submodule git-dir and its common git dir (objects/refs) (`mounts.auto.git_worktree`) and config symlinks that point outside the mounted roots (`mounts.auto.symlinks`)
        - [ ] General intelligent-sensing beyond those cases
    - [ ] **Safe passthrough** - safely passthrough files and folders between host and sandbox, such as package caches
- [x] **Parallel sessions** - each invocation runs as an independent one-shot container, so multiple sandboxed sessions can run concurrently
- [x] **Startup progress** - a self-erasing spinner covers preparation; tool package warm-up names the package and shows Docker/npm fetch diagnostics so a slow first launch has useful detail; disable with `progress.enabled: false` / `SANDBOX_PROGRESS=false`
- [x] **Pinnable Claude version** - set `CLAUDE_VERSION` to lock a specific Claude Code release inside the container
- [x] **Automated tests** - host-side test suites cover the launcher, config resolution, the git wrapper, and the host browser-service wrapper
    - [x] **Launcher and profile tests** - argument parsing, tool selection, version detection, profile configuration, exact argument passthrough, and startup progress
    - [x] **Configuration tests** - YAML validation and env > workspace > user > default resolution
    - [x] **Git wrapper tests** - destructive-operation policy enforcement and argument parsing
    - [x] **Browser MCP tests** - MCP handshake smoke test against the default browser MCP URL, plus unit tests for the host-side `playwright-mcp` wrapper (browser probing/selection, generated config, Wayland/headless handling)
    - [ ] **Docker-backed runtime tests** - end-to-end verification inside real containers
- [x] **Customization** - set preferences through config files (with docs and examples)
    - [x] **Config foundation** - YAML config loading (`yq`), env > workspace > user > default precedence, identity knobs (`sandbox_uid`/`gid`/`username`/`home`)
    - [ ] All isolation designs should be customizable
    - [x] **Git policy** - regex-based allow/block lists (`git.policy.allow` / `git.policy.block`) that patch the default wrapper policy
    - [x] **Git config** - per-sandbox identity override (`git.identity.name`/`email`) and host config passthrough toggle (`git.host_config_passthrough`)
    - [x] **Claude version** - pin Claude Code version via `claude.version`
    - [x] **Claude config passthrough** - toggle `~/.claude` mount via `claude.config_passthrough`
    - [x] **Cleanup** - toggle cleanup container via `sandbox.cleanup`
    - [x] **Additional paths** - mount arbitrary host paths via `mounts.extra` and auto-detect a linked worktree's git-dir + common git dir and out-of-tree config symlinks via `mounts.auto`
- [x] **Alternative Claude config and env** - use dedicated Claude config paths, disable config passthrough, or authenticate with `ANTHROPIC_API_KEY`
- [ ] **Network isolation** - container has its own network, isolated from the host
- [x] **More tools** - first-class Claude Code, Codex CLI, and OpenCode profiles
    - [x] **Codex version** - pin Codex CLI via `CODEX_VERSION` or `codex.version`
    - [x] **OpenCode version** - pin OpenCode via `OPENCODE_VERSION` or `opencode.version`
    - [ ] Additional built-in coding agents
- [x] **Rename** - named `ai-sandbox`, with the short alias `asb` and per-tool entrypoints `asb-claude` / `asb-codex` / `asb-opencode` (symlinks; the launcher auto-detects the tool from the invoked name. An explicit `--tool` still wins)
- [ ] **More runtimes** - support other runtimes than Docker

## TODO

Open items, mostly around the optional host-browser service (`browser.enabled`):

- **No browser auth/session isolation.** The Playwright MCP server binds to `127.0.0.1`, and the sandbox shares the host network, so *any* sandboxed agent can reach `http://localhost:8931/mcp` and get full control of the browser — including the user's logged-in sites (it intentionally drives the real profile). This is a trust boundary worth hardening for untrusted agents.
- **One shared browser instance across concurrent sessions.** The service holds a single browser; parallel `ai-sandbox` sessions all drive it, so pages/tabs from different agents collide. The `--isolated` option of the MCP server is not wired in.
- **Codex / OpenCode get no automatic MCP registration.** Only Claude is wired up with `--mcp-config`; for Codex/OpenCode the remote server must be registered manually. So `browser.enabled` is effectively Claude-only as shipped.

Already addressed: system-browser/Playwright version-mismatch (auto-installs Playwright's own chromium as a fallback) and the hardcoded `DISPLAY=:0` (Wayland is now auto-detected).

## Testing

Automated tests live in `tests/`. Run all tests from the repo root:

```sh
bash tests/run-all.sh
```

Each subdirectory of `tests/` contains a `test.sh` script for one component. The runner discovers and executes all of them. Tests run on the host (no Docker required) - the git wrapper tests use a stubbed real git binary, and the browser-mcp suite's handshake smoke test is skipped when the host-side browser service is not running.

## Further reading

- [docs/configuration.md](docs/configuration.md) - full configuration reference: schema, all knobs, git policy
- [docs/architecture.md](docs/architecture.md) - architecture, volumes, security model
- [docs/tradeoffs.md](docs/tradeoffs.md) - design decisions: privilege dropping, network isolation, and alternatives
- [docs/development.md](docs/development.md) - invariants, resolution logic, PKGBUILD notes, test checklist
