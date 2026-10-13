#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LAUNCHER="$ROOT/bin/ai-sandbox"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home" "$TMP/project"

cat > "$TMP/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\0' "$@" >> "$DOCKER_CALLS"
printf '\n' >> "$DOCKER_CALLS"
case " $* " in
  *" container inspect "*) [[ "${DOCKER_EXISTS:-0}" == 1 ]]; exit $? ;;
esac
if [[ "$1" == inspect ]]; then
  if [[ " $* " == *State.Running* ]]; then
    echo "${DOCKER_RUNNING:-true}"
    exit 0
  fi
  [[ "${DOCKER_EXISTS:-0}" == 1 ]] || exit 1
  case " $* " in
    *ai-sandbox.serve.port*) echo 4096 ;;
    *ai-sandbox.serve.hostname*) echo "${DOCKER_STUB_HOSTNAME:-10.44.55.66}" ;;
    *ai-sandbox.serve.package*) echo "${DOCKER_STUB_PACKAGE:-opencode-ai@1.18.31}" ;;
  esac
fi
if [[ "$1" == exec && "${DOCKER_HEALTH_FAIL:-0}" == 1 ]]; then
  exit 1
fi
if [[ " $* " == *" run -d "* && "${DOCKER_START_FAIL:-0}" == 1 ]]; then
  exit 1
fi
EOF
chmod +x "$TMP/bin/docker"

run_launcher() {
  : > "$TMP/calls"
  env HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/home/.config" \
    PATH="$TMP/bin:$PATH" DOCKER_CALLS="$TMP/calls" \
    SANDBOX_PROGRESS=false SANDBOX_CLEANUP=false \
    SANDBOX_UID=1234 SANDBOX_GID=1234 SANDBOX_USERNAME=tester SANDBOX_HOME=/home/tester \
    OPENCODE_VERSION=1.18.31 OPENCODE_SERVER_PASSWORD="${TEST_SERVER_PASSWORD-test password}" \
    OPENCODE_PASSWORD="${TEST_OPENCODE_PASSWORD-}" \
    DOCKER_EXISTS="${TEST_DOCKER_EXISTS:-0}" \
    DOCKER_START_FAIL="${TEST_DOCKER_START_FAIL:-0}" \
    DOCKER_HEALTH_FAIL="${TEST_DOCKER_HEALTH_FAIL:-0}" \
    DOCKER_RUNNING="${TEST_DOCKER_RUNNING:-true}" \
    DOCKER_STUB_HOSTNAME="${TEST_DOCKER_STUB_HOSTNAME:-10.44.55.66}" \
    DOCKER_STUB_PACKAGE="${DOCKER_STUB_PACKAGE-}" \
    AI_SANDBOX_DIR="$ROOT/share/ai-sandbox" \
    bash "$LAUNCHER" "$@" >"$TMP/out" 2>"$TMP/err"
}

fail=0

# --- bwrap serve stubs and helpers ---
cat > "$TMP/bin/bwrap" <<'EOF'
#!/usr/bin/env bash
printf '%s\0' "$@" >> "$BWRAP_CALLS"; printf '\n' >> "$BWRAP_CALLS"
case " $* " in
  *"/bin/true"*) exit 0 ;;
  *" serve "*|*" web "*) exec sleep 60 ;;
esac
exit 0
EOF
cat > "$TMP/bin/opencode" <<'EOF'
#!/usr/bin/env bash
echo "opencode v${OPENCODE_STUB_VERSION:-2.0.26}"
EOF
cat > "$TMP/bin/node" <<'EOF'
#!/usr/bin/env bash
if [[ "${NODE_STUB_RC:-0}" != 0 ]]; then
  pg="$(cat "$HOME"/.local/state/ai-sandbox/serve/*/server.pgid 2>/dev/null | head -1)"
  [[ -n "$pg" ]] && kill -KILL -- "-$pg" 2>/dev/null
  exit "$NODE_STUB_RC"
fi
exit 0
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
    OPENCODE_SERVER_PASSWORD="${TEST_SERVER_PASSWORD-test password}" \
    OPENCODE_PASSWORD="${TEST_PASSWORD-}" \
    AI_SANDBOX_DIR="$ROOT/share/ai-sandbox" \
    bash "$LAUNCHER" "$@" >"$TMP/out" 2>"$TMP/err"
}

