// The toolbar popup: one entry per page of the running bundle, named by the
// page's <title> (else PART/PAGE), opening page.html#PART/PAGE in a tab.
const titleOf = (html) => new DOMParser().parseFromString(html ?? "", "text/html").title.trim();

function entry(label, onClick) {
  const button = document.createElement("button");
  button.textContent = label;
  button.addEventListener("click", onClick);
  return button;
}

async function show() {
  const stored = await chrome.storage.local.get(["denbox:bundle", "denbox:status"]);
  const bundle = stored["denbox:bundle"] ? parseBundle(stored["denbox:bundle"]) : { parts: {} };
  const entries = pagesOf(bundle).map(({ part, page }) =>
    entry(titleOf(bundle.parts[part].pages[page].html) || `${part}/${page}`, () => {
      chrome.tabs.create({ url: chrome.runtime.getURL(`page.html#${encodeURIComponent(part)}/${encodeURIComponent(page)}`) });
      window.close();
    }),
  );
  if (!entries.length) {
    const empty = document.createElement("p");
    empty.className = stored["denbox:status"]?.error ? "bad" : "muted";
    empty.textContent = stored["denbox:status"]?.error ?? "No pages";
    entries.push(empty);
  }
  document.getElementById("pages").replaceChildren(...entries);
}

document.getElementById("settings").addEventListener("click", () => {
  chrome.runtime.openOptionsPage();
  window.close();
});
show().catch((error) => {
  document.getElementById("pages").textContent = message(error);
});
