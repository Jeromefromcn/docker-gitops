"use strict";
// SSE delta coalescing middleware for the ccr gateway.
//
// Some Anthropic-compatible providers (e.g. Zhipu bigmodel.cn) emit one SSE
// content_block_delta event per token. The VS Code extension's remote
// rendering pipeline cannot keep up with that event rate and output backs up
// for hours. The official Anthropic API batches multiple tokens per delta;
// this middleware restores that shape by merging consecutive same-type delta
// events on the same content block within a small time window (default 40ms).
//
// The gateway (@the-next-ai/ai-gateway) sends provider requests through
// undici's global dispatcher (Dispatcher.dispatch), so the middleware wraps
// dispatch() on every reachable undici copy, plus globalThis.fetch and
// undici.fetch as defense in depth. Only text/event-stream responses without
// content-encoding are transformed; everything else passes through untouched.

const fs = require("node:fs");

const MERGEABLE_DELTA_FIELDS = {
  text_delta: "text",
  thinking_delta: "thinking",
  input_json_delta: "partial_json",
};

const STATS_FILE =
  process.env.CCR_SSE_COALESCE_STATS ||
  "/data/.claude-code-router/sse-coalesce-stats.log";
const STATS_MAX_BYTES = 262144;

function windowMs() {
  const raw = process.env.CCR_SSE_COALESCE_MS;
  if (raw === "0") return 0;
  const v = parseInt(raw, 10);
  return Number.isFinite(v) && v > 0 ? v : 40;
}

// Keep-alive noise some providers send between deltas. Dropping them lets a
// token run keep merging across pings; Anthropic clients do not depend on them.
const dropPing = process.env.CCR_SSE_DROP_PINGS !== "0";

function isPing(parsed) {
  if (!parsed.data) return false;
  try {
    const o = JSON.parse(parsed.data);
    return !!(o && typeof o === "object" && o.type === "ping");
  } catch {
    return false;
  }
}

function parseRecord(raw) {
  let eventName;
  const dataLines = [];
  for (const line of raw.split(/\r?\n/)) {
    if (line.startsWith("event:")) {
      eventName = line.slice(6).trim();
    } else if (line.startsWith("data:")) {
      let v = line.slice(5);
      if (v.startsWith(" ")) v = v.slice(1);
      dataLines.push(v);
    }
  }
  return { eventName, data: dataLines.join("\n") };
}

// Core push-based coalescer: feed() text in, emit() receives complete SSE
// records (merged deltas or verbatim passthrough). end() flushes the tail.
function createCoalescer(winMs, emit) {
  let buf = "";
  let pending = null; // { obj, eventName, deltaType, field, acc, count }
  let timer = null;
  const stats = { inDeltas: 0, outDeltas: 0 };

  const flush = () => {
    if (!pending) return;
    if (timer) {
      clearTimeout(timer);
      timer = null;
    }
    const o = pending.obj;
    const delta = { type: pending.deltaType };
    delta[pending.field] = pending.acc;
    o.delta = delta;
    const lines = [];
    if (pending.eventName) lines.push("event: " + pending.eventName);
    lines.push("data: " + JSON.stringify(o));
    emit(lines.join("\n") + "\n\n");
    stats.outDeltas += 1;
    pending = null;
  };

  const armTimer = () => {
    if (timer || winMs <= 0) return;
    timer = setTimeout(() => {
      timer = null;
      flush();
    }, winMs);
    if (typeof timer.unref === "function") timer.unref();
  };

  const tryMerge = (parsed) => {
    if (!parsed.data) return false;
    let o;
    try {
      o = JSON.parse(parsed.data);
    } catch {
      return false;
    }
    if (
      !o || typeof o !== "object" || o.type !== "content_block_delta" ||
      !o.delta || typeof o.delta !== "object"
    ) {
      return false;
    }
    const field = MERGEABLE_DELTA_FIELDS[o.delta.type];
    if (!field || typeof o.delta[field] !== "string") return false;
    stats.inDeltas += 1;
    if (pending && pending.obj.index === o.index && pending.deltaType === o.delta.type) {
      pending.acc += o.delta[field];
      pending.count += 1;
      pending.obj = o; // keep freshest top-level extras (usage etc.)
      return true;
    }
    flush();
    pending = {
      obj: o,
      eventName: parsed.eventName,
      deltaType: o.delta.type,
      field,
      acc: o.delta[field],
      count: 1,
    };
    armTimer();
    return true;
  };

  const drain = (final) => {
    let m;
    while ((m = buf.match(/\r?\n\r?\n/)) !== null) {
      const raw = buf.slice(0, m.index);
      const sep = m[0];
      buf = buf.slice(m.index + sep.length);
      if (!raw) continue;
      const parsed = parseRecord(raw);
      if (dropPing && isPing(parsed)) continue; // drop keepalive, keep the run open
      if (tryMerge(parsed)) continue;
      flush(); // preserve ordering before non-mergeable events
      emit(raw + sep);
    }
    if (final) {
      if (buf.trim()) {
        const parsed = parseRecord(buf);
        if (dropPing && isPing(parsed)) {
          buf = ""; // trailing keepalive: drop
        } else if (!tryMerge(parsed)) {
          flush();
          emit(buf + "\n\n");
        }
        buf = "";
      }
      flush();
    }
  };

  return {
    feed(text) {
      buf += text;
      drain(false);
    },
    end(text) {
      if (text) buf += text;
      drain(true);
    },
    stats,
  };
}

