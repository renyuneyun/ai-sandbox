# Configuration

`ai-sandbox` reads optional YAML config files instead of requiring env vars for every knob. This page is the full reference. For project overview, installation, and features, see [README.md](../README.md).

## Config file locations

Two files are read, in priority order:

| File | Purpose |
|---|---|
| `$WORKSPACE_DIR/.ai-sandbox.yaml` | Per-project override |
| `${XDG_CONFIG_HOME:-~/.config}/ai-sandbox/config.yaml` | User defaults |

Both files are optional. Precedence per knob: env var > workspace config > user config > built-in default.

A commented template is installed at `<prefix>/share/ai-sandbox/config.example.yaml` (e.g. `/usr/local/share/ai-sandbox/config.example.yaml`). Copy it to get started:

```sh
mkdir -p ~/.config/ai-sandbox
cp /usr/local/share/ai-sandbox/config.example.yaml ~/.config/ai-sandbox/config.yaml
```

Edit the copy, uncommenting the lines you want to change. All fields are commented out by default, so the copied file has no effect until you edit it.

Requires `yq` on the host. Either implementation works:
- **mikefarah's Go `yq`** - `go-yq` on Arch, `brew install yq` on macOS, or [download the binary](https://github.com/mikefarah/yq/releases)
- **kislyuk's Python `yq`** - `yq` on Arch, `pip install yq`

If `yq` is not installed, config files are ignored and env vars / defaults are used instead. A warning is printed to stderr when a config file exists but `yq` is missing. Malformed YAML files are also skipped with a warning.

## Schema

All fields optional:

```yaml
tool: codex                       # claude, codex or opencode; default: claude

claude:
  version: "2.1.152"            # string,  default: host's claude version
  config_passthrough: true      # bool,    default: true
  config_dir: ~/.claude         # string,  default: ~/.claude
  config_file: ~/.claude.json   # string,  default: ~/.claude.json

codex:
  version: "1.2.3"              # string,  default: host's codex version
  config_passthrough: true      # bool,    default: true
  config_dir: ~/.codex          # string,  default: ~/.codex

opencode:
  version: "0.6.9"              # string,  default: host's opencode version
  config_passthrough: true      # bool,    default: true
  data_passthrough: true        # bool,    default: true
  config_dir: ~/.config/opencode        # string, default: ~/.config/opencode
  data_dir: ~/.local/share/opencode     # string, default: ~/.local/share/opencode

proxy:
  env_passthrough: true         # bool,    default: true

browser:
  enabled: true                 # bool,    default: false - drive a visible host browser
  mcp_url: http://127.0.0.1:8931/mcp  # string, default: http://127.0.0.1:8931/mcp

sandbox:
  uid: 1000          # integer, default: $(id -u)
  gid: 1000          # integer, default: $(id -g)
  username: ryey     # string,  default: $(id -un)
  home: /home/ryey   # string,  default: /home/$username
  cleanup: true      # bool,    default: true

git:
  identity:
    name: claude-bot     # string,  default: "" (not set - inherit)
    email: bot@example.com  # string,  default: "" (not set)
  host_config_passthrough: true  # bool, default: true
  allow_local_operations: false  # bool, default: false
  policy:
    allow:              # list of regex (ERE), default: empty
      - "^reset"
      - "^commit --amend"
    block:              # list of regex (ERE), default: empty
      - "^stash pop"
```

Example `~/.config/ai-sandbox/config.yaml`:

```yaml
sandbox:
  username: claude-bot
  home: /home/claude-bot
```

## User identity

By default the launcher mirrors your host identity into the container so that files created inside are owned by you outside:

| Variable | Default | Description |
|---|---|---|
| `SANDBOX_UID` | `$(id -u)` | UID used inside the container |
| `SANDBOX_GID` | `$(id -g)` | GID used inside the container |
| `SANDBOX_USERNAME` | `$(id -un)` | Username created inside the container |
| `SANDBOX_HOME` | `/home/$SANDBOX_USERNAME` | Home directory path inside the container |

Override any of them before invoking the script:

```sh
SANDBOX_UID=4444 SANDBOX_GID=4444 SANDBOX_USERNAME=ryey ai-sandbox
```

When `SANDBOX_UID=0`, the container runs as root and the user-creation step is skipped.

## Git identity

Two knobs control git identity inside the sandbox:

