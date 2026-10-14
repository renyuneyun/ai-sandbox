#!/usr/bin/env bash
# Bump the ai-sandbox version. The version lives in exactly two
# placeholders -- bin/ai-sandbox (VERSION=) and packaging/PKGBUILD
# (pkgver=) -- so this rewrites both, then commits and tags the result.
# Dev-only helper; not installed by install.sh / packaging.
# See "Version bumps" in docs/development.md.
set -euo pipefail

BIN_REL="bin/ai-sandbox"
PKG_REL="packaging/PKGBUILD"

usage() {
  cat <<'EOF'
Usage: scripts/bump-version.sh <patch|minor|major|X.Y.Z> [options]

Bump the ai-sandbox version. By default it rewrites both version
placeholders (VERSION= in bin/ai-sandbox, pkgver=/pkgrel= in
packaging/PKGBUILD), commits "chore: bump version to vX.Y.Z", and creates
the lightweight tag vX.Y.Z.

Options:
  --no-commit   Only rewrite the version files (implies --no-tag).
  --no-tag      Rewrite the files and commit, but do not create the tag.
  --dry-run     Print what would happen without changing anything.
  -h, --help    Show this help.
EOF
}

die() { echo "bump-version: $*" >&2; exit 1; }

selector=""
do_commit=true
do_tag=true
dry_run=false

for arg in "$@"; do
  case "$arg" in
    --no-commit) do_commit=false; do_tag=false ;;
    --no-tag)    do_tag=false ;;
    --dry-run)   dry_run=true ;;
    -h|--help)   usage; exit 0 ;;
    --*)         die "unknown option: $arg" ;;
    *)           [[ -z "$selector" ]] || die "unexpected argument: $arg"
                 selector="$arg" ;;
  esac
done

[[ -n "$selector" ]] || { usage >&2; die "a bump selector is required"; }

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"
cd "$ROOT"
BIN_FILE="$ROOT/$BIN_REL"
PKG_FILE="$ROOT/$PKG_REL"

[[ -f "$BIN_FILE" ]] || die "missing $BIN_REL"
[[ -f "$PKG_FILE" ]] || die "missing $PKG_REL"

current="$(sed -n 's/^VERSION="\([0-9][0-9.]*\)"$/\1/p' "$BIN_FILE" | head -n1)"
[[ -n "$current" ]] || die "could not read VERSION from $BIN_REL"
[[ "$current" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "current version '$current' is not X.Y.Z"

IFS=. read -r cur_major cur_minor cur_patch _ <<<"$current"

case "$selector" in
  patch) new="$cur_major.$cur_minor.$(( 10#$cur_patch + 1 ))" ;;
  minor) new="$cur_major.$(( 10#$cur_minor + 1 )).0" ;;
  major) new="$(( 10#$cur_major + 1 )).0.0" ;;
  [0-9]*.[0-9]*.[0-9]*) new="$selector" ;;
  *) die "invalid selector '$selector' (expected patch|minor|major|X.Y.Z)" ;;
esac
[[ "$new" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid resulting version '$new'"
[[ "$new" != "$current" ]] || die "already at $current"

if git rev-parse -q --verify "refs/tags/v$new" >/dev/null 2>&1; then
  die "tag v$new already exists"
fi

clean=true
[[ -z "$(git status --porcelain)" ]] || clean=false

if [[ "$dry_run" == false && "$do_commit" == true && "$clean" == false ]]; then
  die "working tree is not clean; commit or stash your changes first"
fi

if [[ "$dry_run" == true ]]; then
  echo "bump-version: would set $current -> $new"
  echo "  - $BIN_REL"
  echo "  - $PKG_REL"
  if [[ "$do_commit" == true ]]; then
    echo "  - commit: chore: bump version to v$new"
    if [[ "$do_tag" == true ]]; then
      echo "  - tag: v$new"
    fi
    [[ "$clean" == true ]] || echo "  (note: working tree is not clean; a real run would refuse to commit)"
  fi
  exit 0
fi

grep -q '^VERSION="' "$BIN_FILE" || die "no VERSION= line in $BIN_REL"
grep -q '^pkgver=' "$PKG_FILE" || die "no pkgver= line in $PKG_REL"

# Rewrite via a temp file + cat back (portable; preserves the file's mode).
subst() {  # FILE SED_ARGS...
  local f="$1"; shift
  local tmp; tmp="$(mktemp)"
  if ! sed "$@" "$f" > "$tmp"; then rm -f "$tmp"; return 1; fi
  cat "$tmp" > "$f"
  rm -f "$tmp"
}

subst "$BIN_FILE" "s#^VERSION=.*#VERSION=\"$new\"#"
subst "$PKG_FILE" -e "s#^pkgver=.*#pkgver=$new#" -e "s#^pkgrel=.*#pkgrel=1#"

if [[ "$do_commit" == true ]]; then
  git add -- "$BIN_FILE" "$PKG_FILE"
  git commit -q -m "chore: bump version to v$new"
  echo "bump-version: committed v$new"
  if [[ "$do_tag" == true ]]; then
    git tag "v$new"
    echo "bump-version: tagged v$new"
  fi
else
  echo "bump-version: updated version files to $new (not committed)"
fi