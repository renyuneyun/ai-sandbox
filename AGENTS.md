# AGENTS.md

The agent rules for this repository live in [`CLAUDE.md`](CLAUDE.md) — read it
before changing anything. In particular:

- Keep `README.md` and `docs/` in sync with behavior (the "Keeping docs in sync"
  checklist in [`docs/development.md`](docs/development.md)), and do not break
  the invariants listed there.
- **Commit your own work as you finish it, without waiting for a manual
  instruction to commit.** Follow the "Commit granularity" guidance in
  [`docs/development.md`](docs/development.md): commit in
  coherent reviewable units (a feature, its tests, its docs, or a refactor) —
  they may share a commit or be a few separate ones — not a commit per step, and
  fold follow-up edits and review fixes into the commit they belong to.