| Knob | Default | Description |
|---|---|---|
| `git.identity.name` | `""` (unset) | Overrides `user.name` via `GIT_AUTHOR_NAME` / `GIT_COMMITTER_NAME` env vars |
| `git.identity.email` | `""` (unset) | Overrides `user.email` via `GIT_AUTHOR_EMAIL` / `GIT_COMMITTER_EMAIL` env vars |
| `git.host_config_passthrough` | `true` | When `false`, host `~/.gitconfig` and `~/.config/git/` are not mounted |

Env var overrides: `SANDBOX_GIT_IDENTITY_NAME`, `SANDBOX_GIT_IDENTITY_EMAIL`, `SANDBOX_GIT_HOST_CONFIG_PASSTHROUGH`. Same precedence as identity knobs: env > workspace config > user config > default.

**How identity is applied:** when `git.identity.name` is set, the launcher passes `-e GIT_AUTHOR_NAME=...` and `-e GIT_COMMITTER_NAME=...` to `docker compose run` (same for email). Git's env-var precedence is above any config file, so the override takes effect regardless of whether host `~/.gitconfig` is mounted.

**Combinations:**

| `identity` | `host_config_passthrough` | Behavior |
|---|---|---|
| unset | `true` (default) | Host git identity inherited via `~/.gitconfig` (current behavior). |
| unset | `false` | No git identity in sandbox. `git commit` fails with "Please tell me who you are". |
| set | `true` (default) | Host config mounted, commit authorship overridden by env vars. |
| set | `false` | Clean slate: only sandbox identity applies. |

**Caveat:** `git config user.name` (the command) only reads config files - it ignores the env vars. So when passthrough is on and identity is overridden, `git config user.name` still prints the host's value. Commits are still authored correctly. `git var GIT_AUTHOR_IDENT` is the one git command that does respect the env vars.

## Tool versions

Pin a specific Claude Code version via config instead of the `CLAUDE_VERSION` env var:

```yaml
claude:
  version: "2.1.152"
```

Same precedence as other knobs: env var > workspace config > user config > host's installed version.

Codex mirrors this with `codex.version` and `CODEX_VERSION`:

```yaml
codex:
  version: "1.2.3"
```

OpenCode pins its version with `opencode.version` and `OPENCODE_VERSION`:

```yaml
opencode:
  version: "0.6.9"
```

## Claude config passthrough

By default, the host's `~/.claude` directory and `~/.claude.json` are mounted into the container so Claude Code has credentials, skills, and settings. Disable this for a more isolated environment:

```yaml
claude:
  config_passthrough: false
```

When disabled, Claude Code runs without host credentials. Set `ANTHROPIC_API_KEY` in your environment to authenticate without `~/.claude`. This is useful for running Claude with a clean slate - no host skills, no host settings, no host session history.

You can also point at custom host paths instead of the defaults:

```yaml
claude:
  config_dir: /shared/claude-config        # default: ~/.claude
  config_file: /shared/claude-config.json  # default: ~/.claude.json
```

