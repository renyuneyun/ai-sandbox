# CLAUDE.md

This is a Docker-sandboxed coding-agent launcher with first-class Claude Code and Codex CLI profiles. Read `README.md` for a full description of how it works.

## Files

| File | Purpose |
|---|---|
| `bin/ai-sandbox` | Bash launcher script |
| `share/ai-sandbox/docker-compose.yml` | Container definition and other runtime data files |
| `packaging/PKGBUILD` | Arch Linux package recipe |
| `install.sh` | Cross-platform install script (macOS, WSL, Linux) |
| `README.md` | Full documentation |

## Rules

- Keep `README.md` and the docs under `docs/` up to date whenever you change behaviour, CLI interface, volumes, config/env knobs, or install paths.
- Follow the "Keeping docs in sync" checklist in `docs/development.md` for any change, including auditing docs for drift from older commits — do not leave it for the user to re-check manually.
- Do not break the invariants listed in `docs/development.md`.