// Adapter for fetch-style bodies (Response with ReadableStream).
function makeMergerStream(winMs, onEnd) {
  const decoder = new TextDecoder();
  const encoder = new TextEncoder();
  let coalescer;
  const ensure = () => {
    if (!coalescer) {
      coalescer = createCoalescer(winMs, (s) => {
        try {
          controller.enqueue(encoder.encode(s));
        } catch {
          /* cancelled */
        }
      });
    }
    return coalescer;
  };
  let controller = { enqueue: () => {} };
  return new TransformStream({
    start(c) {
      controller = c;
    },
    transform(chunk, c) {
      controller = c;
      ensure().feed(decoder.decode(chunk, { stream: true }));
    },
    flush(c) {
      controller = c;
      const co = ensure();
      co.end(decoder.decode());
      if (onEnd) {
        try {
          onEnd(co.stats.inDeltas, co.stats.outDeltas);
        } catch {
          /* ignore */
        }
      }
    },
  });
}

// Normalize provider request headers to an array and drop accept-encoding so
// providers reply uncompressed (identity). The coalescer can then inspect and
// re-chunk plain-text SSE. Raw undici dispatch does not add accept-encoding by
// itself, but the gateway does.
function normalizeHeaders(headers) {
  if (!headers) return ["accept-encoding", "identity"];
  const out = [];
  const push = (k, v) => {
    if (String(k).toLowerCase() === "accept-encoding") return;
    out.push(k, v);
  };
  if (Array.isArray(headers)) {
    for (let i = 0; i < headers.length; i += 2) push(headers[i], headers[i + 1]);
  } else if (typeof headers.forEach === "function") {
    headers.forEach((v, k) => push(k, v));
  } else {
    for (const k of Object.keys(headers)) push(k, headers[k]);
  }
  out.push("accept-encoding", "identity");
  return out;
}

// Adapter for undici Dispatcher.dispatch handlers.
function makeDispatchHandlerWrapper(winMs, onEnd, onBypass) {
  return function wrapHandlers(handlers) {
    const state = {
      bypass: true,
      coalescer: null,
      decoder: null,
      queue: [],
      paused: false,
      done: false,
    };

    const pump = () => {
      while (state.queue.length > 0 && !state.paused) {
        const b = state.queue.shift();
        if (handlers.onData(b) === false) {
          state.paused = true;
          break;
        }
      }
    };

    const wrapped = Object.assign({}, handlers);

    wrapped.onHeaders = function (statusCode, headers, resume) {
      let ct = "";
      let enc = "";
      let hdrs = headers;
      if (Array.isArray(headers)) {
        const kept = [];
        for (let i = 0; i < headers.length; i += 2) {
          const k = String(headers[i]).toLowerCase();
          const v = String(headers[i + 1]);
          if (k === "content-type") ct = v.toLowerCase();
          else if (k === "content-encoding") enc = v.toLowerCase();
          if (k !== "content-length") {
            // coalescing changes body length; drop content-length so the
            // stream stays valid (SSE is chunked in practice)
            kept.push(headers[i], headers[i + 1]);
          }
        }
        if (/text\/event-stream/.test(ct) && !enc) {
          hdrs = kept;
          state.bypass = false;
          state.decoder = new TextDecoder();
          state.coalescer = createCoalescer(winMs, (s) => {
            state.queue.push(Buffer.from(s, "utf8"));
            pump();
          });
        } else if (/text\/event-stream/.test(ct) && onBypass) {
          onBypass("bypass enc=" + (enc || "?") + " ct=" + ct);
        }
      }
      return handlers.onHeaders(statusCode, hdrs, () => {
        state.paused = false;
        pump();
        try {
          resume();
        } catch {
          /* ignore */
        }
      });
    };

    wrapped.onData = function (chunk) {
      if (state.bypass || !state.coalescer) return handlers.onData(chunk);
      state.coalescer.feed(state.decoder.decode(chunk, { stream: true }));
      return true; // we accepted the chunk into the coalescer/queue
    };

    wrapped.onComplete = function () {
      if (!state.bypass && state.coalescer) {
        state.done = true;
        state.coalescer.end(state.decoder.decode());
        pump();
        if (onEnd) {
          try {
            onEnd(state.coalescer.stats.inDeltas, state.coalescer.stats.outDeltas);
          } catch {
            /* ignore */
          }
        }
      }
      return handlers.onComplete();
    };

    return wrapped;
  };
}

