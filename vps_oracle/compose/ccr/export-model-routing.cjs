"use strict";
// Exports a *safe* projection of ccr's claude-code profiles (just the model
// routing strings: model/opusModel/sonnetModel/haikuModel) to a plain JSON
// file outside the sensitive ccr-data volume, so other containers (switchboard)
// can read per-group model-tier config without ever touching config.sqlite —
// that file also holds every provider's raw API key and the admin panel
// token, and its directory is 700 root:root by design. Nothing containing a
// key ever leaves this process.
//
// Why this exists: Claude Code's opus/sonnet/haiku tier switching only works
// if ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL are present in the CLI's own
// environment *before* it starts — ccr's gateway does not infer tier from the
// literal "model" string in an incoming request. See
// docs/misc/2026-08-20-ccr-third-party-model-compat-lessons.md.
//
// Regenerates on every config.sqlite/-wal/-shm change (fs.watch, debounced)
// plus a 30s safety-net poll in case an inotify event is ever missed. Runs in
// every node process ccr starts (loaded via NODE_OPTIONS --require, same
// mechanism as sse-coalesce.cjs), so it's idempotent and process-local.

const fs = require("node:fs");
const path = require("node:path");

const CONFIG_DB = "/data/.claude-code-router/config.sqlite";
const OUT_DIR = "/model-routing";
const OUT_FILE = path.join(OUT_DIR, "routing.json");
const DEBOUNCE_MS = 500;
const SAFETY_POLL_MS = 30000;

function readClaudeCodeProfiles() {
  const Database = require("/app/node_modules/better-sqlite3");
  const db = new Database(CONFIG_DB, { readonly: true, fileMustExist: true });
  try {
    const row = db
      .prepare("SELECT value_json FROM app_config WHERE key = 'default'")
      .get();
    if (!row) return {};
    const cfg = JSON.parse(row.value_json);
    const profiles = cfg?.profile?.profiles ?? [];
    const out = {};
    for (const p of profiles) {
      if (p.agent !== "claude-code" || !p.id) continue;
      out[p.id] = {
        model: p.model || "",
        opusModel: p.opusModel || "",
        sonnetModel: p.sonnetModel || "",
        haikuModel: p.haikuModel || "",
      };
    }
    return out;
  } finally {
    db.close();
  }
}

function writeRoutingFile() {
  let data;
  try {
    data = readClaudeCodeProfiles();
  } catch (err) {
    console.error(
      "[export-model-routing] failed to read config.sqlite:",
      err.message,
    );
    return;
  }
  try {
    fs.mkdirSync(OUT_DIR, { recursive: true, mode: 0o755 });
    // Every node process ccr starts runs this same script (loaded via
    // NODE_OPTIONS), so writes race across processes; a per-PID tmp name
    // keeps each writer's rename() atomic and independent instead of
    // occasionally renaming a sibling process's half-written tmp file out
    // from under it.
    const tmp = `${OUT_FILE}.${process.pid}.tmp`;
    fs.writeFileSync(tmp, `${JSON.stringify(data, null, 2)}\n`, {
      mode: 0o644,
    });
    fs.renameSync(tmp, OUT_FILE);
    fs.chmodSync(OUT_FILE, 0o644);
    fs.chmodSync(OUT_DIR, 0o755);
    // stderr only, never stdout: ccr's own entrypoint captures a node
    // subprocess's stdout verbatim to embed the admin-panel token into its
    // generated nginx config — any stdout noise from a --require'd script
    // (including this one) lands inline in that config and breaks nginx.
    // Verified by reproducing the exact corruption with console.log here;
    // sse-coalesce.cjs already gets this right (console.error throughout).
    console.error(
      `[export-model-routing] wrote ${OUT_FILE} (${Object.keys(data).length} profiles)`,
    );
  } catch (err) {
    console.error(
      "[export-model-routing] failed to write routing.json:",
      err.message,
    );
  }
}

let pendingWrite = null;
function scheduleWrite() {
  if (pendingWrite) clearTimeout(pendingWrite);
  pendingWrite = setTimeout(() => {
    pendingWrite = null;
    writeRoutingFile();
  }, DEBOUNCE_MS);
  pendingWrite.unref();
}

function install() {
  if (globalThis.__ccrModelRoutingExportInstalled) return;
  globalThis.__ccrModelRoutingExportInstalled = true;

  writeRoutingFile();

  const dir = path.dirname(CONFIG_DB);
  const base = path.basename(CONFIG_DB);
  try {
    // Watch only the exact main db filename, NOT "-wal"/"-shm": config.sqlite
    // runs in WAL mode, and merely *opening a readonly connection* creates
    // (or touches) config.sqlite-wal/-shm on disk with no real config change
    // — watching those too made every export read its own side effect as a
    // fresh "config changed" event, an infinite self-triggering loop (this
    // was verified against a snapshot of the volume before landing this
    // fix). A real save, by contrast, does update the main file's mtime
    // (checkpointed on connection close), so this alone still catches every
    // actual change; the 30s safety poll below covers anything unusual
    // (e.g. an app write pattern that defers checkpointing).
    const watcher = fs.watch(dir, { persistent: false }, (_event, filename) => {
      if (filename === base) scheduleWrite();
    });
    watcher.unref?.();
  } catch (err) {
    console.error("[export-model-routing] fs.watch unavailable:", err.message);
  }
  setInterval(writeRoutingFile, SAFETY_POLL_MS).unref();

  console.error(
    `[export-model-routing] watching ${dir} for ${base} changes (+${SAFETY_POLL_MS / 1000}s safety poll)`,
  );
}

install();
