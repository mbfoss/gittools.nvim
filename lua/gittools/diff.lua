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

--- One diff session, living in a vertical split of the window it was launched
--- from. It owns its two split windows, the generated buffers, and the
--- location list attached to its right window. On teardown it collapses back
--- to a single window so the original layout is restored.
---@class GitTools.DiffSession
---@field group      integer   augroup id for this session's autocmds
---@field left_win   integer?  window for the left (base/source) side
---@field right_win  integer?  window for the right (target/live) side; owns the loclist
---@field loclist_win integer? the location-list window (records it so we can
---                            still close it once right_win is gone)
---@field buffers    integer[] generated virtual buffers to delete on close
---@field closing    boolean   reentrancy guard for close()
---@field setting_up boolean   reentrancy guard to stop infinite event loops
---@field shown_idx  integer?  loclist index whose diff is currently built, so
---                            a repeat setup for the same entry is a no-op

local _ENTRY_KEY = "gittools.diff"

-- setloclist `title`, used both to populate the list and to recognize (in
-- the QuickFixCmdPost guard below) whether the right window's location list
-- is still ours or has been overwritten by an unrelated :lvimgrep/:laddexpr.
local _LOCLIST_TITLE = "GitTool Diff Layout"

-- Only a single diff session exists at a time; opening a new diff tears down
-- the previous one (see M.diff). nil when idle.
---@type GitTools.DiffSession?
local _session   = nil
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

