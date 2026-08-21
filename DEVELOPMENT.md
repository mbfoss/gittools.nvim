# Development

Internals of gittools.nvim: how the modules fit together, and why the parts
that look odd are the way they are. For what the plugin does and how to use it,
see [README.md](README.md).

## Layout

```
plugin/gittools.lua          version guard (nvim >= 0.10) + lazy :GitTool
lua/gittools/init.lua        :GitTool registration, argument parsing, completion
lua/gittools/diff.lua        git-backed file list for `diff`
lua/gittools/diffpaths.lua   path-backed file list for `diffpaths`
lua/gittools/diffthis.lua    single-buffer diff against a git version
lua/gittools/log.lua         `log`, `graph`, `stashlist`
lua/gittools/blame.lua       `blame`
lua/gittools/merge.lua       `merge`
lua/gittools/util/
    diffsession.lua          the side-by-side diff engine
    git.lua                  git plumbing: run git, resolve roots/revs/paths
    ui.lua                   tab claiming, scratch buffers, window teardown
    usercmd.lua              user-command registration + subcommand completion
    hover.lua                LSP-style floating preview
```

`init.lua` owns only argument parsing and completion; every feature has its own
module.

Loading is driven from `plugin/gittools.lua`, which registers `:GitTool`
through `util/usercmd` — the argument splitter and completion dispatcher, which
knows nothing about the subcommands — and is the only module read at startup.
The run and completion callbacks it passes are `require("gittools").run` /
`.complete` behind a `require` performed at call time, so `init.lua` and the
feature modules it pulls in are read on the first `:GitTool` invocation (or the
first `<Tab>`), not before. `init.lua` has no load-time side effects of its
own.

There is no `setup()`. Registration belongs to `plugin/`, which every loading
path reaches — including `packadd!` during startup, whose bang only suppresses
sourcing at that moment and leaves it to the normal plugin pass. (A `packadd!`
issued *after* startup never sources `plugin/`; use the plain `packadd` there.)

## The diff session engine

`util/diffsession.lua` is the one place that owns windows and buffers for the
side-by-side views. Its input is a flat list of `GitTools.DiffItem`, each
carrying a status letter and a `GitTools.Side` per side describing *how to fetch
the content*, not the content itself:

| Side field | content source |
| --- | --- |
| `rev` | `git show <rev>:<rel>` |
| `index` | `git show :<rel>` |
| `worktree` | the live buffer / file |
| `path` | an absolute path read off disk (no repo needed) |

`gittools.diff` builds those items from a git comparison; `gittools.diffpaths`
builds them from two filesystem paths. Neither knows anything about windows,
and the engine knows nothing about where the items came from. New sources of
"a list of changed files" should be added as another front end, not as another
layout.

### Sessions and tabs

A session is identified by its tabpage. `_sessions` holds every live one, and
`_current_session()` looks up by the current tab. That works because
`ui.claim_tab()` only ever reuses a tab that is a single window over a blank,
unnamed, unmodified buffer — so two sessions can never land in the same tab.
Multiple sessions exist because `c` on a submodule row opens a diff *from
inside* a diff.

`owns_tab` records whether the session created its tab. Teardown closes the tab
it opened, or collapses back to one window in a tab it reused, so the layout
the user launched from is restored either way.

Teardown is wired to `WinClosed` on the left pane, the right pane and the file
list, and to `BufDelete`/`BufWipeout` on the list buffer — closing any one of
them collapses the whole session, so the user never needs more than one close.
Those callbacks all `vim.schedule` the actual teardown: closing further windows
synchronously from inside `WinClosed` breaks Neovim's mid-close bookkeeping
(E445).

`setting_up` and `closing` are reentrancy guards; `shown_line` makes a repeat
setup for the entry already on screen a no-op.

### `]f` / `[f`

Set once globally at module load, not per buffer. The right pane can hold the
user's own worktree buffer, so buffer-local maps would leave strays behind
after the session closed. Outside a session the maps are a no-op, which makes
claiming them globally cheap. `f` rather than `c` because the builtin `]c`/`[c`
(next/previous hunk) has to keep working.

## `util/git.lua`

All git plumbing, no UI. Every question is "which repository is this path in,
and what does it say", answered by the `cwd` each command runs in.

That is why `_SCOPING_VARS` (`GIT_DIR`, `GIT_WORK_TREE`, `GIT_INDEX_FILE`, …)
are stripped from the environment: git exports them when it launches a
difftool/mergetool, and with `GIT_DIR` set,
`git -C <submodule> rev-parse --show-toplevel` reports the *parent* worktree —
a submodule then looks like it is not a repository at all. The environment is
only rebuilt when one of those variables is actually set; otherwise the plain
`{ text = true, cwd = cwd }` options are used.

## Argument parsing

`init.lua` mirrors git's own command line rather than inventing a syntax:

- `_split_sep` splits at a literal `--`, returning a third `found` flag —
  an empty "after" list alone cannot distinguish a trailing `--` from no
  separator at all.
- `_parse_flags` pulls `--staged`/`--cached` out of the positionals.
- `_split_opts` (log/graph) treats anything starting with `-` as a git option,
  and consumes the next argument as its value when the flag is in
  `_LOG_VALUE_OPTS` (`-n 20`, `--author Ada`) so the value isn't taken for a
  revision. Glued short forms (`-n20`) need no entry.

Without a `--`, revision/path disambiguation is deferred to `gittools.diff`,
which knows the repo: leading arguments that resolve to a tree-ish are
revisions, everything from the first non-revision on is a pathspec, and an
argument that is neither a known revision nor an existing path is rejected —
mirroring git, which demands an explicit `--` in exactly that case.

`util/usercmd.lua` handles the command registration and per-subcommand
completion. Its `_split_args` honours shell-style quoting because git hands a
mergetool pre-quoted paths (`cmd = ... "$LOCAL" "$MERGED"`), so paths with
spaces survive.

## log / graph

Both run one `git log` with a fixed `--pretty=format:` and parse it. That is
why options which replace or extend the format (`--pretty`, `--format`,
`--oneline`, `--stat`, `--patch`, `--name-status`, `-z`) are rejected up front
in `_rejected_opt` rather than being handed to git — they would produce an
unparseable buffer. `--graph` is rejected because the rails are drawn here.
`--reverse` is rejected in `graph` only: the layout walks children before
parents, and reversed, every commit would open a rail of its own.

`_is_plain_rev` decides whether a revision can be validated up front; ranges
(`a..b`, `a...b`) and exclusions (`^a`) are left for git to report on.

### Rail layout (`_layout`)

`cols[i]` is the hash the rail in column `i` is waiting for, `false` for a free
column. Walking commits in topological order:

- each commit takes the leftmost column waiting for it, or a fresh one (a tip
  nothing has referenced yet — `_free_col` reuses holes, keeping the graph
  narrow);
- its first parent inherits that column, further parents open new ones;
- every other column waiting for it is a branch merging in, and ends there.

That produces three row kinds: a commit row (dot plus a vertical through every
other live column), an optional link row above it where merged branches curve
back in, and an optional link row below a merge where extra parents curve out.
Glyphs come from `_box(up, down, left, right)`, keyed by which sides of the
cell connect, using rounded corners.

The graph passes `--topo-order` and `--parents` — what `--graph` itself turns
on. `--parents` enables parent rewriting so rails still join across commits a
path filter dropped. Rail colours cycle by column and are re-defined on every
graph, since `:colorscheme` clears highlight groups.

The 500-commit cap (`_LIMIT`) applies unless the user passes their own
`-n`/`--max-count`; rails whose next commit falls past it just run off the
bottom.

## Submodules

A submodule is a gitlink: its two sides are only a pair of commit ids, while
what actually changed is a whole repository one level down. `<CR>` shows the id
pair (what git shows); `c` calls `diff.diff_submodule` to open a second,
independent session over the submodule itself, in its own tab.

`git difftool -d` cannot check a submodule out into its temp trees, so it
writes it as a one-line file — `Subproject commit <sha>`, with an all-zero id
standing in for whichever side is the live working tree. `_GITLINK_LINE` in
`diffpaths.lua` matches exactly that (read only for files small enough to be
that single line), and the submodule is then resolved back to the real
repository the command was run in, so `c` behaves as it does in `GitTool diff`.

## merge

Three entry points, one implementation: the four-file mergetool convention, a
single file (the other three sides recovered from its index stages), or the
current buffer. The view is `$MERGED` itself — a normal, editable, saveable
buffer — with conflict regions painted as Current / Base / Incoming bands.

This module is as read-only toward git as the rest of the plugin: accepting a
side only edits the buffer, `:w` is what lands it, and `git mergetool` stages
`$MERGED` itself on exit. That division is what makes `trustExitCode = false`
the right setting — quitting without saving exits 0, and only git's own
"did the file change" check keeps unresolved markers from being staged.

`xa` (accept base) needs the common ancestor. Under `conflictStyle = zdiff3`
git writes it into the markers and it is read straight from the buffer.
Otherwise it is recovered by re-merging the three inputs with
`git merge-file --diff3` and matching conflicts *by position* — a
correspondence that only holds while the buffer's conflicts still line up with
a fresh merge, so once regions have been hand-edited or resolved, `xa` declines
rather than pasting text from the wrong region. An add/add conflict has no
ancestor at all.

## Highlights

Every group is defined with `default = true` so a colorscheme wins.

