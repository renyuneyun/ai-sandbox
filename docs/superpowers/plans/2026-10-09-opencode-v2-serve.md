# OpenCode v2 `serve` support

## Goal

`asb serve start|stop|attach` today only supports OpenCode **v1** (`opencode-ai`). Extend the existing `serve` subcommand so it also supports OpenCode **v2** (`@opencode/cli`), matching how v2's server actually works. The interactive v2 path is already done and is untouched.

## Scope (locked, from user decisions)

- Only the `serve` subcommand changes. Browser MCP and per-workspace data-store isolation are explicitly **out of scope**.
- `--headless` for v2 is accepted as a **no-op** (v2 `serve` always serves web UI + API; there is no API-only flag).
- The server password is accepted from **either** `OPENCODE_PASSWORD` (v2's name) or `OPENCODE_SERVER_PASSWORD` (v1's name, which v2 also honors).

## Verified v2 facts (source of truth: `@opencode/cli` v2.0.18)

| Concern | v1 (`opencode-ai`) | v2 (`@opencode/cli`) |
|---|---|---|
| server command | `web` (web+API) or `serve` (`--headless` = API only) | single `serve --hostname <h> --port <p>` (always web+API) |
| attach | `opencode-ai attach <url>` | `opencode --server <url>` (no `attach` subcommand) |
| auth | Basic `opencode` / `OPENCODE_SERVER_PASSWORD` (+ optional `OPENCODE_SERVER_USERNAME`) | Basic `opencode` / `OPENCODE_PASSWORD` (or `OPENCODE_SERVER_PASSWORD`) |
| health/readiness | `GET /global/health` | `GET /api/info` (200 = ready, 404 = incompatible, 500 = failed) |
| client link | password login in/browser/app | one-time pairing via `opencode pair` (`--server` is a global flag; `--url` points the link at a reachable address) |

## File structure

- `bin/ai-sandbox` — the launcher. All serve logic lives inline in `main` (no new sourced functions, matching the current procedural style).
- `tests/serve/test.sh` — v1 serve integration tests (stubbed `docker`); updated to also cover v2.
- `docs/development.md`, `docs/architecture.md`, `docs/configuration.md`, `README.md` — documentation sync.
- `share/ai-sandbox/completions/ai-sandbox.bash`, `share/ai-sandbox/completions/_ai-sandbox` — completion text sync (`--headless` description only).
- `share/ai-sandbox/config.example.yaml` — **no change** (serve password is env-only, not config).

## Task 1 — Extend the test suite for v2 (write first, expected to fail)

File: `tests/serve/test.sh`.

### 1a. Make the stubbed `docker` package label overridable

Line 26 currently hardcodes `opencode-ai@1.18.31`. Change to:

```bash
    *ai-sandbox.serve.package*) echo "${DOCKER_STUB_PACKAGE:-opencode-ai@1.18.31}" ;;
```

### 1b. Forward the two new knobs through `run_launcher`

Add two env passthroughs to the `run_launcher` `env` line:

```bash
    OPENCODE_PASSWORD="${TEST_OPENCODE_PASSWORD-}" \
    DOCKER_STUB_PACKAGE="${DOCKER_STUB_PACKAGE-}" \
```

(`OPENCODE_PASSWORD` is set-but-empty by default, so v1 tests are unaffected; v2 tests set it explicitly.)

### 1c. Assert the v1 health path is `/global/health`

In the first v1 start block (the one gated by `run_launcher serve start --tool opencode --hostname 10.44.55.66 --port 4096 ...`), add:

```bash
  if tr '\0' ' ' < "$TMP/calls" | grep -q '/global/health'; then
    echo 'PASS: v1 server health-checks /global/health'
  else
    echo 'FAIL: v1 health path'; fail=1
  fi
```

### 1d. Replace the "v2 server rejected" test with v2 acceptance tests

Replace lines 144–148 (the `if run_launcher serve start --tool opencode@2.0.0 ...` block that expects rejection) with:

