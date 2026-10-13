# More Runtimes: Host-Integrated Namespace Backend

**Date:** 2026-10-10
**Status:** Approved; phases 0–1 implemented. Phase 2 (`serve`/`openchamber`) is specified in `2026-10-13-bwrap-serve-design.md`.
**Scope:** Introduce a runtime-agnostic backend seam in the launcher and add a second backend on Linux, built directly on bubblewrap (`bwrap`), that runs the selected coding agent from the host's own toolchain inside an unprivileged namespace sandbox with a layered, workspace-bounded filesystem. Docker stays the default backend. macOS (Seatbelt) and network isolation are later phases. Extending the backend to the detached OpenCode server (`serve`) and `openchamber` is specified separately in `2026-10-13-bwrap-serve-design.md`.

## Goal

The Docker backend is a clean, reproducible boundary, but it is "too strong" in a way that hurts day-to-day use: it re-acquires an entire toolchain inside an OCI image, so the selected agent and its dependencies are downloaded again instead of reusing the ones already installed on the host. This design adds a lighter backend that:

1. Runs the selected agent from the **host's** installed toolchain (no re-download, no persistent image volume).
2. Confines writes to the **workspace** and to a **persistent per-workspace home layer**, never the real `$HOME`.
3. Needs **no daemon, no root, and no setuid binary**.
4. Reuses the existing launcher concerns unchanged: tool profiles, config/env passthrough, git policy, extra/auto mounts, browser MCP, and `IS_SANDBOX=1`.

Docker remains the default; the new backend is opt-in. The seam is designed so a third backend (macOS Seatbelt, or a `podman` alias) can be added later without touching the launcher's resolution logic.

The primary driver is **lightweight, daemonless/rootless, host-integrated execution on Linux**, chosen by the user after a bake-off of the lightweight frameworks. This spec records that choice.

## Background and decision record

The framework bake-off (Linux-first, lightweight, avoid heavy options):

| Framework | Verdict |
|---|---|
| **bubblewrap (`bwrap`)** | **Chosen.** Unprivileged user namespaces; no daemon, no root, no setuid by default; drops all capabilities; finest per-path filesystem control (`--bind`/`--ro-bind`/`--tmpfs`/overlay); ~8k lines of C; used by Flatpak and by both Claude Code's and Codex's Linux sandboxes; a system-package dependency only. |
| nsjail, minijail | Rejected: coarser filesystem control, larger configuration surface, embedded/Google-internal focus. |
| firejail | Rejected: setuid-root by default, larger attack surface, history of CVEs, path `:` limitations. |
| systemd-nspawn | Rejected: rootfs/admin oriented, not for unprivileged per-command use. |
| Landlock / seccomp | Complementary, not substitutes; require a compiled helper, which conflicts with the current pure-shell, `arch=('any')` packaging. Deferred as later hardening. |
| Podman / Docker | Rejected for this driver: still image-based, still re-downloads the toolchain. |
| gVisor / Kata / Firecracker | Rejected: multi-tenant-grade isolation, VM/daemon overhead, image/guest based. |
| `portable` / `bawn` | Noted, not adopted: strong layered-filesystem and LSM stacking, but desktop-application oriented and requires kernel ≥ 7.0, systemd ≥ 258, and Landlock ABI 8 — too heavy and too new a base for this launcher. Its layered-home idea is reproduced here. |
| `@anthropic-ai/sandbox-runtime` (`srt`) | Considered as a cross-platform delegation; deferred. It would trade control and a pure-shell package for a beta Node dependency. It remains the leading candidate for the macOS phase if hand-written Seatbelt profiles prove costly. |

The threat model is unchanged from `docs/tradeoffs.md`: **accidental damage by the agent, not adversarial escape.** The bwrap backend's filesystem boundary is kernel-enforced and therefore additionally hardens the write dimension beyond the current soft git wrapper.

## Non-goals

- Replacing Docker as the default runtime, or removing the Docker backend.
- Supporting arbitrary user-defined runtimes or commands.
- Network isolation in the first phase (the container shares the host network today; bwrap does the same).
- The cleanup container, the per-UID `ai-agent-home` volume, and root-user mode under the bwrap backend. These stay Docker-only. (`serve`/`openchamber` were also deferred here and are now specified in `2026-10-13-bwrap-serve-design.md`.)
- macOS and Windows in the first phase. macOS Seatbelt is a designed follow-on on the same seam.
- seccomp/Landlock hardening and `--unshare-net` in the first phase.
- Changing the Docker image, compose file, or any existing Docker behavior.

