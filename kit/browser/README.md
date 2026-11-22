# Browser parts

Sources of the parts the kit ships. Each directory is one part; its files map
onto the part's fields in the bundle (see `extension/README.md`):

| Part field | File |
| --- | --- |
| `background` | `<part>/background.js`, when there is one |
| `pages.<page>.html` | `<part>/<page>.html` |
| `pages.<page>.js` | `<part>/<page>.js` |

Plain HTML, CSS and JS with no build step and no dependencies: the files are
embedded into the bundle as text.

`panel` has one page, `panel`, and no background. The API module
(`kit/nix/modules/api.nix`) adds it to every box that runs `denbox-api`.

It reads `GET /state` every 3 seconds while visible and posts to
`/services/restart` and `/services/toggle`.
