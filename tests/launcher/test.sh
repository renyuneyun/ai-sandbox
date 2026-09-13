#!/bin/bash
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER="$SCRIPT_DIR/../../bin/ai-sandbox"
# shellcheck source=/dev/null
source "$LAUNCHER"

pass=0
fail=0
PROFILE_TMP_DIRS=()
cleanup_launcher_tests() {
    local dir
    for dir in "${PROFILE_TMP_DIRS[@]}"; do
        rm -rf "$dir"
    done
}
trap cleanup_launcher_tests EXIT

ok() { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then ok "$name"; else bad "$name (expected '$expected', got '$actual')"; fi
}

unset HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY
unset http_proxy https_proxy all_proxy no_proxy

if declare -F configure_proxy_env >/dev/null; then
    SANDBOX_PROXY_ENV_PASSTHROUGH=true
    HTTP_PROXY='http://uppercase-http.test:8001'
    HTTPS_PROXY='http://user:p@ss@uppercase-https.test:8002/path with space'
    ALL_PROXY='socks5://uppercase-all.test:8003'
    NO_PROXY='localhost,127.0.0.1,.internal.test'
    http_proxy='http://lowercase-http.test:9001'
    https_proxy='http://lowercase-https.test:9002'
    all_proxy='socks5://lowercase-all.test:9003'
    no_proxy='localhost,.lowercase.test'
    configure_proxy_env
    assert_eq "proxy: all eight variables produce argument pairs" "16" "${#PROXY_ENV_ARGS[@]}"
    PROXY_JOINED="$(printf '<%s>' "${PROXY_ENV_ARGS[@]}")"
    [[ "$PROXY_JOINED" == *'<HTTPS_PROXY=http://user:p@ss@uppercase-https.test:8002/path with space>'* ]] &&
      ok "proxy: values preserve spaces and punctuation" ||
      bad "proxy: values preserve spaces and punctuation ($PROXY_JOINED)"
    [[ "$PROXY_JOINED" == *'<HTTP_PROXY=http://uppercase-http.test:8001>'* &&
       "$PROXY_JOINED" == *'<ALL_PROXY=socks5://uppercase-all.test:8003>'* &&
       "$PROXY_JOINED" == *'<NO_PROXY=localhost,127.0.0.1,.internal.test>'* &&
       "$PROXY_JOINED" == *'<http_proxy=http://lowercase-http.test:9001>'* &&
       "$PROXY_JOINED" == *'<https_proxy=http://lowercase-https.test:9002>'* &&
       "$PROXY_JOINED" == *'<all_proxy=socks5://lowercase-all.test:9003>'* &&
       "$PROXY_JOINED" == *'<no_proxy=localhost,.lowercase.test>'* ]] &&
      ok "proxy: uppercase and lowercase names are forwarded independently" ||
      bad "proxy: uppercase and lowercase names ($PROXY_JOINED)"

    HTTPS_PROXY=
    configure_proxy_env
    assert_eq "proxy: empty variables are omitted" "14" "${#PROXY_ENV_ARGS[@]}"

    SANDBOX_PROXY_ENV_PASSTHROUGH=false
    configure_proxy_env
    assert_eq "proxy: disabled passthrough emits no arguments" "0" "${#PROXY_ENV_ARGS[@]}"
else
    bad "proxy: configure_proxy_env function exists"
fi

unset HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY
unset http_proxy https_proxy all_proxy no_proxy SANDBOX_PROXY_ENV_PASSTHROUGH

parse_launcher_args
assert_eq "parse: default workspace is empty sentinel" "" "$WORKSPACE_ARG"
assert_eq "parse: no CLI tool override" "" "$CLI_TOOL"
assert_eq "parse: no tool args" "0" "${#TOOL_USER_ARGS[@]}"

parse_launcher_args --tool codex "/tmp/project with spaces" -- --model "gpt-5.4" "prompt with spaces"
assert_eq "parse: tool" "codex" "$CLI_TOOL"
assert_eq "parse: workspace" "/tmp/project with spaces" "$WORKSPACE_ARG"
assert_eq "parse: passthrough count" "3" "${#TOOL_USER_ARGS[@]}"
assert_eq "parse: passthrough first" "--model" "${TOOL_USER_ARGS[0]}"
assert_eq "parse: passthrough spaced value" "prompt with spaces" "${TOOL_USER_ARGS[2]}"

parse_launcher_args --allow-local-git
assert_eq "parse: allow-local-git sets CLI_ALLOW_LOCAL_GIT" "true" "${CLI_ALLOW_LOCAL_GIT:-}"

parse_launcher_args
assert_eq "parse: no flag leaves CLI_ALLOW_LOCAL_GIT empty" "" "${CLI_ALLOW_LOCAL_GIT:-}"

parse_launcher_args --allow-local-git --tool codex
assert_eq "parse: allow-local-git with tool" "true" "${CLI_ALLOW_LOCAL_GIT:-}"
assert_eq "parse: tool with allow-local-git" "codex" "$CLI_TOOL"

parse_launcher_args --tool codex --allow-local-git
assert_eq "parse: flag order independence (tool)" "codex" "$CLI_TOOL"
assert_eq "parse: flag order independence (override)" "true" "${CLI_ALLOW_LOCAL_GIT:-}"

# Reset state
unset CLI_ALLOW_LOCAL_GIT

if parse_launcher_args --tool >/dev/null 2>&1; then bad "parse: missing tool value"; else ok "parse: missing tool value"; fi
if parse_launcher_args --bogus >/dev/null 2>&1; then bad "parse: unsupported option"; else ok "parse: unsupported option"; fi
if parse_launcher_args one two >/dev/null 2>&1; then bad "parse: multiple workspaces"; else ok "parse: multiple workspaces"; fi

WORKSPACE_CONFIG_VALID=false
USER_CONFIG_VALID=false
unset SANDBOX_TOOL
assert_eq "select: default Claude" "claude" "$(resolve_tool "")"
SANDBOX_TOOL=codex
assert_eq "select: environment" "codex" "$(resolve_tool "")"
SANDBOX_TOOL=opencode
assert_eq "select: environment opencode" "opencode" "$(resolve_tool "")"
assert_eq "select: CLI beats environment" "claude" "$(resolve_tool claude)"
unset SANDBOX_TOOL
if resolve_tool unknown >/dev/null 2>&1; then bad "select: unknown tool"; else ok "select: unknown tool"; fi
unset SANDBOX_TOOL

