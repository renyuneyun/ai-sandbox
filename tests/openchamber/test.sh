#!/usr/bin/env bash
set -u

# `asb openchamber start|stop` starts a sandboxed OpenCode server (Docker) and
# a host-side OpenChamber UI attached to it, with one command. These tests use
# stub `docker` and `openchamber` binaries to assert the wiring: server first,
# then the UI launched with the external-server environment, the resolved UI
# port captured for `stop`, and the security/validation guardrails.

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LAUNCHER="$ROOT/bin/ai-sandbox"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/dockerbin" "$TMP/ocbin" "$TMP/home" "$TMP/project"

# --- stub docker (mirrors tests/serve/test.sh) ---
cat > "$TMP/dockerbin/docker" <<'EOF'
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
    *ai-sandbox.serve.port*) echo "${DOCKER_STUB_PORT:-4096}" ;;
    *ai-sandbox.serve.hostname*) echo "${DOCKER_STUB_HOSTNAME:-0.0.0.0}" ;;
    *ai-sandbox.serve.package*) echo "${DOCKER_STUB_PACKAGE:-@opencode/cli@2.0.0}" ;;
  esac
fi
EOF
chmod +x "$TMP/dockerbin/docker"

# --- stub openchamber ---
cat > "$TMP/ocbin/openchamber" <<'EOF'
#!/usr/bin/env bash
{
  printf '%s\0' "$@"
  printf '\n'
} >> "$OPENCHAMBER_ARGV"
{
  printf 'OPENCODE_HOST=%s\n' "${OPENCODE_HOST-}"
  printf 'OPENCODE_SKIP_START=%s\n' "${OPENCODE_SKIP_START-}"
  printf 'OPENCODE_PASSWORD=%s\n' "${OPENCODE_PASSWORD-}"
  printf 'OPENCHAMBER_DATA_DIR=%s\n' "${OPENCHAMBER_DATA_DIR-}"
  printf 'OPENCHAMBER_UI_PASSWORD=%s\n' "${OPENCHAMBER_UI_PASSWORD-}"
} >> "$OPENCHAMBER_ENV"

if [[ "${1:-}" == stop ]]; then
  exit 0
fi

port=""; prev=""
for a in "$@"; do
  [[ "$prev" == "--port" ]] && port="$a"
  prev="$a"
done
if [[ -n "$port" && "${STUB_PORT_BUSY:-0}" == 1 ]]; then
  echo "Port $port is already in use by another process." >&2
  exit 1
fi
if [[ -n "$port" ]]; then echo "$port"; else echo "${STUB_FREE_PORT:-3000}"; fi
EOF
chmod +x "$TMP/ocbin/openchamber"

run_launcher() {
  : > "$TMP/dcalls"; : > "$TMP/oargv"; : > "$TMP/oenv"
  env HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/home/.config" \
    PATH="${TEST_PATH_PREFIX:-$TMP/dockerbin:$TMP/ocbin}:$PATH" \
    DOCKER_CALLS="$TMP/dcalls" OPENCHAMBER_ARGV="$TMP/oargv" OPENCHAMBER_ENV="$TMP/oenv" \
    SANDBOX_PROGRESS=false SANDBOX_CLEANUP=false \
    SANDBOX_UID=1234 SANDBOX_GID=1234 SANDBOX_USERNAME=tester SANDBOX_HOME=/home/tester \
    OPENCODE_VERSION=1.18.31 \
    OPENCODE_SERVER_PASSWORD="${TEST_SERVER_PASSWORD-test password}" \
    OPENCODE_PASSWORD="${TEST_OPENCODE_PASSWORD-}" \
    OPENCHAMBER_UI_PASSWORD="${TEST_UI_PASSWORD-ui pass}" \
    STUB_FREE_PORT="${TEST_STUB_FREE_PORT:-3000}" \
    STUB_PORT_BUSY="${TEST_STUB_PORT_BUSY:-0}" \
    DOCKER_EXISTS="${TEST_DOCKER_EXISTS:-0}" \
    DOCKER_RUNNING="${TEST_DOCKER_RUNNING:-true}" \
    DOCKER_STUB_PORT="${TEST_DOCKER_STUB_PORT:-4096}" \
    DOCKER_STUB_PACKAGE="${TEST_DOCKER_STUB_PACKAGE-}" \
    DOCKER_STUB_HOSTNAME="${TEST_DOCKER_STUB_HOSTNAME:-0.0.0.0}" \
    AI_SANDBOX_DIR="$ROOT/share/ai-sandbox" \
    bash "$LAUNCHER" "$@" >"$TMP/out" 2>"$TMP/err"
}

