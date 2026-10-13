# Host-Integrated bwrap Runtime Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `bwrap` runtime backend that runs the selected coding agent from the host toolchain inside an unprivileged bubblewrap namespace with a workspace-bounded, layered filesystem, while Docker remains the default and unchanged.

**Architecture:** A runtime selector (`--runtime`/`SANDBOX_RUNTIME`/`.runtime`) dispatches the interactive run to either the existing Docker command or a new bubblewrap command. The existing `-v`/`-e` argument arrays stay the mount/env specification; a bwrap renderer translates them into `--ro-bind`/`--bind`/`--setenv`, and a bwrap prepare step adds the namespaces, system allowlist, per-workspace home layer, secret deny list, git-wrapper rebind, and generated system gitconfig. `serve`, warm-up, cleanup, and root mode stay Docker-only.

**Tech Stack:** Bash (launcher + tests), `bwrap` (bubblewrap), `yq` (config, tests only), overlayfs (optional read-through home), git `/etc/gitconfig` (image path replaced by a generated bind).

**Spec:** `docs/superpowers/specs/2026-10-10-more-runtimes-design.md`

## Global Constraints

- Docker remains the default runtime; the Docker command path must stay byte-for-byte identical (the existing `tests/launcher/test.sh` capture tests are the regression lock).
- New launcher functions must be defined **outside** the main guard (`if [[ "${BASH_SOURCE[0]}" == "${0}" ]]`) for source-level tests.
- All user-facing behavior changes must update `--help`, both completion files, `config.example.yaml`, `README.md`, and `docs/` in the same change (the "Keeping docs in sync" checklist).
- `share/ai-sandbox/docker-compose.yml`, the `ai-agent` service, `ai-agent-home`, `ai-agent`, `ai-sandbox-${SANDBOX_UID}`, and `IS_SANDBOX=1` are stable contracts and must not change.
- The launcher stays pure shell; the PKGBUILD stays `arch=('any')` (no compiled helper). The only new external dependency is the `bwrap` package (system package, not bundled).
- `bwrap` runs as the invoking host user; do not add user/group creation, `runuser`, or `SANDBOX_UID=0` handling to the bwrap path.
- Every new config knob uses the existing precedence: env var > workspace config > user config > default, via `resolve`/`resolve_list`.
- Reset any exported `SANDBOX_*` test env between test groups (existing suites rely on this).

## Review Focus

- **Unprivileged user namespaces unavailable** (Ubuntu 24.04+ AppArmor): `bwrap` must fail with an actionable message (load `bwrap-userns-restrict` / set `kernel.apparmor_restrict_unprivileged_userns=0`, or use `--runtime docker`) — never silently fall back to an unsandboxed run. (Task 3)
- **A path containing a colon** in a mount spec: the project already assumes colon-free host paths; the bwrap parser must split `HOST:CONT:FLAGS` exactly as `configure_extra_mounts` does so `HOST:ro` (flag form) and `HOST:CONT` both translate correctly. (Task 4)
- **`SANDBOX_HOME` differs from the real `$HOME`**: tool-config mounts target `${SANDBOX_HOME}/...`; under bwrap they must be rewritten to the real home path or config lands in a hidden directory. (Task 4)
- **A missing host tool**: `--runtime bwrap` with the selected CLI not installed must fail before `bwrap` runs, with a message naming the tool, rather than an opaque exec error. (Task 8)
- **`--read-home` with a non-existent secret path**: the deny list must skip paths that do not exist instead of aborting `bwrap`. (Task 6)

---

### Task 1: Runtime and read-home selection

**Files:**
- Modify: `bin/ai-sandbox` (add `resolve_runtime`, `resolve_read_home`; extend `parse_launcher_args`; resolve in main)
- Test: `tests/launcher/test.sh`

**Interfaces:**
- Consumes: existing `resolve`, `launcher_error`.
- Produces: `CLI_RUNTIME`, `CLI_READ_HOME` (parse globals); `resolve_runtime CLI_VALUE` → printable name; `resolve_read_home CLI_VALUE` → `true|false`; main globals `RUNTIME`, `READ_HOME`.

- [ ] **Step 1: Write the failing test**

Add to `tests/launcher/test.sh` after the `--git-preset` parse block (around line 135):

```bash
parse_launcher_args --runtime bwrap
assert_eq "parse: runtime sets CLI_RUNTIME" "bwrap" "${CLI_RUNTIME:-}"
parse_launcher_args --runtime=opencode-only
assert_eq "parse: runtime equals form" "opencode-only" "${CLI_RUNTIME:-}"
parse_launcher_args --read-home
assert_eq "parse: read-home sets CLI_READ_HOME" "true" "${CLI_READ_HOME:-}"
parse_launcher_args
assert_eq "parse: no runtime leaves CLI_RUNTIME empty" "" "${CLI_RUNTIME:-}"
assert_eq "parse: no read-home leaves CLI_READ_HOME empty" "" "${CLI_READ_HOME:-}"
if parse_launcher_args --runtime >/dev/null 2>&1; then bad "parse: missing runtime value"; else ok "parse: missing runtime value"; fi
if parse_launcher_args --read-home=true >/dev/null 2>&1; then bad "parse: read-home equals value rejected"; else ok "parse: read-home equals value rejected"; fi

WORKSPACE_CONFIG_VALID=false
USER_CONFIG_VALID=false
unset SANDBOX_RUNTIME SANDBOX_BWRAP_READ_HOME
assert_eq "resolve_runtime: default docker" "docker" "$(resolve_runtime "")"
assert_eq "resolve_runtime: CLI wins" "bwrap" "$(resolve_runtime bwrap)"
SANDBOX_RUNTIME=bwrap
assert_eq "resolve_runtime: env" "bwrap" "$(resolve_runtime "")"
assert_eq "resolve_runtime: CLI beats env" "docker" "$(resolve_runtime docker)"
unset SANDBOX_RUNTIME
assert_eq "resolve_read_home: default false" "false" "$(resolve_read_home "")"
assert_eq "resolve_read_home: CLI true" "true" "$(resolve_read_home true)"
SANDBOX_BWRAP_READ_HOME=true
assert_eq "resolve_read_home: env true" "true" "$(resolve_read_home "")"
assert_eq "resolve_read_home: CLI true beats env" "true" "$(resolve_read_home true)"
unset SANDBOX_BWRAP_READ_HOME
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/launcher/test.sh 2>&1 | tail -20`
Expected: FAIL — `parse: runtime sets CLI_RUNTIME` and `resolve_runtime` failures (`command not found`).

- [ ] **Step 3: Write the implementation**

In `bin/ai-sandbox`, add the two resolver functions next to `resolve_git_preset` (after line ~369), outside the main guard:

