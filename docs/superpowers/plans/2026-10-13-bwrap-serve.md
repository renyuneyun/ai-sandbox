# bwrap `serve` / `openchamber` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `asb serve start|stop|attach` and `asb openchamber start|stop` work under `--runtime bwrap`, running a detached OpenCode server in an unprivileged bwrap sandbox with parity to the Docker path.

**Architecture:** A runtime seam for the serve actions. The bwrap backend records a small `serve.state` file; its presence marks a bwrap server, and its absence keeps the existing Docker container-label path byte-identical. The bwrap server is launched detached with `setsid bwrap …` (omitting `--die-with-parent`) and torn down by process-group signal. The server password passes through a `0600` file bound read-only, never argv.

**Tech Stack:** Bash launcher (`bin/ai-sandbox`), bubblewrap, coreutils `setsid`/`kill`, Docker (stubbed in unit tests), Node/`curl` for the readiness probe.

**Spec:** `docs/superpowers/specs/2026-10-13-bwrap-serve-design.md`

## Global Constraints

- Pure shell: no new runtime dependency beyond `bwrap`, `setsid`, `kill`. Node is used for the probe when present; `curl --netrc-file` is the fallback.
- All new functions are defined **outside** the main guard (`if [[ "${BASH_SOURCE[0]}" == "${0}" ]]`), per the testability invariant in `docs/development.md`. `local` is used **only** inside functions — never in main-guard snippets.
- Credentials never appear in **any** process argv. Docker keeps `-e NAME`; bwrap uses a `0600` state-dir file bound read-only and read into the env by an inner `sh -c` immediately before `exec`.
- `--die-with-parent` is dropped **only** for the detached server; every interactive bwrap run (including `serve attach`) keeps it.
- Generated files a detached server depends on (`gitconfig`, credential file, log, pgid file) live under `$SERVE_STATE_DIR` so `serve stop` removes them.
- The Docker `serve`/`openchamber` rendered commands are **byte-identical** to today; `tests/serve` and `tests/openchamber` are the regression lock.
- `bash tests/run-all.sh` must stay green (7 suites).
- Docs in sync per the checklist in `docs/development.md`.

## Review Focus

- A `serve stop` run with the default `--runtime docker` against a bwrap-started server must stop the bwrap server (the `serve.state` file marks it as bwrap, so the Docker path is not taken).
- A workspace whose bwrap server is gone (stale `serve.state`, no live PGID) must read as a **stopped** server: `serve start` refuses with the actionable message; `serve stop` cleans up and reports stopped.
- A server password containing quotes/`$`/spaces must not break the inner `sh -c` wrapper nor leak into argv or `ps`.
- `--hostname` of `0.0.0.0`, `::`, or a specific non-loopback IP must still produce a reachable probe target.
- `openchamber start --runtime bwrap` when the host OpenCode is v1 must refuse with the OpenCode 2.0.20+ message (the UI would otherwise be broken).

---

## File Structure

| File | Responsibility |
|---|---|
| `bin/ai-sandbox` | The launcher. Add the state helpers, the bwrap assembly/run split, the bwrap serve functions, and the runtime dispatch. |
| `tests/serve/test.sh` | Stub-`docker` + stub-`bwrap` unit tests: state file, detached argv, stop/attach dispatch, password-not-in-argv. |
| `tests/openchamber/test.sh` | openchamber under bwrap: reuse via state, host-version check. |
| `tests/bwrap/test.sh` | Real-bwrap integration: detached lifecycle with a fake `opencode`. |
| `README.md`, `docs/architecture.md`, `docs/configuration.md`, `docs/development.md` | Documentation. |

---

## Task 1: Extract bwrap sandbox assembly; add detached mode

**Files:**
- Modify: `bin/ai-sandbox` (`run_bwrap_agent`, `bwrap_prepare_base`, `bwrap_prepare_git`)
- Test: `tests/bwrap/test.sh`

**Interfaces:**
- Produces: `bwrap_assemble TOOL_PATH ARGS...` → sets `BWRAP_ALL_ARGS`; honors globals `BWRAP_DETACHED` (bool) and `BWRAP_GENERATED_DIR` (dir for generated files). `run_bwrap_agent` keeps its behavior.

- [ ] **Step 1: Write the failing test**

In `tests/bwrap/test.sh`, add before the summary line (the file already sets `ROOT`, `LAUNCHER`, `TMP`, `WS`, `ok`, `bad`):

```bash
# --- interactive argv keeps --die-with-parent (regression) ---
mkdir -p "$TMP/stub"
cat > "$TMP/stub/bwrap" <<'EOF'
#!/usr/bin/env bash
printf '%s\0' "$@" > "$BWRAP_ARGS_OUT"
exit 0
EOF
chmod +x "$TMP/stub/bwrap"
ARGS="$TMP/bwrap-args"
env HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/home/.config" \
    PATH="$TMP/stub:$PATH" BWRAP_ARGS_OUT="$ARGS" \
    SANDBOX_PROGRESS=false SANDBOX_CLEANUP=false SANDBOX_UID=1234 SANDBOX_GID=1234 \
    SANDBOX_USERNAME=tester SANDBOX_HOME=/home/tester \
    SANDBOX_BWRAP_READ_HOME=false AI_SANDBOX_DIR="$ROOT/share/ai-sandbox" \
    bash "$LAUNCHER" --runtime bwrap "$WS" >/dev/null 2>&1
if tr '\0' ' ' < "$ARGS" | grep -q -- '--die-with-parent'; then
    ok "bwrap interactive argv keeps --die-with-parent"
else
    bad "bwrap interactive argv lost --die-with-parent: $(tr '\0' ' ' < "$ARGS")"
fi
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/bwrap/test.sh`
Expected: the new check FAILS/errors because the stub invocation path is assembled inline (no `bwrap_assemble`), and if bwrap is unavailable the whole suite SKIPs.

- [ ] **Step 3: Add `BWRAP_DETACHED` to `bwrap_prepare_base`**

Replace the first line of `bwrap_prepare_base`:

```bash
  BWRAP_BASE_ARGS=(--unshare-all --share-net)
  [[ "${BWRAP_DETACHED:-false}" == "true" ]] || BWRAP_BASE_ARGS+=(--die-with-parent)
```

