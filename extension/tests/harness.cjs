// Runs the manifest's background scripts in a fresh node context with a fake
// `chrome` and `fetch`, the way the browser runs them in one scope.
const { readFileSync } = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const extension = path.join(__dirname, "..");
const manifest = JSON.parse(readFileSync(path.join(extension, "manifest.json"), "utf8"));
const backgroundSource = () =>
  manifest.background.scripts.map((name) => readFileSync(path.join(extension, name), "utf8")).join("\n");

// A Chromium event: tests call `fire` to emit it.
function event() {
  const listeners = [];
  return { addListener: (listener) => listeners.push(listener), fire: (...args) => listeners.map((listener) => listener(...args)), listeners };
}

// `storage` seeds chrome.storage.local. `respond(url, init)` answers fetch with
// { status, body }; every call lands in `requests`.
function loadBackground({ storage = {}, respond = () => ({ status: 404, body: "" }) } = {}) {
  const store = { ...storage };
  const requests = [];
  const injected = [];
  const onChanged = event();
  const pick = (keys) => Object.fromEntries([keys].flat().filter((key) => key in store).map((key) => [key, store[key]]));
  const chrome = {
    reloads: 0,
    storage: {
      onChanged,
      local: {
        get: async (keys) => structuredClone(pick(keys)),
        set: async (values) => {
          const changes = {};
          for (const [key, value] of Object.entries(structuredClone(values))) {
            changes[key] = { oldValue: store[key], newValue: value };
            store[key] = value;
          }
          await Promise.all(onChanged.fire(changes, "local"));
        },
        remove: async (keys) => {
          for (const key of [keys].flat()) delete store[key];
        },
      },
    },
    alarms: { create() {}, clearAll: async () => {}, onAlarm: event() },
    runtime: {
      reload() {
        chrome.reloads += 1;
      },
      getURL: (file) => `chrome-extension://id/${file}`,
      getManifest: () => manifest,
      lastError: undefined,
    },
    tabs: {
      onUpdated: event(),
      executeScript: (tabId, details, done) => {
        injected.push({ tabId, code: details.code });
        done?.();
      },
    },
  };
  const fetch = async (url, init = {}) => {
    requests.push({ url, init });
    const { status = 200, body = "" } = await respond(url, init);
    return {
      status,
      ok: status >= 200 && status < 300,
      text: async () => body,
      json: async () => JSON.parse(body),
    };
  };
  const context = vm.createContext({ chrome, fetch, console, structuredClone, URL });
  vm.runInContext(`${backgroundSource()}\n;globalThis.__ready = ready;`, context);
  return { chrome, store, requests, injected, context, ready: context.__ready };
}

module.exports = { loadBackground, backgroundSource, extension };
