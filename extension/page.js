// page.html#PART/PAGE shows one page of the running bundle. Extension pages
// cannot run inline scripts, so the page's code comes from its `js` field, not
// from <script> tags in its `html`. The code gets `chrome` and `denbox`
// ({ part, address, api }; see README.md).
async function show() {
  const [part, page] = location.hash.slice(1).split("/").map(decodeURIComponent);
  const stored = await chrome.storage.local.get(["denbox:bundle", "denbox:address"]);
  const found = stored["denbox:bundle"] ? parseBundle(stored["denbox:bundle"]).parts[part]?.pages?.[page] : undefined;
  if (!found) {
    document.body.textContent = `No page ${part ?? ""}/${page ?? ""} in this box's bundle`;
    return;
  }
  const parsed = new DOMParser().parseFromString(found.html ?? "", "text/html");
  if (parsed.title) document.title = parsed.title;
  document.head.append(...[...parsed.head.children].filter((node) => node.tagName !== "TITLE"));
  document.body.replaceChildren(...parsed.body.children);
  const address = stored["denbox:address"] ?? "";
  if (found.js) await compile(found.js)(chrome, { part, address: trimAddress(address), api: boxApi(address) });
}

window.addEventListener("hashchange", () => location.reload());
show().catch((error) => {
  document.body.textContent = `This page failed: ${message(error)}`;
});
