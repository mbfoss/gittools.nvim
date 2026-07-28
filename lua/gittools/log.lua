local M        = {}

---@diagnostic disable-next-line: deprecated
local unpack   = table.unpack or unpack

local git      = require("gittools.git")
local difftool = require("gittools.diff")
local ui   = require("gittools.util.ui")

--- `:GitTool log [<opt>...] [<rev>] [-- <path>]` -- commit history as a flat
--- list in a bottom split. `:GitTool graph [<opt>...] [<rev>] [-- <path>]` --
--- the same, but with a commit tree drawn in front of each commit in
--- box-drawing glyphs, one colour per rail. `<opt>` is any `git log` option
--- that leaves one line per commit (`--all`, `--no-merges`, `-n 50`, ...),
--- handed to git as given. `:GitTool stash_log` -- the stash list (`git stash list`) in the
--- same kind of split, each entry labeled with its `stash@{N}` selector
--- instead of a hash. In all three views `<CR>` diffs the commit under the
--- cursor against its first parent; `c` flags a commit, and if another commit
--- was already flagged, immediately diffs the two (via `gittools.diff`).

local _LIMIT      = 500
local _EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

---@param msg string
---@param level integer?
local function _notify(msg, level)
    vim.notify("[gittools] " .. msg, level or vim.log.levels.INFO)
end

--- One buffer line. The link lines of a graph (the rows where rails merge or
--- branch) carry no commit and have only `rails` set.
---@class GitTools.LogEntry
---@field rails   [string, string][]?  graph prefix as {text, highlight} chunks;
---                          unset in the plain log and stash views
---@field hash    string?
---@field parents string[]?
---@field date    string?   author date, short (YYYY-MM-DD)
---@field author  string?   author name
---@field subject string?
---@field refs    string?   ref decoration, e.g. "HEAD -> main, origin/main"
---@field ref     string?   display selector shown instead of the short hash,
---                          e.g. "stash@{0}"; unset outside the stash view

---@class GitTools.LogSession
---@field root    string
---@field buf     integer?
---@field win     integer?
---@field origin  integer?  window the log was launched from; the diff reuses it
---@field flagged string?
---@field entries GitTools.LogEntry[]           by buffer line
---@field line_of table<string, integer>        hash -> buffer line
---@type GitTools.LogSession?
local _session = nil

--- Close the active log/graph session's window, if any. Safe to call anytime.
local function _end_log()
    if not _session then return end
    local win = _session.win
    _session = nil
    if win and vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_win_close, win, false)
    end
end

