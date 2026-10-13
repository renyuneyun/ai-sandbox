# Invocation-Dir Workspace Default

**Date:** 2026-10-13
**Status:** Approved, pending implementation
**Scope:** Let `./.ai-sandbox.yaml` (the config in the directory you launch from) select the workspace via a top-level `workspace:` key when no positional workspace is given, without mixing in the target workspace's own config. Conflicts are warned about and the lower-priority source is ignored. No behavior change when no `workspace:` key is present.

## Goal

Today the workspace is resolved before any config is read (`bin/ai-sandbox:1727`, `export WORKSPACE_DIR="${WORKSPACE_ARG:-$(pwd)}"`), and the workspace config path is derived *from* the workspace (`:1741`, `WORKSPACE_CONFIG="$WORKSPACE_DIR/.ai-sandbox.yaml"`). A config therefore cannot point at the workspace, and omitting the positional argument makes the current directory the workspace.

That is inconvenient for a "launch from `$HOME`" workflow: running `asb` at `$HOME` with no argument mounts the whole home read-write as the workspace. The user wants a per-directory config file at `$HOME` that names the *real* workspace (e.g. `~/tmp/cc`), so `asb` at `$HOME` binds only that dir plus the explicit mounts.

The enabling move is to read the config from a location that does **not** depend on the workspace — the invocation directory — and let that file name the workspace.

## Non-goals

- **`workspace:` in the user config.** Honoring it from `${XDG_CONFIG_HOME:-~/.config}/ai-sandbox/config.yaml` would act as a global default that beats `cwd`, so `cd ~/proj && asb` would silently launch the configured dir instead of `~/proj`. It is deliberately unsupported (ignored with a warning).
- **Layering two config files.** The invocation-dir config and the target workspace's config are never merged; exactly one is authoritative (Design B was rejected during brainstorming).
- **Changing the positional argument's meaning.** An explicit workspace stays authoritative and keeps reading the target dir's `.ai-sandbox.yaml`, exactly as today.
- **Auto-discovery of workspaces or session directories.** The key takes an explicit path (or `~`), nothing more.
- **A new CLI flag or completion changes.** This is config-only; the positional argument already exists.

## Semantics

Let `LAUNCH_DIR` be the canonical current directory. The rule has two cases, and the two config files are never mixed.

### Case 1 — explicit workspace (`asb [OPTIONS] WS`)

- Workspace = `WS` (validated and canonicalized as today).
- Authoritative config = `WS/.ai-sandbox.yaml`.
- If `WS/.ai-sandbox.yaml` itself declares `workspace: W2`, and `canonical(W2) != WS`, warn and **ignore** `W2` (the positional argument is authoritative).
- The invocation-dir config (`./.ai-sandbox.yaml`) is **not** read. Merely existing is **not** warned about — otherwise the `$HOME` daily config would warn on every `asb ~/proj`.

### Case 2 — no positional workspace (`asb [OPTIONS]`)

- Authoritative config = `LAUNCH_DIR/.ai-sandbox.yaml`.
- If that file declares `workspace: W`:
  - `W` is `~`-expanded, and if relative resolved against `LAUNCH_DIR`; then validated and canonicalized (a missing/non-directory target is an error, same as a bad positional argument).
  - Workspace = `W`.
  - If `W != LAUNCH_DIR` and `W/.ai-sandbox.yaml` exists, warn and **ignore** it; the authoritative config stays `LAUNCH_DIR/.ai-sandbox.yaml`.
