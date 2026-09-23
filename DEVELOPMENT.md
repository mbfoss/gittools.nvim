# Development

Internals of gittools.nvim: how the modules fit together, and why the odd
parts are the way they are. For usage, see [README.md](README.md).

## Layout

```
plugin/gittools.lua          version guard (nvim >= 0.10) + lazy :GitTool
lua/gittools/init.lua        :GitTool registration, argument parsing, completion
lua/gittools/diff.lua        git-backed file list for `diff`
lua/gittools/diffpaths.lua   path-backed file list for `diffpaths`
lua/gittools/diffthis.lua    single-buffer diff against a git version
lua/gittools/log.lua         `log`, `logthis`, `graph`, `stashlist`
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
  `:GitTool` through `util/usercmd` (argument splitter + completion dispatcher,
  which knows nothing about the subcommands).
- Its run / completion callbacks `require("gittools")` at call time, so
  `init.lua` and the feature modules load on the first `:GitTool` (or first
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

### `]f` / `[f`

- Set once globally at module load, not per buffer: the right pane can hold the
  user's own worktree buffer, so buffer-local maps would leave strays behind.
- Outside a session they are a no-op, which makes claiming them globally cheap.
- `f` rather than `c` so the builtin `]c` / `[c` (next/previous hunk) keeps
  working.

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

Both run one `git log` with a fixed `--pretty=format:` and parse it.

- `_rejected_opt` rejects options which replace or extend the format
  (`--pretty`, `--format`, `--oneline`, `--stat`, `--patch`, `--name-status`,
  `-z`) up front: they would produce an unparseable buffer.
- `--graph` is rejected because the rails are drawn here.
- `--reverse` is rejected in `graph` only: the layout walks children before
  parents, and reversed, every commit would open a rail of its own.
- `_is_plain_rev` decides whether a revision can be validated up front; ranges
  (`a..b`, `a...b`) and exclusions (`^a`) are left for git to report on.

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
  the real repository the command ran in, so `c` behaves as in `GitTool diff`.

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

## merge

Three entry points, one implementation:

- the four-file mergetool convention;
- a single file, the other three sides recovered from its index stages;
- the current buffer, or — when that isn't conflicted — one picked from
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
  `git merge-file --diff3`, matching conflicts *by position* — a
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

## Help file

`doc/gittools.txt` is generated from `README.md`; edit the README, never the
help file.

```sh
scripts/gendoc.sh          # rewrites doc/gittools.txt and doc/tags
scripts/gendoc.sh --check  # exits 1 when the help file is stale
```

Generator: [panvimdoc](https://github.com/kdheepak/panvimdoc), pinned in
`scripts/gendoc.sh` to commit `662fb20` (v4.0.1).

- A tag can be moved, a commit cannot, so the same README always produces the
  same help file.
- Fetched into `$XDG_CACHE_HOME/panvimdoc-<commit>` on first run and reused;
  the script re-checks the cached checkout's HEAD and refuses to run if it is
  not the pinned commit.
- `PANVIMDOC_DIR` uses a checkout of your own.
- Only `pandoc` needs installing (`brew install pandoc`); nvim is used just to
  refresh `doc/tags`.

`doc/tags` is committed, as |package-create| recommends: nothing in the native
package path generates it, so shipping it is what makes `:help gittools` work
for someone dropping the repo into `pack/*/opt`. Plugin managers — `vim.pack`
included — delete and regenerate it on install and update.

Tags come from the README headings, so `## \`GitTool diff\`` would give
`*gittools-gittool-diff*`. panvimdoc has no override (`--doc-mapping` tags only
`####` headings), so `gendoc.sh` adds one: a heading may end in a hidden
comment naming its tag, project name prefixed automatically.

```markdown
## `GitTool diff` <!-- tag: diff -->
```

- The comment is invisible on GitHub, so the README keeps full section names --
  the help file's sections are still titled `GitTool diff` — while the tag
  shrinks to `*gittools-diff*`.
- A heading without one keeps panvimdoc's derived tag, but every README section
  declares one, so renaming a section never silently renames its help tag.
- `gendoc.sh` collects the declarations, strips the comments from the *copy* it
  feeds panvimdoc, and rewrites the derived tags in the output, fixing both the
  `|links|` in the table of contents and the right-alignment of the trailing
  tag.
- Deriving the "before" tag reproduces panvimdoc's own rule (lowercase, spaces
  to `-`) against the *rendered* heading, which is why the inline markdown
  markers pandoc consumes (`` ` ``, `*`, `_`) are stripped first.
- Nothing else in the README is rewritten, and the README itself is never
  modified.

panvimdoc options:

- `--shift-heading-level-by -1` so the README's `#` title drops out and `##`
  headings become top-level sections — without it every tag carries the title
  (`gittools-gittools.nvim-requirements`).
- `--dedup-subheadings false` to keep `###` tags short (`gittools-maps`).
- `--toc true`, `--treesitter true`.

Known rough edges, all panvimdoc's rendering rather than the README's markup:

- tables are laid out to content width, so the command and highlight tables run
  past 78 columns;
- pandoc's smart quotes put curly apostrophes in the text;
- there is no `:GitTool` help tag; panvimdoc tags sections only.

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
- The plugin's views — log, diff file list, blame sidebar, `diffthis` git side
  — answer `g?` with a hover listing their keys (`keyhelp.map`), each view
  naming its own: other plugins map into these buffers too (a key-hint plugin's
  triggers), so reading every map off the buffer would list theirs as well. In
  a window too short for a hover (the diff file list) the list opens in a float
  over the window, read off the buffer's own maps when pressed — so every map
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