## Decisions (confirmed during brainstorming)

- **Framework:** build directly on `bwrap`; assemble the policy in the launcher (pure shell, no compiled helper).
- **Default runtime:** `docker`. `bwrap` is opt-in via CLI/env/config.
- **`$HOME` model:** a **persistent per-workspace home layer**, plus a **toolchain passthrough allowlist**. The real home is not bound read-write. Whether the whole real home is *readable* is a separate, easily toggled option (`--read-home` / `bwrap.read_home`, default off).
- **Phase 1 scope:** Linux interactive runs only. `serve`/`openchamber` follow in phase 2 (see `2026-10-13-bwrap-serve-design.md`).
- **Network:** shared with the host in phase 1.

## Configuration

A new top-level runtime selector and a `bwrap` section. All fields optional.

```yaml
runtime: docker            # docker | bwrap

bwrap:
  # Extra host paths to make visible in the sandbox, read-only by default.
  # Entries are HOST or HOST:rw. Entries are ADDED to the built-in system and
  # per-user toolchain allowlist (there is no replace mode in phase 1).
  passthrough: []
  # Extra host paths to shadow with an empty/dir-masked view (secrets,
  # credentials). Entries are ADDED to the built-in secret list.
  deny: []
  # Whether the ENTIRE real home is readable inside the sandbox. false
  # (default) shows host home content only through the toolchain allowlist and
  # the tool-config / passthrough mounts. true makes the real home the
  # read-only lower layer of the writable per-workspace layer, so the agent can
  # read anything in the home (minus `deny`) while writes still never touch it.
  # Toggle from the command line with --read-home.
  read_home: false
```

Per-knob precedence is the existing scalar/list pattern: env var > workspace config > user config > default.

| Environment variable | YAML key | Default |
|---|---|---|
| `SANDBOX_RUNTIME` | `runtime` | `docker` |
| `SANDBOX_BWRAP_PASSTHROUGH` (newline-joined) | `bwrap.passthrough` | empty (built-in allowlist always applies) |
| `SANDBOX_BWRAP_DENY` (newline-joined) | `bwrap.deny` | empty (built-in secret list always applies) |
| `SANDBOX_BWRAP_READ_HOME` | `bwrap.read_home` | `false` |

An unknown `runtime` value fails before any sandbox starts and lists `docker` and `bwrap`.

## User interface

```
ai-sandbox --runtime bwrap [--read-home] [OPTIONS] [WORKSPACE] [-- TOOL_ARGS...]
```

Both `--runtime` and `--read-home` are launcher options handled by `parse_launcher_args`.

`--runtime` takes a value (with the existing `--opt=value` single-token form). Precedence:

1. CLI `--runtime NAME`
2. `SANDBOX_RUNTIME`
3. Workspace config `runtime`
4. User config `runtime`
5. Default `docker`

`--read-home` is a presence flag (like `--allow-local-git`) that turns on `bwrap.read_home` — the easy command-line control over whether the whole home is readable. Omit it to keep the default (off), or set `SANDBOX_BWRAP_READ_HOME=false` to override a config that enables it. It is a bwrap-only option: with the Docker backend it is ignored with a warning.

```sh
ai-sandbox --runtime bwrap              # real home hidden (default)
ai-sandbox --runtime bwrap --read-home  # whole home readable, writes still isolated
```

In phase 1 `--runtime` was **not** valid for `serve` (Docker-only, rejected with a clear message). Phase 2 lifts this: `serve`/`openchamber` accept `--runtime bwrap` — see `2026-10-13-bwrap-serve-design.md`.

## Architecture

### Backend seam and the existing specification arrays

The launcher already builds structured, backend-adaptable arrays: each `*_VOLUME_ARGS` is a sequence of `-v` plus a `HOST:CONT:FLAGS` spec, and each `*_ENV_ARGS` is a sequence of `-e` plus a `NAME=VALUE` spec. Rather than re-derive them (which would rewrite every builder and its tests for no functional gain), the seam treats these arrays as the mount/env specification and adds a renderer per backend:

- The `docker` renderer passes the arrays to `docker compose run`/`docker exec` exactly as today. The existing launcher tests, which assert on the captured Docker command, are the regression lock.
- The `bwrap` renderer walks the same arrays and translates each `-v HOST:CONT:FLAGS` into `--ro-bind HOST CONT` (`ro`) or `--bind HOST CONT` (`rw`), and each `-e NAME=VALUE` into `--setenv NAME VALUE`.
- Backend-specific mounts (the system allowlist, the home layer, `--proc`/`--dev`/`--tmpfs /tmp`, the git-wrapper rebind, the generated system gitconfig) and namespace flags are added by the bwrap prepare step, not by the shared builders.