serve_state_path() {
  local h
  h="$(printf '%s' "$TMP/project" | git hash-object --stdin)"
  printf '%s/ai-sandbox/serve/ai-sandbox-serve-1234-%s/serve.state' \
    "$TMP/home/.local/state" "${h:0:12}"
}

cleanup_bwrap() {
  local sf pgid
  sf="$(serve_state_path)"
  pgid="$(sed -n 's/^pgid=//p' "$sf" 2>/dev/null)"
  [[ -n "$pgid" ]] && kill -KILL -- "-$pgid" 2>/dev/null || true
  rm -rf "$TMP/home/.local/state"
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
cleanup_bwrap

# --- the password value never appears in any argv ---
run_bwrap serve start --runtime bwrap --tool opencode "$TMP/project" || true
if tr '\0' '\n' < "$TMP/bwcalls" | grep -q 'test password'; then
  echo 'FAIL: server password leaked into bwrap argv'; fail=1
else
  echo 'PASS: server password is absent from bwrap argv'
fi
cleanup_bwrap

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
cleanup_bwrap

# --- a server that never becomes ready is recorded and stoppable ---
NODE_STUB_RC=1
run_bwrap serve start --runtime bwrap --tool opencode "$TMP/project" && start_rc=0 || start_rc=$?
sf="$(serve_state_path)"
if [[ "$start_rc" != 0 && -f "$sf" ]]; then
  if run_bwrap serve stop --tool opencode "$TMP/project"; then
    echo 'PASS: a never-ready bwrap server is recorded and stoppable'
  else echo "FAIL: stop of never-ready server: $(cat "$TMP/err")"; fail=1; fi
else
  echo "FAIL: never-ready start left no state (rc=$start_rc): $(cat "$TMP/err")"; fail=1
fi
unset NODE_STUB_RC
cleanup_bwrap

# --- a version pin is warned as ignored and the connect message follows the host version ---
if run_bwrap serve start --runtime bwrap --tool opencode@1.18.31 "$TMP/project"; then
  ok=1
  grep -q 'version pins are ignored' "$TMP/err" || ok=0
  grep -q "connect a client with 'asb serve attach'" "$TMP/out" || ok=0
  grep -q 'password from OPENCODE_SERVER_PASSWORD' "$TMP/out" && ok=0
  if [[ "$ok" == 1 ]]; then echo 'PASS: bwrap serve warns on a version pin and follows the host version'
  else echo "FAIL: pin warning/connect message: err=[$(cat "$TMP/err")] out=[$(cat "$TMP/out")]"; fail=1; fi
else
  echo "FAIL: pinned bwrap start failed: $(cat "$TMP/err")"; fail=1
fi
cleanup_bwrap

if run_launcher serve start --tool opencode --hostname 10.44.55.66 --port 4096 "$TMP/project"; then
  if tr '\0' ' ' < "$TMP/calls" | grep -q 'run -d .*opencode-ai@1.18.31 web --hostname 10.44.55.66 --port 4096'; then
    echo 'PASS: detached web server starts in the sandbox'
  else
    echo 'FAIL: detached web server command'; fail=1
  fi
  if tr '\0' ' ' < "$TMP/calls" | grep -q -- '-e OPENCODE_SERVER_PASSWORD'; then
    echo 'PASS: server password is forwarded by name'
  else
    echo 'FAIL: server password forwarding'; fail=1
  fi
  if tr '\0' ' ' < "$TMP/calls" | grep -q -- '--label ai-sandbox.serve.hostname=10.44.55.66'; then
    echo 'PASS: server bind address is recorded for attach'
  else
    echo 'FAIL: server bind address metadata'; fail=1
  fi
  if tr '\0' ' ' < "$TMP/calls" | grep -q -- '--auto web'; then
    echo 'FAIL: TUI-only flag reached web server'; fail=1
  else
    echo 'PASS: web server omits TUI-only flag'
  fi
  if tr '\0' ' ' < "$TMP/calls" | grep -q '/global/health'; then
    echo 'PASS: v1 server health-checks /global/health'
  else
    echo 'FAIL: v1 health path'; fail=1
  fi
  if grep -q 'test password' "$TMP/calls"; then
    echo 'FAIL: password appeared in Docker arguments'; fail=1
  fi
else
  echo "FAIL: start rejected: $(cat "$TMP/err")"; fail=1
fi

# --opt=value (single-token "=") form is accepted for serve the same as "--opt value".
if run_launcher serve start --tool=opencode --hostname=10.44.55.66 --port=5080 "$TMP/project"; then
  if tr '\0' ' ' < "$TMP/calls" | grep -q 'run -d .*opencode-ai@1.18.31 web --hostname 10.44.55.66 --port 5080'; then
    echo 'PASS: detached server starts with --opt=value equals form'
  else
    echo 'FAIL: equals form server command'; fail=1
  fi
else
  echo "FAIL: equals form start rejected: $(cat "$TMP/err")"; fail=1
fi

if run_launcher serve start "$TMP/project"; then
  if tr '\0' ' ' < "$TMP/calls" | grep -q 'opencode-ai@1.18.31 web --hostname 0.0.0.0 --port 4096'; then
    echo 'PASS: default bind accepts host, LAN, and ZeroTier interfaces'
  else
    echo 'FAIL: default bind address or port'; fail=1
  fi
else
  echo 'FAIL: default server start rejected'; fail=1
fi

TEST_DOCKER_EXISTS=1
TEST_DOCKER_STUB_HOSTNAME=0.0.0.0
if run_launcher serve attach "$TMP/project"; then
  if tr '\0' ' ' < "$TMP/calls" | grep -q 'attach http://127.0.0.1:4096'; then
    echo 'PASS: attach reaches an all-interface server over loopback'
  else
    echo 'FAIL: all-interface attach address'; fail=1
  fi
else
  echo 'FAIL: all-interface attach rejected'; fail=1
fi
unset TEST_DOCKER_EXISTS TEST_DOCKER_STUB_HOSTNAME

if run_launcher serve start --hostname lo "$TMP/project"; then
  if tr '\0' ' ' < "$TMP/calls" | grep -q 'web --hostname 127.0.0.1 --port 4096'; then
    echo 'PASS: lo shorthand binds loopback only'
  else
    echo 'FAIL: lo shorthand'; fail=1
  fi
else
  echo 'FAIL: lo shorthand rejected'; fail=1
fi

if run_launcher serve start --hostname local "$TMP/project"; then
  echo 'FAIL: obsolete local shorthand accepted'; fail=1
elif ! grep -q 'use lo' "$TMP/err"; then
  echo 'FAIL: obsolete local shorthand gives no replacement'; fail=1
else
  echo 'PASS: obsolete local shorthand points to lo'
fi

if run_launcher serve start --hostname all "$TMP/project"; then
  if tr '\0' ' ' < "$TMP/calls" | grep -q 'web --hostname 0.0.0.0 --port 4096'; then
    echo 'PASS: all shorthand binds every IPv4 interface'
  else
    echo 'FAIL: all shorthand'; fail=1
  fi
else
  echo 'FAIL: all shorthand rejected'; fail=1
fi

if run_launcher serve start --tool opencode --headless --hostname 10.44.55.66 "$TMP/project"; then
  if tr '\0' ' ' < "$TMP/calls" | grep -q 'opencode-ai@1.18.31 serve --hostname 10.44.55.66'; then
    echo 'PASS: headless mode starts the API server'
  else
    echo 'FAIL: headless mode command'; fail=1
  fi
else
  echo 'FAIL: headless start rejected'; fail=1
fi

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

TEST_DOCKER_EXISTS=1
TEST_SERVER_PASSWORD=''
if run_launcher serve attach --tool opencode "$TMP/project"; then
  if tr '\0' ' ' < "$TMP/calls" | grep -q 'exec -u 1234:1234 .*opencode-ai@1.18.31 attach http://10.44.55.66:4096'; then
    echo 'PASS: TUI attaches inside the running container'
  else
    echo 'FAIL: TUI attach command'; fail=1
  fi
else
  echo 'FAIL: TUI attach rejected'; fail=1
fi

if run_launcher serve stop --tool opencode "$TMP/project"; then
  if tr '\0' ' ' < "$TMP/calls" | grep -q 'stop ai-sandbox-serve-1234-' && \
     tr '\0' ' ' < "$TMP/calls" | grep -q 'rm ai-sandbox-serve-1234-'; then
    echo 'PASS: stop removes the detached container'
  else
    echo 'FAIL: stop container removal'; fail=1
  fi
else
  echo 'FAIL: stop rejected'; fail=1
fi
unset TEST_SERVER_PASSWORD

if run_launcher serve start --tool opencode --hostname 10.44.55.66 "$TMP/project"; then
  echo 'FAIL: duplicate start accepted'; fail=1
else
  if grep -q 'already exists' "$TMP/err"; then
    echo 'PASS: duplicate start rejected'
  else
    echo 'FAIL: duplicate start error'; fail=1
  fi
fi
unset TEST_DOCKER_EXISTS

TEST_SERVER_PASSWORD=''
if run_launcher serve start --hostname 10.44.55.66 "$TMP/project"; then
  echo 'FAIL: empty password accepted'; fail=1
else
  if grep -q 'OPENCODE_SERVER_PASSWORD is required' "$TMP/err" && [[ ! -s "$TMP/calls" ]]; then
    echo 'PASS: empty password rejected before Docker'
  else
    echo 'FAIL: empty password handling'; fail=1
  fi
fi
unset TEST_SERVER_PASSWORD

if run_launcher serve start --hostname 10.44.55.66 --port 0 "$TMP/project"; then
  echo 'FAIL: invalid port accepted'; fail=1
else
  if [[ ! -s "$TMP/calls" ]]; then
    echo 'PASS: invalid port rejected before Docker'
  else
    echo 'FAIL: invalid port reached Docker'; fail=1
  fi
fi

SANDBOX_GIT_POLICY_BLOCK='^stash pop' run_launcher serve start --hostname 10.44.55.66 "$TMP/project"
if find "$TMP/home/.local/state/ai-sandbox/serve" -name 'policy.*' | grep -q .; then
  echo 'PASS: detached server retains its mounted git policy'
else
  echo 'FAIL: git policy mount vanished after start'; fail=1
fi

TEST_DOCKER_EXISTS=1
run_launcher serve stop "$TMP/project"
if [[ ! -d "$TMP/home/.local/state/ai-sandbox/serve" ]] || \
   [[ -z "$(find "$TMP/home/.local/state/ai-sandbox/serve" -name 'policy.*')" ]]; then
  echo 'PASS: stop removes persisted policy files'
else
  echo 'FAIL: stop left policy files'; fail=1
fi
unset TEST_DOCKER_EXISTS

TEST_DOCKER_START_FAIL=1
if SANDBOX_GIT_POLICY_BLOCK='^stash pop' run_launcher serve start --hostname 10.44.55.66 "$TMP/project"; then
  echo 'FAIL: Docker startup failure was ignored'; fail=1
else
  if [[ ! -d "$TMP/home/.local/state/ai-sandbox/serve" ]] || \
     [[ -z "$(find "$TMP/home/.local/state/ai-sandbox/serve" -name 'policy.*')" ]]; then
    echo 'PASS: failed start cleans generated policy files'
  else
    echo 'FAIL: failed start left policy files'; fail=1
  fi
fi

unset TEST_DOCKER_START_FAIL
TEST_DOCKER_HEALTH_FAIL=1
TEST_DOCKER_RUNNING=false
if run_launcher serve start --hostname 10.44.55.66 "$TMP/project"; then
  echo 'FAIL: exited server reported as ready'; fail=1
else
  if grep -q 'did not become ready' "$TMP/err"; then
    echo 'PASS: exited server reports startup failure'
  else
    echo 'FAIL: startup failure diagnostic'; fail=1
  fi
fi

TEST_DOCKER_HEALTH_FAIL=0
if run_launcher serve start --hostname 10.44.55.66 "$TMP/project"; then
  echo 'FAIL: stopped container accepted a port response from another process'; fail=1
else
  if grep -q 'did not become ready' "$TMP/err"; then
    echo 'PASS: startup requires the server container to remain running'
  else
    echo 'FAIL: stopped-container diagnostic'; fail=1
  fi
fi

# --- stop signals the recorded process group of a bwrap server ---
sf="$(serve_state_path)"; rm -rf "$(dirname "$sf")"; mkdir -p "$(dirname "$sf")"
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
  kill -KILL -- "-$livepgid" 2>/dev/null || true
fi

# --- attach builds the interactive sandbox with the recorded URL ---
sf="$(serve_state_path)"; rm -rf "$(dirname "$sf")"; mkdir -p "$(dirname "$sf")"
setsid sh -c 'echo $$ > "$1"; exec sleep 300' _ "$TMP/att.pgid" &
sleep 0.3
attpgid="$(cat "$TMP/att.pgid")"
{
  echo "runtime=bwrap"; echo "package=@opencode/cli@2.0.26"
  echo "port=4096"; echo "hostname=0.0.0.0"
  echo "pgid=$attpgid"; echo "pw_var=OPENCODE_PASSWORD"
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
kill -KILL -- "-$attpgid" 2>/dev/null || true
rm -rf "$TMP/home/.local/state"

exit "$fail"
