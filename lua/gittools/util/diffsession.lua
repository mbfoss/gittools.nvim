local M          = {}

local git        = require("gittools.git")
local ui         = require("gittools.util.ui")

--- The generic engine behind the side-by-side diff UI: it takes a flat list of
--- "items" (each describing a file's status and how to fetch its left/right
--- content) and drives the split layout, the file-list picker, and the native
--- diff. It knows nothing about where the items came from -- `gittools.diff`
--- feeds it git revision/index/worktree comparisons, `gittools.diffpaths` feeds
--- it two arbitrary files or directories -- so all the window/buffer plumbing
--- lives here once.

--- One side of a comparison. Exactly one field is set.
---@class GitTools.Side
---@field rev      string?  a git revision; content via `git show <rev>:<rel>`
---@field index    boolean? the index (staged); content via `git show :<rel>`
---@field worktree boolean? the live working-tree file
---@field path     string?  an absolute filesystem path read directly off disk,
---                          for comparisons that need not lie in any repository;
---                          nil `path` here means the file is absent on this
---                          side (added/deleted)

--- One file to show in the list, plus how to fetch each side's content. This is
--- the engine's input; callers build a list of these and hand it to `M.open`.
---@class GitTools.DiffItem
---@field status    "A"|"M"|"D"|"R"|"C"|"?" single-letter status
---@field root      string?  repo root for git-backed Sides; "" (or nil) when
---                           both Sides read straight off disk via `path`
---@field left_rel  string?  relative path on the left; nil if absent (added)
---@field right_rel string?  relative path on the right; nil if absent (deleted)
---@field left      GitTools.Side  how to fetch left content
---@field right     GitTools.Side  how to fetch right content

---@class GitTools.EntryData
---@field root      string  absolute path to repo root
---@field left_rel  string? relative path on the left side; nil if the file
---                          doesn't exist there (e.g. it was added)
---@field right_rel string? relative path on the right side; nil if the file
---                          doesn't exist there (e.g. it was deleted)
---@field left  GitTools.Side   how to fetch left content
---@field right GitTools.Side   how to fetch right content

--- One row of the file list: a status letter, the (rename-aware) label shown
--- for it, and the data needed to build its side-by-side diff.
---@class GitTools.DiffEntry
---@field status "A"|"M"|"D"|"R"|"C"|"?"  single-letter status
---@field label  string                   display label (rename-aware)
---@field data   GitTools.EntryData        how to fetch each side's content

--- One diff session, living in a vertical split of the window it was launched
--- from. It owns its two split windows, the generated buffers, and a custom
--- list buffer (in a bottom split) whose cursor drives which file is diffed.
--- On teardown it collapses back to a single window so the original layout is
--- restored.
---@class GitTools.DiffSession
---@field group      integer   augroup id for this session's autocmds
---@field left_win   integer?  window for the left (base/source) side
---@field right_win  integer?  window for the right (target/live) side
---@field list_buf   integer?  scratch buffer listing the changed files
---@field list_win   integer?  bottom split window showing the list buffer
---@field entries    GitTools.DiffEntry[]  one per list-buffer line (1-based)
---@field buffers    integer[] generated virtual buffers to delete on close
---@field closing    boolean   reentrancy guard for close()
---@field setting_up boolean   reentrancy guard to stop infinite event loops
---@field shown_line integer?  list line whose diff is currently built, so a
---                            repeat setup for the same entry is a no-op

-- Only a single diff session exists at a time; opening a new diff tears down
-- the previous one (see M.open). nil when idle.
---@type GitTools.DiffSession?
local _session   = nil
local _next_id   = 0