- [ ] **Step 4: Honor `BWRAP_GENERATED_DIR` in `bwrap_prepare_git`**

Replace `BWRAP_GITCONFIG="$(mktemp)"` with:

```bash
  if [[ -n "${BWRAP_GENERATED_DIR:-}" ]]; then
    BWRAP_GITCONFIG="$(mktemp "$BWRAP_GENERATED_DIR/gitconfig.XXXXXX")"
  else
    BWRAP_GITCONFIG="$(mktemp)"
  fi
```

- [ ] **Step 5: Extract `bwrap_assemble` and rewrite `run_bwrap_agent`**

Replace the whole `run_bwrap_agent` with:

```bash
# Assemble the bwrap argv for TOOL_PATH and its arguments into BWRAP_ALL_ARGS.
# Honors BWRAP_DETACHED (omit --die-with-parent) and BWRAP_GENERATED_DIR
# (where generated, sandbox-bound files are written).
bwrap_assemble() {  # TOOL_PATH ARGS...
  local tool_path="$1"; shift
  BWRAP_HOST_PATH="${PATH}"
  bwrap_prepare_base
  bwrap_prepare_git
  bwrap_translate_mounts \
    "${TOOL_VOLUME_ARGS[@]}" "${GIT_VOLUME_ARGS[@]}" \
    "${EXTRA_MOUNT_VOLUME_ARGS[@]}"
  local -a extra_env=()
  if [[ -n "${POLICY_FILE:-}" ]]; then
    BWRAP_MOUNT_ARGS+=(--ro-bind "$POLICY_FILE" /run/ai-sandbox/git-policy.conf)
    extra_env+=(--setenv GIT_POLICY_FILE /run/ai-sandbox/git-policy.conf)
  fi
  if [[ -n "${MCP_CONFIG_FILE:-}" ]]; then
    BWRAP_MOUNT_ARGS+=(--ro-bind "$MCP_CONFIG_FILE" /run/ai-sandbox/mcp-config.json)
  fi
  bwrap_prepare_env
  bwrap_translate_env \
    "${TOOL_ENV_ARGS[@]}" "${GIT_ENV_ARGS[@]}" "${GIT_MODE_ENV_ARGS[@]}" \
    "${PROXY_ENV_ARGS[@]}" "${HOST_SETTINGS_ENV_ARGS[@]}" "${BROWSER_ENV_ARGS[@]}"
  BWRAP_ALL_ARGS=(
    "${BWRAP_BASE_ARGS[@]}"
    "${BWRAP_GIT_ARGS[@]}"
    "${BWRAP_MOUNT_ARGS[@]}"
    "${BWRAP_BASE_ENV[@]}"
    "${BWRAP_TRANSLATED_ENV[@]}"
    "${extra_env[@]}"
    --chdir "$WORKSPACE_DIR"
    "$tool_path" "$@"
  )
}

run_bwrap_agent() {
  local tool_path
  tool_path="$(bwrap_resolve_host_tool "$SELECTED_TOOL")" || { launcher_error "host tool '${SELECTED_TOOL}' not found"; return 2; }

  # Rewrite the fixed /etc/ai-sandbox MCP-config path to the relocated one.
  local -a tool_args=() a
  for a in "${TOOL_DEFAULT_ARGS[@]}"; do
    if [[ "$a" == "/etc/ai-sandbox/mcp-config.json" ]]; then
      tool_args+=("/run/ai-sandbox/mcp-config.json")
    else
      tool_args+=("$a")
    fi
  done

  bwrap_assemble "$tool_path" "${tool_args[@]}" "${TOOL_USER_ARGS[@]}"
  bwrap "${BWRAP_ALL_ARGS[@]}"
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bash tests/bwrap/test.sh`
Expected: the new check passes; existing integration checks pass or SKIP.

- [ ] **Step 7: Commit**

```bash
git add bin/ai-sandbox tests/bwrap/test.sh
git commit -m "refactor(bwrap): extract sandbox assembly and add detached mode"
```

---

## Task 2: `serve start --runtime bwrap`

**Files:**
- Modify: `bin/ai-sandbox` (remove the bwrap-serve rejection; add `serve_state_write/get`, `serve_resolve_shape`, `serve_bwrap_pw_var`, `serve_probe_bwrap`, `serve_start_bwrap`; extend `bwrap_assemble`; route the start block)
- Test: `tests/serve/test.sh`

**Interfaces:**
- Consumes: `bwrap_assemble` (Task 1).
- Produces: `serve_state_write KEY=VALUE...`, `serve_state_get KEY`, `serve_resolve_shape` (sets `SERVER_PACKAGE` `SERVER_COMMAND` `SERVE_HEALTH_PATH`), `serve_bwrap_pw_var PACKAGE`, `serve_probe_bwrap PW`, `serve_start_bwrap`.

- [ ] **Step 1: Write the failing tests**

Add stubs and a `run_bwrap` helper to `tests/serve/test.sh`, after the `run_launcher` definition:

```bash
cat > "$TMP/bin/bwrap" <<'EOF'
#!/usr/bin/env bash
printf '%s\0' "$@" >> "$BWRAP_CALLS"; printf '\n' >> "$BWRAP_CALLS"
exit 0
EOF
cat > "$TMP/bin/opencode" <<'EOF'
#!/usr/bin/env bash
echo "opencode v${OPENCODE_STUB_VERSION:-2.0.26}"
EOF
cat > "$TMP/bin/node" <<'EOF'
#!/usr/bin/env bash
exit "${NODE_STUB_RC:-0}"
EOF
chmod +x "$TMP/bin/bwrap" "$TMP/bin/opencode" "$TMP/bin/node"

run_bwrap() {  # ARGS...
  : > "$TMP/bwcalls"
  env HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/home/.config" \
    PATH="$TMP/bin:$PATH" BWRAP_CALLS="$TMP/bwcalls" \
    SANDBOX_PROGRESS=false SANDBOX_CLEANUP=false \
    SANDBOX_UID=1234 SANDBOX_GID=1234 SANDBOX_USERNAME=tester SANDBOX_HOME=/home/tester \
    OPENCODE_STUB_VERSION="${OPENCODE_STUB_VERSION:-2.0.26}" \
    NODE_STUB_RC="${NODE_STUB_RC:-0}" \
    OPENCODE_PASSWORD="${TEST_PASSWORD-test password}" \
    AI_SANDBOX_DIR="$ROOT/share/ai-sandbox" \
    bash "$LAUNCHER" "$@" >"$TMP/out" 2>"$TMP/err"
}

serve_state_path() {
  local h
  h="$(printf '%s' "$TMP/project" | git hash-object --stdin)"
  printf '%s/ai-sandbox/serve/ai-sandbox-serve-1234-%s/serve.state' \
    "$TMP/home/.local/state" "${h:0:12}"
}

# --- serve start --runtime bwrap: detached, no --die-with-parent, state written ---
if run_bwrap serve start --runtime bwrap --tool opencode --hostname 0.0.0.0 --port 4096 "$TMP/project"; then
  sf="$(serve_state_path)"; ok=1
  tr '\0' ' ' < "$TMP/bwcalls" | grep -q -- '--unshare-all' || ok=0
  ! tr '\0' ' ' < "$TMP/bwcalls" | grep -q -- '--die-with-parent' || ok=0
  tr '\0' ' ' < "$TMP/bwcalls" | grep -q -- 'serve --hostname 0.0.0.0 --port 4096' || ok=0
  grep -qx 'runtime=bwrap' "$sf" 2>/dev/null || ok=0
  grep -q '^pgid=' "$sf" 2>/dev/null || ok=0
  if [[ "$ok" == 1 ]]; then echo 'PASS: bwrap serve start is detached with state'
  else echo "FAIL: bwrap serve argv/state: $(tr '\0' ' ' < "$TMP/bwcalls") | $(cat "$sf" 2>/dev/null)"; fail=1; fi
else
  echo "FAIL: bwrap serve start failed: $(cat "$TMP/err")"; fail=1
fi
bash "$LAUNCHER" serve stop --tool opencode "$TMP/project" >/dev/null 2>&1 || true
rm -rf "$TMP/home/.local/state"

# --- the password value never appears in any argv ---
if run_bwrap serve start --runtime bwrap --tool opencode "$TMP/project"; then :; fi
if tr '\0' '\n' < "$TMP/bwcalls" | grep -q 'test password'; then
  echo 'FAIL: server password leaked into bwrap argv'; fail=1
else
  echo 'PASS: server password is absent from bwrap argv'
fi
bash "$LAUNCHER" serve stop --tool opencode "$TMP/project" >/dev/null 2>&1 || true
rm -rf "$TMP/home/.local/state"

# --- v1 host version selects web + /global/health ---
OPENCODE_STUB_VERSION=1.18.31
if run_bwrap serve start --runtime bwrap --tool opencode "$TMP/project"; then
  if tr '\0' ' ' < "$TMP/bwcalls" | grep -q ' web --hostname'; then
    echo 'PASS: bwrap v1 uses the web command'
  else echo "FAIL: bwrap v1 command: $(tr '\0' ' ' < "$TMP/bwcalls")"; fail=1; fi
else
  echo "FAIL: bwrap v1 start failed: $(cat "$TMP/err")"; fail=1
fi
unset OPENCODE_STUB_VERSION
bash "$LAUNCHER" serve stop --tool opencode "$TMP/project" >/dev/null 2>&1 || true
rm -rf "$TMP/home/.local/state"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/serve/test.sh`
Expected: the bwrap checks FAIL — `serve start --runtime bwrap` currently errors "available only with --runtime docker".

- [ ] **Step 3: Remove the bwrap-serve rejection**

Delete:

```bash
if [[ -n "$SERVE_ACTION" && "$RUNTIME" == bwrap ]]; then
  launcher_error "serve and openchamber are available only with --runtime docker in this release"; exit 2
fi
```

- [ ] **Step 4: Add the state, shape, probe, and start functions (outside the main guard)**

Insert after the `openchamber_*` helpers (before `# --- Main execution`):

