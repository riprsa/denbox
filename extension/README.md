# Denbox extension

A Manifest V2 extension for Chromium browsers that still run MV2 (Helium, for
one). It holds no feature of its own: it fetches the bundle of one box from
that box's `denbox-api` and runs it. Everything it shows comes from the
bundle's parts, such as the kit's `panel` (`kit/browser/panel`).

Bundle code runs with all of this extension's permissions. Point it only at a
box you trust.

## Install

1. Copy this folder somewhere it can stay.
2. Open `chrome://extensions`, turn on Developer mode, **Load unpacked**, pick
   the folder.
3. In the extension's options set the box API's address, for example
   `https://box.example.com/api`, and press **Save and check**.

The extension checks the box every 5 minutes and on **Save and check**. It
sends every request with the header `x-denbox-api: 1` and the profile's
cookies, so a front door behind the profile's login works.

**Updates of the extension itself.** Copy a new version of this folder over the
old one. Every 5 minutes the extension compares `version` in the manifest on
disk with the one it runs and reloads itself when they differ. Bump `version`
with every change.

The manifest `key` is the one of the extension Denbox replaces, so the
extension id, and every origin and native messaging host that trusts it, stays
the same.

## Bundle

`GET <address>/bundle.json` answers

```json
{
  "version": 1,
  "parts": {
    "panel": {
      "background": "code",
      "content": [{ "matches": ["https://*.example.com/*"], "js": "code" }],
      "pages": { "panel": { "html": "<title>Box</title>...", "js": "code" } }
    }
  }
}
```

Every field of a part is optional. 404 means the box has no parts; the
extension then runs nothing.

- A changed bundle is stored and applied by reloading the extension, so every
  part starts clean. The stored copy runs on the next start, also while the
  box is unreachable.
- A bundle that does not parse (not JSON, not version 1, a field of the wrong
  type) is not stored. The running one keeps running, and the options page
  shows why.
- Each part starts on its own. A part whose code does not compile, throws or
  rejects is recorded as failed in the options page; the other parts keep
  running.
- `content` scripts run in the top frame of a tab whose address matches one of
  `matches` (`*` matches anything) once the page has loaded, via
  `tabs.executeScript`.

## What a part gets

`background` and page `js` are the body of an async function called with two
arguments, so they may use top-level `await` and their top-level names stay
their own.

- `chrome`, with the manifest's permissions: `tabs`, `tabCapture`,
  `nativeMessaging`, `alarms`, `storage`, `unlimitedStorage`, `bookmarks`,
  `clipboardWrite`, `cookies`, `contextMenus`, `notifications`,
  `webNavigation`, `webRequest`, `webRequestBlocking`, `<all_urls>`. Manifest
  V2 has no `action`, `scripting` or `storage.session`: use `browserAction`
  and `tabs.executeScript`.
- `denbox`:

| Field | Meaning |
| --- | --- |
| `part` | the part's name |
| `address` | the box API's address, without a trailing `/` |
| `api(path)` | `GET` of the box API; answers the parsed JSON |
| `api(path, body)` | `POST` of `body` as JSON |
| `hold(reason)` | background only: keeps the extension from reloading (a bundle update or a new version on disk) until the returned function is called |

`api` throws with the server's `error` on a reply that is not 2xx. `hold` is
for work a reload would cut short, such as a recording.

A part's background starts once per start of the extension, so it should not
wait for `runtime.onInstalled` or `onStartup`. It keeps its storage under its
own prefix (`<part>:`) and leaves `denbox:*` alone. Alarms are cleared when
the box drops its bundle.

### Pages

A page opens at `page.html#PART/PAGE`. Its `html` is parsed into the page
(`<head>` and `<body>` children; `<title>` becomes the tab's title) on top of
the extension's `stock.css`. Inline `<script>` does not run: the page's code
is its `js`. Anything after `#PART/PAGE/` is the page's own; the page reloads
when the hash changes.

**Popup.** The toolbar popup lists every page of every part, named by its
`<title>` (else `PART/PAGE`), and opens the chosen one in a new tab. That is
the whole mechanism: a part shows up in the popup by having a page.

**Shortcuts.** Manifest `commands` cannot come from a bundle, so the manifest
has four slots, `shortcut-1` to `shortcut-4`, with no keys suggested. A part
listens with

```js
chrome.commands.onCommand.addListener((command) => {
  if (command === "shortcut-1") start();
});
```

The environment decides which part uses which slot. The person binds keys at
`chrome://extensions/shortcuts`; the options page shows what is bound.

## Storage

| Key | Holds |
| --- | --- |
| `denbox:address` | the box API's address |
| `denbox:bundle` | the text of the running bundle |
| `denbox:status` | `{ checkedAt, error? }` of the last check |
| `denbox:started` | `{ at, error?, parts: { NAME: { state, error? } } }`, state `starting`, `running` or `failed` |
| `denbox:check` | written by the options page to check now |

## Tests

```sh
node --test 'extension/tests/*.test.cjs'
```

`tests/harness.cjs` runs the background scripts in a node context with a fake
`chrome` and `fetch`.