let statsBytes = -1;
function appendStats(kind, inD, outD) {
  try {
    if (statsBytes < 0) {
      try {
        statsBytes = fs.statSync(STATS_FILE).size;
      } catch {
        statsBytes = 0;
      }
    }
    const line =
      new Date().toISOString() +
      " " +
      kind +
      " in=" +
      inD +
      " out=" +
      outD +
      "\n";
    if (statsBytes > STATS_MAX_BYTES) {
      fs.writeFileSync(STATS_FILE, line);
      statsBytes = Buffer.byteLength(line);
    } else {
      fs.appendFileSync(STATS_FILE, line);
      statsBytes += Buffer.byteLength(line);
    }
  } catch {
    /* ignore */
  }
}

let installed = false;
function install() {
  if (installed) return { ok: true, already: true };
  installed = true;
  const winMs = windowMs();
  if (winMs <= 0) {
    console.error("[sse-coalesce] disabled (CCR_SSE_COALESCE_MS=0)");
    return { ok: true, disabled: true };
  }

  let patched = 0;

  const wrapFetchFn = (label, fetchFn) => {
    const realFetch = fetchFn;
    const wrapped = function (input, init) {
      return Promise.resolve(realFetch(input, init)).then((res) => {
        let ct = "";
        try {
          ct = (res.headers && res.headers.get("content-type")) || "";
        } catch {
          /* ignore */
        }
        if (!res || !res.body || !/text\/event-stream/i.test(ct)) return res;
        let stream;
        try {
          stream = res.body.pipeThrough(
            makeMergerStream(winMs, (a, b) => appendStats("merge", a, b))
          );
        } catch (e) {
          console.error("[sse-coalesce] pipeThrough failed:", e && e.message);
          return res;
        }
        try {
          const headers = new Headers(res.headers);
          headers.delete("content-length");
          return new Response(stream, {
            status: res.status,
            statusText: res.statusText,
            headers,
          });
        } catch (e) {
          console.error("[sse-coalesce] Response rebuild failed:", e && e.message);
          return res;
        }
      });
    };
    console.error("[sse-coalesce] patched " + label);
    return wrapped;
  };

  const wrapDispatcher = (label, d) => {
    if (!d || typeof d.dispatch !== "function" || d.__sseCoalesce) return;
    const realDispatch = d.dispatch;
    const wrapH = makeDispatchHandlerWrapper(
      winMs,
      (a, b) => appendStats("merge", a, b),
      (msg) => appendStats("info", msg, 0)
    );
    d.dispatch = function (opts, handlers) {
      let o = opts;
      try {
        o = Object.assign({}, opts);
        o.headers = normalizeHeaders(opts.headers);
      } catch {
        /* keep original opts */
      }
      return realDispatch.call(this, o, wrapH(handlers));
    };
    try {
      d.__sseCoalesce = true;
    } catch {
      /* non-writable marker is fine */
    }
    patched += 1;
    console.error("[sse-coalesce] patched dispatcher " + label);
  };

  const patchUndici = (label, undici) => {
    if (!undici || undici.__sseCoalescePatched) return;
    try {
      undici.__sseCoalescePatched = true;
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
    try {
      if (typeof undici.getGlobalDispatcher === "function") {
        const realGet = undici.getGlobalDispatcher;
        undici.getGlobalDispatcher = function () {
          const d = realGet.call(this);
          wrapDispatcher(label + " global", d);
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
          wrapDispatcher(label + " set", d);
          return realSet.call(this, d);
        };
      }
    } catch {
      /* frozen exports */
    }
    try {
      wrapDispatcher(label + " current", undici.getGlobalDispatcher());
    } catch {
      /* ignore */
    }
  };

  try {
    const d = Object.getOwnPropertyDescriptor(globalThis, "fetch");
    if (d && (d.writable || d.set)) {
      globalThis.fetch = wrapFetchFn("globalThis.fetch", globalThis.fetch);
      patched += 1;
    }
  } catch (e) {
    console.error("[sse-coalesce] global patch failed:", e && e.message);
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
  makeMergerStream,
  createCoalescer,
  makeDispatchHandlerWrapper,
  parseRecord,
};

// Auto-install on load. The module is loaded two ways: explicitly by
// gateway-proxy-preload.cjs (which calls install()), and via NODE_OPTIONS
// --require, which merely loads the file without invoking anything. install()
// is idempotent, so calling it here covers both paths exactly once.
try {
  install();
} catch (e) {
  console.error("[sse-coalesce] auto-install failed:", (e && e.stack) || e);
}