```bash
# --- Serve runtime state (bwrap backend) ---

# Write the bwrap server record for this workspace. Arguments are KEY=VALUE
# pairs; the file is replaced atomically so a reader never sees a partial record.
serve_state_write() {  # KEY=VALUE...
  [[ -n "$SERVE_STATE_DIR" ]] || return 1
  mkdir -p -m 700 "$SERVE_STATE_DIR" || return 1
  local tmp
  tmp="$(mktemp "$SERVE_STATE_DIR/.state.XXXXXX")" || return 1
  printf '%s\n' "$@" > "$tmp"
  mv -f -- "$tmp" "$SERVE_STATE_DIR/serve.state"
}

# Print the value of KEY from the record. Returns 1 when it is absent.
serve_state_get() {  # KEY
  local line
  [[ -f "$SERVE_STATE_DIR/serve.state" ]] || return 1
  while IFS= read -r line; do
    case "$line" in
      "$1="*) printf '%s' "${line#*=}"; return 0 ;;
    esac
  done < "$SERVE_STATE_DIR/serve.state"
  return 1
}

# Populate SERVER_PACKAGE, SERVER_COMMAND, and SERVE_HEALTH_PATH for the
# resolved runtime. Docker uses the requested package; bwrap uses the host
# OpenCode version (pins are ignored, matching interactive bwrap).
serve_resolve_shape() {
  case "$RUNTIME" in
    bwrap)
      local hv; hv="$(detect_host_version opencode)"
      case "${hv#v}" in
        ''|1|1.*)
          SERVER_PACKAGE="opencode-ai${hv:+@$hv}"
          SERVER_COMMAND=web
          [[ "$SERVE_HEADLESS" == true ]] && SERVER_COMMAND=serve
          SERVE_HEALTH_PATH=/global/health
          ;;
        *)
          SERVER_PACKAGE="@opencode/cli${hv:+@$hv}"
          SERVER_COMMAND=serve
          SERVE_HEALTH_PATH=/api/info
          ;;
      esac
      ;;
    *)
      SERVER_PACKAGE="$TOOL_PACKAGE"
      case "$TOOL_PACKAGE" in
        opencode-ai*)
          SERVER_COMMAND=web
          [[ "$SERVE_HEADLESS" == true ]] && SERVER_COMMAND=serve
          SERVE_HEALTH_PATH=/global/health
          ;;
        @opencode/cli*)
          SERVER_COMMAND=serve
          SERVE_HEALTH_PATH=/api/info
          ;;
      esac
      ;;
  esac
}

# The env var the sandboxed server reads its password from (mirrors Docker's
# choice): v1 uses OPENCODE_SERVER_PASSWORD; v2 uses OPENCODE_SERVER_PASSWORD
# when the user set that, else OPENCODE_PASSWORD.
serve_bwrap_pw_var() {  # PACKAGE
  case "$1" in
    opencode-ai*) printf '%s' OPENCODE_SERVER_PASSWORD ;;
    *) if [[ -n "${OPENCODE_SERVER_PASSWORD:-}" ]]; then printf '%s' OPENCODE_SERVER_PASSWORD; else printf '%s' OPENCODE_PASSWORD; fi ;;
  esac
}

# Probe a detached bwrap server on loopback until it answers or the process
# dies. PW is supplied through the environment, never argv. Returns 0 when ready.
serve_probe_bwrap() {  # PW
  local pw="$1" url_host="$SERVE_HOSTNAME"
  case "$url_host" in ""|0.0.0.0) url_host=127.0.0.1 ;; "::") url_host="::1" ;; esac
  local attempt
  for ((attempt=0; attempt<20; attempt++)); do
    if [[ -n "${SERVE_PGID:-}" ]] && ! kill -0 -- "-$SERVE_PGID" 2>/dev/null; then
      return 1
    fi
    if command -v node >/dev/null 2>&1; then
      if OPENCODE_SERVER_PASSWORD="$pw" OPENCODE_PASSWORD="$pw" \
         OPENCODE_SERVER_USERNAME="${OPENCODE_SERVER_USERNAME:-opencode}" node -e '
        let host = process.argv[1]
        if (host.includes(":") && !host.startsWith("[")) host = `[${host}]`
        const url = `http://${host}:${process.argv[2]}${process.argv[3]}`
        const username = process.env.OPENCODE_SERVER_USERNAME || "opencode"
        const password = process.env.OPENCODE_SERVER_PASSWORD || process.env.OPENCODE_PASSWORD || ""
        const auth = "Basic " + Buffer.from(`${username}:${password}`).toString("base64")
        fetch(url, {headers: {Authorization: auth}, signal: AbortSignal.timeout(1000)})
          .then(r => process.exit(r.ok ? 0 : 1)).catch(() => process.exit(1))
      ' "$url_host" "$SERVE_PORT" "$SERVE_HEALTH_PATH" >/dev/null 2>&1; then
        return 0
      fi
    elif command -v curl >/dev/null 2>&1; then
      local netrc; netrc="$(mktemp "$SERVE_STATE_DIR/.netrc.XXXXXX")"
      chmod 600 "$netrc"
      printf 'machine %s login %s password %s\n' \
        "$url_host" "${OPENCODE_SERVER_USERNAME:-opencode}" "$pw" > "$netrc"
      if curl -sf --netrc-file "$netrc" --max-time 2 \
           "http://$url_host:$SERVE_PORT$SERVE_HEALTH_PATH" >/dev/null 2>&1; then
        rm -f "$netrc"; return 0
      fi
      rm -f "$netrc"
    fi
    sleep 1
  done
  return 1
}

# Start a detached OpenCode server under bwrap. Returns 0 when ready.
serve_start_bwrap() {
  bwrap_available || return 1
  local tool_path; tool_path="$(bwrap_resolve_host_tool opencode)" || return 1
  serve_resolve_shape

  local pwfile="$SERVE_STATE_DIR/server-password" pw
  case "$SERVER_PACKAGE" in
    opencode-ai*) pw="${OPENCODE_SERVER_PASSWORD:-}" ;;
    *) pw="${OPENCODE_SERVER_PASSWORD:-${OPENCODE_PASSWORD:-}}" ;;
  esac
  printf '%s' "$pw" > "$pwfile"
  chmod 600 "$pwfile"
  local pw_var; pw_var="$(serve_bwrap_pw_var "$SERVER_PACKAGE")"

  SANDBOX_BWRAP_PASSTHROUGH="$(resolve_list SANDBOX_BWRAP_PASSTHROUGH .bwrap.passthrough)"
  SANDBOX_BWRAP_DENY="$(resolve_list SANDBOX_BWRAP_DENY .bwrap.deny)"
  BWRAP_DETACHED=true
  BWRAP_GENERATED_DIR="$SERVE_STATE_DIR"
  BWRAP_SERVER_PASSWORD_FILE="$pwfile"
  bwrap_assemble /bin/sh -c \
    "export $pw_var=\"\$(cat /run/ai-sandbox/server-password)\"; exec \"\$0\" \"\$@\"" \
    "$tool_path" "$SERVER_COMMAND" --hostname "$SERVE_HOSTNAME" --port "$SERVE_PORT"

  local log="$SERVE_STATE_DIR/server.log" pgidfile="$SERVE_STATE_DIR/server.pgid"
  rm -f "$pgidfile"
  setsid sh -c 'echo $$ > "$1"; shift; exec "$@"' _ "$pgidfile" bwrap "${BWRAP_ALL_ARGS[@]}" \
    </dev/null >>"$log" 2>&1 &
  local i
  for ((i=0; i<100; i++)); do [[ -s "$pgidfile" ]] && break; sleep 0.02; done
  SERVE_PGID="$(cat "$pgidfile" 2>/dev/null || true)"
  if [[ -z "$SERVE_PGID" ]]; then
    launcher_error "failed to start the bwrap server; see $log"
    return 1
  fi
  SERVE_STARTED=true

  if ! serve_probe_bwrap "$pw"; then
    launcher_error "OpenCode server did not become ready; see the OpenCode log and $log, then use 'asb serve stop'"
    return 1
  fi

  serve_state_write \
    "runtime=bwrap" \
    "package=$SERVER_PACKAGE" \
    "port=$SERVE_PORT" \
    "hostname=$SERVE_HOSTNAME" \
    "pgid=$SERVE_PGID" \
    "pw_var=$pw_var"
  return 0
}
```

- [ ] **Step 5: Bind the credential file in `bwrap_assemble`**

Add next to the `MCP_CONFIG_FILE` bind:

```bash
  if [[ -n "${BWRAP_SERVER_PASSWORD_FILE:-}" ]]; then
    BWRAP_MOUNT_ARGS+=(--ro-bind "$BWRAP_SERVER_PASSWORD_FILE" /run/ai-sandbox/server-password)
  fi
