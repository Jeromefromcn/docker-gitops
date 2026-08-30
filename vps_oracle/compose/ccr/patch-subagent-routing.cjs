"use strict";
// Patches a routing bug in claude-code-router v3.0.20's minified server.js, at
// container startup, before the gateway loads it. The patch lives here in git
// and is re-applied by every node process ccr starts (loaded via NODE_OPTIONS
// --require, same mechanism as sse-coalesce.cjs / export-model-routing.cjs), so
// it survives a `docker compose up -d --build` image rebuild: even if the image
// ships the pristine server.js, the first node process to boot re-patches it.
//
// ## The bug (see docs/incidents/2026-08-30-ccr-subagent-flash-routing.md)
//
// Claude Code's subagent requests carry `x-claude-code-agent-id` plus a
// `cc_is_subagent=true` billing header. ccr's route engine (KPe) marks these
// `builtInClaudeCodeSubagent = true`. Its ZPe() guard then does:
//
//     if (e.builtInClaudeCodeSubagent === true) return false;
//
// which *unconditionally* disables the "client-model" policy (the model the
// client actually asked for — e.g. the pro tier the parent session is using).
// With no CLAUDE_CODE_SUBAGENT_MODEL env set on the profile, the next
// subagent-specific policy (XPe) also yields nothing, so routing falls through
// to the profile's default `model` (flash) — every subagent request gets
// silently downgraded from pro to flash, even though the request body says pro.
//
// ## The fix
//
// Only disable the client-model policy for subagents when a
// CLAUDE_CODE_SUBAGENT_MODEL actually exists (in which case the XPe policy
// takes over with its exact-match logic). Otherwise keep the client-model
// policy, so the request's own model (pro) is honoured. This is a one-line
// semantic change inside ZPe: the `return false` becomes `return !i`, where
// `i` is the resolved CLAUDE_CODE_SUBAGENT_MODEL (already computed).
//
// ## Why patch a file instead of patching config
//
// ZPe lives in the upstream minified dist (`/app/packages/core/dist/main/
// server.js`), inside the image layer — there is no config switch for it. The
// patch is applied at startup rather than committed into the image because the
// image is built from a pinned git tag (v3.0.20); patching at runtime keeps the
// change reviewable in this repo and re-appliable after any rebuild.

const fs = require("node:fs");
const path = require("node:path");

const SERVER_JS = "/app/packages/core/dist/main/server.js";

// Minified function body we replace. Kept as the exact byte-for-byte string so
// the patch is idempotent: if it's absent, either it already got patched or the
// upstream code changed (a newer ccr version) — never patch a mismatch.
const OLD_ZPE =
  'function ZPe(e,t,r,n){if(!gh(e,t,"claude-code"))return!0;' +
  'if(e.builtInClaudeCodeSubagent===!0)return!1;' +
  'let o=u0(e,t,"claude-code"),i=LP(o?.env?.[w5],t,r);' +
  'return!i||!n||i.canonicalSelector.toLowerCase()!==n.canonicalSelector.toLowerCase()}';

const NEW_ZPE =
  'function ZPe(e,t,r,n){if(!gh(e,t,"claude-code"))return!0;' +
  'let o=u0(e,t,"claude-code"),i=LP(o?.env?.[w5],t,r);' +
  'if(e.builtInClaudeCodeSubagent===!0)return!i;' +
  'return!i||!n||i.canonicalSelector.toLowerCase()!==n.canonicalSelector.toLowerCase()}';

// Marker comment injected at the patch site, so we can tell "already patched"
// apart from "upstream code drifted" cheaply.
const MARKER = "/* ccr-subagent-routing-patch */";

function patchOnce() {
  if (globalThis.__ccrSubagentPatchApplied) return;
  globalThis.__ccrSubagentPatchApplied = true;

  let src, mode;
  try {
    src = fs.readFileSync(SERVER_JS, "utf8");
    mode = fs.statSync(SERVER_JS).mode;
  } catch (err) {
    console.error(
      "[patch-subagent-routing] cannot read server.js:",
      err.message,
    );
    return;
  }

  if (src.includes(OLD_ZPE)) {
    const patched = src.replace(OLD_ZPE, MARKER + NEW_ZPE);
    if (patched === src) {
      console.error("[patch-subagent-routing] replace produced no change");
      return;
    }
    try {
      // Every node process ccr starts runs this same script (loaded via
      // NODE_OPTIONS), so writes race across processes; a per-PID tmp name
      // + rename keeps this atomic instead of letting a concurrently
      // starting process's require(server.js) observe a truncated file
      // mid-write. Same hazard and fix as export-model-routing.cjs.
      const tmp = `${SERVER_JS}.${process.pid}.tmp`;
      fs.writeFileSync(tmp, patched, { mode });
      fs.renameSync(tmp, SERVER_JS);
    } catch (err) {
      console.error(
        "[patch-subagent-routing] failed to write patched server.js:",
        err.message,
      );
      return;
    }
    console.error(
      "[patch-subagent-routing] applied ZPe fix to",
      SERVER_JS,
    );
  } else if (src.includes(NEW_ZPE)) {
    console.error(
      "[patch-subagent-routing] already patched, skipping",
    );
  } else {
    // Upstream code drifted (e.g. newer ccr version) — do NOT blindly patch.
    // This is a real signal for whoever upgrades ccr: re-check the ZPe logic.
    console.error(
      "[patch-subagent-routing] WARNING: ZPe not found in expected form — " +
        "ccr may have been upgraded; verify the subagent routing fix still applies.",
    );
  }
}

patchOnce();
