// The options page: the box API's address, the last check, what the running
// bundle started and how each part did, and the shortcut slots. Saving writes
// denbox:check, which makes loader.js check the box right away.
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

function showStatus(status) {
  const line = field("status");
  line.className = status?.error ? "bad" : "muted";
  line.textContent = !status ? "Not checked yet" : `Checked ${time(status.checkedAt)}${status.error ? `: ${status.error}` : ""}`;
}

function showStarted(started) {
  const names = Object.keys(started?.parts ?? {});
  const rows = names.map((name) => {
    const { state, error } = started.parts[name];
    return row([name], [error ? `${state}: ${error}` : state, state === "failed" ? "bad" : "muted"]);
  });
  if (started?.error) rows.unshift(row(["bundle"], [started.error, "bad"]));
  if (!started) rows.push(row(["None", "muted"]));
  else rows.push(row([`Started ${time(started.at)}`, "muted"]));
  field("parts").replaceChildren(...rows);
}

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

field("save").addEventListener("click", () => {
  void chrome.storage.local.set({ "denbox:address": trimAddress(field("address").value), "denbox:check": Date.now() });
});

chrome.storage.local.get(["denbox:address", "denbox:status", "denbox:started"]).then((stored) => {
  field("address").value = stored["denbox:address"] ?? "";
  showStatus(stored["denbox:status"]);
  showStarted(stored["denbox:started"]);
});
chrome.storage.onChanged.addListener((changes, area) => {
  if (area !== "local") return;
  if (changes["denbox:status"]) showStatus(changes["denbox:status"].newValue);
  if (changes["denbox:started"]) showStarted(changes["denbox:started"].newValue);
});
