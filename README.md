# scripts

Small scripts for the sway desktop and for development. They are linked into `~/.local/bin`
(`ln -sfn ~/Projects/scripts/NAME ~/.local/bin/NAME`).

## Desktop

| Script | What it does |
|---|---|
| `statusbar`, `statusbar-refresh` | The swaybar status line, and a way to redraw it (or show every module) at once |
| `lock-screen` | Lock with a blurred snapshot of the screen |
| `lid-handler` | Lid open/close and docking: switch the laptop panel off when docked |
| `privacy-status` | Says whether the microphone, the camera or a screen share is in use; the status bar shows an icon for each |
| `presentation-mode` | Toggle do-not-disturb, night light and idle lock |
| `scale-step` | Make the display bigger or smaller (`reset` goes back) |
| `minimize-all` | "Show desktop": windows to the scratchpad and back |
| `dropdown-terminal` | Toggle the terminal that lives in the scratchpad |
| `screen-record` | Start or stop a recording (`region` or `full`) |
| `wallpaper-cycle` | Rotate the wallpaper; `SIGUSR1` skips to the next one |
| `battery`, `battery-warn` | Battery text for the bar, and the low-battery notifications |

## Pickers (fuzzel)

`audio-menu`, `bluetooth-menu`, `wifi-menu`, `bookmarks`, `calculator`, `emoji-picker`, `file-finder`,
`keybindings-help`, `power-menu`, `power-profile`, `quick-note`, `web-search`, `window-switcher`.
Most take `--print` to list what the menu would show.

## Development

| Script | What it does |
|---|---|
| `compiler FILE` | Build and/or run a file depending on its extension |
| `formatter FILE` | Format a file (C only) |
| `sloc FILE` | Count the lines that are not blank |
| `prof`, `bench`, `bench-new` | Profiling and benchmarking; see `PROFILING.md` |
| `bib-add` | Add a book to the bibliography by ISBN or by searching Open Library |
| `ado` | Azure DevOps at a glance via `az login`: pull requests (also the ones a team of yours has to review), failed runs, your work items, and creating a branch for a work item (pick the item with fzf when you give no number) |
| `teams` | A small Teams client on Microsoft Graph: chats, unread, read, send. Needs an Entra app registration (see its header) |
| `stow DIR` | Link every item of `DIR` into the current folder |

## Conventions

- The first lines say what the script does and how to call it, including the environment variables
  that change it. `prof` and `bench` print that block for `--help`.
- A picker keeps what the menu shows (`entries`) next to what each entry does (`actions`), at the same
  index, and has `--print` to list the entries without showing the menu.
- Anything longer than a few lines is a function, and the main flow is at the bottom.
- Control flow is `if` and `case`, not `cmd && { ...; }` chains. Quote variables.
- Icons are the Nerd Font characters, or a named constant with its code point when the script has several.
- State that does not survive a reboot goes in `$XDG_RUNTIME_DIR`.
- A change should keep the output the same. Check it by running the old and the new version on the
  same input (the `--print`, `--dry` and `--eval` modes make that easy).
