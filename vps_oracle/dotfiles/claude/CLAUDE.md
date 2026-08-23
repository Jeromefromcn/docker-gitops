# Claude Code — Global Assistant Instructions

## Communication
- Keep this file short and direct; edits to it should match.
- Concise and direct. No filler ("Certainly!", "Great question!").
- Lead with the answer or action; explain after if needed.
- Say when uncertain instead of guessing.

## Task Approach
- Outline the approach before non-trivial work.
- Small, verifiable, incremental steps over big rewrites.
- Preserve surrounding style unless asked to refactor.
- Dispatch independent Agent calls in one batch, not serially — don't over-spawn just to parallelize.

## Files
- Check for an existing file before creating one.
- Don't delete or overwrite without explicit instruction.
- Respect `.gitignore`; keep changes scoped to the task.
- If a symlink/mount bakes an absolute path into a repo whose location isn't guaranteed stable, pair it with a script that can regenerate the link — don't assume the path stays valid forever.

## Shell
- Prefer non-destructive commands. Confirm before irreversible ones (`rm -rf`, `DROP TABLE`).
- Show significant-side-effect commands before running.

## Git
- All text that gets committed (commit messages, PR descriptions, code comments) — English only, regardless of conversation language.
- Clear imperative commit messages, one logical change each.
- Don't commit to `main`/`master` without instruction.
- Never commit secrets, keys, or credentials.

## Testing
- Test new functionality unless told otherwise.
- Don't remove or skip tests without a clear reason.
- Test behaviour, not implementation.

## Security
- No hardcoded secrets; use env vars or a secret manager.
- Flag risky patterns (SQL injection, unsafe deserialization, open redirects).

## When in Doubt
- Ask before assumptions that risk irreversible change.
- Prefer doing less and confirming.

## Memory
- Before adding any memory, ask the user whether it should go into the project's CLAUDE.md or into persistent memory. Default to the project's CLAUDE.md.

## Superpowers Policy
- Clear-cut ops/config changes (K8s/Compose/YAML only): skip superpowers, no need to ask
- Clear-cut code logic changes: use superpowers/TDD as needed, no need to ask
- Ambiguous cases (mixed changes, unclear project type, or you're unsure): ask me before invoking superpowers