This keeps the Docker path untouched, makes the bwrap translation a small independently testable unit, and lets a future backend (e.g. Seatbelt) render the same arrays. The seam's stable internal contract is therefore: the `-v`/`-e` array families are the specification, and each backend provides `prepare`, `render`, `available`, and `serve` hooks (Docker-only in phase 1, both backends from phase 2 — see `2026-10-13-bwrap-serve-design.md`).

### Backend hooks

Each backend provides:

- `runtime_prepare` — resolve backend settings, run detection, populate backend-specific mounts (e.g. the home layer, the git wrapper binding, `--proc`/`--dev`).
- `runtime_available` — return non-zero with an actionable message when the backend cannot run (missing `bwrap`, or unprivileged user namespaces disabled).
- `runtime_warmup` — a best-effort pre-launch step. For Docker this stays the `npx --version` fetch; for bwrap it is a `--version` sanity check of the host tool (or a no-op).
- `runtime_run` — foreground interactive execution.
- `runtime_serve_{start,attach,stop}` — Docker in phase 1; the bwrap implementations are added by `2026-10-13-bwrap-serve-design.md`.
- `runtime_cleanup` — Docker's stub-dir cleanup; a no-op for bwrap.

All new functions are defined **outside** the main guard, consistent with the existing testability invariant.

### bwrap backend

#### Process and identity

- Runs as the **invoking host user**; bwrap keeps the caller's UID/GID by default, so no user/group creation, no `runuser`, and no `SANDBOX_UID=0` root mode. File ownership on the workspace bind is consistent with the host.
- Namespaces: `--unshare-all` plus `--share-net` (phase 1). User namespace is bwrap's normal unprivileged path.
- Runs the host-installed selected tool directly (the launcher already detects host versions), instead of `npx`. The `TOOL_PACKAGE`/`npx` model is Docker-specific; bwrap uses a backend-neutral command resolved from the host `PATH`.

#### Filesystem model

The view is assembled as an ordered bind list; **later binds win**, and per-user paths are therefore applied after the home layer so they land inside it:

1. **System toolchain (read-only).** System directories (`/usr`, `/bin`, `/sbin`, `/lib*` when present, `/etc`, `/opt`, `/run`, `/nix` when present). This is what makes the host toolchain — node, npm, and the agent binary — available without re-download.
2. **Home layer (read-write, persistent per workspace).** `$HOME` is bound to a per-workspace directory under the XDG state directory (`$XDG_STATE_HOME/ai-sandbox/runtime/bwrap/<workspace-hash>/home`). Writes persist across runs and never touch the real `$HOME`. If `read_home` is true, the real home is additionally the read-only lower layer of an overlayfs whose upper is the same layer directory, so reads fall through to the real home while writes still land in the layer.
3. **Per-user toolchain (read-only).** Common per-user toolchain directories (`~/.nvm`, `~/.volta`, `~/.asdf`, `~/.fnm`, `~/.bun`, `~/.cargo`, `~/.rustup`, `~/.local`, `~/.deno`, and similar), bound **after** the home layer so they are visible inside it. `runtime.bwrap.passthrough` adds entries to this list; an entry may end in `:rw`.
4. **Tool config passthrough (read-write).** The existing `claude.*`/`codex.*`/`opencode.*` config directories are bound read-write from the host, exactly as the Docker profiles do today, so credentials and session state persist. In the default mode (`read_home: false`) these are the agent's view of `~/.claude`, `~/.codex`, `~/.config/opencode`, and `~/.local/share/opencode`.
5. **Workspace (read-write).** `--bind $WORKSPACE_DIR $WORKSPACE_DIR` — the primary writable tree.
6. **Writable caches.** Selected cache directories may be passed through `:rw` (e.g. `~/.npm`, `~/.cache`) so the agent reuses and updates host caches, matching the "use the host's tools" goal.
7. **Extra and auto mounts.** `mounts.extra` and the auto-detected worktree/symlink mounts map to `--ro-bind`/`--bind`. Because the bwrap root is the host root rather than an empty image, read-only entries are often already visible; the practical effect of an extra mount under bwrap is making a path writable or re-exposing a masked path. This semantic difference is documented.
8. **Runtime directories.** `--proc /proc`, `--dev /dev`, `--tmpfs /tmp`, and a `--tmpfs` for `/run/user` as needed.

