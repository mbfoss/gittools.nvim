# gittools.nvim

A git front end built entirely on Neovim's **native** diff facilities — no
external diff tool, no floating-window framework. One command, four
subcommands:

```
:GitTool diff [--staged] [<rev> [<rev>]]
:GitTool diffthis [<rev>]
:GitTool log [<rev>] [-- <path>]
:GitTool blame
```

Requires Neovim >= 0.10.

## Subcommands

### `:GitTool diff`

Directory-level diff in a dedicated tab: a quickfix list of changed paths
drives a side-by-side native diff (left: base, right: target). Navigate the
quickfix list (`:cnext` / `:cprev` or `<CR>` in the quickfix window) and the
diff panes follow.

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

### `:GitTool log`

Interactive commit history in a bottom split. Without a path it walks the real
parent/child graph from `HEAD` (merge branches nest as collapsible lanes);
with `-- <path>` it is a flat list of commits touching that path.

| Key | Action |
|---|---|
| `<CR>` | expand / collapse a lane |
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