```bash
# Resolve the runtime backend name. CLI --runtime wins, else env > workspace >
# user > default (docker). Validation against the supported set happens in main.
resolve_runtime() {  # CLI_VALUE
  local cli_value="$1" selected
  if [[ -n "$cli_value" ]]; then
    selected="$cli_value"
  else
    selected="$(resolve SANDBOX_RUNTIME .runtime docker)"
  fi
  echo "$selected"
}

# Resolve whether the whole real $HOME is readable under bwrap. CLI --read-home
# wins, else env > workspace > user > default (false). Follows resolve_allow_local.
resolve_read_home() {  # CLI_VALUE
  local cli_value="$1" selected
  if [[ -n "$cli_value" ]]; then
    selected="$cli_value"
  else
    selected="$(resolve SANDBOX_BWRAP_READ_HOME .bwrap.read_home false)"
  fi
  echo "$selected"
}
```

In `parse_launcher_args`, add the globals at the top (after `CLI_GIT_PRESET=""`, line ~228):

```bash
  CLI_RUNTIME=""
  CLI_READ_HOME=""
```

Extend the `--opt=value` pre-pass split list (line ~244):

```bash
      --tool=*|--git-preset=*|--hostname=*|--port=*|--runtime=*)
```

Add cases in the option `while` loop (after the `--git-preset` case, line ~282):

```bash
      --runtime)
        (($# >= 2)) || { launcher_error "--runtime requires docker or bwrap"; return; }
        CLI_RUNTIME="$2"
        shift 2
        ;;
      --read-home)
        CLI_READ_HOME=true
        shift
        ;;
```

In the main guard, after `SELECTED_TOOL="$CLI_RESOLVED_TOOL"` (line ~904) or after the identity block, resolve and validate:

```bash
RUNTIME="$(resolve_runtime "$CLI_RUNTIME")"
case "$RUNTIME" in
  docker|bwrap) ;;
  *) launcher_error "unsupported runtime '$RUNTIME'; supported runtimes: docker, bwrap"; exit 2 ;;
esac
READ_HOME="$(resolve_read_home "$CLI_READ_HOME")"
if [[ "$RUNTIME" == docker && "$CLI_READ_HOME" == true ]]; then
  warn_msg "--read-home has no effect with --runtime docker (it is ignored)."
fi
if [[ -n "$SERVE_ACTION" && "$RUNTIME" == bwrap ]]; then
  launcher_error "serve is available only with --runtime docker in this release"; exit 2
fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/launcher/test.sh 2>&1 | tail -5`
Expected: PASS (the suite prints `N passed, 0 failed`).

- [ ] **Step 5: Commit**

```bash
git add bin/ai-sandbox tests/launcher/test.sh
git commit -m "feat(runtime): add --runtime and --read-home selection"
```

---

### Task 2: Extract the Docker renderer and dispatch

**Files:**
- Modify: `bin/ai-sandbox` (add `run_docker_agent`; dispatch the interactive tail)
- Test: `tests/launcher/test.sh` (existing capture tests must stay green; add a dispatch assertion)

**Interfaces:**
- Consumes: the `*_VOLUME_ARGS`/`*_ENV_ARGS` globals, `COMPOSE_PROJECT`, `SANDBOX_COMPOSE_DIR`, `SANDBOX_HOME`, `TOOL_PACKAGE`, `TOOL_DEFAULT_ARGS`, `TOOL_USER_ARGS`.
- Produces: `run_docker_agent` (foreground Docker run, identical command), `run_bwrap_agent` (stub until Task 8), `RUNTIME` dispatch.

- [ ] **Step 1: Write the failing test**

Add to `tests/launcher/test.sh` after the warm-up tests (around line 1335):

```bash
# Runtime dispatch: bwrap must not invoke docker.
CAPTURE_DIR_BWRAP_DISPATCH="$(mktemp -d)"
PROFILE_TMP_DIRS+=("$CAPTURE_DIR_BWRAP_DISPATCH")
run_captured_launcher "$CAPTURE_DIR_BWRAP_DISPATCH" --runtime bwrap "$SCRIPT_DIR/../.." || true
[[ ! -e "$CAPTURE_DIR_BWRAP_DISPATCH/docker.args" ]] &&
  ok "dispatch: bwrap runtime does not call docker" ||
  bad "dispatch: bwrap runtime does not call docker"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/launcher/test.sh 2>&1 | tail -20`
Expected: FAIL — the bwrap dispatch still runs `docker compose` (the capture file exists) because dispatch is not implemented.

- [ ] **Step 3: Write the implementation**

In `bin/ai-sandbox`, replace the final interactive block (lines ~1249-1267) with a function definition outside the main guard and a dispatch call. First add the function after `configure_auto_mounts` (line ~821):

```bash
# Render and run the selected agent in a one-shot Docker container.
# Docker behavior is unchanged from the pre-seam launcher; the capture tests in
# tests/launcher/test.sh are the regression lock.
run_docker_agent() {
  docker compose -p "$COMPOSE_PROJECT" -f "$SANDBOX_COMPOSE_DIR/docker-compose.yml" run \
    --rm \
    -e HOME="${SANDBOX_HOME}" \
    "${PROXY_ENV_ARGS[@]}" \
    "${HOST_SETTINGS_ENV_ARGS[@]}" \
    "${HOST_SETTINGS_VOLUME_ARGS[@]}" \
    "${TOOL_ENV_ARGS[@]}" \
    "${GIT_ENV_ARGS[@]}" \
    "${GIT_MODE_ENV_ARGS[@]}" \
    "${GIT_VOLUME_ARGS[@]}" \
    "${TOOL_VOLUME_ARGS[@]}" \
    "${GIT_POLICY_VOLUME_ARGS[@]}" \
    "${BROWSER_ENV_ARGS[@]}" \
    "${BROWSER_VOLUME_ARGS[@]}" \
    "${EXTRA_MOUNT_VOLUME_ARGS[@]}" \
    -it ai-agent \
    npx --yes "$TOOL_PACKAGE" "${TOOL_DEFAULT_ARGS[@]}" "${TOOL_USER_ARGS[@]}"
}

# Placeholder until Task 8: the bwrap backend.
run_bwrap_agent() {
  launcher_error "the bwrap runtime backend is not implemented yet"
  return 2
}
```

Then replace the old inline Docker run (the block at the end of the file) with:

```bash
case "$RUNTIME" in
  docker) run_docker_agent ;;
  bwrap)  run_bwrap_agent ;;
esac
```