---@param parents string  space-separated hashes from `%P`
---@return string[]
local function _split_parents(parents)
    local out = {}
    for p in parents:gmatch("%S+") do out[#out + 1] = p end
    return out
end

--- Parse `git log --pretty=format:%H\t%P\t%ad\t%an\t%s` output.
---@param out string
---@return GitTools.LogEntry[]
local function _parse_log(out)
    local entries = {}
    for _, line in ipairs(git.lines(out)) do
        local hash, parents, date, author, subject =
            line:match("^(%x+)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$")
        if hash then
            entries[#entries + 1] = {
                hash = hash, parents = _split_parents(parents),
                date = date, author = author, subject = subject,
            }
        end
    end
    return entries
end

--- Rail colours, cycled by column so neighbouring rails stay distinguishable.
--- Linked with `default` so a colorscheme can override them, and (re)defined on
--- every graph since `:colorscheme` clears them.
local _RAIL_HL = { "GitToolsGraph1", "GitToolsGraph2", "GitToolsGraph3",
    "GitToolsGraph4", "GitToolsGraph5", "GitToolsGraph6" }
local _RAIL_LINK = { "Function", "String", "Identifier", "Type", "Constant", "Statement" }

local function _define_rail_hl()
    for i, name in ipairs(_RAIL_HL) do
        vim.api.nvim_set_hl(0, name, { link = _RAIL_LINK[i], default = true })
    end
end

---@param col integer  rail column, 1-based
---@return string
local function _rail_hl(col)
    return _RAIL_HL[(col - 1) % #_RAIL_HL + 1]
end

--- Box-drawing glyphs keyed by which sides of the cell connect, as
--- "<up><down><left><right>". Corners are the rounded variants, which is what
--- gives merges and branch-offs their curve.
local _BOX = {
    ["1100"] = "│", ["1101"] = "├", ["1110"] = "┤", ["1111"] = "┼",
    ["1010"] = "╯", ["1001"] = "╰", ["1011"] = "┴",
    ["0110"] = "╮", ["0101"] = "╭", ["0111"] = "┬",
    ["0011"] = "─", ["0010"] = "─", ["0001"] = "─",
    ["1000"] = "│", ["0100"] = "│",
}

---@return string
local function _box(up, down, left, right)
    local key = (up and "1" or "0") .. (down and "1" or "0")
        .. (left and "1" or "0") .. (right and "1" or "0")
    return _BOX[key] or " "
end

local _DOT       = "●"  -- ordinary commit
local _MERGE_DOT = "◆"  -- commit with more than one parent

--- Turn per-cell `{char, rail column}` pairs into `{text, highlight}` chunks,
--- runs of the same colour merged into one chunk.
---@param cells {ch: string, col: integer}[]
---@return [string, string][]
local function _cells_to_chunks(cells)
    local chunks = {}
    for _, cell in ipairs(cells) do
        local hl = _rail_hl(cell.col)
        local last = chunks[#chunks]
        if last and last[2] == hl then
            last[1] = last[1] .. cell.ch
        else
            chunks[#chunks + 1] = { cell.ch, hl }
        end
    end
    return chunks
end

--- Index of the first column with no rail in it, at or after `from`; one past
--- the end if every column is taken. Reusing holes keeps the graph narrow.
---@param cols (string|false)[]
---@param from integer
---@return integer
local function _free_col(cols, from)
    for i = from, #cols do
        if not cols[i] then return i end
    end
    return #cols + 1
end

--- Lay the commits out into rails and draw them.
---
--- `cols[i]` is the hash the rail in column `i` is waiting for (`false` for an
--- unused column). Walking the commits in topological order, each commit takes
--- the leftmost column waiting for it (or a fresh one, if it is a branch tip
--- nothing has referenced yet); its first parent inherits that column, any
--- further parents open new ones, and every other column waiting for it is a
--- branch merging in and ends here.
---
--- That yields three kinds of row: a commit row, with the commit's dot and a
--- vertical through every other live column; above it, when other columns were
--- waiting for the commit, a link row where those branches curve back in; and
--- below it, when the commit is a merge, a link row where the extra parents
--- curve out into columns of their own.
---@param commits GitTools.LogEntry[]  in log order, `hash`/`parents` set
---@return GitTools.LogEntry[]         commits interleaved with link rows
local function _layout(commits)
    local rows = {}
    ---@type (string|false)[]
    local cols = {}

    --- One row of rails going from the column state `before` to `after`, with
    --- a horizontal run from `anchor` out to each column in `ends`.
    ---@param before (string|false)[]
    ---@param after  (string|false)[]
    ---@param anchor integer
    ---@param ends   integer[]
    ---@return {ch: string, col: integer}[]
    local function link_cells(before, after, anchor, ends)
        local lo, hi = anchor, anchor
        for _, i in ipairs(ends) do
            lo, hi = math.min(lo, i), math.max(hi, i)
        end
        local cells = {}
        for i = 1, math.max(#before, #after) do
            local span = i >= lo and i <= hi
            local up, down = before[i] and true or false, after[i] and true or false
            cells[#cells + 1] = {
                ch  = _box(up, down, span and i > lo, span and i < hi),
                -- A column the run only crosses -- nothing above it and nothing
                -- below it -- carries no rail of its own, so it takes the
                -- anchor's colour like the rest of the run; colouring it by its
                -- own column would break the line into two colours mid-way.
                col = (span and not up and not down) and anchor or i,
            }
            -- The gap after the column: part of the horizontal run (and so the
            -- anchor's colour) while it is still inside it.
            local run = i >= lo and i < hi
            cells[#cells + 1] = { ch = run and "─" or " ", col = run and anchor or i }
        end
        return cells
    end

    for _, commit in ipairs(commits) do
        -- Columns waiting for this commit; the leftmost is the one it sits in,
        -- the rest are branches merging into it.
        local waiting = {}
        for i = 1, #cols do
            if cols[i] == commit.hash then waiting[#waiting + 1] = i end
        end
        local col = waiting[1]
        if not col then
            col = _free_col(cols, 1)
            cols[col] = commit.hash
        end

        -- Branches merging in end above the commit, so that they visibly join
        -- the dot rather than the commit below it.
        if #waiting > 1 then
            local merged, ends = { unpack(cols) }, {}
            for i = 2, #waiting do
                merged[waiting[i]] = false
                ends[#ends + 1] = waiting[i]
            end
            rows[#rows + 1] = { rails = _cells_to_chunks(link_cells(cols, merged, col, ends)) }
            while #merged > 0 and not merged[#merged] do
                merged[#merged] = nil
            end
            cols = merged
        end

        local cells = {}
        for i = 1, #cols do
            local ch = (i == col and (#commit.parents > 1 and _MERGE_DOT or _DOT))
                or (cols[i] and "│" or " ")
            cells[#cells + 1] = { ch = ch, col = i }
            cells[#cells + 1] = { ch = " ", col = i }
        end
        commit.rails = _cells_to_chunks(cells)
        rows[#rows + 1] = commit

        -- Advance the rails: the first parent inherits this column, and any
        -- further parent takes a column of its own to the right of it.
        local next_cols = { unpack(cols) }
        next_cols[col] = commit.parents[1] or false
        local ends = {}
        for i = 2, #commit.parents do
            local parent = commit.parents[i]
            local at
            for j = 1, #next_cols do
                if next_cols[j] == parent then at = j break end
            end
            if not at then
                at = _free_col(next_cols, col + 1)
                next_cols[at] = parent
            end
            if at ~= col then ends[#ends + 1] = at end
        end
        if #ends > 0 then
            rows[#rows + 1] = { rails = _cells_to_chunks(link_cells(cols, next_cols, col, ends)) }
        end

        -- Drop columns that fell off the right so the graph re-narrows.
        while #next_cols > 0 and not next_cols[#next_cols] do
            next_cols[#next_cols] = nil
        end
        cols = next_cols
    end

    -- Pad every prefix out to the widest one, so the commit text lines up in a
    -- single column no matter how many rails a row happens to carry.
    local width = 0
    for _, row in ipairs(rows) do
        local w = 0
        for _, chunk in ipairs(row.rails) do w = w + vim.fn.strdisplaywidth(chunk[1]) end
        width = math.max(width, w)
    end
    for _, row in ipairs(rows) do
        if row.hash then
            local w = 0
            for _, chunk in ipairs(row.rails) do w = w + vim.fn.strdisplaywidth(chunk[1]) end
            row.rails[#row.rails + 1] = { string.rep(" ", width - w), "Normal" }
        end
    end

    return rows
end

--- Parse `git log --pretty=format:%H\t%P\t%ad\t%an\t%D\t%s` output and lay the
--- commits out as a graph.
---@param out string
---@return GitTools.LogEntry[]
local function _parse_graph(out)
    local commits = {}
    for _, line in ipairs(git.lines(out)) do
        local hash, parents, date, author, refs, subject =
            line:match("^(%x+)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$")
        if hash then
            commits[#commits + 1] = {
                hash = hash, parents = _split_parents(parents),
                date = date, author = author, refs = refs, subject = subject,
            }
        end
    end
    return _layout(commits)
end

--- The leading identifier for a line: the short hash, or (in the stash view)
--- the `stash@{N}` selector, which is what a user would actually type at a
--- git command to act on that entry.
---@param e GitTools.LogEntry
---@return string
local function _id(e)
    return e.ref or e.hash:sub(1, 7)
end

--- The `{text, hl}` chunks for a commit's fields: id, date, author, subject.
---@param e GitTools.LogEntry
---@return [string, string][]
local function _build_entry(e)
    local chunks = {
        { _id(e), "Comment" },
        { " " .. e.date .. " ", "DiagnosticHint" },
        { e.author .. " ", "Identifier" },
    }
    if e.refs and e.refs ~= "" then
        chunks[#chunks + 1] = { "(" .. e.refs .. ") ", "WarningMsg" }
    end
    chunks[#chunks + 1] = { e.subject, "Normal" }
    return chunks
end

--- The `{text, hl}` chunks making up one buffer line.
---@param session GitTools.LogSession
---@param entry   GitTools.LogEntry
---@return [string, string][]
local function _entry_chunks(session, entry)
    local chunks = {}
    for _, chunk in ipairs(entry.rails or {}) do
        chunks[#chunks + 1] = chunk
    end
    if entry.hash then
        if session.flagged == entry.hash then
            chunks[#chunks + 1] = { "» ", "WarningMsg" }
        end
        for _, chunk in ipairs(_build_entry(entry)) do
            chunks[#chunks + 1] = chunk
        end
    end
    return chunks
end

local _ns_id = vim.api.nvim_create_namespace("gittoolslog")

--- Replace line `lnum` (1-based; the buffer's full range when nil) with the
--- rendered entries and their highlight extmarks.
---@param session GitTools.LogSession
---@param lnum    integer?
local function _render(session, lnum)
    local buf = session.buf
    if not buf or not vim.api.nvim_buf_is_valid(buf) then return end

    local first = lnum or 1
    local last  = lnum or #session.entries
    local lines, hls = {}, {}
    for i = first, last do
        local row, col, line = i - 1, 0, ""
        for _, chunk in ipairs(_entry_chunks(session, session.entries[i])) do
            local txt, hl = chunk[1], chunk[2]
            if hl then
                hls[#hls + 1] = { row = row, s_col = col, e_col = col + #txt, hl = hl }
            end
            line = line .. txt
            col = col + #txt
        end
        lines[#lines + 1] = line
    end

    vim.api.nvim_buf_clear_namespace(buf, _ns_id, first - 1, last)
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, first - 1, lnum and last or -1, false, lines)
    vim.bo[buf].modifiable = false
    for _, h in ipairs(hls) do
        vim.api.nvim_buf_set_extmark(buf, _ns_id, h.row, h.s_col, {
            end_col = h.e_col, hl_group = h.hl,
        })
    end
end

--- The commit under the cursor, or nil on a rail-only line.
---@param session GitTools.LogSession
---@return GitTools.LogEntry?
local function _entry_at_cursor(session)
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    local entry = session.entries[lnum]
    return (entry and entry.hash) and entry or nil
end

--- Close the log split and return focus to the window it was launched from, so
--- a diff opened next reuses that window instead of splitting new panes on top
--- of the (bottom) log split. Returns the root to diff in.
---@param session GitTools.LogSession
---@return string root
local function _handoff_to_diff(session)
    local root, origin = session.root, session.origin
    _end_log()
    if origin and vim.api.nvim_win_is_valid(origin) then
        vim.api.nvim_set_current_win(origin)
    end
    return root
end

--- Diff `entry` against its first parent (or the empty tree, for a root
--- commit) -- i.e. show what that commit itself changed. Closes the log split
--- and reuses the window it was launched from for the diff.
---@param session GitTools.LogSession
---@param entry   GitTools.LogEntry
local function _diff_against_parent(session, entry)
    local root = _handoff_to_diff(session)
    local parent = entry.parents[1]
    if parent and git.verify_rev(root, parent) then
        difftool.diff({ revs = { parent, entry.hash }, root = root })
    else
        difftool.diff({ revs = { _EMPTY_TREE, entry.hash }, root = root })
    end
end

--- Show `session.entries` in a scratch buffer in a bottom split and wire up
--- the `gd` / `c` / `q` maps.
---@param session GitTools.LogSession
local function _show(session)
    -- Remember the window the log is launched from (before the split below) so
    -- diffs can reuse it rather than pile new splits onto the log window.
    session.origin = vim.api.nvim_get_current_win()
    _end_log()

    local buf = ui.create_scratch_buffer(false, {
        filetype   = "gittoolslog",
        modifiable = false,
        undolevels = -1,
    }, function()
        if _session == session then _session = nil end
    end)
    session.buf = buf
    _render(session)

    vim.cmd("botright new")
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    vim.api.nvim_win_set_height(win, math.min(20, #session.entries))
    -- A new split inherits window-local options (scrollbind, cursorbind, ...)
    -- from the window it split off of; reset them so the log split can't end
    -- up scroll-linked to the buffer the user opened it from (e.g. a leftover
    -- `:GitTool blame` sidebar with scrollbind still on). `spell` goes the same
    -- way: inherited from a prose buffer it would underline hashes, author
    -- names and half the subject lines.
    vim.wo[win].scrollbind = false
    vim.wo[win].cursorbind = false
    vim.wo[win].spell = false
    vim.wo[win].wrap = false

    session.win = win
    _session = session

    vim.keymap.set("n", "<CR>", function()
        local entry = _entry_at_cursor(session)
        if not entry then return end
        _diff_against_parent(session, entry)
    end, { buffer = buf, desc = "Diff commit against its parent" })

    vim.keymap.set("n", "c", function()
        local entry = _entry_at_cursor(session)
        if not entry then return end
        local old = session.flagged
        -- Re-flagging the same commit clears the flag (toggle).
        session.flagged = old ~= entry.hash and entry.hash or nil
        if old then _render(session, session.line_of[old]) end
        if session.flagged then _render(session, session.line_of[session.flagged]) end
        -- A different commit was already flagged: diff it against the one
        -- just flagged.
        if old and old ~= entry.hash then
            local root = _handoff_to_diff(session)
            difftool.diff({ revs = { old, entry.hash }, root = root })
        end
    end, { buffer = buf, desc = "Flag commit, diffing against the previous flag if any" })

    vim.keymap.set("n", "q", _end_log, { buffer = buf, desc = "Close log" })
end

--- Options that would break parsing (they replace or extend the `--pretty`
--- format this module relies on) or the layout, keyed by the flag as written;
--- `=`-joined values are stripped before the lookup. `--reverse` is rejected
--- only in the graph view: the layout walks children before parents, and in
--- reverse order every commit would open a rail of its own.
local _REJECTED = {
    ["--pretty"] = true, ["--format"] = true, ["--oneline"] = true,
    ["--graph"] = true, ["-p"] = true, ["-u"] = true, ["--patch"] = true,
    ["--stat"] = true, ["--shortstat"] = true, ["--numstat"] = true,
    ["--raw"] = true, ["--name-only"] = true, ["--name-status"] = true,
    ["-z"] = true, ["--null"] = true,
}

--- The first option in `args` this module can't render, or nil if all of them
--- are fine to hand to git.
---@param args    string[]
---@param reverse boolean  whether `--reverse` is usable in this view
---@return string?
local function _rejected_opt(args, reverse)
    for _, a in ipairs(args) do
        local flag = a:match("^([^=]+)=") or a
        if _REJECTED[flag] or (not reverse and flag == "--reverse") then
            return a
        end
    end
    return nil
end

--- Whether `rev` is a plain revision that can be checked up front, as opposed
--- to a range (`a..b`, `a...b`) or an exclusion (`^a`), which `git rev-parse
--- --verify` rejects and which git itself will report on instead.
---@param rev string
---@return boolean
local function _is_plain_rev(rev)
    return not rev:find("%.%.", 1, false) and not vim.startswith(rev, "^")
end

---@class GitTools.LogOpts
---@field rev  string?    start the log from this revision instead of HEAD
---@field path string?    scope the log to commits touching this path
---@field args string[]?  extra `git log` options, passed through verbatim
---                       (e.g. `--all`, `--no-merges`, `--author=...`)

--- Validate `opts`, run `git log <extra_args>... <opts.args>... [<rev>]
--- [-- <path>]`, and show the parsed entries.
---@param opts       GitTools.LogOpts
---@param extra_args string[]
---@param parse      fun(out: string): GitTools.LogEntry[]
---@param reverse    boolean?  whether the view can render `--reverse` output
local function _run_log(opts, extra_args, parse, reverse)
    local root = git.root()
    if not root then
        _notify("Not inside a git repository", vim.log.levels.WARN)
        return
    end

    local bad = _rejected_opt(opts.args or {}, reverse or false)
    if bad then
        _notify("Option not supported here: " .. bad, vim.log.levels.ERROR)
        return
    end

    if opts.rev and _is_plain_rev(opts.rev) and not git.verify_rev(root, opts.rev) then
        _notify("Unknown revision: " .. opts.rev, vim.log.levels.ERROR)
        return
    end

    local rel
    if opts.path then
        local abs = vim.fn.fnamemodify(opts.path, ":p")
        rel = git.relpath(root, abs)
        if not rel then
            _notify("File is outside the repository: " .. opts.path, vim.log.levels.WARN)
            return
        end
    end

    -- The user's options come last, so that a `-n`/`--max-count` of their own
    -- overrides the default cap rather than being overridden by it (git takes
    -- the last occurrence).
    local args = { "log", "--date=short", "-n", tostring(_LIMIT) }
    vim.list_extend(args, extra_args)
    vim.list_extend(args, opts.args or {})
    if opts.rev then args[#args + 1] = opts.rev end
    if rel then
        args[#args + 1] = "--"
        args[#args + 1] = rel
    end

    local out, err = git.run(root, args)
    if not out then
        _notify(err ~= "" and err or "git log failed", vim.log.levels.ERROR)
        return
    end

    local entries = parse(out)
    if #entries == 0 then
        _notify("No commits found")
        return
    end

    local line_of = {}
    for i, entry in ipairs(entries) do
        if entry.hash then line_of[entry.hash] = i end
    end

    _show({ root = root, flagged = nil, entries = entries, line_of = line_of })
end

--- List commit history in an interactive bottom split, starting from
--- `opts.rev` (default HEAD) and optionally scoped to `opts.path` -- mirrors
--- `git log [<opts.args>...] [<rev>] [-- <path>]`.
---@param opts GitTools.LogOpts?
function M.log(opts)
    _run_log(opts or {}, { "--pretty=format:%H\t%P\t%ad\t%an\t%s" }, _parse_log, true)
end

--- Like `M.log`, but with the commit tree drawn in front of each commit, plus
--- each commit's ref decoration -- mirrors `git log --graph --decorate
--- [<opts.args>...] [<rev>] [-- <path>]`, except that the rails are drawn here
--- rather than by git, in box-drawing glyphs with one colour per rail. With
--- `opts.args` naming several tips (`--all`, `--branches`, ...) the layout
--- gives each tip a rail of its own, exactly as it does for the branches that
--- merge into a single one.
---
--- `--topo-order` and `--parents` are what `--graph` itself turns on. Without
--- topological order commits come out by date, which interleaves unrelated
--- branches and leaves the rails running the length of the graph instead of in
--- compact runs. `--parents` turns on parent rewriting, which matters once
--- `opts.path` limits the history: `%P` then names the nearest ancestor that
--- is still in the log rather than the true parent, so the rails still join up
--- instead of every commit starting a column of its own.
---@param opts GitTools.LogOpts?
function M.graph(opts)
    _define_rail_hl()
    _run_log(opts or {}, {
        "--topo-order",
        "--parents",
        "--decorate=short",
        "--pretty=format:%H\t%P\t%ad\t%an\t%D\t%s",
    }, _parse_graph, false)
end

--- Run `git stash list` and show the parsed entries -- mirrors `_run_log`,
--- but stash entries live only in the `refs/stash` reflog rather than on any
--- branch, so there's no `<rev>`/`<path>` to scope by. Each entry is labeled
--- with its `stash@{N}` selector (N counted off from the top of the list,
--- exactly as `git stash list` orders it) rather than a hash, since that's
--- what a user would type at `git stash apply/pop/drop` to act on it.
local function _run_stash_log()
    local root = git.root()
    if not root then
        _notify("Not inside a git repository", vim.log.levels.WARN)
        return
    end

    local args = { "stash", "list", "--date=short", "--pretty=format:%H\t%P\t%ad\t%an\t%s" }
    local entries = _parse_log((git.run(root, args)) or "")
    if #entries == 0 then
        _notify("No stashes found")
        return
    end

    local line_of = {}
    for i, entry in ipairs(entries) do
        entry.ref = string.format("stash@{%d}", i - 1)
        line_of[entry.hash] = i
    end

    _show({ root = root, flagged = nil, entries = entries, line_of = line_of })
end

--- List stashes in an interactive bottom split, same interaction as `M.log`
--- (flag/diff/close) -- mirrors `git stash list`. Diffing a stash
--- (with nothing flagged) compares it against its first parent, i.e. the
--- commit that was checked out when it was stashed -- the tracked changes it
--- holds. A stash created with `git stash push -u` also carries untracked
--- files in a second parent that this diff doesn't show.
function M.stash_log()
    _run_stash_log()
end

return M