-- Unicode "rightwards arrow", used in place of a plain "->" between the old
-- and new path of a rename/copy entry. Deliberately not a heavier Nerd Font
-- glyph (e.g. nf-fa-arrow_right): this reads lighter at a glance and needs
-- no patched font.
local _RENAME_ARROW = vim.fn.nr2char(0x2192)
local _RENAME_ARROW_PAT = vim.fn.escape(_RENAME_ARROW, [[/\.*$^~[]])

vim.api.nvim_set_hl(0, "GitToolsRenameArrow", { link = "GitToolsStatusRenamed", default = true })
vim.api.nvim_set_hl(0, "GitToolsRenameOldPath", { link = "Comment", default = true })

---@param path string
---@return string[]
local function _path_segments(path)
    local segs = {}
    for seg in path:gmatch("[^/]+") do
        segs[#segs + 1] = seg
    end
    return segs
end

--- The label for a rename/copy entry. Mirrors git's own condensed rename
--- display: path segments shared between the old and new path (a common
--- prefix and/or suffix, e.g. a directory both paths live in, or a filename
--- both paths share) are printed once, with only the part that actually
--- changed shown inside `{old -> new}`. Falls back to the full "old -> new"
--- form when the two paths share no whole segment.
---@param old_rel string
---@param new_rel string
---@return string
local function _rename_label(old_rel, new_rel)
    local old_segs, new_segs = _path_segments(old_rel), _path_segments(new_rel)
    local n_old, n_new = #old_segs, #new_segs

    local prefix = 0
    while prefix < n_old and prefix < n_new and old_segs[prefix + 1] == new_segs[prefix + 1] do
        prefix = prefix + 1
    end

    local suffix = 0
    while suffix < (n_old - prefix) and suffix < (n_new - prefix)
        and old_segs[n_old - suffix] == new_segs[n_new - suffix] do
        suffix = suffix + 1
    end

    if prefix == 0 and suffix == 0 then
        return string.format("%s %s %s", old_rel, _RENAME_ARROW, new_rel)
    end

    local mid_old, mid_new = {}, {}
    for i = prefix + 1, n_old - suffix do mid_old[#mid_old + 1] = old_segs[i] end
    for i = prefix + 1, n_new - suffix do mid_new[#mid_new + 1] = new_segs[i] end

    local parts = {}
    if prefix > 0 then
        parts[#parts + 1] = table.concat(old_segs, "/", 1, prefix) .. "/"
    end
    parts[#parts + 1] = string.format(
        "{%s %s %s}", table.concat(mid_old, "/"), _RENAME_ARROW, table.concat(mid_new, "/"))
    if suffix > 0 then
        parts[#parts + 1] = "/" .. table.concat(old_segs, "/", n_old - suffix + 1, n_old)
    end

    return table.concat(parts)
end

--- Color each location-list line by its leading status letter (see
--- `_STATUS_HL`). Rename/copy lines additionally get their arrow colored to
--- match the status letter, and the superseded (old) path dimmed. Scoped to
--- `bufnr` alone so it can't bleed into unrelated quickfix/location-list
--- windows elsewhere in the session.
---@param bufnr integer
local function _highlight_loclist(bufnr)
    vim.api.nvim_buf_call(bufnr, function()
        for status, pair in pairs(_STATUS_HL) do
            local pattern = status == "?" and [[^?]] or ("^" .. status .. [[\>]])
            vim.cmd(string.format("syntax match %s /%s/", pair[1], pattern))
        end
        vim.cmd(string.format([[syntax match GitToolsRenameArrow /%s/]], _RENAME_ARROW_PAT))
        vim.cmd([[syntax match GitToolsRenameArrow /[{}]/]])
        vim.cmd(string.format(
            [[syntax match GitToolsRenameOldPath /{\zs.\{-}\ze %s/]], _RENAME_ARROW_PAT))
        vim.cmd(string.format(
            [[syntax match GitToolsRenameOldPath /^[RC] \zs[^{]\{-}\ze %s/]], _RENAME_ARROW_PAT))
    end)
end

---@param msg string
---@param level integer?
local function _notify(msg, level)
    vim.notify("[gittools] " .. msg, level or vim.log.levels.INFO)
end

--- Tear down `session`: drop its autocmds, close the location list, collapse
--- the side-by-side split back to a single surviving window (so the original
--- layout is restored), and delete its generated buffers. Safe to invoke at
--- any point, whichever of the split windows or the loclist the user closed.
---@param session GitTools.DiffSession
local function _close_session(session)
    if session.closing then return end
    session.closing = true

    if _session == session then _session = nil end

    -- Drop the autocmds before closing anything, so the window closes below
    -- don't re-trigger teardown through our own WinClosed hooks.
    vim.api.nvim_del_augroup_by_id(session.group)

    -- The loclist window survives nvim_win_close of its owner; close it first.
    -- Prefer the window recorded at open time: once right_win (the list's
    -- owner) has itself been closed, getloclist can no longer locate the list,
    -- so a lookup keyed on right_win would miss it and leave the loclist window
    -- behind.
    local llwin = session.loclist_win
    if not (llwin and vim.api.nvim_win_is_valid(llwin))
        and session.right_win and vim.api.nvim_win_is_valid(session.right_win) then
        local found = vim.fn.getloclist(session.right_win, { winid = 0 }).winid
        llwin = found ~= 0 and found or nil
    end
    if llwin and vim.api.nvim_win_is_valid(llwin) then
        pcall(vim.api.nvim_win_close, llwin, false)
    end
    session.loclist_win = nil

    -- Keep exactly one of the two split windows so the layout collapses back
    -- to a single window. Prefer the right (target/worktree) side; fall back
    -- to the left when the user closed the right one.
    local left_valid  = session.left_win and vim.api.nvim_win_is_valid(session.left_win)
    local right_valid = session.right_win and vim.api.nvim_win_is_valid(session.right_win)
    local survivor    = (right_valid and session.right_win) or (left_valid and session.left_win) or nil

    for _, win in ipairs({ session.left_win, session.right_win }) do
        if win and win ~= survivor and vim.api.nvim_win_is_valid(win) then
            pcall(vim.api.nvim_win_close, win, false)
        end
    end
    if survivor and vim.api.nvim_win_is_valid(survivor) then
        vim.api.nvim_win_call(survivor, function() vim.cmd("diffoff") end)
    end
    session.left_win  = nil
    session.right_win = nil

    -- Delete the generated buffers, but spare whichever one is still shown in
    -- the surviving window so it doesn't blank out under the user.
    local keep = survivor and vim.api.nvim_win_is_valid(survivor)
        and vim.api.nvim_win_get_buf(survivor) or nil
    for _, bufnr in ipairs(session.buffers) do
        if bufnr ~= keep and vim.api.nvim_buf_is_valid(bufnr) then
            pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
        end
    end
    session.buffers = {}
end

--- Close the active diff session, if any (e.g. on VimLeavePre).
function M.clear_session()
    if _session then _close_session(_session) end
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
    -- set_lines marked the scratch buffer modified; clear it so window
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

    -- Skip if the currently selected entry's diff is already built. Lets the
    -- initial setup be driven explicitly (see M.diff) while any redundant
    -- BufWinEnter for the same entry -- e.g. the one `:lfirst` fires -- is a
    -- harmless no-op rather than a second, buffer-leaking rebuild.
    local idx = vim.fn.getloclist(rw, { idx = 0 }).idx
    if session.shown_idx == idx then
        session.setting_up = false
        return
    end
    session.shown_idx = idx

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

--- Split the current window into the side-by-side diff layout, reusing the
--- launching window as the left side and a vertical split as the right side.
--- Closing either split window (or, once registered, the location list) tears
--- the session down and collapses back to a single window.
---@param session GitTools.DiffSession
local function _build_layout(session)
    session.left_win = vim.api.nvim_get_current_win()
    vim.cmd("rightbelow vsplit")
    session.right_win = vim.api.nvim_get_current_win()

    -- Defer teardown: closing further windows synchronously from WinClosed
    -- breaks Neovim's own mid-close bookkeeping (E445).
    for _, win in ipairs({ session.left_win, session.right_win }) do
        vim.api.nvim_create_autocmd("WinClosed", {
            group    = session.group,
            pattern  = tostring(win),
            callback = function() vim.schedule(function() _close_session(session) end) end,
        })
    end
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

    -- Commands like :lvimgrep, :lgrep, or :laddexpr silently replace the
    -- right window's location list (and drop our quickfixtextfunc), leaving
    -- the loclist buffer's `syntax match` status-letter highlighting behind
    -- to mismatch against unrelated content. Detect the takeover via the
    -- list title and tear the session down rather than let it show stale
    -- highlights over a list it no longer owns.
    vim.api.nvim_create_autocmd("QuickFixCmdPost", {
        group    = session.group,
        pattern  = "l*",
        callback = function()
            if not (session.right_win and vim.api.nvim_win_is_valid(session.right_win)) then
                return
            end
            local info = vim.fn.getloclist(session.right_win, { title = 1 })
            if info.title ~= _LOCLIST_TITLE then
                vim.schedule(function() _close_session(session) end)
            end
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

--- Diff the requested revisions/index/working-tree sides by splitting the
--- current window, driving a location list of changed paths and a
--- side-by-side native diff. Closing either split window or the location list
--- collapses back to a single window, restoring the original layout.
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
        left_win    = nil,
        right_win   = nil,
        loclist_win = nil,
        buffers    = {},
        closing    = false,
        setting_up = false,
        shown_idx  = nil,
    }
    -- Only a single diff at a time: tear down any existing session before
    -- building the new one. Done here, after every early return above, so a
    -- diff that turns out to be invalid or empty leaves the current one intact.
    if _session then _close_session(_session) end
    _session = session

    _register_autocmds(session)
    _build_layout(session)

    vim.fn.setloclist(session.right_win, {}, " ", {
        title            = _LOCLIST_TITLE,
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
                        label = _rename_label(ud.left_rel, ud.right_rel)
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
        session.loclist_win = llwin
        _highlight_loclist(vim.api.nvim_win_get_buf(llwin))
        -- Closing the location list on its own also collapses the session, so
        -- the user only ever needs one close to get back to a single window.
        vim.api.nvim_create_autocmd("WinClosed", {
            group    = session.group,
            pattern  = tostring(llwin),
            callback = function() vim.schedule(function() _close_session(session) end) end,
        })
    end
    vim.api.nvim_set_current_win(session.right_win)
    vim.cmd.lfirst()

    -- Bootstrap the first entry's diff explicitly rather than leaning on the
    -- BufWinEnter that `:lfirst` happens to fire: that event doesn't fire when
    -- the (possibly reused) right window already displays the first entry's
    -- file, which would otherwise leave the diff unbuilt. The shown_idx guard
    -- in _setup_diff keeps this from double-building in the common case.
    local entry = _current_diff_entry(session)
    if entry then _setup_diff(session, entry) end
end

return M