dcalls() { tr '\0' ' ' < "$TMP/dcalls"; }
oargv()  { tr '\0' ' ' < "$TMP/oargv"; }
oenv()   { grep "^$1=" "$TMP/oenv" 2>/dev/null | head -1 | cut -d= -f2-; }
state_port() { cat "$(find "$TMP/home/.local/state/ai-sandbox/serve" -name openchamber.port 2>/dev/null | head -1)" 2>/dev/null; }

fail=0

# --- start: server first, then the host UI attached to it ---
if run_launcher openchamber start --tool opencode@2.0.0 --hostname 10.44.55.66 --port 4096 "$TMP/project"; then
  if dcalls | grep -q 'run -d .*@opencode/cli@2.0.0 serve --hostname 10.44.55.66 --port 4096'; then
    echo 'PASS: openchamber start launches the sandboxed server'
  else
    echo 'FAIL: sandboxed server command'; fail=1
  fi
  if oargv | grep -q -- '--host 0.0.0.0' && ! oargv | grep -q -- '--port'; then
    echo 'PASS: default UI port is not pinned (OpenChamber may reassign it)'
  else
    echo "FAIL: UI argv: $(oargv)"; fail=1
  fi
  if [[ "$(oenv OPENCODE_HOST)" == "http://127.0.0.1:4096" && "$(oenv OPENCODE_SKIP_START)" == "true" ]]; then
    echo 'PASS: UI attaches to the external sandboxed server'
  else
    echo "FAIL: external-server env: $(cat "$TMP/oenv")"; fail=1
  fi
  if [[ "$(oenv OPENCODE_PASSWORD)" == "test password" ]]; then
    echo 'PASS: server password is forwarded to the UI'
  else
    echo 'FAIL: UI password forwarding'; fail=1
  fi
  if grep -q 'http://127.0.0.1:3000' "$TMP/out"; then
    echo 'PASS: start prints the UI URL'
  else
    echo "FAIL: UI URL not printed: $(cat "$TMP/out")"; fail=1
  fi
  if [[ "$(state_port)" == "3000" ]]; then
    echo 'PASS: resolved UI port is recorded for stop'
  else
    echo "FAIL: recorded UI port: $(state_port)"; fail=1
  fi
else
  echo "FAIL: openchamber start rejected: $(cat "$TMP/err")"; fail=1
fi

# --- explicit --ui-port is pinned ---
if run_launcher openchamber start --tool opencode@2.0.0 --ui-port 3001 "$TMP/project"; then
  if oargv | grep -q -- '--port 3001'; then
    echo 'PASS: explicit --ui-port is passed to OpenChamber'
  else
    echo "FAIL: explicit UI port argv: $(oargv)"; fail=1
  fi
  if [[ "$(state_port)" == "3001" ]]; then
    echo 'PASS: explicit UI port is recorded'
  else
    echo "FAIL: explicit UI port recorded: $(state_port)"; fail=1
  fi
else
  echo "FAIL: explicit --ui-port start rejected: $(cat "$TMP/err")"; fail=1
fi

# --- an occupied explicit UI port fails loudly ---
TEST_STUB_PORT_BUSY=1
if run_launcher openchamber start --tool opencode@2.0.0 --ui-port 3001 "$TMP/project"; then
  echo 'FAIL: occupied explicit UI port accepted'; fail=1
else
  if grep -q '3001' "$TMP/err" && grep -qi 'in use' "$TMP/err"; then
    echo 'PASS: occupied explicit UI port is surfaced'
  else
    echo "FAIL: occupied-port diagnostic: $(cat "$TMP/err")"; fail=1
  fi
fi
unset TEST_STUB_PORT_BUSY