if command -v yq >/dev/null 2>&1; then
    LAUNCHER_TMP="$(mktemp -d)"
    PROFILE_TMP_DIRS+=("$LAUNCHER_TMP")
    printf 'tool: codex\n' > "$LAUNCHER_TMP/workspace.yaml"
    printf 'tool: claude\n' > "$LAUNCHER_TMP/user.yaml"
    WORKSPACE_CONFIG="$LAUNCHER_TMP/workspace.yaml"
    USER_CONFIG="$LAUNCHER_TMP/user.yaml"
    WORKSPACE_CONFIG_VALID=true
    USER_CONFIG_VALID=true
    assert_eq "select: workspace beats user" "codex" "$(resolve_tool "")"
    SANDBOX_TOOL=claude
    assert_eq "select: environment beats workspace" "claude" "$(resolve_tool "")"
    assert_eq "select: CLI beats all config" "codex" "$(resolve_tool codex)"
    unset SANDBOX_TOOL

    WORKSPACE_CONFIG_VALID=false
    assert_eq "select: user fills workspace gap" "claude" "$(resolve_tool "")"
fi

# --- resolve_allow_local tests ---
# Follows the resolve_tool pattern: CLI value wins, else resolve() from env/config/default.

# Without yq, only env var and default matter
WORKSPACE_CONFIG_VALID=false
USER_CONFIG_VALID=false
unset SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS
assert_eq "resolve_allow_local: default false" "false" "$(resolve_allow_local "")"
assert_eq "resolve_allow_local: CLI true wins" "true" "$(resolve_allow_local true)"
SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS=true
assert_eq "resolve_allow_local: env true" "true" "$(resolve_allow_local "")"
SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS=false
assert_eq "resolve_allow_local: env false" "false" "$(resolve_allow_local "")"
assert_eq "resolve_allow_local: CLI true beats env false" "true" "$(resolve_allow_local true)"
unset SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS

if command -v yq >/dev/null 2>&1; then
    ALLOW_TMP="$(mktemp -d)"
    PROFILE_TMP_DIRS+=("$ALLOW_TMP")
    printf 'git:\n  allow_local_operations: true\n' > "$ALLOW_TMP/workspace.yaml"
    printf 'git:\n  allow_local_operations: false\n' > "$ALLOW_TMP/user.yaml"
    WORKSPACE_CONFIG="$ALLOW_TMP/workspace.yaml"
    USER_CONFIG="$ALLOW_TMP/user.yaml"
    WORKSPACE_CONFIG_VALID=true
    USER_CONFIG_VALID=true
    unset SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS
    assert_eq "resolve_allow_local: workspace true beats user false" "true" "$(resolve_allow_local "")"
    WORKSPACE_CONFIG_VALID=false
    assert_eq "resolve_allow_local: user false when workspace invalid" "false" "$(resolve_allow_local "")"
    SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS=true
    assert_eq "resolve_allow_local: env beats workspace" "true" "$(resolve_allow_local "")"
    assert_eq "resolve_allow_local: CLI beats env" "false" "$(resolve_allow_local false)"
    unset SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS
fi

# Restore state for subsequent tests
WORKSPACE_CONFIG_VALID=false
USER_CONFIG_VALID=false

reset_profile_context() {
    PROFILE_TMP="$(mktemp -d)"
    PROFILE_TMP_DIRS+=("$PROFILE_TMP")
    HOME="$PROFILE_TMP/host-home"
    SANDBOX_HOME="/home/tester"
    mkdir -p "$HOME/.claude" "$HOME/.codex" "$HOME/.config/opencode" "$HOME/.local/share/opencode"
    printf '{}\n' > "$HOME/.claude.json"
    WORKSPACE_CONFIG="$PROFILE_TMP/missing-workspace.yaml"
    USER_CONFIG="$PROFILE_TMP/missing-user.yaml"
    WORKSPACE_CONFIG_VALID=false
    USER_CONFIG_VALID=false
    unset CLAUDE_VERSION CLAUDE_CONFIG_PASSTHROUGH CLAUDE_CONFIG_DIR CLAUDE_CONFIG_FILE
    unset CODEX_VERSION CODEX_CONFIG_PASSTHROUGH CODEX_CONFIG_DIR
    unset OPENCODE_VERSION OPENCODE_CONFIG_PASSTHROUGH OPENCODE_DATA_PASSTHROUGH OPENCODE_CONFIG_DIR OPENCODE_DATA_DIR
    unset ANTHROPIC_API_KEY OPENAI_API_KEY
}

reset_profile_context
CLAUDE_VERSION=2.1.152
ANTHROPIC_API_KEY=anthropic-secret
OPENAI_API_KEY=openai-secret
configure_tool claude
assert_eq "profile Claude: package" "@anthropic-ai/claude-code@2.1.152" "$TOOL_PACKAGE"
assert_eq "profile Claude: autonomy flag" "--dangerously-skip-permissions" "${TOOL_DEFAULT_ARGS[0]}"
assert_eq "profile Claude: two mounts" "4" "${#TOOL_VOLUME_ARGS[@]}"
assert_eq "profile Claude: only one API key pair" "2" "${#TOOL_ENV_ARGS[@]}"
assert_eq "profile Claude: API key name" "ANTHROPIC_API_KEY=anthropic-secret" "${TOOL_ENV_ARGS[1]}"

reset_profile_context
CODEX_VERSION=1.2.3
ANTHROPIC_API_KEY=anthropic-secret
OPENAI_API_KEY=openai-secret
configure_tool codex
assert_eq "profile Codex: package" "@openai/codex@1.2.3" "$TOOL_PACKAGE"
assert_eq "profile Codex: autonomy flag" "--dangerously-bypass-approvals-and-sandbox" "${TOOL_DEFAULT_ARGS[0]}"
assert_eq "profile Codex: one mount" "2" "${#TOOL_VOLUME_ARGS[@]}"
assert_eq "profile Codex: mount destination" "$HOME/.codex:$SANDBOX_HOME/.codex" "${TOOL_VOLUME_ARGS[1]}"
assert_eq "profile Codex: only one API key pair" "2" "${#TOOL_ENV_ARGS[@]}"
assert_eq "profile Codex: API key name" "OPENAI_API_KEY=openai-secret" "${TOOL_ENV_ARGS[1]}"

reset_profile_context
CODEX_CONFIG_PASSTHROUGH=false
configure_tool codex
assert_eq "profile Codex: disabled passthrough" "0" "${#TOOL_VOLUME_ARGS[@]}"

