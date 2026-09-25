"use strict";
// Unit tests for sanitize-tool-schema.cjs — no dependencies, no network.
//
//   node vps_oracle/compose/ccr/sanitize-tool-schema.test.cjs
//
// Two properties matter most here. First, scope: this middleware sits in
// front of every provider request, so it must rewrite `pattern` values on
// tool definitions and *nothing else* — a `\0` in message text or in a tool
// description must survive untouched. Second, reassembly: the gateway hands
// it an AsyncGenerator of chunks, and the result must be identical whatever
// the chunk boundaries are, including a multi-byte UTF-8 character split
// across two chunks.

const assert = require("node:assert");

// Capture stdout first: a --require script that prints to stdout corrupts
// ccr's nginx token generation (see the compat-lessons doc).
let stdout = "";
const realStdoutWrite = process.stdout.write.bind(process.stdout);
process.stdout.write = (c, ...a) => {
  stdout += String(c);
  return true;
};

// Stub fetch before requiring, so the module's auto-install wraps the stub
// rather than the real network stack.
let lastInit = null;
globalThis.fetch = (input, init) => {
  lastInit = init;
  return Promise.resolve({ ok: true });
};

const M = require("./sanitize-tool-schema.cjs");
process.stdout.write = realStdoutWrite;

const drain = async (iterable) => {
  const out = [];
  for await (const chunk of iterable) out.push(Buffer.from(chunk));
  return Buffer.concat(out).toString("utf8");
};

// A body shaped like a real one, and deliberately carrying non-ASCII text so
// a UTF-8 character lands on odd boundaries.
function syntheticBody() {
  const filler = "測試中文字元 — em-dash and 日本語、한국어。".repeat(400);
  return JSON.stringify({
    model: "deepseek-flash",
    system: "a prompt mentioning a literal \\0 which must survive",
    messages: [{ role: "user", content: [{ type: "text", text: filler + " code: char c = '\\0';" }] }],
    tools: [
      {
        name: "Other",
        description: "a description containing \\0 which must survive",
        input_schema: {
          type: "object",
          properties: {
            collection: { type: "string", pattern: "^(?!\\.\\.?(?:\\/|$))[A-Za-z0-9_\\-.~:@+]{1,200}$" },
            contract: { type: "string", pattern: "^(0|[1-9]\\d{0,3})\\.(0|[1-9]\\d{0,5})$" },
          },
        },
      },
      {
        name: "Artifact",
        input_schema: {
          type: "object",
          properties: {
            file_paths: {
              description: "the offending field",
              type: "array",
              minItems: 1,
              maxItems: 25,
              items: { type: "string", minLength: 1, maxLength: 1024, pattern: "^[^\\0]*$" },
            },
            octal_looking: { type: "string", pattern: "^[^\\012]*$" },
          },
        },
      },
    ],
  });
}

