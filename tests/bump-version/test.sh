#!/bin/bash
# Unit tests for scripts/bump-version.sh.
# Run: bash tests/bump-version/test.sh
#
# Each case builds a throwaway git repo containing the two version
# placeholders (bin/ai-sandbox + packaging/PKGBUILD) and runs the real
# script inside it, asserting the file/commit/tag effects.
#
# Git identity comes from the environment so the tests never call
# `git config` (blocked by the ai-sandbox git wrapper, and unnecessary).

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUMP="$SCRIPT_DIR/../../scripts/bump-version.sh"

if ! command -v git >/dev/null 2>&1; then
    echo "SKIP: git not installed; skipping bump-version tests"
    exit 0
fi

# Fail loudly (rather than vacuously) if the script is missing.
if [[ ! -f "$BUMP" ]]; then
    echo "FAIL: $BUMP not found"
    exit 1
fi

export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.com
# Keep signing off without touching config (works on any host).
export GIT_CONFIG_COUNT=2
export GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false
export GIT_CONFIG_KEY_1=tag.gpgsign    GIT_CONFIG_VALUE_1=false

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

pass=0
fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
check_eq() {  # NAME EXPECTED ACTUAL
    if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi
}

# Build a clean git repo with the two version placeholders.
make_fixture() {  # DIR [CURRENT_VERSION] [PKGREL]
    local dir="$1" ver="${2:-0.7.1}" rel="${3:-1}"
    mkdir -p "$dir/bin" "$dir/packaging"
    printf '#!/usr/bin/env bash\n\nVERSION="%s"\n' "$ver" > "$dir/bin/ai-sandbox"
    printf 'pkgname=ai-sandbox\npkgver=%s\npkgrel=%s\n' "$ver" "$rel" > "$dir/packaging/PKGBUILD"
    git -c init.defaultBranch=main init -q "$dir"
    git -C "$dir" add -A
    git -C "$dir" commit -q -m initial
}

run_bump() {  # DIR ARGS...
    local dir="$1"; shift
    ( cd "$dir" && bash "$BUMP" "$@" )
}

bin_version()  { sed -n 's/^VERSION="\(.*\)"$/\1/p' "$1/bin/ai-sandbox"; }
pkg_ver()      { sed -n 's/^pkgver=\(.*\)$/\1/p' "$1/packaging/PKGBUILD"; }
pkg_rel()      { sed -n 's/^pkgrel=\(.*\)$/\1/p' "$1/packaging/PKGBUILD"; }
head_subject() { git -C "$1" log -1 --format=%s; }
tag_exists()   { [[ -n "$(git -C "$1" tag -l "$2")" ]]; }

# --- patch / minor / major arithmetic ---

d="$TMPROOT/patch"; make_fixture "$d"
run_bump "$d" patch >/dev/null 2>&1
check_eq "patch: VERSION bumped" "0.7.2" "$(bin_version "$d")"
check_eq "patch: pkgver bumped"  "0.7.2" "$(pkg_ver "$d")"

d="$TMPROOT/minor"; make_fixture "$d"
if run_bump "$d" minor >/dev/null 2>&1; then ok "minor: exits 0"; else bad "minor: exit status"; fi
check_eq "minor: VERSION bumped"     "0.8.0" "$(bin_version "$d")"
check_eq "minor: pkgver bumped"      "0.8.0" "$(pkg_ver "$d")"
check_eq "minor: commit message"     "chore: bump version to v0.8.0" "$(head_subject "$d")"
if tag_exists "$d" v0.8.0; then ok "minor: tag v0.8.0 created"; else bad "minor: tag v0.8.0"; fi
check_eq "minor: tag points at HEAD" "$(git -C "$d" rev-parse HEAD)" "$(git -C "$d" rev-parse v0.8.0)"
check_eq "minor: clean tree after"   "" "$(git -C "$d" status --porcelain)"

d="$TMPROOT/major"; make_fixture "$d"
run_bump "$d" major >/dev/null 2>&1
check_eq "major: VERSION bumped" "1.0.0" "$(bin_version "$d")"

# --- explicit version override ---

