// What the background page, the popup, the options page, page.html and the
// panel share: checking sources, reading bundles and talking to the box API.
// Loaded first everywhere, and by the tests in node.
const AsyncFunction = (async () => {}).constructor;
const GUARD_HEADER = "x-denbox-api";

const message = (error) => (error instanceof Error ? error.message : String(error));

// The code of a part's background or page runs as the body of an async function
// with these two arguments.
const compile = (code) => new AsyncFunction("chrome", "denbox", code);

const isText = (value) => typeof value === "string";
const isRecord = (value) => typeof value === "object" && value !== null && !Array.isArray(value);

// Throws unless `text` is a bundle of format version 1; answers the bundle.
// Only the shape is checked here. A part whose code does not compile fails when
// it starts, without taking the other parts with it.
function parseBundle(text) {
  const bundle = JSON.parse(text);
  if (!isRecord(bundle) || bundle.version !== 1) throw new Error("not a version 1 bundle");
  if (!isRecord(bundle.parts)) throw new Error("parts must be an object");
  for (const [name, part] of Object.entries(bundle.parts)) {
    const fail = (reason) => {
      throw new Error(`part ${name}: ${reason}`);
    };
    if (!isRecord(part)) fail("must be an object");
    if (part.background !== undefined && !isText(part.background)) fail("background must be text");
    if (part.content !== undefined) {
      if (!Array.isArray(part.content)) fail("content must be a list");
      for (const script of part.content) {
        if (!isRecord(script) || !isText(script.js)) fail("content needs js");
        if (!Array.isArray(script.matches) || !script.matches.every(isText)) fail("content needs matches");
      }
    }
    if (part.pages !== undefined) {
      if (!isRecord(part.pages)) fail("pages must be an object");
      for (const [page, value] of Object.entries(part.pages)) {
        if (!isRecord(value)) fail(`page ${page} must be an object`);
        if (value.html !== undefined && !isText(value.html)) fail(`page ${page}: html must be text`);
        if (value.js !== undefined && !isText(value.js)) fail(`page ${page}: js must be text`);
      }
    }
  }
  return bundle;
}

// Why `url` cannot be a source, or undefined when it can. A source is https and
// not on the box's origin: the box supplies data, never code. The loader and
// the options page both ask, so a source stored before a change of the box
// address is refused too.
function sourceError(url, address) {
  let source;
  try {
    source = new URL(url);
  } catch {
    return "not a URL";
  }
  if (source.protocol !== "https:") return "must be https";
  if (!address) return undefined;
  let box;
  try {
    box = new URL(trimAddress(address));
  } catch {
    return "the box address is not a URL";
  }
  if (source.origin === box.origin) return "is on the box's origin, and the box must not supply code";
  return undefined;
}

// The parts of the stored bundles in the order they start: source order, then
// bundle order. `sources` is denbox:sources, `bundles` is denbox:bundles. An
// entry is { source, name, part } for a part that runs, or { source, name,
// error } for one that does not: a duplicate name (the first one runs) or a
// stored bundle that no longer parses (name null). Refused sources are left out.
function plan(address, sources, bundles) {
  const entries = [];
  const owners = new Map();
  for (const { url } of sources) {
    if (sourceError(url, address) || bundles[url] === undefined) continue;
    let bundle;
    try {
      bundle = parseBundle(bundles[url]);
    } catch (error) {
      entries.push({ source: url, name: null, error: `stored bundle: ${message(error)}` });
      continue;
    }
    for (const [name, part] of Object.entries(bundle.parts)) {
      const owner = owners.get(name);
      if (owner) {
        entries.push({ source: url, name, error: `not started: ${owner} has a part of this name` });
      } else {
        owners.set(name, url);
        entries.push({ source: url, name, part });
      }
    }
  }
  return entries;
}

// Every page of every running part, as `{ part, page, html }`. The popup lists
// them and page.html#PART/PAGE shows one.
const pagesOf = (entries) =>
  entries.flatMap(({ name, part }) =>
    Object.entries(part?.pages ?? {}).map(([page, value]) => ({ part: name, page, html: value.html })),
  );

// A content script's match pattern as a regular expression; * matches anything.
const matchPattern = (pattern) =>
  new RegExp(`^${pattern.replace(/[.+?^${}()|[\]\\]/g, "\\$&").replaceAll("*", ".*")}$`);

const trimAddress = (address) => address.trim().replace(/\/+$/, "");

// Calls the box API at `address`: api("/state") is a GET, api(path, body) a
// POST of `body` as JSON. Answers the parsed reply; a reply that is not 2xx
// throws with the server's `error`. Requests carry the profile's cookies, so a
// front door behind the profile's login works, and never a source's token.
// The reply is data: callers put it into pages as text only.
function boxApi(address) {
  return async (path, body) => {
    const response = await fetch(`${trimAddress(address)}${path}`, {
      method: body === undefined ? "GET" : "POST",
      cache: "no-store",
      credentials: "include",
      headers: { [GUARD_HEADER]: "1", ...(body === undefined ? {} : { "content-type": "application/json" }) },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const reply = await response.json().catch(() => null);
    if (!response.ok) throw new Error(reply?.error ?? `HTTP ${response.status}`);
    return reply;
  };
}

if (typeof module !== "undefined") {
  module.exports = { parseBundle, sourceError, plan, pagesOf, matchPattern, trimAddress, boxApi, compile };
}
