#!/bin/bash
# Unit tests for git-wrapper.
# Run: bash tests/git-wrapper/test.sh

set -u

WRAPPER_DIR="$(cd "$(dirname "$0")/../../share/ai-sandbox" && pwd)"
WRAPPER="$WRAPPER_DIR/git-wrapper"

STUB_DIR="$(mktemp -d)"
export STUB_DIR
trap 'rm -rf "$STUB_DIR"' EXIT

# Stub: records that it was called, exits 0.
cat > "$STUB_DIR/git" <<'EOF'
#!/bin/bash
touch "$STUB_DIR/called"
exit 0
EOF
chmod +x "$STUB_DIR/git"

pass=0
fail=0

# Assert the wrapper blocks the command (exit 1, [SECURITY] in stderr, real git not called).
assert_blocked() {
    local desc="$1"; shift
    rm -f "$STUB_DIR/called"
    local err code
    err="$(REAL_GIT="$STUB_DIR/git" "$WRAPPER" "$@" 2>&1 >/dev/null)" && code=0 || code=$?
    if [[ $code -ne 1 ]]; then
        echo "FAIL: $desc (exit $code, expected 1)"
        fail=$((fail+1)); return
    fi
    if [[ "$err" != *"[SECURITY]"* ]]; then
        echo "FAIL: $desc (no [SECURITY] in stderr: $err)"
        fail=$((fail+1)); return
    fi
    if [[ -f "$STUB_DIR/called" ]]; then
        echo "FAIL: $desc (real git was called despite block)"
        fail=$((fail+1)); return
    fi
    echo "PASS: $desc"
    pass=$((pass+1))
}

# Assert the wrapper allows the command (exit 0, real git called).
assert_allowed() {
    local desc="$1"; shift
    rm -f "$STUB_DIR/called"
    REAL_GIT="$STUB_DIR/git" "$WRAPPER" "$@" >/dev/null 2>&1
    local code=$?
    if [[ $code -ne 0 ]]; then
        echo "FAIL: $desc (exit $code, expected 0)"
        fail=$((fail+1)); return
    fi
    if [[ ! -f "$STUB_DIR/called" ]]; then
        echo "FAIL: $desc (real git was not called)"
        fail=$((fail+1)); return
    fi
    echo "PASS: $desc"
    pass=$((pass+1))
}

# --- Tests ---

# Skeleton: pass-through cases
assert_allowed "git status"
assert_allowed "git log"
assert_allowed "git --version"
assert_allowed "git --help"
assert_allowed "git -C /tmp status"
assert_allowed "git -c user.name=x status"

# Task 2: fully blocked subcommands
assert_blocked "git push" push
assert_blocked "git push origin main" push origin main
assert_blocked "git reset" reset
assert_blocked "git reset --hard HEAD~1" reset --hard HEAD~1
assert_blocked "git reset --soft HEAD~1" reset --soft HEAD~1
assert_blocked "git rebase" rebase
assert_blocked "git rebase main" rebase main
assert_blocked "git filter-branch" filter-branch
assert_blocked "git filter-repo" filter-repo
assert_blocked "git clean" clean
assert_blocked "git clean -fd" clean -fd
assert_blocked "git config" config
assert_blocked "git config --get user.name" config --get user.name
assert_blocked "git config user.name X" config user.name X
assert_blocked "git config --global user.name X" config --global user.name X

# Task 2: parser must handle space-separated value flags to prevent bypass
assert_blocked "git --git-dir /tmp push" --git-dir /tmp push
assert_blocked "git --work-tree /tmp reset" --work-tree /tmp reset
assert_blocked "git --namespace foo push" --namespace foo push
assert_blocked "git --config-env user.name=ENVVAR push" --config-env user.name=ENVVAR push
assert_allowed "git --git-dir /tmp status" --git-dir /tmp status

