local M         = {}

local git       = require("gittools.git")
local difftool  = require("gittools.diff")
local TreeBuffer = require("gittools.util.TreeBuffer")

--- `:GitTool log [<rev>] [-- <path>]` -- an interactive commit graph. `<Tab>` flags a
--- commit; `gd` on a second commit diffs the two flagged commits (via
--- `gittools.diff`); `gd` with nothing flagged diffs a commit against its
--- first parent. `<CR>` is left as plain expand/collapse (`TreeBuffer`'s
--- default). Without a path this walks the real parent/child graph from
--- HEAD; with a path (whose immediate parents are mostly not in the
--- filtered set) it's a flat, non-collapsible list instead.

local _LIMIT      = 500
local _EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

---@param msg string
---@param level integer?
local function _notify(msg, level)
    vim.notify("[gittools] " .. msg, level or vim.log.levels.INFO)
end

---@class GitTools.LogCommit
---@field hash    string
---@field parents string[]
---@field date    string
---@field subject string

---@class GitTools.LogSession
---@field root     string
---@field win      integer?
---@field flagged  string?
---@type GitTools.LogSession?
local _session = nil

--- Close the active log session's window, if any. Safe to call anytime.
local function _end_log()
    if not _session then return end
    local win = _session.win
    _session = nil
    if win and vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_win_close, win, false)
    end
end