- Otherwise workspace = `LAUNCH_DIR` (today's behavior).

### User config

`workspace:` is not a supported key in the user config. If present there, warn and ignore it. (The user config is still read for every other knob, as today.)

### Precedence and non-changes

- The chosen config file occupies the existing "workspace config" slot, so `resolve()` precedence is unchanged: **env var > chosen config > user config > default**.
- All other keys in the authoritative file apply normally (`tool`, `runtime`, `mounts.extra`, ...). This is what "load all of it" means.
- `mounts.auto.symlinks.workspace` is unrelated (a scan depth); only a **top-level** `workspace:` is the default workspace.

### Resolution algorithm

```
LAUNCH_DIR = canonical(pwd)

if WORKSPACE_ARG is set:
    WS     = canonical(validate(WORKSPACE_ARG))          # error if missing
    CONFIG = WS/.ai-sandbox.yaml
    W2     = workspace-key(CONFIG)                        # if valid config
    if W2 non-empty and canonical(W2) != WS:
        warn "explicit workspace wins; ignoring workspace '$W2' in CONFIG"
else:
    CONFIG = LAUNCH_DIR/.ai-sandbox.yaml
    W      = workspace-key(CONFIG)                        # if valid config
    if W empty:
        WS = LAUNCH_DIR
    else:
        WS = canonical(validate(expand(W, base=LAUNCH_DIR)))   # error if missing
        if WS != LAUNCH_DIR and -f WS/.ai-sandbox.yaml:
            warn "invocation-dir config wins; ignoring WS/.ai-sandbox.yaml"

if workspace-key(USER_CONFIG) non-empty:
    warn "'workspace' is only honored in the invocation-dir .ai-sandbox.yaml; ignoring USER_CONFIG"

WORKSPACE_DIR    = WS
WORKSPACE_CONFIG = CONFIG
```

`workspace-key(FILE)` returns the raw `.workspace` string, or empty when the file is absent, invalid, or has no key. An explicit empty or null value counts as "no key".

## Knob naming

| Aspect | Choice |
|---|---|
| Config key | top-level `workspace:` (e.g. `workspace: ~/tmp/cc`) |
| Value | absolute, `~`-prefixed, or relative-to-the-config-file's-directory path to an existing directory |
| CLI | unchanged — the positional `WORKSPACE` argument |
| Env | none |

Alternatives considered and rejected: `target:`, `workspace_dir:` (less obvious); a `sandbox.workspace` nest (the value is not a sandbox-identity knob); a `--workspace` flag (the positional argument already covers the CLI case).

## Backward compatibility

- No `workspace:` key anywhere → identical behavior: config comes from the positional target, or from `cwd` when none is given, and the workspace is the same dir.
- New key + new warnings only; no flag, env var, or file-name changes.
- The only behavioral difference with the key present is the intended workspace redirection and the "ignore the other config" warnings.

## Implementation

### `bin/ai-sandbox`

1. Capture `LAUNCH_DIR="$(cd "$(pwd)" && pwd)"` **before** workspace resolution (`:1727`), while `pwd` is still the invocation directory.
2. Add a helper `workspace_from_config FILE` (outside the main guard, next to `check_config`/`resolve`) that prints `.workspace` via `yq -r` when the file exists and parses, else nothing. It needs the same `yq`-availability guard as `check_config`.
3. Replace the single `WORKSPACE_DIR="${WORKSPACE_ARG:-$(pwd)}"` line with the algorithm above: resolve `WS`, validate/canonicalize it, and set `WORKSPACE_CONFIG` to the chosen file (`WS/.ai-sandbox.yaml` in Case 1, `LAUNCH_DIR/.ai-sandbox.yaml` in Case 2) instead of always `$WORKSPACE_DIR/.ai-sandbox.yaml`.
4. Emit the three warnings through `warn_msg`, gated so they never fire in the no-key/no-conflict path.
5. Keep `check_config` validation for whichever config is authoritative.
6. `serve`/`openchamber` need no special handling: they share `WORKSPACE_DIR`, so the server name (`SERVE_NAME`, hashed from `WORKSPACE_DIR`) and the working directory follow the resolved workspace automatically.

### `docs/development.md`

- Add `workspace_from_config` to the "must remain defined outside the main guard" list.
- Add the rule to "Key invariants": the authoritative config is `$WORKSPACE_ARG/.ai-sandbox.yaml` when a positional workspace is given, else `$LAUNCH_DIR/.ai-sandbox.yaml`; the two are never merged; a top-level `workspace:` is only honored in the invocation-dir file.
- Add a manual-testing checklist item (see [Testing](#testing)).

### `docs/configuration.md`, `README.md`, `share/ai-sandbox/config.example.yaml`

- Document the top-level `workspace:` key, its two-case resolution, the conflict warnings, and the "not honored in the user config" restriction.
- `config.example.yaml`: add a commented top-level block near the top, e.g.

  ```yaml
  # Default workspace for `asb` run from this directory with no positional
  # argument. Only honored in an invocation-dir .ai-sandbox.yaml, never in the
  # user config. `~` and relative paths (against this file's dir) are allowed.
  # workspace: ~/tmp/cc
  ```

- `README.md`: a short note in the config/usage section; the `--help` `CONFIGURATION` blurb may mention that `workspace:` selects the default workspace.

## Testing

### `tests/launcher/test.sh`

- No arg, no key → `WORKSPACE_DIR` == cwd; `WORKSPACE_CONFIG` == `cwd/.ai-sandbox.yaml` (unchanged).
- No arg, key `workspace: <tmpdir>` → `WORKSPACE_DIR` == canonical `<tmpdir>`; `WORKSPACE_CONFIG` == `cwd/.ai-sandbox.yaml` (not the target's).
- No arg, key relative (`workspace: sub`) → resolves against the invocation dir.
- No arg, key `~`-prefixed → expands to `$HOME`.
- No arg, key points at a missing dir → error before any container, non-zero.
- No arg, key redirects and the target has its own `.ai-sandbox.yaml` → warning emitted and the target config ignored (its knobs do not take effect).
- Explicit workspace in `parse_launcher_args` → `WORKSPACE_CONFIG` == `WS/.ai-sandbox.yaml`; the cwd config is not read and does **not** warn.
- Explicit workspace whose config declares a different `workspace:` → warning, and `WORKSPACE_DIR` stays the explicit arg.
- `workspace:` in the user config → warning; the value is ignored; `WORKSPACE_DIR` falls back to cwd.
- Invalid YAML / `yq` absent → the key is treated as absent (no crash), consistent with `check_config`.

### Manual testing checklist (added to `docs/development.md`)

- Put `~/.ai-sandbox.yaml` with `workspace: ~/tmp/cc` and, say, `runtime: bwrap` and a `mounts.extra` list. From `$HOME`, `asb` binds `~/tmp/cc` (not `$HOME`) and applies the mounts; `~/tmp/cc/.ai-sandbox.yaml`, if present, is warned about and ignored. From another dir, `asb` is unaffected. `asb ~/proj` uses `~/proj/.ai-sandbox.yaml` and does not warn about `~/.ai-sandbox.yaml`.

## Open questions

None. Confirmed during brainstorming:

- Design A (invocation-dir config) selected over two-file layering (B) and a global user-config default (C).
- Explicit workspace remains authoritative; the two configs are never mixed.
- Warnings only on real conflicts (a config's own `workspace:` contradicting an already-chosen workspace; a second config at the target in the no-arg case) — not merely because `./.ai-sandbox.yaml` exists while an explicit workspace is given.
- Top-level `workspace:` key; user-config `workspace:` unsupported (warned).