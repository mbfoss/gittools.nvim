# gittools.nvim

A git-backed front end for Neovim's native diff facilities. Everything lives
under a single `:GitTool` command.

| command | what it does |
| --- | --- |
| `GitTool diff [--staged] [<rev> [<rev>]]` | directory diff: file list + side-by-side layout |
| `GitTool diffpaths <a> <b>` | diff two files or two directories off disk (no repo needed) |
| `GitTool diffthis [<rev>]` | diff the current buffer, including unsaved edits |
| `GitTool log [<opt>...] [<rev>] [-- <path>]` | browse commit history as an interactive list |
| `GitTool graph [<opt>...] [<rev>] [-- <path>]` | like `log`, with the commit tree drawn alongside it |
| `GitTool stashlist` | browse `git stash list` the same way as `log` |
| `GitTool blame` | annotate the current buffer in a scroll-bound sidebar |
| `GitTool merge [<file> \| $LOCAL $BASE $REMOTE $MERGED]` | resolve merge conflicts inline |

The views that want room -- `diff`, `diffpaths`, `log`, `graph`, `stashlist` --
open in a tab of their own rather than carving up the windows you already have.
The current tab is reused only when it is a single window holding an empty,
unnamed buffer, i.e. an editor you haven't used yet. Closing such a view closes
the tab with it, putting you back exactly where you launched it from.
`diffthis`, `blame` and `merge` are about the buffer you're in, so they stay in
the current tab.

## `GitTool log` and `GitTool graph`

Both open the history in a tab of its own, one commit per line, and both take an
optional revision to start from and an optional path to scope to:

```vim
:GitTool log                      " history from HEAD
:GitTool graph v1.2.0             " ...starting at a tag
:GitTool graph -- lua/gittools    " ...only commits touching a path
```

Anything else starting with `-` is a `git log` option, handed to git as
written, so the usual revision selection and filtering works here too:

```vim
:GitTool graph --all              " every branch, tag and remote, not just HEAD
:GitTool graph --branches --remotes --no-merges
:GitTool graph --all -n 2000      " raise the 500-commit default cap
:GitTool log --author=Ren --since=2.weeks main..dev -- lua/
```

Completion offers the common ones (`--all`, `--branches`, `--remotes`,
`--tags`, `--first-parent`, `--merges`, `--no-merges`, `--author=`, `--grep=`,
`--since=`, `--until=`, `-n`, ...) alongside the ref names. Options that
replace the one-line-per-commit output -- `--pretty`, `--format`, `--oneline`,
`--stat`, `--patch`, `--name-status`, `-z` and friends -- are rejected with a
message rather than silently producing an unreadable buffer, as is `--graph`
itself (gittools draws the rails). `--reverse` works in `log`; `graph` rejects
it, since the layout needs children before parents. Anything git doesn't
recognise comes back as git's own error.

In either view `<CR>` diffs the commit under the cursor against its first
parent (a root commit against the empty tree), `c` flags a commit -- and if
another one was already flagged, diffs the two straight away -- `K` shows the
commit's details (header, message and diffstat) in a float, and `q` closes
the view. `GitTool stashlist` is the same view over `git stash list`, with each
entry labelled by the `stash@{N}` selector you would type at `git stash
apply/pop/drop`.

The history stays open behind the diffs it launches: the diff gets a tab of its
own, so `q` there lands you back on the same commit, ready to open the next one.

`graph` adds the commit tree in front of each commit and the ref names after
the author. The rails are drawn by gittools rather than by `git log --graph`,
in box-drawing glyphs with rounded corners, and each rail is coloured by the
column it occupies so two branches side by side stay easy to tell apart:

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

Commits come out in topological order (what `git log --graph` uses too), which
keeps a branch's commits in one unbroken run instead of interleaving them with
whatever else was committed the same week. Scoping to a path turns on git's
parent rewriting, so the rails still join up across the commits that the path
filter dropped. Either view loads at most 500 commits unless you pass an `-n`/`--max-count` of
your own; rails whose next commit falls past that limit simply run off the
bottom.

### Highlights

The rail colours are `GitToolsGraph1` through `GitToolsGraph6`, cycled by
column. They link to sensible defaults and can be overridden by a colorscheme.

## `GitTool diffpaths`

Diffs two arbitrary paths off disk in the same file-list + side-by-side layout
as `GitTool diff`, with no repository involved. Both paths must be the same
kind:

```vim
:GitTool diffpaths old/config.lua new/config.lua   " two files
:GitTool diffpaths ./before ./after               " two directories
```

Two files open straight into the diff. Two directories are compared recursively
(via `git diff --no-index`) and every differing file becomes a row in the list,
with added/deleted files showing an empty pane on the missing side. It completes
paths, so `:GitTool diffpaths <Tab>` works.

The two-argument form is also git's difftool calling convention, so gittools can
serve as your `git difftool`:

```ini
[difftool "gittools_diff"]
    cmd = nvim -c \"GitTool diffpaths $LOCAL $REMOTE\"
[diff]
    tool = gittools_diff
```

Then `git difftool` opens each changed file in the layout, and `git difftool -d`
(directory mode) opens the whole change set at once.

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
they work on any conflicted file in the repo. The single-file form is handy for
jumping straight to a conflict from a file list without opening it first (it
completes paths, so `:GitTool merge <Tab>` works).

The four-argument form is git's classic mergetool calling convention. To use it
as your mergetool:

```ini
[mergetool "gittools_merge"]
    cmd = nvim -c \"GitTool merge $LOCAL $BASE $REMOTE $MERGED\"
    trustExitCode = false
[merge]
    tool = gittools_merge
```

Then `git mergetool` opens each conflicted file in turn.

`trustExitCode = false` matters here. This view never writes `$MERGED` for you --
resolving is an edit and `:w` is how it lands -- so quitting with `:q` leaves the
file untouched and exits 0. With `trustExitCode = true` git would read that 0 as
"resolved" and stage the file with its conflict markers still in it. With it
`false`, git instead checks whether the file actually changed: if you saved, it
accepts the resolution silently; if you didn't, it tells you

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

These are buffer-local to `$MERGED`, but note that while they are active a bare
`x` (delete character) waits `'timeoutlen'` to see whether one of them follows.

Accepting only edits the buffer -- save with `:w` as usual. Nothing here stages
or checks out; `git mergetool` stages `$MERGED` itself on exit.

### Base text

`xa` needs the common ancestor. If you set

```ini
[merge]
    conflictStyle = zdiff3
```

git writes the base into the conflict markers itself and `xa` reads it straight
from the buffer. Otherwise gittools recovers it by re-merging the three inputs
with `git merge-file --diff3`, matching conflicts by position. That
correspondence only holds while the file's conflicts still line up with a fresh
merge, so once you have hand-edited or resolved some regions `xa` declines
rather than paste in text from the wrong place. `zdiff3` is the more reliable
setup. An add/add conflict has no ancestor at all, so `xa` never applies there.

### Highlights

All link to sensible defaults and can be overridden by a colorscheme:
`GitToolsMergeCurrent`, `GitToolsMergeIncoming`, `GitToolsMergeBase`,
`GitToolsMergeMarker`, `GitToolsMergeLabel`.