# Task 3: conditionally blocked subcommands
assert_blocked "git reflog expire" reflog expire
assert_blocked "git reflog delete" reflog delete
assert_blocked "git reflog expire --all" reflog expire --all
assert_blocked "git reflog delete HEAD@{0}" reflog delete 'HEAD@{0}'
assert_allowed "git reflog show" reflog show
assert_allowed "git reflog exists HEAD" reflog exists HEAD
assert_allowed "git reflog (no sub-subcommand)" reflog
assert_blocked "git notes remove" notes remove
assert_blocked "git notes prune" notes prune
assert_blocked "git notes remove HEAD" notes remove HEAD
assert_allowed "git notes list" notes list
assert_allowed "git notes show HEAD" notes show HEAD
assert_allowed "git notes (no sub-subcommand)" notes
assert_blocked "git worktree remove" worktree remove
assert_blocked "git worktree prune" worktree prune
assert_blocked "git worktree remove /tmp/foo" worktree remove /tmp/foo
assert_allowed "git worktree list" worktree list
assert_allowed "git worktree add ../foo" worktree add ../foo
assert_allowed "git worktree (no sub-subcommand)" worktree

# Task 4: flag-level blocks (commit, tag, branch)
assert_blocked "git commit --amend" commit --amend
assert_blocked "git commit --amend --no-edit" commit --amend --no-edit
assert_blocked "git commit --reset-author" commit --reset-author
assert_allowed "git commit -m test" commit -m test
assert_allowed "git commit -am test" commit -am test
assert_allowed "git tag -d v1" tag -d v1
assert_allowed "git tag --delete v1" tag --delete v1
assert_blocked "git tag -f v1" tag -f v1
assert_blocked "git tag --force v1" tag --force v1
assert_blocked "git tag --delete --force v1" tag --delete --force v1
assert_allowed "git tag v1" tag v1
assert_allowed "git tag -a v1 -m msg" tag -a v1 -m msg
assert_allowed "git branch -d feature" branch -d feature
assert_blocked "git branch -D feature" branch -D feature
assert_allowed "git branch --delete feature" branch --delete feature
assert_blocked "git branch --delete --force feature" branch --delete --force feature
assert_blocked "git branch --force --delete feature" branch --force --delete feature
assert_blocked "git branch -d -f feature" branch -d -f feature
assert_allowed "git branch feature" branch feature
assert_allowed "git branch -a" branch -a

# Task 4: combined short flags (bypass prevention)
assert_blocked "git branch -df feature" branch -df feature
assert_blocked "git branch -Df feature" branch -Df feature
assert_blocked "git tag -fa v1 -m msg" tag -fa v1 -m msg
assert_blocked "git tag -af v1" tag -af v1
# Task 4: subcommand-alone boundary case
assert_allowed "git commit (no flags)" commit
assert_allowed "git tag (no args)" tag
assert_allowed "git branch (no args)" branch

# Task 5: flag-level blocks (stash, checkout, restore)
assert_blocked "git stash drop" stash drop
assert_blocked "git stash drop stash@{0}" stash drop 'stash@{0}'
assert_blocked "git stash clear" stash clear
assert_allowed "git stash" stash
assert_allowed "git stash push" stash push
assert_allowed "git stash pop" stash pop
assert_allowed "git stash list" stash list
assert_blocked "git checkout -B main" checkout -B main
assert_blocked "git checkout -f main" checkout -f main
assert_blocked "git checkout --force main" checkout --force main
assert_blocked "git checkout -- file.txt" checkout -- file.txt
assert_allowed "git checkout main" checkout main
assert_allowed "git checkout -b feature" checkout -b feature
assert_blocked "git restore --worktree file.txt" restore --worktree file.txt
assert_blocked "git restore -W file.txt" restore -W file.txt
assert_blocked "git restore --staged --worktree file.txt" restore --staged --worktree file.txt
assert_allowed "git restore --staged file.txt" restore --staged file.txt
# Task 5: combined short flags (bypass prevention)
assert_blocked "git checkout -Bf main" checkout -Bf main
assert_blocked "git checkout -fb feature" checkout -fb feature
assert_blocked "git restore -WS file.txt" restore -WS file.txt
# Task 5: subcommand-alone boundary case
assert_allowed "git checkout (no args)" checkout
assert_allowed "git restore (no args)" restore