Guard the warm-up block (lines ~1136-1159) so it is Docker-only: change the condition to `if [[ "$RUNTIME" == docker && "$SANDBOX_PROGRESS" == "true" ]]; then`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/launcher/test.sh 2>&1 | tail -5`
Expected: PASS — all existing Docker capture tests remain green (proving the extracted command is byte-identical), and the new dispatch assertion holds (no docker capture for `--runtime bwrap`). The bwrap run itself errors with the placeholder message, which is acceptable for this task.

- [ ] **Step 5: Commit**

```bash
git add bin/ai-sandbox tests/launcher/test.sh
git commit -m "refactor(runtime): extract run_docker_agent and dispatch by runtime"
```

---

### Task 3: bwrap availability detection

**Files:**
- Modify: `bin/ai-sandbox` (add `bwrap_available`, `bwrap_detect_error`)
- Test: `tests/launcher/test.sh`

**Interfaces:**
- Produces: `bwrap_available` → 0 when `bwrap` exists and can create a sandbox, else non-zero after printing remediation via `launcher_error`; `bwrap_probe_userns` helper.

- [ ] **Step 1: Write the failing test**

Add to `tests/launcher/test.sh` after the dispatch test:

```bash
# bwrap detection: a stub bwrap that succeeds is available; a missing bwrap is not.
DETECT_DIR="$(mktemp -d)"
PROFILE_TMP_DIRS+=("$DETECT_DIR")
mkdir -p "$DETECT_DIR/bin"
printf '#!/bin/sh\nexit 0\n' > "$DETECT_DIR/bin/bwrap"
chmod +x "$DETECT_DIR/bin/bwrap"
OLD_PATH="$PATH"
PATH="$DETECT_DIR/bin:$PATH"
if bwrap_available; then ok "bwrap: available when bwrap probe succeeds"; else bad "bwrap: available when bwrap probe succeeds"; fi

PATH="$DETECT_DIR/empty"
mkdir -p "$PATH"
detect_out="$(bwrap_available 2>&1)" && detect_code=0 || detect_code=$?
[[ $detect_code -ne 0 && "$detect_out" == *"bwrap"* ]] &&
  ok "bwrap: missing bwrap is reported with a message" ||
  bad "bwrap: missing bwrap is reported with a message (code=$detect_code, out='$detect_out')"
PATH="$OLD_PATH"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/launcher/test.sh 2>&1 | tail -20`
Expected: FAIL — `bwrap_available` is not defined.

- [ ] **Step 3: Write the implementation**

Add after `run_bwrap_agent` (outside the main guard):

```bash
# Probe whether the bwrap backend can run on this host. Returns 0 and prints
# nothing on success; otherwise returns 1 with an actionable message on stderr.
# The probe actually creates a minimal sandbox so a present-but-unusable bwrap
# (e.g. unprivileged user namespaces blocked by AppArmor) is detected.
bwrap_available() {
  if ! command -v bwrap >/dev/null 2>&1; then
    echo "ai-sandbox: bwrap not found on PATH; install the 'bubblewrap' package or use --runtime docker" >&2
    return 1
  fi
  if ! bwrap --ro-bind / / --proc /proc --dev /dev --unshare-all --share-net -- /bin/true >/dev/null 2>&1; then
    echo "ai-sandbox: bwrap cannot create a sandbox on this host (unprivileged user namespaces are unavailable)." >&2
    echo "ai-sandbox: on Ubuntu 24.04+ load the AppArmor profile (e.g. /etc/apparmor.d/bwrap-userns-restrict) or set" >&2
    echo "ai-sandbox:   kernel.apparmor_restrict_unprivileged_userns=0, or use --runtime docker." >&2
    return 1
  fi
  return 0
}
```

In the main guard, before dispatch, call it when the runtime is bwrap:

```bash
if [[ "$RUNTIME" == bwrap ]]; then
  bwrap_available || exit 2
fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/launcher/test.sh 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add bin/ai-sandbox tests/launcher/test.sh
git commit -m "feat(runtime): detect bwrap availability and explain userns failures"
```

---

### Task 4: Translate mount specs to bwrap binds

**Files:**
- Modify: `bin/ai-sandbox` (add `bwrap_rewrite_cont_path`, `bwrap_translate_mounts`)
- Test: `tests/launcher/test.sh`

**Interfaces:**
- Consumes: `SANDBOX_HOME`, `BWRAP_HOME` (mount point, default `$HOME`).
- Produces: `bwrap_rewrite_cont_path PATH` → printable path; `bwrap_translate_mounts ARGS...` → fills global `BWRAP_MOUNT_ARGS`.

- [ ] **Step 1: Write the failing test**

Add to `tests/launcher/test.sh`:

```bash
# bwrap mount translation: -v HOST:CONT[:FLAGS] -> --ro-bind/--bind.
SANDBOX_HOME="/home/tester"
BWRAP_HOME="/host/tester"
bwrap_translate_mounts -v "/host/tester/.claude:/home/tester/.claude:rw" -v "/etc/localtime:/etc/localtime:ro" -v "/opt/x:/opt/x"
JOINED="$(printf '<%s>' "${BWRAP_MOUNT_ARGS[@]}")"
assert_eq "bwrap mounts: rewritten cont path" "<--bind><\/host/tester/.claude></host/tester/.claude>" \
  "$(printf '<%s>' "${BWRAP_MOUNT_ARGS[0]}" "${BWRAP_MOUNT_ARGS[1]}" "${BWRAP_MOUNT_ARGS[2]}")"
[[ "$JOINED" == *"<--ro-bind><\/etc/localtime></etc/localtime>"* ]] &&
  ok "bwrap mounts: ro flag maps to --ro-bind" || bad "bwrap mounts: ro flag ($JOINED)"
[[ "$JOINED" == *"<--ro-bind></opt/x></opt/x>"* ]] &&
  ok "bwrap mounts: default (no flag) is read-only" || bad "bwrap mounts: default ro ($JOINED)"
