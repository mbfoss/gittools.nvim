# gittools.nvim

A git front end built entirely on Neovim's **native** diff facilities — no
external diff tool, no floating-window framework. One command, five
subcommands:

```
:GitTool diff [--staged] [<rev> [<rev>]]
:GitTool diffthis [<rev>]
:GitTool log [<rev>] [-- <path>]
:GitTool graph [<rev>] [-- <path>]
:GitTool blame
```

Requires Neovim >= 0.10.

## Subcommands

### `:GitTool diff`

Directory-level diff in a dedicated tab: a location list of changed paths
(owned by the right diff window) drives a side-by-side native diff (left:
base, right: target). Navigate the location list (`:lnext` / `:lprev` from
the right window, or `<CR>` in the location-list window) and the diff panes
follow. Each invocation opens its own tab; existing diff tabs stay open.

| Invocation | Compares |
|---|---|
| `:GitTool diff` | index ↔ working tree |
| `:GitTool diff --staged [<rev>]` | `<rev>` (default `HEAD`) ↔ index |
| `:GitTool diff <rev>` | `<rev>` ↔ working tree |
| `:GitTool diff <rev> <rev>` | first ↔ second |

When the working tree is the right side, untracked files and files whose only
changes are unsaved buffer edits are included too. Closing either diff window
(or the tab) tears the whole session down.

### `:GitTool diffthis`

Single-file diff of the **current buffer** — including unsaved edits — against
its git version, using `:diffthis` in a side split. The git side (default: the
index; pass a revision to compare against that instead) is a read-only scratch
buffer on the left; the live buffer stays on the right, so the diff tracks
your edits as you type. Close either window to end the diff.

### `:GitTool log` and `:GitTool graph`

Interactive commit history in a bottom split, starting from `<rev>` (default
`HEAD`) and optionally limited to commits touching `<path>`. `log` is a flat
list; `graph` prefixes each commit with `git log --graph`'s rail drawing, so
branch and merge topology stays visible.

| Key | Action |
|---|---|
| `<Tab>` | flag / unflag the commit under the cursor |
| `gd` | diff: flagged commit ↔ commit under cursor, or commit ↔ its first parent when nothing is flagged |
| `q` | close the log |

Diffs open through `:GitTool diff` in their own tab, so the log stays put for
further browsing.

### `:GitTool blame`

Annotates the current buffer with per-line commit info (short hash, date,
author) in a scroll-bound sidebar. The buffer's **live** contents are blamed
(`git blame --contents -`), so unsaved edits stay line-aligned and show up as
`Not committed`. Moving the cursor in the sidebar echoes the commit's summary
line.

| Key | Action |
|---|---|
| `<CR>` | diff the commit under the cursor against its parent |
| `q` | close the sidebar |

Editing the file closes the sidebar automatically (the alignment would go
stale).

## Install

It is a normal `packadd`-style plugin. With the built-in package system:

```sh
git clone <repo-url> ~/.config/nvim/pack/plugins/opt/gittools.nvim
```

```lua
vim.cmd.packadd("gittools.nvim")
require("gittools").setup()
```

`setup()` takes no options; it just registers the `:GitTool` command (with
completion for subcommands, revisions, and paths).