-- Status letters (mirroring `git status --short`) rendered at the start of
-- each list line, and the highlight group each links to by default.
-- Linked to the builtin `Diagnostic*` groups rather than `Diff*`: those are
-- mostly background fills meant for whole lines, so on a single character
-- they read as an easy-to-miss colored speck (only `Title`, used for R/C in
-- an earlier pass, was ever visible). `Diagnostic*` groups are foreground
-- colors instead, so a single highlighted letter still stands out, and
-- they're guaranteed to exist in any Neovim >= 0.6 regardless of colorscheme.
-- `default = true` lets colorschemes/users override without editing here.
local _STATUS_HL = {
    A = { "GitToolsStatusAdded", "DiagnosticOk" },
    M = { "GitToolsStatusModified", "DiagnosticWarn" },
    D = { "GitToolsStatusDeleted", "DiagnosticError" },
    R = { "GitToolsStatusRenamed", "DiagnosticInfo" },
    C = { "GitToolsStatusCopied", "DiagnosticHint" },
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

--- The display label for an item: the plain path for adds/deletes/edits, or
--- the condensed `{old -> new}` form for a rename/copy.
---@param item GitTools.DiffItem
---@return string
local function _entry_label(item)
    if item.left_rel and item.right_rel and item.left_rel ~= item.right_rel then
        return _rename_label(item.left_rel, item.right_rel)
    end
    -- Every item sets at least one side (adds: right, deletes: left).
    return (item.right_rel or item.left_rel) --[[@as string]]
end

--- Color each list line by its leading status letter (see `_STATUS_HL`).
--- Rename/copy lines additionally get their arrow colored to match the status
--- letter, and the superseded (old) path dimmed. Scoped to `bufnr` alone so it
--- can't bleed into unrelated buffers elsewhere in the session.
---@param bufnr integer
local function _highlight_list(bufnr)
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

--- Tear down `session`: drop its autocmds, close the file list, collapse the
--- side-by-side split back to a single surviving window (so the original
--- layout is restored), and delete its generated buffers. Safe to invoke at
--- any point, whichever of the split windows or the list the user closed.
---@param session GitTools.DiffSession
local function _close_session(session)
    if session.closing then return end
    session.closing = true

    if _session == session then _session = nil end

    -- Drop the autocmds before closing anything, so the window closes below
    -- don't re-trigger teardown through our own WinClosed hooks.
    vim.api.nvim_del_augroup_by_id(session.group)

    -- Close the file-list window first (it's a separate bottom split); its
    -- scratch buffer is bufhidden=wipe, so this also drops the buffer.
    if session.list_win and vim.api.nvim_win_is_valid(session.list_win) then
        pcall(vim.api.nvim_win_close, session.list_win, false)
    end
    session.list_win  = nil
    session.list_buf  = nil

    -- Keep exactly one of the two split windows so the layout collapses back
    -- to a single window. Prefer the right (target/worktree) side; fall back
    -- to the left when the user closed the right one.
    local left_valid  = session.left_win and vim.api.nvim_win_is_valid(session.left_win)
    local right_valid = session.right_win and vim.api.nvim_win_is_valid(session.right_win)
    local survivor    = (right_valid and session.right_win) or (left_valid and session.left_win) or nil

    -- Turn off diff mode on every split window up front, before any of them is
    -- closed. `diffthis` sets window-local flags (diff, scrollbind, cursorbind,
    -- foldmethod=diff, foldcolumn, ...); the window being closed discards its
    -- own, but a pane showing a real worktree-file buffer can leave that buffer
    -- diff-highlighted in any other window still displaying it. Clearing both
    -- sides here guarantees no diff flag / highlight survives the teardown.
    for _, win in ipairs({ session.left_win, session.right_win }) do
        if win and vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_call(win, function() vim.cmd("diffoff!") end)
        end
    end

    for _, win in ipairs({ session.left_win, session.right_win }) do
        if win and win ~= survivor and vim.api.nvim_win_is_valid(win) then
            pcall(vim.api.nvim_win_close, win, false)
        end
    end
    if survivor and vim.api.nvim_win_is_valid(survivor) then
        -- If the surviving window is left showing one of our generated temp
        -- buffers (e.g. a rev-vs-rev diff, where neither side is the real
        -- worktree file), swap it for a fresh empty buffer rather than parking
        -- the user on a throwaway git:// scratch buffer.
        if vim.tbl_contains(session.buffers, vim.api.nvim_win_get_buf(survivor)) then
            vim.api.nvim_win_call(survivor, function() vim.cmd("enew") end)
        end
    end
    session.left_win  = nil
    session.right_win = nil

    -- Delete the generated buffers. Any that was still shown in the surviving
    -- window was swapped out above, so none blanks out under the user.
    for _, bufnr in ipairs(session.buffers) do
        if vim.api.nvim_buf_is_valid(bufnr) then
            pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
        end
    end
    session.buffers = {}
end

--- Close the active diff session, if any (e.g. on VimLeavePre).
function M.clear()
    if _session then _close_session(_session) end
end

--- Create a read-only scratch buffer holding one side's content: an on-disk
--- file (`side.path`), a git blob (`side.rev`/`side.index`), the live worktree
--- file, or empty when the side is absent (an add or delete).
---@param session GitTools.DiffSession
---@param root string Repo root (for git-backed sides)
---@param side GitTools.Side Side description
---@param rel string? Relative path on this side; nil if the file doesn't
---                    exist on this side (e.g. it was added or deleted)
---@param side_label string "left" or "right"
---@param filetype string Syntax highlighting string
---@return integer bufnr
local function _make_side_buf(session, root, side, rel, side_label, filetype)
    local buf = vim.api.nvim_create_buf(false, true)
    local lines = {}

    if rel then
        if side.path then
            if vim.fn.filereadable(side.path) == 1 then
                lines = vim.fn.readfile(side.path)
            end
        elseif side.worktree then
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

    local name_tag         = side.rev or (side.index and "index") or (side.path and "path") or "worktree"
    vim.api.nvim_buf_set_name(buf, string.format("git://%d/%s/%s/%s", buf, name_tag, side_label, rel or "(none)"))

    table.insert(session.buffers, buf)

    return buf
end

--- The entry (and its 1-based list line) under the cursor in the list window.
---@param session GitTools.DiffSession
---@return GitTools.DiffEntry? entry
---@return integer? line
local function _entry_at_cursor(session)
    local win = session.list_win
    if not (win and vim.api.nvim_win_is_valid(win)) then return nil, nil end
    local lnum = vim.api.nvim_win_get_cursor(win)[1]
    return session.entries[lnum], lnum
end

--- Drive side-by-side native splits using fresh contextual buffer snapshots
--- for the file on list line `lnum`.
---@param session GitTools.DiffSession
---@param entry   GitTools.DiffEntry
---@param lnum    integer  the entry's list line, used as the rebuild guard
local function _setup_diff(session, entry, lnum)
    if session.setting_up then return end
    session.setting_up = true

    local lw, rw = session.left_win, session.right_win
    if not (lw and vim.api.nvim_win_is_valid(lw) and rw and vim.api.nvim_win_is_valid(rw)) then
        session.setting_up = false
        return
    end

    -- Skip if this line's diff is already built, so repeatedly landing on the
    -- same entry (e.g. horizontal cursor moves) is a harmless no-op rather
    -- than a second, buffer-leaking rebuild.
    if session.shown_line == lnum then
        session.setting_up = false
        return
    end
    session.shown_line = lnum

    local ud = entry.data
    local filetype = vim.filetype.match({ filename = ud.right_rel or ud.left_rel }) or ""

    local right_buf
    if ud.right.worktree and ud.right_rel then
        right_buf = vim.fn.bufadd(ud.root .. "/" .. ud.right_rel)
        vim.bo[right_buf].swapfile = false
        vim.fn.bufload(right_buf)
    else
        right_buf = _make_side_buf(session, ud.root, ud.right, ud.right_rel, "right", filetype)
    end

    local left_buf = _make_side_buf(session, ud.root, ud.left, ud.left_rel, "left", filetype)

    vim.api.nvim_win_set_buf(lw, left_buf)
    vim.api.nvim_win_set_buf(rw, right_buf)

    vim.api.nvim_win_call(lw, function() vim.cmd("diffoff!") end)
    vim.api.nvim_win_call(rw, vim.cmd.diffthis)
    vim.api.nvim_win_call(lw, vim.cmd.diffthis)

    session.setting_up = false
end

--- Move the list cursor `delta` rows (clamped to the list) and show that file's
--- swapped, never the current window.
---@param session GitTools.DiffSession
---@param delta   integer
local function _step(session, delta)
    local lwin = session.list_win
    if not (lwin and vim.api.nvim_win_is_valid(lwin)) then return end
    local lnum = vim.api.nvim_win_get_cursor(lwin)[1]
    local target = math.max(1, math.min(#session.entries, lnum + delta))
    if target ~= lnum then
        vim.api.nvim_win_set_cursor(lwin, { target, 0 })
    end
    local entry = session.entries[target]
    if entry then _setup_diff(session, entry, target) end
end

-- `[f` / `]f` step to the previous / next file of the active diff session, from
-- any window: either diff pane, the file list, or anywhere else. Global (set
-- once, at load) rather than buffer-local, so the motion works the moment a
-- diff is open without wiring maps onto each generated buffer -- and, since the
-- right pane can hold the user's real worktree-file buffer, without leaving
-- stray maps behind in it once the session closes.
--
-- Uppercase because the builtin `[c` / `]c` (previous/next *hunk* within the
-- current file's diff) has to keep working. A no-op when no session is open,
-- which is also why claiming these globally is cheap: only one diff session
-- exists at a time, and outside one the keys do nothing.
for _, map in ipairs({
    { lhs = "]f", delta = 1,  desc = "Show the next file's diff" },
    { lhs = "[f", delta = -1, desc = "Show the previous file's diff" },
}) do
    vim.keymap.set("n", map.lhs, function()
        if _session then _step(_session, map.delta) end
    end, { desc = "gittools: " .. map.desc })
end

--- Split the current window into the side-by-side diff layout, reusing the
--- launching window as the left side and a vertical split as the right side.
--- Closing either split window (or, once registered, the file list) tears the
--- session down and collapses back to a single window.
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

--- Render `session.entries` into a fresh scratch buffer.
---@param session GitTools.DiffSession
---@return integer bufnr
local function _make_list_buf(session)
    local buf = ui.create_scratch_buffer(false, {
        filetype   = "gittoolsdiff",
        modifiable = false,
        undolevels = -1,
    }, function()
        -- The list buffer wiping (e.g. the user :bdelete'd it) collapses the
        -- whole session, so it can't outlive the diff it drives.
        vim.schedule(function() _close_session(session) end)
    end)

    local lines = {}
    for _, entry in ipairs(session.entries) do
        lines[#lines + 1] = string.format("%s %s", entry.status, entry.label)
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false

    _highlight_list(buf)
    return buf
end

--- Open the file list in a bottom split and wire the `<CR>` / `q` maps.
---@param session GitTools.DiffSession
local function _open_list(session)
    local buf = _make_list_buf(session)
    session.list_buf = buf

    vim.cmd("botright new")
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    vim.api.nvim_win_set_height(win, math.min(15, #session.entries))
    -- A new split inherits window-local options (scrollbind, cursorbind, ...)
    -- from the window it split off of; reset them so the list can't end up
    -- scroll-linked to a diff pane, and dress it as a picker.
    vim.wo[win].scrollbind     = false
    vim.wo[win].cursorbind     = false
    vim.wo[win].wrap           = false
    vim.wo[win].number         = false
    vim.wo[win].relativenumber = false
    vim.wo[win].cursorline     = true
    vim.wo[win].winfixheight   = true
    session.list_win           = win

    -- Closing the list on its own also collapses the session, so the user only
    -- ever needs one close to get back to a single window.
    vim.api.nvim_create_autocmd("WinClosed", {
        group    = session.group,
        pattern  = tostring(win),
        callback = function() vim.schedule(function() _close_session(session) end) end,
    })

    -- Show the file under the cursor in the diff panes, staying in the list.
    local function show_at_cursor()
        local entry, lnum = _entry_at_cursor(session)
        if entry and lnum then _setup_diff(session, entry, lnum) end
    end

    -- <CR> activates the file under the cursor: show its diff and step up into
    -- the diff pane so the user can read/navigate it directly.
    vim.keymap.set("n", "<CR>", function()
        show_at_cursor()
        --local rw = session.right_win
        --if rw and vim.api.nvim_win_is_valid(rw) then
        --    vim.api.nvim_set_current_win(rw)
        --end
    end, { buffer = buf, desc = "Open the diff for the file under the cursor" })

    vim.keymap.set("n", "q", function() _close_session(session) end,
        { buffer = buf, desc = "Close the diff" })
end

--- Open a diff session over `items`: build the side-by-side layout, the driving
--- file list, and show the first item up front (so the layout opens on a real
--- diff rather than empty panes; the user flips through the rest with `<CR>` /
--- `]f` / `[f`). Tears down any existing session first -- done here, after the
--- caller's early returns, so an invalid or empty request leaves the current
--- session intact. Callers must pass a non-empty list.
---@param items GitTools.DiffItem[]
function M.open(items)
    ---@type GitTools.DiffEntry[]
    local entries = {}
    for _, item in ipairs(items) do
        entries[#entries + 1] = {
            status = item.status,
            label  = _entry_label(item),
            data   = {
                root      = item.root or "",
                left_rel  = item.left_rel,
                right_rel = item.right_rel,
                left      = item.left,
                right     = item.right,
            },
        }
    end

    _next_id = _next_id + 1
    ---@type GitTools.DiffSession
    local session = {
        group      = vim.api.nvim_create_augroup("gittools.diff." .. _next_id, { clear = true }),
        left_win   = nil,
        right_win  = nil,
        list_buf   = nil,
        list_win   = nil,
        entries    = entries,
        buffers    = {},
        closing    = false,
        setting_up = false,
        shown_line = nil,
    }
    if _session then _close_session(_session) end
    _session = session

    _build_layout(session)
    _open_list(session)

    -- Focus the list and show the first entry's diff up front. The shown_line
    -- guard makes a later <CR> on line 1 a no-op.
    vim.api.nvim_set_current_win(session.list_win)
    vim.api.nvim_win_set_cursor(session.list_win, { 1, 0 })
    local entry, lnum = _entry_at_cursor(session)
    if entry and lnum then _setup_diff(session, entry, lnum) end
end

return M
