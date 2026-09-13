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

- Keep `README.md` up to date whenever you change behaviour, CLI interface, volumes, or install paths.
- Do not break the invariants listed in `docs/development.md`.
