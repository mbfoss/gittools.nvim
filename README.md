# gittools.nvim

A git-backed front end for Neovim's native diff facilities, under a single
`:GitTool` command.

| command | what it does |
| --- | --- |
| `GitTool diff [--staged] [<rev> [<rev>]] [-- <path>...]` | directory diff: file list + side-by-side layout |
| `GitTool diffpaths <a> <b>` | diff two files or two directories off disk (no repo needed) |
| `GitTool diffthis [<rev>]` | diff the current buffer, including unsaved edits |
| `GitTool log [<opt>...] [<rev>] [-- <path>]` | browse commit history as an interactive list |
| `GitTool graph [<opt>...] [<rev>] [-- <path>]` | like `log`, with the commit tree drawn alongside it |
| `GitTool stashlist` | browse `git stash list` the same way as `log` |
| `GitTool blame` | annotate the current buffer in a scroll-bound sidebar |
| `GitTool merge [<file> \| $LOCAL $BASE $REMOTE $MERGED]` | resolve merge conflicts inline |

`diff`, `diffpaths`, `log`, `graph` and `stashlist` open in a tab of their own.
The current tab is reused only when it is a single window holding an empty,
unnamed buffer. Closing such a view closes the tab with it, returning you to the
window layout you launched it from. `diffthis`, `blame` and `merge` act on the
current buffer and stay in the current tab.

## Requirements

Neovim >= 0.10 and `git` on your `PATH`.

## Installation

With any plugin manager, or by dropping the repository into your package path.
There is nothing to configure and no setup call to make: `:GitTool` registers
itself when the plugin loads, and the plugin's own modules are read only when
the command is first used.

```lua
{ "gittools.nvim" }
```

From `pack/*/opt`, `packadd` it as usual:

```lua
vim.cmd.packadd("gittools.nvim")
```

`packadd!` works too when it runs during startup, since `plugin/` scripts are
sourced in the normal pass afterwards; after startup use the plain `packadd`,
which sources them itself.

## `GitTool diff`

Takes the same arguments as `git diff`: no revision compares the index against
the working tree, one compares that revision against the working tree, two
compare the revisions with each other, and `--staged` (or `--cached`) compares
`HEAD` -- or the revision you name -- against the index.

Trailing paths limit the diff to those files, exactly as on git's command line,
and are resolved relative to your current directory:

```vim
:GitTool diff                          " index vs working tree
:GitTool diff HEAD~3                   " ...against an older commit
:GitTool diff --staged                 " HEAD vs index
:GitTool diff main dev                 " two revisions
:GitTool diff lua/gittools/diff.lua    " one file, index vs working tree
:GitTool diff main dev -- lua/ README.md
:GitTool diff HEAD -- '*.lua'          " a pathspec, so it needs the --
```

The `--` is optional when the arguments can't be mistaken for revisions: each
one is taken as a revision if it names one, and as a path if it exists on disk.
A wildcard matches neither, so pass those after a `--`; without it git reports
an ambiguous argument.

Untracked files are listed whenever the working tree is the right-hand side, as
are files you have edited but not yet written, which are diffed from the buffer.
Pathspecs filter both.

The layout is a file list in a bottom split driving a side-by-side diff:

| key | action |
| --- | --- |
| `<CR>` | show the file under the cursor and jump into the diff |
| `]f` / `[f` | show the next / previous file, from anywhere in the tab |
| `o` | on a submodule row, open the submodule's own diff in a new tab |

`]f` / `[f` step through the file list of the session in the current tab, so two
diffs open at once stay independent.

A changed submodule is listed like any other entry, and `<CR>` shows it as the
pair of commit ids it points at, as git does. `o` on a submodule row opens a
second diff over the submodule itself, in a tab of its own, with the same file
list and side-by-side layout: between the commits the parent records, or against
the submodule's own working tree when that is what the parent is being compared
against, so uncommitted edits inside it show too. The session you launched from
stays open, and closing the submodule's tab returns you to it.

## `GitTool diffthis`

Diffs the current buffer -- unsaved edits included -- against its git version in
a side split, using Neovim's native diff mode. With no argument the git side is
the index; pass a revision to compare against that instead:

```vim
:GitTool diffthis
:GitTool diffthis HEAD~1
```

The git side is a read-only scratch buffer on the left; the live buffer is on
the right, so the diff tracks edits as you type.

## `GitTool log` and `GitTool graph`

