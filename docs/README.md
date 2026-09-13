# docs

This repo's knowledge lives in two layers: **the root README and each subdirectory README are the single source of truth for "how things are now"**, while this directory holds "why it ended up this way / how we got here" — consult it on demand, not as pre-work for everyday operation.

| Directory | What goes here | When to look |
|---|---|---|
| [`incidents/`](incidents/README.md) | Troubleshooting records, newest first, with root causes | Search first when you hit a similar symptom — there may be a recorded root cause |
| [`misc/`](misc/README.md) | Other material unrelated to daily ops (upstream feedback, external reports, etc.) | Basically never need to look proactively |
| `superpowers/plans/`, `superpowers/specs/` | Design docs and implementation plans, mostly point-in-time snapshots of a phase | When digging into "why was this current behavior designed this way" — **they do not describe the current state**: for that, read the README; content here may already have been superseded by later changes |
| [`container-topology/`](container-topology/v3.md) | Successive container deployment topology snapshots (v1/v2/v3), each recording the full service distribution at that time | When you want to see the overall architecture at some point in time; the highest version number is the newest |
| [`2026-07-26-npm-reverse-proxy-migration.md`](2026-07-26-npm-reverse-proxy-migration.md) | Complete record of building the NPM reverse proxy from scratch and migrating existing services onto it, including 7 gotchas | When troubleshooting NPM-related issues, there may be a ready-made case |

Files under `superpowers/plans/` and `superpowers/specs/` aren't listed one by one here — there are too many (35+) and most of their content has already been absorbed into the corresponding README sections; the ones that are genuinely still current and not yet covered by a README are linked directly from the root README or `vps_oracle/k3s/README.md`. When there's no direct link and you want to dig into a phase's historical decisions, search these two subdirectories by filename date / keyword.