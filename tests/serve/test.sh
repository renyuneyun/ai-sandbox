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
    *ai-sandbox.serve.package*) echo opencode-ai@1.18.31 ;;
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
    DOCKER_EXISTS="${TEST_DOCKER_EXISTS:-0}" \
    DOCKER_START_FAIL="${TEST_DOCKER_START_FAIL:-0}" \
    DOCKER_HEALTH_FAIL="${TEST_DOCKER_HEALTH_FAIL:-0}" \
    DOCKER_RUNNING="${TEST_DOCKER_RUNNING:-true}" \
    DOCKER_STUB_HOSTNAME="${TEST_DOCKER_STUB_HOSTNAME:-10.44.55.66}" \
    AI_SANDBOX_DIR="$ROOT/share/ai-sandbox" \
    bash "$LAUNCHER" "$@" >"$TMP/out" 2>"$TMP/err"
}

fail=0
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
  if grep -q 'test password' "$TMP/calls"; then
    echo 'FAIL: password appeared in Docker arguments'; fail=1
  fi
else
  echo "FAIL: start rejected: $(cat "$TMP/err")"; fail=1
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

if run_launcher serve start --tool opencode@2.0.0 --hostname 10.44.55.66 "$TMP/project"; then
  echo 'FAIL: v2 server unexpectedly accepted'; fail=1
else
  echo 'PASS: v2 server rejected'
fi

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

exit "$fail"
