// What the background page, the popup, the options page and page.html share:
// reading a bundle and talking to the box API. Loaded first everywhere, and by
// the tests in node.
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

// Every page of every part, in bundle order, as `{ part, page }`. The popup
// lists them and page.html#PART/PAGE shows one.
const pagesOf = (bundle) =>
  Object.entries(bundle.parts).flatMap(([part, value]) => Object.keys(value.pages ?? {}).map((page) => ({ part, page })));

// A content script's match pattern as a regular expression; * matches anything.
const matchPattern = (pattern) =>
  new RegExp(`^${pattern.replace(/[.+?^${}()|[\]\\]/g, "\\$&").replaceAll("*", ".*")}$`);

const trimAddress = (address) => address.trim().replace(/\/+$/, "");

// Calls the box API at `address`: api("/state") is a GET, api(path, body) a
// POST of `body` as JSON. Answers the parsed reply; a reply that is not 2xx
// throws with the server's `error`. Requests carry the profile's cookies, so a
// front door behind the profile's login works.
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

if (typeof module !== "undefined") module.exports = { parseBundle, pagesOf, matchPattern, trimAddress, boxApi, compile };
