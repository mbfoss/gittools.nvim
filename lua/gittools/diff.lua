local M   = {}

local git = require("gittools.git")

--- One side of a comparison. Exactly one field is set.
---@class GitTools.Side
---@field rev      string?  a git revision; content via `git show <rev>:<rel>`
---@field index    boolean? the index (staged); content via `git show :<rel>`
---@field worktree boolean? the live working-tree file

---@class GitTools.EntryData
---@field rel   string          relative path from repo root
---@field root  string          absolute path to repo root
---@field left  GitTools.Side   how to fetch left content
---@field right GitTools.Side   how to fetch right content

--- One diff tab. Several can be open at once; each owns its tab, windows,
--- generated buffers, and the location list attached to its right window.
---@class GitTools.DiffSession
---@field group      integer   augroup id for this session's autocmds
---@field tab        integer?  tabpage handle the diff lives in
---@field left_win   integer?  window for the left (base/source) side
---@field right_win  integer?  window for the right (target/live) side; owns the loclist
---@field buffers    integer[] generated virtual buffers to delete on close
---@field closing    boolean   reentrancy guard for close()
---@field setting_up boolean   reentrancy guard to stop infinite event loops

local _ENTRY_KEY = "gittools.diff"

---@type GitTools.DiffSession[]
local _sessions  = {}
local _next_id   = 0

---@param msg string
---@param level integer?
local function _notify(msg, level)
    vim.notify("[gittools] " .. msg, level or vim.log.levels.INFO)
end

--- Tear down `session`: drop its autocmds, close its windows (the location
--- list window follows its owning window), and delete its generated buffers.
--- Safe to invoke at any point.
---@param session GitTools.DiffSession
local function _close_session(session)
    if session.closing then return end
    session.closing = true

    for i, s in ipairs(_sessions) do
        if s == session then
            table.remove(_sessions, i)
            break
        end
    end

    pcall(vim.api.nvim_del_augroup_by_id, session.group)

    -- The loclist window survives nvim_win_close of its owner; close it first.
    if session.right_win and vim.api.nvim_win_is_valid(session.right_win) then
        local llwin = vim.fn.getloclist(session.right_win, { winid = 0 }).winid
        if llwin ~= 0 and vim.api.nvim_win_is_valid(llwin) then
            pcall(vim.api.nvim_win_close, llwin, false)
        end
    end

    for _, win_key in ipairs({ "left_win", "right_win" }) do
        local win = session[win_key] --[[@as integer?]]
        if win and vim.api.nvim_win_is_valid(win) then
            pcall(vim.api.nvim_win_close, win, false)
        end
        session[win_key] = nil
    end

    for _, bufnr in ipairs(session.buffers) do
        if vim.api.nvim_buf_is_valid(bufnr) then
            pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
        end
    end
    session.buffers = {}
    session.tab     = nil
end

--- Close every open diff session (e.g. on VimLeavePre).
function M.clear_session()
    -- _close_session removes the session from _sessions; iterate off a copy.
    for _, session in ipairs({ unpack(_sessions) }) do
        _close_session(session)
    end
end

--- Create a read-only scratch buffer filled with historical blob contents or empty for deletions
---@param session GitTools.DiffSession
---@param root string Repo root
---@param side GitTools.Side Side description
---@param rel string Relative path
---@param side_label string "left" or "right"
---@param filetype string Syntax highlighting string
---@return integer bufnr
local function _make_git_buf(session, root, side, rel, side_label, filetype)
    local buf = vim.api.nvim_create_buf(false, true)
    local lines = {}

    if side.worktree then
        local full_path = root .. "/" .. rel
        local existing = vim.fn.bufnr(full_path)
        if existing ~= -1 and vim.api.nvim_buf_is_loaded(existing) then
            lines = vim.api.nvim_buf_get_lines(existing, 0, -1, false)
        elseif vim.fn.filereadable(full_path) == 1 then
            lines = vim.fn.readfile(full_path)
        end
    else
        local spec = side.rev and (side.rev .. ":" .. rel) or (":" .. rel)
        local blob = git.run_raw(root, { "show", spec })
        if blob then
            lines = vim.split(blob, "\n", { plain = true })
            if lines[#lines] == "" then table.remove(lines) end
        end
    end

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].buftype    = "nofile"
    vim.bo[buf].bufhidden  = "wipe"
    vim.bo[buf].swapfile   = false
    vim.bo[buf].filetype   = filetype
    vim.bo[buf].modifiable = false
    -- set_lines marked the scratch buffer modified; clear it so window/tab
    -- closes aren't blocked by E445 when 'hidden' is off.
    vim.bo[buf].modified   = false

    local name_tag         = side.rev or (side.index and "index" or "worktree")
    vim.api.nvim_buf_set_name(buf, string.format("git://%d/%s/%s/%s", buf, name_tag, side_label, rel))

    table.insert(session.buffers, buf)

    return buf