reset_profile_context
CODEX_CONFIG_DIR="$PROFILE_TMP/custom codex"
mkdir -p "$CODEX_CONFIG_DIR"
configure_tool codex
assert_eq "profile Codex: custom mount preserves spaces" "$CODEX_CONFIG_DIR:$SANDBOX_HOME/.codex" "${TOOL_VOLUME_ARGS[1]}"

reset_profile_context
STUB_BIN="$PROFILE_TMP/bin"
mkdir -p "$STUB_BIN"
printf '#!/bin/sh\nprintf "codex-cli 4.5.6\\n"\n' > "$STUB_BIN/codex"
chmod +x "$STUB_BIN/codex"
OLD_PATH="$PATH"
PATH="$STUB_BIN:$PATH"
configure_tool codex
assert_eq "profile Codex: host version fallback" "@openai/codex@4.5.6" "$TOOL_PACKAGE"
PATH="$OLD_PATH"

reset_profile_context
EMPTY_BIN="$PROFILE_TMP/empty-bin"
/bin/mkdir -p "$EMPTY_BIN"
PATH="$EMPTY_BIN"
configure_tool codex
assert_eq "profile Codex: absent host CLI is unpinned" "@openai/codex" "$TOOL_PACKAGE"
PATH="$OLD_PATH"

reset_profile_context
OPENCODE_VERSION=0.6.9
ANTHROPIC_API_KEY=anthropic-secret
OPENAI_API_KEY=openai-secret
configure_tool opencode
assert_eq "profile OpenCode: package" "opencode-ai@0.6.9" "$TOOL_PACKAGE"
assert_eq "profile OpenCode: autonomy flag" "--auto" "${TOOL_DEFAULT_ARGS[0]}"
assert_eq "profile OpenCode: two mounts" "4" "${#TOOL_VOLUME_ARGS[@]}"
assert_eq "profile OpenCode: config mount destination" "$HOME/.config/opencode:$SANDBOX_HOME/.config/opencode" "${TOOL_VOLUME_ARGS[1]}"
assert_eq "profile OpenCode: data mount destination" "$HOME/.local/share/opencode:$SANDBOX_HOME/.local/share/opencode" "${TOOL_VOLUME_ARGS[3]}"
assert_eq "profile OpenCode: two API key pairs" "4" "${#TOOL_ENV_ARGS[@]}"
[[ "$(printf '<%s>' "${TOOL_ENV_ARGS[@]}")" == *"<ANTHROPIC_API_KEY=anthropic-secret>"* &&
   "$(printf '<%s>' "${TOOL_ENV_ARGS[@]}")" == *"<OPENAI_API_KEY=openai-secret>"* ]] &&
  ok "profile OpenCode: both API key names forwarded" ||
  bad "profile OpenCode: both API key names forwarded ($(printf '<%s>' "${TOOL_ENV_ARGS[@]}"))"

reset_profile_context
OPENCODE_CONFIG_PASSTHROUGH=false
OPENCODE_DATA_PASSTHROUGH=false
configure_tool opencode
assert_eq "profile OpenCode: both passthroughs disabled" "0" "${#TOOL_VOLUME_ARGS[@]}"

reset_profile_context
OPENCODE_CONFIG_PASSTHROUGH=false
configure_tool opencode
assert_eq "profile OpenCode: config-only passthrough" "2" "${#TOOL_VOLUME_ARGS[@]}"
assert_eq "profile OpenCode: data-only mount destination" "$HOME/.local/share/opencode:$SANDBOX_HOME/.local/share/opencode" "${TOOL_VOLUME_ARGS[1]}"

reset_profile_context
OPENCODE_CONFIG_DIR="$PROFILE_TMP/custom opencode config"
OPENCODE_DATA_DIR="$PROFILE_TMP/custom opencode data"
mkdir -p "$OPENCODE_CONFIG_DIR" "$OPENCODE_DATA_DIR"
configure_tool opencode
assert_eq "profile OpenCode: custom config mount preserves spaces" "$OPENCODE_CONFIG_DIR:$SANDBOX_HOME/.config/opencode" "${TOOL_VOLUME_ARGS[1]}"
assert_eq "profile OpenCode: custom data mount preserves spaces" "$OPENCODE_DATA_DIR:$SANDBOX_HOME/.local/share/opencode" "${TOOL_VOLUME_ARGS[3]}"

reset_profile_context
STUB_BIN="$PROFILE_TMP/bin"
mkdir -p "$STUB_BIN"
printf '#!/bin/sh\nprintf "opencode 7.7.7\\n"\n' > "$STUB_BIN/opencode"
chmod +x "$STUB_BIN/opencode"
OLD_PATH="$PATH"
PATH="$STUB_BIN:$PATH"
configure_tool opencode
assert_eq "profile OpenCode: host version fallback" "opencode-ai@7.7.7" "$TOOL_PACKAGE"
PATH="$OLD_PATH"

reset_profile_context
EMPTY_BIN="$PROFILE_TMP/empty-bin"
/bin/mkdir -p "$EMPTY_BIN"
PATH="$EMPTY_BIN"
configure_tool opencode
assert_eq "profile OpenCode: absent host CLI is unpinned" "opencode-ai" "$TOOL_PACKAGE"
PATH="$OLD_PATH"

# PATH is emptied so detect_host_version finds no `opencode` on PATH. Otherwise
# an installed host opencode would run during version detection and create
# ~/.config/opencode & ~/.local/share/opencode inside the fresh HOME, making the
# "absent" dirs exist and the mounts happen. (Same trick as the version tests.)
reset_profile_context
STUB_BIN="$PROFILE_TMP/absent-dirs"
NO_PATH="$PROFILE_TMP/nopath"
mkdir -p "$STUB_BIN" "$NO_PATH"
HOME="$PROFILE_TMP/empty-host-home"
PATH="$NO_PATH"
configure_tool opencode
assert_eq "profile OpenCode: absent host dirs are not mounted" "0" "${#TOOL_VOLUME_ARGS[@]}"
PATH="$OLD_PATH"