```

- [ ] **Step 6: Route the start block through `serve_resolve_shape` and the runtime**

In the `start` block, replace the `case "$TOOL_PACKAGE"` password gate and the `docker container inspect` duplicate/reuse check with:

```bash
  serve_resolve_shape
  case "$SERVER_PACKAGE" in
    opencode-ai*)
      [[ -n "${OPENCODE_SERVER_PASSWORD:-}" ]] ||
        { launcher_error "OPENCODE_SERVER_PASSWORD is required for serve start (OpenCode v1)"; exit 2; }
      ;;
    @opencode/cli*)
      [[ -n "${OPENCODE_SERVER_PASSWORD:-}" || -n "${OPENCODE_PASSWORD:-}" ]] ||
        { launcher_error "OPENCODE_PASSWORD or OPENCODE_SERVER_PASSWORD is required for serve start (OpenCode v2)"; exit 2; }
      ;;
  esac
  if [[ -f "$SERVE_STATE_DIR/serve.state" ]]; then
    # A bwrap server record exists for this workspace.
    SERVE_PACKAGE="$(serve_state_get package || true)"
    SERVE_PORT="$(serve_state_get port || true)"
    SERVE_HOSTNAME="$(serve_state_get hostname || true)"
    SERVE_PGID="$(serve_state_get pgid || true)"
    SERVE_ALIVE=false
    [[ -n "$SERVE_PGID" ]] && kill -0 -- "-$SERVE_PGID" 2>/dev/null && SERVE_ALIVE=true
    if [[ "$OPENCHAMBER_ACTION" == start ]]; then
      if [[ "$SERVE_ALIVE" == true ]]; then
        SERVE_REUSE=true
        SERVE_STARTED=true
      else
        launcher_error "a stopped OpenCode server exists for $WORKSPACE_DIR; run 'asb serve stop' first"
        exit 2
      fi
    else
      launcher_error "server already exists for $WORKSPACE_DIR; use 'asb serve stop' first"
      exit 2
    fi
  elif docker container inspect "$SERVE_NAME" >/dev/null 2>&1; then
    <existing Docker duplicate/reuse block, unchanged>
  fi
  mkdir -p -m 700 "$SERVE_STATE_DIR"
```

Then, in the start execution section, wrap the Docker body in an `else`:

```bash
if [[ "$SERVE_ACTION" == start ]]; then
  if [[ "${SERVE_REUSE:-false}" != true ]]; then
    if [[ "$RUNTIME" == bwrap ]]; then
      serve_start_bwrap || exit 2
    else
      <existing Docker SERVER_ENV_ARGS / SERVER_COMMAND / compose run / probe block>
      SERVE_STARTED=true
    fi
  fi
  <existing URL report + openchamber_start_ui + exit>
fi
```

In that Docker block, the `case "$TOOL_PACKAGE"` that sets `SERVER_ENV_ARGS`/`SERVER_COMMAND`/`SERVE_HEALTH_PATH` becomes a `case "$SERVER_PACKAGE"` that sets **only** `SERVER_ENV_ARGS` (`SERVER_COMMAND`/`SERVE_HEALTH_PATH` now come from `serve_resolve_shape`):

```bash
  case "$SERVER_PACKAGE" in
    opencode-ai*)
      SERVER_ENV_ARGS=(-e OPENCODE_SERVER_PASSWORD)
      [[ -n "${OPENCODE_SERVER_USERNAME:-}" ]] && SERVER_ENV_ARGS+=(-e OPENCODE_SERVER_USERNAME)
      ;;
    @opencode/cli*)
      if [[ -n "${OPENCODE_SERVER_PASSWORD:-}" ]]; then
        SERVER_ENV_ARGS=(-e OPENCODE_SERVER_PASSWORD)
      else
        SERVER_ENV_ARGS=(-e OPENCODE_PASSWORD)
      fi
      ;;
  esac
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `bash tests/serve/test.sh`
Expected: all checks pass, including the bwrap start/state/argv-leak/v1-shape checks.

- [ ] **Step 8: Commit**

```bash
git add bin/ai-sandbox tests/serve/test.sh
git commit -m "feat(serve): start a detached OpenCode server under bwrap"
```

---

## Task 3: `serve stop` for a bwrap server

**Files:**
- Modify: `bin/ai-sandbox` (add `serve_stop_bwrap`; add the bwrap branch to the stop block)
- Test: `tests/serve/test.sh`

**Interfaces:**
- Consumes: `serve_state_get` (Task 2).
- Produces: `serve_stop_bwrap`.

- [ ] **Step 1: Write the failing test**

This test uses a **real** detached process group to prove teardown reaches the sandboxed child.

```bash
# --- stop signals the recorded process group of a bwrap server ---
sf="$(serve_state_path)"; mkdir -p "$(dirname "$sf")"
setsid sh -c 'echo $$ > "$1"; exec sleep 300' _ "$TMP/live.pgid" &
sleep 0.3
livepgid="$(cat "$TMP/live.pgid")"
{
  echo "runtime=bwrap"; echo "package=@opencode/cli@2.0.26"
  echo "port=4096"; echo "hostname=0.0.0.0"
  echo "pgid=$livepgid"; echo "pw_var=OPENCODE_PASSWORD"
} > "$sf"
if run_launcher serve stop --tool opencode "$TMP/project"; then
  sleep 0.3
  if kill -0 -- "-$livepgid" 2>/dev/null; then
    echo 'FAIL: stopped bwrap server is still alive'; fail=1
    kill -KILL -- "-$livepgid" 2>/dev/null || true
  elif [[ ! -e "$(dirname "$sf")" ]]; then
    echo 'PASS: serve stop signals the recorded bwrap process group and cleans state'
  else
    echo 'FAIL: serve stop left the state dir'; fail=1
  fi
else
  echo "FAIL: bwrap stop failed: $(cat "$TMP/err")"; fail=1
fi
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/serve/test.sh`
Expected: FAIL — with no `bwrap` branch, the stop block runs the Docker path against a nonexistent container and reports "server is not running" (or errors), leaving the process alive.

