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

echo "$pass passed, $fail failed, $skip skipped"
[[ $fail -eq 0 ]]
