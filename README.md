# scripts

Small scripts for the sway desktop and for development. They are linked into `~/.local/bin`
(`ln -sfn ~/Projects/scripts/NAME ~/.local/bin/NAME`).

## Desktop

| Script | What it does |
|---|---|
| `statusbar`, `statusbar-refresh` | The swaybar status line (with the temperature, the number of dnf updates and the countdown of `timer`), and a way to redraw it (or show every module) at once |
| `lock-screen` | Lock with a blurred snapshot of the screen |
| `lid-handler` | Lid open/close and docking: switch the laptop panel off when docked |
| `privacy-status` | Says whether the microphone, the camera or a screen share is in use; the status bar shows an icon for each |
| `presentation-mode` | Toggle do-not-disturb, night light and idle lock |
| `timer` | A countdown (`timer 25m [label]`, `timer stop`): shown in the status bar, with a notification when it ends |
| `scale-step` | Make the display bigger or smaller (`reset` goes back) |
| `minimize-all` | "Show desktop": windows to the scratchpad and back |
| `dropdown-terminal` | Toggle the terminal that lives in the scratchpad |
| `screen-record` | Start or stop a recording (`region` or `full`) |
| `wallpaper-cycle` | Rotate the wallpaper; `SIGUSR1` skips to the next one |
| `battery`, `battery-warn` | Battery text for the bar, and the low-battery notifications |

## Pickers (fuzzel)

`audio-menu`, `bluetooth-menu`, `wifi-menu`, `bookmarks`, `calculator`, `file-finder`,
`keybindings-help`, `power-menu`, `power-profile`, `quick-note`, `web-search`, `window-switcher`.
Most take `--print` to list what the menu would show.

`emoji-picker`, `gif-picker` and `clipboard-history` use rofi (`~/.config/rofi/onedark.rasi`, keys in `config.rasi`)
instead of fuzzel, because fuzzel cannot draw colour emoji or pictures.

- `gif-picker` searches Giphy and shows the results as a grid. A small floating mpv window plays the highlighted GIF (it
  needs a rule in the sway config, see the top of the script). Enter puts the GIF on the clipboard as a picture by its
  address (that is what Teams in Firefox accepts), Shift+Enter puts the link to its Giphy page there. It needs a Giphy
  API key, in the environment, the keyring or `~/.config/gif-picker/config`.
- `clipboard-history` lists what cliphist has kept, newest first. Images and GIFs have a small picture, Alt+i shows a
  grid of just the images, and Alt+d deletes the highlighted entry from the history.

## Development

| Script | What it does |
|---|---|
| `compiler FILE` | Build and/or run a file depending on its extension |
| `formatter FILE` | Format a file (C only) |
| `sloc FILE` | Count the lines that are not blank |
| `prof`, `bench`, `bench-new` | Profiling and benchmarking; see `PROFILING.md` |
| `bib-add` | Add a book to the bibliography by ISBN or by searching Open Library |
| `ado` | Azure DevOps at a glance via `az login`: pull requests (also the ones a team of yours has to review), failed runs, your work items, creating a branch for a work item (pick the item with fzf when you give no number), voting on and reading the comments of a pull request, re-running a failed run, changing the state of a work item, creating work items (also a task under an item) and looking at the sprint of your team, creating a pull request from a branch or a work item, replying to and resolving comment threads, auto-complete, undoing the last vote or state change, starting work on an item (branch, state and a terminal on the branch in one go), attaching a file or a GIF to a work item or a pull request, why a run failed (the cause, picked out of its log, also as a fuzzel list), notifications for new reviews, votes, comments and failed runs (with the cause) that open their page when clicked, and a fuzzel menu with all of it (Enter for actions, search for work items, recent picks first) |
| `notification-history` | Browse the notifications mako has dismissed in fuzzel; picking one copies its text, or opens its page when it has one (the ones `ado` sends: a failed run, a review that is asked, ...) |
| `bug-report` | Record an area of the screen as a GIF (or with `--shot` take a picture of it) and make a Dev Bug of it under a work item of yours: not assigned, in the work item's sprint, with the file attached and a description of what you were looking at (the branch and commit of your clone, the window, the screen, the area); you see that before you say yes. Run it to choose the work item and the area, run it again to stop and type the title. A GIF over 15 MB is replaced by the video, as a link |
| `teams` | A small Teams client on Microsoft Graph: chats, unread, read, send. Needs an Entra app registration (see its header) |
| `recurring` | Turn the rules in `~/Notes/recurring.md` (`weekly sun \| text`, `monthly last \| text`) into todos with a deadline for the next 14 days; run daily by a systemd user timer. `--dry` shows what it would add |
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
