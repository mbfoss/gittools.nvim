# Development

Internals of gittools.nvim: how the modules fit together, and why the odd
parts are the way they are. For usage, see [README.md](README.md).

## Layout

```
plugin/gittools.lua          version guard (nvim >= 0.10) + lazy :Gittools
lua/gittools/init.lua        :Gittools registration, argument parsing, completion
lua/gittools/diff.lua        git-backed file list for `diff`
lua/gittools/diffpaths.lua   path-backed file list for `diffpaths`
lua/gittools/diffthis.lua    single-buffer diff against a git version
lua/gittools/log.lua         `log`, `logthis`, `graph`, `stashlist`, `reflog`
lua/gittools/blame.lua       `blame`
lua/gittools/merge.lua       `merge`
lua/gittools/util/
    diffsession.lua          the side-by-side diff engine
    git.lua                  git plumbing: run git, resolve roots/revs/paths
    ui.lua                   tab claiming, scratch buffers, window teardown
    usercmd.lua              user-command registration + subcommand completion
    hover.lua                LSP-style floating preview
    keyhelp.lua              `g?`: a view's keys, listed in a hover
```

Loading:

- `init.lua` owns argument parsing and completion only; every feature has its
  own module, and it has no load-time side effects.
- `plugin/gittools.lua` is the only module read at startup. It registers
  `:Gittools` through `util/usercmd` (completion dispatcher, which knows nothing
  about the subcommands); the run callback takes its arguments from `opts.fargs`.
- Its run / completion callbacks `require("gittools")` at call time, so
  `init.lua` and the feature modules load on the first `:Gittools` (or first
  `<Tab>`).
- No `setup()`: registration belongs to `plugin/`, which every loading path
  reaches, including `packadd!` during startup (its bang only suppresses
  sourcing at that moment). A `packadd!` *after* startup never sources
  `plugin/`; use plain `packadd` there.

## The diff session engine

`util/diffsession.lua` is the one owner of windows and buffers for the
side-by-side views. Input: a flat list of `GitTools.DiffItem`, each with a
status letter and a `GitTools.Side` per side describing *how to fetch the
content*, not the content:

| Side field | content source |
| --- | --- |
| `rev` | `git show <rev>:<rel>` |
| `index` | `git show :<rel>` |
| `worktree` | the live buffer / file |
| `path` | an absolute path read off disk (no repo needed) |

- `gittools.diff` builds items from a git comparison, `gittools.diffpaths` from
  two filesystem paths; neither knows about windows, and the engine knows
  nothing about where items came from.
- New sources of "a list of changed files" belong as another front end, not
  another layout.
- `opts.title` is the one thing the front end still words: the two labels for
  the list window's winbar, composed left `→` right by the engine (which owns
  the arrow and escapes `%`, the winbar being a statusline string). Only the
  front end can name its sides -- a revision's branch/tag/hash for `diff`, the
  two trees for a `diffpaths` directory -- so the engine takes the finished
  words rather than deducing them from the items.

### Sessions and tabs

- A session is identified by its tabpage: `_sessions` holds every live one,
  `_current_session()` looks up by the current tab.
- That is sound because `ui.claim_tab()` only reuses a tab that is a single
  window over a blank, unnamed, unmodified buffer, so two sessions never share
  a tab. Multiple sessions exist because `c` on a submodule row opens a diff
  from inside a diff.
- `owns_tab` records whether the session created its tab. Teardown closes a tab
  it opened, or collapses a reused one back to one window, restoring the
  launching layout either way.
- Teardown is wired to `WinClosed` on the left pane, right pane and file list,
  and to `BufDelete`/`BufWipeout` on the list buffer: closing any one collapses
  the session.
- Those callbacks `vim.schedule` the teardown; closing further windows
  synchronously from inside `WinClosed` breaks Neovim's mid-close bookkeeping
  (E445).
- `setting_up` / `closing` are reentrancy guards; `shown_line` makes a repeat
  setup for the on-screen entry a no-op.
- `opts.refresh` gives the engine a way to rebuild its items from the original
  comparison. `:Gittools refresh` re-collects, rewrites the list in place, and
  keeps the shown path where it survives; an empty result closes the session.

### `]f` / `[f`

- Set once globally at module load, not per buffer: the right pane can hold the
  user's own worktree buffer, so buffer-local maps would leave strays behind.
- Outside a session they are a no-op, which makes claiming them globally cheap.
- `f` rather than `c` so the builtin `]c` / `[c` (next/previous hunk) keeps
  working.

### `git difftool -d` (`diffpaths.lua`)

- Dir-diff mode hands the tool two `mkdtemp` trees
  (`git-difftool.XXXXXX/left`, `/right`) whose names carry nothing about the
  comparison, and git exports no variable naming the revisions -- only
  `GIT_DIFFTOOL_DIRDIFF`. There is nothing honest to label the list with, so
  under that variable it gets no winbar at all, rather than one made of temp
  paths.

## `util/git.lua`

All git plumbing, no UI. Every question is "which repository is this path in,
and what does it say", answered by the `cwd` each command runs in.