run_captured_launcher() {
    local capture_dir="$1"
    shift
    mkdir -p "$capture_dir/bin" "$capture_dir/home"
    printf '#!/bin/sh\nprintf "%%s\\0" "$@" > "$DOCKER_CAPTURE"\n' > "$capture_dir/bin/docker"
    chmod +x "$capture_dir/bin/docker"
    DOCKER_CAPTURE="$capture_dir/docker.args" \
    HOME="$capture_dir/home" \
    XDG_CONFIG_HOME="$capture_dir/home/.config" \
    SANDBOX_UID=1234 \
    SANDBOX_GID=1234 \
    SANDBOX_USERNAME=tester \
    SANDBOX_HOME=/home/tester \
    SANDBOX_CLEANUP=false \
    CLAUDE_VERSION=integration-test \
    CODEX_VERSION=integration-test \
    OPENCODE_VERSION=integration-test \
    HTTP_PROXY="${TEST_HTTP_PROXY:-}" \
    HTTPS_PROXY= ALL_PROXY= NO_PROXY= \
    http_proxy= https_proxy= all_proxy= no_proxy= \
    SANDBOX_PROXY_ENV_PASSTHROUGH="${TEST_PROXY_PASSTHROUGH:-true}" \
    AI_SANDBOX_DIR="$SCRIPT_DIR/../../share/ai-sandbox" \
    PATH="$capture_dir/bin:$PATH" \
      bash "$LAUNCHER" "$@"
    mapfile -d '' -t CAPTURED_DOCKER_ARGS < "$capture_dir/docker.args"
}

CAPTURE_DIR="$(mktemp -d)"
PROFILE_TMP_DIRS+=("$CAPTURE_DIR")
TEST_HTTP_PROXY='http://codex-proxy.test:7890'
run_captured_launcher "$CAPTURE_DIR" --tool codex "$SCRIPT_DIR/../.." -- --model "gpt test" resume
CAPTURED_JOINED="$(printf '<%s>' "${CAPTURED_DOCKER_ARGS[@]}")"
[[ "$CAPTURED_JOINED" == *"<@openai/codex"* ]] &&
  ok "integration: Codex package reaches Docker" ||
  bad "integration: Codex package reaches Docker ($CAPTURED_JOINED)"
[[ "$CAPTURED_JOINED" == *"<--dangerously-bypass-approvals-and-sandbox><--model><gpt test><resume>"* ]] &&
  ok "integration: defaults precede exact passthrough args" ||
  bad "integration: passthrough ordering ($CAPTURED_JOINED)"
[[ "$CAPTURED_JOINED" == *"<-e><HTTP_PROXY=http://codex-proxy.test:7890>"* ]] &&
  ok "integration: proxy reaches Codex Docker invocation" ||
  bad "integration: proxy reaches Codex Docker invocation ($CAPTURED_JOINED)"

CAPTURE_DIR_OPENCODE="$(mktemp -d)"
PROFILE_TMP_DIRS+=("$CAPTURE_DIR_OPENCODE")
run_captured_launcher "$CAPTURE_DIR_OPENCODE" --tool opencode "$SCRIPT_DIR/../.." -- --model "test model" resume
CAPTURED_JOINED="$(printf '<%s>' "${CAPTURED_DOCKER_ARGS[@]}")"
[[ "$CAPTURED_JOINED" == *"<opencode-ai@integration-test"* ]] &&
  ok "integration: OpenCode package reaches Docker" ||
  bad "integration: OpenCode package reaches Docker ($CAPTURED_JOINED)"
[[ "$CAPTURED_JOINED" == *"<--auto><--model><test model><resume>"* ]] &&
  ok "integration: OpenCode defaults precede exact passthrough args" ||
  bad "integration: OpenCode passthrough ordering ($CAPTURED_JOINED)"

CAPTURE_DIR_2="$(mktemp -d)"
PROFILE_TMP_DIRS+=("$CAPTURE_DIR_2")
TEST_PROXY_PASSTHROUGH=false
run_captured_launcher "$CAPTURE_DIR_2" "$SCRIPT_DIR/../.."
CAPTURED_JOINED="$(printf '<%s>' "${CAPTURED_DOCKER_ARGS[@]}")"
[[ "$CAPTURED_JOINED" == *"<@anthropic-ai/claude-code"*"<--dangerously-skip-permissions>"* ]] &&
  ok "integration: default invocation remains Claude" ||
  bad "integration: default invocation remains Claude ($CAPTURED_JOINED)"
[[ "$CAPTURED_JOINED" != *"<HTTP_PROXY=http://codex-proxy.test:7890>"* ]] &&
  ok "integration: disabled proxy does not reach Docker" ||
  bad "integration: disabled proxy reaches Docker ($CAPTURED_JOINED)"
unset TEST_HTTP_PROXY TEST_PROXY_PASSTHROUGH

# --- GIT_MODE_ENV_ARGS integration tests ---
CAPTURE_DIR_OVERRIDE="$(mktemp -d)"
PROFILE_TMP_DIRS+=("$CAPTURE_DIR_OVERRIDE")
run_captured_launcher "$CAPTURE_DIR_OVERRIDE" --allow-local-git "$SCRIPT_DIR/../.."
CAPTURED_JOINED="$(printf '<%s>' "${CAPTURED_DOCKER_ARGS[@]}")"
[[ "$CAPTURED_JOINED" == *"<-e><SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS=true>"* ]] &&
  ok "integration: --allow-local-git reaches Docker env" ||
  bad "integration: --allow-local-git reaches Docker env ($CAPTURED_JOINED)"

CAPTURE_DIR_NO_OVERRIDE="$(mktemp -d)"
PROFILE_TMP_DIRS+=("$CAPTURE_DIR_NO_OVERRIDE")
run_captured_launcher "$CAPTURE_DIR_NO_OVERRIDE" "$SCRIPT_DIR/../.."
CAPTURED_JOINED="$(printf '<%s>' "${CAPTURED_DOCKER_ARGS[@]}")"
[[ "$CAPTURED_JOINED" != *"<SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS=true>"* ]] &&
  ok "integration: no override flag omits env var" ||
  bad "integration: no override flag omits env var ($CAPTURED_JOINED)"

CAPTURE_DIR_ENV_OVERRIDE="$(mktemp -d)"
PROFILE_TMP_DIRS+=("$CAPTURE_DIR_ENV_OVERRIDE")
SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS=true run_captured_launcher "$CAPTURE_DIR_ENV_OVERRIDE" "$SCRIPT_DIR/../.."
CAPTURED_JOINED="$(printf '<%s>' "${CAPTURED_DOCKER_ARGS[@]}")"
[[ "$CAPTURED_JOINED" == *"<-e><SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS=true>"* ]] &&
  ok "integration: env var override reaches Docker" ||
  bad "integration: env var override reaches Docker ($CAPTURED_JOINED)"
unset SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS

# --- Extra mount (configure_extra_mounts) tests ---
reset_extra_mounts() {
    SANDBOX_EXTRA_MOUNTS=""
    SANDBOX_EXTRA_MOUNTS_ENABLED=true
}

