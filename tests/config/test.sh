#!/bin/bash
# Unit tests for config resolution (check_config + resolve).
# Run: bash tests/config/test.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER="$SCRIPT_DIR/../../bin/ai-sandbox"

# Source the launcher to get check_config and resolve functions.
# The main guard ensures sourcing doesn't trigger docker compose.
# shellcheck source=/dev/null
source "$LAUNCHER"

# yq is required for most tests; skip the suite if not installed.
if ! command -v yq >/dev/null 2>&1; then
    echo "SKIP: yq not installed; skipping config tests"
    exit 0
fi

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

pass=0
fail=0

ok() { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

# --- check_config tests ---

# Test: missing file -> return 1, no warning
err=$(check_config "$TMPDIR/nonexistent.yaml" 2>&1 >/dev/null) && code=0 || code=$?
if [[ $code -eq 1 && -z "$err" ]]; then
    ok "check_config: missing file returns 1 silently"
else
    bad "check_config: missing file (code=$code, err='$err')"
fi

# Test: valid YAML -> return 0, no warning
printf 'sandbox:\n  uid: 1000\n' > "$TMPDIR/valid.yaml"
err=$(check_config "$TMPDIR/valid.yaml" 2>&1 >/dev/null) && code=0 || code=$?
if [[ $code -eq 0 && -z "$err" ]]; then
    ok "check_config: valid YAML returns 0"
else
    bad "check_config: valid YAML (code=$code, err='$err')"
fi

# Test: malformed YAML -> return 1, warning contains "malformed YAML"
printf 'sandbox:\n  uid: [unterminated\n' > "$TMPDIR/malformed.yaml"
err=$(check_config "$TMPDIR/malformed.yaml" 2>&1 >/dev/null) && code=0 || code=$?
if [[ $code -eq 1 && "$err" == *"malformed YAML"* ]]; then
    ok "check_config: malformed YAML warns and returns 1"
else
    bad "check_config: malformed YAML (code=$code, err='$err')"
fi

# Test: yq not on PATH + file present -> return 1, warning contains "yq not found"
err=$(PATH="/nonexistent" check_config "$TMPDIR/valid.yaml" 2>&1 >/dev/null) && code=0 || code=$?
if [[ $code -eq 1 && "$err" == *"yq not found"* ]]; then
    ok "check_config: yq missing warns and returns 1"
else
    bad "check_config: yq missing (code=$code, err='$err')"
fi

# Test: empty file (valid YAML, no content) -> return 0
printf '' > "$TMPDIR/empty.yaml"
err=$(check_config "$TMPDIR/empty.yaml" 2>&1 >/dev/null) && code=0 || code=$?
if [[ $code -eq 0 && -z "$err" ]]; then
    ok "check_config: empty file returns 0"
else
    bad "check_config: empty file (code=$code, err='$err')"
fi

# --- resolve tests ---
# resolve depends on globals: WORKSPACE_CONFIG, USER_CONFIG,
# WORKSPACE_CONFIG_VALID, USER_CONFIG_VALID. Tests set these directly.

# Setup: create valid config files for resolve tests
printf 'sandbox:\n  uid: 1111\n  gid: 2222\n  username: workspaceuser\n  home: /home/workspaceuser\n' > "$TMPDIR/workspace.yaml"
printf 'sandbox:\n  uid: 3333\n  gid: 4444\n  username: useruser\n  home: /home/useruser\n' > "$TMPDIR/user.yaml"
printf 'sandbox:\n  username: onlyusername\n' > "$TMPDIR/partial.yaml"

# Test: env var wins over workspace and user config
SANDBOX_UID=9999
WORKSPACE_CONFIG="$TMPDIR/workspace.yaml"
USER_CONFIG="$TMPDIR/user.yaml"
WORKSPACE_CONFIG_VALID=true
USER_CONFIG_VALID=true
result=$(resolve SANDBOX_UID .sandbox.uid 0)
if [[ "$result" == "9999" ]]; then
    ok "resolve: env var wins over workspace and user"
else
    bad "resolve: env var wins (got '$result')"
fi

# Test: workspace wins over user (no env var)
unset SANDBOX_UID
WORKSPACE_CONFIG="$TMPDIR/workspace.yaml"
USER_CONFIG="$TMPDIR/user.yaml"
WORKSPACE_CONFIG_VALID=true
USER_CONFIG_VALID=true
result=$(resolve SANDBOX_UID .sandbox.uid 0)
if [[ "$result" == "1111" ]]; then
    ok "resolve: workspace wins over user"
else
    bad "resolve: workspace wins over user (got '$result')"
fi

# Test: user fills gap when workspace absent (VALID=false)
unset SANDBOX_UID
WORKSPACE_CONFIG="$TMPDIR/nonexistent.yaml"
USER_CONFIG="$TMPDIR/user.yaml"
WORKSPACE_CONFIG_VALID=false
USER_CONFIG_VALID=true
result=$(resolve SANDBOX_UID .sandbox.uid 0)
if [[ "$result" == "3333" ]]; then
    ok "resolve: user fills gap when workspace absent"
else
    bad "resolve: user fills gap (got '$result')"
fi

# Test: default when nothing set (both VALID=false)
unset SANDBOX_UID
WORKSPACE_CONFIG="$TMPDIR/nonexistent.yaml"
USER_CONFIG="$TMPDIR/nonexistent.yaml"
WORKSPACE_CONFIG_VALID=false
USER_CONFIG_VALID=false
result=$(resolve SANDBOX_UID .sandbox.uid 5555)
if [[ "$result" == "5555" ]]; then
    ok "resolve: default when nothing set"
else
    bad "resolve: default when nothing set (got '$result')"
fi

# Test: missing key in valid workspace file falls through to default
unset SANDBOX_UID
WORKSPACE_CONFIG="$TMPDIR/partial.yaml"
USER_CONFIG="$TMPDIR/nonexistent.yaml"
WORKSPACE_CONFIG_VALID=true
USER_CONFIG_VALID=false
result=$(resolve SANDBOX_UID .sandbox.uid 6666)
if [[ "$result" == "6666" ]]; then
    ok "resolve: missing key falls through to default"
else
    bad "resolve: missing key falls through (got '$result')"
fi

# Test: malformed workspace (VALID=false) skipped, user used
unset SANDBOX_UID
WORKSPACE_CONFIG="$TMPDIR/malformed.yaml"
USER_CONFIG="$TMPDIR/user.yaml"
WORKSPACE_CONFIG_VALID=false
USER_CONFIG_VALID=true
result=$(resolve SANDBOX_UID .sandbox.uid 0)
if [[ "$result" == "3333" ]]; then
    ok "resolve: malformed workspace skipped, user used"
else
    bad "resolve: malformed workspace skipped (got '$result')"
fi

# Test: empty string value in YAML treated as missing, falls through
printf 'sandbox:\n  uid:\n' > "$TMPDIR/emptyval.yaml"
unset SANDBOX_UID
WORKSPACE_CONFIG="$TMPDIR/emptyval.yaml"
USER_CONFIG="$TMPDIR/nonexistent.yaml"
WORKSPACE_CONFIG_VALID=true
USER_CONFIG_VALID=false
result=$(resolve SANDBOX_UID .sandbox.uid 7777)
if [[ "$result" == "7777" ]]; then
    ok "resolve: empty string value falls through to default"
else
    bad "resolve: empty string value falls through (got '$result')"
fi

# --- resolve tests for git config paths ---

# Setup: create config files with git sections for the new tests
printf 'git:\n  identity:\n    name: workspace-name\n    email: workspace@example.com\n  host_config_passthrough: false\n' > "$TMPDIR/git-workspace.yaml"
printf 'git:\n  identity:\n    name: user-name\n    email: user@example.com\n  host_config_passthrough: true\n' > "$TMPDIR/git-user.yaml"

# Test: git.identity.name - env var wins
SANDBOX_GIT_IDENTITY_NAME=env-name
WORKSPACE_CONFIG="$TMPDIR/git-workspace.yaml"
USER_CONFIG="$TMPDIR/git-user.yaml"
WORKSPACE_CONFIG_VALID=true
USER_CONFIG_VALID=true
result=$(resolve SANDBOX_GIT_IDENTITY_NAME .git.identity.name "")
if [[ "$result" == "env-name" ]]; then
    ok "resolve: git.identity.name env var wins"
else
    bad "resolve: git.identity.name env var wins (got '$result')"
fi

# Test: git.identity.name - workspace wins over user (no env)
unset SANDBOX_GIT_IDENTITY_NAME
WORKSPACE_CONFIG="$TMPDIR/git-workspace.yaml"
USER_CONFIG="$TMPDIR/git-user.yaml"
WORKSPACE_CONFIG_VALID=true
USER_CONFIG_VALID=true
result=$(resolve SANDBOX_GIT_IDENTITY_NAME .git.identity.name "")
if [[ "$result" == "workspace-name" ]]; then
    ok "resolve: git.identity.name workspace wins over user"
else
    bad "resolve: git.identity.name workspace wins over user (got '$result')"
fi

# Test: git.identity.name - user fills gap when workspace absent
unset SANDBOX_GIT_IDENTITY_NAME
WORKSPACE_CONFIG="$TMPDIR/nonexistent.yaml"
USER_CONFIG="$TMPDIR/git-user.yaml"
WORKSPACE_CONFIG_VALID=false
USER_CONFIG_VALID=true
result=$(resolve SANDBOX_GIT_IDENTITY_NAME .git.identity.name "")
if [[ "$result" == "user-name" ]]; then
    ok "resolve: git.identity.name user fills gap when workspace absent"
else
    bad "resolve: git.identity.name user fills gap (got '$result')"
fi

# Test: git.identity.name - empty default when nothing set
unset SANDBOX_GIT_IDENTITY_NAME
WORKSPACE_CONFIG="$TMPDIR/nonexistent.yaml"
USER_CONFIG="$TMPDIR/nonexistent.yaml"
WORKSPACE_CONFIG_VALID=false
USER_CONFIG_VALID=false
result=$(resolve SANDBOX_GIT_IDENTITY_NAME .git.identity.name "")
if [[ "$result" == "" ]]; then
    ok "resolve: git.identity.name empty default when nothing set"
else
    bad "resolve: git.identity.name empty default (got '$result')"
fi

# Test: git.identity.email - workspace value via yq path
unset SANDBOX_GIT_IDENTITY_EMAIL
WORKSPACE_CONFIG="$TMPDIR/git-workspace.yaml"
USER_CONFIG="$TMPDIR/nonexistent.yaml"
WORKSPACE_CONFIG_VALID=true
USER_CONFIG_VALID=false
result=$(resolve SANDBOX_GIT_IDENTITY_EMAIL .git.identity.email "")
if [[ "$result" == "workspace@example.com" ]]; then
    ok "resolve: git.identity.email workspace value"
else
    bad "resolve: git.identity.email workspace value (got '$result')"
fi

# Test: git.host_config_passthrough - default is "true"
unset SANDBOX_GIT_HOST_CONFIG_PASSTHROUGH
WORKSPACE_CONFIG="$TMPDIR/nonexistent.yaml"
USER_CONFIG="$TMPDIR/nonexistent.yaml"
WORKSPACE_CONFIG_VALID=false
USER_CONFIG_VALID=false
result=$(resolve SANDBOX_GIT_HOST_CONFIG_PASSTHROUGH .git.host_config_passthrough true)
if [[ "$result" == "true" ]]; then
    ok "resolve: git.host_config_passthrough default true"
else
    bad "resolve: git.host_config_passthrough default (got '$result')"
fi

# Test: git.host_config_passthrough - env var "false" wins
SANDBOX_GIT_HOST_CONFIG_PASSTHROUGH=false
WORKSPACE_CONFIG="$TMPDIR/git-workspace.yaml"
USER_CONFIG="$TMPDIR/git-user.yaml"
WORKSPACE_CONFIG_VALID=true
USER_CONFIG_VALID=true
result=$(resolve SANDBOX_GIT_HOST_CONFIG_PASSTHROUGH .git.host_config_passthrough true)
if [[ "$result" == "false" ]]; then
    ok "resolve: git.host_config_passthrough env var false wins"
else
    bad "resolve: git.host_config_passthrough env false (got '$result')"
fi

# Test: git.host_config_passthrough - workspace "false" when no env
unset SANDBOX_GIT_HOST_CONFIG_PASSTHROUGH
WORKSPACE_CONFIG="$TMPDIR/git-workspace.yaml"
USER_CONFIG="$TMPDIR/git-user.yaml"
WORKSPACE_CONFIG_VALID=true
USER_CONFIG_VALID=true
result=$(resolve SANDBOX_GIT_HOST_CONFIG_PASSTHROUGH .git.host_config_passthrough true)
if [[ "$result" == "false" ]]; then
    ok "resolve: git.host_config_passthrough workspace false (no env)"
else
    bad "resolve: git.host_config_passthrough workspace false (got '$result')"
fi

# Test: git.host_config_passthrough - user "true" wins over default when workspace absent
unset SANDBOX_GIT_HOST_CONFIG_PASSTHROUGH
WORKSPACE_CONFIG="$TMPDIR/nonexistent.yaml"
USER_CONFIG="$TMPDIR/git-user.yaml"
WORKSPACE_CONFIG_VALID=false
USER_CONFIG_VALID=true
result=$(resolve SANDBOX_GIT_HOST_CONFIG_PASSTHROUGH .git.host_config_passthrough false)
if [[ "$result" == "true" ]]; then
    ok "resolve: git.host_config_passthrough user true beats false default"
else
    bad "resolve: git.host_config_passthrough user true (got '$result')"
fi

# --- resolve tests for git.allow_local_operations ---

# Setup: config files with allow_local_operations
printf 'git:\n  allow_local_operations: true\n' > "$TMPDIR/allow-workspace.yaml"
printf 'git:\n  allow_local_operations: false\n' > "$TMPDIR/allow-user.yaml"

# Test: git.allow_local_operations - env var wins
SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS=false
WORKSPACE_CONFIG="$TMPDIR/allow-workspace.yaml"
USER_CONFIG="$TMPDIR/allow-user.yaml"
WORKSPACE_CONFIG_VALID=true
USER_CONFIG_VALID=true
result=$(resolve SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS .git.allow_local_operations false)
if [[ "$result" == "false" ]]; then
    ok "resolve: git.allow_local_operations env var wins"
else
    bad "resolve: git.allow_local_operations env var wins (got '$result')"
fi

# Test: git.allow_local_operations - workspace wins over user (no env)
unset SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS
WORKSPACE_CONFIG="$TMPDIR/allow-workspace.yaml"
USER_CONFIG="$TMPDIR/allow-user.yaml"
WORKSPACE_CONFIG_VALID=true
USER_CONFIG_VALID=true
result=$(resolve SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS .git.allow_local_operations false)
if [[ "$result" == "true" ]]; then
    ok "resolve: git.allow_local_operations workspace wins over user"
else
    bad "resolve: git.allow_local_operations workspace wins over user (got '$result')"
fi

# Test: git.allow_local_operations - user fills gap when workspace absent
unset SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS
WORKSPACE_CONFIG="$TMPDIR/nonexistent.yaml"
USER_CONFIG="$TMPDIR/allow-user.yaml"
WORKSPACE_CONFIG_VALID=false
USER_CONFIG_VALID=true
result=$(resolve SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS .git.allow_local_operations false)
if [[ "$result" == "false" ]]; then
    ok "resolve: git.allow_local_operations user fills gap when workspace absent"
else
    bad "resolve: git.allow_local_operations user fills gap (got '$result')"
fi

# Test: git.allow_local_operations - default false when nothing set
unset SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS
WORKSPACE_CONFIG="$TMPDIR/nonexistent.yaml"
USER_CONFIG="$TMPDIR/nonexistent.yaml"
WORKSPACE_CONFIG_VALID=false
USER_CONFIG_VALID=false
result=$(resolve SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS .git.allow_local_operations false)
if [[ "$result" == "false" ]]; then
    ok "resolve: git.allow_local_operations default false"
else
    bad "resolve: git.allow_local_operations default (got '$result')"
fi

# --- resolve tests for claude.version and sandbox.cleanup ---

# Setup: config files with claude and sandbox sections
printf 'claude:\n  version: "1.0.0"\nsandbox:\n  cleanup: false\n' > "$TMPDIR/cs-workspace.yaml"
printf 'claude:\n  version: "2.0.0"\nsandbox:\n  cleanup: true\n' > "$TMPDIR/cs-user.yaml"

# Test: claude.version - env var wins
CLAUDE_VERSION=env-version
WORKSPACE_CONFIG="$TMPDIR/cs-workspace.yaml"
USER_CONFIG="$TMPDIR/cs-user.yaml"
WORKSPACE_CONFIG_VALID=true
USER_CONFIG_VALID=true
result=$(resolve CLAUDE_VERSION .claude.version "default-ver")
if [[ "$result" == "env-version" ]]; then
    ok "resolve: claude.version env var wins"
else
    bad "resolve: claude.version env var wins (got '$result')"
fi

# Test: claude.version - workspace wins over user (no env)
unset CLAUDE_VERSION
WORKSPACE_CONFIG="$TMPDIR/cs-workspace.yaml"
USER_CONFIG="$TMPDIR/cs-user.yaml"
WORKSPACE_CONFIG_VALID=true
USER_CONFIG_VALID=true
result=$(resolve CLAUDE_VERSION .claude.version "default-ver")
if [[ "$result" == "1.0.0" ]]; then
    ok "resolve: claude.version workspace wins over user"
else
    bad "resolve: claude.version workspace wins over user (got '$result')"
fi

# Test: claude.version - user fills gap when workspace absent
unset CLAUDE_VERSION
WORKSPACE_CONFIG="$TMPDIR/nonexistent.yaml"
USER_CONFIG="$TMPDIR/cs-user.yaml"
WORKSPACE_CONFIG_VALID=false
USER_CONFIG_VALID=true
result=$(resolve CLAUDE_VERSION .claude.version "default-ver")
if [[ "$result" == "2.0.0" ]]; then
    ok "resolve: claude.version user fills gap"
else
    bad "resolve: claude.version user fills gap (got '$result')"
fi

# Test: claude.version - default when nothing set
unset CLAUDE_VERSION
WORKSPACE_CONFIG="$TMPDIR/nonexistent.yaml"
USER_CONFIG="$TMPDIR/nonexistent.yaml"
WORKSPACE_CONFIG_VALID=false
USER_CONFIG_VALID=false
result=$(resolve CLAUDE_VERSION .claude.version "default-ver")
if [[ "$result" == "default-ver" ]]; then
    ok "resolve: claude.version default when nothing set"
else
    bad "resolve: claude.version default (got '$result')"
fi

# Test: sandbox.cleanup - default is "true"
unset SANDBOX_CLEANUP
WORKSPACE_CONFIG="$TMPDIR/nonexistent.yaml"
USER_CONFIG="$TMPDIR/nonexistent.yaml"
WORKSPACE_CONFIG_VALID=false
USER_CONFIG_VALID=false
result=$(resolve SANDBOX_CLEANUP .sandbox.cleanup true)
if [[ "$result" == "true" ]]; then
    ok "resolve: sandbox.cleanup default true"
else
    bad "resolve: sandbox.cleanup default (got '$result')"
fi

# Test: sandbox.cleanup - env var "false" wins
SANDBOX_CLEANUP=false
WORKSPACE_CONFIG="$TMPDIR/cs-workspace.yaml"
USER_CONFIG="$TMPDIR/cs-user.yaml"
WORKSPACE_CONFIG_VALID=true
USER_CONFIG_VALID=true
result=$(resolve SANDBOX_CLEANUP .sandbox.cleanup true)
if [[ "$result" == "false" ]]; then
    ok "resolve: sandbox.cleanup env var false wins"
else
    bad "resolve: sandbox.cleanup env false (got '$result')"
fi

# Test: sandbox.cleanup - workspace "false" when no env
unset SANDBOX_CLEANUP
WORKSPACE_CONFIG="$TMPDIR/cs-workspace.yaml"
USER_CONFIG="$TMPDIR/cs-user.yaml"
WORKSPACE_CONFIG_VALID=true
USER_CONFIG_VALID=true
result=$(resolve SANDBOX_CLEANUP .sandbox.cleanup true)
if [[ "$result" == "false" ]]; then
    ok "resolve: sandbox.cleanup workspace false"
else
    bad "resolve: sandbox.cleanup workspace false (got '$result')"
fi

# Test: sandbox.cleanup - user "true" wins over default when workspace absent
unset SANDBOX_CLEANUP
WORKSPACE_CONFIG="$TMPDIR/nonexistent.yaml"
USER_CONFIG="$TMPDIR/cs-user.yaml"
WORKSPACE_CONFIG_VALID=false
USER_CONFIG_VALID=true
result=$(resolve SANDBOX_CLEANUP .sandbox.cleanup false)
if [[ "$result" == "true" ]]; then
    ok "resolve: sandbox.cleanup user true beats false default"
else
    bad "resolve: sandbox.cleanup user true (got '$result')"
fi

# --- resolve tests for claude.config_passthrough ---

printf 'claude:\n  config_passthrough: false\n' > "$TMPDIR/cp-workspace.yaml"
printf 'claude:\n  config_passthrough: true\n' > "$TMPDIR/cp-user.yaml"

# Test: claude.config_passthrough - default is "true"
unset CLAUDE_CONFIG_PASSTHROUGH
WORKSPACE_CONFIG="$TMPDIR/nonexistent.yaml"
USER_CONFIG="$TMPDIR/nonexistent.yaml"
WORKSPACE_CONFIG_VALID=false
USER_CONFIG_VALID=false
result=$(resolve CLAUDE_CONFIG_PASSTHROUGH .claude.config_passthrough true)
if [[ "$result" == "true" ]]; then
    ok "resolve: claude.config_passthrough default true"
else
    bad "resolve: claude.config_passthrough default (got '$result')"
fi

# Test: claude.config_passthrough - env var "false" wins
CLAUDE_CONFIG_PASSTHROUGH=false
WORKSPACE_CONFIG="$TMPDIR/cp-workspace.yaml"
USER_CONFIG="$TMPDIR/cp-user.yaml"
WORKSPACE_CONFIG_VALID=true
USER_CONFIG_VALID=true
result=$(resolve CLAUDE_CONFIG_PASSTHROUGH .claude.config_passthrough true)
if [[ "$result" == "false" ]]; then
    ok "resolve: claude.config_passthrough env false wins"
else
    bad "resolve: claude.config_passthrough env false (got '$result')"
fi

# Test: claude.config_passthrough - workspace "false" when no env
unset CLAUDE_CONFIG_PASSTHROUGH
WORKSPACE_CONFIG="$TMPDIR/cp-workspace.yaml"
USER_CONFIG="$TMPDIR/cp-user.yaml"
WORKSPACE_CONFIG_VALID=true
USER_CONFIG_VALID=true
result=$(resolve CLAUDE_CONFIG_PASSTHROUGH .claude.config_passthrough true)
if [[ "$result" == "false" ]]; then
    ok "resolve: claude.config_passthrough workspace false"
else
    bad "resolve: claude.config_passthrough workspace false (got '$result')"
fi

# Test: claude.config_passthrough - user "true" beats false default
unset CLAUDE_CONFIG_PASSTHROUGH
WORKSPACE_CONFIG="$TMPDIR/nonexistent.yaml"
USER_CONFIG="$TMPDIR/cp-user.yaml"
WORKSPACE_CONFIG_VALID=false
USER_CONFIG_VALID=true
result=$(resolve CLAUDE_CONFIG_PASSTHROUGH .claude.config_passthrough false)
if [[ "$result" == "true" ]]; then
    ok "resolve: claude.config_passthrough user true beats false default"
else
    bad "resolve: claude.config_passthrough user true (got '$result')"
fi

# --- resolve_list tests ---

printf 'git:\n  policy:\n    allow:\n      - "^reset"\n      - "^commit --amend"\n    block:\n      - "^stash pop"\n' > "$TMPDIR/policy-workspace.yaml"
printf 'git:\n  policy:\n    allow:\n      - "^push"\n' > "$TMPDIR/policy-user.yaml"

# Test: resolve_list - env var (newline-separated) wins
SANDBOX_GIT_POLICY_ALLOW=$'^env1\n^env2'
WORKSPACE_CONFIG="$TMPDIR/policy-workspace.yaml"
USER_CONFIG="$TMPDIR/policy-user.yaml"
WORKSPACE_CONFIG_VALID=true
USER_CONFIG_VALID=true
result=$(resolve_list SANDBOX_GIT_POLICY_ALLOW .git.policy.allow)
if [[ "$result" == $'^env1\n^env2' ]]; then
    ok "resolve_list: env var wins"
else
    bad "resolve_list: env var wins (got '$result')"
fi

# Test: resolve_list - workspace wins over user (no env)
unset SANDBOX_GIT_POLICY_ALLOW
WORKSPACE_CONFIG="$TMPDIR/policy-workspace.yaml"
USER_CONFIG="$TMPDIR/policy-user.yaml"
WORKSPACE_CONFIG_VALID=true
USER_CONFIG_VALID=true
result=$(resolve_list SANDBOX_GIT_POLICY_ALLOW .git.policy.allow)
if [[ "$result" == $'^reset\n^commit --amend' ]]; then
    ok "resolve_list: workspace wins over user"
else
    bad "resolve_list: workspace wins over user (got '$result')"
fi

# Test: resolve_list - user fills gap when workspace absent
unset SANDBOX_GIT_POLICY_ALLOW
WORKSPACE_CONFIG="$TMPDIR/nonexistent.yaml"
USER_CONFIG="$TMPDIR/policy-user.yaml"
WORKSPACE_CONFIG_VALID=false
USER_CONFIG_VALID=true
result=$(resolve_list SANDBOX_GIT_POLICY_ALLOW .git.policy.allow)
if [[ "$result" == "^push" ]]; then
    ok "resolve_list: user fills gap"
else
    bad "resolve_list: user fills gap (got '$result')"
fi

# Test: resolve_list - empty when nothing set
unset SANDBOX_GIT_POLICY_ALLOW
WORKSPACE_CONFIG="$TMPDIR/nonexistent.yaml"
USER_CONFIG="$TMPDIR/nonexistent.yaml"
WORKSPACE_CONFIG_VALID=false
USER_CONFIG_VALID=false
result=$(resolve_list SANDBOX_GIT_POLICY_ALLOW .git.policy.allow)
if [[ -z "$result" ]]; then
    ok "resolve_list: empty when nothing set"
else
    bad "resolve_list: empty when nothing set (got '$result')"
fi

# Test: resolve_list - missing key in valid file returns empty
printf 'git: {}\n' > "$TMPDIR/no-policy.yaml"
unset SANDBOX_GIT_POLICY_ALLOW
WORKSPACE_CONFIG="$TMPDIR/no-policy.yaml"
USER_CONFIG="$TMPDIR/nonexistent.yaml"
WORKSPACE_CONFIG_VALID=true
USER_CONFIG_VALID=false
result=$(resolve_list SANDBOX_GIT_POLICY_ALLOW .git.policy.allow)
if [[ -z "$result" ]]; then
    ok "resolve_list: missing key returns empty"
else
    bad "resolve_list: missing key returns empty (got '$result')"
fi

# Test: resolve_list - block list from workspace
unset SANDBOX_GIT_POLICY_BLOCK
WORKSPACE_CONFIG="$TMPDIR/policy-workspace.yaml"
USER_CONFIG="$TMPDIR/nonexistent.yaml"
WORKSPACE_CONFIG_VALID=true
USER_CONFIG_VALID=false
result=$(resolve_list SANDBOX_GIT_POLICY_BLOCK .git.policy.block)
if [[ "$result" == "^stash pop" ]]; then
    ok "resolve_list: block list from workspace"
else
    bad "resolve_list: block list from workspace (got '$result')"
fi

# --- resolve_list tests for mounts.extra ---

printf 'mounts:\n  enabled: false\n  extra:\n    - "~/.config/cc-switch"\n    - "/tmp/x:/opt/x:rw"\n' > "$TMPDIR/mounts-workspace.yaml"

# Test: resolve_list - mounts.extra from workspace
unset SANDBOX_EXTRA_MOUNTS
WORKSPACE_CONFIG="$TMPDIR/mounts-workspace.yaml"
USER_CONFIG="$TMPDIR/nonexistent.yaml"
WORKSPACE_CONFIG_VALID=true
USER_CONFIG_VALID=false
result=$(resolve_list SANDBOX_EXTRA_MOUNTS .mounts.extra)
if [[ "$result" == $'~/.config/cc-switch\n/tmp/x:/opt/x:rw' ]]; then
    ok "resolve_list: mounts.extra workspace list"
else
    bad "resolve_list: mounts.extra workspace list (got '$result')"
fi

# Test: resolve_list - mounts.extra env var wins
SANDBOX_EXTRA_MOUNTS=$'~/.cache/npm:/home/user/.cache/npm:rw'
result=$(resolve_list SANDBOX_EXTRA_MOUNTS .mounts.extra)
if [[ "$result" == $'~/.cache/npm:/home/user/.cache/npm:rw' ]]; then
    ok "resolve_list: mounts.extra env var wins"
else
    bad "resolve_list: mounts.extra env var wins (got '$result')"
fi
unset SANDBOX_EXTRA_MOUNTS

# Test: resolve_list - mounts.extra empty when nothing set
WORKSPACE_CONFIG="$TMPDIR/nonexistent.yaml"
USER_CONFIG="$TMPDIR/nonexistent.yaml"
WORKSPACE_CONFIG_VALID=false
USER_CONFIG_VALID=false
result=$(resolve_list SANDBOX_EXTRA_MOUNTS .mounts.extra)
if [[ -z "$result" ]]; then
    ok "resolve_list: mounts.extra empty when nothing set"
else
    bad "resolve_list: mounts.extra empty when nothing set (got '$result')"
fi

# Test: resolve - mounts.enabled default true
unset SANDBOX_EXTRA_MOUNTS_ENABLED
result=$(resolve SANDBOX_EXTRA_MOUNTS_ENABLED .mounts.enabled true)
if [[ "$result" == "true" ]]; then
    ok "resolve: mounts.enabled default true"
else
    bad "resolve: mounts.enabled default (got '$result')"
fi

# Test: resolve - mounts.enabled workspace false wins
WORKSPACE_CONFIG="$TMPDIR/mounts-workspace.yaml"
USER_CONFIG="$TMPDIR/nonexistent.yaml"
WORKSPACE_CONFIG_VALID=true
USER_CONFIG_VALID=false
result=$(resolve SANDBOX_EXTRA_MOUNTS_ENABLED .mounts.enabled true)
if [[ "$result" == "false" ]]; then
    ok "resolve: mounts.enabled workspace false wins"
else
    bad "resolve: mounts.enabled workspace false (got '$result')"
fi

# --- resolve tests for claude.config_dir and claude.config_file ---

printf 'claude:\n  config_dir: /custom/ws-claude\n  config_file: /custom/ws-claude.json\n' > "$TMPDIR/cd-workspace.yaml"
printf 'claude:\n  config_dir: /custom/user-claude\n  config_file: /custom/user-claude.json\n' > "$TMPDIR/cd-user.yaml"

# Test: claude.config_dir - env var wins
CLAUDE_CONFIG_DIR=/env-claude
WORKSPACE_CONFIG="$TMPDIR/cd-workspace.yaml"
USER_CONFIG="$TMPDIR/cd-user.yaml"
WORKSPACE_CONFIG_VALID=true
USER_CONFIG_VALID=true
result=$(resolve CLAUDE_CONFIG_DIR .claude.config_dir "/default/.claude")
if [[ "$result" == "/env-claude" ]]; then
    ok "resolve: claude.config_dir env var wins"
else
    bad "resolve: claude.config_dir env var wins (got '$result')"
fi

# Test: claude.config_dir - workspace wins over user (no env)
unset CLAUDE_CONFIG_DIR
WORKSPACE_CONFIG="$TMPDIR/cd-workspace.yaml"
USER_CONFIG="$TMPDIR/cd-user.yaml"
WORKSPACE_CONFIG_VALID=true
USER_CONFIG_VALID=true
result=$(resolve CLAUDE_CONFIG_DIR .claude.config_dir "/default/.claude")
if [[ "$result" == "/custom/ws-claude" ]]; then
    ok "resolve: claude.config_dir workspace wins over user"
else
    bad "resolve: claude.config_dir workspace wins over user (got '$result')"
fi

# Test: claude.config_dir - user fills gap when workspace absent
unset CLAUDE_CONFIG_DIR
WORKSPACE_CONFIG="$TMPDIR/nonexistent.yaml"
USER_CONFIG="$TMPDIR/cd-user.yaml"
WORKSPACE_CONFIG_VALID=false
USER_CONFIG_VALID=true
result=$(resolve CLAUDE_CONFIG_DIR .claude.config_dir "/default/.claude")
if [[ "$result" == "/custom/user-claude" ]]; then
    ok "resolve: claude.config_dir user fills gap"
else
    bad "resolve: claude.config_dir user fills gap (got '$result')"
fi

# Test: claude.config_dir - default when nothing set
unset CLAUDE_CONFIG_DIR
WORKSPACE_CONFIG="$TMPDIR/nonexistent.yaml"
USER_CONFIG="$TMPDIR/nonexistent.yaml"
WORKSPACE_CONFIG_VALID=false
USER_CONFIG_VALID=false
result=$(resolve CLAUDE_CONFIG_DIR .claude.config_dir "/default/.claude")
if [[ "$result" == "/default/.claude" ]]; then
    ok "resolve: claude.config_dir default when nothing set"
else
    bad "resolve: claude.config_dir default (got '$result')"
fi

# Test: claude.config_file - workspace value via yq path
unset CLAUDE_CONFIG_FILE
WORKSPACE_CONFIG="$TMPDIR/cd-workspace.yaml"
USER_CONFIG="$TMPDIR/nonexistent.yaml"
WORKSPACE_CONFIG_VALID=true
USER_CONFIG_VALID=false
result=$(resolve CLAUDE_CONFIG_FILE .claude.config_file "/default/.claude.json")
if [[ "$result" == "/custom/ws-claude.json" ]]; then
    ok "resolve: claude.config_file workspace value"
else
    bad "resolve: claude.config_file workspace value (got '$result')"
fi

# Test: claude.config_file - user fills gap when workspace absent
unset CLAUDE_CONFIG_FILE
WORKSPACE_CONFIG="$TMPDIR/nonexistent.yaml"
USER_CONFIG="$TMPDIR/cd-user.yaml"
WORKSPACE_CONFIG_VALID=false
USER_CONFIG_VALID=true
result=$(resolve CLAUDE_CONFIG_FILE .claude.config_file "/default/.claude.json")
if [[ "$result" == "/custom/user-claude.json" ]]; then
    ok "resolve: claude.config_file user fills gap"
else
    bad "resolve: claude.config_file user fills gap (got '$result')"
fi

printf 'tool: codex\ncodex:\n  version: "1.2.3"\n  config_passthrough: false\n  config_dir: /workspace/codex\n' > "$TMPDIR/codex-workspace.yaml"
printf 'tool: claude\ncodex:\n  version: "4.5.6"\n  config_passthrough: true\n  config_dir: /user/codex\n' > "$TMPDIR/codex-user.yaml"

WORKSPACE_CONFIG="$TMPDIR/codex-workspace.yaml"
USER_CONFIG="$TMPDIR/codex-user.yaml"
WORKSPACE_CONFIG_VALID=true
USER_CONFIG_VALID=true
unset SANDBOX_TOOL CODEX_VERSION CODEX_CONFIG_PASSTHROUGH CODEX_CONFIG_DIR

result=$(resolve SANDBOX_TOOL .tool claude)
[[ "$result" == "codex" ]] && ok "resolve: tool workspace wins" || bad "resolve: tool workspace wins (got '$result')"
result=$(resolve CODEX_VERSION .codex.version "")
[[ "$result" == "1.2.3" ]] && ok "resolve: codex.version workspace wins" || bad "resolve: codex.version workspace wins (got '$result')"
result=$(resolve CODEX_CONFIG_PASSTHROUGH .codex.config_passthrough true)
[[ "$result" == "false" ]] && ok "resolve: codex passthrough false preserved" || bad "resolve: codex passthrough false (got '$result')"
result=$(resolve CODEX_CONFIG_DIR .codex.config_dir "$HOME/.codex")
[[ "$result" == "/workspace/codex" ]] && ok "resolve: codex config dir workspace wins" || bad "resolve: codex config dir (got '$result')"

CODEX_VERSION=9.9.9
result=$(resolve CODEX_VERSION .codex.version "")
[[ "$result" == "9.9.9" ]] && ok "resolve: codex.version env wins" || bad "resolve: codex.version env wins (got '$result')"
unset CODEX_VERSION

WORKSPACE_CONFIG_VALID=false
result=$(resolve CODEX_VERSION .codex.version "")
[[ "$result" == "4.5.6" ]] && ok "resolve: codex.version user fallback" || bad "resolve: codex.version user fallback (got '$result')"

# --- resolve tests for proxy.env_passthrough ---

printf 'proxy:\n  env_passthrough: false\n' > "$TMPDIR/proxy-workspace.yaml"
printf 'proxy:\n  env_passthrough: true\n' > "$TMPDIR/proxy-user.yaml"

WORKSPACE_CONFIG="$TMPDIR/proxy-workspace.yaml"
USER_CONFIG="$TMPDIR/proxy-user.yaml"
WORKSPACE_CONFIG_VALID=true
USER_CONFIG_VALID=true
unset SANDBOX_PROXY_ENV_PASSTHROUGH

result=$(resolve SANDBOX_PROXY_ENV_PASSTHROUGH .proxy.env_passthrough true)
[[ "$result" == "false" ]] && ok "resolve: proxy passthrough workspace wins" || bad "resolve: proxy passthrough workspace (got '$result')"

SANDBOX_PROXY_ENV_PASSTHROUGH=true
result=$(resolve SANDBOX_PROXY_ENV_PASSTHROUGH .proxy.env_passthrough false)
[[ "$result" == "true" ]] && ok "resolve: proxy passthrough env wins" || bad "resolve: proxy passthrough env (got '$result')"
unset SANDBOX_PROXY_ENV_PASSTHROUGH

WORKSPACE_CONFIG_VALID=false
result=$(resolve SANDBOX_PROXY_ENV_PASSTHROUGH .proxy.env_passthrough false)
[[ "$result" == "true" ]] && ok "resolve: proxy passthrough user fallback" || bad "resolve: proxy passthrough user fallback (got '$result')"

USER_CONFIG_VALID=false
result=$(resolve SANDBOX_PROXY_ENV_PASSTHROUGH .proxy.env_passthrough true)
[[ "$result" == "true" ]] && ok "resolve: proxy passthrough default true" || bad "resolve: proxy passthrough default (got '$result')"

echo ""
echo "Results: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]] || exit 1
