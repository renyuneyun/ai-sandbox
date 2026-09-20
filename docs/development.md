# Internals

## Key invariants

These must not be broken without updating all affected documentation:

- `share/ai-sandbox/docker-compose.yml` must stay at `share/ai-sandbox/` relative to the repo root (dev-mode detection depends on it).
- The `ai-agent` service name must not change without updating every `docker compose run` call in the script.
- `IS_SANDBOX=1` must remain set in the container environment.
- The git push-blocking entrypoint must remain.
- The `git-wrapper` bind mount (`./git-wrapper:/usr/local/bin/git:ro` in `ai-agent.volumes`) must remain. Removing it disables the git operation policy.
- `share/ai-sandbox/git-wrapper` must be executable (mode 755). `install.sh` and `packaging/PKGBUILD` must install it with mode 755.
- `/usr/local/bin` must precede `/usr/bin` in the container's `PATH` (true for `node:22-bookworm` by default). If the base image changes, verify this.
- The conditional `~/.gitconfig` and `~/.config/git/` mounts in `bin/ai-sandbox` must check existence before mounting (avoids Docker creating empty stub dirs on the host).
- The entrypoint's `git config --system` calls must use `/usr/bin/git` (not `git`). The wrapper at `/usr/local/bin/git` blocks `config`, which would break the `&&` chain and skip `runuser`, leaving Claude Code running as root.
- The workspace bind, per-UID home named volume, and selected-tool config bind must remain.
- `WORKSPACE_DIR` must be exported before `docker compose up` — the compose file interpolates it.
- `SANDBOX_UID`, `SANDBOX_GID`, `SANDBOX_USERNAME`, and `SANDBOX_HOME` must be exported before `docker compose up` — the compose file interpolates them for volume paths and the user-creation entrypoint.
- `SANDBOX_GIT_IDENTITY_NAME`, `SANDBOX_GIT_IDENTITY_EMAIL`, and `SANDBOX_GIT_HOST_CONFIG_PASSTHROUGH` are launcher-side only — they are NOT exported and NOT interpolated by the compose file. The launcher reads them to build `-e` and `-v` flags for `docker compose run`. Do not add them to the "must be exported" list above.
- `SANDBOX_TOOL`, all `CLAUDE_*`, all `CODEX_*`, and all `OPENCODE_*` profile knobs, `SANDBOX_PROXY_ENV_PASSTHROUGH`, `SANDBOX_CLEANUP`, `SANDBOX_GIT_POLICY_ALLOW`, `SANDBOX_GIT_POLICY_BLOCK`, `SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS`, `SANDBOX_BROWSER_ENABLED`, `SANDBOX_BROWSER_MCP_URL`, `SANDBOX_EXTRA_MOUNTS`, `SANDBOX_EXTRA_MOUNTS_ENABLED`, `SANDBOX_AUTO_GIT_WORKTREE`, `SANDBOX_AUTO_SYMLINKS`, and `SANDBOX_PROGRESS` are launcher-side only — they are NOT exported and NOT interpolated by the compose file. The launcher reads them to choose/configure a profile and build `-e` and `-v` flags for `docker compose run`. `GIT_MODE_ENV_ARGS` follows the same conditional-fill pattern as `GIT_ENV_ARGS` and `PROXY_ENV_ARGS` (only populated when the knob is `true`).
- Selected-profile config mounts are in the launcher (`TOOL_VOLUME_ARGS`), not in `docker-compose.yml`. `TOOL_VOLUME_ARGS` replaces the former `CLAUDE_VOLUME_ARGS`; the compose file must not mount tool config paths.
- Tool API keys are forwarded dynamically through `TOOL_ENV_ARGS` only when present. Do not add `ANTHROPIC_API_KEY` or `OPENAI_API_KEY` as static Compose environment entries.
- Proxy variables are forwarded through generic `PROXY_ENV_ARGS`, not through a tool profile or static Compose entries. When enabled, collect only non-empty `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY`, `NO_PROXY` and lowercase equivalents; preserve each name and value exactly. `configure_proxy_env` must remain outside the main guard for source-level tests.
- `GIT_VOLUME_ARGS` remains the conditional read-only host git-config mounts. `GIT_POLICY_VOLUME_ARGS` remains the optional one-invocation generated policy bind.
- The `GIT_POLICY_FILE` path (`/etc/ai-sandbox/git-policy.conf`) is the contract between the launcher and the wrapper. Changing it requires updating both.
- The browser MCP config path (`/etc/ai-sandbox/mcp-config.json`) is the contract between the launcher and the Claude `--mcp-config`; it is generated only when `SANDBOX_BROWSER_ENABLED=true`. Changing it requires updating the launcher and this doc.
- `resolve_list`, `parse_launcher_args`, `resolve_tool`, `detect_host_version`, `configure_tool`, `configure_proxy_env`, `configure_extra_mounts`, `configure_auto_mounts`, `expand_home`, `canonicalize`, `_auto_add_mount`, `detect_git_worktree_mount`, `detect_symlink_mounts`, `_init_symlink_roots`, `progress_start`, `progress_stop`, and `warn_msg` must remain defined outside the main guard (for testability), same as `check_config` and `resolve`.
- The generated-file cleanup trap (`trap 'progress_stop; if [[ -n "$POLICY_FILE" ]]; then rm -f -- "$POLICY_FILE"; fi; if [[ -n "$MCP_CONFIG_FILE" ]]; then rm -f -- "$MCP_CONFIG_FILE"; fi' EXIT`, installed unconditionally) must remain. The `progress_stop` call restores the terminal (clears the progress line, shows the cursor) on any exit path; the `if`-guarded `rm` calls keep the trap from changing the script's exit status. Without the `rm`s, temp git-policy and MCP-config files leak in `/tmp`.
- Startup progress semantics: `progress_start`/`progress_stop`/`warn_msg` implement a single self-erasing stderr line (spinner on a TTY, static lines otherwise), disabled by `SANDBOX_PROGRESS=false` / `progress.enabled: false`. When progress is disabled the launcher must keep the legacy behavior exactly: no progress output AND no warm-up container run. Mid-prepare warnings and launcher errors must go through `warn_msg` / `launcher_error` (which suspend the spinner) so they cannot garble an active line. The warm-up is best-effort except for SIGINT: docker reporting 130 during the warm-up must abort the launcher instead of falling through to the interactive session.
- `WORKSPACE_DIR` must be resolved to an absolute path before `WORKSPACE_CONFIG` is derived from it (the workspace config path is `$WORKSPACE_DIR/.ai-sandbox.yaml`).
- Config file functions (`check_config`, `resolve`) must remain defined outside the main execution guard so tests can source the launcher and call them directly.
- All `docker compose` invocations must pass `-p "$COMPOSE_PROJECT"` (set to `ai-sandbox-${SANDBOX_UID}`) — this namespaces containers and volumes per user, preventing conflicts on multi-user machines.
- The names `ai-agent-home`, `ai-sandbox-${SANDBOX_UID}`, and `ai-agent`, plus all installed `ai-sandbox` paths, are stable contracts and must remain unchanged.
- The compose file resolution order must not be reordered without updating the section below.

