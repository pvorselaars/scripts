# homepage

A minimal start page for the browser: a clock, search, your open todos from the notes in `~/Notes`,
and a wallpaper. Ticking a todo writes `[x]` into the note; typing one adds it to today's note.
No dependencies: Node's standard library only.

```
            10:17
   Friday 23 October  ·  Good morning, Perry
      ________ Search or type an address ________

 Todos (10)
 ______________ Add a todo ______________
 2026-10-21
  [ ] Itemgroep meerdere keren koppelen ...
  [ ] Performance issue 61 bloksmodel
```

## Run

```
npm start                       # http://127.0.0.1:7878
npm test                        # the tests
systemctl --user enable --now homepage.service   # the unit is in the dotfiles repo
```

Settings are environment variables, all optional:

| Variable | Default | |
|---|---|---|
| `HOMEPAGE_PORT` | `7878` | |
| `NOTES_DIR` | `~/Notes` | flat folder of `.md` notes |
| `WALLPAPER_DIR` | `~/Pictures/Wallpapers` | jpg, png, webp or avif |
| `HOMEPAGE_WALLPAPER` | (none) | file name to use as the background every day, instead of the daily pick |
| `HOMEPAGE_NAME` | your user name | used in the greeting |

## Background

One image, the same on every page, tab and reload: the home page and every note view. It is chosen
once a day from the wallpaper folder (by the date, so a restart does not change it) and changes at
midnight. New wallpapers added during the day almost never change the pick. Set
`HOMEPAGE_WALLPAPER=name.jpg` to keep one image for good.

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

Text that looks like an address opens it; anything else is a DuckDuckGo search, so `!yt lofi` and `!gh sway` work. A leading `?`
forces a search.

## Todos

A todo is a line `- [ ] text` or `- [x] text` in any `.md` file directly inside the notes folder.
Today's note, then daily notes (newest first), then other notes. Ticked todos stay visible,
struck through, until the next reload, so a mis-click is easy to undo. The page refreshes when you
come back to the tab and every minute, so changes made in nvim show up.

## Wiki links and the note view

`[[selios]]` in a todo is a link to `selios.md` (telekasten style). It opens the **note view** at `/note/selios`:
the note rendered read-only, with its todos still tickable, and a **Linked from** list of every note
that links to it, with the line that does. Links to notes that do not exist yet are dimmed and dashed.

| Link | Goes to |
|---|---|
| `[[note]]` | `note.md`, found whatever the case (`[[Note]]` works too) |
| `[[note|alias]]` | the same, shown as *alias* |
| `[[note#Heading]]` | the same, scrolled to that heading |
| `[text](https://…)` | an external link (only http and https) |

The note view understands a small subset of markdown: headings, paragraphs, bullet and numbered
lists, todos, quotes, code blocks, `code`, **bold** and the links above. Everything else is shown as
plain text. `Esc` goes back to the home page. A note that links to itself is not listed in its own backlinks.

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
  point elsewhere are refused, for reading (note view, backlinks, todo list) as well as writing.
- The page is built with `textContent`, never `innerHTML`, and served with a strict
  Content-Security-Policy (no inline scripts or styles, no other origins). Text in a note cannot
  inject markup.
- The systemd unit makes everything except `~/Notes` read-only and the service cannot gain privileges.
- Every write to a note is logged: `journalctl --user -u homepage` shows what changed and when.

## Files

```
server.js         the server and the API
public/           index.html + app.js (home), note.html + note.js (note view), style.css,
                  lib.js (pure helpers, also tested in Node)
test/             node --test: todos, security, data, page logic, and app.js against the real server
```

API (all JSON): `GET /api/todos`, `GET /api/note/NAME`, `GET /api/wallpaper`,
`POST /api/todos/toggle` `{file, line, text, done}`, `POST /api/todos/add` `{text}`.
