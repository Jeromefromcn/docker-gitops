"use strict";
// Outgoing tool-schema sanitiser for the ccr gateway.
//
// DeepSeek's request validator rejects JSON-Schema `pattern` values that use
// the `\0` escape, and it rejects them by refusing the whole request:
//
//   400 Invalid schema for function 'Artifact': {"type":"string",
//   "minLength":1,"maxLength":1024,"pattern":"^[^\\0]*$"} is not valid
//   under any of the schemas listed in the 'anyOf' keyword
//
// `\0` is a perfectly legal regex escape for NUL, but their validator will
// not take it — while `\u0000`, which means exactly the same thing, it will.
// Claude Code's `Artifact` tool ships that pattern on `file_paths.items` in
// its richer variant, and that variant is frozen into a session's prompt
// snapshot when the session is created. The result is a session that cannot
// talk to DeepSeek at all, while a freshly created one works: the old session
// keeps re-sending the old tool schema, the new one never had the field.
// See docs/incidents/2026-09-25-ccr-deepseek-artifact-schema-400.md.
//
// Where it hooks: the gateway does NOT send provider requests through
// globalThis.fetch — the only such call it makes is its own
// /__ccr/raw-trace-sync upload. Provider requests go out through undici's
// Dispatcher.dispatch(), with `opts.body` an AsyncGenerator of chunks. So
// dispatch is the primary hook; fetch is wrapped as defence in depth, the
// same shape sse-coalesce.cjs uses for the response side.
//
// What it will and will not touch. This middleware sits in front of *all*
// provider traffic, so it only ever rewrites `pattern` values that hang off a
// tool definition — `tools[].input_schema` (Anthropic shape) and
// `tools[].function.parameters` (OpenAI shape). A `\0` sitting in message
// text, a system prompt, or a tool description is left exactly as it is:
// rewriting those would silently alter conversation content. The body is
// buffered (bounded — see CCR_SCHEMA_SANITIZE_MAX_BYTES) so it can be parsed
// as a whole; it is re-serialised only when something actually changed.
//
// Any error, an unparseable body, an unknown chunk type, or a body over the
// cap all fall back to forwarding the original bytes untouched. The rewrite
// also drops `content-length` and `content-encoding` from the outgoing
// headers, since the body gets longer (3 -> 7 bytes per escaped `\0`) and any
// length the caller computed would be stale — the same reasoning
// sse-coalesce.cjs applies to the response side.

// A pattern holding `\0` reaches us as wire JSON, where the backslash is
// itself escaped: the bytes on the wire are `\\0`.
const WIRE_MARKER = "\\\\0";
// Once parsed, the escape is a single backslash followed by "0". The
// negative lookahead leaves octal escapes such as `\012` alone.
const DECODED_ESCAPE = /\\0(?![0-9])/g;
const DECODED_REPLACEMENT = "\\u0000";

const BINARY_CONTENT_TYPE =
  /multipart\/|application\/octet-stream|image\/|audio\/|video\//i;

const DEFAULT_MAX_BYTES = 64 * 1024 * 1024;

const enabled = process.env.CCR_SCHEMA_SANITIZE !== "0";
const debug = process.env.CCR_SCHEMA_SANITIZE_DEBUG === "1";

function maxBytes() {
  const v = parseInt(process.env.CCR_SCHEMA_SANITIZE_MAX_BYTES, 10);
  return Number.isFinite(v) && v > 0 ? v : DEFAULT_MAX_BYTES;
}

let rewrites = 0;

function note(msg) {
  console.error("[sanitize-tool-schema] " + msg);
}

// Rewrite every `pattern` inside a JSON Schema subtree, in place.
// Returns how many values changed.
function fixPatterns(node) {
  let changed = 0;
  const walk = (n) => {
    if (!n || typeof n !== "object") return;
    if (Array.isArray(n)) {
      for (const item of n) walk(item);
      return;
    }
    if (typeof n.pattern === "string" && n.pattern.indexOf("\\0") !== -1) {
      const fixed = n.pattern.replace(DECODED_ESCAPE, DECODED_REPLACEMENT);
      if (fixed !== n.pattern) {
        n.pattern = fixed;
        changed += 1;
      }
    }
    for (const key of Object.keys(n)) walk(n[key]);
  };
  walk(node);
  return changed;
}

// Rewrite a parsed request document: tool definitions only, nothing else.
function fixRequestDocument(doc) {
  if (!doc || typeof doc !== "object") return 0;
  const tools = Array.isArray(doc.tools) ? doc.tools : [];
  let changed = 0;
  for (const tool of tools) {
    if (!tool || typeof tool !== "object") continue;
    changed += fixPatterns(tool.input_schema); // Anthropic shape
    if (tool.function && typeof tool.function === "object") {
      changed += fixPatterns(tool.function.parameters); // OpenAI shape
    }
  }
  return changed;
}