## Keeping docs in sync

Any change to behavior, the CLI, volumes, config/env knobs, or the install layout must keep the human-facing docs accurate — **committed in the same change**, not left for the user to verify afterwards. Run this checklist before finishing.

- [ ] `README.md` — Features checklist, Usage/CLI examples, and any summary of behavior or vision.
- [ ] `share/ai-sandbox/config.example.yaml` — every new config key and env var (in the `#` comments) with its default and a one-line purpose.
- [ ] `docs/configuration.md` — the Schema block plus a per-knob section for every new knob/env var (default, precedence, semantics).
- [ ] `docs/architecture.md` — Volume-layout table, Container-environment table, and lifecycle/security-model sections that touch mounts, volumes, env, or network.
- [ ] `docs/development.md` — Key invariants (launcher-side-only knobs, functions that must stay outside the main guard), the config-resolution defaults, and the Manual testing checklist (add/refresh numbered items).
- [ ] `install.sh` + `packaging/PKGBUILD` — add any new installed file (launcher, data file, systemd unit) to both.

**Drift audit** — do this even when you did not author the change:

- Extract every `resolve`/`resolve_list` knob from `bin/ai-sandbox` and diff the set against `docs/` + `config.example.yaml`. Every knob must appear somewhere.
- Grep for new env vars, CLI flags, or mount-behavior changes and confirm each is documented.
- If an older commit shipped a feature without its doc update, fold that doc fix into this change rather than leaving it.
- `docs/superpowers/specs/` and `docs/superpowers/plans/` are historical planning artifacts (they may reference old names like `bin/claude-sandboxed`, `CLAUDE_VOLUME_ARGS`) and are intentionally **not** kept in sync — do not "fix" them as part of the audit.