- [ ] **Step 3: Add `serve_stop_bwrap` and the stop branch**

Add outside the main guard:

```bash
# Stop a detached bwrap server: signal its recorded process group, escalate to
# SIGKILL if it lingers, then remove the state directory.
serve_stop_bwrap() {
  local pgid; pgid="$(serve_state_get pgid 2>/dev/null || true)"
  if [[ -n "$pgid" ]] && kill -0 -- "-$pgid" 2>/dev/null; then
    kill -TERM -- "-$pgid" 2>/dev/null || true
    local i
    for ((i=0; i<50; i++)); do
      kill -0 -- "-$pgid" 2>/dev/null || break
      sleep 0.1
    done
    if kill -0 -- "-$pgid" 2>/dev/null; then
      kill -KILL -- "-$pgid" 2>/dev/null || true
    fi
  fi
  rm -rf -- "$SERVE_STATE_DIR"
  SERVE_STATE_DIR=""
  echo "ai-sandbox: stopped OpenCode server for $WORKSPACE_DIR"
}
```

At the top of the stop block, before the existing Docker logic, add:

```bash
  if [[ -f "$SERVE_STATE_DIR/serve.state" ]]; then
    serve_stop_bwrap
    exit 0
  fi
```

(The existing Docker `inspect`/`stop`/`rm` logic stays as the fall-through for a Docker server.)

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash tests/serve/test.sh`
Expected: PASS, including the process-group teardown check and all existing Docker stop checks.

- [ ] **Step 5: Commit**

```bash
git add bin/ai-sandbox tests/serve/test.sh
git commit -m "feat(serve): stop a detached bwrap server by process-group signal"
```

---

## Task 4: `serve attach` for a bwrap server

**Files:**
- Modify: `bin/ai-sandbox` (add `serve_attach_bwrap`; add the bwrap branch to the attach block)
- Test: `tests/serve/test.sh`

**Interfaces:**
- Consumes: `serve_state_get`, `bwrap_assemble` (Task 1).
- Produces: `serve_attach_bwrap`.

- [ ] **Step 1: Write the failing test**

```bash
# --- attach builds the interactive sandbox with the recorded URL ---
sf="$(serve_state_path)"; mkdir -p "$(dirname "$sf")"
{
  echo "runtime=bwrap"; echo "package=@opencode/cli@2.0.26"
  echo "port=4096"; echo "hostname=0.0.0.0"
  echo "pgid=$livedpgid"; echo "pw_var=OPENCODE_PASSWORD"
} > "$sf"
if run_bwrap serve attach --tool opencode "$TMP/project"; then
  bw="$(tr '\0' ' ' < "$TMP/bwcalls")"
  if [[ "$bw" == *"--die-with-parent"* && "$bw" == *"--server http://127.0.0.1:4096"* ]]; then
    echo 'PASS: bwrap attach uses the interactive sandbox and recorded URL'
  else
    echo "FAIL: bwrap attach argv: $bw"; fail=1
  fi
else
  echo "FAIL: bwrap attach failed: $(cat "$TMP/err")"; fail=1
fi
rm -rf "$(dirname "$sf")"
```

Set `livedpgid` from a real live process group first (reuse the Task 3 pattern):

```bash
setsid sh -c 'echo $$ > "$1"; exec sleep 300' _ "$TMP/att.pgid" &
sleep 0.3
livedpgid="$(cat "$TMP/att.pgid")"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/serve/test.sh`
Expected: FAIL — with no `bwrap` branch, the attach block runs the Docker label reads and errors.

- [ ] **Step 3: Add `serve_attach_bwrap` and the attach branch**

Add outside the main guard:

```bash
# Open a TUI against a running bwrap server, in a second interactive sandbox
# that shares the workspace and home layer.
serve_attach_bwrap() {
  bwrap_available || return 2
  local tool_path; tool_path="$(bwrap_resolve_host_tool opencode)" || return 2
  SANDBOX_BWRAP_PASSTHROUGH="$(resolve_list SANDBOX_BWRAP_PASSTHROUGH .bwrap.passthrough)"
  SANDBOX_BWRAP_DENY="$(resolve_list SANDBOX_BWRAP_DENY .bwrap.deny)"

  local attach_host="$SERVE_HOSTNAME"
  [[ "$attach_host" == "0.0.0.0" ]] && attach_host=127.0.0.1
  local -a attach_args
  case "$SERVE_PACKAGE" in
    opencode-ai*)   attach_args=(attach "http://$attach_host:$SERVE_PORT") ;;
    @opencode/cli*) attach_args=(--server "http://$attach_host:$SERVE_PORT") ;;
    *) launcher_error "server package metadata is missing"; return 2 ;;
  esac

  BWRAP_DETACHED=false
  local pwfile="$SERVE_STATE_DIR/server-password"
  if [[ -n "${SERVE_PW_VAR:-}" && -f "$pwfile" ]]; then
    BWRAP_SERVER_PASSWORD_FILE="$pwfile"
    bwrap_assemble /bin/sh -c \
      "export ${SERVE_PW_VAR}=\"\$(cat /run/ai-sandbox/server-password)\"; exec \"\$0\" \"\$@\"" \
      "$tool_path" "${attach_args[@]}"
  else
    bwrap_assemble "$tool_path" "${attach_args[@]}"
  fi
  progress_stop
  exec bwrap "${BWRAP_ALL_ARGS[@]}"
}
```

At the top of the attach block, before the existing Docker label reads, add:

```bash
  if [[ -f "$SERVE_STATE_DIR/serve.state" ]]; then
    SERVE_PACKAGE="$(serve_state_get package || true)"
    SERVE_PORT="$(serve_state_get port || true)"
    SERVE_HOSTNAME="$(serve_state_get hostname || true)"
    SERVE_PGID="$(serve_state_get pgid || true)"
    SERVE_PW_VAR="$(serve_state_get pw_var || true)"
    [[ "$SERVE_PORT" =~ ^[0-9]+$ ]] || { launcher_error "server port metadata is missing"; exit 2; }
    [[ -n "$SERVE_PGID" ]] && kill -0 -- "-$SERVE_PGID" 2>/dev/null ||
      { launcher_error "server is not running for $WORKSPACE_DIR"; exit 2; }
    serve_attach_bwrap
    exit $?
  fi
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash tests/serve/test.sh`
Expected: PASS, including the attach argv check and existing Docker attach checks.

- [ ] **Step 5: Commit**

```bash
git add bin/ai-sandbox tests/serve/test.sh
git commit -m "feat(serve): attach to a bwrap server in an interactive sandbox"
```

---

## Task 5: `openchamber` under bwrap

**Files:**
- Modify: `bin/ai-sandbox` (`openchamber_prepare_start` host-version check)
- Test: `tests/openchamber/test.sh`

**Interfaces:**
- Consumes: the start/stop dispatch from Tasks 2–3 (openchamber already routes through them).
- Produces: no new function (behavioral change only).

- [ ] **Step 1: Write the failing test**

Add a `run_bwrap` helper to `tests/openchamber/test.sh` (same shape as Task 2's, with its own stub `bwrap`/`opencode`/`node` on `PATH`), then:

```bash
# --- openchamber start under bwrap refuses a v1 host OpenCode ---
OPENCODE_STUB_VERSION=1.18.31
if run_bwrap openchamber start --runtime bwrap --tool opencode@2.0.26 "$TMP/project"; then
  echo 'FAIL: openchamber accepted a v1 host under bwrap'; fail=1
