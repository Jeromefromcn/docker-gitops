# ccr misroutes subagent pro requests as flash

- Date: 2026-08-30
- Environment: VS Code Claude Code (2.1.251) → ccr (claude-code-router v3.0.20, self-built Docker image) → byteplus (Volcano Ark deepseek-v4 series)
- Symptom: the main session using pro (opus tier) works fine, but subagent requests spawned by the Task tool get downgraded to flash, and become noticeably faster/dumber in their answers
- Fix: added `vps_oracle/compose/ccr/patch-subagent-routing.cjs`, patching one piece of logic in `ZPe()` inside server.js before the gateway starts; mounted via compose + injected via `NODE_OPTIONS --require`, self-healing at runtime and surviving image rebuilds

---

## 1. Conclusion first

**The root cause is in ccr's routing code, not in Claude Code.** CC's subagent request fills the model field correctly with pro (full name `byteplus/deepseek-v4-pro-ga-260813`), but ccr's `builtin-agent-claude-code` rule, after recognizing the subagent marker, **unconditionally disables the "client-model" strategy**, so the pro carried by the request is ignored and it falls through to the profile's fallback `model` (flash).

## 2. Evidence chain

### 2.1 Symptom reproduction (request-logs)

The main session and the subagent are the same CC session; the main session's request is model=pro, and the subagent's request should also be pro, but the actual routing result:

```
12203 main         | CC sent pro   → resolved pro    ✓
12205 SUB(a51eea)  | CC sent pro   → resolved FLASH  ✗  ← root cause
12206 SUB(a51eea)  | CC sent pro   → resolved FLASH  ✗
```

At the same moment, in the same session, the main session goes via `default-route` (respecting the request's model=pro), while the subagent goes via `builtin-agent-claude-code` (forcing profile.model=flash).

### 2.2 The subagent request body CC sends (recorded proxy capture as hard evidence)

`x-anthropic-billing-header: cc_version=...; cc_entrypoint=claude-vscode; cc_is_subagent=true;`

The request body's `model` field = `byteplus/deepseek-v4-pro-ga-260813` (pro), **CC did not send it wrong**.

### 2.3 ccr routing decision (trace)

Subagent request hop2: `decision builtins.builtin-agent-claude-code → target: flash`

Main session request hop2: `decision builtins.default-route → target: pro`

The difference is that the subagent request carries the `x-claude-code-agent-id` + `cc_is_subagent=true` markers, triggering the builtin rule.

## 3. Root cause

In ccr's minified `server.js` (`/app/packages/core/dist/main/server.js`), the evaluation chain for the routing decision `KPe`:

```
g = client-model (the request's own model, kept if resolvable by modelRegistry)
p = builtin-agent (eQe → profile.model = flash)
final m = A ?? g ?? p
```

Where `g` is gated by `ZPe()`:

```js
function ZPe(e,t,r,n){
  if(!gh(e,t,"claude-code")) return true;
  if(e.builtInClaudeCodeSubagent===!0) return false;   // ← the defect
  ...
}
```

For a subagent request (`builtInClaudeCodeSubagent=true`), `ZPe` directly `return false`, **unconditionally disabling client-model**. At this point:

- `XPe` (the subagent-env strategy) reads the `CLAUDE_CODE_SUBAGENT_MODEL` environment variable — this repo's profile doesn't set it → returns undefined
- So the evaluation chain falls all the way to `p` (`eQe` → `profile.model` = flash)

**The essence of the defect**: disabling client-model for a subagent should be preconditioned on "`CLAUDE_CODE_SUBAGENT_MODEL` exists", not unconditional. When there's no subagent-specific model, it should fall back to client-model (the pro carried by the request).

## 4. Fix

`patch-subagent-routing.cjs` rewrites `ZPe` before the gateway starts (via `NODE_OPTIONS --require`) into:

```js
function ZPe(e,t,r,n){
  if(!gh(e,t,"claude-code")) return true;
  let o=u0(e,t,"claude-code"), i=LP(o?.env?.[w5],t,r);
  if(e.builtInClaudeCodeSubagent===!0) return !i;   // disable client-model only when SUBAGENT_MODEL exists
  return !i || !n || i.canonicalSelector.toLowerCase() !== n.canonicalSelector.toLowerCase();
}
```

That is: for a subagent, client-model is disabled only when the profile sets `CLAUDE_CODE_SUBAGENT_MODEL` (`i` is non-empty), letting `XPe`'s exact matching take over; otherwise client-model is kept, respecting the model carried by the request. **No model is hardcoded** — it fully follows the tier-dependent model CC sends dynamically.

### Verification after the fix

```
12295 SUB(ac9937) | CC sent pro → resolved PRO  ✓
12297 SUB(ac9937) | CC sent pro → resolved PRO  ✓
```

The trace shows subagent requests now going via `default-route` (consistent with the main session), no longer forced to flash by `builtin-agent-claude-code`.

## 5. Why a patch script rather than a config change

`ZPe` lives at the image layer (`/app/packages/core/dist/main/server.js`) with no config switch. The image is built from a pinned git tag v3.0.20, so the patch is made as a `--require` script:

- **Runtime self-healing**: each node process re-applies the patch at startup; after `docker compose up -d --build` rebuilds the image, the first node process automatically re-applies it (verified: after a rebuild both the patch marker and the new ZPe are present, the old ZPe is zeroed out)
- **Idempotent**: only patches when the old string is detected; skips if already patched; warns if the expected string can't be detected (hinting ccr may have been upgraded and the ZPe logic needs manual review)
- **git-auditable**: the patch content is in `vps_oracle/compose/ccr/patch-subagent-routing.cjs`, the same `--require` pattern as `sse-coalesce.cjs` and `export-model-routing.cjs`

## 6. Open items / notes

- If `CLAUDE_CODE_SUBAGENT_MODEL` is later set for the profile in the ccr panel, the subagent goes via `XPe` exact matching (hit only when `CLAUDE_CODE_SUBAGENT_MODEL == request model`); non-matching still falls through to profile.model. This is ccr's native design, unchanged by this patch.
- If ccr is upgraded to a new version, `ZPe`'s minified string may change, and the patch script will warn "ZPe not found in expected form" — at that point the new version's logic must be re-reviewed and `OLD_ZPE`/`NEW_ZPE` updated.
- The flash requests with `query_source: auto_mode` (no agent-id) appearing in the main session are CC's auto mode behavior, unrelated to this bug.