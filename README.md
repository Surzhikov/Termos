# Termos

A minimal terminal multiplexer for macOS written in Swift (AppKit + a SwiftUI sidebar).
Terminal emulation is provided by [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) v1.11.2 (MIT),
vendored in `Vendor/SwiftTerm` (no dev dependencies; the scroller is switched to overlay style).

## Build

    ./build.sh            # → build/Termos.app
    ./build.sh --install  # also copies it to /Applications
    open build/Termos.app

Only the Command Line Tools are required (no Xcode).

## Projects

Termos works in terms of **projects** (like VS Code): a project is a `.termos` file that holds
all workspaces with their terminals, split layout, colors, startup commands and frozen state.

- **File → New Project…** (⇧⌘N) — choose where to save, get a workspace with one terminal.
- **File → Open Project…** (⌘O) or double-click a `.termos` file in Finder.
- The project file is updated automatically on every change, so after a reboot just open it
  and everything comes back exactly as it was — including frozen terminals.

### Frozen terminals

Any terminal can be **frozen** (right-click → Freeze Terminal, or ⇧⌘F): its shell and everything
running in it is stopped to free memory, and the pane turns into a gray block with the terminal's
name and a **Restore** button. Restore starts the shell again and re-runs the terminal's
**Startup Command** (e.g. `claude --resume <session>`), so long-running sessions are one click away.

### Multiple windows

**File → New Window** (⌘N) opens another Termos process with its own project. Each window can
have its own project open. Terminals pass their window's id down to the programs they run, so
Claude Code started inside a pane always controls the window it lives in.

## Shortcuts

| Action | Keys |
|---|---|
| New / open project | ⇧⌘N / ⌘O |
| New window | ⌘N |
| New workspace | ⌘T |
| Split right / down | ⌘D / ⇧⌘D |
| Freeze terminal | ⇧⌘F |
| Close terminal / workspace | ⌘W / ⇧⌘W |
| Move focus | ⌥⌘ + arrows |
| Swap with neighbor | ⌃⌘ + arrows |
| Next / previous terminal | ⌘] / ⌘[ |
| Workspace 1…9 | ⌘1…⌘9 |
| Next / previous workspace | ⇧⌘] / ⇧⌘[ |
| Zoom terminal to the whole workspace | ⇧⌘↩ or double-click the header |
| Equalize sizes | ⌃⌘= or double-click a divider |
| Custom background color | ⇧⌘K |
| Rename workspace / terminal | ⇧⌘R / ⌥⌘R |
| Toggle sidebar | ⌃⌘S |
| Font bigger / smaller / reset | ⌘= / ⌘- / ⌘0 |
| Full screen | ⌃⌘F |

Color scheme, border label and rename are available from the right-click menu on a terminal,
its header or its sidebar row, and from the Terminal menu.

## Drag & drop

Drop files or folders onto a terminal to insert their shell-escaped paths (like Terminal.app).
Image data without a file (e.g. dragged from a browser) is saved to
`~/Library/Caches/Termos/Drops/` and its path is inserted. Text is sent as a bracketed paste,
so tools like Claude Code pick up dropped image paths as image attachments.
Terminals can be rearranged by dragging their headers — into another split position,
another workspace in the sidebar, or onto “New Workspace” to move one out.

## Claude Code (MCP)

`Termos --mcp` is a stdio MCP server. It talks to the running app over per-user Unix sockets
(mode 0600) and launches Termos if it isn't running. Register it once:

    claude mcp add -s user termos -- /Applications/Termos.app/Contents/MacOS/Termos --mcp

With several Termos windows open, the server picks the window automatically when Claude Code is
started inside one of its terminals, and otherwise lists the running windows with their
workspaces and asks you to pick (or set `TERMOS_INSTANCE_ID`).

Tools: `termos_list`, `termos_new_project`, `termos_open_session`, `termos_create_workspace`
(grid of columns × rows, one entry per terminal with name / cwd / command / theme / label),
`termos_add_terminal`, `termos_run`, `termos_read`, `termos_update_terminal`,
`termos_update_workspace`, `termos_focus` (with `restore: true` for frozen terminals),
`termos_freeze_terminal`, `termos_restore_terminal`, `termos_close_terminal`,
`termos_close_workspace` (both refuse while a program runs unless `force`), `termos_save_layout`,
`termos_open_layout`.

Example prompt: *"Create a workspace with a 3×2 grid and a terminal for each client in ~/clients,
named after the client."*
