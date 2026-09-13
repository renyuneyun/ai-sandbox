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
ai-sandbox ~/projects/my-app -- --resume
```

Claude is the default. Tool selection precedence is CLI `--tool` (or the invoked `asb-claude`/`asb-codex`/`asb-opencode` name) > `SANDBOX_TOOL` > workspace `tool` > user `tool` > Claude. Supported tools: `claude`, `codex`, `opencode`. Arguments after `--` are passed unchanged to the selected tool.

Set `AI_SANDBOX_DIR` to override the directory containing `docker-compose.yml`.

Set `CLAUDE_VERSION`, `CODEX_VERSION`, or `OPENCODE_VERSION` to pin the selected tool version inside the container. Each defaults to the corresponding host CLI version, or npm's latest when that CLI is not installed.

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

When enabled, the launcher passes `PLAYWRIGHT_MCP_URL` into the sandbox and (for Claude) registers the MCP server automatically, so the agent can call `browser_navigate`, `browser_click`, `browser_snapshot`, etc. The browser window appears on the host and is only launched when the agent first drives it. See [docs/configuration.md#browser](docs/configuration.md#browser) for details.

## Configuration

Identity knobs can be set persistently via YAML config files instead of env vars. Two files are read, in priority order: `$WORKSPACE_DIR/.ai-sandbox.yaml` (per-project) and `${XDG_CONFIG_HOME:-~/.config}/ai-sandbox/config.yaml` (user defaults). Both are optional. Precedence per knob: env var > workspace config > user config > built-in default.

A commented template is installed at `<prefix>/share/ai-sandbox/config.example.yaml`. Copy it to get started:

```sh
mkdir -p ~/.config/ai-sandbox
cp /usr/local/share/ai-sandbox/config.example.yaml ~/.config/ai-sandbox/config.yaml
```

Requires `yq` on the host; config files are ignored (with a warning) when `yq` is missing.

See [docs/configuration.md](docs/configuration.md) for the full schema and per-knob reference: user identity, git identity, tool versions, Claude/Codex/OpenCode config passthrough, proxy env passthrough, cleanup, git policy config, local-override mode, and the git wrapper policy reference.

## Features

- [x] **Sandboxed execution** - confines Claude Code to the target workspace, protecting the rest of your system from unintended changes
    - [x] **Workspace isolation** - only the target project directory is mounted; the rest of the host filesystem is unreachable inside the container
    - [x] **Isolated environment and cache** - packages and global tools install into a persistent container volume, never touching the host
    - [x] **Git operation policy** - a wrapper script blocks destructive git operations (push, reset, rebase, clean, commit --amend, branch -D, tag -f, etc.) and history-bypass plumbing (commit-tree, update-ref, replace, fast-import, prune, symbolic-ref) while allowing non-destructive and appending-only operations (commit, add, status, log, fetch, merge, branch -d, tag -d, etc.)
    - [x] **Git config inheritance** - the host user's `~/.gitconfig` and `~/.config/git/` are bind-mounted read-only so Claude commits with the host user's identity
    - [x] **Sandbox information** - The runtime can detect that it is in the sandbox
        - [x] Option 1: via `IS_SANDBOX=1`
        - [ ] Option 2: via system prompt
        - [ ] Option 3: via skill (which exposes multiple information, including some additional hints for sandbox-host interaction)
- [x] **Transparent isolation** - the sandbox boundary is invisible to Claude Code: it sees the same user identity, credentials, paths, and Claude settings as on the host, while the rest of the system stays out of reach
    - [x] **Claude config passthrough** - the entire `~/.claude` directory (credentials, skills, settings, etc.) and `ANTHROPIC_API_KEY` are forwarded automatically
    - [x] **Host identity mirroring** - Claude Code runs as your host user (same UID, GID, username, and home path), so file ownership is consistent
    - [x] **Host network access** - the container shares the host network, so host-local services are reachable from inside (e.g. a proxy at `127.0.0.1:1080`, or a network-based MCP server running on the host)
    - [x] **On-host visible browser** - optional (`browser.enabled`) browser automation where the browser runs on the host (visible/interactive for the user) via a Playwright MCP server, driven from inside over host networking
    - [x] **Proxy environment passthrough** - standard uppercase and lowercase proxy variables are forwarded by default, with a global or per-workspace opt-out
    - [x] **Automatic cleanup** - the container is removed on exit
    - [x] **Additional mountpoints** - Additional paths to mount into the container
        - [x] Manual list (`mounts.extra`; read-only by default, e.g. CC Switch's own settings directory)
        - [x] Automatic-sensing for known cases: linked git worktree / submodule common git dir (`mounts.auto.git_worktree`) and config symlinks that point outside the mounted roots (`mounts.auto.symlinks`)
        - [ ] General intelligent-sensing beyond those cases
    - [ ] **Safe passthrough** - safely passthrough files and folders between host and sandbox, such as package caches
- [x] **Parallel sessions** - each invocation runs as an independent one-shot container, so multiple sandboxed sessions can run concurrently
- [x] **Pinnable Claude version** - set `CLAUDE_VERSION` to lock a specific Claude Code release inside the container
- [x] **Automated tests** - host-side test suites cover the launcher, config resolution, and git wrapper
    - [x] **Launcher and profile tests** - argument parsing, tool selection, version detection, profile configuration, and exact argument passthrough
    - [x] **Configuration tests** - YAML validation and env > workspace > user > default resolution
    - [x] **Git wrapper tests** - destructive-operation policy enforcement and argument parsing
    - [ ] **Docker-backed runtime tests** - end-to-end verification inside real containers
- [x] **Customization** - set preferences through config files (with docs and examples)
    - [x] **Config foundation** - YAML config loading (`yq`), env > workspace > user > default precedence, identity knobs (`sandbox_uid`/`gid`/`username`/`home`)
    - [ ] All isolation designs should be customizable
    - [x] **Git policy** - regex-based allow/block lists (`git.policy.allow` / `git.policy.block`) that patch the default wrapper policy
    - [x] **Git config** - per-sandbox identity override (`git.identity.name`/`email`) and host config passthrough toggle (`git.host_config_passthrough`)
    - [x] **Claude version** - pin Claude Code version via `claude.version`
    - [x] **Claude config passthrough** - toggle `~/.claude` mount via `claude.config_passthrough`
    - [x] **Cleanup** - toggle cleanup container via `sandbox.cleanup`
    - [x] **Additional paths** - mount arbitrary host paths via `mounts.extra` and auto-detect git-worktree/symlink paths via `mounts.auto`
- [x] **Alternative Claude config and env** - use dedicated Claude config paths, disable config passthrough, or authenticate with `ANTHROPIC_API_KEY`
- [ ] **Network isolation** - container has its own network, isolated from the host
- [x] **More tools** - first-class Claude Code, Codex CLI, and OpenCode profiles
    - [x] **Codex version** - pin Codex CLI via `CODEX_VERSION` or `codex.version`
    - [x] **OpenCode version** - pin OpenCode via `OPENCODE_VERSION` or `opencode.version`
    - [ ] Additional built-in coding agents
- [x] **Rename** - named `ai-sandbox`, with the short alias `asb` and per-tool entrypoints `asb-claude` / `asb-codex` / `asb-opencode` (symlinks; the launcher auto-detects the tool from the invoked name. An explicit `--tool` still wins)
- [ ] **More runtimes** - support other runtimes than Docker

## Testing

Automated tests live in `tests/`. Run all tests from the repo root:

```sh
bash tests/run-all.sh
```

Each subdirectory of `tests/` contains a `test.sh` script for one component. The runner discovers and executes all of them. Tests run on the host (no Docker required) - the git wrapper tests use a stubbed real git binary.

## Further reading

- [docs/configuration.md](docs/configuration.md) - full configuration reference: schema, all knobs, git policy
- [docs/architecture.md](docs/architecture.md) - architecture, volumes, security model
- [docs/tradeoffs.md](docs/tradeoffs.md) - design decisions: privilege dropping, network isolation, and alternatives
- [docs/development.md](docs/development.md) - invariants, resolution logic, PKGBUILD notes, test checklist