```bash
# --- OpenCode v2 serve ---

if run_launcher serve start --tool opencode@2.0.0 --hostname 10.44.55.66 --port 4096 "$TMP/project"; then
  if tr '\0' ' ' < "$TMP/calls" | grep -q 'run -d .*@opencode/cli@2.0.0 serve --hostname 10.44.55.66 --port 4096'; then
    echo 'PASS: v2 detached server starts (serve)'
  else
    echo 'FAIL: v2 detached server command'; fail=1
  fi
  if tr '\0' ' ' < "$TMP/calls" | grep -q -- '-e OPENCODE_SERVER_PASSWORD'; then
    echo 'PASS: v2 forwards password by name'
  else
    echo 'FAIL: v2 password forwarding'; fail=1
  fi
  if tr '\0' ' ' < "$TMP/calls" | grep -q '/api/info'; then
    echo 'PASS: v2 server health-checks /api/info'
  else
    echo 'FAIL: v2 health path'; fail=1
  fi
  if tr '\0' ' ' < "$TMP/calls" | grep -q -- '--auto\|--standalone'; then
    echo 'FAIL: v2 serve leaked a TUI-only flag'; fail=1
  else
    echo 'PASS: v2 serve omits TUI-only flags'
  fi
  if grep -q 'test password' "$TMP/calls"; then
    echo 'FAIL: v2 password appeared in Docker arguments'; fail=1
  fi
else
  echo "FAIL: v2 start rejected: $(cat "$TMP/err")"; fail=1
fi

# --headless is a no-op for v2
if run_launcher serve start --tool opencode@2.0.0 --headless --hostname 10.44.55.66 "$TMP/project"; then
  if tr '\0' ' ' < "$TMP/calls" | grep -q '@opencode/cli@2.0.0 serve ' && \
     ! tr '\0' ' ' < "$TMP/calls" | grep -q 'web'; then
    echo 'PASS: v2 --headless is a no-op (still runs serve)'
  else
    echo 'FAIL: v2 --headless handling'; fail=1
  fi
else
  echo 'FAIL: v2 headless start rejected'; fail=1
fi

# OPENCODE_PASSWORD alone is accepted and forwarded by name
TEST_SERVER_PASSWORD=''
TEST_OPENCODE_PASSWORD='v2secret'
if run_launcher serve start --tool opencode@2.0.0 --hostname 10.44.55.66 "$TMP/project"; then
  if tr '\0' ' ' < "$TMP/calls" | grep -q -- '-e OPENCODE_PASSWORD' && \
     ! tr '\0' ' ' < "$TMP/calls" | grep -q -- '-e OPENCODE_SERVER_PASSWORD'; then
    echo 'PASS: v2 accepts OPENCODE_PASSWORD by name'
  else
    echo 'FAIL: v2 OPENCODE_PASSWORD forwarding'; fail=1
  fi
else
  echo "FAIL: v2 OPENCODE_PASSWORD start rejected: $(cat "$TMP/err")"; fail=1
fi
unset TEST_OPENCODE_PASSWORD TEST_SERVER_PASSWORD

# Neither password var set → rejected before Docker
TEST_SERVER_PASSWORD=''
TEST_OPENCODE_PASSWORD=''
if run_launcher serve start --tool opencode@2.0.0 --hostname 10.44.55.66 "$TMP/project"; then
  echo 'FAIL: v2 with no password env accepted'; fail=1
else
  if grep -q 'OPENCODE_PASSWORD or OPENCODE_SERVER_PASSWORD is required' "$TMP/err" && [[ ! -s "$TMP/calls" ]]; then
    echo 'PASS: v2 rejects missing password before Docker'
  else
    echo 'FAIL: v2 missing-password handling'; fail=1
  fi
fi
unset TEST_OPENCODE_PASSWORD TEST_SERVER_PASSWORD

# v2 attach connects via --server
TEST_DOCKER_EXISTS=1
DOCKER_STUB_PACKAGE='@opencode/cli@2.0.0'
if run_launcher serve attach --tool opencode@2.0.0 "$TMP/project"; then
  if tr '\0' ' ' < "$TMP/calls" | grep -q 'exec -u 1234:1234 .*@opencode/cli@2.0.0 --server http://10.44.55.66:4096'; then
    echo 'PASS: v2 TUI attaches via --server'
  else
    echo 'FAIL: v2 attach command'; fail=1
  fi
else
  echo 'FAIL: v2 attach rejected'; fail=1
fi
unset TEST_DOCKER_EXISTS DOCKER_STUB_PACKAGE
```

## Task 2 — Implement v2 serve in the launcher

File: `bin/ai-sandbox`.

### 2a. Remove the v1-only gate

Lines 748–753. Replace:

```bash
if [[ -n "$SERVE_ACTION" ]]; then
  [[ "$SELECTED_TOOL" == opencode ]] || { launcher_error "serve currently supports only OpenCode"; exit 2; }
  if [[ "$SERVE_ACTION" == start ]]; then
    [[ "$TOOL_PACKAGE" == opencode-ai* ]] || { launcher_error "serve currently supports only OpenCode v1"; exit 2; }
  fi
fi
```

with:

```bash
if [[ -n "$SERVE_ACTION" ]]; then
  [[ "$SELECTED_TOOL" == opencode ]] || { launcher_error "serve currently supports only OpenCode"; exit 2; }
fi
```

### 2b. Attach by package

Lines 823–829. Replace the package validation and the `docker exec` (the `npx ... attach ...` line) with:

```bash
  SERVE_PACKAGE="$(docker inspect -f '{{ index .Config.Labels "ai-sandbox.serve.package" }}' "$SERVE_NAME")"
  case "$SERVE_PACKAGE" in
    opencode-ai*)   SERVE_ATTACH_ARGS=(attach "http://$SERVE_ATTACH_HOST:$SERVE_PORT") ;;
    @opencode/cli*) SERVE_ATTACH_ARGS=(--server "http://$SERVE_ATTACH_HOST:$SERVE_PORT") ;;
    *) launcher_error "server package metadata is missing"; exit 2 ;;
  esac
  progress_stop
  docker exec -u "${SANDBOX_UID}:${SANDBOX_GID}" -w "$WORKSPACE_DIR" -it "$SERVE_NAME" \
    npx --yes "$SERVE_PACKAGE" "${SERVE_ATTACH_ARGS[@]}"
  exit $?
```

### 2c. Start: per-package password requirement

Lines 833–840. Replace the `[[ -n "${OPENCODE_SERVER_PASSWORD:-}" ]] ...` check with a `case`:

```bash
if [[ "$SERVE_ACTION" == start ]]; then
  case "$TOOL_PACKAGE" in
    opencode-ai*)
      [[ -n "${OPENCODE_SERVER_PASSWORD:-}" ]] ||
        { launcher_error "OPENCODE_SERVER_PASSWORD is required for serve start (OpenCode v1)"; exit 2; }
      ;;
    @opencode/cli*)
      [[ -n "${OPENCODE_SERVER_PASSWORD:-}" || -n "${OPENCODE_PASSWORD:-}" ]] ||
        { launcher_error "OPENCODE_PASSWORD or OPENCODE_SERVER_PASSWORD is required for serve start (OpenCode v2)"; exit 2; }
      ;;
  esac
  if docker container inspect "$SERVE_NAME" >/dev/null 2>&1; then
    launcher_error "server already exists for $WORKSPACE_DIR; use 'asb serve stop' first"
    exit 2
  fi
  mkdir -p -m 700 "$SERVE_STATE_DIR"
fi
```

### 2d. Start: per-package env, command, and health path

Lines 987–991. Replace:

```bash
  SERVER_ENV_ARGS=(-e OPENCODE_SERVER_PASSWORD)
  [[ -n "${OPENCODE_SERVER_USERNAME:-}" ]] && SERVER_ENV_ARGS+=(-e OPENCODE_SERVER_USERNAME)
  SERVER_COMMAND=web
  [[ "$SERVE_HEADLESS" == true ]] && SERVER_COMMAND=serve
```

with:

```bash
  case "$TOOL_PACKAGE" in
    opencode-ai*)
      SERVER_ENV_ARGS=(-e OPENCODE_SERVER_PASSWORD)
      [[ -n "${OPENCODE_SERVER_USERNAME:-}" ]] && SERVER_ENV_ARGS+=(-e OPENCODE_SERVER_USERNAME)
      SERVER_COMMAND=web
      [[ "$SERVE_HEADLESS" == true ]] && SERVER_COMMAND=serve
      SERVE_HEALTH_PATH=/global/health
      ;;
    @opencode/cli*)
      # v2: --headless has no API-only equivalent; serve always runs web+API.
      if [[ -n "${OPENCODE_SERVER_PASSWORD:-}" ]]; then
        SERVER_ENV_ARGS=(-e OPENCODE_SERVER_PASSWORD)
      else
        SERVER_ENV_ARGS=(-e OPENCODE_PASSWORD)
      fi
      SERVER_COMMAND=serve
      SERVE_HEALTH_PATH=/api/info
      ;;
  esac
```

The rest of the `docker compose run` and the labels are unchanged (they already use `"$SERVER_ENV_ARGS"` and `"$TOOL_PACKAGE" "$SERVER_COMMAND"`).

### 2e. Health-check script: parameterize path + password

Lines 1018–1030. Replace the two relevant lines of the inlined Node script and the trailing invocation args.

- URL line → `` const url = `http://${host}:${process.argv[2]}${process.argv[3]}` ``
- password line → `` const password = process.env.OPENCODE_SERVER_PASSWORD || process.env.OPENCODE_PASSWORD || "" ``
- invocation line (1030) → `    ' "$SERVE_HOSTNAME" "$SERVE_PORT" "$SERVE_HEALTH_PATH" >/dev/null 2>&1; then`

