const assert = require("node:assert/strict");
const test = require("node:test");
const vm = require("node:vm");
const { loadBackground, backgroundSource } = require("./harness.cjs");
const { parseBundle, sourceError } = require("../bundle.js");

const ADDRESS = "https://box.example.com/api";
const A = "https://git.example.com/a/bundle.json";
const B = "https://git.example.org/b/bundle.json";
const bundle = (parts) => JSON.stringify({ version: 1, parts });
const plain = (value) => JSON.parse(JSON.stringify(value));

// Storage with the box address, `sources` (URLs or { url, token }) and the
// bundles they last gave.
const stored = (sources, bundles = {}) => ({
  "denbox:address": ADDRESS,
  "denbox:sources": sources.map((source) => (typeof source === "string" ? { url: source } : source)),
  "denbox:bundles": bundles,
});
// Answers each URL with its text from `served`; a number is an HTTP status.
const serve = (served) => (url) => {
  const value = served[url];
  return typeof value === "number" ? { status: value } : value === undefined ? { status: 404 } : { body: value };
};
const state = (store, source, name) => plain(store["denbox:started"]).parts.find((part) => part.source === source && part.name === name);

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

test("a source must be https and off the box's origin", () => {
  assert.equal(sourceError(A, ADDRESS), undefined);
  assert.equal(sourceError("https://box.example.com:8443/b.json", ADDRESS), undefined, "another port is another origin");
  assert.match(sourceError("http://git.example.com/b.json", ADDRESS), /https/);
  assert.match(sourceError("https://box.example.com/files/b.json", ADDRESS), /box's origin/);
  assert.match(sourceError("https://box.example.com/b.json", "https://box.example.com"), /box's origin/);
  assert.match(sourceError("nope", ADDRESS), /not a URL/);
});

test("a part that throws while starting is recorded and the others run", async () => {
  const text = bundle({
    ok: { background: "globalThis.okRan = denbox.part;" },
    sync: { background: "throw new Error('broken');" },
    later: { background: "await null; throw new Error('later');" },
    syntax: { background: "this is not code" },
  });
  const { store, context, ready, chrome } = loadBackground({ storage: stored([A], { [A]: text }), respond: serve({ [A]: text }) });
  await ready;
  assert.equal(context.okRan, "ok");
  assert.deepEqual(state(store, A, "ok"), { source: A, name: "ok", state: "running" });
  assert.deepEqual(state(store, A, "sync"), { source: A, name: "sync", state: "failed", error: "broken" });
  assert.equal(state(store, A, "later").error, "later");
  assert.equal(state(store, A, "syntax").state, "failed");
  assert.equal(chrome.reloads, 0, "the same bundle at the source causes no reload");
});

test("every source runs, and a failing source keeps its bundle while another changes", async () => {
  const a = bundle({ a: { background: "globalThis.aRan = true;" } });
  const b = bundle({ b: { background: "globalThis.bRan = true;" } });
  const nextB = bundle({ b: {}, c: {} });
  for (const failure of [502, "{ nope", JSON.stringify({ version: 2, parts: {} })]) {
    const { store, ready, chrome, context } = loadBackground({
      storage: stored([A, B], { [A]: a, [B]: b }),
      respond: serve({ [A]: failure, [B]: nextB }),
    });
    await ready;
    assert.ok(context.aRan && context.bRan);
    assert.deepEqual(store["denbox:bundles"], { [A]: a, [B]: nextB });
    assert.ok(store["denbox:status"][A].error, `status of A for ${failure}`);
    assert.equal(store["denbox:status"][B].error, undefined);
    assert.equal(chrome.reloads, 1);
  }
});

test("a removed source drops its parts", async () => {
  const a = bundle({ a: {} });
  const { store, ready, chrome } = loadBackground({ storage: stored([A], { [A]: a, [B]: bundle({ b: {} }) }), respond: serve({ [A]: a }) });
  await ready;
  assert.deepEqual(store["denbox:bundles"], { [A]: a });
  assert.deepEqual(Object.keys(store["denbox:status"]), [A]);
  assert.deepEqual(plain(store["denbox:started"]).parts.map((part) => part.name), ["a"]);
  assert.equal(chrome.reloads, 1);
});

test("a second part of the same name is reported and not started", async () => {
  const a = bundle({ same: { background: "globalThis.ran = 'a';" } });
  const b = bundle({ same: { background: "globalThis.ran = 'b';" }, other: {} });
  const { store, ready, context } = loadBackground({ storage: stored([A, B], { [A]: a, [B]: b }), respond: serve({ [A]: a, [B]: b }) });
  await ready;
  assert.equal(context.ran, "a");
  assert.equal(state(store, A, "same").state, "running");
  assert.equal(state(store, B, "same").state, "skipped");
  assert.match(state(store, B, "same").error, new RegExp(A));
  assert.equal(state(store, B, "other").state, "running");
});

test("a stored source on the box's origin is refused and its bundle dropped", async () => {
  const onBox = "https://box.example.com/api/parts.json";
  const text = bundle({ evil: { background: "globalThis.ran = true;" } });
  const { store, ready, requests, context } = loadBackground({ storage: stored([onBox], { [onBox]: text }), respond: serve({ [onBox]: text }) });
  await ready;
  assert.equal(context.ran, undefined);
  assert.equal(requests.length, 0);
  assert.deepEqual(store["denbox:bundles"], {});
  assert.match(store["denbox:status"][onBox].error, /Refused/);
});

test("a redirect to the box's origin is refused", async () => {
  const { store, ready } = loadBackground({
    storage: stored([A]),
    respond: () => ({ body: bundle({ evil: {} }), url: `${ADDRESS}/parts.json` }),
  });
  await ready;
  assert.deepEqual(store["denbox:bundles"], {});
  assert.match(store["denbox:status"][A].error, /redirected/);
});

test("a token goes only to its own source", async () => {
  const text = bundle({ a: { background: "globalThis.api = denbox.api;" } });
  const { ready, requests, context } = loadBackground({
    storage: stored([{ url: A, token: "secret" }, B], { [A]: text }),
    respond: (url) => (url === A ? { body: text } : url === B ? { body: bundle({}) } : { body: "{}" }),
  });
  await ready;
  await context.api("/state");
  const to = (url) => requests.find((request) => request.url === url).init;
  assert.equal(to(A).headers.authorization, "Bearer secret");
  assert.equal(to(A).credentials, "omit");
  assert.equal(to(B).headers.authorization, undefined);
  assert.equal(to(B).credentials, "include");
  const box = to(`${ADDRESS}/state`);
  assert.equal(box.headers.authorization, undefined);
  assert.equal(box.headers["x-denbox-api"], "1");
  assert.ok(requests.every((request) => request.url === A || !JSON.stringify(request.init).includes("secret")));
});

test("a hold keeps the extension from reloading until it is released", async () => {
  const old = bundle({ rec: { background: "globalThis.release = denbox.hold('recording');" } });
  let served = old;
  const { store, ready, chrome, context } = loadBackground({ storage: stored([A], { [A]: old }), respond: () => ({ body: served }) });
  await ready;
  served = bundle({ rec: {} });
  await vm.runInContext("check()", context);
  assert.equal(chrome.reloads, 0);
  assert.equal(store["denbox:bundles"][A], old);
  assert.match(store["denbox:status"][A].error, /recording/);
  context.release();
  await vm.runInContext("check()", context);
  assert.equal(chrome.reloads, 1);
});

test("saving in the options checks the sources at once", async () => {
  const next = bundle({ a: {} });
  const { store, ready, chrome } = loadBackground({ respond: serve({ [A]: next }) });
  await ready;
  await chrome.storage.local.set({ ...stored([A]), "denbox:check": 1 });
  assert.equal(store["denbox:bundles"][A], next);
  assert.equal(chrome.reloads, 1);
});

test("content scripts run in tabs whose address matches", async () => {
  const text = bundle({ a: { content: [{ matches: ["https://*.example.com/*"], js: "1" }] } });
  const { ready, chrome, injected } = loadBackground({ storage: stored([A], { [A]: text }), respond: serve({ [A]: text }) });
  await ready;
  chrome.tabs.onUpdated.fire(1, { status: "complete" }, { url: "https://docs.example.com/x" });
  chrome.tabs.onUpdated.fire(2, { status: "complete" }, { url: "https://example.org/" });
  chrome.tabs.onUpdated.fire(3, { status: "loading" }, { url: "https://docs.example.com/x" });
  assert.deepEqual(plain(injected), [{ tabId: 1, code: "1" }]);
});

test("denbox.api posts to the box address and throws the server's error", async () => {
  const text = bundle({ a: { background: "globalThis.api = denbox.api;" } });
  const { ready, context, requests } = loadBackground({
    storage: stored([A], { [A]: text }),
    respond: (url) => (url === A ? { body: text } : { status: 400, body: '{"error":"unknown service"}' }),
  });
  await ready;
  await assert.rejects(context.api("/services/restart", { name: "x" }), /unknown service/);
  const call = requests.at(-1);
  assert.equal(call.url, `${ADDRESS}/services/restart`);
  assert.equal(call.init.method, "POST");
  assert.equal(call.init.body, '{"name":"x"}');
});
