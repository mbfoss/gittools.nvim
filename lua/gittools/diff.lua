local M           = {}

local git         = require("gittools.git")

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

--- Active session state tracking
---@class GitTools.Layout
---@field group     integer?  augroup id, nil when no session is active
---@field tab       integer?  tabpage handle the diff lives in
---@field left_win  integer?  window for the left (base/source) side
---@field right_win integer?  window for the right (target/live) side
---@field buffers   integer[] tracking list of generated virtual buffers to clear on reset
local _layout     = { group = nil, tab = nil, left_win = nil, right_win = nil, buffers = {} }

local _ENTRY_KEY  = "gittools.diff"
local _closing    = false
local _setting_up = false  -- Reentrancy guard to stop infinite event loops

---@param msg string
---@param level integer?
local function _notify(msg, level)
    vim.notify("[gittools] " .. msg, level or vim.log.levels.INFO)
end

--- Delete previous virtual buffers, close layout windows/tabs, and clear autocommands.
--- Safe to invoke at any point to reset state completely.
function M.clear_session()
    if _closing then return end
    _closing = true

    -- 1. Clear autocommands
    if _layout.group then
        pcall(vim.api.nvim_del_augroup_by_id, _layout.group)
        _layout.group = nil
    end

    -- 2. Close quickfix window
    vim.cmd.cclose()

    -- 3. Safely kill layout windows
    for _, win_key in ipairs({ "left_win", "right_win" }) do
        local win = _layout[win_key] --[[@as integer?]]
        if win and vim.api.nvim_win_is_valid(win) then
            pcall(vim.api.nvim_win_close, win, false)
        end
        _layout[win_key] = nil
    end

    -- 4. Purge generated temporary virtual memory buffers
    if _layout.buffers then
        for _, bufnr in ipairs(_layout.buffers) do
            if vim.api.nvim_buf_is_valid(bufnr) then
                pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
            end
        end
        _layout.buffers = {}
    end

    _layout.tab = nil
    _closing    = false
end

--- Wrapper to safely route window closure triggers back to standard session cleanup
local function _cleanup()
    M.clear_session()
end

--- Create a read-only scratch buffer filled with historical blob contents or empty for deletions
---@param root string Repo root
---@param side GitTools.Side Side description
---@param rel string Relative path
---@param side_label string "left" or "right"
---@param filetype string Syntax highlighting string
---@return integer bufnr
local function _make_git_buf(root, side, rel, side_label, filetype)
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

    local name_tag         = side.rev or (side.index and "index" or "worktree")
    vim.api.nvim_buf_set_name(buf, string.format("git://%d/%s/%s/%s", buf, name_tag, side_label, rel))

    table.insert(_layout.buffers, buf)

    return buf
end

--- Extract the active layout quickfix item payload if it belongs to us
---@return table? entry
local function _current_diff_entry()
    local info = vim.fn.getqflist({ idx = 0, items = 1, size = 1 })
    if info.size == 0 then return nil end

    local entry = info.items[info.idx]
    if not (entry and entry.user_data and entry.user_data[_ENTRY_KEY]) then
        return nil
    end
    return entry
end

--- Drive side-by-side native splits using fresh contextual buffer snapshots
---@param entry table
local function _setup_diff(entry)
    if _setting_up then return end
    _setting_up = true

    local lw, rw = _layout.left_win, _layout.right_win
    if not (lw and vim.api.nvim_win_is_valid(lw) and rw and vim.api.nvim_win_is_valid(rw)) then
        _setting_up = false
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
        right_buf = _make_git_buf(ud.root, ud.right, ud.rel, "right", filetype)
    end

    local left_buf = _make_git_buf(ud.root, ud.left, ud.rel, "left", filetype)

    vim.api.nvim_win_set_buf(lw, left_buf)
    vim.api.nvim_win_set_buf(rw, right_buf)

    vim.api.nvim_win_call(lw, function() vim.cmd("diffoff!") end)
    vim.api.nvim_win_call(rw, vim.cmd.diffthis)
    vim.api.nvim_win_call(lw, vim.cmd.diffthis)

    _setting_up = false
end

--- Build a standalone tab page layout without nvim.difftool orchestration
local function _build_layout()
    vim.cmd.tabnew()
    _layout.tab      = vim.api.nvim_get_current_tabpage()
    _layout.left_win = vim.api.nvim_get_current_win()
    vim.cmd("rightbelow vsplit")
    _layout.right_win = vim.api.nvim_get_current_win()
    vim.cmd("botright copen")
    vim.api.nvim_set_current_win(_layout.right_win)

    for _, win in ipairs({ _layout.left_win, _layout.right_win }) do
        vim.api.nvim_create_autocmd("WinClosed", {
            group    = _layout.group,
            pattern  = tostring(win),
            callback = _cleanup,
        })
    end
    vim.api.nvim_create_autocmd("TabClosed", {
        group    = _layout.group,
        callback = function()
            if not (_layout.tab and vim.api.nvim_tabpage_is_valid(_layout.tab)) then
                _cleanup()
            end
        end,
    })
end

--- Installs the tracking hook for running dynamic side updates upon navigation
local function _register_autocmds()
    vim.api.nvim_create_autocmd("BufWinEnter", {
        group    = _layout.group,
        pattern  = "*",
        callback = function()
            -- Ignore BufWinEnter events fired synchronously by our own
            -- nvim_win_set_buf calls in _setup_diff; otherwise they re-trigger
            -- setup endlessly.
            if _setting_up then return end
            local win = vim.api.nvim_get_current_win()
            if win ~= _layout.left_win and win ~= _layout.right_win then return end
            local entry = _current_diff_entry()
            if not entry then return end
            vim.schedule(function() _setup_diff(entry) end)
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

--- Diff the requested revisions/index/working-tree sides in a dedicated tab,
--- driving a quickfix list of changed paths and a side-by-side native diff.
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

    local root = git.root()
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

    M.clear_session()

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

    _layout.group = vim.api.nvim_create_augroup("gittools.diff", { clear = true })
    _register_autocmds()

    vim.fn.setqflist({}, " ", {
        title            = "GitTool Diff Layout",
        items            = entries,
        quickfixtextfunc = function(info)
            local items = vim.fn.getqflist({ id = info.id, items = 1 }).items
            local out = {}
            for i = info.start_idx, info.end_idx do
                local e       = items[i]
                local ud      = e.user_data and e.user_data[_ENTRY_KEY]
                out[#out + 1] = string.format("%s %s", e.text or "*", ud and ud.rel or e.filename)
            end
            return out
        end,
    })

    _build_layout()
    vim.cmd.cfirst()
end

return M