**Secrets.** A built-in deny list (`~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.config/gh`, `~/.netrc`, `~/.docker`, browser profiles, and similar) is shadowed with an empty view. `runtime.bwrap.deny` adds to it. In the default mode (`read_home: false`) the real home is not exposed at all except through the passthrough allowlist, so the deny list is defense-in-depth; with `--read-home` it becomes the primary guard against reading credentials.

#### Git policy

- The existing `share/ai-sandbox/git-wrapper` is bind-mounted read-only into the namespace as `git`, with `PATH` set so it precedes the host git. This preserves the current policy behavior and all presets.
- The entrypoint's `git config --system` push block is replaced by a generated read-only config bound over the sandbox's system git config path (or `GIT_CONFIG_SYSTEM`), since there is no root entrypoint.
- Git identity (`git.identity.*`) and host git-config passthrough (`git.host_config_passthrough`) map to `--setenv` and read visibility. `~/.gitconfig` is read-only passthrough as today.
- Documented limitation: calling the real git by absolute path remains a soft-barrier bypass, exactly as with Docker. The namespace binding does not change the threat model.

#### Network and browser

- Network is shared with the host in phase 1 (`--share-net`), matching today's `network_mode: host`. `--unshare-net` plus an on-host proxy is a later phase.
- The optional on-host browser MCP server remains reachable at `localhost`; the generated `--mcp-config` is bound read-only and `PLAYWRIGHT_MCP_URL` is set, so Claude's browser wiring is unchanged.

### Docker backend

Unchanged in behavior. The refactor only routes it through the seam; the rendered command is identical to today's. The Docker warm-up, `serve`, cleanup container, root mode, and `ai-agent-home` volume remain as they are.

## Compatibility matrix

| Concern | Docker backend | bwrap backend (phase 1) |
|---|---|---|
| Tool acquisition | `npx` inside the image, cached in `ai-agent-home` | Host-installed tool, run directly |
| Writes | Only mounted paths | Workspace + persistent home layer + allowlisted `:rw` paths |
| Read isolation | Only mounted paths visible | Allowlist-defined (strict by default) |
| Identity | Mirrored host UID/GID via entrypoint | Invoking host user directly |
| Git policy | Wrapper + entrypoint system config | Wrapper + generated system config |
| `serve` | Yes | Yes (phase 2; `2026-10-13-bwrap-serve-design.md`) |
| Cleanup container / root mode / volume | Yes | Not applicable |
| Network | host | host (phase 1) |
| Browser MCP | Yes | Yes |

## Security model and trade-offs

- **Stronger on writes:** the filesystem view is enforced by the kernel mount namespace; the agent cannot write outside the workspace, the home layer, and explicitly `:rw` paths, regardless of what it calls.
- **Read isolation is policy-defined:** unlike Docker (where anything unmounted is unreachable), the bwrap view is a constructed allowlist. The default (`read_home: false`) keeps the real home out of the view; `--read-home` widens reads to the whole home deliberately while keeping writes isolated. The deny list masks secrets in both modes.
- **No isolation from the host kernel:** bwrap shares the host kernel. This matches the project's non-adversarial threat model; kernel-level escapes are out of scope, as with Docker without a VM.
- **User-namespace fragility:** on distributions that restrict unprivileged user namespaces (notably Ubuntu 24.04+ AppArmor), `bwrap` cannot create the namespace and must fail with an actionable message instructing the user to load the `bwrap-userns-restrict` AppArmor profile or set `kernel.apparmor_restrict_unprivileged_userns=0`, or to use `--runtime docker`. The launcher must not silently fall back.
- **Dependency footprint:** adds only the `bwrap` system package; the launcher stays pure shell and the PKGBUILD stays `arch=('any')`.

These trade-offs are recorded in `docs/tradeoffs.md`.

## Error handling

Before starting the sandbox, the launcher rejects:

- an unknown `runtime` value, listing `docker` and `bwrap`;
- `--runtime` without a value;
- a bwrap run when `bwrap` is absent, or when user namespaces are unavailable, with the remediation above.

Runtime failures inside the sandbox surface as the selected tool's own errors, unchanged.

## Phasing