- `_SCOPING_VARS` (`GIT_DIR`, `GIT_WORK_TREE`, `GIT_INDEX_FILE`, ...) are
  stripped from the environment: git exports them when launching a
  difftool/mergetool, and with `GIT_DIR` set
  `git -C <submodule> rev-parse --show-toplevel` reports the *parent* worktree,
  making a submodule look like no repository at all.
- The environment is rebuilt only when one of those is actually set; otherwise
  plain `{ text = true, cwd = cwd }`.

## Argument parsing

`init.lua` mirrors git's command line rather than inventing a syntax:

- `_split_sep` splits at a literal `--` and returns a third `found` flag: an
  empty "after" list alone cannot distinguish a trailing `--` from no separator.
- `_parse_flags` pulls `--staged` / `--cached` out of the positionals.
- `_split_opts` (log/graph) treats anything starting with `-` as a git option,
  consuming the next argument as its value when the flag is in
  `_LOG_VALUE_OPTS` (`-n 20`, `--author Ada`) so the value isn't taken for a
  revision. Glued short forms (`-n20`) need no entry.

Without a `--`, revision/path disambiguation is deferred to `gittools.diff`,
which knows the repo:

- leading arguments resolving to a tree-ish are revisions;
- everything from the first non-revision on is a pathspec;
- an argument that is neither a known revision nor an existing path is
  rejected, mirroring git, which demands an explicit `--` in exactly that case.

`util/usercmd.lua` handles registration and per-subcommand completion. Its
`_split_args` honours shell-style quoting, since git hands a mergetool
pre-quoted paths (`cmd = ... "$LOCAL" "$MERGED"`), so paths with spaces
survive.

## log / graph

Both run one `git log` with a fixed `--pretty=format:` and parse it. The
command's arguments are captured in a `fetch` closure stored on the session, so
`:Gittools refresh` re-runs the same query in place.

- `_rejected_opt` rejects options which replace or extend the format
  (`--pretty`, `--format`, `--oneline`, `--stat`, `--patch`, `--name-status`,
  `-z`) up front: they would produce an unparseable buffer.
- `--graph` is rejected because the rails are drawn here.
- `--reverse` is rejected in `graph` only: the layout walks children before
  parents, and reversed, every commit would open a rail of its own.
- `_is_plain_rev` decides whether a revision can be validated up front; ranges
  (`a..b`, `a...b`) and exclusions (`^a`) are left for git to report on.

### reflog

- Identity is the selector (`HEAD@{N}`), not the hash: one commit can appear on
  several entries, so `line_of` and `marked` key on `entry.ref or entry.hash`.
- The date comes from `%gd` under `--date=format:`. On a reflog entry `%ad` and
  `%cd` are the pointed-at commit's, so a reset to a 2020 commit would be dated
  2020; `%gd` is the only place the entry's own time appears.
- `<CR>` with nothing marked diffs against the entry below (`prev_diff`), not the
  first parent: the state before that event. Repeats are stepped over.
- Options are an allowlist (`_REFLOG_OPTS`) rather than a denylist: `-n` and
  `--since` only, since the `@{N}` index is derived from list position and
  `--until` would shift it.

### Rail layout (`_layout`)

`cols[i]` is the hash the rail in column `i` waits for, `false` for a free
column. Walking commits in topological order:

- each commit takes the leftmost column waiting for it, or a fresh one (a tip
  nothing has referenced yet; `_free_col` reuses holes, keeping the graph
  narrow);
- its first parent inherits that column, further parents open new ones;
- every other column waiting for it is a branch merging in, and ends there.

Three row kinds result: a commit row (dot plus a vertical through every other
live column), an optional link row above it where merged branches curve back
in, and an optional link row below a merge where extra parents curve out.
Glyphs come from `_box(up, down, left, right)`, keyed by which sides of the
cell connect, with rounded corners.

- The graph passes `--topo-order` and `--parents`, what `--graph` itself turns
  on; `--parents` enables parent rewriting so rails join across commits a path
  filter dropped.
- Rail colours cycle by column and are re-defined on every graph, since
  `:colorscheme` clears highlight groups.
- The 500-commit cap (`_LIMIT`) applies unless the user passes `-n` /
  `--max-count`; rails whose next commit falls past it run off the bottom.

## Submodules

- A submodule is a gitlink: its two sides are a pair of commit ids, while what
  changed is a whole repository one level down.
- `<CR>` shows the id pair (what git shows); `c` calls `diff.diff_submodule`
  for a second, independent session over the submodule, in its own tab.
- `git difftool -d` cannot check a submodule out into its temp trees and writes
  it as a one-line file, `Subproject commit <sha>`, with an all-zero id for
  whichever side is the live working tree.
- `_GITLINK_LINE` in `diffpaths.lua` matches exactly that (read only for files
  small enough to be that single line), and the submodule is resolved back to
  the real repository the command ran in, so `c` behaves as in `Gittools diff`.

## blame

