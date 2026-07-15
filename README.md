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
| `GitTool merge [$LOCAL $BASE $REMOTE $MERGED]` | resolve merge conflicts inline |

## `GitTool merge`

Shows the `$MERGED` file in a normal, editable buffer with each conflict region
painted as a Current / Base / Incoming band, and adds buffer-local maps to
resolve them.

With no arguments it infers the four sides from the index stages of the current
file, so on any conflicted file you can just:

```vim
:GitTool merge
```

With four arguments it follows git's classic mergetool calling convention. To
use it as your mergetool:

```ini
[mergetool "gittools"]
    cmd = nvim -c "GitTool merge \"$LOCAL\" \"$BASE\" \"$REMOTE\" \"$MERGED\""
    trustExitCode = true
[merge]
    tool = gittools
```

Then `git mergetool` opens each conflicted file in turn.

### Maps

| key | action |
| --- | --- |
| `co` | accept **c**urrent (ours) |
| `ct` | accept incoming (**t**heirs) |
| `cb` | accept **b**oth, current first |
| `cB` | accept the common ancestor (**B**ase) |
| `]x` / `[x` | jump to the next / previous conflict |
| `cD` | toggle the `$LOCAL` \| `$MERGED` \| `$REMOTE` three-way diff |

Accepting only edits the buffer -- save with `:w` as usual. Nothing here stages
or checks out; `git mergetool` stages `$MERGED` itself on exit.

### Base text

`cB` needs the common ancestor. If you set

```ini
[merge]
    conflictStyle = zdiff3
```

git writes the base into the conflict markers itself and `cB` reads it straight
from the buffer. Otherwise gittools recovers it by re-merging the three inputs
with `git merge-file --diff3`, matching conflicts by position. That
correspondence only holds while the file's conflicts still line up with a fresh
merge, so once you have hand-edited or resolved some regions `cB` declines
rather than paste in text from the wrong place. `zdiff3` is the more reliable
setup. An add/add conflict has no ancestor at all, so `cB` never applies there.

### Highlights

All link to sensible defaults and can be overridden by a colorscheme:
`GitToolsMergeCurrent`, `GitToolsMergeIncoming`, `GitToolsMergeBase`,
`GitToolsMergeMarker`, `GitToolsMergeLabel`.