1. **Phase 0 — seam only.** Introduce the `runtime` selector, the `--runtime` flag, backend dispatch, and the extracted `docker` renderer. No observable behavior change; existing tests stay green.
2. **Phase 1 — bwrap interactive backend (this spec's implementation target).** Resolution, detection, filesystem model, host-tool run, git wrapper/config, env/mounts, browser MCP, error handling, docs.
3. **Phase 2.** bwrap `serve`/`openchamber` (`2026-10-13-bwrap-serve-design.md`); network isolation (`--unshare-net` + proxy); optional seccomp/Landlock hardening; macOS Seatbelt on the same seam (possibly via `srt`).

This spec's implementation plan covers phases 0 and 1.

## Testing

Source-level (host, no root, no Docker):

- `runtime` resolution precedence (CLI > env > workspace > user > default).
- `read_home` resolution precedence, the `--read-home` presence flag, and the warning when it is set with the Docker backend.
- Unknown `runtime` and missing-value rejection. (The phase-1 `serve` + `bwrap` rejection is superseded by `2026-10-13-bwrap-serve-design.md`.)
- The `-v`/`-e` specification arrays are populated for every existing concern (tool config, git config/policy/identity, proxy, host settings, extra/auto mounts, browser), unchanged.
- **Docker renderer regression:** the rendered `docker compose run`/`docker exec` command is byte-identical to the pre-refactor command for a representative matrix of tools and options.
- bwrap renderer argv assembly: namespace flags, allowlist binds, home layer bind, workspace bind, config binds, git wrapper binding, generated system gitconfig, env vars, workdir, and command.
- Home-layer path derivation is stable per workspace and does not depend on invocation order.

Integration (skipped when `bwrap` or user namespaces are unavailable):

- A bwrap run launches the selected host tool with `IS_SANDBOX=1`.
- Writes inside the workspace persist; writes outside it (and outside the home layer) fail.
- The home layer persists across two runs and the real `$HOME` is unchanged.
- `which git` resolves to the wrapper; `git push` is blocked and allowed operations work.

`tests/launcher/test.sh` gains the renderer and resolution cases; a new `tests/bwrap/test.sh` may host the bwrap-specific argv/integration checks. Existing config and git-wrapper suites must remain green.

## Documentation

Per the "Keeping docs in sync" checklist:

- `README.md` — tick "More runtimes", document `--runtime`, the bwrap backend, the home layer, and the host-toolchain reuse. (`serve` was Docker-only in phase 1; see `2026-10-13-bwrap-serve-design.md`.)
- `share/ai-sandbox/config.example.yaml` — `runtime`, `bwrap.passthrough`, `bwrap.deny`, `bwrap.read_home`.
- `docs/configuration.md` — schema and per-knob reference for the new keys.
- `docs/architecture.md` — a backend-seam section, the bwrap filesystem model, and the volume/lifecycle tables.
- `docs/development.md` — new invariants (backend functions outside the main guard; the Docker-renderer regression; the home-layer path contract) and manual test items.
- `docs/tradeoffs.md` — "Host-integrated namespace backend vs OCI container".
- `--help` and both shell-completion files — `--runtime` and `--read-home`.

## Files expected to change

| File | Change |
|---|---|
| `bin/ai-sandbox` | `--runtime` parsing/resolution; backend dispatch; extracted `docker` renderer; `bwrap` prepare/render and detection |
| `share/ai-sandbox/config.example.yaml` | New `runtime` and `bwrap.*` keys |
| `share/ai-sandbox/completions/ai-sandbox.bash` | `--runtime`, `--read-home` |
| `share/ai-sandbox/completions/_ai-sandbox` | `--runtime`, `--read-home` |
| `tests/launcher/test.sh` | Resolution, renderer, and error handling |
| `tests/bwrap/test.sh` (new) | bwrap argv assembly and integration checks |
| `tests/config/test.sh` | New config keys |
| `README.md` | Feature checklist, usage, backend description |
| `docs/architecture.md` | Backend seam and bwrap filesystem model |
| `docs/configuration.md` | New schema and knobs |
| `docs/development.md` | Invariants and manual tests |
| `docs/tradeoffs.md` | New backend trade-off entry |
| `install.sh`, `packaging/PKGBUILD` | Only if a new data file is added |

## Open questions

- **Default allowlist contents.** The exact system and per-user toolchain directory list is finalized in the implementation plan by probing a reference Linux host; the categories are fixed by this spec.
- **Writable caches.** Which host caches default to `:rw` (reuse + update) versus `:ro` (reuse only) is decided in the plan; the safe default is `:ro` with `:rw` opt-in.
- **Home-layer seeding.** Whether a fresh home layer is seeded with a minimal skeleton (e.g. empty `.config`) or left empty is a plan-level detail.
- **macOS backend mechanism.** Hand-written Seatbelt profile versus delegating the profile generation to `srt` is deferred to the macOS phase.
