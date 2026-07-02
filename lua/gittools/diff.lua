local M   = {}

local git = require("gittools.git")

--- One side of a comparison. Exactly one field is set.
---@class GitTools.Side
---@field rev      string?  a git revision; content via `git show <rev>:<rel>`
---@field index    boolean? the index (staged); content via `git show :<rel>`
---@field worktree boolean? the live working-tree file

---@class GitTools.EntryData
---@field root      string  absolute path to repo root
---@field left_rel  string? relative path on the left side; nil if the file
---                          doesn't exist there (e.g. it was added)
---@field right_rel string? relative path on the right side; nil if the file
---                          doesn't exist there (e.g. it was deleted)
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

-- Status letters (mirroring `git status --short`) rendered at the start of
-- each location-list line, and the highlight group each links to by default.
-- Linked to the builtin `Diagnostic*` groups rather than `Diff*`: those are
-- mostly background fills meant for whole lines, so on a single character
-- they read as an easy-to-miss colored speck (only `Title`, used for R/C in
-- an earlier pass, was ever visible). `Diagnostic*` groups are foreground
-- colors instead, so a single highlighted letter still stands out, and
-- they're guaranteed to exist in any Neovim >= 0.6 regardless of colorscheme.
-- `default = true` lets colorschemes/users override without editing here.
local _STATUS_HL = {
    A = { "GitToolsStatusAdded",     "DiagnosticOk" },
    M = { "GitToolsStatusModified",  "DiagnosticWarn" },
    D = { "GitToolsStatusDeleted",   "DiagnosticError" },
    R = { "GitToolsStatusRenamed",   "DiagnosticInfo" },
    C = { "GitToolsStatusCopied",    "DiagnosticHint" },
    ["?"] = { "GitToolsStatusUntracked", "Comment" },
}

for _, pair in pairs(_STATUS_HL) do
    vim.api.nvim_set_hl(0, pair[1], { link = pair[2], default = true })
end

--- Color each location-list line by its leading status letter (see
--- `_STATUS_HL`). Scoped to `bufnr` alone so it can't bleed into unrelated
--- quickfix/location-list windows elsewhere in the session.
---@param bufnr integer
local function _highlight_loclist(bufnr)
    vim.api.nvim_buf_call(bufnr, function()
        for status, pair in pairs(_STATUS_HL) do
            local pattern = status == "?" and [[^?]] or ("^" .. status .. [[\>]])
            vim.cmd(string.format("syntax match %s /%s/", pair[1], pattern))
        end
    end)