else
  if grep -q '2.0.20' "$TMP/err"; then
    echo 'PASS: openchamber requires a v2 host under bwrap'
  else echo "FAIL: openchamber v1-host diagnostic: $(cat "$TMP/err")"; fail=1; fi
fi
unset OPENCODE_STUB_VERSION

# --- openchamber start under bwrap reuses a running server (state, not labels) ---
sf="$TMP/home/.local/state/ai-sandbox/serve/ai-sandbox-serve-1234-$(printf '%s' "$TMP/project" | git hash-object --stdin | cut -c1-12)/serve.state"
mkdir -p "$(dirname "$sf")"
setsid sh -c 'echo $$ > "$1"; exec sleep 300' _ "$TMP/oc.pgid" &
sleep 0.3
{
  echo "runtime=bwrap"; echo "package=@opencode/cli@2.0.26"
  echo "port=4096"; echo "hostname=0.0.0.0"
  echo "pgid=$(cat "$TMP/oc.pgid")"; echo "pw_var=OPENCODE_PASSWORD"
} > "$sf"
if run_bwrap openchamber start --runtime bwrap --tool opencode "$TMP/project"; then
  if grep -q 'OpenChamber UI started' "$TMP/out"; then
    echo 'PASS: openchamber start under bwrap reuses the running server'
  else echo "FAIL: openchamber reuse output: $(cat "$TMP/out")"; fail=1; fi
else
  echo "FAIL: openchamber start under bwrap failed: $(cat "$TMP/err")"; fail=1
fi
kill -KILL -- "-$(cat "$TMP/oc.pgid")" 2>/dev/null || true
rm -rf "$TMP/home/.local/state"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/openchamber/test.sh`
Expected: the v1-host check FAILS (the current check reads `TOOL_PACKAGE=@opencode/cli@2.0.26` and passes).

- [ ] **Step 3: Base the v2 requirement on the effective package**

In `openchamber_prepare_start`, replace the `TOOL_PACKAGE` v2 check with:

```bash
  local effective="${TOOL_PACKAGE}"
  if [[ "$RUNTIME" == bwrap ]]; then
    local hv; hv="$(detect_host_version opencode)"
    case "${hv#v}" in
      ''|1|1.*) effective="opencode-ai${hv:+@$hv}" ;;
      *)        effective="@opencode/cli${hv:+@$hv}" ;;
    esac
  fi
  case "$effective" in
    @opencode/cli*) ;;
    *) launcher_error "openchamber requires OpenCode 2.0.20+; the host OpenCode is too old for --runtime bwrap; install OpenCode 2.0.20+"; return 1 ;;
  esac
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash tests/openchamber/test.sh`
Expected: PASS, including both new checks and all existing openchamber checks.

- [ ] **Step 5: Commit**

```bash
git add bin/ai-sandbox tests/openchamber/test.sh
git commit -m "feat(openchamber): support --runtime bwrap"
```

---

## Task 6: Real-bwrap integration test

**Files:**
- Modify: `tests/bwrap/test.sh`

**Interfaces:**
- Consumes: the shipped launcher behavior (Tasks 1–5).

- [ ] **Step 1: Write the test**

Add to `tests/bwrap/test.sh`, guard the whole block on `command -v node` and `command -v curl` (skip otherwise):

```bash
# --- detached bwrap serve lifecycle with a fake opencode ---
if command -v node >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
  FAKE="$TMP/fakebin"; mkdir -p "$FAKE"
  cat > "$FAKE/opencode" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then echo "opencode v2.0.26"; exit 0; fi