# --- the reassigned default port is reported and recorded ---
TEST_STUB_FREE_PORT=3007
if run_launcher openchamber start --tool opencode@2.0.0 "$TMP/project"; then
  if grep -q 'http://127.0.0.1:3007' "$TMP/out" && [[ "$(state_port)" == "3007" ]]; then
    echo 'PASS: a reassigned default port is reported and recorded'
  else
    echo "FAIL: reassigned port handling: out=$(cat "$TMP/out") state=$(state_port)"; fail=1
  fi
else
  echo "FAIL: reassigned-port start rejected: $(cat "$TMP/err")"; fail=1
fi
unset TEST_STUB_FREE_PORT

# --- UI host shorthand: lo is loopback and needs no password ---
TEST_UI_PASSWORD=''
if run_launcher openchamber start --tool opencode@2.0.0 --ui-host lo "$TMP/project"; then
  if oargv | grep -q -- '--host 127.0.0.1'; then
    echo 'PASS: --ui-host lo binds loopback'
  else
    echo "FAIL: loopback UI host argv: $(oargv)"; fail=1
  fi
else
  echo "FAIL: loopback UI start rejected: $(cat "$TMP/err")"; fail=1
fi
unset TEST_UI_PASSWORD

# --- a network-exposed UI without a password falls back to a printed default ---
TEST_UI_PASSWORD=''
if run_launcher openchamber start --tool opencode@2.0.0 --ui-host all "$TMP/project"; then
  if [[ "$(oenv OPENCHAMBER_UI_PASSWORD)" == "openchamber" ]] && grep -q "default 'openchamber'" "$TMP/err"; then
    echo 'PASS: a network bind without a UI password uses a printed default'
  else
    echo "FAIL: default UI password handling: env=$(oenv OPENCHAMBER_UI_PASSWORD) err=$(cat "$TMP/err")"; fail=1
  fi
else
  echo "FAIL: default-UI-password start rejected: $(cat "$TMP/err")"; fail=1
fi
unset TEST_UI_PASSWORD

# --- a missing server password falls back to a printed default ---
TEST_SERVER_PASSWORD='' TEST_OPENCODE_PASSWORD=''
if run_launcher openchamber start --tool opencode@2.0.0 "$TMP/project"; then
  if dcalls | grep -q -- '-e OPENCODE_PASSWORD' && [[ "$(oenv OPENCODE_PASSWORD)" == "opencode" ]] && grep -q "default 'opencode'" "$TMP/err"; then
    echo 'PASS: a missing server password falls back to a printed default'
  else
    echo "FAIL: default server password: docker=$(dcalls) env=$(oenv OPENCODE_PASSWORD) err=$(cat "$TMP/err")"; fail=1
  fi
else
  echo "FAIL: default-server-password start rejected: $(cat "$TMP/err")"; fail=1
fi
unset TEST_SERVER_PASSWORD TEST_OPENCODE_PASSWORD

# --- a missing openchamber binary is refused before Docker ---
if SANDBOX_OPENCHAMBER_BIN="$TMP/no-such-openchamber" run_launcher openchamber start --tool opencode@2.0.0 "$TMP/project"; then
  echo 'FAIL: start accepted without openchamber installed'; fail=1
else
  if grep -q 'no-such-openchamber' "$TMP/err" && [[ ! -s "$TMP/dcalls" ]]; then
    echo 'PASS: a missing openchamber binary is refused before Docker'
  else
    echo "FAIL: missing-binary handling: $(cat "$TMP/err")"; fail=1
  fi
fi

# --- openchamber supports only the OpenCode tool ---
if run_launcher openchamber start --tool claude "$TMP/project"; then
  echo 'FAIL: openchamber accepted a non-opencode tool'; fail=1
else
  if grep -q 'OpenCode' "$TMP/err"; then
    echo 'PASS: openchamber rejects non-opencode tools'
  else
    echo "FAIL: non-opencode diagnostic: $(cat "$TMP/err")"; fail=1
  fi
fi

# --- openchamber requires OpenCode v2 (OpenChamber 2.0.20+) ---
if run_launcher openchamber start --tool opencode@1.18.31 "$TMP/project"; then
  echo 'FAIL: openchamber accepted an OpenCode v1 tool'; fail=1
else
  if grep -q '2.0.20' "$TMP/err" && [[ ! -s "$TMP/dcalls" ]]; then
    echo 'PASS: openchamber requires OpenCode v2 (refused before Docker)'
  else
    echo "FAIL: v1 refusal: $(cat "$TMP/err")"; fail=1
  fi
