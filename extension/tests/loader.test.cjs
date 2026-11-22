const assert = require("node:assert/strict");
const test = require("node:test");
const vm = require("node:vm");
const { loadBackground, backgroundSource } = require("./harness.cjs");
const { parseBundle } = require("../bundle.js");

const ADDRESS = "https://box.example.com/api";
const bundle = (parts) => JSON.stringify({ version: 1, parts });
const plain = (value) => JSON.parse(JSON.stringify(value));

// A box whose /bundle.json answers `text`, or `status` when given.
const box = (text, status = 200) => () => ({ status, body: text });

// Background scripts share one scope: a name declared at the top of two of
// them stops the later one from loading, and nothing says so.
test("the background scripts load together", () => {
  assert.doesNotThrow(() => new vm.Script(backgroundSource()));
});

test("parseBundle accepts version 1 and rejects other shapes", () => {
  const good = { a: { background: "x", content: [{ matches: ["https://*"], js: "y" }], pages: { p: { html: "", js: "" } } } };
  assert.deepEqual(Object.keys(parseBundle(bundle(good)).parts), ["a"]);
  assert.doesNotThrow(() => parseBundle(bundle({})));
  for (const [text, reason] of [
    ["{", /JSON/],
    [JSON.stringify({ version: 2, parts: {} }), /version 1/],
    [JSON.stringify({ version: 1 }), /parts/],
    [bundle({ a: { background: 1 } }), /part a: background/],
    [bundle({ a: { content: [{ js: "x" }] } }), /part a: content needs matches/],
    [bundle({ a: { pages: { p: { js: 2 } } } }), /page p: js/],
  ]) {
    assert.throws(() => parseBundle(text), reason, text);
  }
});

test("a part that throws while starting is recorded and the others run", async () => {
  const text = bundle({
    ok: { background: "globalThis.okRan = denbox.part;" },
    sync: { background: "throw new Error('broken');" },
    later: { background: "await null; throw new Error('later');" },
    syntax: { background: "this is not code" },
  });
  const { store, context, ready, chrome } = loadBackground({ storage: { "denbox:address": ADDRESS, "denbox:bundle": text }, respond: box(text) });
  await ready;
  assert.equal(context.okRan, "ok");
  const { parts } = plain(store["denbox:started"]);
  assert.deepEqual(parts.ok, { state: "running" });
  assert.deepEqual(parts.sync, { state: "failed", error: "broken" });
  assert.deepEqual(parts.later, { state: "failed", error: "later" });
  assert.equal(parts.syntax.state, "failed");
  assert.equal(chrome.reloads, 0, "the same bundle on the box causes no reload");
});

test("a changed bundle is stored and applied by a reload", async () => {
  const old = bundle({ a: {} });
  const next = bundle({ a: {}, b: {} });
  const { store, requests, ready, chrome } = loadBackground({ storage: { "denbox:address": `${ADDRESS}/`, "denbox:bundle": old }, respond: box(next) });
  await ready;
  assert.equal(store["denbox:bundle"], next);
  assert.equal(chrome.reloads, 1);
  assert.equal(requests[0].url, `${ADDRESS}/bundle.json`);
  assert.equal(requests[0].init.headers["x-denbox-api"], "1");
});

test("a bundle that does not parse leaves the previous one running", async () => {
  const old = bundle({ a: {} });
  for (const broken of ["{ nope", JSON.stringify({ version: 2, parts: {} })]) {
    const { store, ready, chrome } = loadBackground({ storage: { "denbox:address": ADDRESS, "denbox:bundle": old }, respond: box(broken) });
    await ready;
    assert.equal(store["denbox:bundle"], old);
    assert.equal(chrome.reloads, 0);
    assert.ok(store["denbox:status"].error);
  }
});

test("an unreachable box keeps the running bundle", async () => {
  const old = bundle({ a: {} });
  const { store, ready, chrome } = loadBackground({ storage: { "denbox:address": ADDRESS, "denbox:bundle": old }, respond: box("", 502) });
  await ready;
  assert.equal(store["denbox:bundle"], old);
  assert.equal(store["denbox:status"].error, "HTTP 502");
  assert.equal(chrome.reloads, 0);
});

test("a box without parts (404) clears the running bundle", async () => {
  const { store, ready, chrome } = loadBackground({ storage: { "denbox:address": ADDRESS, "denbox:bundle": bundle({ a: {} }) }, respond: box("", 404) });
  await ready;
  assert.equal(store["denbox:bundle"], undefined);
  assert.equal(chrome.reloads, 1);
});

test("a hold keeps the extension from reloading until it is released", async () => {
  const old = bundle({ rec: { background: "globalThis.release = denbox.hold('recording');" } });
  let served = old;
  const { store, ready, chrome, context } = loadBackground({
    storage: { "denbox:address": ADDRESS, "denbox:bundle": old },
    respond: () => ({ body: served }),
  });
  await ready;
  served = bundle({ rec: {} });
  await vm.runInContext("check()", context);
  assert.equal(chrome.reloads, 0);
  assert.equal(store["denbox:bundle"], old);
  assert.match(store["denbox:status"].error, /recording/);
  context.release();
  await vm.runInContext("check()", context);
  assert.equal(chrome.reloads, 1);
});

test("saving an address in the options checks the box at once", async () => {
  const next = bundle({ a: {} });
  const { store, ready, chrome } = loadBackground({ respond: box(next) });
  await ready;
  await chrome.storage.local.set({ "denbox:address": ADDRESS, "denbox:check": 1 });
  assert.equal(store["denbox:bundle"], next);
  assert.equal(chrome.reloads, 1);
});

test("content scripts run in tabs whose address matches", async () => {
  const text = bundle({ a: { content: [{ matches: ["https://*.example.com/*"], js: "1" }] } });
  const { ready, chrome, injected } = loadBackground({ storage: { "denbox:address": ADDRESS, "denbox:bundle": text }, respond: box(text) });
  await ready;
  chrome.tabs.onUpdated.fire(1, { status: "complete" }, { url: "https://docs.example.com/x" });
  chrome.tabs.onUpdated.fire(2, { status: "complete" }, { url: "https://example.org/" });
  chrome.tabs.onUpdated.fire(3, { status: "loading" }, { url: "https://docs.example.com/x" });
  assert.deepEqual(plain(injected), [{ tabId: 1, code: "1" }]);
});

test("denbox.api sends the guard header and throws the server's error", async () => {
  const text = bundle({ a: { background: "globalThis.api = denbox.api;" } });
  const { ready, context, requests } = loadBackground({
    storage: { "denbox:address": ADDRESS, "denbox:bundle": text },
    respond: (url) => (url.endsWith("/bundle.json") ? { body: text } : { status: 400, body: '{"error":"unknown service"}' }),
  });
  await ready;
  await assert.rejects(context.api("/services/restart", { name: "x" }), /unknown service/);
  const call = requests.at(-1);
  assert.equal(call.url, `${ADDRESS}/services/restart`);
  assert.equal(call.init.method, "POST");
  assert.equal(call.init.headers["x-denbox-api"], "1");
  assert.equal(call.init.body, '{"name":"x"}');
});