// Returns the rewritten body text, or null when nothing needed changing.
function rewriteJsonText(text) {
  if (typeof text !== "string" || text.indexOf(WIRE_MARKER) === -1) return null;
  let doc;
  try {
    doc = JSON.parse(text);
  } catch {
    return null; // not JSON, or not JSON we can round-trip: leave it alone
  }
  const changed = fixRequestDocument(doc);
  if (changed === 0) return null;
  rewrites += changed;
  note("rewrote " + changed + " pattern value(s) (total " + rewrites + ")");
  return JSON.stringify(doc);
}

function toBuffer(chunk) {
  if (typeof chunk === "string") return Buffer.from(chunk, "utf8");
  if (chunk instanceof Uint8Array) return Buffer.from(chunk);
  return null;
}

// Buffered rewrite of an async-iterable body: collect, parse, fix, re-emit.
// Passes the body through chunk-by-chunk, untouched, as soon as anything
// unexpected turns up (unknown chunk type, or more than the size cap).
async function* rewriteStream(iterable, label) {
  const collected = [];
  let total = 0;
  let passthrough = false;

  for await (const chunk of iterable) {
    if (passthrough) {
      yield chunk;
      continue;
    }
    const buf = toBuffer(chunk);
    if (buf === null) {
      passthrough = true;
      note("unknown chunk type, forwarding body untouched (" + label + ")");
      for (const b of collected) yield b;
      collected.length = 0;
      yield chunk;
      continue;
    }
    collected.push(buf);
    total += buf.length;
    if (total > maxBytes()) {
      passthrough = true;
      note("body over " + maxBytes() + " bytes, forwarding untouched (" + label + ")");
      for (const b of collected) yield b;
      collected.length = 0;
    }
  }

  if (passthrough) return;

  const original = Buffer.concat(collected);
  const fixed = rewriteJsonText(original.toString("utf8"));
  if (debug) {
    note("stream done (" + label + "), " + original.length + " bytes, " +
      (fixed === null ? "unchanged" : "rewritten"));
  }
  yield fixed === null ? original : Buffer.from(fixed, "utf8");
}

function contentTypeOf(headers) {
  try {
    if (!headers) return "";
    if (typeof headers.get === "function") return String(headers.get("content-type") || "");
    if (Array.isArray(headers)) {
      for (let i = 0; i < headers.length; i += 2) {
        if (String(headers[i]).toLowerCase() === "content-type") return String(headers[i + 1] || "");
      }
      return "";
    }
    for (const k of Object.keys(headers)) {
      if (k.toLowerCase() === "content-type") return String(headers[k] || "");
    }
  } catch {
    /* treat as unknown */
  }
  return "";
}

function headerNames(headers) {
  try {
    if (!headers) return "";
    if (Array.isArray(headers)) {
      const out = [];
      for (let i = 0; i < headers.length; i += 2) out.push(String(headers[i]));
      return out.join(",");
    }
    if (typeof headers.forEach === "function") {
      const out = [];
      headers.forEach((_v, k) => out.push(String(k)));
      return out.join(",");
    }
    return Object.keys(headers).join(",");
  } catch {
    return "?";
  }
}

// The rewrite changes the body length, so any content-length the caller had
// computed is stale; content-encoding would be too, since the bytes changed.
function stripStaleHeaders(headers) {
  const drop = new Set(["content-length", "content-encoding"]);
  try {
    if (!headers) return headers;
    if (Array.isArray(headers)) {
      const kept = [];
      for (let i = 0; i < headers.length; i += 2) {
        if (drop.has(String(headers[i]).toLowerCase())) continue;
        kept.push(headers[i], headers[i + 1]);
      }
      return kept;
    }
    if (typeof headers.delete === "function") {
      for (const name of drop) headers.delete(name);
      return headers;
    }
    for (const k of Object.keys(headers)) {
      if (drop.has(k.toLowerCase())) delete headers[k];
    }
    return headers;
  } catch {
    return headers;
  }
}

// Rewrite a body of any shape we understand. Returns the replacement, or the
// original when nothing needed changing (callers compare by identity).
function rewriteBody(body, headers, label) {
  try {
    if (typeof body === "string") return rewriteJsonText(body) ?? body;
    if (body instanceof Uint8Array) {
      const fixed = rewriteJsonText(Buffer.from(body).toString("utf8"));
      return fixed === null ? body : Buffer.from(fixed, "utf8");
    }
    const iterable =
      body &&
      (typeof body[Symbol.asyncIterator] === "function" || typeof body[Symbol.iterator] === "function");
    if (iterable) {
      if (BINARY_CONTENT_TYPE.test(contentTypeOf(headers))) {
        if (debug) note("binary content-type, body left untouched (" + label + ")");
        return body;
      }
      return rewriteStream(body, label);
    }
    if (body !== undefined && body !== null && typeof body === "object" && debug) {
      note("body is a " + (body.constructor && body.constructor.name) + ", not inspected (" + label + ")");
    }
  } catch (e) {
    note("body rewrite failed, forwarding original: " + ((e && e.message) || e));
  }
  return body;
}