# Task 5b: flag-level blocks (switch)
assert_blocked "git switch -C main" switch -C main
assert_blocked "git switch --discard-changes main" switch --discard-changes main
assert_allowed "git switch main" switch main
assert_allowed "git switch -c feature" switch -c feature
assert_allowed "git switch --detach HEAD" switch --detach HEAD
# Task 5b: combined short flags (bypass prevention)
assert_blocked "git switch -Cc feature" switch -Cc feature
assert_blocked "git switch -cC feature" switch -cC feature
# Task 5b: long-flag abbreviation
assert_blocked "git switch --discard main" switch --discard main
assert_allowed "git switch --det HEAD" switch --det HEAD
# Task 5b: subcommand-alone boundary case
assert_allowed "git switch (no args)" switch

# Task 6: flag-level blocks (rm, gc)
assert_blocked "git rm file.txt" rm file.txt
assert_blocked "git rm -f file.txt" rm -f file.txt
assert_blocked "git rm -r file.txt" rm -r file.txt
assert_allowed "git rm --cached file.txt" rm --cached file.txt
assert_allowed "git rm --cached -r file.txt" rm --cached -r file.txt
assert_blocked "git gc --prune" gc --prune
assert_blocked "git gc --prune=now" gc --prune=now
assert_allowed "git gc" gc
# Task 6: long-flag abbreviation
assert_allowed "git rm --cach file.txt" rm --cach file.txt
assert_blocked "git gc --pru" gc --pru

# Task 7: history-bypass subcommands (plumbing that circumvents rebase/filter-branch blocks)
assert_blocked "git commit-tree" commit-tree
assert_blocked "git commit-tree -p deadbeef -m msg" commit-tree -p deadbeef -m msg
assert_blocked "git update-ref" update-ref
assert_blocked "git update-ref refs/heads/x deadbeef" update-ref refs/heads/x deadbeef
assert_blocked "git update-ref -d refs/heads/x" update-ref -d refs/heads/x
assert_blocked "git update-ref --force refs/heads/x deadbeef" update-ref --force refs/heads/x deadbeef
assert_blocked "git replace" replace
assert_blocked "git replace deadbeef feedface" replace deadbeef feedface
assert_blocked "git replace -d deadbeef" replace -d deadbeef
assert_blocked "git fast-import" fast-import
assert_blocked "git prune" prune
assert_blocked "git prune --expire=now" prune --expire=now
assert_blocked "git symbolic-ref" symbolic-ref
assert_blocked "git symbolic-ref HEAD" symbolic-ref HEAD
assert_blocked "git symbolic-ref HEAD refs/heads/x" symbolic-ref HEAD refs/heads/x
assert_blocked "git symbolic-ref -d HEAD" symbolic-ref -d HEAD

# Task 8: block message includes bypass guidance
err="$(REAL_GIT="$STUB_DIR/git" "$WRAPPER" push 2>&1 >/dev/null)"
if [[ "$err" == *"Do not bypass"* && "$err" == *"always blocked"* && "$err" == *"Reconsider"* && "$err" == *"autonomous work"* ]]; then
    echo "PASS: block message includes bypass guidance"
    pass=$((pass+1))
else
    echo "FAIL: block message missing bypass guidance (got: $err)"
    fail=$((fail+1))
fi

# --- Git policy file tests ---

POLICY_TMP="$(mktemp)"

# Helper: run wrapper with a policy file set.
assert_blocked_with_policy() {
    local desc="$1"; shift
    local policy_content="$1"; shift
    printf '%s' "$policy_content" > "$POLICY_TMP"
    rm -f "$STUB_DIR/called"
    local err code
    err="$(REAL_GIT="$STUB_DIR/git" GIT_POLICY_FILE="$POLICY_TMP" "$WRAPPER" "$@" 2>&1 >/dev/null)" && code=0 || code=$?
    if [[ $code -ne 1 || "$err" != *"[SECURITY]"* ]]; then
        echo "FAIL: $desc (expected block, got code=$code err='$err')"
        fail=$((fail+1)); return
    fi
    echo "PASS: $desc"
    pass=$((pass+1))
}