if [[ "${1:-}" == "serve" ]]; then
  host=127.0.0.1; port=0
  while (($#)); do case "$1" in --hostname) host="$2"; shift 2 ;; --port) port="$2"; shift 2 ;; *) shift ;; esac; done
  exec node -e '
    const http=require("http"),port=+process.argv[1],host=process.argv[2];
    const user=process.env.OPENCODE_SERVER_USERNAME||"opencode";
    const pass=process.env.OPENCODE_SERVER_PASSWORD||process.env.OPENCODE_PASSWORD||"";
    http.createServer((req,res)=>{
      const want="Basic "+Buffer.from(user+":"+pass).toString("base64");
      res.writeHead((req.headers.authorization||"")===want?200:401); res.end("ok");
    }).listen(port,host);
  ' "$port" "$host"
fi
exit 1
EOF
  chmod +x "$FAKE/opencode"

  SWS="$TMP/serve-ws"; mkdir -p "$SWS"
  env HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/home/.config" \
      PATH="$FAKE:$PATH" SANDBOX_PROGRESS=false SANDBOX_CLEANUP=false \
      SANDBOX_UID=1234 SANDBOX_GID=1234 SANDBOX_USERNAME=tester SANDBOX_HOME=/home/tester \
      SANDBOX_BWRAP_PASSTHROUGH="$FAKE" OPENCODE_PASSWORD="test password" \
      AI_SANDBOX_DIR="$ROOT/share/ai-sandbox" \
      bash "$LAUNCHER" serve start --runtime bwrap --tool opencode --hostname 0.0.0.0 --port 4097 "$SWS"

  if curl -sf -u "opencode:test password" "http://127.0.0.1:4097/api/info" >/dev/null 2>&1; then
    ok "bwrap serve start: detached server reachable on host loopback"
  else
    bad "bwrap serve start: server not reachable"
  fi

  env HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/home/.config" \
      SANDBOX_UID=1234 SANDBOX_GID=1234 SANDBOX_USERNAME=tester SANDBOX_HOME=/home/tester \
      AI_SANDBOX_DIR="$ROOT/share/ai-sandbox" \
      bash "$LAUNCHER" serve stop --tool opencode "$SWS" >/dev/null 2>&1
  sleep 0.3
  if curl -sf --max-time 2 "http://127.0.0.1:4097/api/info" >/dev/null 2>&1; then
    bad "bwrap serve stop: server still answering"
  else
    ok "bwrap serve stop: detached server torn down"
  fi
else
  skipmsg "node or curl unavailable for the fake server"
fi
```

- [ ] **Step 2: Run it to verify it passes**

Run: `bash tests/bwrap/test.sh`
Expected: PASS when bwrap works here; the whole suite SKIPs when bwrap/userns is unavailable. If it fails, inspect the workspace's `server.log` under the state dir.

- [ ] **Step 3: Commit**

```bash
git add tests/bwrap/test.sh
git commit -m "test(bwrap): integration coverage for the detached serve lifecycle"
```

---

## Task 7: Documentation

**Files:**
- Modify: `README.md`, `docs/architecture.md`, `docs/configuration.md`, `docs/development.md`

- [ ] **Step 1: Update `README.md`**

- In the runtime section, remove `serve` from the "remain Docker-only" list (keep the cache warm-up, cleanup container, per-UID volume, root mode).
- Add that `serve` and `openchamber` support `--runtime bwrap`: a detached host-tool server, version pins ignored, logs at `<data-dir>/log/opencode.log`.
- In the `serve`/`openchamber` sections, note `--runtime bwrap` and that `--hostname`/`--port` behave identically.

- [ ] **Step 2: Update `docs/architecture.md`**

Add a "Serve runtime seam" subsection: the bwrap-only `serve.state` record, the detached `setsid` server, the credential-file mechanism, group-signal teardown, and the dispatch (state present → bwrap, absent → Docker labels).

- [ ] **Step 3: Update `docs/configuration.md`**

Note that `runtime` now applies to `serve`/`openchamber`, and that the bwrap server runs the host OpenCode and ignores version pins.

- [ ] **Step 4: Update `docs/development.md`**

Add invariants and manual-test items:

- The bwrap server record is `$SERVE_STATE_DIR/serve.state`; its presence marks a bwrap server (Docker uses container labels).
- Credentials never in argv (Docker `-e`; bwrap `0600` file + inner `sh -c`).
- `--die-with-parent` is off only when `BWRAP_DETACHED=true`.
- Generated files for a detached server live in `$SERVE_STATE_DIR`.
- Manual: `asb serve start --runtime bwrap …`, verify the URL and that it survives the shell exiting, then `serve attach` and `serve stop` (no process left); `asb openchamber start --runtime bwrap …`; a v1 host OpenCode is refused.

- [ ] **Step 5: Run the docs-in-sync checks and the full suite**

Run: `bash -n bin/ai-sandbox && bash tests/run-all.sh`
Expected: all suites pass; no stale "serve … Docker-only" claims remain (grep the docs).

- [ ] **Step 6: Commit**

```bash
git add README.md docs/architecture.md docs/configuration.md docs/development.md
git commit -m "docs: bwrap serve and openchamber"
```

---

## Self-Review

**Spec coverage:**
- Runtime seam + `serve.state` (bwrap-only, label path unchanged) → Task 2 (record) and Tasks 3–4 (dispatch).
- Detached bwrap server (`setsid`, no `--die-with-parent`, state) → Tasks 1–2.
- Readiness probe (host loopback, node/curl, no argv credential) → Task 2.
- Teardown by group signal → Task 3.
- `attach` (second interactive sandbox) → Task 4.
- Host tool, pins ignored, host-version shape → Task 2 (`serve_resolve_shape`) and Task 5.
- Credential file, never argv → Task 2.
- openchamber reuse + v2 host check → Task 5.
- No `serve logs`; OpenCode's own log + fallback → Task 2 messages, Task 7 docs.
- Removal of the Docker-only rejection → Task 2.
- Docs → Task 7.

**Placeholder scan:** the `<existing …>` markers in Tasks 2–3 refer to code already present at named locations (the Docker `case` for `SERVER_ENV_ARGS`, the Docker duplicate/reuse block, the Docker stop block); the executor edits in place. No other placeholders.

**Type consistency:** `bwrap_assemble`, `serve_state_write`, `serve_state_get`, `serve_resolve_shape`, `serve_bwrap_pw_var`, `serve_probe_bwrap`, `serve_start_bwrap`, `serve_stop_bwrap`, `serve_attach_bwrap` are named identically wherever referenced. State keys (`runtime`, `package`, `port`, `hostname`, `pgid`, `pw_var`) match the spec. No `local` is used in a main-guard snippet.

**Review Focus → tests:** item 1 → Task 3 (state present routes to bwrap even though the default runtime is docker); item 2 → Task 2 (stale state → "stopped server exists") and Task 3 (stop cleans up); item 3 → Task 2 argv-leak check plus Task 6's real password `test password` (contains a space); item 4 → Task 2 probe host mapping; item 5 → Task 5 v1-host check.