# No mounts configured -> no volume args
reset_extra_mounts
configure_extra_mounts
assert_eq "extra: empty list emits nothing" "0" "${#EXTRA_MOUNT_VOLUME_ARGS[@]}"

# Disabled -> no volume args even when mounts are set
reset_extra_mounts
SANDBOX_EXTRA_MOUNTS="~/.config/cc-switch"
SANDBOX_EXTRA_MOUNTS_ENABLED=false
configure_extra_mounts
assert_eq "extra: disabled emits nothing" "0" "${#EXTRA_MOUNT_VOLUME_ARGS[@]}"

# Host-only spec: same path, ~ expanded, default read-only
reset_extra_mounts
HOME="/host/alice"
SANDBOX_EXTRA_MOUNTS="~/.config/cc-switch"
configure_extra_mounts
assert_eq "extra: host-only spec" "-v" "${EXTRA_MOUNT_VOLUME_ARGS[0]}"
assert_eq "extra: host-only destination" "/host/alice/.config/cc-switch:/host/alice/.config/cc-switch:ro" "${EXTRA_MOUNT_VOLUME_ARGS[1]}"

# Absolute host-only spec, no expansion, default ro
reset_extra_mounts
SANDBOX_EXTRA_MOUNTS="/opt/shared"
configure_extra_mounts
assert_eq "extra: absolute host-only" "-v" "${EXTRA_MOUNT_VOLUME_ARGS[0]}"
assert_eq "extra: absolute host-only dest" "/opt/shared:/opt/shared:ro" "${EXTRA_MOUNT_VOLUME_ARGS[1]}"

# Explicit container destination + rw flag
reset_extra_mounts
HOME="/host/alice"
SANDBOX_EXTRA_MOUNTS="~/.cache/npm:/home/user/.cache/npm:rw"
configure_extra_mounts
assert_eq "extra: explicit dest rw" "/host/alice/.cache/npm:/home/user/.cache/npm:rw" "${EXTRA_MOUNT_VOLUME_ARGS[1]}"

# Multiple specs on separate lines
reset_extra_mounts
HOME="/host/alice"
printf '~/.config/cc-switch\n~/.cache/npm:/home/user/.cache/npm:rw\n' > "$PROFILE_TMP/mounts.txt"
SANDBOX_EXTRA_MOUNTS="$(cat "$PROFILE_TMP/mounts.txt")"
configure_extra_mounts
assert_eq "extra: two specs produce two -v pairs" "4" "${#EXTRA_MOUNT_VOLUME_ARGS[@]}"
assert_eq "extra: first spec" "/host/alice/.config/cc-switch:/host/alice/.config/cc-switch:ro" "${EXTRA_MOUNT_VOLUME_ARGS[1]}"
assert_eq "extra: second spec" "/host/alice/.cache/npm:/home/user/.cache/npm:rw" "${EXTRA_MOUNT_VOLUME_ARGS[3]}"

# Lines with surrounding whitespace are trimmed; blank lines ignored
reset_extra_mounts
HOME="/host/alice"
SANDBOX_EXTRA_MOUNTS=$'  ~/.config/cc-switch  \n   \n~/.cache/npm:ro'
configure_extra_mounts
assert_eq "extra: whitespace trimmed count" "4" "${#EXTRA_MOUNT_VOLUME_ARGS[@]}"
assert_eq "extra: whitespace trimmed first" "/host/alice/.config/cc-switch:/host/alice/.config/cc-switch:ro" "${EXTRA_MOUNT_VOLUME_ARGS[1]}"
assert_eq "extra: whitespace trimmed third" "/host/alice/.cache/npm:/host/alice/.cache/npm:ro" "${EXTRA_MOUNT_VOLUME_ARGS[3]}"

# A single trailing-token "host:ro" is treated as a flag, container == host
assert_eq "extra: host:flag keeps same path" "/host/alice/.cache/npm:/host/alice/.cache/npm:ro" "${EXTRA_MOUNT_VOLUME_ARGS[3]}"

reset_extra_mounts
unset HOME

# --- Extra mount integration: specs reach docker compose run ---
# run_captured_launcher sets HOME=$capture_dir/home, so "~" expands there.
CAPTURE_DIR_EXTRA="$(mktemp -d)"
PROFILE_TMP_DIRS+=("$CAPTURE_DIR_EXTRA")
SANDBOX_EXTRA_MOUNTS="~/.config/cc-switch:/home/tester/.config/cc-switch:ro" \
run_captured_launcher "$CAPTURE_DIR_EXTRA" "$SCRIPT_DIR/../.."
CAPTURED_JOINED="$(printf '<%s>' "${CAPTURED_DOCKER_ARGS[@]}")"
[[ "$CAPTURED_JOINED" == *"<-v><$CAPTURE_DIR_EXTRA/home/.config/cc-switch:/home/tester/.config/cc-switch:ro>"* ]] &&
  ok "extra: mount reaches docker compose run" ||
  bad "extra: mount reaches docker compose run ($CAPTURED_JOINED)"

# --- Auto-detect mount tests (git worktree / symlinks) ---
reset_auto_mounts() {
    SANDBOX_EXTRA_MOUNTS_ENABLED=true
    SANDBOX_AUTO_GIT_WORKTREE=true
    SANDBOX_AUTO_SYMLINKS=true
    AUTO_MOUNTED_CONTS=()
    AUTO_SYMLINK_ROOTS=()
    EXTRA_MOUNT_VOLUME_ARGS=()
}

# git worktree: .git is a file pointing at an outside common git dir -> mounted rw
AUTO_DIR="$(mktemp -d)"
PROFILE_TMP_DIRS+=("$AUTO_DIR")
COMMON_GIT="$AUTO_DIR/common-git"
mkdir -p "$COMMON_GIT"
WORKSPACE_DIR="$AUTO_DIR/linked-wt"
mkdir -p "$WORKSPACE_DIR"
printf 'gitdir: %s\n' "$COMMON_GIT" > "$WORKSPACE_DIR/.git"
reset_auto_mounts
configure_auto_mounts
assert_eq "auto git: common git dir mounted" "-v" "${EXTRA_MOUNT_VOLUME_ARGS[0]}"
assert_eq "auto git: common git dir rw (no :ro suffix)" "$COMMON_GIT:$COMMON_GIT" "${EXTRA_MOUNT_VOLUME_ARGS[1]}"