(async () => {
  // 1. the escape is rewritten on a tool pattern, and nowhere else
  const one = JSON.stringify({
    tools: [{ name: "T", input_schema: { properties: { p: { pattern: "^[^\\0]*$" } } } }],
  });
  assert.strictEqual(
    M.rewriteJsonText(one),
    JSON.stringify({ tools: [{ name: "T", input_schema: { properties: { p: { pattern: "^[^\\u0000]*$" } } } }] })
  );
  console.log("✓ 1  tool pattern 的 \\0 被改寫成 \\u0000（語義相同）");

  // 2. octal escapes and other backslash escapes are left alone
  const others = JSON.stringify({
    tools: [{ input_schema: { properties: {
      a: { pattern: "^[^\\012]*$" },
      b: { pattern: "^\\d+\\.\\d+$" },
    } } }],
  });
  assert.strictEqual(M.rewriteJsonText(others), null);
  console.log("✓ 2  \\012（八進位）同 \\d \\. 等轉義原封不動");

  // 3. scope: \\0 outside a tool pattern must survive, even inside a tool's
  //    own description
  const prose = JSON.stringify({
    system: "literal \\0 here",
    messages: [{ role: "user", content: "code: '\\0'" }],
    tools: [{ name: "T", description: "describes \\0", input_schema: { properties: { p: { description: "\\0" } } } }],
  });
  assert.strictEqual(M.rewriteJsonText(prose), null, "prose must not be rewritten");
  console.log("✓ 3  對話內容、system prompt、tool description 裡的 \\0 一律唔碰");

  // 4. OpenAI-shaped tool definitions are handled too
  const openai = JSON.stringify({
    tools: [{ type: "function", function: { name: "T", parameters: { properties: { p: { pattern: "^[^\\0]*$" } } } } }],
  });
  const fixedOpenai = M.rewriteJsonText(openai);
  assert.ok(fixedOpenai && JSON.parse(fixedOpenai).tools[0].function.parameters.properties.p.pattern === "^[^\\u0000]*$");
  console.log("✓ 4  OpenAI 形狀（tools[].function.parameters）一樣處理");

  // 5. streamed reassembly equals whole-body rewrite, for every chunk size
  const body = syntheticBody();
  const expected = M.rewriteJsonText(body);
  assert.ok(expected !== null, "synthetic body must contain a rewrite target");
  assert.ok(!expected.includes("must survive") === false, "sanity: prose retained");
  assert.ok(expected.includes("a prompt mentioning a literal \\\\0"), "system prompt text preserved verbatim");
  assert.ok(expected.includes("code: char c = '\\\\0';"), "message text preserved verbatim");
  const bytes = Buffer.from(body, "utf8");
  for (const size of [1, 2, 3, 5, 8, 64, 4096, 65536]) {
    const chunks = [];
    for (let i = 0; i < bytes.length; i += size) chunks.push(bytes.subarray(i, i + size));
    const got = await drain(M.rewriteStream(chunks, "test"));
    assert.strictEqual(got, expected, `chunk size ${size} must reassemble to the whole-body rewrite`);
  }
  console.log("✓ 5  串流重組：1 byte ~ 64KB 切塊結果全部一致，且 CJK 內容零損傷");

  // 6. binary content types are never touched
  const stream = { async *[Symbol.asyncIterator]() { yield Buffer.from("\\\\0"); } };
  assert.strictEqual(M.rewriteBody(stream, { "content-type": "image/png" }, "test"), stream);
  assert.strictEqual(M.rewriteBody(stream, { "content-type": "multipart/form-data; boundary=x" }, "test"), stream);
  console.log("✓ 6  binary content-type 完全唔碰");

  // 7. over the size cap: forwarded untouched rather than buffered
  process.env.CCR_SCHEMA_SANITIZE_MAX_BYTES = "1024";
  const big = await drain(M.rewriteStream([Buffer.from(body, "utf8")], "test"));
  assert.strictEqual(big, body, "over-cap bodies must be forwarded verbatim");
  delete process.env.CCR_SCHEMA_SANITIZE_MAX_BYTES;
  console.log("✓ 7  超出 size cap 的 body 原樣轉發（唔會無上限緩衝）");

  // 8. non-UTF-8 bytes and unknown chunk types do not throw, and an unknown
  //    chunk is passed through as the same object, in its original position
  await drain(M.rewriteStream([Buffer.from([0xff, 0xfe, 0x5c, 0x5c, 0x30]), "tail"], "test"));
  const weird = { toString: () => "nope" };
  const passthrough = [];
  for await (const c of M.rewriteStream([weird, Buffer.from("{}")], "test")) passthrough.push(c);
  assert.strictEqual(passthrough[0], weird, "unknown chunk must pass through unchanged");
  assert.strictEqual(passthrough.length, 2);
  console.log("✓ 8  非 UTF-8 位元組、未知 chunk 型別唔會拋錯，且原樣保留、次序不變");

  // 9. the fetch wrapper rewrites a dirty body and leaves a clean one alone
  const dirty = '{"tools":[{"input_schema":{"properties":{"p":{"pattern":"^[^\\\\0]*$"}}}}]}';
  const clean = JSON.stringify({ messages: [{ role: "user", content: "hi" }] });
  await globalThis.fetch("http://example.test/v1/messages", { body: dirty });
  assert.strictEqual(lastInit.body, '{"tools":[{"input_schema":{"properties":{"p":{"pattern":"^[^\\\\u0000]*$"}}}}]}');
  const untouched = { body: clean };
  await globalThis.fetch("http://example.test/v1/messages", untouched);
  assert.strictEqual(lastInit, untouched, "a request that needs no rewrite must be forwarded as the same object");
  console.log("✓ 9  fetch wrapper：要改嘅改、唔使改嘅原物件通過");

  // 10. stdout stayed clean
  assert.strictEqual(stdout, "", "module wrote to stdout: " + JSON.stringify(stdout));
  console.log("✓ 10 stdout 乾淨（--require 腳本的硬性要求）");

  console.log("\nAll tests passed.");
})().catch((e) => {
  process.stdout.write = realStdoutWrite;
  console.error("FAIL:", (e && e.message) || e);
  process.exit(1);
});
