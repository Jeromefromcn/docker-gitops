---
name: write-incident
description: Write up a troubleshooting session as a record under docs/incidents/ and add the corresponding row to the index table. Use when an investigation wraps up and the user says "note this down", "write an incident record", "archive this investigation", or when a non-trivial root-cause analysis has just finished.
---

# Write an incident record

## When it's worth writing

Only write one when the root cause is **non-obvious** and you'd have to re-investigate it from scratch next time. Don't write one for a typo fix. Test: if a future-you six months from now sees the same symptoms, would this record save them the investigation time?

## 1. Search first

```bash
grep -ril '<keyword>' docs/incidents/
```

If a record already covers the same root cause, **add a "postscript" to the end of that one** instead of starting a new one — `2026-08-15-ccr-vscode-extension-stall.md` did exactly this (postscript II at the end).

## 2. Filename

`docs/incidents/YYYY-MM-DD-<service>-<short-description>.md`

The date is the **day the incident happened**, not the day you write the doc. `<service>` uses the stack name from the repo (`npm`, `ccr`, `3x-ui`…); cross-component ones use the `a/b` form (`k3s/docker`, `compose/k3s`).

## 3. Skeleton

```markdown
# <one line saying clearly what happened>

- Date: YYYY-MM-DD
- Environment: <components and versions involved, specific enough to reproduce>
- Symptom: <what the user / monitoring saw>
- Fix: <what was ultimately changed, in one line>

---

## 1. Conclusion first

**The root cause is X, not Y.** <finish in a few sentences so the reader can act without reading the rest>

## 2. Evidence chain

<give commands and output in time/reasoning order. paste real output, don't paraphrase>

## 3. Root cause

<explain at the mechanism level: why this necessarily happens under these conditions>

## 4. Fix

<which files changed, what was run, and why this approach over another>

## 5. Verification

<how to confirm it's actually fixed — command + expected output>

## 6. Leftovers / lessons

<what's still unresolved; how to spot it faster next time; whether there's an inspection check that should be added>
```

Minor incidents may merge sections (see the six-section style in `2026-08-19-npm-to-k3s-nodeport-outage.md`), but **"conclusion first" always goes at the very front** — that's the consistent style of this set of docs.

## 4. Add the index entry (don't miss it)

Add a row to the table in [`docs/incidents/README.md`](../../../docs/incidents/README.md), **inserted at the top in reverse chronological order**:

```markdown
| YYYY-MM-DD | <service> | <one-line summary including the root cause> | [link](YYYY-MM-DD-<service>-<description>.md) |
```

The summary must include the root cause, not just the symptom — this table is for "spotting similar issues at a glance".

## 5. Consider whether to add an inspection check

If this incident was "the kind that would've been far less severe if caught earlier", consider adding a check under [`vps_oracle/host-native/inspector/`](../../../vps_oracle/host-native/inspector/) — use the `inspector-check` skill. The `npm-nginx-config.sh` and `k3s-memory` checks all came about this way.

## 6. Language

Write the body in Chinese per repo convention; commit messages in English.