assert_eq "bwrap rewrite: exact home" "/host/tester" "$(bwrap_rewrite_cont_path /home/tester)"
assert_eq "bwrap rewrite: under home" "/host/tester/.codex" "$(bwrap_rewrite_cont_path /home/tester/.codex)"
assert_eq "bwrap rewrite: unrelated path" "/etc/hosts" "$(bwrap_rewrite_cont_path /etc/hosts)"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/launcher/test.sh 2>&1 | tail -20`
Expected: FAIL — functions not defined.

- [ ] **Step 3: Write the implementation**

Add after `bwrap_available`:

```bash
# Rewrite a container-side path so a mount that targeted the Docker sandbox home
# lands on the real host home under bwrap (they are usually equal; they differ
# only when sandbox.home is customized).
bwrap_rewrite_cont_path() {  # PATH
  local p="$1" home="${BWRAP_HOME:-$HOME}"
  case "$p" in
    "$SANDBOX_HOME")   printf '%s' "$home" ;;
    "$SANDBOX_HOME"/*) printf '%s/%s' "$home" "${p#"$SANDBOX_HOME"/}" ;;
    *)                 printf '%s' "$p" ;;
  esac
}

# Translate the launcher's -v specification arrays into bwrap bind arguments.
# Each "-v HOST:CONT[:FLAGS]" becomes "--ro-bind HOST CONT" (default/ro) or
# "--bind HOST CONT" (rw). Paths are assumed colon-free, matching
# configure_extra_mounts. Results populate the global BWRAP_MOUNT_ARGS.
bwrap_translate_mounts() {
  BWRAP_MOUNT_ARGS=()
  local a spec host cont rest flags
  while (($#)); do
    a="$1"
    if [[ "$a" == "-v" ]]; then
      shift
      spec="$1"
      host="${spec%%:*}"
      rest="${spec#*:}"
      if [[ "$rest" == *:* ]]; then
        cont="${rest%%:*}"
        flags="${rest#*:}"
      else
        cont="$rest"
        flags=""
      fi
      cont="$(bwrap_rewrite_cont_path "$cont")"
      if [[ "$flags" == "rw" ]]; then
        BWRAP_MOUNT_ARGS+=(--bind "$host" "$cont")
      else
        BWRAP_MOUNT_ARGS+=(--ro-bind "$host" "$cont")
      fi
    fi
    shift
  done
  return 0
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/launcher/test.sh 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add bin/ai-sandbox tests/launcher/test.sh
git commit -m "feat(runtime): translate mount specs into bwrap binds"
```

---

### Task 5: Translate environment specs to bwrap setenv

**Files:**
- Modify: `bin/ai-sandbox` (add `bwrap_translate_env`)
- Test: `tests/launcher/test.sh`

**Interfaces:**
- Produces: `bwrap_translate_env ARGS...` → fills global `BWRAP_TRANSLATED_ENV`.

- [ ] **Step 1: Write the failing test**

```bash
# bwrap env translation: -e K=V -> --setenv K V, preserving '=' in values.
bwrap_translate_env -e "ANTHROPIC_API_KEY=sk-a=b" -e "TZ=Pacific/Auckland"
assert_eq "bwrap env: count" "4" "${#BWRAP_TRANSLATED_ENV[@]}"
assert_eq "bwrap env: key" "--setenv" "${BWRAP_TRANSLATED_ENV[0]}"
assert_eq "bwrap env: value keeps equals" "sk-a=b" "${BWRAP_TRANSLATED_ENV[2]}"
assert_eq "bwrap env: second value" "Pacific/Auckland" "${BWRAP_TRANSLATED_ENV[5]}"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/launcher/test.sh 2>&1 | tail -20`
Expected: FAIL — function not defined.

- [ ] **Step 3: Write the implementation**

Add after `bwrap_translate_mounts`:

```bash
# Translate the launcher's -e specification arrays into bwrap --setenv pairs.
# Splits on the FIRST '=' so values may contain '='. Populates BWRAP_TRANSLATED_ENV.
bwrap_translate_env() {
  BWRAP_TRANSLATED_ENV=()
  local a kv k v
  while (($#)); do
    a="$1"
    if [[ "$a" == "-e" ]]; then
      shift
      kv="$1"
      k="${kv%%=*}"
      v="${kv#*=}"
      BWRAP_TRANSLATED_ENV+=(--setenv "$k" "$v")
    fi
    shift
  done
  return 0
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/launcher/test.sh 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add bin/ai-sandbox tests/launcher/test.sh
git commit -m "feat(runtime): translate env specs into bwrap setenv"
```

---

### Task 6: bwrap base view (namespaces, allowlist, home layer, deny)

**Files:**
- Modify: `bin/ai-sandbox` (add `bwrap_home_layer_path`, `bwrap_prepare_base`)
- Test: `tests/launcher/test.sh`

**Interfaces:**
- Consumes: `WORKSPACE_DIR`, `HOME`, `READ_HOME`, `SANDBOX_BWRAP_*` config values, `XDG_STATE_HOME`.
- Produces: `bwrap_home_layer_path` → printable layer dir; `bwrap_prepare_base` → fills global `BWRAP_BASE_ARGS`; globals `BWRAP_LAYER_DIR`, `BWRAP_WORK_DIR`.

- [ ] **Step 1: Write the failing test**

```bash
# bwrap base view: namespaces, system allowlist, home layer, deny list.
BASE_DIR="$(mktemp -d)"
PROFILE_TMP_DIRS+=("$BASE_DIR")
mkdir -p "$BASE_DIR/state"
WORKSPACE_DIR="/ws/proj"
XDG_STATE_HOME="$BASE_DIR/state"
HOME="/host/tester"
READ_HOME=false
SANDBOX_BWRAP_PASSTHROUGH=""
SANDBOX_BWRAP_DENY=""
bwrap_prepare_base
BASE_JOINED="$(printf '<%s>' "${BWRAP_BASE_ARGS[@]}")"
[[ "$BASE_JOINED" == *"<--unshare-all><--share-net>"* ]] &&
  ok "bwrap base: namespaces unshared with host net" || bad "bwrap base: namespaces ($BASE_JOINED)"
[[ "$BASE_JOINED" == *"<--proc></proc>"* && "$BASE_JOINED" == *"<--dev></dev>"* && "$BASE_JOINED" == *"<--tmpfs></tmp>"* ]] &&
  ok "bwrap base: proc/dev/tmp mounted" || bad "bwrap base: runtime dirs ($BASE_JOINED)"
[[ "$BASE_JOINED" == *"<--bind><$BWRAP_LAYER_DIR></host/tester>"* ]] &&
  ok "bwrap base: home layer bound at real home" || bad "bwrap base: home layer ($BASE_JOINED)"
[[ "$BWRAP_LAYER_DIR" == "$BASE_DIR/state/ai-sandbox/runtime/bwrap/"*"/home" ]] &&
  ok "bwrap base: layer path is workspace-scoped under XDG state" || bad "bwrap base: layer path ($BWRAP_LAYER_DIR)"

# read-home adds an overlay lower of the real home.
READ_HOME=true
bwrap_prepare_base
BASE_JOINED="$(printf '<%s>' "${BWRAP_BASE_ARGS[@]}")"
[[ "$BASE_JOINED" == *"<--overlay-src></host/tester>"* && "$BASE_JOINED" == *"<--overlay>"* ]] &&
  ok "bwrap base: read-home uses overlay lower" || bad "bwrap base: read-home overlay ($BASE_JOINED)"

# deny list skips non-existent paths and shadows existing directories.
READ_HOME=true
SANDBOX_BWRAP_DENY=$'/host/tester/.ssh\n/definitely/missing'
mkdir -p "$HOME/.ssh"
bwrap_prepare_base
BASE_JOINED="$(printf '<%s>' "${BWRAP_BASE_ARGS[@]}")"
[[ "$BASE_JOINED" == *"<--tmpfs></host/tester/.ssh>"* ]] &&
  ok "bwrap base: existing deny path is shadowed" || bad "bwrap base: deny shadow ($BASE_JOINED)"
[[ "$BASE_JOINED" != *"/definitely/missing"* ]] &&
  ok "bwrap base: missing deny path is skipped" || bad "bwrap base: missing deny skipped ($BASE_JOINED)"
unset SANDBOX_BWRAP_PASSTHROUGH SANDBOX_BWRAP_DENY
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/launcher/test.sh 2>&1 | tail -20`
Expected: FAIL — functions not defined.

- [ ] **Step 3: Write the implementation**

Add after `bwrap_translate_env`:

```bash
# The persistent per-workspace home layer directory. Stable for a workspace so
# writes persist across runs; derived from a hash of the canonical workspace path.
bwrap_home_layer_path() {
  local hash
  hash="$(printf '%s' "$WORKSPACE_DIR" | git hash-object --stdin 2>/dev/null)" || hash=""
  [[ -n "$hash" ]] || hash="$(printf '%s' "$WORKSPACE_DIR" | md5sum | cut -d' ' -f1)"
  printf '%s/ai-sandbox/runtime/bwrap/%s/home' "${XDG_STATE_HOME:-$HOME/.local/state}" "${hash:0:12}"
}

# Assemble the bwrap-specific base arguments: namespaces, the read-only system
# allowlist, the layered $HOME, the per-user toolchain allowlist, the secret deny
# list, and the runtime directories. Later binds win, so the home layer precedes
# the per-user/tool-config binds that must land inside it. Populates
# BWRAP_BASE_ARGS and BWRAP_LAYER_DIR / BWRAP_WORK_DIR.
bwrap_prepare_base() {
  BWRAP_BASE_ARGS=(--unshare-all --share-net --die-with-parent --new-session)
  BWRAP_LAYER_DIR="$(bwrap_home_layer_path)"
  BWRAP_WORK_DIR="$(dirname "$BWRAP_LAYER_DIR")/work"
  BWRAP_HOME="${BWRAP_HOME:-$HOME}"

  # 1. System toolchain, read-only.
  local d
  for d in /usr /bin /sbin /lib /lib64 /lib32 /etc /opt /nix; do
    [[ -e "$d" ]] && BWRAP_BASE_ARGS+=(--ro-bind "$d" "$d")
  done

  # 2. Runtime directories.
  BWRAP_BASE_ARGS+=(--proc /proc --dev /dev --tmpfs /tmp --dir /tmp)

  # 3. Home: a persistent per-workspace layer (writes never touch the real home).
  mkdir -p "$BWRAP_LAYER_DIR" "$BWRAP_WORK_DIR"
  if [[ "$READ_HOME" == "true" ]]; then
    BWRAP_BASE_ARGS+=(--overlay-src "$HOME" --overlay "$BWRAP_LAYER_DIR" "$BWRAP_WORK_DIR" "$HOME")
  else
    BWRAP_BASE_ARGS+=(--bind "$BWRAP_LAYER_DIR" "$HOME")
  fi

  # 4. Per-user toolchain, read-only, applied after the home layer.
  local rel
  for rel in .nvm .volta .asdf .fnm .bun .cargo .rustup .deno .local; do
    [[ -e "$HOME/$rel" ]] && BWRAP_BASE_ARGS+=(--ro-bind "$HOME/$rel" "$HOME/$rel")
  done

  # 5. Secret deny list (only meaningful when the real home is visible).
  if [[ "$READ_HOME" == "true" ]]; then
    local deny
    while IFS= read -r deny; do
      [[ -n "$deny" && -e "$deny" ]] && BWRAP_BASE_ARGS+=(--tmpfs "$deny")
    done <<< "${SANDBOX_BWRAP_DENY:-}"
    for deny in "$HOME/.ssh" "$HOME/.aws" "$HOME/.gnupg" "$HOME/.config/gh" "$HOME/.netrc" "$HOME/.docker"; do
      case "${SANDBOX_BWRAP_DENY:-}" in *"$deny"*) continue ;; esac
      [[ -e "$deny" ]] && BWRAP_BASE_ARGS+=(--tmpfs "$deny")
    done
  fi
  return 0
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/launcher/test.sh 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add bin/ai-sandbox tests/launcher/test.sh
git commit -m "feat(runtime): assemble bwrap namespaces, allowlist, and home layer"
```

---

### Task 7: Git wrapper rebind and generated system gitconfig

**Files:**
- Modify: `bin/ai-sandbox` (add `bwrap_prepare_git`; extend the exit trap for `BWRAP_GITCONFIG`)
- Test: `tests/launcher/test.sh`

**Interfaces:**
- Consumes: `SANDBOX_COMPOSE_DIR`, `SANDBOX_HOME`, `BWRAP_HOME`.
- Produces: `bwrap_prepare_git` → fills global `BWRAP_GIT_ARGS`, sets `BWRAP_GITCONFIG`; the trap removes it.

- [ ] **Step 1: Write the failing test**

```bash
# bwrap git: wrapper rebound at /usr/local/bin/git; generated system config.
GITPREP_DIR="$(mktemp -d)"
PROFILE_TMP_DIRS+=("$GITPREP_DIR")
SANDBOX_COMPOSE_DIR="$GITPREP_DIR/data"
mkdir -p "$SANDBOX_COMPOSE_DIR"
printf '#!/bin/sh\n' > "$SANDBOX_COMPOSE_DIR/git-wrapper"
SANDBOX_HOME="/home/tester"
BWRAP_HOME="/host/tester"
BWRAP_GITCONFIG=""
bwrap_prepare_git
GIT_JOINED="$(printf '<%s>' "${BWRAP_GIT_ARGS[@]}")"
[[ "$GIT_JOINED" == *"<--ro-bind><$SANDBOX_COMPOSE_DIR/git-wrapper></usr/local/bin/git>"* ]] &&
  ok "bwrap git: wrapper rebound at /usr/local/bin/git" || bad "bwrap git: wrapper rebind ($GIT_JOINED)"
[[ "$GIT_JOINED" == *"<$BWRAP_GITCONFIG></etc/gitconfig>"* ]] &&
  ok "bwrap git: generated system config bound" || bad "bwrap git: generated config ($GIT_JOINED)"
[[ -n "$BWRAP_GITCONFIG" && -f "$BWRAP_GITCONFIG" ]] &&
  ok "bwrap git: generated config file exists" || bad "bwrap git: generated config file"
grep -q "insteadOf" "$BWRAP_GITCONFIG" &&
  ok "bwrap git: config blocks remote URLs" || bad "bwrap git: config blocks remote URLs"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/launcher/test.sh 2>&1 | tail -20`
Expected: FAIL — function not defined.

- [ ] **Step 3: Write the implementation**

Add after `bwrap_prepare_base`:

```bash
# Rebind the existing git wrapper over the host git inside the namespace and
# generate a read-only system gitconfig that blocks SSH pushes and rewrites
# GitHub URLs (the bwrap analogue of the Docker entrypoint's /usr/bin/git
# config --system). Populates BWRAP_GIT_ARGS and BWRAP_GITCONFIG.
bwrap_prepare_git() {
  BWRAP_GIT_ARGS=(
    --ro-bind "$SANDBOX_COMPOSE_DIR/git-wrapper" /usr/local/bin/git
  )
  BWRAP_GITCONFIG="$(mktemp)"
  cat > "$BWRAP_GITCONFIG" <<'EOF'
[core]
	sshCommand = echo "[SECURITY] Remote push operations are prohibited inside this sandbox." && false
[url "https://prohibited/"]
	insteadOf = https://github.com/
[url "https://prohibited/"]
	insteadOf = git@github.com:
EOF
  BWRAP_GIT_ARGS+=(--ro-bind "$BWRAP_GITCONFIG" /etc/gitconfig)
  return 0
}
```

Update the exit trap in main (line ~890) so it also removes `BWRAP_GITCONFIG`:

```bash
trap 'progress_stop; if [[ "$SERVE_STARTED" != true ]]; then if [[ -n "$POLICY_FILE" ]]; then rm -f -- "$POLICY_FILE"; fi; if [[ -n "$MCP_CONFIG_FILE" ]]; then rm -f -- "$MCP_CONFIG_FILE"; fi; if [[ -n "${BWRAP_GITCONFIG:-}" ]]; then rm -f -- "$BWRAP_GITCONFIG"; fi; if [[ -n "$SERVE_STATE_DIR" ]]; then rmdir -- "$SERVE_STATE_DIR" 2>/dev/null || true; fi; fi' EXIT
```

Initialize `BWRAP_GITCONFIG=""` next to `POLICY_FILE=""` (line ~886).

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/launcher/test.sh 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add bin/ai-sandbox tests/launcher/test.sh
git commit -m "feat(runtime): rebind git wrapper and system config under bwrap"
```

---

### Task 8: Assemble and run the bwrap backend

**Files:**
- Modify: `bin/ai-sandbox` (replace `run_bwrap_agent`; add `bwrap_resolve_host_tool`, `bwrap_prepare_env`; wire config resolution and version-pin warning in main)
- Test: `tests/launcher/test.sh`

**Interfaces:**
- Consumes: all preparation globals and the `*_VOLUME_ARGS`/`*_ENV_ARGS` arrays; `SELECTED_TOOL`, `TOOL_DEFAULT_ARGS`, `TOOL_USER_ARGS`, `WORKSPACE_DIR`, `SANDBOX_COMPOSE_DIR`.
- Produces: `bwrap_resolve_host_tool TOOL` → printable absolute path or non-zero; `bwrap_prepare_env` → fills `BWRAP_BASE_ENV`; `run_bwrap_agent` executes the assembled command.

- [ ] **Step 1: Write the failing test**

```bash
# bwrap run assembly: a stub bwrap captures the full argv.
RUN_DIR="$(mktemp -d)"
PROFILE_TMP_DIRS+=("$RUN_DIR")
mkdir -p "$RUN_DIR/bin" "$RUN_DIR/state" "$RUN_DIR/home"
printf '#!/bin/sh\nprintf "%%s\\0" "$@" > "$BWRAP_CAPTURE"\n' > "$RUN_DIR/bin/bwrap"
chmod +x "$RUN_DIR/bin/bwrap"
printf '#!/bin/sh\necho "claude 9.9.9"\n' > "$RUN_DIR/bin/claude"
chmod +x "$RUN_DIR/bin/claude"
SELECTED_TOOL=claude
TOOL_DEFAULT_ARGS=(--dangerously-skip-permissions)
TOOL_USER_ARGS=(--resume)
WORKSPACE_DIR="$RUN_DIR/ws"
mkdir -p "$WORKSPACE_DIR"
SANDBOX_HOME="/home/tester"
SANDBOX_COMPOSE_DIR="$SCRIPT_DIR/../../share/ai-sandbox"
XDG_STATE_HOME="$RUN_DIR/state"
HOME="$RUN_DIR/home"
READ_HOME=false
TOOL_VOLUME_ARGS=(); TOOL_ENV_ARGS=(); PROXY_ENV_ARGS=(); HOST_SETTINGS_ENV_ARGS=()
HOST_SETTINGS_VOLUME_ARGS=(); GIT_ENV_ARGS=(); GIT_MODE_ENV_ARGS=(); GIT_VOLUME_ARGS=()
GIT_POLICY_VOLUME_ARGS=(); BROWSER_ENV_ARGS=(); BROWSER_VOLUME_ARGS=(); EXTRA_MOUNT_VOLUME_ARGS=()
BWRAP_GITCONFIG=""
BWRAP_CAPTURE="$RUN_DIR/bwrap.args" \
PATH="$RUN_DIR/bin:$PATH" run_bwrap_agent
mapfile -d '' -t CAPTURED_BWRAP < "$RUN_DIR/bwrap.args"
JOINED="$(printf '<%s>' "${CAPTURED_BWRAP[@]}")"
[[ "$JOINED" == *"<--unshare-all><--share-net>"* ]] &&
  ok "bwrap run: namespaces present" || bad "bwrap run: namespaces ($JOINED)"
[[ "$JOINED" == *"<--setenv><IS_SANDBOX><1>"* ]] &&
  ok "bwrap run: IS_SANDBOX set" || bad "bwrap run: IS_SANDBOX ($JOINED)"
[[ "$JOINED" == *"<--chdir><$WORKSPACE_DIR>"* ]] &&
  ok "bwrap run: chdir to workspace" || bad "bwrap run: chdir ($JOINED)"
[[ "$JOINED" == *"<$RUN_DIR/bin/claude><--dangerously-skip-permissions><--resume>"* ]] &&
  ok "bwrap run: host tool with defaults then user args" || bad "bwrap run: command ($JOINED)"

# Missing host tool is reported before bwrap runs.
EMPTY_RUN="$RUN_DIR/emptybin"
mkdir -p "$EMPTY_RUN"
PATH="$RUN_DIR/bin:$PATH" SELECTED_TOOL=nonexistent \
  bwrap_resolve_host_tool nonexistent >/dev/null 2>&1 && code=0 || code=$?
[[ $code -ne 0 ]] && ok "bwrap run: missing host tool is rejected" || bad "bwrap run: missing host tool"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/launcher/test.sh 2>&1 | tail -20`
Expected: FAIL — `run_bwrap_agent` is the placeholder; `bwrap_resolve_host_tool` undefined.

- [ ] **Step 3: Write the implementation**

Replace the `run_bwrap_agent` placeholder and add helpers:

```bash
# Resolve the selected tool to an absolute host path. Prints the path and
# returns 0, or prints an error and returns 1 when the tool is not installed.
bwrap_resolve_host_tool() {  # TOOL
  local tool="$1" path
  path="$(command -v "$tool" 2>/dev/null)" || true
  if [[ -z "$path" ]]; then
    echo "ai-sandbox: '$tool' is not installed on the host; --runtime bwrap runs the host CLI. Install it or use --runtime docker." >&2
    return 1
  fi
  printf '%s' "$path"
}

# Base sandbox environment. The host environment is cleared so the sandbox sees
# the same minimal, explicit set the Docker container does.
bwrap_prepare_env() {
  BWRAP_BASE_ENV=(
    --clearenv
    --setenv HOME "$BWRAP_HOME"
    --setenv PATH "/usr/local/bin:$BWRAP_HOST_PATH"
    --setenv TERM "${TERM:-dumb}"
    --setenv SHELL "${SHELL:-/bin/sh}"
    --setenv USER "$(id -un)"
    --setenv LOGNAME "$(id -un)"
    --setenv TMPDIR /tmp
    --setenv IS_SANDBOX 1
  )
  return 0
}

# Run the selected agent on the host inside a bwrap namespace sandbox.
run_bwrap_agent() {
  local tool_path
  tool_path="$(bwrap_resolve_host_tool "$SELECTED_TOOL")" || { launcher_error "host tool '${SELECTED_TOOL}' not found"; return 2; }

  BWRAP_HOST_PATH="${PATH}"
  bwrap_prepare_base
  bwrap_prepare_git
  bwrap_translate_mounts \
    "${TOOL_VOLUME_ARGS[@]}" "${GIT_VOLUME_ARGS[@]}" "${GIT_POLICY_VOLUME_ARGS[@]}" \
    "${HOST_SETTINGS_VOLUME_ARGS[@]}" "${BROWSER_VOLUME_ARGS[@]}" "${EXTRA_MOUNT_VOLUME_ARGS[@]}"
  bwrap_prepare_env
  bwrap_translate_env \
    "${TOOL_ENV_ARGS[@]}" "${GIT_ENV_ARGS[@]}" "${GIT_MODE_ENV_ARGS[@]}" \
    "${PROXY_ENV_ARGS[@]}" "${HOST_SETTINGS_ENV_ARGS[@]}" "${BROWSER_ENV_ARGS[@]}"

  bwrap \
    "${BWRAP_BASE_ARGS[@]}" \
    "${BWRAP_GIT_ARGS[@]}" \
    "${BWRAP_MOUNT_ARGS[@]}" \
    "${BWRAP_BASE_ENV[@]}" \
    "${BWRAP_TRANSLATED_ENV[@]}" \
    --chdir "$WORKSPACE_DIR" \
    "$tool_path" "${TOOL_DEFAULT_ARGS[@]}" "${TOOL_USER_ARGS[@]}"
}
```

In the main guard, when the runtime is bwrap, resolve the bwrap config knobs and warn on an ignored version pin, before dispatch:

```bash
if [[ "$RUNTIME" == bwrap ]]; then
  BWRAP_GITCONFIG=""
  SANDBOX_BWRAP_PASSTHROUGH="$(resolve_list SANDBOX_BWRAP_PASSTHROUGH .bwrap.passthrough)"
  SANDBOX_BWRAP_DENY="$(resolve_list SANDBOX_BWRAP_DENY .bwrap.deny)"
  case "$SELECTED_TOOL" in
    claude) [[ -n "${CLAUDE_VERSION:-}${CLI_TOOL_VERSION:-}" ]] && warn_msg "version pins are ignored under --runtime bwrap; the host $SELECTED_TOOL is used." ;;
    codex)  [[ -n "${CODEX_VERSION:-}${CLI_TOOL_VERSION:-}" ]] && warn_msg "version pins are ignored under --runtime bwrap; the host $SELECTED_TOOL is used." ;;
    opencode) [[ -n "${OPENCODE_VERSION:-}${CLI_TOOL_VERSION:-}" ]] && warn_msg "version pins are ignored under --runtime bwrap; the host $SELECTED_TOOL is used." ;;
  esac
  progress_stop
  echo "ai-sandbox: launching $SELECTED_TOOL on the host (bwrap)..." >&2
fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/launcher/test.sh 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add bin/ai-sandbox tests/launcher/test.sh
git commit -m "feat(runtime): assemble and run the bwrap agent backend"
```

---

### Task 9: Configuration, help, completions, and docs

**Files:**
- Modify: `bin/ai-sandbox` (`print_help`)
- Modify: `share/ai-sandbox/config.example.yaml`
- Modify: `share/ai-sandbox/completions/ai-sandbox.bash`
- Modify: `share/ai-sandbox/completions/_ai-sandbox`
- Modify: `README.md`, `docs/configuration.md`, `docs/architecture.md`, `docs/development.md`, `docs/tradeoffs.md`
- Test: `tests/launcher/test.sh` (help + completion assertions)

**Interfaces:**
- Consumes: nothing.
- Produces: user-facing documentation of `--runtime`, `--read-home`, and the `bwrap.*` keys.

- [ ] **Step 1: Write the failing test**

Add to `tests/launcher/test.sh` in the help and completion sections:

```bash
[[ "$HELP_OUT" == *"--runtime"* && "$HELP_OUT" == *"--read-home"* ]] &&
  ok "help: runtime options documented" || bad "help: runtime options documented"
```

and in the bash-completion block:

```bash
COMP_WORDS=("ai-sandbox" "--"); COMP_CWORD=1
_ai_sandbox
COMPLETION_JOINED="$(printf '%s' "${COMPREPLY[@]}")"
[[ "$COMPLETION_JOINED" == *"--runtime"* && "$COMPLETION_JOINED" == *"--read-home"* ]] &&
  ok "completion: runtime options included" || bad "completion: runtime options included"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/launcher/test.sh 2>&1 | tail -20`
Expected: FAIL — help/completion do not mention the new options.

- [ ] **Step 3: Write the implementation**

In `print_help` (after the `--git-preset` block, line ~94), add:

```
  --runtime <docker|bwrap>         Sandbox backend (default: docker). bwrap
                                   runs the host's own toolchain in a user
                                   namespace; Docker re-acquires it in an image.
  --read-home                      bwrap only: make the whole real home
                                   readable (writes still go to a per-workspace
                                   layer). Default: off.
```

Update `share/ai-sandbox/completions/ai-sandbox.bash`: add `--runtime` to the `--opt=`-aware `prev` case with values `docker bwrap`, add `--runtime --read-home` to both option word lists (serve list stays Docker-only; add `--runtime --read-home` only to the non-serve list). Update `_ai-sandbox` similarly with `'--runtime=[Sandbox backend]:backend:(docker bwrap)'` and `'--read-home[Make the whole home readable]'` in the non-serve `opts` array.

Update `share/ai-sandbox/config.example.yaml` after the `tool:` block:

```yaml
# Sandbox backend. docker (default) runs the agent in an image container and
# re-acquires its toolchain; bwrap runs the host's own toolchain in an
# unprivileged user-namespace sandbox, with writes confined to the workspace and
# a persistent per-workspace home layer. Supported: docker, bwrap.
# Env override: SANDBOX_RUNTIME. CLI: --runtime.
# runtime: docker

bwrap:
  # Extra host paths to make visible inside the sandbox, read-only by default.
  # Entries are HOST or HOST:rw; they are ADDED to the built-in system and
  # per-user toolchain allowlist. Env override: SANDBOX_BWRAP_PASSTHROUGH.
  # passthrough: []
  # Extra host paths to shadow with an empty view (secrets, credentials),
  # ADDED to the built-in deny list. Only meaningful with read_home: true.
  # Env override: SANDBOX_BWRAP_DENY.
  # deny: []
  # Whether the ENTIRE real home is readable. When false (default) host home
  # content is visible only through the toolchain allowlist and passthrough.
  # When true the real home is the read-only lower layer of the writable
  # per-workspace layer. CLI: --read-home. Env override: SANDBOX_BWRAP_READ_HOME.
  # read_home: false
```

Update the human docs:
- `README.md`: tick "More runtimes", add a "Runtimes" subsection describing `--runtime bwrap`, host-toolchain reuse, the home layer, `--read-home`, and that serve is Docker-only.
- `docs/configuration.md`: add `runtime`, `bwrap.passthrough`, `bwrap.deny`, `bwrap.read_home`.
- `docs/architecture.md`: add a backend-seam section and the bwrap filesystem model and lifecycle.
- `docs/development.md`: add invariants (backend functions outside the main guard; the Docker-command regression lock; the home-layer path contract) and manual test items.
- `docs/tradeoffs.md`: add "Host-integrated namespace backend vs OCI container".

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run-all.sh 2>&1 | tail -15`
Expected: all suites PASS.

- [ ] **Step 5: Commit**

```bash
git add bin/ai-sandbox share/ai-sandbox README.md docs tests/launcher/test.sh
git commit -m "docs(runtime): document bwrap backend, knobs, and completions"
```

---

### Task 10: bwrap integration test suite

**Files:**
- Create: `tests/bwrap/test.sh`
- Modify: `docs/development.md` (manual checklist item referencing the suite)

**Interfaces:**
- Consumes: the built launcher.
- Produces: a real-bwrap integration suite that is skipped when `bwrap` or user namespaces are unavailable.

- [ ] **Step 1: Write the failing test**

Create `tests/bwrap/test.sh`:

```bash
#!/bin/bash
# Integration tests for the bwrap runtime backend. Skipped when bwrap or
# unprivileged user namespaces are unavailable.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER="$SCRIPT_DIR/../../bin/ai-sandbox"
pass=0; fail=0; skip=0
ok() { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
skipmsg() { echo "SKIP: $1"; skip=$((skip+1)); }

if ! command -v bwrap >/dev/null 2>&1; then skipmsg "bwrap not installed"; echo "$pass passed, $fail failed, $skip skipped"; exit 0; fi
if ! bwrap --ro-bind / / --proc /proc --dev /dev --unshare-all --share-net -- /bin/true >/dev/null 2>&1; then
  skipmsg "bwrap cannot create a sandbox here (userns restricted)"; echo "$pass passed, $fail failed, $skip skipped"; exit 0
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
WS="$TMP/ws"; mkdir -p "$WS" "$TMP/home"
# A stub docker must never be called under bwrap.
mkdir -p "$TMP/bin" "$TMP/home"
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/docker"; chmod +x "$TMP/bin/docker"
# A stub host tool so no real agent is needed.
printf '#!/bin/sh\necho "stub-tool $*"\n' > "$TMP/bin/stubtool"; chmod +x "$TMP/bin/stubtool"

run() {
  HOME="$TMP/home" XDG_STATE_HOME="$TMP/home/.local/state" \
  SANDBOX_HOME="$TMP/home" SANDBOX_UID="$(id -u)" SANDBOX_GID="$(id -g)" \
  SANDBOX_USERNAME="$(id -un)" SANDBOX_CLEANUP=false SANDBOX_PROGRESS=false \
  SANDBOX_PROXY_ENV_PASSTHROUGH=false \
  AI_SANDBOX_DIR="$SCRIPT_DIR/../../share/ai-sandbox" \
  PATH="$TMP/bin:$PATH" "$@"
}

# IS_SANDBOX and workspace write confinement.
out="$(run bash "$LAUNCHER" --runtime bwrap --tool claude "$WS" -- 2>&1 || true)"
echo "$out" | grep -q "not installed on the host" \
  && ok "bwrap integration: missing host tool is reported" \
  || bad "bwrap integration: missing host tool message ($out)"

# Real user-namespace confinement via a direct bwrap probe of the launcher's flags.
bwrap --unshare-all --share-net --ro-bind / / --proc /proc --dev /dev --tmpfs /tmp \
  --bind "$WS" "$WS" --chdir "$WS" --setenv IS_SANDBOX 1 -- /bin/sh -c 'echo ok' >/dev/null 2>&1 \
  && ok "bwrap integration: reference sandbox runs" \
  || bad "bwrap integration: reference sandbox runs"

echo "$pass passed, $fail failed, $skip skipped"
[[ $fail -eq 0 ]]
```

Make it executable: `chmod +x tests/bwrap/test.sh`.

- [ ] **Step 2: Run test to verify it fails (or skips)**

Run: `bash tests/bwrap/test.sh`
Expected: on a host without `bwrap`, `SKIP` and exit 0. On a host with `bwrap`, it runs and reports the launcher's missing-host-tool message.

- [ ] **Step 3: Adjust the launcher if the integration reveals a defect**

If the reference sandbox or the missing-tool path fails, fix `bin/ai-sandbox` (for example, ensure `BWRAP_HOME` is set before `bwrap_prepare_base` uses it) and re-run.

- [ ] **Step 4: Run the whole suite**

Run: `bash tests/run-all.sh 2>&1 | tail -15`
Expected: all suites PASS (with `tests/bwrap` skipping when unavailable).

- [ ] **Step 5: Commit**

```bash
git add tests/bwrap/test.sh docs/development.md
git commit -m "test(runtime): add bwrap integration suite"
```

---

## Self-Review

**Spec coverage:**
- Runtime selector + precedence → Task 1.
- Docker unchanged → Task 2 (capture tests).
- bwrap availability/userns → Task 3.
- Existing mount/env specs translated → Tasks 4, 5.
- System allowlist, home layer, per-user toolchain, deny list, runtime dirs → Task 6.
- Git wrapper rebind + generated system gitconfig → Task 7.
- Host-tool run, base env, dispatch, version-pin warning, warm-up skip → Tasks 2, 8.
- `serve` Docker-only, root mode/volume/cleanup Docker-only → Tasks 1, 2.
- Config/CLI/docs/completions → Tasks 1, 9.
- Testing → per-task tests + Task 10 integration.
- Not covered here (planned later): macOS Seatbelt, network isolation, seccomp/Landlock, bwrap `serve`.

**Placeholder scan:** No TBD/TODO; every code step carries the code to write.

**Type consistency:** `bwrap_rewrite_cont_path`, `bwrap_translate_mounts`, `bwrap_translate_env`, `bwrap_prepare_base`, `bwrap_prepare_git`, `bwrap_resolve_host_tool`, `bwrap_prepare_env`, `run_bwrap_agent`, `bwrap_available`, `bwrap_home_layer_path`, `resolve_runtime`, `resolve_read_home` are used consistently; globals `BWRAP_MOUNT_ARGS`, `BWRAP_TRANSLATED_ENV`, `BWRAP_BASE_ARGS`, `BWRAP_GIT_ARGS`, `BWRAP_BASE_ENV`, `BWRAP_LAYER_DIR`, `BWRAP_WORK_DIR`, `BWRAP_HOME`, `BWRAP_HOST_PATH`, `BWRAP_GITCONFIG` are named the same wherever referenced.

**Review Focus tests:** colon-splitting (Task 4 tests `HOST:CONT` and `HOST:ro`); `SANDBOX_HOME`≠`$HOME` rewrite (Task 4); userns failure message (Task 3); missing host tool (Task 8); missing deny path skipped (Task 6).
