// The toolbar popup: the box panel first, then one entry per page of the
// running parts, named by the page's <title> (else PART/PAGE), each opening in
// a new tab.
const titleOf = (html) => new DOMParser().parseFromString(html ?? "", "text/html").title.trim();

function entry(label, file) {
  const button = document.createElement("button");
  button.textContent = label;
  button.addEventListener("click", () => {
    chrome.tabs.create({ url: chrome.runtime.getURL(file) });
    window.close();
  });
  return button;
}

async function show() {
  const stored = await chrome.storage.local.get(["denbox:address", "denbox:sources", "denbox:bundles", "denbox:status"]);
  const entries = plan(stored["denbox:sources"] ?? [], stored["denbox:bundles"] ?? {});
  const pages = pagesOf(entries).map(({ part, page, html }) =>
    entry(titleOf(html) || `${part}/${page}`, `page.html#${encodeURIComponent(part)}/${encodeURIComponent(page)}`),
  );
  const failed = Object.values(stored["denbox:status"] ?? {}).filter((status) => status.error).length;
  const note = document.createElement("p");
  note.className = "bad";
  note.textContent = `${failed} source${failed === 1 ? "" : "s"} failed`;
  document.getElementById("pages").replaceChildren(entry("Box", "panel.html"), ...pages, ...(failed ? [note] : []));
}

document.getElementById("settings").addEventListener("click", () => {
  chrome.runtime.openOptionsPage();
  window.close();
});
show().catch((error) => {
  document.getElementById("pages").textContent = message(error);
});