--- Parse `git log --pretty=format:%H\t%P\t%ad\t%s` output into a lookup by
--- hash plus the original (newest-first) order.
---@param out string
---@return table<string, GitTools.LogCommit> commits
---@return string[] order
local function _parse_commits(out)
    local commits, order = {}, {}
    for _, line in ipairs(git.lines(out)) do
        local hash, parents, date, subject = line:match("^(%x+)\t([^\t]*)\t([^\t]*)\t(.*)$")
        if hash then
            local parent_list = {}
            for p in parents:gmatch("%S+") do parent_list[#parent_list + 1] = p end
            commits[hash] = { hash = hash, parents = parent_list, date = date, subject = subject }
            order[#order + 1] = hash
        end
    end
    return commits, order
end

--- Commits from `order` that are never referenced as a parent by another
--- fetched commit -- the tree's roots (normally just HEAD).
---@param commits table<string, GitTools.LogCommit>
---@param order   string[]
---@return string[]
local function _find_roots(commits, order)
    local is_parent = {}
    for _, hash in ipairs(order) do
        for _, p in ipairs(commits[hash].parents) do is_parent[p] = true end
    end
    local roots = {}
    for _, hash in ipairs(order) do
        if not is_parent[hash] then roots[#roots + 1] = hash end
    end
    return roots
end

---@param session GitTools.LogSession
---@return keystone.util.TreeBuffer.FormatterFn
local function _formatter(session)
    return function(id, data, _expanded)
        local chunks = {}
        if session.flagged == id then
            chunks[#chunks + 1] = { "» ", "WarningMsg" }
        end
        chunks[#chunks + 1] = { data.hash:sub(1, 7), "Comment" }
        chunks[#chunks + 1] = { " " .. data.date .. " ", "Number" }
        chunks[#chunks + 1] = { data.subject, "Normal" }
        return chunks, nil
    end
end

--- Populate `tb` as a parent/child graph rooted at HEAD. Depth only
--- increases at real branch points: a commit's first parent continues the
--- *same* lane (a flat run of siblings), and only a merge commit's other
--- parents start a new, nested lane -- otherwise every commit would nest
--- one level deeper than the last, producing a "staircase" instead of a
--- graph. Skips any hash already placed in the tree (a commit reachable via
--- two merge paths would otherwise collide -- `Tree` requires unique ids).
---@param tb keystone.util.TreeBuffer
---@param commits table<string, GitTools.LogCommit>
---@param order string[]
local function _build_graph(tb, commits, order)
    local roots = _find_roots(commits, order)
    local seen = {}

    --- Walk the first-parent chain from `start_hash` as one flat lane
    --- (siblings under `lane_parent_id`), deferring any merge branches
    --- found along the way until the lane itself has been added to `tb`.
    local function walk_lane(lane_parent_id, start_hash)
        local items, branches = {}, {}
        local hash = start_hash
        while hash and commits[hash] and not seen[hash] do
            seen[hash] = true
            local commit = commits[hash]
            items[#items + 1] = { id = hash, data = commit, expanded = true }
            for i = 2, #commit.parents do
                local p = commit.parents[i]
                if commits[p] and not seen[p] then
                    branches[#branches + 1] = { at = hash, parent = p }
                end
            end
            hash = commit.parents[1]
        end
        tb:set_children(lane_parent_id, items)
        for _, b in ipairs(branches) do walk_lane(b.at, b.parent) end
    end

    for _, hash in ipairs(roots) do
        if not seen[hash] then walk_lane(nil, hash) end
    end
end

--- Populate `tb` as a flat, non-collapsible list in `order`.
---@param tb keystone.util.TreeBuffer
---@param commits table<string, GitTools.LogCommit>
---@param order string[]
local function _build_flat_list(tb, commits, order)
    local items = {}
    for _, hash in ipairs(order) do
        items[#items + 1] = { id = hash, data = commits[hash] }
    end
    tb:set_children(nil, items)
end

--- Diff `hash` against `flagged` (if set and different) or against its
--- first parent (or the empty tree, for a root commit) otherwise. Leaves the
--- log split open in its own tab -- `gittools.diff` opens the comparison in
--- a fresh tab, so the log stays put for further browsing.
---@param root     string
---@param session  GitTools.LogSession
---@param commit   GitTools.LogCommit
local function _diff_from_cursor(root, session, commit)
    local flagged = session.flagged
    if flagged and flagged ~= commit.hash then
        difftool.diff({ revs = { flagged, commit.hash } })
        return
    end
    local parent = commit.parents[1]
    if parent and git.verify_rev(root, parent) then
        difftool.diff({ revs = { parent, commit.hash } })
    else
        difftool.diff({ revs = { _EMPTY_TREE, commit.hash } })
    end
end

---@class GitTools.LogOpts
---@field rev  string?  start the log from this revision instead of HEAD
---@field path string?  scope the log to commits touching this path

--- List commit history in an interactive tree/graph split, starting from
--- `opts.rev` (default HEAD) and optionally scoped to `opts.path` -- mirrors
--- `git log [<rev>] [-- <path>]`.
---@param opts GitTools.LogOpts?
function M.log(opts)
    opts = opts or {}

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

    local args = { "log", "--pretty=format:%H\t%P\t%ad\t%s", "--date=short", "-n", tostring(_LIMIT) }
    if opts.rev then args[#args + 1] = opts.rev end
    if rel then
        args[#args + 1] = "--"
        args[#args + 1] = rel
    end

    local commits, order = _parse_commits((git.run(root, args)) or "")
    if #order == 0 then
        _notify("No commits found")
        return
    end

    _end_log()

    local session = { root = root, flagged = nil }
    local tb = TreeBuffer.new({
        filetype    = "gittoolslog",
        collapsible = not rel,
        formatter   = _formatter(session),
    })

    local buf = tb:create_buffer(function() _session = nil end)

    if rel then
        _build_flat_list(tb, commits, order)
    else
        _build_graph(tb, commits, order)
    end

    vim.cmd("botright new")
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    vim.api.nvim_win_set_height(win, math.min(20, #order))

    session.win = win
    _session = session

    vim.keymap.set("n", "gd", function()
        local item = tb:get_cursor_item()
        if not item then return end
        _diff_from_cursor(root, session, item.data)
    end, { buffer = buf, desc = "Diff flagged/parent commit" })

    vim.keymap.set("n", "<Tab>", function()
        local item = tb:get_cursor_item()
        if not item then return end
        local old = session.flagged
        session.flagged = item.data.hash
        if old then tb:refresh_item(old) end
        tb:refresh_item(session.flagged)
    end, { buffer = buf })

    vim.keymap.set("n", "q", _end_log, { buffer = buf })
end

return M
