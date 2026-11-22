// page.html#PART/PAGE shows one page of a running part. Extension pages cannot
// run inline scripts, so the page's code comes from its `js` field, not from
// <script> tags in its `html`. The code gets `chrome` and `denbox`
// ({ part, address, api }; see README.md).
async function show() {
  const [part, page] = location.hash.slice(1).split("/").map(decodeURIComponent);
  const stored = await chrome.storage.local.get(["denbox:address", "denbox:sources", "denbox:bundles"]);
  const address = stored["denbox:address"] ?? "";
  const entries = plan(stored["denbox:sources"] ?? [], stored["denbox:bundles"] ?? {});
  const found = entries.find((entry) => entry.part && entry.name === part)?.part.pages?.[page];
  if (!found) {
    document.body.textContent = `No page ${part ?? ""}/${page ?? ""} in the running parts`;
    return;
  }
  const parsed = new DOMParser().parseFromString(found.html ?? "", "text/html");
  if (parsed.title) document.title = parsed.title;
  document.head.append(...[...parsed.head.children].filter((node) => node.tagName !== "TITLE"));
  document.body.replaceChildren(...parsed.body.children);
  if (found.js) await compile(found.js)(chrome, { part, address: trimAddress(address), api: boxApi(address) });
}

window.addEventListener("hashchange", () => location.reload());
show().catch((error) => {
  document.body.textContent = `This page failed: ${message(error)}`;
});