# git: .git is a real directory (main worktree) -> nothing to mount
AUTO_DIR_MAIN="$(mktemp -d)"
PROFILE_TMP_DIRS+=("$AUTO_DIR_MAIN")
WORKSPACE_DIR="$AUTO_DIR_MAIN/main-wt"
mkdir -p "$WORKSPACE_DIR/.git"
reset_auto_mounts
configure_auto_mounts
assert_eq "auto git: plain .git dir mounts nothing" "0" "${#EXTRA_MOUNT_VOLUME_ARGS[@]}"

# git: relative gitdir path resolved against the worktree
AUTO_DIR_REL="$(mktemp -d)"
PROFILE_TMP_DIRS+=("$AUTO_DIR_REL")
mkdir -p "$AUTO_DIR_REL/.git/worktrees/foo" "$AUTO_DIR_REL/main"
printf 'gitdir: ../.git/worktrees/foo\n' > "$AUTO_DIR_REL/main/.git"
WORKSPACE_DIR="$AUTO_DIR_REL/main"
reset_auto_mounts
configure_auto_mounts
assert_eq "auto git: relative gitdir resolved" "$AUTO_DIR_REL/.git/worktrees/foo:$AUTO_DIR_REL/.git/worktrees/foo" "${EXTRA_MOUNT_VOLUME_ARGS[1]}"

# git: absent target dir (broken gitdir) -> no mount, no crash
AUTO_DIR_BROKEN="$(mktemp -d)"
PROFILE_TMP_DIRS+=("$AUTO_DIR_BROKEN")
WORKSPACE_DIR="$AUTO_DIR_BROKEN/wt"
mkdir -p "$WORKSPACE_DIR"
printf 'gitdir: /definitely/not/here\n' > "$WORKSPACE_DIR/.git"
reset_auto_mounts
configure_auto_mounts
assert_eq "auto git: broken gitdir mounts nothing" "0" "${#EXTRA_MOUNT_VOLUME_ARGS[@]}"

# symlink: a skill symlink pointing outside the config root is mounted ro at its realpath
AUTO_SYM="$(mktemp -d)"
PROFILE_TMP_DIRS+=("$AUTO_SYM")
CLAUDE_CONFIG_DIR="$AUTO_SYM/.claude"
mkdir -p "$CLAUDE_CONFIG_DIR/skills"
SKILL_REAL="$AUTO_SYM/skills-real"
mkdir -p "$SKILL_REAL"
ln -s "$SKILL_REAL" "$CLAUDE_CONFIG_DIR/skills/my-skill"
SELECTED_TOOL=claude
CLAUDE_CONFIG_PASSTHROUGH=true
reset_auto_mounts
configure_auto_mounts
assert_eq "auto symlink: external target mounted ro" "$SKILL_REAL:$SKILL_REAL:ro" "${EXTRA_MOUNT_VOLUME_ARGS[1]}"

# symlink: target already inside a mounted root -> skipped
ln -s "$AUTO_SYM/.claude/skills" "$CLAUDE_CONFIG_DIR/internal"
reset_auto_mounts
configure_auto_mounts
assert_eq "auto symlink: internal target skipped (only external ro)" "2" "${#EXTRA_MOUNT_VOLUME_ARGS[@]}"

# symlink: relative target resolved against the link's directory
AUTO_SYM_REL="$(mktemp -d)"
PROFILE_TMP_DIRS+=("$AUTO_SYM_REL")
CLAUDE_CONFIG_DIR="$AUTO_SYM_REL/.claude"
mkdir -p "$CLAUDE_CONFIG_DIR/skills"
mkdir -p "$AUTO_SYM_REL/shared-lib"
ln -s "$AUTO_SYM_REL/shared-lib" "$CLAUDE_CONFIG_DIR/skills/lib"
reset_auto_mounts
configure_auto_mounts
assert_eq "auto symlink: relative target resolved" "$AUTO_SYM_REL/shared-lib:$AUTO_SYM_REL/shared-lib:ro" "${EXTRA_MOUNT_VOLUME_ARGS[1]}"

# symlink: unmounted config root (passthrough off) is not scanned
reset_auto_mounts
CLAUDE_CONFIG_PASSTHROUGH=false
configure_auto_mounts
assert_eq "auto symlink: passthrough off scans nothing" "0" "${#EXTRA_MOUNT_VOLUME_ARGS[@]}"

# auto disabled entirely via global switch
AUTO_OFF_DIR="$(mktemp -d)"
PROFILE_TMP_DIRS+=("$AUTO_OFF_DIR")
WORKSPACE_DIR="$AUTO_OFF_DIR/wt"
mkdir -p "$WORKSPACE_DIR" "$AUTO_OFF_DIR/git"
printf 'gitdir: %s\n' "$AUTO_OFF_DIR/git" > "$WORKSPACE_DIR/.git"
reset_auto_mounts
SANDBOX_EXTRA_MOUNTS_ENABLED=false
configure_auto_mounts
assert_eq "auto: global mounted.enabled=false disables all" "0" "${#EXTRA_MOUNT_VOLUME_ARGS[@]}"
unset SELECTED_TOOL CLAUDE_CONFIG_DIR CLAUDE_CONFIG_PASSTHROUGH SANDBOX_AUTO_GIT_WORKTREE SANDBOX_AUTO_SYMLINKS SANDBOX_EXTRA_MOUNTS_ENABLED

# Auto-detected mounts reach docker compose run (default tool = claude)
AUTO_INT="$(mktemp -d)"
PROFILE_TMP_DIRS+=("$AUTO_INT")
mkdir -p "$AUTO_INT/common-git" "$AUTO_INT/wt"
printf 'gitdir: %s\n' "$AUTO_INT/common-git" > "$AUTO_INT/wt/.git"
run_captured_launcher "$AUTO_INT/int" "$AUTO_INT/wt"
CAPTURED_JOINED="$(printf '<%s>' "${CAPTURED_DOCKER_ARGS[@]}")"
[[ "$CAPTURED_JOINED" == *"<-v><$AUTO_INT/common-git:$AUTO_INT/common-git>"* ]] &&
  ok "auto integration: worktree common git dir reaches docker" ||
  bad "auto integration: worktree common git dir reaches docker ($CAPTURED_JOINED)"