The username line stays `const username = process.env.OPENCODE_SERVER_USERNAME || "opencode"` — correct for both (v2 does not forward `OPENCODE_SERVER_USERNAME`, so it resolves to `opencode`).

### 2f. Start: success message per package

Lines 1043–1050. Keep the two "started at" lines; replace only the final username/password line with:

```bash
  case "$TOOL_PACKAGE" in
    opencode-ai*)
      echo "ai-sandbox: username ${OPENCODE_SERVER_USERNAME:-opencode}; password from OPENCODE_SERVER_PASSWORD"
      ;;
    @opencode/cli*)
      echo "ai-sandbox: connect a client with 'asb serve attach'; pair a browser or app with 'opencode pair'"
      ;;
  esac
  exit 0
```

## Task 3 — Run the tests

```sh
bash tests/run-all.sh
```

All suites pass, and `tests/serve/test.sh` now includes the v2 cases. No changes to `tests/launcher/test.sh`, `tests/config/test.sh`, etc. are needed (serve logic is integration-tested via the stubbed `docker`, not sourced).

## Task 4 — Update help, completions, and docs

### 4a. `print_help` (`bin/ai-sandbox`, line 91)

```
  --headless                        Use the API-only server instead of the web UI.
```
→
```
  --headless                        API-only server (OpenCode v1 only; no-op for v2).
```

### 4b. Completions

- `share/ai-sandbox/completions/_ai-sandbox` line 13: `'--headless[Run API server without web UI]'` → `'--headless[API-only server (v1 only; no-op for v2)]'`.
- `share/ai-sandbox/completions/ai-sandbox.bash` — no flag list change (all flags unchanged).

### 4c. `README.md`

- Line 59: `serve start|stop|attach manages an OpenCode v1 server` → `… manages an OpenCode server (v1 or v2)`.
- Lines 73–92: retitle the section from "OpenCode v1 server for mobile access" to "OpenCode server for mobile access (v1 and v2)", and split the prose into v1 vs v2:
  - v1: `web`/`serve --headless`, `attach`, username `opencode` + `OPENCODE_SERVER_PASSWORD`/`OPENCODE_SERVER_USERNAME`.
  - v2: single `serve` (always web+API), `--headless` is accepted but ignored, password from `OPENCODE_PASSWORD` or `OPENCODE_SERVER_PASSWORD`, `attach` runs `opencode --server <url>`, and browser/app access is via `opencode pair` one-time links rather than a password login.
  - Update line 86 ("v2 and other tools are not supported by this command yet") accordingly.
  - Update line 92 (the `OPENCODE_SERVER_PASSWORD` paragraph) to mention both names.

### 4d. `docs/architecture.md`

- Line 11: "`serve start` instead runs an OpenCode v1 web server" → "an OpenCode (v1 or v2) server".
- Line 18: "An OpenCode v1 server is named" → "An OpenCode server is named".

### 4e. `docs/configuration.md`

- Line 188: "`serve start|stop|attach` remains v1-only." → describe v2 support: v2 runs `@opencode/cli serve` (web+API always on; `--headless` accepted as a no-op), password from `OPENCODE_PASSWORD` or `OPENCODE_SERVER_PASSWORD`, attach via `opencode --server`, health `/api/info`, browser/app pairing via `opencode pair`.

### 4f. `docs/development.md`

- Add a manual-test item (after 55) capturing v2 serve verification, e.g.:
  > **56. OpenCode v2 serve:** `OPENCODE_PASSWORD=<pw> asb serve start --tool opencode@2.x --hostname lo --port <p>` starts `@opencode/cli serve` (web+API); `GET /api/info` with `-u opencode:<pw>` returns 200 while no/bad auth returns 401/403; `asb serve attach --tool opencode@2.x` opens a TUI over `--server`; a phone/browser links via `opencode pair`. `--headless` is accepted and ignored for v2.

## Task 5 — Verification

- `bash tests/run-all.sh` → all pass.
- `bin/ai-sandbox --help` shows the updated `--headless` text; completions render the updated description.
- Manual (optional, live): `OPENCODE_PASSWORD=secret asb serve start --tool opencode@2.0.18 --hostname lo --port 41995`, confirm `curl -u opencode:secret http://127.0.0.1:41995/api/info` → 200 with a `version` field, then `asb serve stop`.

## Out of scope (deferred, by user decision)

- Browser MCP auto-registration for non-Claude tools.
- Per-workspace OpenCode data-store isolation (v2 already runs concurrent sessions over a shared store; this is acceptable).