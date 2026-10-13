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

if ! command -v bwrap >/dev/null 2>&1; then
    skipmsg "bwrap not installed"
    echo "$pass passed, $fail failed, $skip skipped"; exit 0
fi
if ! bwrap --ro-bind / / --proc /proc --dev /dev --unshare-all --share-net -- /bin/true >/dev/null 2>&1; then
    skipmsg "bwrap cannot create a sandbox here (userns restricted)"
    echo "$pass passed, $fail failed, $skip skipped"; exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
WS="$TMP/ws"; mkdir -p "$WS" "$TMP/bin" "$TMP/home"

# Reference confinement: with the launcher's flag shape, the workspace is
# writable, IS_SANDBOX is set, and a write outside the writable set fails.
bwrap --unshare-all --share-net --ro-bind / / --proc /proc --dev /dev --tmpfs /tmp \
    --bind "$WS" "$WS" --chdir "$WS" --setenv IS_SANDBOX 1 -- \
    /bin/sh -c 'printf "%s" "$IS_SANDBOX" > "$PWD/probe"; printf x > "$PWD/../escape" 2>/dev/null' \
    >/dev/null 2>&1
if [[ -f "$WS/probe" && "$(cat "$WS/probe")" == "1" ]]; then
    ok "bwrap integration: workspace writable and IS_SANDBOX set"
else
    bad "bwrap integration: workspace writable and IS_SANDBOX set"
fi
if [[ ! -e "$TMP/escape" ]]; then
    ok "bwrap integration: write outside the writable set is blocked"
else
    bad "bwrap integration: write outside blocked"
fi

# End-to-end: the launcher runs a stub host tool inside the real bwrap sandbox.
# The stub lives in a directory exposed via bwrap.passthrough so its absolute
# path is visible inside the namespace.
TOOLBIN="$TMP/toolbin"; mkdir -p "$TOOLBIN"
printf '#!/bin/sh\nprintf "IS_SANDBOX=%%s PWD=%%s\\n" "$IS_SANDBOX" "$PWD"\n' > "$TOOLBIN/claude"
chmod +x "$TOOLBIN/claude"
printf '#!/bin/sh\n: > "$DOCKER_CAPTURE"\n' > "$TMP/bin/docker"
chmod +x "$TMP/bin/docker"
out="$(HOME="$TMP/home" XDG_STATE_HOME="$TMP/home/.local/state" \
    DOCKER_CAPTURE="$TMP/docker.called" \
    SANDBOX_UID="$(id -u)" SANDBOX_GID="$(id -g)" SANDBOX_USERNAME="$(id -un)" \
    SANDBOX_CLEANUP=false SANDBOX_PROGRESS=false SANDBOX_PROXY_ENV_PASSTHROUGH=false \
    SANDBOX_BWRAP_PASSTHROUGH="$TOOLBIN" \
    AI_SANDBOX_DIR="$SCRIPT_DIR/../../share/ai-sandbox" PATH="$TOOLBIN:$TMP/bin:$PATH" \
    bash "$LAUNCHER" --runtime bwrap --tool claude "$WS" -- 2>&1 || true)"
if echo "$out" | grep -q "IS_SANDBOX=1"; then
    ok "bwrap integration: launcher runs the host tool inside the sandbox"
else
    bad "bwrap integration: launcher sandbox run ($out)"
fi
if echo "$out" | grep -q "PWD=$WS"; then
    ok "bwrap integration: sandbox cwd is the workspace"
else
    bad "bwrap integration: sandbox cwd ($out)"
fi
if [[ ! -e "$TMP/docker.called" ]]; then
    ok "bwrap integration: launcher does not call docker"
else
    bad "bwrap integration: launcher called docker"
fi

# --- bwrap argv assembly: interactive vs detached, generated-file location ---
mkdir -p "$TMP/stub"
cat > "$TMP/stub/bwrap" <<'EOF'
#!/usr/bin/env bash
printf '%s\0' "$@" > "$BWRAP_ARGS_OUT"
exit 0
EOF
cat > "$TMP/stub/opencode" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP/stub/bwrap" "$TMP/stub/opencode"