assert_allowed_with_policy() {
    local desc="$1"; shift
    local policy_content="$1"; shift
    printf '%s' "$policy_content" > "$POLICY_TMP"
    rm -f "$STUB_DIR/called"
    REAL_GIT="$STUB_DIR/git" GIT_POLICY_FILE="$POLICY_TMP" "$WRAPPER" "$@" >/dev/null 2>&1
    local code=$?
    if [[ $code -ne 0 || ! -f "$STUB_DIR/called" ]]; then
        echo "FAIL: $desc (expected allow, got code=$code)"
        fail=$((fail+1)); return
    fi
    echo "PASS: $desc"
    pass=$((pass+1))
}

# Test: allow rule unblocks a default-blocked command
assert_allowed_with_policy "policy allow unblocks git reset --hard" \
    '[allow]
^reset' reset --hard HEAD~1

# Test: allow rule unblocks git commit --amend
assert_allowed_with_policy "policy allow unblocks git commit --amend" \
    '[allow]
^commit --amend' commit --amend

# Test: block rule blocks an allowed command
assert_blocked_with_policy "policy block blocks git stash pop" \
    '[block]
^stash pop' stash pop

# Test: allow rule for one command doesn't affect unrelated blocked commands
assert_blocked_with_policy "policy allow ^reset does not unblock git push" \
    '[allow]
^reset' push

# Test: block rule doesn't affect unrelated allowed commands
assert_allowed_with_policy "policy block ^stash pop does not block git status" \
    '[block]
^stash pop' status

# Test: comments and empty lines in policy file are skipped
assert_allowed_with_policy "policy file with comments and empty lines" \
    '[allow]
# this is a comment

^reset

# another comment' reset --hard

# Test: no policy file means default behavior (push still blocked)
rm -f "$STUB_DIR/called"
REAL_GIT="$STUB_DIR/git" "$WRAPPER" push >/dev/null 2>&1
code=$?
if [[ $code -eq 1 && ! -f "$STUB_DIR/called" ]]; then
    echo "PASS: no policy file - default blocks still apply"
    pass=$((pass+1))
else
    echo "FAIL: no policy file - default blocks still apply (code=$code)"
    fail=$((fail+1))
fi

rm -f "$POLICY_TMP"

# --- Local-override mode tests ---
# When SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS=true, only push is blocked.
# User policy file is also ignored.

# Same as assert_blocked but with SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS=true.
assert_blocked_override() {
    local desc="$1"; shift
    rm -f "$STUB_DIR/called"
    local err code
    err="$(REAL_GIT="$STUB_DIR/git" SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS=true "$WRAPPER" "$@" 2>&1 >/dev/null)" && code=0 || code=$?
    if [[ $code -ne 1 ]]; then
        echo "FAIL: $desc (exit $code, expected 1)"
        fail=$((fail+1)); return
    fi
    if [[ "$err" != *"[SECURITY]"* ]]; then
        echo "FAIL: $desc (no [SECURITY] in stderr: $err)"
        fail=$((fail+1)); return
    fi
    if [[ -f "$STUB_DIR/called" ]]; then
        echo "FAIL: $desc (real git was called despite block)"
        fail=$((fail+1)); return
    fi
    echo "PASS: $desc"
    pass=$((pass+1))
}

# Same as assert_allowed but with SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS=true.
assert_allowed_override() {
    local desc="$1"; shift
    rm -f "$STUB_DIR/called"
    REAL_GIT="$STUB_DIR/git" SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS=true "$WRAPPER" "$@" >/dev/null 2>&1
    local code=$?
    if [[ $code -ne 0 ]]; then
        echo "FAIL: $desc (exit $code, expected 0)"
        fail=$((fail+1)); return
    fi
    if [[ ! -f "$STUB_DIR/called" ]]; then
        echo "FAIL: $desc (real git was not called)"
        fail=$((fail+1)); return
    fi
    echo "PASS: $desc"
    pass=$((pass+1))
}