## Config resolution

Identity, git, proxy, cleanup, policy, browser, mounts, and tool-profile knobs (`SANDBOX_TOOL`, all `CLAUDE_*`, all `CODEX_*`, and all `OPENCODE_*`) are resolved per-knob from four sources in priority order:

1. **Env var** (`SANDBOX_UID`, etc.) - if set and non-empty.
2. **Workspace config** (`$WORKSPACE_DIR/.ai-sandbox.yaml`) - if the key is present and non-null.
3. **User config** (`${XDG_CONFIG_HOME:-$HOME/.config}/ai-sandbox/config.yaml`) - if the key is present and non-null.
4. **Default** - identity knobs: `$(id -u)`, `$(id -g)`, `$(id -un)`, `/home/$SANDBOX_USERNAME`. Git identity knobs: `""`, `""`. `SANDBOX_GIT_HOST_CONFIG_PASSTHROUGH`: `true`. `SANDBOX_TOOL`: `claude`. Each tool version uses its host CLI version, or npm's latest if absent. All config/data passthrough toggles: `true`. Claude paths: `$HOME/.claude` and `$HOME/.claude.json`; Codex path: `$HOME/.codex`; OpenCode paths: `$HOME/.config/opencode` and `$HOME/.local/share/opencode`. `SANDBOX_PROXY_ENV_PASSTHROUGH`: `true`. `SANDBOX_CLEANUP`: `true`. `SANDBOX_GIT_POLICY_ALLOW` / `SANDBOX_GIT_POLICY_BLOCK`: empty. `SANDBOX_BROWSER_ENABLED`: `false`. `SANDBOX_BROWSER_MCP_URL`: `http://127.0.0.1:8931/mcp`. `SANDBOX_EXTRA_MOUNTS`: empty. `SANDBOX_EXTRA_MOUNTS_ENABLED`: `true`. `SANDBOX_AUTO_GIT_WORKTREE`: `true`. `SANDBOX_AUTO_SYMLINKS`: `true`. `SANDBOX_PROGRESS`: `true`.

Two bash functions in `bin/ai-sandbox` implement this:

- `check_config FILE` - returns 0 if the file exists, `yq` is on `PATH`, and the YAML parses; returns 1 (with a stderr warning) otherwise. Missing files return 1 silently.
- `resolve ENV_NAME YQ_PATH DEFAULT` - checks the env var, then the validated workspace config, then the validated user config, then the default. Consults `WORKSPACE_CONFIG_VALID` / `USER_CONFIG_VALID` flags set by up-front `check_config` calls.
- `resolve_list ENV_NAME YQ_PATH` - like `resolve` but for YAML arrays. Returns newline-joined values. Used for `git.policy.allow`, `git.policy.block`, and `mounts.extra`. No default parameter (empty if nothing set).

`yq` is a host-only dependency. Either mikefarah's Go `yq` or kislyuk's Python `yq` works - the spec uses only `yq '.' file` (validation) and `yq -r '.path' file` (key lookup), which are common-denominator operations.

## Compose file location resolution

Priority order (first match wins), implemented in `bin/ai-sandbox`:

1. `$AI_SANDBOX_DIR` — explicit override
2. `<script-dir>/../share/` — dev/repo checkout (`bin/` → `share/`)
3. `<script-prefix>/share/ai-sandbox` — installed package