- The sidebar and the file window are scroll- and cursor-bound.
- The session is a stack of levels: `stack[1]` is the live buffer, blamed
  through `--contents -`; each `R` pushes a read-only copy of the file at the
  `previous` commit `--line-porcelain` reports for the line (the parent the
  blame passed through, and the file's path there, which is how renames are
  followed). `<BS>` pops one.
- History copies are `bufhidden=hide`, not `wipe`: one covered by a later level
  has to survive for `<BS>`. They are deleted when popped or at teardown.
- `shown_buf` is the buffer the file window should show at the current level,
  and the `BufWinLeave` check compares against it rather than the live buffer,
  since `R` / `<BS>` swap the window's buffer themselves.
- `_pop` clears a level's autocmds before deleting its copy, so the deletion
  doesn't read as the user closing it.
- The sidebar's autocmds and mappings read the cursor through `_sidebar_lnum`,
  which names the sidebar window: they can fire while the user is in another
  window, where no cursor is ours to read.
- `blame()` captures the window alongside the buffer and re-asserts it before
  splitting, so the split lands there and no window else is touched.

## merge

Three entry points, one implementation:

- the four-file mergetool convention;
- a single file, the other three sides recovered from its index stages;
- the current buffer, or, when that isn't conflicted, one picked from
  `git diff --diff-filter=U` through `vim.ui.select`.

The view is `$MERGED` itself: a normal, editable, saveable buffer with conflict
regions painted as Current / Base / Incoming bands.

- As read-only toward git as the rest of the plugin: accepting a side only
  edits the buffer, `:w` lands it, `git mergetool` stages `$MERGED` on exit.
- That division is what makes `trustExitCode = false` right: quitting without
  saving exits 0, and only git's own "did the file change" check keeps
  unresolved markers from being staged.

`xa` (accept base) needs the common ancestor:

- Under `conflictStyle = zdiff3` git writes it into the markers and it is read
  straight from the buffer.
- Otherwise it is recovered by re-merging the three inputs with
  `git merge-file --diff3`, matching conflicts *by position*, a
  correspondence holding only while the buffer's conflicts still line up with a
  fresh merge, so once regions are hand-edited or resolved `xa` declines rather
  than paste text from the wrong region.
- An add/add conflict has no ancestor at all.

## Highlights

Every group is defined with `default = true` so a colorscheme wins.

- `diffsession` status letters link to `Diagnostic*`, not `Diff*`: the `Diff*`
  groups are mostly background fills meant for whole lines, which on a single
  status character read as an easy-to-miss coloured speck. `Diagnostic*` are
  foreground colours and exist in any Neovim >= 0.6.
- `merge` links to `Diff*` instead, because it fills whole-line bands.
- The rename arrow is `→` (U+2192), not a Nerd Font glyph, so no patched font
  is needed.

## Demos

`demo/*.scene` are recorded by `scripts/record-demos.sh` with
[nvim-demo](https://github.com/mbfoss/nvim-demo-generator); GIFs and casts land
in `demo-out/` (ignored). The scenes run in `demo/fixture`, a throwaway
repository rebuilt by `demo/setup-fixture.sh` with fixed authors and dates, so
recordings are reproducible. The GIFs are published to the `assets` branch
under `demos/`.

## Conventions

- User-visible messages go through a module-local `_notify` that prefixes
  `[gittools]`.
- Private functions are `_`-prefixed and file-local; the module table exports
  only entry points.
- Types use LuaLS `---@class` / `---@field`; the shared shapes (`Side`,
  `DiffItem`, `DiffEntry`, `DiffSession`) are declared in
  `util/diffsession.lua`.
- Windows the plugin creates get inherited window-local options reset
  (`scrollbind`, `cursorbind`, `wrap`, `spell`, ...): a new split inherits them
  from whatever it split off of, which otherwise scroll-links a picker to a
  diff pane or spell-checks a list of hashes.
- No view maps `q`: it stays the user's (macro recording), and views close the
  way any window does.
- The plugin's views (log, diff file list, blame sidebar, `diffthis` git side)
  answer `g?` with a hover listing their keys (`keyhelp.map`), each view
  naming its own: other plugins map into these buffers too (a key-hint plugin's
  triggers), so reading every map off the buffer would list theirs as well. In
  a window too short for a hover (the diff file list) the list opens in a float
  over the window, read off the buffer's own maps when pressed, so every map
  there needs a `desc`, which is its help text. `$MERGED` gets none: `g?` is
  rot13 on a real file, and the band hints already name its keys.
- Generated buffers are `buftype=nofile` scratch buffers via
  `ui.create_scratch_buffer`, unlisted ones with `bufhidden=wipe`.
- Sessions clean themselves up on any event that could make their snapshot
  stale; for `blame` that is the file being edited, reloaded, replaced in its
  window, or deleted.
- Nothing hooks `VimLeavePre`: teardown only undoes process-local state
  (windows, scratch buffers, window-local diff options), and the merge
  tempfiles come from `vim.fn.tempname()`, whose directory Neovim removes on
  exit. `diff.clear_session()` / `merge.clear_session()` remain for an embedder
  that wants to force it.
