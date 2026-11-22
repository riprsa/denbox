// The background page. Runs the parts of the stored bundle and keeps that
// bundle current with the box: every 5 minutes, and when the options page
// saves, it fetches <address>/bundle.json and applies a changed one by
// reloading the extension, which starts every part clean.
//
// Storage (chrome.storage.local):
//   denbox:address   the box API's address, set in the options page
//   denbox:bundle    the text of the running bundle
//   denbox:status    { checkedAt, error? } of the last check
//   denbox:started   { at, parts: { NAME: { state, error? } } } of this start;
//                    state is "starting", "running" or "failed"
//   denbox:check     written by the options page to ask for a check now
//
// Bundle code runs with all of this extension's permissions: point it only at
// a box you trust.
const CHECK_ALARM = "denbox:check";
const BASE_ALARM = "denbox:base";
const KEYS = ["denbox:address", "denbox:bundle"];

// Reasons parts gave to keep the extension from reloading (see denbox.hold),
// one entry per hold.
const holds = new Set();
const holdReasons = () => [...holds].map((hold) => hold.reason).join(", ");

const setStatus = (status) => chrome.storage.local.set({ "denbox:status": { checkedAt: Date.now(), ...status } });

// Fetches the box's bundle. A changed bundle that parses is stored and the
// extension reloads into it. A failed fetch or a bundle that does not parse
// leaves the running one alone. 404 means the box has no parts.
async function check() {
  const stored = await chrome.storage.local.get(KEYS);
  const address = stored["denbox:address"];
  if (!address) return;
  if (holds.size) return await setStatus({ error: `Update waits: ${holdReasons()}` });
  try {
    // no-cache revalidates through the HTTP cache, so an unchanged file is not downloaded again.
    const response = await fetch(`${trimAddress(address)}/bundle.json`, {
      cache: "no-cache",
      credentials: "include",
      headers: { [GUARD_HEADER]: "1" },
    });
    if (response.status === 404) {
      await setStatus({ error: "The box has no parts" });
      if (stored["denbox:bundle"]) await forget();
      return;
    }
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const text = await response.text();
    if (text === stored["denbox:bundle"]) return await setStatus({});
    parseBundle(text);
    await chrome.storage.local.set({ "denbox:bundle": text, "denbox:status": { checkedAt: Date.now() } });
    chrome.runtime.reload();
  } catch (error) {
    await setStatus({ error: message(error) });
  }
}

// Drops the running bundle and every alarm its parts made, then reloads into
// an extension that runs nothing.
async function forget() {
  await chrome.storage.local.remove(["denbox:bundle", "denbox:started"]);
  await chrome.alarms.clearAll();
  chrome.runtime.reload();
}

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
async function startParts(text, address) {
  const started = { at: Date.now(), parts: {} };
  const save = () => chrome.storage.local.set({ "denbox:started": started });
  let bundle;
  try {
    bundle = parseBundle(text);
  } catch (error) {
    started.error = message(error);
    return await save();
  }
  const names = Object.keys(bundle.parts);
  for (const name of names) started.parts[name] = { state: "starting" };
  await save();
  await Promise.all(
    names.map(async (name) => {
      const part = bundle.parts[name];
      try {
        injectContent(part.content ?? []);
        if (part.background) await compile(part.background)(chrome, backgroundDenbox(name, address));
        started.parts[name] = { state: "running" };
      } catch (error) {
        started.parts[name] = { state: "failed", error: message(error) };
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
chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === BASE_ALARM) void checkBase();
  if (alarm.name === CHECK_ALARM) void check();
});

chrome.storage.onChanged.addListener(async (changes, area) => {
  if (area !== "local" || !changes["denbox:check"]) return;
  const stored = await chrome.storage.local.get(KEYS);
  if (stored["denbox:address"]) {
    chrome.alarms.create(CHECK_ALARM, { periodInMinutes: 5 });
    await check();
  } else if (stored["denbox:bundle"]) {
    await forget();
  }
});

// Ready when the stored bundle's parts have started and the first check is
// done; the tests wait for it.
const ready = chrome.storage.local.get(KEYS).then(async (stored) => {
  const address = stored["denbox:address"];
  if (!address) return;
  chrome.alarms.create(CHECK_ALARM, { periodInMinutes: 5 });
  await Promise.all([stored["denbox:bundle"] ? startParts(stored["denbox:bundle"], address) : null, check()]);
});