Both open the history in a tab of its own, one commit per line, and both take an
optional revision to start from and an optional path to scope to:

```vim
:GitTool log                      " history from HEAD
:GitTool graph v1.2.0             " ...starting at a tag
:GitTool graph -- lua/gittools    " ...only commits touching a path
```

Anything else starting with `-` is a `git log` option, handed to git as written,
so the usual revision selection and filtering applies:

```vim
:GitTool graph --all              " every branch, tag and remote, not just HEAD
:GitTool graph --branches --remotes --no-merges
:GitTool graph --all -n 2000      " raise the 500-commit default cap
:GitTool log --author=Ren --since=2.weeks main..dev -- lua/
```

Completion offers the common ones (`--all`, `--branches`, `--remotes`,
`--tags`, `--first-parent`, `--merges`, `--no-merges`, `--author=`, `--grep=`,
`--since=`, `--until=`, `-n`, ...) alongside the ref names. Options that replace
the one-line-per-commit output -- `--pretty`, `--format`, `--oneline`, `--stat`,
`--patch`, `--name-status`, `-z` and similar -- are rejected with a message, as
is `--graph` (gittools draws the rails). `--reverse` works in `log`; `graph`
rejects it. Anything git doesn't recognise comes back as git's own error.

| key | action |
| --- | --- |
| `<CR>` | diff the commit under the cursor (against its first parent, or the marked base) |
| `c` | mark / unmark the commit under the cursor as the comparison base |
| `K` | show the commit's header, message and diffstat in a float |

`GitTool stashlist` is the same view over `git stash list`, with each entry
labelled by the `stash@{N}` selector you would type at `git stash
apply/pop/drop`.

The marked commit is drawn with a `»` in front of it:

```
●   4bebd0e 2025-06-13 Ren  (HEAD -> main) Merge pull request #40 from feat/toggle
● » 1f0a2c9 2025-06-11 Ren  Add the toggle
●   9d3e871 2025-06-10 Ren  Tidy up the option table
```

From then on `<CR>` diffs against that commit instead of against parents, so any
commit in the list can be compared with the same base. Only one commit is ever
marked: `c` elsewhere moves the mark, and `c` on the marked commit clears it,
putting `<CR>` back to parent diffs. (`<CR>` on the marked commit itself would
compare it with itself, so that one still diffs against its parent.)

The diff opens in a tab of its own and the history stays open, so closing the
diff returns you to the same commit in the list.

`graph` adds the commit tree in front of each commit and the ref names after the
author, in box-drawing glyphs, each rail coloured by the column it occupies:

```
◆   4bebd0e 2025-06-13 Ren  (HEAD -> main) Merge pull request #40 from feat/toggle
├─╮
│ ● e1817e2 2025-06-13 Ren  feat: add ClaudeCodeFocus command
├─╯
●   21f984b 2025-06-13 Ren  fix: native terminal window flags
```

`●` is an ordinary commit and `◆` one with more than one parent. A branch curves
out below the merge commit that brought it in and curves back into the commit
where it forked, so a rail spans exactly the commits that are on it.

Commits come out in topological order, as with `git log --graph`, so a branch's
commits appear in one unbroken run rather than interleaved by date. Scoping to a
path still joins the rails up across the commits the path filter dropped. Either
view loads at most 500 commits unless you pass an `-n`/`--max-count`; rails
whose next commit falls past that limit run off the bottom.

## `GitTool blame`

Annotates the current buffer with per-line commit info in a scroll-bound
sidebar. The buffer's live contents are blamed, so unsaved edits stay
line-aligned and are shown as "Not committed". Moving the cursor echoes the
commit's summary.

| key | action |
| --- | --- |
| `<CR>` | diff the commit under the cursor against its parent |
| `K` | show that commit's details in a float |

The annotations are a snapshot, so the sidebar closes as soon as they could go
stale: on either window closing, or on the file being edited, reloaded, replaced
or deleted.

## `GitTool diffpaths`

Diffs two arbitrary paths off disk in the same file-list + side-by-side layout
as `GitTool diff`, with no repository involved. Both paths must be the same
kind:

```vim
:GitTool diffpaths old/config.lua new/config.lua   " two files
:GitTool diffpaths ./before ./after               " two directories
```

Two files open directly into the diff. Two directories are compared recursively
and every differing file becomes a row in the list, with added/deleted files
showing an empty pane on the missing side. It completes paths, so
`:GitTool diffpaths <Tab>` works.