## PKGBUILD notes

- `arch=('any')` — no compiled code, pure shell + config.
- PKGBUILD lives in `packaging/`; run `cd packaging && makepkg -si` to build.
- `source=()` is empty — no fetching step. `_repodir="$(realpath ..)"` is evaluated at parse time (CWD is `packaging/`) and captures the repo root; `package()` installs from there directly.
- Adding new files to `bin/` or `share/` requires updating both `package()` and `install.sh`.
- Fill in `url=` before publishing to AUR; switch to `source=("git+https://...")` with `sha256sums=('SKIP')` and a proper `pkgver()` function at that point.

## Manual testing checklist

1. **Dev mode:** run `./bin/ai-sandbox` from the repo root — should pick up `share/ai-sandbox/docker-compose.yml`.
2. **Installed mode:** run `cd packaging && makepkg -si`, then run `ai-sandbox` from an unrelated directory — should pick up `/usr/share/ai-sandbox/docker-compose.yml`.
3. **Override mode:** `AI_SANDBOX_DIR=/some/path ai-sandbox` — should use that path regardless.
4. **Push protection:** inside the container, `git push` should fail with the security message.
5. **Git wrapper:** inside the container, `which git` shows `/usr/local/bin/git`.
6. **Git policy - blocked:** inside the container, `git push`, `git reset --hard`, `git commit --amend`, `git clean -fd`, `git rebase`, `git config --get user.name`, `git commit-tree`, `git update-ref` all fail with `[SECURITY]` messages.
7. **Git policy - allowed:** inside the container, `git status`, `git log`, `git add`, `git commit -m test` (in a repo), `git switch`, `git fetch` all work.
8. **Git config inheritance:** with `~/.gitconfig` on the host, commits inside the container use the host user's identity. Without `~/.gitconfig`, the container starts and git uses defaults.
9. **Automated tests:** run `bash tests/run-all.sh` from the repo root — all test suites pass.
10. **Git identity override:** with `git.identity.name`/`email` set in workspace config, `git commit` inside the container uses the overridden identity. Verify: `git log -1 --format='%an <%ae>'` shows the configured name/email, not host's.
11. **Host passthrough off:** with `git.host_config_passthrough: false`, `/usr/bin/git config user.name` inside the container returns nothing (or git's compiled default), not host's value. `cat ~/.gitconfig` fails (file doesn't exist). Note: `git config` (without `/usr/bin/`) is blocked by the wrapper — use `/usr/bin/git` to introspect.
12. **Identity + passthrough off:** both `git.identity` set and `host_config_passthrough: false`. `git commit` inside the container uses the sandbox identity. `git log -1 --format='%an <%ae>'` shows the configured name/email.
13. **Identity + passthrough on (default):** `git.identity` set, `host_config_passthrough` unset (default true). `git commit` uses the env-var identity. `git config user.name` (via `/usr/bin/git`) still reports host's value (env vars don't affect `git config --get`).
14. **Claude version:** with `claude.version: "2.1.152"` in workspace config, the container runs that version (verify with `claude --version` inside).
15. **Claude config passthrough off:** with `claude.config_passthrough: false`, `~/.claude` is not mounted. `ls ~/.claude` inside the container shows nothing (or the volume's empty dir). Claude starts with `ANTHROPIC_API_KEY` set.
16. **Claude config custom paths:** with `claude.config_dir: /shared/claude` and `claude.config_file: /shared/claude.json`, the container mounts those host paths at `${SANDBOX_HOME}/.claude` and `${SANDBOX_HOME}/.claude.json`. Verify: `ls ~/.claude` inside shows the custom dir's contents, not the host default.
17. **Cleanup off:** with `sandbox.cleanup: false`, no `cleanup` container runs after exit. Stub dirs may remain in the volume (harmless).
18. **Git policy allow:** with `git.policy.allow: ["^reset"]`, `git reset --hard HEAD~1` works inside the container.
19. **Git policy block:** with `git.policy.block: ["^stash pop"]`, `git stash pop` is blocked with a "[SECURITY]" message.
20. **Git policy file:** `cat /etc/ai-sandbox/git-policy.conf` inside the container shows the effective policy.
21. **Git policy doesn't affect unmatched commands:** with `git.policy.allow: ["^reset"]`, `git push` is still blocked.
22. **Git local-override:** with `--allow-local-git`, inside the container `git push` is blocked but `git reset --hard`, `git commit --amend`, `git config user.name X`, `git clean -fd`, `git rebase` all work.
23. **Git local-override config:** with `git.allow_local_operations: true` in workspace config, the same behavior as `--allow-local-git` applies.
24. **Git local-override warning:** with `--allow-local-git` and `git.policy.block: ["^stash pop"]` both set, the launcher prints a warning to stderr about policy rules being ignored.
25. **Git local-override policy ignored:** with `--allow-local-git` and a policy file that blocks `git status`, `git status` still works inside the container.
26. **Default Claude:** `ai-sandbox` launches Claude with its autonomy flag.
27. **Codex host login:** `ai-sandbox --tool codex` uses host `~/.codex` and the Codex autonomy flag.
28. **Codex API-key isolation:** with passthrough disabled and `OPENAI_API_KEY` set, Codex starts without mounting host config.
29. **Pinned versions:** verify both Claude and Codex YAML/env version knobs select the requested releases.
30. **Exact passthrough:** arguments after `--`, including spaces and option-looking values, arrive unchanged.
31. **Unsupported tool:** an unsupported `--tool` exits non-zero and lists Claude, Codex, and OpenCode.
32. **Concurrent profiles:** Claude and Codex containers are independent, their config binds differ, and they share only the documented per-UID `ai-agent-home` named volume.
33. **Proxy passthrough:** set uppercase and lowercase proxy variables to distinct sentinel values; verify all non-empty values are visible inside both Claude and Codex containers and available to `npx`.
34. **Proxy passthrough off:** set `proxy.env_passthrough: false` (and no environment override); verify none of the eight supported proxy variables is present inside the container.
35. **OpenCode host login:** `ai-sandbox --tool opencode` uses host `~/.config/opencode` and `~/.local/share/opencode` (auth + sessions) and the `--auto` autonomy flag.
36. **OpenCode API-key isolation:** with both passthroughs disabled and `OPENAI_API_KEY` (or `ANTHROPIC_API_KEY`) set, OpenCode starts without mounting host config or data.
37. **OpenCode custom paths:** with `opencode.config_dir` / `opencode.data_dir` pointing at custom host paths, the container mounts them at `${SANDBOX_HOME}/.config/opencode` / `${SANDBOX_HOME}/.local/share/opencode`.
38. **Browser disabled (default):** with no browser config, the container has no `PLAYWRIGHT_MCP_URL` env, no `/etc/ai-sandbox/mcp-config.json` mount, and Claude gets no `--mcp-config` arg.
39. **Browser enabled (Claude):** with `browser.enabled: true`, `PLAYWRIGHT_MCP_URL` is passed, the mcp-config is mounted read-only, and Claude's Docker args include `--mcp-config /etc/ai-sandbox/mcp-config.json`.
40. **Browser enabled (Codex/OpenCode):** with `browser.enabled: true` and `--tool codex`, `PLAYWRIGHT_MCP_URL` is still passed but no `--mcp-config` arg is added.
41. **Browser URL override:** with `browser.mcp_url` (or `SANDBOX_BROWSER_MCP_URL`) set, the injected `PLAYWRIGHT_MCP_URL` and the mcp-config `url` both use that value; the default is `http://127.0.0.1:8931/mcp`.
42. **Browser unstarted hint:** with `browser.enabled: true` and a non-reachable endpoint, the launcher prints the `systemctl --user enable --now ai-sandbox-playwright` hint to stderr. With a reachable endpoint (or browser disabled) it does not.
43. **Extra mount host-only:** with `mounts.extra: ["~/.some-dir"]` pointing at an existing host dir, the dir appears read-only at the same path inside the container (host `/home/<user>/.some-dir` → container `${SANDBOX_HOME}/.some-dir:ro`). Verify with `ls` and attempt a write (should fail).
44. **Extra mount explicit path and rw:** with `mounts.extra: ["/tmp/x:/opt/x:rw"]`, the container sees `/opt/x` read-write (write succeeds in the sandbox and is visible on the host).
45. **Extra mount disabled:** with `mounts.extra` set and `mounts.enabled: false`, no extra `-v` args reach `docker compose run`.
46. **Git worktree auto-mount:** in a linked worktree (`.git` file with `gitdir: <path>`), both the COMMON git dir (`<repo>/.git`, objects/refs) and the worktree git-dir (`<repo>/.git/worktrees/<name>`, HEAD/index) are mounted read-write at the same paths. Verify: `git status`/`git log` work and `git checkout`/`git commit` succeed inside the sandbox. In a normal checkout (`.git` is a dir) nothing extra is mounted.
47. **Submodule auto-mount:** from inside a submodule, its module git-dir (target of the `.git` file, `<repo>/.git/modules/<name>`) is itself the common dir and is mounted rw (a single mount) so git works without the superproject being reachable.
48. **Symlink auto-mount:** with a skill symlink in `~/.claude/skills` pointing elsewhere, the target is mounted read-only at its real path and `ls -L ~/.claude/skills/<name>` resolves. Symlinks staying inside `~/.claude` are not duplicated.
49. **Auto disabled:** with `mounts.auto.git_worktree: false` (or `mounts.enabled: false`), linked-worktree/submodule git dirs are not auto-mounted.
50. **Browser display detection (Wayland):** with the `ai-sandbox-playwright` unit running on a Wayland session, its startup log reports `using Wayland display: <wl>` and the generated config includes `--ozone-platform=wayland`. On an X11-only or headless box (no `WAYLAND_DISPLAY`/`wayland-0` socket) it reports `using X11 display` and passes no ozone arg.
51. **Browser bundled-chromium fallback:** with the unit running where no system chromium/firefox validates against the installed Playwright, its startup log reports `using Playwright's own chromium` and auto-installs it on first need (no crash on the first agent `browser_*` call). With a valid system browser it logs `using system chromium/firefox` and makes no install.
52. **Startup progress:** launching on a terminal shows a single self-erasing spinner line with elapsed seconds over the prepare phase (`Preparing sandbox...`, then `Fetching tool package (first launch may download it)...`), then the tool launches; on first launch the package download happens during the warm-up phase (visible spinner), not silently inside the tool. Warnings (e.g. the browser systemd hint with `browser.enabled: true` and a down endpoint) print on their own lines without garbling the spinner, which resumes after. Ctrl-C during the warm-up aborts the launch instead of starting the interactive session. With `SANDBOX_PROGRESS=false` (or `progress.enabled: false`), there is no progress output and no warm-up container (legacy behavior). Piping stderr to a file shows one static `ai-sandbox: ...` line per phase and no ANSI escapes.

## Automated tests

Automated tests live in `tests/`. Each subdirectory contains a `test.sh` script for one component. The runner (`tests/run-all.sh`) discovers and executes all `tests/*/test.sh` scripts.

Run all tests from the repo root:

```sh
bash tests/run-all.sh
```

Current test suites:

- `tests/git-wrapper/test.sh` — unit tests for the git wrapper script (policy enforcement, argument parsing). Uses a stubbed real git binary so tests run on the host without Docker.
- `tests/config/test.sh` — unit tests for config resolution (`check_config`, `resolve`). Sources the launcher directly. Requires `yq` on `PATH`; skipped if `yq` is not installed.
- `tests/launcher/test.sh` — unit tests for launcher argument parsing, tool selection, version detection, proxy environment collection, final Docker command assembly, Claude/Codex/OpenCode profile configuration, and startup progress (spinner degradation without a TTY, warning suspension, cache warm-up run assembly, and failure tolerance).

To add a new test suite, create `tests/<component>/test.sh` and make it executable. The runner picks it up automatically. A test script should print `PASS:` / `FAIL:` lines and exit non-zero on any failure.

All automated tests must pass before release.
