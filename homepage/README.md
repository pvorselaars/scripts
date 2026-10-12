# homepage

A start page for the browser: clock, search, your open todos from the notes in `~/Notes`, your
Firefox bookmarks, and a wallpaper. Ticking a todo writes `[x]` into the note; typing one adds it
to today's note. No dependencies: Node's standard library only (Node 22 or newer, for `node:sqlite`).

```
10:17                    Friday 23 October
                         Good morning, Perry
              [ Search DuckDuckGo or type an address ]
 TODOS (12)                          [Code] [Figma] [GitHub] ...
 [ Add a todo to today's note ]
 2026-10-21
  [ ] Itemgroep meerdere keren koppelen ...
  [x] ...
```

## Run

```
npm start                       # http://127.0.0.1:7878
npm test                        # 40 tests
systemctl --user enable --now homepage.service   # the unit is in the dotfiles repo
```

Settings are environment variables, all optional:

| Variable | Default | |
|---|---|---|
| `HOMEPAGE_PORT` | `7878` | |
| `NOTES_DIR` | `~/Notes` | flat folder of `.md` notes |
| `WALLPAPER_DIR` | `~/Pictures/Wallpapers` | jpg, png, webp or avif; one is picked per page load |
| `FIREFOX_PROFILE` | the most recently used profile | folder containing `places.sqlite` |
| `HOMEPAGE_NAME` | your user name | used in the greeting |

## Using it as the new tab page

Firefox has no setting for a custom new-tab address.

- **Homepage and new windows:** `about:preferences#home`, then *Homepage and new windows*,
  *Custom URLs*, and enter `http://127.0.0.1:7878`.
- **New tabs:** install an add-on that overrides the new tab page (for example *New Tab Override*)
  and give it the same address. Look for its option to put the focus on the page instead of the
  address bar, so `/` and `n` work straight away.

If the service is not running the tab shows a connection error: `systemctl --user status homepage`.

## Keys

| Key | |
|---|---|
| `/` | focus the search box |
| `n` | focus the "add a todo" box |
| `Esc` | leave the box |

Typing in the search box dims the bookmarks that do not match. Text that looks like an address
opens it; anything else is a DuckDuckGo search, so `!yt lofi` and `!gh sway` work. A leading `?`
forces a search.

## Todos

A todo is a line `- [ ] text` or `- [x] text` in any `.md` file directly inside the notes folder.
Today's note, then daily notes (newest first), then other notes. Ticked todos stay visible,
struck through, until the next reload, so a mis-click is easy to undo. The page refreshes when you
come back to the tab and every minute, so changes made in nvim show up.

Writing is careful:

- The server re-reads the file and finds the todo by its **text**, not only its line number, so
  lines added in nvim in the meantime do not cause the wrong line to change. If the text is gone or
  appears twice, nothing is written and the page asks you to reload.
- Only that one line changes. Line endings (including CRLF), the trailing newline and the file mode
  are kept; the file is replaced atomically, and the write is refused if the file changed while it
  was being processed.
- Added todos go to `YYYY-MM-DD.md`, in the same format as `quick-note`.

## Security

It listens on `127.0.0.1` only and can write to your notes, so it checks every request:

- The `Host` header must be `127.0.0.1:PORT` or `localhost:PORT` (stops DNS rebinding).
- `POST` requests must be `application/json` and, when an `Origin` is sent, from this page. A web
  page on another site cannot send that, and no CORS headers are ever returned.
- Note names are limited to `.md` files directly in the notes folder; path tricks and symlinks that
  point elsewhere are refused.
- The page is built with `textContent`, never `innerHTML`, and served with a strict
  Content-Security-Policy (no inline scripts or styles, no other origins). Text in a note or a
  bookmark title cannot inject markup. Only `http(s)` bookmark links are rendered.
- The systemd unit makes everything except `~/Notes` read-only and the service cannot gain privileges.
- Firefox keeps its bookmark database locked, so it is read from a temporary copy; the original is never touched.

## Files

```
server.js         the server and the API
public/           index.html, style.css, app.js (the page), lib.js (pure helpers, also tested in Node)
test/             node --test: todos, security, data, page logic, and app.js against the real server
```

API (all JSON): `GET /api/todos`, `GET /api/bookmarks`, `GET /api/wallpaper`,
`POST /api/todos/toggle` `{file, line, text, done}`, `POST /api/todos/add` `{text}`.