bwrap_argv_run() {  # ARGS_OUT [extra env...]
    local args_out="$1"; shift
    env HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/home/.config" \
        PATH="$TMP/stub:$PATH" BWRAP_ARGS_OUT="$args_out" "$@" \
        SANDBOX_PROGRESS=false SANDBOX_CLEANUP=false SANDBOX_UID=1234 SANDBOX_GID=1234 \
        SANDBOX_USERNAME=tester SANDBOX_HOME=/home/tester SANDBOX_PROXY_ENV_PASSTHROUGH=false \
        SANDBOX_BWRAP_READ_HOME=false AI_SANDBOX_DIR="$SCRIPT_DIR/../../share/ai-sandbox" \
        bash "$LAUNCHER" --runtime bwrap --tool opencode "$WS" >/dev/null 2>&1
}

# Interactive runs keep --die-with-parent (regression lock).
ARGS="$TMP/bwrap-args-interactive"
bwrap_argv_run "$ARGS"
if tr '\0' ' ' < "$ARGS" | grep -q -- '--die-with-parent'; then
    ok "bwrap interactive argv keeps --die-with-parent"
else
    bad "bwrap interactive argv lost --die-with-parent: $(tr '\0' ' ' < "$ARGS")"
fi

# BWRAP_DETACHED omits --die-with-parent (the detached-server mode).
ARGS2="$TMP/bwrap-args-detached"
bwrap_argv_run "$ARGS2" BWRAP_DETACHED=true
if tr '\0' ' ' < "$ARGS2" | grep -q -- '--die-with-parent'; then
    bad "bwrap detached argv still has --die-with-parent"
else
    ok "bwrap detached argv omits --die-with-parent"
fi

# BWRAP_GENERATED_DIR relocates the generated gitconfig into that directory.
GEN="$TMP/generated"; mkdir -p "$GEN"
ARGS3="$TMP/bwrap-args-generated"
bwrap_argv_run "$ARGS3" BWRAP_GENERATED_DIR="$GEN"
if tr '\0' ' ' < "$ARGS3" | grep -q -- "$GEN/gitconfig"; then
    ok "bwrap generated gitconfig honors BWRAP_GENERATED_DIR"
else
    bad "bwrap generated gitconfig ignored BWRAP_GENERATED_DIR: $(tr '\0' ' ' < "$ARGS3")"
fi

# --- detached bwrap serve lifecycle with a fake opencode (real bwrap) ---
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
        SANDBOX_PROXY_ENV_PASSTHROUGH=false \
        SANDBOX_UID=1234 SANDBOX_GID=1234 SANDBOX_USERNAME=tester SANDBOX_HOME=/home/tester \
        SANDBOX_BWRAP_PASSTHROUGH="$FAKE" \
        OPENCODE_SERVER_PASSWORD= OPENCODE_PASSWORD="test password" \
        AI_SANDBOX_DIR="$SCRIPT_DIR/../../share/ai-sandbox" \
        bash "$LAUNCHER" serve start --runtime bwrap --tool opencode --hostname 0.0.0.0 --port 4613 "$SWS" \
        >/dev/null 2>"$TMP/serve.err"

    if curl -sf -u "opencode:test password" "http://127.0.0.1:4613/api/info" >/dev/null 2>&1; then
        ok "bwrap serve start: detached server reachable on host loopback"
    else
        bad "bwrap serve start: server not reachable ($(cat "$TMP/serve.err"))"
    fi

    env HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/home/.config" \
        SANDBOX_UID=1234 SANDBOX_GID=1234 SANDBOX_USERNAME=tester SANDBOX_HOME=/home/tester \
        AI_SANDBOX_DIR="$SCRIPT_DIR/../../share/ai-sandbox" \
        bash "$LAUNCHER" serve stop --tool opencode "$SWS" >/dev/null 2>&1
    sleep 0.5
    if curl -sf --max-time 2 "http://127.0.0.1:4613/api/info" >/dev/null 2>&1; then
        bad "bwrap serve stop: server still answering"
    else
        ok "bwrap serve stop: detached server torn down"
    fi
else
    skipmsg "node or curl unavailable for the fake server"
fi

echo "$pass passed, $fail failed, $skip skipped"
[[ $fail -eq 0 ]]