end

--- Extract the session's current location-list item if it belongs to us
---@param session GitTools.DiffSession
---@return table? entry
local function _current_diff_entry(session)
    local win = session.right_win
    if not (win and vim.api.nvim_win_is_valid(win)) then return nil end
    local info = vim.fn.getloclist(win, { idx = 0, items = 1, size = 1 })
    if info.size == 0 then return nil end

    local entry = info.items[info.idx]
    if not (entry and entry.user_data and entry.user_data[_ENTRY_KEY]) then
        return nil
    end
    return entry
end

--- Drive side-by-side native splits using fresh contextual buffer snapshots
---@param session GitTools.DiffSession
---@param entry table
local function _setup_diff(session, entry)
    if session.setting_up then return end
    session.setting_up = true

    local lw, rw = session.left_win, session.right_win
    if not (lw and vim.api.nvim_win_is_valid(lw) and rw and vim.api.nvim_win_is_valid(rw)) then
        session.setting_up = false
        return
    end

    ---@type GitTools.EntryData
    local ud = entry.user_data[_ENTRY_KEY]
    local filetype = vim.filetype.match({ filename = ud.rel }) or ""

    local right_buf
    if ud.right.worktree then
        right_buf = vim.fn.bufadd(ud.root .. "/" .. ud.rel)
        vim.fn.bufload(right_buf)
    else
        right_buf = _make_git_buf(session, ud.root, ud.right, ud.rel, "right", filetype)
    end

    local left_buf = _make_git_buf(session, ud.root, ud.left, ud.rel, "left", filetype)

    vim.api.nvim_win_set_buf(lw, left_buf)
    vim.api.nvim_win_set_buf(rw, right_buf)

    vim.api.nvim_win_call(lw, function() vim.cmd("diffoff!") end)
    vim.api.nvim_win_call(rw, vim.cmd.diffthis)
    vim.api.nvim_win_call(lw, vim.cmd.diffthis)

    session.setting_up = false
end

--- Build a standalone tab page layout without nvim.difftool orchestration
---@param session GitTools.DiffSession
local function _build_layout(session)
    vim.cmd.tabnew()
    session.tab      = vim.api.nvim_get_current_tabpage()
    session.left_win = vim.api.nvim_get_current_win()
    vim.cmd("rightbelow vsplit")
    session.right_win = vim.api.nvim_get_current_win()

    for _, win in ipairs({ session.left_win, session.right_win }) do
        vim.api.nvim_create_autocmd("WinClosed", {
            group    = session.group,
            pattern  = tostring(win),
            callback = function() _close_session(session) end,
        })
    end
    vim.api.nvim_create_autocmd("TabClosed", {
        group    = session.group,
        callback = function()
            if not (session.tab and vim.api.nvim_tabpage_is_valid(session.tab)) then
                _close_session(session)
            end
        end,
    })
end

--- Installs the tracking hook for running dynamic side updates upon navigation
---@param session GitTools.DiffSession
local function _register_autocmds(session)
    vim.api.nvim_create_autocmd("BufWinEnter", {
        group    = session.group,
        pattern  = "*",
        callback = function()
            -- Ignore BufWinEnter events fired synchronously by our own
            -- nvim_win_set_buf calls in _setup_diff; otherwise they re-trigger
            -- setup endlessly.
            if session.setting_up then return end
            local win = vim.api.nvim_get_current_win()
            if win ~= session.left_win and win ~= session.right_win then return end
            local entry = _current_diff_entry(session)
            if not entry then return end
            vim.schedule(function() _setup_diff(session, entry) end)
        end,
    })
end

--- Resolve parsed CLI options into the left/right sides of the comparison.
---@param staged boolean
---@param revs   string[]
---@return GitTools.Side? left
---@return GitTools.Side? right
---@return string?       err  set (with left/right nil) when the args are invalid
local function _resolve_sides(staged, revs)
    if #revs > 2 then return nil, nil, "GitTool diff takes at most two revisions" end
    if staged then
        if #revs >= 2 then return nil, nil, "GitTool diff --staged takes at most one revision" end
        return { rev = revs[1] or "HEAD" }, { index = true }
    end
    if #revs >= 2 then
        return { rev = revs[1] }, { rev = revs[2] }
    elseif #revs == 1 then
        return { rev = revs[1] }, { worktree = true }
    end
    return { index = true }, { worktree = true }
end