let installed = false;
function install() {
  if (installed) return { ok: true, already: true };
  installed = true;
  if (!enabled) {
    note("disabled (CCR_SCHEMA_SANITIZE=0)");
    return { ok: true, disabled: true };
  }

  const wrapFetchFn = (label, fetchFn) => {
    const realFetch = fetchFn;
    return function (input, init) {
      if (init && init.body !== undefined) {
        try {
          const body = rewriteBody(init.body, init.headers, label);
          if (body !== init.body) {
            init = Object.assign({}, init, { body, headers: stripStaleHeaders(init.headers) });
          }
        } catch {
          /* fall through with the original init */
        }
      }
      return realFetch(input, init);
    };
  };

  const wrapDispatch = (label, d) => {
    if (!d || typeof d.dispatch !== "function" || d.__schemaSanitize) return;
    const realDispatch = d.dispatch;
    d.dispatch = function (opts, handlers) {
      try {
        if (opts && opts.body !== undefined) {
          const body = rewriteBody(opts.body, opts.headers, label);
          if (body !== opts.body) {
            const patched = Object.assign({}, opts);
            patched.body = body;
            patched.headers = stripStaleHeaders(opts.headers);
            if (debug) {
              note("dispatch body replaced (" + label + "); headers were [" + headerNames(opts.headers) + "]");
            }
            return realDispatch.call(this, patched, handlers);
          }
        }
      } catch (e) {
        note("dispatch rewrite failed, forwarding original: " + ((e && e.message) || e));
      }
      return realDispatch.call(this, opts, handlers);
    };
    try {
      d.__schemaSanitize = true;
    } catch {
      /* non-writable marker is fine */
    }
    note("patched dispatcher " + label);
  };

  const patchUndici = (label, undici) => {
    if (!undici || undici.__schemaSanitizePatched) return;
    try {
      undici.__schemaSanitizePatched = true;
    } catch {
      /* ignore */
    }
    try {
      if (typeof undici.fetch === "function") {
        undici.fetch = wrapFetchFn(label + ".fetch", undici.fetch);
      }
    } catch {
      /* frozen exports */
    }
    // Mirror sse-coalesce: cover dispatchers created after we load, not just
    // the one that happens to be current now.
    try {
      if (typeof undici.getGlobalDispatcher === "function") {
        const realGet = undici.getGlobalDispatcher;
        undici.getGlobalDispatcher = function () {
          const d = realGet.call(this);
          wrapDispatch(label + " global", d);
          return d;
        };
      }
    } catch {
      /* frozen exports */
    }
    try {
      if (typeof undici.setGlobalDispatcher === "function") {
        const realSet = undici.setGlobalDispatcher;
        undici.setGlobalDispatcher = function (d) {
          wrapDispatch(label + " set", d);
          return realSet.call(this, d);
        };
      }
    } catch {
      /* frozen exports */
    }
    try {
      wrapDispatch(label + " current", undici.getGlobalDispatcher());
    } catch {
      /* ignore */
    }
  };

  let patched = 0;
  try {
    const d = Object.getOwnPropertyDescriptor(globalThis, "fetch");
    if (d && (d.writable || d.set)) {
      globalThis.fetch = wrapFetchFn("globalThis.fetch", globalThis.fetch);
      patched += 1;
    }
  } catch (e) {
    note("global patch failed: " + ((e && e.message) || e));
  }

  const candidates = [
    process.env.CCR_UNDICI_MODULE,
    "/app/node_modules/@the-next-ai/ai-gateway/node_modules/undici",
    "/app/packages/core/node_modules/undici",
    "/app/node_modules/undici",
    "undici",
  ].filter(Boolean);
  for (const spec of candidates) {
    try {
      patchUndici("undici [" + spec + "]", require(spec));
    } catch {
      /* candidate not loadable; fine */
    }
  }
  return { ok: patched > 0, patched };
}

module.exports = {
  install,
  fixPatterns,
  fixRequestDocument,
  rewriteJsonText,
  rewriteBody,
  rewriteStream,
  stripStaleHeaders,
};

// Auto-install on load: the module is mounted into every node process in the
// container via NODE_OPTIONS --require, which merely loads the file.
install();