end

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
---@param rel string? Relative path on this side; nil if the file doesn't
---                    exist on this side (e.g. it was added or deleted)
---@param side_label string "left" or "right"
---@param filetype string Syntax highlighting string
---@return integer bufnr
local function _make_git_buf(session, root, side, rel, side_label, filetype)
    local buf = vim.api.nvim_create_buf(false, true)
    local lines = {}

    if rel then
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
    vim.api.nvim_buf_set_name(buf, string.format("git://%d/%s/%s/%s", buf, name_tag, side_label, rel or "(none)"))

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
    local filetype = vim.filetype.match({ filename = ud.right_rel or ud.left_rel }) or ""

    local right_buf
    if ud.right.worktree and ud.right_rel then
        right_buf = vim.fn.bufadd(ud.root .. "/" .. ud.right_rel)
        vim.fn.bufload(right_buf)
    else
        right_buf = _make_git_buf(session, ud.root, ud.right, ud.right_rel, "right", filetype)
    end

    local left_buf = _make_git_buf(session, ud.root, ud.left, ud.left_rel, "left", filetype)

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

    -- Defer teardown: closing further windows synchronously from WinClosed
    -- breaks commands like :tabclose that are still mid-close (E445).
    local function close_later()
        vim.schedule(function() _close_session(session) end)
    end
    for _, win in ipairs({ session.left_win, session.right_win }) do
        vim.api.nvim_create_autocmd("WinClosed", {
            group    = session.group,
            pattern  = tostring(win),
            callback = close_later,
        })
    end
    vim.api.nvim_create_autocmd("TabClosed", {
        group    = session.group,
        callback = function()
            if not (session.tab and vim.api.nvim_tabpage_is_valid(session.tab)) then
                close_later()
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

---@class GitTools.Change
---@field left_rel  string? path on the left side; nil if the file was added
---@field right_rel string? path on the right side; nil if the file was deleted
---@field status     "A"|"M"|"D"|"R"|"C"|"?" single-letter status, mirroring
---                   `git status --short` (`?` for untracked)

--- Parse `git diff --name-status -M` output into per-file change records,
--- keeping the old and new paths of a rename/copy distinct instead of
--- collapsing them into a single name.
---@param out string?
---@return GitTools.Change[]
local function _parse_name_status(out)
    local changes = {}
    for _, line in ipairs(git.lines(out)) do
        local parts  = vim.split(line, "\t", { plain = true })
        local status = parts[1]:sub(1, 1)
        if status == "R" or status == "C" then
            changes[#changes + 1] = { left_rel = parts[2], right_rel = parts[3], status = status }
        elseif status == "A" then
            changes[#changes + 1] = { right_rel = parts[2], status = status }
        elseif status == "D" then
            changes[#changes + 1] = { left_rel = parts[2], status = status }
        else
            changes[#changes + 1] = { left_rel = parts[2], right_rel = parts[2], status = "M" }
        end
    end
    return changes
end

--- The changes (relative to the repo root) between `left` and `right`, with
--- renames/copies kept as distinct old/new paths rather than collapsed into
--- one name (plain `--name-only` reports only the new path, which breaks
--- diffing against the old content). Untracked files are included only when
--- the working tree is the right side (git never reports those as a diff
--- status on its own). When the working tree is the right side, files that
--- only differ via unsaved buffer edits (clean on disk, dirty in a loaded
--- buffer) are also included. Deduped, sorted.
---@param root  string repo root
---@param left  GitTools.Side
---@param right GitTools.Side
---@return GitTools.Change[] changes
local function _collect_changes(root, left, right)
    local args, include_untracked
    if right.worktree then
        args = { "diff", "--name-status", "-M" }
        if left.rev then args[#args + 1] = left.rev end
        include_untracked = true
    elseif right.index then
        args, include_untracked = { "diff", "--name-status", "-M", "--cached", left.rev }, false
    else
        args, include_untracked = { "diff", "--name-status", "-M", left.rev, right.rev }, false
    end

    local seen, changes = {}, {}
    ---@param change GitTools.Change
    local function add(change)
        -- Deletions have no right_rel, so key those on left_rel instead.
        local key = change.right_rel and ("r:" .. change.right_rel) or ("l:" .. (change.left_rel or ""))
        if not seen[key] then
            seen[key] = true
            changes[#changes + 1] = change
        end
    end

    for _, change in ipairs(_parse_name_status((git.run(root, args)))) do add(change) end
    if include_untracked then
        for _, rel in ipairs(git.lines((git.run(root, { "ls-files", "--others", "--exclude-standard" })))) do
            add({ right_rel = rel, status = "?" })
        end
        for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_is_loaded(bufnr)
                and vim.bo[bufnr].modified
                and vim.bo[bufnr].buftype == "" then
                local rel = git.relpath(root, vim.api.nvim_buf_get_name(bufnr))
                if rel then add({ left_rel = rel, right_rel = rel, status = "M" }) end
            end
        end
    end

    table.sort(changes, function(a, b)
        return (a.right_rel or a.left_rel) < (b.right_rel or b.left_rel)
    end)
    return changes
end

--- The set of paths (relative to the repo root) that differ between `left`
--- and `right`. For renames/copies this reports only the new path; use
--- `_collect_changes` where the old path (for diffing against prior content)
--- is also needed.
---@param root  string repo root
---@param left  GitTools.Side
---@param right GitTools.Side
---@return string[] rels
function M.changed_paths_between(root, left, right)
    local rels = {}
    for _, change in ipairs(_collect_changes(root, left, right)) do
        rels[#rels + 1] = change.right_rel or change.left_rel
    end
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

    local changes = _collect_changes(root, left, right)
    if #changes == 0 then
        _notify("No changes found")
        return
    end

    local entries = {}
    for _, change in ipairs(changes) do
        local display = change.right_rel or change.left_rel
        entries[#entries + 1] = {
            filename  = root .. "/" .. display,
            text      = change.status,
            user_data = {
                [_ENTRY_KEY] = {
                    root      = root,
                    left_rel  = change.left_rel,
                    right_rel = change.right_rel,
                    left      = left,
                    right     = right,
                }
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
                local label   = e.filename
                if ud then
                    if ud.left_rel and ud.right_rel and ud.left_rel ~= ud.right_rel then
                        label = string.format("%s -> %s", ud.left_rel, ud.right_rel)
                    else
                        label = ud.right_rel or ud.left_rel
                    end
                end
                out[#out + 1] = string.format("%s %s", e.text or "*", label)
            end
            return out
        end,
    })

    -- The loclist window can only be opened once its window has a list.
    vim.api.nvim_win_call(session.right_win, function() vim.cmd("botright lopen") end)
    local llwin = vim.fn.getloclist(session.right_win, { winid = 0 }).winid
    if llwin ~= 0 then
        _highlight_loclist(vim.api.nvim_win_get_buf(llwin))
    end
    vim.api.nvim_set_current_win(session.right_win)
    vim.cmd.lfirst()
end

return M