The two-argument form is also git's difftool calling convention, so gittools can
be used as `git difftool`:

```ini
[difftool "gittools_diff"]
    cmd = nvim -c \"GitTool diffpaths $LOCAL $REMOTE\"
[diff]
    tool = gittools_diff
```

Then `git difftool` opens each changed file in the layout, and `git difftool -d`
(directory mode) opens the whole change set at once. Submodules are handled
there too: they are listed as rows like any other change, and `o` opens the
submodule's own diff in its own tab, as in `GitTool diff`.

The `\"` escaping is required: git's config parser strips a plain `"..."` from
the value, which would leave nvim running a bare `GitTool` (no subcommand, so it
reports `Argument required`) and treating the paths as files to open. Escaping
keeps the quotes so the `-c` argument stays a single command.

## `GitTool merge`

Shows the `$MERGED` file in a normal, editable buffer with each conflict region
painted as a Current / Base / Incoming band, and adds buffer-local maps to
resolve them.

It takes three forms:

```vim
:GitTool merge                  " the current buffer's file
:GitTool merge path/to/file     " that file, from anywhere
:GitTool merge $LOCAL $BASE $REMOTE $MERGED
```

The first two name only `$MERGED` -- explicitly, or implicitly as the current
buffer -- and recover the other three sides from that file's index stages, so
they work on any conflicted file in the repo. The single-file form completes
paths, so `:GitTool merge <Tab>` works.

The four-argument form is git's mergetool calling convention. To use it as your
mergetool:

```ini
[mergetool "gittools_merge"]
    cmd = nvim -c \"GitTool merge $LOCAL $BASE $REMOTE $MERGED\"
    trustExitCode = false
[merge]
    tool = gittools_merge
```

Then `git mergetool` opens each conflicted file in turn.

`trustExitCode = false` matters here. This view never writes `$MERGED`;
resolving is an edit, and `:w` is what saves it, so quitting with `:q` leaves the
file untouched and exits 0. With `trustExitCode = true` git would read that 0 as
"resolved" and stage the file with its conflict markers still in it. With it
`false`, git checks whether the file actually changed: if you saved, it accepts
the resolution silently; if you didn't, it reports

```
$MERGED seems unchanged.
Was the merge successful [y/n]?
```

and leaves the conflict in place if you answer `n`.

### Maps

All conflict maps share an `x` prefix, matching the `]x` / `[x` motions:

| key | action |
| --- | --- |
| `xc` | accept the **c**urrent change (ours) |
| `xi` | accept the **i**ncoming change (theirs) |
| `xb` | accept **b**oth changes, current first |
| `xa` | accept the b**a**se (common ancestor) |
| `]x` / `[x` | jump to the next / previous conflict |
| `xd` | toggle the `$LOCAL` \| `$MERGED` \| `$REMOTE` three-way **d**iff |

These are buffer-local to `$MERGED`. Note that while they are active, a bare `x`
(delete character) waits `'timeoutlen'` to see whether one of them follows.

Accepting only edits the buffer -- save with `:w`. Nothing here stages or checks
out; `git mergetool` stages `$MERGED` itself on exit.

### Base text

`xa` needs the common ancestor. If you set

```ini
[merge]
    conflictStyle = zdiff3
```

git writes the base into the conflict markers itself and `xa` reads it from the
buffer. Otherwise gittools recovers it by re-merging the three inputs, which
only works while the file's conflicts still line up with a fresh merge: once you
have hand-edited or resolved some regions, `xa` declines rather than insert text
from the wrong region. `zdiff3` is the more reliable setup. An add/add conflict
has no ancestor, so `xa` never applies there.

## Highlights

All link to defaults and can be overridden by a colorscheme.

| group | where |
| --- | --- |
| `GitToolsStatusAdded` / `Modified` / `Deleted` / `Renamed` / `Copied` / `Untracked` | the status letter in a diff file list |
| `GitToolsRenameOldPath`, `GitToolsRenameArrow` | rename entries in that list |
| `GitToolsGraph1` .. `GitToolsGraph6` | graph rails, cycled by column |
| `GitToolsLogMark` | the `»` comparison-base marker |
| `GitToolsMergeCurrent` / `Incoming` / `Base` / `Marker` / `Label` | the merge view's bands |

## Development

See [DEVELOPMENT.md](DEVELOPMENT.md) for internals, design notes and
conventions.
