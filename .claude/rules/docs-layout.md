# Where documentation goes

No `paths:` scope on purpose — this decides where a *new* file gets written, so it has to be in context before any doc file is read.

Knowledge in this repo has two layers:

| Layer | Location | What it is |
|---|---|---|
| **Current state** | root `README.md`, each subdirectory's `README.md`, `.claude/rules/` | The single authority on "how things are now, and how to do it" |
| **History** | `docs/` | "Why it ended up this way" — consult on demand, not required daily reading |

Inside `docs/`:

- `incidents/` — troubleshooting records. Filename `YYYY-MM-DD-<service>-<short-description>.md`; after adding one, add a row to the table in [`docs/incidents/README.md`](../../docs/incidents/README.md), newest first.
- `misc/` — upstream reports and other material unrelated to daily ops.
- `superpowers/specs/`, `superpowers/plans/` — design docs and implementation plans. **Point-in-time snapshots; they do not describe the current state.**
- `container-topology/` — container topology snapshots; the highest version number is the newest.

Rules:

- When troubleshooting, **search `docs/incidents/` first** — a matching symptom may already have a root cause on record.
- Never quote `docs/superpowers/` as a statement of current state without checking it against the README first.
- A change that alters "how things are now" must update the README/rules; adding a `docs/` record is optional.
- Diagrams in any markdown file: use Mermaid, not ASCII art.