d="$TMPROOT/explicit"; make_fixture "$d"
run_bump "$d" 0.9.3 >/dev/null 2>&1
check_eq "explicit: VERSION set" "0.9.3" "$(bin_version "$d")"
if tag_exists "$d" v0.9.3; then ok "explicit: tag v0.9.3 created"; else bad "explicit: tag v0.9.3"; fi

# --- pkgrel is reset to 1 ---

d="$TMPROOT/pkgrel"; make_fixture "$d" 0.7.1 3
run_bump "$d" minor >/dev/null 2>&1
check_eq "pkgrel: reset to 1" "1" "$(pkg_rel "$d")"

# --- partial modes ---

d="$TMPROOT/nocommit"; make_fixture "$d"
if run_bump "$d" minor --no-commit >/dev/null 2>&1; then ok "no-commit: exits 0"; else bad "no-commit: exit status"; fi
check_eq "no-commit: VERSION bumped"  "0.8.0"   "$(bin_version "$d")"
check_eq "no-commit: HEAD untouched"  "initial" "$(head_subject "$d")"
if tag_exists "$d" v0.8.0; then bad "no-commit: unexpected tag"; else ok "no-commit: no tag"; fi

d="$TMPROOT/notag"; make_fixture "$d"
if run_bump "$d" minor --no-tag >/dev/null 2>&1; then ok "no-tag: exits 0"; else bad "no-tag: exit status"; fi
check_eq "no-tag: commit created" "chore: bump version to v0.8.0" "$(head_subject "$d")"
if tag_exists "$d" v0.8.0; then bad "no-tag: unexpected tag"; else ok "no-tag: no tag"; fi

d="$TMPROOT/dryrun"; make_fixture "$d"
if run_bump "$d" minor --dry-run >/dev/null 2>&1; then ok "dry-run: exits 0"; else bad "dry-run: exit status"; fi
check_eq "dry-run: VERSION untouched" "0.7.1"   "$(bin_version "$d")"
check_eq "dry-run: HEAD untouched"    "initial" "$(head_subject "$d")"
if tag_exists "$d" v0.8.0; then bad "dry-run: unexpected tag"; else ok "dry-run: no tag"; fi

# --- guards ---

d="$TMPROOT/dirty"; make_fixture "$d"
printf '# scratch\n' >> "$d/bin/ai-sandbox"
if run_bump "$d" minor >/dev/null 2>&1; then bad "dirty: should refuse to commit"; else ok "dirty: refuses to commit"; fi
check_eq "dirty: VERSION untouched" "0.7.1"   "$(bin_version "$d")"
check_eq "dirty: HEAD untouched"    "initial" "$(head_subject "$d")"

d="$TMPROOT/tagclash"; make_fixture "$d"
git -C "$d" tag v0.8.0
if run_bump "$d" minor >/dev/null 2>&1; then bad "tagclash: should refuse existing tag"; else ok "tagclash: refuses existing tag"; fi
check_eq "tagclash: VERSION untouched" "0.7.1"   "$(bin_version "$d")"
check_eq "tagclash: HEAD untouched"    "initial" "$(head_subject "$d")"

d="$TMPROOT/equal"; make_fixture "$d"
if run_bump "$d" 0.7.1 >/dev/null 2>&1; then bad "equal: should refuse same version"; else ok "equal: refuses same version"; fi
check_eq "equal: VERSION untouched" "0.7.1" "$(bin_version "$d")"

d="$TMPROOT/badarg"; make_fixture "$d"
if run_bump "$d" banana >/dev/null 2>&1; then bad "badarg: should refuse bad selector"; else ok "badarg: refuses bad selector"; fi
check_eq "badarg: VERSION untouched" "0.7.1" "$(bin_version "$d")"

d="$TMPROOT/noarg"; make_fixture "$d"
if run_bump "$d" >/dev/null 2>&1; then bad "noarg: should refuse missing selector"; else ok "noarg: refuses missing selector"; fi
check_eq "noarg: VERSION untouched" "0.7.1" "$(bin_version "$d")"

echo ""
echo "Results: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]] || exit 1