# --- Browser (Playwright MCP) integration tests ---
CAPTURE_DIR_BROWSER="$(mktemp -d)"
PROFILE_TMP_DIRS+=("$CAPTURE_DIR_BROWSER")
SANDBOX_BROWSER_ENABLED=true \
SANDBOX_BROWSER_MCP_URL='http://127.0.0.1:8931/mcp' \
run_captured_launcher "$CAPTURE_DIR_BROWSER" "$SCRIPT_DIR/../.."
CAPTURED_JOINED="$(printf '<%s>' "${CAPTURED_DOCKER_ARGS[@]}")"
[[ "$CAPTURED_JOINED" == *"<-e><PLAYWRIGHT_MCP_URL=http://127.0.0.1:8931/mcp>"* ]] &&
  ok "browser: PLAYWRIGHT_MCP_URL reaches Docker" ||
  bad "browser: PLAYWRIGHT_MCP_URL reaches Docker ($CAPTURED_JOINED)"
[[ "$CAPTURED_JOINED" == *":/etc/ai-sandbox/mcp-config.json:ro>"* ]] &&
  ok "browser: mcp-config mounted read-only" ||
  bad "browser: mcp-config mounted read-only ($CAPTURED_JOINED)"
[[ "$CAPTURED_JOINED" == *"<--mcp-config></etc/ai-sandbox/mcp-config.json>"* ]] &&
  ok "browser: Claude gets --mcp-config" ||
  bad "browser: Claude gets --mcp-config ($CAPTURED_JOINED)"

CAPTURE_DIR_BROWSER_CODEX="$(mktemp -d)"
PROFILE_TMP_DIRS+=("$CAPTURE_DIR_BROWSER_CODEX")
SANDBOX_BROWSER_ENABLED=true \
run_captured_launcher "$CAPTURE_DIR_BROWSER_CODEX" --tool codex "$SCRIPT_DIR/../.."
CAPTURED_JOINED="$(printf '<%s>' "${CAPTURED_DOCKER_ARGS[@]}")"
[[ "$CAPTURED_JOINED" == *"<-e><PLAYWRIGHT_MCP_URL=http://127.0.0.1:8931/mcp>"* ]] &&
  ok "browser: PLAYWRIGHT_MCP_URL passed for codex too" ||
  bad "browser: PLAYWRIGHT_MCP_URL passed for codex too ($CAPTURED_JOINED)"
[[ "$CAPTURED_JOINED" != *"<--mcp-config>"* ]] &&
  ok "browser: no --mcp-config for non-Claude tools" ||
  bad "browser: no --mcp-config for non-Claude tools ($CAPTURED_JOINED)"

CAPTURE_DIR_BROWSER_URL="$(mktemp -d)"
PROFILE_TMP_DIRS+=("$CAPTURE_DIR_BROWSER_URL")
SANDBOX_BROWSER_ENABLED=true \
SANDBOX_BROWSER_MCP_URL='http://127.0.0.1:9999/mcp' \
run_captured_launcher "$CAPTURE_DIR_BROWSER_URL" "$SCRIPT_DIR/../.."
CAPTURED_JOINED="$(printf '<%s>' "${CAPTURED_DOCKER_ARGS[@]}")"
[[ "$CAPTURED_JOINED" == *"<-e><PLAYWRIGHT_MCP_URL=http://127.0.0.1:9999/mcp>"* ]] &&
  ok "browser: custom mcp_url honored" ||
  bad "browser: custom mcp_url honored ($CAPTURED_JOINED)"

CAPTURE_DIR_NOBROWSER="$(mktemp -d)"
PROFILE_TMP_DIRS+=("$CAPTURE_DIR_NOBROWSER")
run_captured_launcher "$CAPTURE_DIR_NOBROWSER" "$SCRIPT_DIR/../.."
CAPTURED_JOINED="$(printf '<%s>' "${CAPTURED_DOCKER_ARGS[@]}")"
[[ "$CAPTURED_JOINED" != *"<PLAYWRIGHT_MCP_URL"* && "$CAPTURED_JOINED" != *"<mcp-config>"* ]] &&
  ok "browser: disabled by default, no injection" ||
  bad "browser: disabled by default, no injection ($CAPTURED_JOINED)"

# --- Conflicting config warning tests ---
# Runs the launcher as a subprocess and captures stderr to check for the warning.
run_launcher_stderr() {
    local capture_dir="$1"
    shift
    mkdir -p "$capture_dir/bin" "$capture_dir/home"
    printf '#!/bin/sh\nexit 0\n' > "$capture_dir/bin/docker"
    chmod +x "$capture_dir/bin/docker"
    HOME="$capture_dir/home" \
    XDG_CONFIG_HOME="$capture_dir/home/.config" \
    SANDBOX_UID=1234 \
    SANDBOX_GID=1234 \
    SANDBOX_USERNAME=tester \
    SANDBOX_HOME=/home/tester \
    SANDBOX_CLEANUP=false \
    CLAUDE_VERSION=integration-test \
    AI_SANDBOX_DIR="$SCRIPT_DIR/../../share/ai-sandbox" \
    PATH="$capture_dir/bin:$PATH" \
      bash "$LAUNCHER" "$@" 2>&1 >/dev/null
}

WARN_DIR_1="$(mktemp -d)"
PROFILE_TMP_DIRS+=("$WARN_DIR_1")
output=$(run_launcher_stderr "$WARN_DIR_1" --allow-local-git "$SCRIPT_DIR/../..")
if [[ "$output" == *"git.allow_local_operations is enabled"* && "$output" == *"git.policy.allow/block rules will be ignored"* ]]; then
    bad "warn: no policy set, no warning expected (got warning)"
else
    ok "warn: no policy set, no warning"
fi

WARN_DIR_2="$(mktemp -d)"
PROFILE_TMP_DIRS+=("$WARN_DIR_2")
output=$(SANDBOX_GIT_POLICY_BLOCK="^stash pop" run_launcher_stderr "$WARN_DIR_2" --allow-local-git "$SCRIPT_DIR/../..")
if [[ "$output" == *"git.allow_local_operations is enabled; git.policy.allow/block rules will be ignored."* ]]; then
    ok "warn: override + policy.block emits warning"
else
    bad "warn: override + policy.block emits warning (got '$output')"
fi

WARN_DIR_3="$(mktemp -d)"
PROFILE_TMP_DIRS+=("$WARN_DIR_3")
output=$(SANDBOX_GIT_POLICY_ALLOW="^reset" run_launcher_stderr "$WARN_DIR_3" --allow-local-git "$SCRIPT_DIR/../..")
if [[ "$output" == *"git.allow_local_operations is enabled; git.policy.allow/block rules will be ignored."* ]]; then
    ok "warn: override + policy.allow emits warning"
else
    bad "warn: override + policy.allow emits warning (got '$output')"
fi