The container-side path is always `${SANDBOX_HOME}/.claude` and `${SANDBOX_HOME}/.claude.json` (that's where Claude Code expects them); only the host-side path changes. This lets you share a dedicated Claude config across projects or use a config that differs from your host user's default.

## Codex config passthrough

Codex similarly bind-mounts the host's `~/.codex` directory read/write at `${SANDBOX_HOME}/.codex`. Disable it independently with `codex.config_passthrough: false`, or choose a custom host path with `codex.config_dir`. The matching environment overrides are `CODEX_CONFIG_PASSTHROUGH` and `CODEX_CONFIG_DIR`.

## OpenCode config and data passthrough

OpenCode splits its state across two host directories, and each is mounted (and toggleable) independently:

- `~/.config/opencode` - `opencode.json`, agent definitions, themes. Mounted read/write at `${SANDBOX_HOME}/.config/opencode`; toggle with `opencode.config_passthrough` / `OPENCODE_CONFIG_PASSTHROUGH`; custom host path via `opencode.config_dir` / `OPENCODE_CONFIG_DIR`.
- `~/.local/share/opencode` - `auth.json` credentials plus session/storage data. Mounted read/write at `${SANDBOX_HOME}/.local/share/opencode`; toggle with `opencode.data_passthrough` / `OPENCODE_DATA_PASSTHROUGH`; custom host path via `opencode.data_dir` / `OPENCODE_DATA_DIR`.

Because the data directory contains session history, mounting it means sessions started in the sandbox appear on the host (and vice versa). Disable both passthroughs for a clean slate and authenticate with `ANTHROPIC_API_KEY` or `OPENAI_API_KEY`, which opencode reads from the environment.

## Proxy environment passthrough

By default, the launcher forwards non-empty standard proxy variables from the host into the sandbox:

- `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY`, and `NO_PROXY`
- `http_proxy`, `https_proxy`, `all_proxy`, and `no_proxy`

Uppercase and lowercase names are handled independently and values are preserved unchanged. This applies to both tool profiles and to the `npx` process that starts them. For example:

```sh
HTTP_PROXY=http://127.0.0.1:7890 \
HTTPS_PROXY=http://127.0.0.1:7890 \
ai-sandbox --tool codex
```

The container uses host networking, so a proxy listening on the host at `127.0.0.1` is reachable. Host networking alone does not copy proxy settings or force clients through that proxy; the environment-variable passthrough configures proxy-aware clients to use it.

Disable passthrough in YAML when proxy URLs contain credentials or when a workspace should not inherit the host proxy:

```yaml
proxy:
  env_passthrough: false
```

The environment override is `SANDBOX_PROXY_ENV_PASSTHROUGH=false`. It follows the normal precedence: environment override > workspace config > user config > default. Proxy URLs are intentionally not accepted in YAML; keep them in the host environment.

## Browser (automation of a visible host browser)

By default the sandbox has no browser. When `browser.enabled: true`, the sandboxed agent can drive a browser that runs on the host (visible and interactive for the user) by connecting to a Playwright MCP server started by a systemd user service over host networking.

```yaml
browser:
  enabled: true                 # drive a visible host browser; default: false
  mcp_url: http://127.0.0.1:8931/mcp  # default: http://127.0.0.1:8931/mcp
```

The environment overrides are `SANDBOX_BROWSER_ENABLED` and `SANDBOX_BROWSER_MCP_URL`, following the normal precedence: environment override > workspace config > user config > default.

### Setup

The unit is installed by the package manager (into `/usr/lib/systemd/user`) or by `install.sh` (into `${XDG_DATA_HOME:-~/.local/share}/systemd/user`, already on the systemd user search path). Enabling it is the normal one-liner:

```sh
systemctl --user daemon-reload
systemctl --user enable --now ai-sandbox-playwright
```

This auto-starts it at login. It only launches the browser when an agent drives it — the browser appears on the host display (headed by default).

### What the launcher injects

When `browser.enabled` is true, the launcher:

- passes `PLAYWRIGHT_MCP_URL=$mcp_url` into the container (any agent or bit of code can use it to connect a Playwright client over CDP/HTTP);
- generates a read-only MCP config file mounted at `/etc/ai-sandbox/mcp-config.json`;
- for **Claude** (the default tool), appends `--mcp-config /etc/ai-sandbox/mcp-config.json`, registering the server as `playwright`. The agent can then call `browser_navigate`, `browser_click`, `browser_snapshot`, `browser_take_screenshot`, etc.
- for **Codex / OpenCode**, the server is reachable at any configured MCP endpoint; read `PLAYWRIGHT_MCP_URL` or register the remote server yourself (Codex reads `~/.codex/config.toml`, OpenCode reads its `mcp` config).

The endpoint is bound to `127.0.0.1` on the host. Because the container uses host networking, the agent reaches it directly at `http://127.0.0.1:8931/mcp` — same mechanism as the host proxy.

### Notes

- The service holds one browser instance; concurrent sandbox sessions share it. Use the MCP server's `--isolated` option if each session needs its own profile.
- For headless or remote (SSH/VNC) operation, edit the unit's `Environment` (e.g. uncomment `PLAYWRIGHT_MCP_HEADLESS=true` or change `DISPLAY`).
- The browser is a real resource on the host: the agent is granted full control of pages it is given, so only enable it where you trust the agent's browser activity.
- Requires `npx`/Node.js on the host (the service runs `@playwright/mcp`). The first browser launch pulls the Playwright browser into `~/.cache/ms-playwright`.
- The launcher does a lightweight reachability check when `browser.enabled` is true: if the endpoint is not up, it prints the one-liner to start the unit (`systemctl --user enable --now ai-sandbox-playwright`) to stderr so the user is never left guessing.

## Cleanup

The launcher runs a small `cleanup` container after the main container exits to remove empty stub directories Docker may have created inside the `ai-agent-home` volume. Disable it to skip that one quick container startup:

```yaml
sandbox:
  cleanup: false
```

Stubs are harmless (empty dirs); this is a minor optimization.

## Git policy config

The built-in git operation policy (see [Git policy](#git-policy) below) blocks destructive git operations. Customize it with regex-based allow/block lists that patch the default:

```yaml
git:
  policy:
    allow:
      - "^reset"           # allow all reset forms (--hard, --soft, etc.)
      - "^commit --amend"  # allow amend
    block:
      - "^stash pop"       # block stash pop (example)
```

Patterns are extended regex (ERE), matched against the git subcommand + args (global flags like `-C` are stripped first). Substring match by default; use `^` and `$` to anchor.

**Precedence** (first match wins):

1. User `allow` rules - if a pattern matches, the command runs even if the default would block it.
2. User `block` rules - if a pattern matches, the command is blocked even if the default allows it.
3. Built-in default policy (see list below).
4. Allowed (exec real git).

To inspect the effective policy inside the container:

```sh
cat /etc/ai-sandbox/git-policy.conf
```

The file is only present when `git.policy` is set. When neither `allow` nor `block` is configured, the wrapper uses the built-in default policy directly.

## Local-override mode

When `git.allow_local_operations` is `true`, the wrapper blocks only `git push` and allows all local operations unconditionally - including `reset --hard`, `commit --amend`, `branch -D`, `clean -fd`, `rebase`, `config`, and the history-bypass plumbing commands. User `policy.allow`/`block` rules are ignored entirely in this mode.

Intended for quick override from the command line when you trust the agent with local repository operations:

```sh
ai-sandbox --allow-local-git
```

Remote push protection is unchanged: the wrapper still blocks `git push`, and the system git config in the container entrypoint still blocks SSH pushes and rewrites GitHub URLs to `https://prohibited/` as defense in depth.

A warning is printed to stderr when `allow_local_operations: true` is combined with non-empty `policy.allow` or `policy.block`, since the policy rules become inert in override mode.

## Authentication

Claude Code uses `~/.claude`, `~/.claude.json`, and optionally `ANTHROPIC_API_KEY`. Codex CLI uses `~/.codex` and optionally `OPENAI_API_KEY`. OpenCode uses `~/.local/share/opencode/auth.json` (plus config in `~/.config/opencode`) and optionally `ANTHROPIC_API_KEY` / `OPENAI_API_KEY`. Existing config paths are bind-mounted read/write by default, and passthrough can be disabled independently for each profile. API keys are forwarded only when present.

## Git policy

Inside the sandbox, `git` is a wrapper script that blocks destructive operations and allows non-destructive / appending-only ones. Blocked operations print `[SECURITY] ...` to stderr and exit non-zero.

Block messages include guidance for the AI agent: the restriction is intentional and must not be bypassed. `git push` is always blocked; other destructive operations are generally prohibited. The agent is prompted to reconsider whether the underlying operation is genuinely needed and aligns with the user's intent, rather than asking the user to authorize individual operations.

**Fully blocked subcommands:** `push`, `reset`, `rebase`, `filter-branch`, `filter-repo`, `clean`, `config`, `commit-tree`, `update-ref`, `replace`, `fast-import`, `prune`, `symbolic-ref`.

**Conditionally blocked subcommands:** `reflog expire|delete`, `notes remove|prune`, `worktree remove|prune`, `stash drop|clear`, `branch -d|-D|--delete`, `tag -d|--delete|-f|--force`.

**Flag-level blocks on allowed subcommands:**

| Subcommand | Blocked flags |
|---|---|
| `commit` | `--amend`, `--reset-author` |
| `checkout` | `-B`, `-f`, `--force`, `-- <pathspec>` |
| `switch` | `-C`, `--discard-changes` |
| `restore` | `--worktree`, `-W` |
| `rm` | (without `--cached`) |
| `gc` | `--prune` |

`git config` is blocked entirely (including reads) because allowing `git config --local` writes would let Claude define an alias like `alias.x = !/usr/bin/git push` that bypasses the wrapper. Use `cat ~/.gitconfig` or `cat .git/config` to read config.

**Known limitations:**
- The wrapper is a soft barrier. Calling `/usr/bin/git` by absolute path bypasses it. This is consistent with the project's threat model (accidental damage, not adversarial resistance).
- The wrapper does not strip `-c` flags or `GIT_CONFIG_*` env vars. A command like `git -c alias.x='!/usr/bin/git push' x` would bypass the push block. This is acceptable because push is also blocked by system git config (defense in depth), and the threat model is non-adversarial.
- Long-flag abbreviations (e.g., `--forc` for `--force`) bypass flag-level checks in subcommands that use exact-match patterns (`commit`, `tag`, `branch`, `checkout`, `restore`). The `rm` and `gc` cases use prefix matching and are not affected. Claude uses full flag names in practice, so this is a low-risk gap.
