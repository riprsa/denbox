# Denbox extension

A Manifest V2 extension for Chromium browsers that still run MV2 (Helium, for
one). It has a page of its own, the panel, that shows one box's state and
sends it restarts and toggles. Every other feature is a part of a bundle that
the extension loads from a Git source.

Its options hold two separate things:

- **The box address**, where the box's `denbox-api` answers. The box supplies
  data only. The panel and the parts read it as data and never run it.
- **Sources**, each a URL of one bundle with an optional token. The code of a
  source runs with all of this extension's permissions (see Sources).

The extension id is `obadaankgmebnmebkimmlmfmjmipjkld`, fixed by the `key` in
`manifest.json`. No private key for it exists: the extension is only ever
loaded unpacked, so none is needed.

## Install

1. Copy this folder somewhere it can stay.
2. Open `chrome://extensions`, turn on Developer mode, **Load unpacked**, pick
   the folder.
3. In the extension's options set the box address, for example
   `https://box.example.com/api`, add the sources you want and press
   **Save and check**.

The panel works with the box address alone. It is the first entry of the
toolbar popup. Requests to the box carry the header `x-denbox-api: 1` and the
profile's cookies, so a front door behind the profile's login works.

**Updates of the extension itself.** Copy a new version of this folder over the
old one. Every 5 minutes the extension compares `version` in the manifest on
disk with the one it runs and reloads itself when they differ. Bump `version`
with every change.

## Sources

A source is the URL of one bundle file. The extension fetches every source
every 5 minutes and on **Save and check**.

- **What makes a URL safe.** The file is on a protected branch of a Git
  repository, and no agent can push to that branch or merge into it. Then only
  a person's merge changes what runs in the browser. A raw file URL of the
  environment's `main` is the usual choice, for example
  `https://raw.githubusercontent.com/example/environment/main/browser/bundle.json`.
  A box, anything an agent can write to, or a branch agents can push to is not
  a source: the code would run in every signed-in session of the profile.
- **Refused.** A source must be `https:` and must not be on the origin of the
  box address. The options page will not save such a source, and the loader
  skips one that is already stored. A redirect is held to the same rules.
- **Login.** Without a token the request carries the profile's cookies for the
  source's host, so a file behind the profile's login works. With a token it
  carries `authorization: Bearer <token>` and no cookies. A token goes only to
  its own source, never to the box or to another source.
- **Each source on its own.** Each keeps its own stored bundle and status. A
  source that fails to load, or gives a bundle that does not parse, leaves its
  previous bundle running, and the options page shows why. Removing a source
  drops its parts.
- **Applying.** A changed bundle is stored and applied by reloading the
  extension, so every part starts clean; the alarms parts made are cleared.
  The stored bundles run on the next start, also without network.

## Bundle

```json
{
  "version": 1,
  "parts": {
    "notes": {
      "background": "code",
      "content": [{ "matches": ["https://*.example.com/*"], "js": "code" }],
      "pages": { "notes": { "html": "<title>Notes</title>...", "js": "code" } }
    }
  }
}
```

Every field of a part is optional.

- A part name is unique across sources. A second part of the same name, in
  source order, is reported in the options page and not started.
- Each part starts on its own. A part whose code does not compile, throws or
  rejects is recorded as failed in the options page; the other parts keep
  running.
- `content` scripts run in the top frame of a tab whose address matches one of
  `matches` (`*` matches anything) once the page has loaded, via
  `tabs.executeScript`.

### Building a bundle

`denbox.lib.mkBundle pkgs parts` builds the file from parts given as files,
the same shape with paths in place of text:

```nix
bundle = denbox.lib.mkBundle pkgs {
  notes = {
    background = ./browser/notes/background.js;
    content = [{ matches = [ "https://*.example.com/*" ]; js = ./browser/notes/content.js; }];
    pages.notes = { html = ./browser/notes/notes.html; js = ./browser/notes/notes.js; };
  };
};
```

The source repository exposes it, say as `packages.${system}.bundle`, and
commits the built file, so the URL serves it as is:
`nix build .#bundle && cp result browser/bundle.json`. Its CI fails when the
committed file is not what the parts build, for example with a check

```nix
checks.${system}.bundle = pkgs.runCommand "bundle-is-built" { } ''
  diff ${bundle} ${./browser/bundle.json} && touch $out
'';
```

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
| `address` | the box address, without a trailing `/` |
| `api(path)` | `GET` of the box API; answers the parsed JSON |
| `api(path, body)` | `POST` of `body` as JSON |
| `hold(reason)` | background only: keeps the extension from reloading (a bundle update or a new version on disk) until the returned function is called |

`api` throws with the server's `error` on a reply that is not 2xx. What it
answers is data from the box: put it into a page as text, never as markup,
a URL or code. `hold` is for work a reload would cut short, such as a
recording.

A part's background starts once per start of the extension, so it should not
wait for `runtime.onInstalled` or `onStartup`. It keeps its storage under its
own prefix (`<part>:`) and leaves `denbox:*` alone.

### Pages

A page opens at `page.html#PART/PAGE`. Its `html` is parsed into the page
(`<head>` and `<body>` children; `<title>` becomes the tab's title) on top of
the extension's `stock.css`. Inline `<script>` does not run: the page's code
is its `js`. Anything after `#PART/PAGE/` is the page's own; the page reloads
when the hash changes.

**Popup.** The toolbar popup lists the panel, then every page of every running
part, named by its `<title>` (else `PART/PAGE`), and opens the chosen one in a
new tab. A part shows up in the popup by having a page.

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
| `denbox:address` | the box address |
| `denbox:sources` | `[{ url, token? }]` |
| `denbox:bundles` | `{ URL: text }`, the bundle each source last gave |
| `denbox:status` | `{ URL: { checkedAt, error? } }` of the last check |
| `denbox:started` | `{ at, parts: [{ source, name, state, error? }] }`, state `starting`, `running`, `failed` or `skipped` |
| `denbox:check` | written by the options page to check now |

## Tests

```sh
node --test 'extension/tests/*.test.cjs'
```

`tests/harness.cjs` runs the background scripts in a node context with a fake
`chrome` and `fetch`. `tests/panel.test.cjs` runs the panel against a fake DOM
that refuses markup.