--- The set of paths (relative to the repo root) that differ between `left` and
--- `right`. Untracked files are included only when the working tree is the
--- right side (git's own `--name-only` never lists them). When the working tree
--- is the right side, files that only differ via unsaved buffer edits (clean on
--- disk, dirty in a loaded buffer) are also included. Deduped, sorted.
---@param root  string repo root
---@param left  GitTools.Side
---@param right GitTools.Side
---@return string[] rels
function M.changed_paths_between(root, left, right)
    local args, include_untracked
    if right.worktree then
        args = { "diff", "--name-only" }
        if left.rev then args[#args + 1] = left.rev end
        include_untracked = true
    elseif right.index then
        args, include_untracked = { "diff", "--name-only", "--cached", left.rev }, false
    else
        args, include_untracked = { "diff", "--name-only", left.rev, right.rev }, false
    end

    local seen, rels = {}, {}
    local function add(rel)
        if rel ~= "" and not seen[rel] then
            seen[rel] = true
            rels[#rels + 1] = rel
        end
    end

    for _, rel in ipairs(git.lines((git.run(root, args)))) do add(rel) end
    if include_untracked then
        for _, rel in ipairs(git.lines((git.run(root, { "ls-files", "--others", "--exclude-standard" })))) do
            add(rel)
        end
        for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_is_loaded(bufnr)
                and vim.bo[bufnr].modified
                and vim.bo[bufnr].buftype == "" then
                local rel = git.relpath(root, vim.api.nvim_buf_get_name(bufnr))
                if rel then add(rel) end
            end
        end
    end

    table.sort(rels)
    return rels
end

--- Back-compat shorthand for "working tree vs `rev`".
---@param root string repo root
---@param rev  string
---@return string[] rels
function M.changed_paths(root, rev)
    return M.changed_paths_between(root, { rev = rev }, { worktree = true })
end

---@class GitTools.DiffOpts
---@field staged boolean?  compare the index instead of the working tree
---@field revs   string[]? zero, one, or two revisions (see git-diff semantics)
---@field root   string?   repo root to diff in (default: the root containing the editor's cwd)

--- Diff the requested revisions/index/working-tree sides in a dedicated tab,
--- driving a location list of changed paths and a side-by-side native diff.
--- Each call opens its own tab; existing diff tabs are left untouched.
---@param opts GitTools.DiffOpts?
function M.diff(opts)
    opts = opts or {}
    local staged = opts.staged or false
    local revs = opts.revs or {}

    local left, right, err = _resolve_sides(staged, revs)
    if err then
        _notify(err, vim.log.levels.ERROR)
        return
    end
    ---@cast left GitTools.Side
    ---@cast right GitTools.Side

    local root = opts.root or git.root()
    if not root then
        _notify("Not inside a git repository", vim.log.levels.WARN)
        return
    end

    for _, side in ipairs({ left, right }) do
        if side.rev and not git.verify_rev(root, side.rev) then
            _notify("Unknown revision: " .. side.rev, vim.log.levels.ERROR)
            return
        end
    end

    local rels = M.changed_paths_between(root, left, right)
    if #rels == 0 then
        _notify("No changes found")
        return
    end

    local entries = {}
    for _, rel in ipairs(rels) do
        entries[#entries + 1] = {
            filename  = root .. "/" .. rel,
            text      = "±",
            user_data = {
                [_ENTRY_KEY] = { root = root, rel = rel, left = left, right = right }
            }
        }
    end

    _next_id = _next_id + 1
    ---@type GitTools.DiffSession
    local session = {
        group      = vim.api.nvim_create_augroup("gittools.diff." .. _next_id, { clear = true }),
        tab        = nil,
        left_win   = nil,
        right_win  = nil,
        buffers    = {},
        closing    = false,
        setting_up = false,
    }
    _sessions[#_sessions + 1] = session

    _register_autocmds(session)
    _build_layout(session)

    vim.fn.setloclist(session.right_win, {}, " ", {
        title            = "GitTool Diff Layout",
        items            = entries,
        quickfixtextfunc = function(info)
            local items = vim.fn.getloclist(info.winid, { id = info.id, items = 1 }).items
            local out = {}
            for i = info.start_idx, info.end_idx do
                local e       = items[i]
                local ud      = e.user_data and e.user_data[_ENTRY_KEY]
                out[#out + 1] = string.format("%s %s", e.text or "*", ud and ud.rel or e.filename)
            end
            return out
        end,
    })

    -- The loclist window can only be opened once its window has a list.
    vim.api.nvim_win_call(session.right_win, function() vim.cmd("botright lopen") end)
    vim.api.nvim_set_current_win(session.right_win)
    vim.cmd.lfirst()
end

return M