fi

# --- a data-dir override reaches the UI ---
SANDBOX_OPENCHAMBER_DATA_DIR="$TMP/oc-data" run_launcher openchamber start --tool opencode@2.0.0 "$TMP/project"
if [[ "$(oenv OPENCHAMBER_DATA_DIR)" == "$TMP/oc-data" ]]; then
  echo 'PASS: data-dir override reaches the UI'
else
  echo "FAIL: data-dir forwarding: $(oenv OPENCHAMBER_DATA_DIR)"; fail=1
fi

# --- stop locates the instance in the same configured data dir ---
if SANDBOX_OPENCHAMBER_DATA_DIR="$TMP/oc-data" TEST_DOCKER_EXISTS=1 run_launcher openchamber stop --tool opencode@2.0.0 "$TMP/project"; then
  if [[ "$(oenv OPENCHAMBER_DATA_DIR)" == "$TMP/oc-data" ]]; then
    echo 'PASS: stop targets the configured data dir'
  else
    echo "FAIL: stop data dir: $(oenv OPENCHAMBER_DATA_DIR)"; fail=1
  fi
else
  echo "FAIL: data-dir stop rejected: $(cat "$TMP/err")"; fail=1
fi

# --- reuse: an already-running server is not restarted ---
TEST_DOCKER_EXISTS=1
TEST_DOCKER_RUNNING=true
TEST_DOCKER_STUB_PORT=5090
TEST_DOCKER_STUB_PACKAGE='@opencode/cli@2.0.0'
if run_launcher openchamber start --tool opencode@2.0.0 "$TMP/project"; then
  if ! dcalls | grep -q 'run -d'; then
    echo 'PASS: an already-running server is reused, not restarted'
  else
    echo "FAIL: reuse restarted the server: $(dcalls)"; fail=1
  fi
  if [[ "$(oenv OPENCODE_HOST)" == "http://127.0.0.1:5090" ]]; then
    echo 'PASS: reuse attaches the UI to the running server port'
  else
    echo "FAIL: reuse port: $(oenv OPENCODE_HOST)"; fail=1
  fi
else
  echo "FAIL: reuse start rejected: $(cat "$TMP/err")"; fail=1
fi
unset TEST_DOCKER_EXISTS TEST_DOCKER_RUNNING TEST_DOCKER_STUB_PORT TEST_DOCKER_STUB_PACKAGE

# --- stop: stops the UI instance and the sandboxed server ---
# (state from the explicit --ui-port 3001 run above is still on disk)
TEST_DOCKER_EXISTS=1
if run_launcher openchamber stop --tool opencode@2.0.0 "$TMP/project"; then
  if oargv | grep -q 'stop --port'; then
    echo 'PASS: stop targets the recorded UI instance'
  else
    echo "FAIL: stop UI argv: $(oargv)"; fail=1
  fi
  if dcalls | grep -q 'stop ai-sandbox-serve-1234-' && dcalls | grep -q 'rm ai-sandbox-serve-1234-'; then
    echo 'PASS: stop removes the sandboxed server'
  else
    echo "FAIL: stop server removal: $(dcalls)"; fail=1
  fi
else
  echo "FAIL: openchamber stop rejected: $(cat "$TMP/err")"; fail=1
fi

# --- stop --keep-server leaves the server running ---
if run_launcher openchamber start --tool opencode@2.0.0 --ui-port 3002 "$TMP/project"; then :; else
  echo "FAIL: restart for keep-server rejected: $(cat "$TMP/err")"; fail=1
fi
if run_launcher openchamber stop --keep-server --tool opencode@2.0.0 "$TMP/project"; then
  if oargv | grep -q 'stop --port' && ! dcalls | grep -q 'stop ai-sandbox-serve'; then
    echo 'PASS: stop --keep-server stops the UI but leaves the server'
  else
    echo "FAIL: keep-server: argv=$(oargv) docker=$(dcalls)"; fail=1
  fi
else
  echo "FAIL: keep-server stop rejected: $(cat "$TMP/err")"; fail=1
fi
unset TEST_DOCKER_EXISTS

exit "$fail"