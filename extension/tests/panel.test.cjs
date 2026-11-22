// The panel shows what a box answers, and a box may have been steered by
// someone else. These tests run panel.js against a fake DOM that refuses every
// way of turning text into markup, URLs, styles or code, feed it a /state full
// of markup, and check the markup arrives as text.
const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");
const { extension } = require("./harness.cjs");

const source = (name) => readFileSync(path.join(extension, name), "utf8");
const ADDRESS = "https://box.example.com/api";
const EVIL = '<img src=x onerror="globalThis.pwned=1">';

class Node {}
class Text extends Node {
  constructor(data) {
    super();
    this.data = data;
  }
}
// Only what panel.js uses. Setting anything that parses or loads throws.
class Element extends Node {
  constructor(tag) {
    super();
    this.tagName = tag.toUpperCase();
    this.childNodes = [];
    this.listeners = {};
  }
  append(...children) {
    for (const child of children) this.childNodes.push(child instanceof Node ? child : new Text(String(child)));
  }
  replaceChildren(...children) {
    this.childNodes = [];
    this.append(...children);
  }
  set textContent(value) {
    this.childNodes = [new Text(String(value))];
  }
  get textContent() {
    return this.childNodes.map((child) => (child instanceof Text ? child.data : child.textContent)).join("");
  }
  addEventListener(type, listener) {
    this.listeners[type] = listener;
  }
}
for (const name of ["innerHTML", "outerHTML", "style", "href", "src", "srcdoc", "action"]) {
  Object.defineProperty(Element.prototype, name, {
    set() {
      throw new Error(`panel set ${name}`);
    },
  });
}
for (const name of ["insertAdjacentHTML", "setAttribute", "setHTMLUnsafe"]) {
  Element.prototype[name] = () => {
    throw new Error(`panel called ${name}`);
  };
}

// Runs panel.js after bundle.js, as panel.html does, with the box answering `state`.
async function loadPanel(state, address = ADDRESS) {
  const ids = ["error", "system", "services", "ports", "restart-all", "services-note"];
  const elements = Object.fromEntries(ids.map((id) => [id, new Element("div")]));
  const created = [];
  const document = {
    visibilityState: "hidden",
    getElementById: (id) => elements[id],
    createElement: (tag) => {
      const node = new Element(tag);
      created.push(node);
      return node;
    },
    addEventListener() {},
  };
  const chrome = { storage: { local: { get: async () => ({ "denbox:address": address }) } } };
  const fetch = async () => ({ ok: true, status: 200, json: async () => structuredClone(state) });
  const context = vm.createContext({ document, chrome, fetch, Node, setTimeout, clearTimeout, console, structuredClone, URL });
  vm.runInContext(`${source("bundle.js")}\n${source("panel.js")}\n;globalThis.__ready = ready;`, context);
  await context.__ready;
  return { elements, created, context };
}

// Every text node under `node`.
const texts = (node) => (node instanceof Text ? [node.data] : node.childNodes.flatMap(texts));

test("a /state full of markup reaches the page as text", async () => {
  const state = {
    system: { state: "unavailable", reason: EVIL },
    services: [
      { name: EVIL, up: true, seconds: 5, optional: true, enabled: true },
      { name: "t3", up: false, seconds: EVIL },
    ],
    ports: [{ port: EVIL, address: EVIL, process: EVIL }],
  };
  const { elements, created, context } = await loadPanel(state);
  assert.equal(context.pwned, undefined);
  assert.equal(elements.error.hidden, true, elements.error.textContent);
  const tags = new Set(["TABLE", "TR", "TD", "SPAN", "BUTTON", "METER"]);
  assert.ok(created.every((node) => tags.has(node.tagName)), "only the panel's own elements");
  for (const id of ["system", "services", "ports"]) {
    assert.ok(texts(elements[id]).some((text) => text.includes(EVIL)), `${id} shows the markup as text`);
  }
});

test("a section of an unexpected shape is reported in place, as text", async () => {
  const state = {
    system: { memory: { usedBytes: EVIL, limitBytes: EVIL }, cpu: { percent: EVIL }, network: {}, uptimeSeconds: EVIL },
    services: { state: EVIL },
    ports: EVIL,
  };
  const { elements, context } = await loadPanel(state);
  assert.equal(context.pwned, undefined);
  for (const id of ["system", "services", "ports"]) {
    assert.match(elements[id].textContent, /Unexpected data/, id);
  }
});

test("without a box address the panel says so and calls nothing", async () => {
  const { elements } = await loadPanel({}, null);
  assert.equal(elements.error.hidden, false);
  assert.match(elements.error.textContent, /box address/);
});

test("the panel's code has no way to turn data into markup or code", () => {
  const code = source("panel.js").replace(/^\s*\/\/.*$/gm, "");
  for (const forbidden of [/innerHTML/, /outerHTML/, /insertAdjacentHTML/, /\beval\b/, /Function\(/, /document\.write/, /\.style\b/, /\bstyle:/, /\bhref\b/, /\bsrc\b/, /setAttribute/]) {
    assert.doesNotMatch(code, forbidden);
  }
});
