#!/bin/bash
# Tests for the browser (Playwright MCP) integration.
#
# 1. Handshake smoke test: the launcher's *default* browser MCP URL must be
#    accepted by the on-host playwright-mcp HTTP transport. The transport
#    validates the Host header against the bound address normalized to
#    `localhost`, so a `127.0.0.1` URL is rejected with 403 even though the
#    TCP port is reachable. This test runs the launcher with a stub docker,
#    extracts the injected PLAYWRIGHT_MCP_URL, and performs a real MCP
#    `initialize` handshake against it. Skipped when the service is not
#    running (no reachable endpoint) or curl is unavailable.
#
# 2. Unit tests for share/ai-sandbox/playwright-mcp (the host-side service
#    launcher): browser probing/selection and generated config JSON, driven
#    with stub `playwright-mcp`/`node`/`chromium`/`npm` binaries on PATH.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$SCRIPT_DIR/../.."
LAUNCHER="$REPO_ROOT/bin/ai-sandbox"
PW_WRAPPER="$REPO_ROOT/share/ai-sandbox/playwright-mcp"

pass=0
fail=0
skip_count=0
TMPDIRS=()
cleanup() {
    local dir
    for dir in "${TMPDIRS[@]}"; do
        rm -rf "$dir"
    done
}
trap cleanup EXIT