- `diffsession` status letters link to `Diagnostic*`, not `Diff*`: the `Diff*`
  groups are mostly background fills meant for whole lines, which on a single
  status character read as an easy-to-miss coloured speck. `Diagnostic*` are
  foreground colours and exist in any Neovim >= 0.6.
- `merge` does the opposite and links to `Diff*`, because it fills whole-line
  bands — exactly what those groups are for.
- The rename arrow is `→` (U+2192) rather than a Nerd Font glyph, so no patched
  font is needed.

## Help file

`doc/gittools.txt` is generated from `README.md`; edit the README, never the
help file. Regenerate with

```sh
scripts/gendoc.sh          # rewrites doc/gittools.txt and doc/tags
scripts/gendoc.sh --check  # exits 1 when the help file is stale
```

The generator is [panvimdoc](https://github.com/kdheepak/panvimdoc), pinned in
`scripts/gendoc.sh` to commit `662fb20` (v4.0.1) -- a tag can be moved, a commit
cannot, so the same README always produces the same help file. It is fetched
into `$XDG_CACHE_HOME/panvimdoc-<commit>` on first run and reused after that;
the script re-checks the cached checkout's HEAD and refuses to run if it is not
the pinned commit. Set `PANVIMDOC_DIR` to use a checkout of your own. The only
tool you need installed is `pandoc` (`brew install pandoc`); nvim is used just
to refresh `doc/tags`.

`doc/tags` is committed, as |package-create| recommends: nothing in the native
package path generates it, so shipping it is what makes `:help gittools` work
for someone who drops the repo into `pack/*/opt` and runs `packadd`. Plugin
managers -- including `vim.pack` -- delete and regenerate it on install and
update, so the committed copy costs them nothing.

Section names come from the README headings, and so do the tags, so
`## \`GitTool diff\`` would give `*gittools-gittool-diff*`. panvimdoc has no
override for that (`--doc-mapping` only tags `####` headings), so `gendoc.sh`
adds one: a heading may end in a hidden comment naming the tag it wants, with
the project name prefixed automatically.

```markdown
## `GitTool diff` <!-- tag: diff -->
```

The comment is invisible on GitHub, so the README keeps its full section names
-- the help file's sections are still titled `GitTool diff` -- while the tag
shrinks to `*gittools-diff*`. A heading without one keeps the tag panvimdoc
derives from its text, but every section in the README declares one anyway, so
that renaming a section never silently renames its help tag.

`gendoc.sh` collects those declarations, strips the comments from the *copy* it
feeds panvimdoc, and rewrites the derived tags in panvimdoc's output, fixing up
both the `|links|` in the table of contents and the right-alignment of the
trailing tag. Deriving the "before" tag means reproducing panvimdoc's own rule
-- lowercase, spaces to `-` -- against the *rendered* heading, which is why the
inline markdown markers pandoc consumes (`` ` ``, `*`, `_`) are stripped first.
Nothing else in the README is rewritten, and the README itself is never
modified.

Options passed to panvimdoc:

- `--shift-heading-level-by -1` so the README's `#` title drops out and `##`
  headings become the help file's top-level sections -- without it every tag
  carries the title too (`gittools-gittools.nvim-requirements`).
- `--dedup-subheadings false` to keep `###` tags short (`gittools-maps`).
- `--toc true`, `--demojify true`, `--treesitter true`.

Known rough edges, all of them panvimdoc's rendering rather than the README's
markup: tables are laid out to their content width, so the command table and
the highlight table run past 78 columns, and pandoc's smart quotes put curly
apostrophes in the prose. There is no `:GitTool` help tag; panvimdoc tags
sections only.

## Conventions

- User-visible messages go through a module-local `_notify` that prefixes
  `[gittools]`.
- Private functions are `_`-prefixed and file-local; the module table exports
  only entry points.
- Types are declared with LuaLS `---@class` / `---@field` annotations; the
  shared shapes (`Side`, `DiffItem`, `DiffEntry`, `DiffSession`) are declared in
  `util/diffsession.lua`.
- Windows the plugin creates get their inherited window-local options reset
  (`scrollbind`, `cursorbind`, `wrap`, `spell`, …) — a new split inherits them
  from whatever it split off of, which otherwise scroll-links a picker to a
  diff pane or spell-checks a list of hashes.
- Generated buffers are `buftype=nofile` scratch buffers via
  `ui.create_scratch_buffer`, unlisted ones with `bufhidden=wipe`.
- Sessions clean themselves up on any event that could make their snapshot
  stale — for `blame`, that is the file being edited, reloaded, replaced in its
  window, or deleted. Nothing hooks `VimLeavePre`: teardown only undoes
  process-local state (windows, scratch buffers, window-local diff options),
  and the merge tempfiles come from `vim.fn.tempname()`, whose directory
  Neovim removes on exit. `diff.clear_session()` / `merge.clear_session()`
  remain for an embedder that wants to force it.
