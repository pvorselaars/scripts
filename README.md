# scripts

Small scripts for sway and for development, linked into `~/.local/bin`. The top of each script says what it does and
how to call it.

## Desktop

| Script | What it does |
|---|---|
| `statusbar`, `statusbar-refresh` | The swaybar status line, and a way to redraw it |
| `lock-screen` | Lock with a blurred snapshot of the screen |
| `lid-handler` | Lid and docking: switch the laptop panel off when docked |
| `privacy-status` | Whether the microphone, the camera or a screen share is in use |
| `presentation-mode` | Toggle do-not-disturb, night light and idle lock |
| `timer` | A countdown in the status bar (`timer 25m [label]`, `timer stop`) |
| `scale-step` | Make the display bigger or smaller (`reset` goes back) |
| `minimize-all` | "Show desktop" |
| `dropdown-terminal` | Toggle the terminal in the scratchpad |
| `screen-record` | Start or stop a recording (`region` or `full`) |
| `wallpaper-cycle` | Rotate the wallpaper; `SIGUSR1` skips to the next one |
| `battery`, `battery-warn` | Battery text for the bar, and low-battery notifications |

## Pickers

Most take `--print` to list what the menu would show.

- fuzzel: `audio-menu`, `bluetooth-menu`, `wifi-menu`, `bookmarks`, `calculator`, `file-finder`,
  `keybindings-help`, `power-menu`, `power-profile`, `quick-note`, `web-search`, `window-switcher`,
  `notification-history`
- rofi, because fuzzel cannot show colour emoji or pictures: `emoji-picker`, `gif-picker` (needs a Giphy API key),
  `clipboard-history`

## Development

| Script | What it does |
|---|---|
| `compiler FILE` | Build and/or run a file, depending on its extension |
| `formatter FILE` | Format a C file |
| `sloc FILE` | Count the lines that are not blank |
| `prof`, `bench`, `bench-new` | Profiling and benchmarking, see `PROFILING.md` |
| `bib-add` | Add a book to the bibliography by ISBN or by searching Open Library |
| `ado` | Azure DevOps from the terminal: pull requests, failed runs, work items, notifications |
| `bug-report` | Record a GIF of the screen and make a Dev Bug of it under one of your work items |
| `teams` | A small Teams client: chats, unread, read, send (needs an Entra app registration) |
| `recurring` | Turn the rules in `~/Notes/recurring.md` into todos, run every morning by a systemd timer |
| `stow DIR` | Link every item of `DIR` into the current folder |

## Conventions

- A picker keeps what the menu shows (`entries`) next to what each entry does (`actions`), at the same index.
- Anything longer than a few lines is a function, and the main flow is at the bottom.
- Control flow is `if` and `case`, not `cmd && { ...; }`. Quote variables.
- State that does not survive a reboot goes in `$XDG_RUNTIME_DIR`.
- A change should keep the output the same. Run the old and the new version on the same input to check (`--print`,
  `--dry` and `--eval` help).