ok() { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
skip() { echo "SKIP: $1"; skip_count=$((skip_count+1)); }
assert_contains() {
    local name="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then ok "$name"; else bad "$name (missing '$needle' in '$haystack')"; fi
}
assert_not_contains() {
    local name="$1" haystack="$2" needle="$3"
    if [[ "$haystack" != *"$needle"* ]]; then ok "$name"; else bad "$name (unexpected '$needle' in '$haystack')"; fi
}

# --- Part 1: the launcher's default browser MCP URL must actually serve MCP ---

unset SANDBOX_BROWSER_MCP_URL
CAPTURE_DIR="$(mktemp -d)"
TMPDIRS+=("$CAPTURE_DIR")
mkdir -p "$CAPTURE_DIR/bin" "$CAPTURE_DIR/home"
printf '#!/bin/sh\nprintf "%%s\\0" "$@" > "$DOCKER_CAPTURE"\n' > "$CAPTURE_DIR/bin/docker"
chmod +x "$CAPTURE_DIR/bin/docker"
DOCKER_CAPTURE="$CAPTURE_DIR/docker.args" \
HOME="$CAPTURE_DIR/home" \
XDG_CONFIG_HOME="$CAPTURE_DIR/home/.config" \
SANDBOX_UID=1234 \
SANDBOX_GID=1234 \
SANDBOX_USERNAME=tester \
SANDBOX_HOME=/home/tester \
SANDBOX_CLEANUP=false \
CLAUDE_VERSION=integration-test \
CODEX_VERSION=integration-test \
OPENCODE_VERSION=integration-test \
HTTP_PROXY= HTTPS_PROXY= ALL_PROXY= NO_PROXY= \
http_proxy= https_proxy= all_proxy= no_proxy= \
SANDBOX_BROWSER_ENABLED=true \
AI_SANDBOX_DIR="$REPO_ROOT/share/ai-sandbox" \
PATH="$CAPTURE_DIR/bin:$PATH" \
  bash "$LAUNCHER" "$REPO_ROOT" >/dev/null 2>&1
mapfile -d '' -t CAPTURED_DOCKER_ARGS < "$CAPTURE_DIR/docker.args"

DEFAULT_URL=""
for ((i=0; i<${#CAPTURED_DOCKER_ARGS[@]}; i++)); do
    if [[ "${CAPTURED_DOCKER_ARGS[i]}" == PLAYWRIGHT_MCP_URL=* ]]; then
        DEFAULT_URL="${CAPTURED_DOCKER_ARGS[i]#*=}"
    fi
done

if [[ -z "$DEFAULT_URL" ]]; then
    bad "handshake: launcher injects PLAYWRIGHT_MCP_URL by default (browser enabled)"
else
    ok "handshake: launcher injects PLAYWRIGHT_MCP_URL by default ($DEFAULT_URL)"

    # Reachability (TCP) pre-check so machines without the service skip cleanly.
    hostport="${DEFAULT_URL#*://}"; hostport="${hostport%%/*}"
    host="${hostport%:*}"; port="${hostport##*:}"
    reachable=false
    ( exec 3<>"/dev/tcp/$host/$port" ) 2>/dev/null && reachable=true

    if [[ "$reachable" != true ]]; then
        skip "handshake: browser MCP service not running at $DEFAULT_URL (start ai-sandbox-playwright)"
    elif ! command -v curl >/dev/null 2>&1; then
        skip "handshake: curl not available"
    else
        body="$CAPTURE_DIR/resp"
        code="$(curl -sS -o "$body" -w '%{http_code}' -m 10 -X POST "$DEFAULT_URL" \
            -H 'Content-Type: application/json' \
            -H 'Accept: application/json, text/event-stream' \
            -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"ai-sandbox-test","version":"0"}}}' 2>"$CAPTURE_DIR/curl.err")"
        if [[ "$code" == "200" ]]; then
            ok "handshake: MCP initialize accepted at default URL"
        else
            bad "handshake: MCP initialize accepted at default URL (HTTP $code: $(head -c 200 "$body" 2>/dev/null || head -c 200 "$CAPTURE_DIR/curl.err"))"
        fi
        if grep -q '"serverInfo"' "$body" 2>/dev/null; then
            ok "handshake: response contains serverInfo"
        else
            bad "handshake: response contains serverInfo (body: $(head -c 200 "$body" 2>/dev/null))"
        fi
    fi
fi

# --- Part 2: host-side playwright-mcp wrapper (stubbed binaries) ---

STUB="$(mktemp -d)"
TMPDIRS+=("$STUB")
mkdir -p "$STUB/bin"

# Stub MCP server: records argv and the config JSON passed via --config.
cat > "$STUB/bin/playwright-mcp" <<'EOF'
#!/bin/bash
cfg=""
for ((i=0; i<$#; i++)); do
    [[ "${!i}" == "--config" ]] && cfg="${@:i+1:1}"
done
{ printf 'ARGS:%s\n' "$(printf '<%s>' "$@")"
  [[ -n "$cfg" ]] && cat "$cfg"
} > "${PW_MCP_CAPTURE:?}"
EOF
chmod +x "$STUB/bin/playwright-mcp"

# Stub node: probe scripts (they contain browser.launch) succeed or fail on
# demand; anything else (e.g. cli.js install) succeeds.
cat > "$STUB/bin/node" <<'EOF'
#!/bin/bash
if [[ -f "$1" ]] && grep -q "browser.launch" "$1" 2>/dev/null; then
    exit "${FAKE_PROBE_RC:-0}"
fi
exit 0
EOF
chmod +x "$STUB/bin/node"

# Stub npm: prints the fake global node_modules root when FAKE_NPM_ROOT is
# non-empty (enables browser probing via the npm-global branch of
# resolve_playwright); prints nothing when it is empty, so PW_DIR stays
# unset and probing/auto-install is disabled (deterministic fallback case).
mkdir -p "$STUB/pw/node_modules/playwright"
cat > "$STUB/bin/npm" <<'EOF'
#!/bin/bash
[[ -n "${FAKE_NPM_ROOT:-}" ]] && echo "$FAKE_NPM_ROOT"
exit 0
EOF
chmod +x "$STUB/bin/npm"

# Stub system browser: just needs to exist on PATH for probing.
printf '#!/bin/sh\nexit 0\n' > "$STUB/bin/chromium"
chmod +x "$STUB/bin/chromium"

run_pw_wrapper() {  # caller prefixes env assignments (FAKE_PROBE_RC, FAKE_NPM_ROOT, PLAYWRIGHT_MCP_HEADLESS, ...)
    PW_MCP_CAPTURE="$STUB/pw-capture" \
    PATH="$STUB/bin:/usr/bin:/bin" \
    HOME="$STUB/home" \
      bash "$PW_WRAPPER" --host 127.0.0.1 --port 8931 2>"$STUB/pw-stderr"
}

# Case A: headless, system chromium probe succeeds -> chromium with
# executablePath, --headless flag, no display args.
out="$(FAKE_PROBE_RC=0 FAKE_NPM_ROOT="$STUB/pw/node_modules" PLAYWRIGHT_MCP_HEADLESS=true run_pw_wrapper)"
ARGS_LINE="$(head -n 1 "$STUB/pw-capture")"
CONFIG_JSON="$(tail -n +2 "$STUB/pw-capture")"
assert_contains "wrapper: passes --headless in headed-off mode" "$ARGS_LINE" "<--headless>"
assert_contains "wrapper: forwards extra CLI args to playwright-mcp" "$ARGS_LINE" "<--host><127.0.0.1><--port><8931>"
assert_contains "wrapper: config picks chromium" "$CONFIG_JSON" '"browserName":"chromium"'
assert_contains "wrapper: config pins system chromium executablePath" "$CONFIG_JSON" "\"executablePath\":\"$STUB/bin/chromium\""
assert_contains "wrapper: headless config has no display args" "$CONFIG_JSON" '"args":[]'
assert_contains "wrapper: logs system chromium selection" "$(cat "$STUB/pw-stderr")" "using system chromium"

# Case B: probing disabled (no playwright resolved) and probes cannot run ->
# falls back to Playwright's own chromium (no executablePath), still with
# --headless.
out="$(FAKE_PROBE_RC=1 FAKE_NPM_ROOT= PLAYWRIGHT_MCP_HEADLESS=true run_pw_wrapper)"
ARGS_LINE="$(head -n 1 "$STUB/pw-capture")"
CONFIG_JSON="$(tail -n +2 "$STUB/pw-capture")"
assert_contains "wrapper: fallback still passes --headless" "$ARGS_LINE" "<--headless>"
assert_contains "wrapper: fallback config picks chromium" "$CONFIG_JSON" '"browserName":"chromium"'
assert_not_contains "wrapper: fallback config has no executablePath" "$CONFIG_JSON" "executablePath"
assert_contains "wrapper: logs Playwright chromium fallback" "$(cat "$STUB/pw-stderr")" "using Playwright's own chromium"

# Case C: headed on Wayland -> --ozone-platform=wayland lands in launch args,
# no --headless. Needs a real socket file; skipped without python3.
WL_DIR="$(mktemp -d)"
TMPDIRS+=("$WL_DIR")
if command -v python3 >/dev/null 2>&1; then
    python3 -c "import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])" "$WL_DIR/wayland-0" 2>/dev/null
    if [[ -S "$WL_DIR/wayland-0" ]]; then
        out="$(FAKE_PROBE_RC=0 FAKE_NPM_ROOT="$STUB/pw/node_modules" XDG_RUNTIME_DIR="$WL_DIR" WAYLAND_DISPLAY=wayland-0 run_pw_wrapper)"
        ARGS_LINE="$(head -n 1 "$STUB/pw-capture")"
        CONFIG_JSON="$(tail -n +2 "$STUB/pw-capture")"
        assert_not_contains "wrapper: wayland mode does not force --headless" "$ARGS_LINE" "<--headless>"
        assert_contains "wrapper: wayland config passes ozone arg" "$CONFIG_JSON" '"args":["--ozone-platform=wayland"]'
        assert_contains "wrapper: logs wayland display selection" "$(cat "$STUB/pw-stderr")" "using Wayland display: wayland-0"
    else
        skip "wrapper: could not create a unix socket for the wayland case"
    fi
else
    skip "wrapper: python3 not available for the wayland socket"
fi

echo "$pass passed, $fail failed, $skip_count skipped"
if [[ $fail -ne 0 ]]; then
    exit 1
fi
exit 0
