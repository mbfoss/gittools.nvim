# gittools.nvim

A git-backed front end for Neovim's native diff facilities. Everything lives
under a single `:GitTool` command.

| command | what it does |
| --- | --- |
| `GitTool diff [--staged] [<rev> [<rev>]]` | directory diff: file list + side-by-side layout |
| `GitTool diffthis [<rev>]` | diff the current buffer, including unsaved edits |
| `GitTool log [<rev>] [-- <path>]` | browse commit history as an interactive list |
| `GitTool graph [<rev>] [-- <path>]` | like `log`, with `git log --graph` rail drawing |
| `GitTool stashlist` | browse `git stash list` the same way as `log` |
| `GitTool blame` | annotate the current buffer in a scroll-bound sidebar |
| `GitTool merge [<file> \| $LOCAL $BASE $REMOTE $MERGED]` | resolve merge conflicts inline |

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
[mergetool "gittools"]
    cmd = nvim -c "GitTool merge \"$LOCAL\" \"$BASE\" \"$REMOTE\" \"$MERGED\""
    trustExitCode = true
[merge]
    tool = gittools
```

Then `git mergetool` opens each conflicted file in turn.

### Maps

All conflict maps share an `x` prefix, matching the `]x` / `[x` motions:

| key | action |
| --- | --- |
| `xo` | accept **o**urs (current) |
| `xt` | accept **t**heirs (incoming) |
| `xb` | accept **b**oth, ours first |
| `xa` | accept the common **a**ncestor (base) |
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
