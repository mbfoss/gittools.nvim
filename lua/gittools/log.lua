local M        = {}

local git      = require("gittools.git")
local difftool = require("gittools.diff")
local ui   = require("gittools.util.ui")

--- `:GitTool log [<rev>] [-- <path>]` -- commit history as a flat list in a
--- bottom split. `:GitTool graph [<rev>] [-- <path>]` -- the same, but with
--- `git log --graph` rail drawing in front of each commit. `:GitTool
--- stash_log` -- the stash list (`git stash list`) in the same kind of split,
--- each entry labeled with its `stash@{N}` selector instead of a hash. In all
--- three views `<CR>` diffs the commit under the cursor against its first
--- parent; `c` flags a commit, and if another commit was already flagged,
--- immediately diffs the two (via `gittools.diff`).

local _LIMIT      = 500
local _EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

---@param msg string
---@param level integer?
local function _notify(msg, level)
    vim.notify("[gittools] " .. msg, level or vim.log.levels.INFO)
end

--- One buffer line. Rail-only lines of a graph (`|/`, `|\`, ...) carry no
--- commit and have only `rails` set.
---@class GitTools.LogEntry
---@field rails   string    graph rail prefix; "" in the plain log view
---@field hash    string?
---@field parents string[]?
---@field date    string?   author date, short (YYYY-MM-DD)
---@field author  string?   author name
---@field subject string?
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
                rails = "", hash = hash, parents = _split_parents(parents),
                date = date, author = author, subject = subject,
            }
        end
    end
    return entries
end

--- Parse `git log --graph --pretty=format:%x09%H%x09%P%x09%ad%x09%an%x09%s`
--- output. The leading tab in the format separates git's rail drawing from the
--- commit fields; lines without it are pure rail art between commits.
---@param out string
---@return GitTools.LogEntry[]
local function _parse_graph(out)
    local entries = {}
    for _, line in ipairs(git.lines(out)) do
        local rails, hash, parents, date, author, subject =
            line:match("^([^\t]*)\t(%x+)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$")
        if hash then
            entries[#entries + 1] = {
                rails = rails, hash = hash, parents = _split_parents(parents),
                date = date, author = author, subject = subject,
            }
        else
            entries[#entries + 1] = { rails = line }
        end
    end
    return entries
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
    return {
        { _id(e), "Comment" },
        { " " .. e.date .. " ", "DiagnosticHint" },
        { e.author .. " ", "Identifier" },
        { e.subject, "Normal" },
    }
end

--- The `{text, hl}` chunks making up one buffer line.
---@param session GitTools.LogSession
---@param entry   GitTools.LogEntry
---@return [string, string][]
local function _entry_chunks(session, entry)
    local chunks = {}
    if entry.rails ~= "" then
        chunks[#chunks + 1] = { entry.rails, "Special" }
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
    -- `:GitTool blame` sidebar with scrollbind still on).
    vim.wo[win].scrollbind = false
    vim.wo[win].cursorbind = false

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

---@class GitTools.LogOpts
---@field rev  string?  start the log from this revision instead of HEAD
---@field path string?  scope the log to commits touching this path

--- Validate `opts`, run `git log <extra_args>... [<rev>] [-- <path>]`, and
--- show the parsed entries.
---@param opts       GitTools.LogOpts
---@param extra_args string[]
---@param parse      fun(out: string): GitTools.LogEntry[]
local function _run_log(opts, extra_args, parse)
    local root = git.root()
    if not root then
        _notify("Not inside a git repository", vim.log.levels.WARN)
        return
    end

    if opts.rev and not git.verify_rev(root, opts.rev) then
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

    local args = { "log", "--date=short", "-n", tostring(_LIMIT) }
    vim.list_extend(args, extra_args)
    if opts.rev then args[#args + 1] = opts.rev end
    if rel then
        args[#args + 1] = "--"
        args[#args + 1] = rel
    end

    local entries = parse((git.run(root, args)) or "")
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
--- `git log [<rev>] [-- <path>]`.
---@param opts GitTools.LogOpts?
function M.log(opts)
    _run_log(opts or {}, { "--pretty=format:%H\t%P\t%ad\t%an\t%s" }, _parse_log)
end

--- Like `M.log`, but with `git log --graph` rail drawing in front of each
--- commit -- mirrors `git log --graph [<rev>] [-- <path>]`.
---@param opts GitTools.LogOpts?
function M.graph(opts)
    _run_log(opts or {}, { "--graph", "--pretty=format:%x09%H%x09%P%x09%ad%x09%an%x09%s" }, _parse_graph)
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
