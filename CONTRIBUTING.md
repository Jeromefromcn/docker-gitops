# Contributing

Issues, questions and pull requests are welcome. This is a personal GitOps
repo for one VPS, so responses are best-effort.

## Before opening a pull request

- Open an issue first for anything non-trivial.
- One change per commit, scoped to a single stack or component.
- Commit messages: English, imperative mood.
- Never commit secrets. Use `.env` (gitignored), never inline values.
- Run the conventions checker locally:

  ```bash
  python3 .github/scripts/check-compose-conventions.py
  ```

- For compose changes, also run `docker compose config -q` on the file.
- Follow the rules in [`.claude/rules/`](.claude/rules/) and the README of the
  directory you are changing.

## Reporting security issues

Do not open a public issue. See [SECURITY.md](SECURITY.md).
