// The background page. Runs the parts of the stored bundles and keeps every
// source's bundle current: every 5 minutes, and when the options page saves,
// it fetches each source and applies a change by reloading the extension,
// which starts every part clean.
//
// Storage (chrome.storage.local):
//   denbox:address   the box API's address: data only, never code
//   denbox:sources   [{ url, token? }], set in the options page
//   denbox:bundles   { URL: text } of the bundle each source last gave
//   denbox:status    { URL: { checkedAt, error? } } of the last check
//   denbox:started   { at, parts: [{ source, name, state, error? }] } of this
//                    start; state is "starting", "running", "failed" or "skipped"
//   denbox:check     written by the options page to ask for a check now
//
// Source code runs with all of this extension's permissions: a source must be
// a file that only a merge changes (README.md, Sources).
const CHECK_ALARM = "denbox:check";
const BASE_ALARM = "denbox:base";
const KEYS = ["denbox:address", "denbox:sources", "denbox:bundles"];

// Reasons parts gave to keep the extension from reloading (see denbox.hold),
// one entry per hold.
const holds = new Set();
const holdReasons = () => [...holds].map((hold) => hold.reason).join(", ");

async function read() {
  const stored = await chrome.storage.local.get(KEYS);
  return { address: stored["denbox:address"] ?? "", sources: stored["denbox:sources"] ?? [], bundles: stored["denbox:bundles"] ?? {} };
}

// Fetches one source. Without a token the request carries the profile's
// cookies for that host; with one it carries only the token. A redirect is held
// to the same rules as the source itself.
async function fetchSource({ url, token }, address) {
  // no-cache revalidates through the HTTP cache, so an unchanged file is not downloaded again.
  const response = await fetch(url, {
    cache: "no-cache",
    credentials: token ? "omit" : "include",
    headers: token ? { authorization: `Bearer ${token}` } : {},
  });
  const landed = response.url && response.url !== url ? sourceError(response.url, address) : undefined;
  if (landed) throw new Error(`redirected to ${response.url}, which ${landed}`);
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  return await response.text();
}

// Fetches every source. A source that fails, or gives a bundle that does not
// parse, keeps its previous bundle. Bundles of removed or refused sources are
// dropped. Any change is stored and the extension reloads into it.
async function runCheck() {
  const { address, sources, bundles } = await read();
  if (holds.size) {
    const error = `Update waits: ${holdReasons()}`;
    const status = Object.fromEntries(sources.map(({ url }) => [url, { checkedAt: Date.now(), error }]));
    return await chrome.storage.local.set({ "denbox:status": status });
  }
  const next = {};
  const status = {};
  await Promise.all(
    sources.map(async (source) => {
      const { url } = source;
      const refused = sourceError(url, address);
      if (refused) return void (status[url] = { checkedAt: Date.now(), error: `Refused: ${refused}` });
      if (bundles[url] !== undefined) next[url] = bundles[url];
      try {
        const text = await fetchSource(source, address);
        if (text !== bundles[url]) {
          parseBundle(text);
          next[url] = text;
        }
        status[url] = { checkedAt: Date.now() };
      } catch (error) {
        status[url] = { checkedAt: Date.now(), error: message(error) };
      }
    }),
  );
  const urls = new Set([...Object.keys(bundles), ...Object.keys(next)]);
  const changed = [...urls].some((url) => bundles[url] !== next[url]);
  await chrome.storage.local.set({ "denbox:bundles": next, "denbox:status": status });
  if (changed) {
    // Parts start clean, so the alarms they made go too; the loader makes its own again.
    await chrome.alarms.clearAll();
    chrome.runtime.reload();
  }
}

// Checks run one after another, so a save during a check is not lost; one
// that fails does not stop the next.
let queue = Promise.resolve();
const check = () => (queue = queue.catch(() => {}).then(runCheck));

// Runs content scripts once a matching page has loaded.
function injectContent(scripts) {
  if (!scripts.length) return;
  const rules = scripts.map(({ matches, js }) => ({ js, patterns: matches.map(matchPattern) }));
  chrome.tabs.onUpdated.addListener((tabId, change, tab) => {
    if (change.status !== "complete" || !tab.url) return;
    for (const { js, patterns } of rules) {
      if (patterns.some((pattern) => pattern.test(tab.url))) {
        chrome.tabs.executeScript(tabId, { code: js }, () => void chrome.runtime.lastError);
      }
    }
  });
}

// The `denbox` object a part's background code gets. See README.md.
function backgroundDenbox(part, address) {
  return {
    part,
    address: trimAddress(address),
    api: boxApi(address),
    hold(reason = part) {
      const entry = { reason: String(reason) };
      holds.add(entry);
      return () => void holds.delete(entry);
    },
  };
}

// Starts every part at once; each one's outcome lands in denbox:started as it
// settles, so a part that throws, or never finishes starting, holds up no other.
async function startParts({ address, sources, bundles }) {
  const entries = plan(address, sources, bundles);
  const started = {
    at: Date.now(),
    parts: entries.map(({ source, name, error }) => (error ? { source, name, state: "skipped", error } : { source, name, state: "starting" })),
  };
  const save = () => chrome.storage.local.set({ "denbox:started": started });
  await save();
  await Promise.all(
    entries.map(async ({ name, part }, index) => {
      if (!part) return;
      const { source } = started.parts[index];
      try {
        injectContent(part.content ?? []);
        if (part.background) await compile(part.background)(chrome, backgroundDenbox(name, address));
        started.parts[index] = { source, name, state: "running" };
      } catch (error) {
        started.parts[index] = { source, name, state: "failed", error: message(error) };
      }
      await save();
    }),
  );
}

// An installer copies a new version of the unpacked folder over the old one.
// Reloading picks it up, so the extension is loaded into a browser only once.
async function checkBase() {
  if (holds.size) return;
  try {
    const onDisk = await (await fetch(chrome.runtime.getURL("manifest.json"))).json();
    if (onDisk.version !== chrome.runtime.getManifest().version) chrome.runtime.reload();
  } catch {
    // Mid-copy; the next check sees the finished file.
  }
}

chrome.alarms.create(BASE_ALARM, { periodInMinutes: 5 });
chrome.alarms.create(CHECK_ALARM, { periodInMinutes: 5 });
chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === BASE_ALARM) void checkBase();
  if (alarm.name === CHECK_ALARM) void check();
});

chrome.storage.onChanged.addListener(async (changes, area) => {
  if (area === "local" && changes["denbox:check"]) await check();
});

// Ready when the stored bundles' parts have started and the first check is
// done; the tests wait for it.
const ready = read().then((stored) => Promise.all([startParts(stored), check()]));