WARN_DIR_4="$(mktemp -d)"
PROFILE_TMP_DIRS+=("$WARN_DIR_4")
output=$(SANDBOX_GIT_POLICY_BLOCK="^stash pop" run_launcher_stderr "$WARN_DIR_4" "$SCRIPT_DIR/../..")
if [[ "$output" == *"git.allow_local_operations is enabled"* ]]; then
    bad "warn: no override, no warning expected (got warning)"
else
    ok "warn: no override, no warning"
fi

# Browser hint: when the browser MCP endpoint is not reachable, the launcher
# tells the user how to start the systemd unit.
HINT_DIR="$(mktemp -d)"
PROFILE_TMP_DIRS+=("$HINT_DIR")
hint_out=$(SANDBOX_BROWSER_ENABLED=true SANDBOX_BROWSER_MCP_URL='http://127.0.0.1:59999/mcp' run_launcher_stderr "$HINT_DIR" "$SCRIPT_DIR/../..")
if [[ "$hint_out" == *"systemctl --user enable --now ai-sandbox-playwright"* ]]; then
    ok "browser: unreachable endpoint emits systemd start hint"
else
    bad "browser: unreachable endpoint emits systemd start hint (got '$hint_out')"
fi

# --- Entrypoint symlink auto-detection ---
# asb-claude / asb-codex / asb-opencode select the tool from the invoked name;
# asb and ai-sandbox use normal precedence. An explicit --tool still wins.
run_entrypoint() {
    local name="$1"; shift
    local edir; edir="$(mktemp -d)"
    PROFILE_TMP_DIRS+=("$edir")
    mkdir -p "$edir/bin" "$edir/home"
    printf '#!/bin/sh\nprintf "%%s\\0" "$@" > "$DOCKER_CAPTURE"\n' > "$edir/bin/docker"
    chmod +x "$edir/bin/docker"
    ln -s "$LAUNCHER" "$edir/$name"
    DOCKER_CAPTURE="$edir/docker.args" \
    HOME="$edir/home" \
    XDG_CONFIG_HOME="$edir/home/.config" \
    SANDBOX_UID=1234 SANDBOX_GID=1234 SANDBOX_USERNAME=tester SANDBOX_HOME=/home/tester \
    SANDBOX_CLEANUP=false \
    CLAUDE_VERSION=entry-test CODEX_VERSION=entry-test OPENCODE_VERSION=entry-test \
    SANDBOX_PROXY_ENV_PASSTHROUGH=false \
    AI_SANDBOX_DIR="$SCRIPT_DIR/../../share/ai-sandbox" \
    PATH="$edir/bin:$edir:$PATH" \
      bash "$edir/$name" "$@"
    mapfile -d '' -t CAPTURED_DOCKER_ARGS < "$edir/docker.args"
}

run_entrypoint asb-codex "$SCRIPT_DIR/../.."
CAPTURED_JOINED="$(printf '<%s>' "${CAPTURED_DOCKER_ARGS[@]}")"
[[ "$CAPTURED_JOINED" == *"<@openai/codex@entry-test>"* ]] &&
  ok "entrypoint: asb-codex selects codex" ||
  bad "entrypoint: asb-codex selects codex ($CAPTURED_JOINED)"

run_entrypoint asb-opencode "$SCRIPT_DIR/../.."
CAPTURED_JOINED="$(printf '<%s>' "${CAPTURED_DOCKER_ARGS[@]}")"
[[ "$CAPTURED_JOINED" == *"<opencode-ai@entry-test>"* ]] &&
  ok "entrypoint: asb-opencode selects opencode" ||
  bad "entrypoint: asb-opencode selects opencode ($CAPTURED_JOINED)"

run_entrypoint asb-claude "$SCRIPT_DIR/../.."
CAPTURED_JOINED="$(printf '<%s>' "${CAPTURED_DOCKER_ARGS[@]}")"
[[ "$CAPTURED_JOINED" == *"<@anthropic-ai/claude-code@entry-test>"* ]] &&
  ok "entrypoint: asb-claude selects claude" ||
  bad "entrypoint: asb-claude selects claude ($CAPTURED_JOINED)"

run_entrypoint asb "$SCRIPT_DIR/../.."
CAPTURED_JOINED="$(printf '<%s>' "${CAPTURED_DOCKER_ARGS[@]}")"
[[ "$CAPTURED_JOINED" == *"<@anthropic-ai/claude-code@entry-test>"* ]] &&
  ok "entrypoint: asb defaults to claude" ||
  bad "entrypoint: asb defaults to claude ($CAPTURED_JOINED)"

run_entrypoint asb-claude --tool codex "$SCRIPT_DIR/../.."
CAPTURED_JOINED="$(printf '<%s>' "${CAPTURED_DOCKER_ARGS[@]}")"
[[ "$CAPTURED_JOINED" == *"<@openai/codex@entry-test>"* ]] &&
  ok "entrypoint: explicit --tool beats asb-claude" ||
  bad "entrypoint: explicit --tool beats asb-claude ($CAPTURED_JOINED)"

assert_rejected_before_docker() {
    local name="$1" expected_error="$2"
    shift 2
    local reject_dir
    reject_dir="$(mktemp -d)"
    PROFILE_TMP_DIRS+=("$reject_dir")
    mkdir -p "$reject_dir/bin" "$reject_dir/home"
    printf '#!/bin/sh\n: > "$DOCKER_CAPTURE"\n' > "$reject_dir/bin/docker"
    chmod +x "$reject_dir/bin/docker"
    local output code
    output=$(DOCKER_CAPTURE="$reject_dir/called" HOME="$reject_dir/home" \
      PATH="$reject_dir/bin:$PATH" bash "$LAUNCHER" "$@" 2>&1) && code=0 || code=$?
    if [[ $code -ne 0 && "$output" == *"$expected_error"* && ! -e "$reject_dir/called" ]]; then
      ok "$name"
    else
      bad "$name (code=$code, output='$output', docker_called=$([[ -e "$reject_dir/called" ]] && echo yes || echo no))"
    fi
}

assert_rejected_before_docker "integration: unknown tool rejected" "supported tools: claude, codex, opencode" --tool unknown
assert_rejected_before_docker "integration: missing tool rejected" "--tool requires" --tool
assert_rejected_before_docker "integration: unknown option rejected" "unsupported option" --bad
assert_rejected_before_docker "integration: multiple workspaces rejected" "at most one workspace" one two
assert_rejected_before_docker "integration: missing workspace rejected" "workspace does not exist" /definitely/not/a/workspace

echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