# Push still blocked in override mode
assert_blocked_override "override: git push" push
assert_blocked_override "override: git push origin main" push origin main

# Previously-blocked local ops now allowed
assert_allowed_override "override: git reset --hard HEAD~1" reset --hard HEAD~1
assert_allowed_override "override: git reset --soft HEAD~1" reset --soft HEAD~1
assert_allowed_override "override: git commit --amend" commit --amend
assert_allowed_override "override: git commit --reset-author" commit --reset-author
assert_allowed_override "override: git branch -D x" branch -D x
assert_allowed_override "override: git branch --delete --force x" branch --delete --force x
assert_allowed_override "override: git config user.name X" config user.name X
assert_allowed_override "override: git config --global user.name X" config --global user.name X
assert_allowed_override "override: git clean -fd" clean -fd
assert_allowed_override "override: git rebase main" rebase main
assert_allowed_override "override: git stash drop" stash drop
assert_allowed_override "override: git stash clear" stash clear
assert_allowed_override "override: git tag -f v1" tag -f v1
assert_allowed_override "override: git tag --force v1" tag --force v1
assert_allowed_override "override: git checkout -B x" checkout -B x
assert_allowed_override "override: git checkout --force x" checkout --force x
assert_allowed_override "override: git switch -C x" switch -C x
assert_allowed_override "override: git restore --worktree x" restore --worktree x
assert_allowed_override "override: git rm file" rm file
assert_allowed_override "override: git gc --prune" gc --prune
assert_allowed_override "override: git reflog expire" reflog expire
assert_allowed_override "override: git notes remove" notes remove
assert_allowed_override "override: git worktree remove x" worktree remove x
assert_allowed_override "override: git commit-tree HEAD" commit-tree HEAD
assert_allowed_override "override: git update-ref refs/heads/x HEAD" update-ref refs/heads/x HEAD
assert_allowed_override "override: git replace refs/heads/x HEAD" replace refs/heads/x HEAD
assert_allowed_override "override: git filter-branch" filter-branch
assert_allowed_override "override: git filter-repo" filter-repo
assert_allowed_override "override: git fast-import" fast-import
assert_allowed_override "override: git prune" prune
assert_allowed_override "override: git symbolic-ref" symbolic-ref

# Default-allowed ops still allowed
assert_allowed_override "override: git status" status
assert_allowed_override "override: git log" log

# User policy file ignored in override mode
POLICY_TMP="$(mktemp)"
printf '[block]\n^status$\n[allow]\n^push$\n' > "$POLICY_TMP"
rm -f "$STUB_DIR/called"
REAL_GIT="$STUB_DIR/git" SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS=true GIT_POLICY_FILE="$POLICY_TMP" "$WRAPPER" status >/dev/null 2>&1
code=$?
if [[ $code -eq 0 && -f "$STUB_DIR/called" ]]; then
    echo "PASS: override: user policy block on status ignored"
    pass=$((pass+1))
else
    echo "FAIL: override: user policy block on status ignored (code=$code)"
    fail=$((fail+1))
fi
rm -f "$STUB_DIR/called"
REAL_GIT="$STUB_DIR/git" SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS=true GIT_POLICY_FILE="$POLICY_TMP" "$WRAPPER" push >/dev/null 2>&1
code=$?
if [[ $code -eq 1 && ! -f "$STUB_DIR/called" ]]; then
    echo "PASS: override: user policy allow on push ignored"
    pass=$((pass+1))
else
    echo "FAIL: override: user policy allow on push ignored (code=$code)"
    fail=$((fail+1))
fi
rm -f "$POLICY_TMP"

echo ""
echo "Results: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]] || exit 1
