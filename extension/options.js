// The options page: the box address, the list of sources with their tokens,
// what each source last gave and how its parts did, and the shortcut slots.
// Saving writes denbox:check, which makes loader.js check every source now.
const field = (id) => document.getElementById(id);
const time = (at) => new Date(at).toLocaleString();

function row(...cells) {
  const tr = document.createElement("tr");
  for (const [text, className] of cells) {
    const td = document.createElement("td");
    td.textContent = text;
    if (className) td.className = className;
    tr.append(td);
  }
  return tr;
}

// One editable source: its URL, its optional token and a remove button.
function sourceRow({ url = "", token = "" } = {}) {
  const line = document.createElement("div");
  line.className = "row source";
  const urlInput = Object.assign(document.createElement("input"), { type: "url", value: url, placeholder: "https://raw.githubusercontent.com/OWNER/REPO/main/bundle.json" });
  const tokenInput = Object.assign(document.createElement("input"), { type: "password", value: token, placeholder: "token (optional)" });
  const remove = Object.assign(document.createElement("button"), { textContent: "Remove" });
  remove.addEventListener("click", () => line.remove());
  line.append(urlInput, tokenInput, remove);
  return line;
}

function showSources(sources) {
  field("sources").replaceChildren(...sources.map(sourceRow));
}

// The sources as typed, or the reason they cannot be saved.
function readSources() {
  const sources = [];
  for (const line of field("sources").children) {
    const [urlInput, tokenInput] = line.querySelectorAll("input");
    const url = urlInput.value.trim();
    const token = tokenInput.value.trim();
    if (!url) continue;
    const error = sourceError(url);
    if (error) return { error: `${url} ${error}` };
    if (sources.some((source) => source.url === url)) return { error: `${url} is listed twice` };
    sources.push(token ? { url, token } : { url });
  }
  return { sources };
}

// Per source: when it was checked and any error, then each of its parts.
function showLoaded({ "denbox:sources": sources = [], "denbox:status": status = {}, "denbox:started": started }) {
  const rows = [];
  for (const { url } of sources) {
    const checked = status[url];
    const state = !checked ? ["Not checked yet", "muted"] : [`Checked ${time(checked.checkedAt)}${checked.error ? `: ${checked.error}` : ""}`, checked.error ? "bad" : "muted"];
    rows.push(row([url, "url"], state));
    for (const part of started?.parts ?? []) {
      if (part.source !== url) continue;
      const bad = part.state === "failed" || part.state === "skipped";
      rows.push(row([part.name ?? "bundle", "part"], [part.error ? `${part.state}: ${part.error}` : part.state, bad ? "bad" : "muted"]));
    }
  }
  if (!sources.length) rows.push(row(["No sources", "muted"]));
  if (started) rows.push(row([`Started ${time(started.at)}`, "muted"]));
  field("loaded").replaceChildren(...rows);
}

const LOADED = ["denbox:sources", "denbox:status", "denbox:started"];
const refreshLoaded = () => chrome.storage.local.get(LOADED).then(showLoaded);

// Chromium lets the person, not the extension, bind keys to the slots; parts
// listen for "shortcut-N" in chrome.commands.onCommand.
chrome.commands.getAll((commands) => {
  field("shortcuts").replaceChildren(
    ...commands
      .filter((command) => command.name.startsWith("shortcut-"))
      .map((command) => row([command.name], command.shortcut ? [command.shortcut] : ["Not bound", "muted"])),
  );
});
field("bind").addEventListener("click", () => chrome.tabs.create({ url: "chrome://extensions/shortcuts" }));
field("add").addEventListener("click", () => field("sources").append(sourceRow()));

field("save").addEventListener("click", () => {
  const address = trimAddress(field("address").value);
  const saved = field("saved");
  if (address && !/^https?:$/.test(URL.canParse(address) ? new URL(address).protocol : "")) {
    saved.className = "bad";
    saved.textContent = "Not saved: the box address must be an http or https URL";
    return;
  }
  const { sources, error } = readSources();
  if (error) {
    saved.className = "bad";
    saved.textContent = `Not saved: ${error}`;
    return;
  }
  saved.className = "muted";
  saved.textContent = "Saved";
  void chrome.storage.local.set({ "denbox:address": address, "denbox:sources": sources, "denbox:check": Date.now() });
});

chrome.storage.local.get(["denbox:address", ...LOADED]).then((stored) => {
  field("address").value = stored["denbox:address"] ?? "";
  showSources(stored["denbox:sources"] ?? []);
  showLoaded(stored);
});
chrome.storage.onChanged.addListener((changes, area) => {
  if (area === "local" && LOADED.some((key) => changes[key])) void refreshLoaded();
});
