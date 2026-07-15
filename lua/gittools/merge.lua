local M   = {}

local git = require("gittools.git")

--- The conflict-resolution feature behind `:GitTool merge`. It serves two entry
--- points with one implementation:
---
---   :GitTool merge $LOCAL $BASE $REMOTE $MERGED   git's classic mergetool
---                                                 four-file calling convention
---   :GitTool merge                                infer the four sides from the
---                                                 index stages of the current
---                                                 (conflicted) buffer
---
--- The view is the `$MERGED` file itself -- a normal, editable, saveable buffer
--- -- with each conflict region painted the way VSCode paints them: a Current
--- band, an optional Base band, and an Incoming band. Buffer-local maps resolve
--- the region under the cursor:
---
---   xo / xt / xb / xa   accept ours / theirs / both / ancestor (base)
---   ]x / [x             jump to the next / previous conflict
---   xd                  open the $LOCAL | $MERGED | $REMOTE three-way diff
---
--- Accepting only edits the buffer; the user saves with `:w`. Nothing here
--- stages, checks out, or otherwise mutates the repository -- `git mergetool`
--- stages `$MERGED` itself on exit, and that division keeps this module as
--- read-only toward git as the rest of the plugin.

---@param msg string
---@param level integer?
local function _notify(msg, level)
    vim.notify("[gittools] " .. msg, level or vim.log.levels.INFO)
end

local _ns = vim.api.nvim_create_namespace("gittools.merge")

--- Unlike `gittools.diff`, which shuns the `Diff*` groups because a background
--- fill on a single status character reads as a colored speck, this view fills
--- whole line bands -- exactly what `Diff*` is for. `default = true` so a
--- colorscheme can still override.
local _HL = {
    { "GitToolsMergeCurrent",  "DiffAdd" },
    { "GitToolsMergeIncoming", "DiffChange" },
    { "GitToolsMergeBase",     "DiffText" },
    { "GitToolsMergeMarker",   "Comment" },
    { "GitToolsMergeLabel",    "Identifier" },
}
for _, pair in ipairs(_HL) do
    vim.api.nvim_set_hl(0, pair[1], { link = pair[2], default = true })
end

--- A parsed conflict region. Line numbers are 1-based and index the `$MERGED`
--- buffer as it stood at the last parse; every mutation re-parses rather than
--- trying to carry these through arbitrary user edits.
---@class GitTools.MergeHunk
---@field s_lnum       integer               line holding `<<<<<<<`
---@field e_lnum       integer               line holding `>>>>>>>`
---@field ours         [integer,integer]     inclusive content range; s > e when the side is empty
---@field base         [integer,integer]?    nil unless the markers carried a `|||||||` section
---@field theirs       [integer,integer]
---@field ours_label   string
---@field theirs_label string

---@class GitTools.MergeSides
---@field local_path  string   $LOCAL  -- "ours", the current branch
---@field base_path   string?  $BASE   -- nil for an add/add conflict (no common ancestor)
---@field remote_path string   $REMOTE -- "theirs", the incoming branch
---@field merged_path string   $MERGED -- the real file, carrying the markers

--- The active merge session. Only one exists at a time. nil when idle.
---@class GitTools.MergeSession
---@field buf         integer               the $MERGED file buffer
---@field win         integer               the window holding it (the middle pane under xd)
---@field sides       GitTools.MergeSides
---@field group       integer               the session's autocmd group
---@field hunks       GitTools.MergeHunk[]  last parse, 1:1 with the bands on screen
---@field maps        string[]              lhs of every map we set, so teardown can't drift out of sync
---@field tmp         string[]              tempfiles to unlink on teardown
---@field base_texts  string[][]?           lazy `merge-file --diff3` base fallback, by hunk index
---@field base_tried  boolean               guard: the fallback shells out at most once
---@field diff_wins   integer[]?            the xd three-way panes, when open
---@field diff_bufs   integer[]?            the xd scratch buffers, when open
---@type GitTools.MergeSession?
local _session = nil

--- Close the three-way split, if open, collapsing back to the inline view. The
--- `$MERGED` buffer survives -- only the generated sides go.
---@param session GitTools.MergeSession
local function _close_diff(session)
    local wins, bufs = session.diff_wins, session.diff_bufs
    session.diff_wins, session.diff_bufs = nil, nil
    if not wins then return end

    -- diffoff every window showing $MERGED before closing anything: the file
    -- buffer is real and may be on screen elsewhere, where it would otherwise
    -- stay diff-highlighted forever.
    for _, win in ipairs(vim.fn.win_findbuf(session.buf)) do
        pcall(vim.api.nvim_win_call, win, function() vim.cmd("diffoff") end)
    end
    for _, win in ipairs(wins) do
        if win ~= session.win and vim.api.nvim_win_is_valid(win) then
            pcall(vim.api.nvim_win_close, win, false)
        end
    end
    for _, buf in ipairs(bufs or {}) do
        if vim.api.nvim_buf_is_valid(buf) then
            pcall(vim.api.nvim_buf_delete, buf, { force = true })
        end
    end
end

--- Tear the session down: drop the augroup first so the window closes below
--- can't re-enter through their own WinClosed hooks, then unpaint, unmap, and
--- unlink the stage tempfiles.
local function _end_merge()
    local session = _session
    if not session then return end
    _session = nil

    pcall(vim.api.nvim_del_augroup_by_id, session.group)
    _close_diff(session)

    if vim.api.nvim_buf_is_valid(session.buf) then
        pcall(vim.api.nvim_buf_clear_namespace, session.buf, _ns, 0, -1)
        for _, lhs in ipairs(session.maps) do
            pcall(vim.keymap.del, "n", lhs, { buffer = session.buf })
        end
    end

    for _, path in ipairs(session.tmp) do
        pcall(vim.uv.fs_unlink, path)
    end
end

--- Close the active merge session, if any (e.g. on VimLeavePre).
function M.clear_session()
    _end_merge()
end

--- Split a git blob into lines, dropping the single trailing newline a
--- well-formed text file ends with.
---@param blob string
---@return string[]
local function _blob_lines(blob)
    if blob:sub(-1) == "\n" then
        blob = blob:sub(1, -2)
    end
    return vim.split(blob, "\n", { plain = true })
end

--- Parse conflict markers out of `lines`. Marker sets that never terminate are
--- skipped rather than raising: a half-typed buffer shouldn't break the view.
---@param lines string[]
---@return GitTools.MergeHunk[]
local function _parse(lines)
    local hunks = {}
    local i, n = 1, #lines

    while i <= n do
        local ours_label = lines[i]:match("^<<<<<<<%s*(.*)$")
        if ours_label then
            local s_lnum = i
            local base_s, sep, e_lnum
            local j = i + 1
            while j <= n do
                local line = lines[j]
                if line:match("^<<<<<<<") then
                    break -- a new set opened before this one closed; abandon it
                elseif not base_s and line:match("^|||||||") then
                    base_s = j
                elseif not sep and line == "=======" then
                    sep = j
                elseif line:match("^>>>>>>>") then
                    e_lnum = j
                    break
                end
                j = j + 1
            end

            if e_lnum and sep then
                local ours_e = (base_s or sep) - 1
                hunks[#hunks + 1] = {
                    s_lnum       = s_lnum,
                    e_lnum       = e_lnum,
                    ours         = { s_lnum + 1, ours_e },
                    base         = base_s and { base_s + 1, sep - 1 } or nil,
                    theirs       = { sep + 1, e_lnum - 1 },
                    ours_label   = ours_label ~= "" and ours_label or "current",
                    theirs_label = lines[e_lnum]:match("^>>>>>>>%s*(.*)$") or "incoming",
                }
                i = e_lnum + 1
            else
                i = s_lnum + 1
            end
        else
            i = i + 1
        end
    end
    return hunks
end

--- The text of an inclusive 1-based line range, empty when the range is empty.
---@param buf integer
---@param range [integer,integer]
---@return string[]
local function _range_lines(buf, range)
    if range[1] > range[2] then return {} end
    return vim.api.nvim_buf_get_lines(buf, range[1] - 1, range[2], false)
end

--- Paint the bands. Content lines get `line_hl_group` + `hl_eol` so blank lines
--- inside a side still carry their colour; the `<<<<<<<` line additionally gets
--- a virtual-text hint, which is the only key discoverability surface the plugin
--- offers anywhere.
---@param session GitTools.MergeSession
local function _render(session)
    local buf = session.buf
    if not vim.api.nvim_buf_is_valid(buf) then return end

    vim.api.nvim_buf_clear_namespace(buf, _ns, 0, -1)

    local function band(range, hl)
        if not range then return end
        for lnum = range[1], range[2] do
            vim.api.nvim_buf_set_extmark(buf, _ns, lnum - 1, 0, {
                line_hl_group = hl,
                hl_eol        = true,
                strict        = false,
            })
        end
    end

    for _, h in ipairs(session.hunks) do
        band(h.ours, "GitToolsMergeCurrent")
        band(h.base, "GitToolsMergeBase")
        band(h.theirs, "GitToolsMergeIncoming")

        local markers = { h.s_lnum, h.theirs[1] - 1, h.e_lnum }
        if h.base then markers[#markers + 1] = h.base[1] - 1 end
        for _, lnum in ipairs(markers) do
            vim.api.nvim_buf_set_extmark(buf, _ns, lnum - 1, 0, {
                line_hl_group = "GitToolsMergeMarker",
                hl_eol        = true,
                strict        = false,
            })
        end

        vim.api.nvim_buf_set_extmark(buf, _ns, h.s_lnum - 1, 0, {
            virt_text     = { { "  xo ours · xt theirs · xb both · xa base · xd diff",
                "GitToolsMergeLabel" } },
            virt_text_pos = "eol",
            strict        = false,
        })
    end
end

--- Re-parse the live buffer and repaint. Every edit path funnels through here,
--- so the bands track both our own resolutions and the user's hand edits.
---@param session GitTools.MergeSession
local function _refresh(session)
    if not vim.api.nvim_buf_is_valid(session.buf) then return end
    session.hunks = _parse(vim.api.nvim_buf_get_lines(session.buf, 0, -1, false))
    _render(session)
end

--- Base text for hunk `idx`, for the common case where `merge.conflictStyle` is
--- the default `merge` and `$MERGED` therefore carries no `|||||||` sections.
---
--- Recovers it by asking git to redo the merge in diff3 style against the
--- *original* three files and parsing that output with the same parser, matching
--- hunk-for-hunk by position. That correspondence only holds while the buffer's
--- conflicts still line up with a fresh merge of the inputs -- once the user has
--- resolved or hand-edited hunks the counts diverge, and we decline rather than
--- paste in text from the wrong region.
---@param session GitTools.MergeSession
---@param idx     integer
---@return string[]?
local function _base_fallback(session, idx)
    local sides = session.sides
    if not sides.base_path then return nil end

    if not session.base_tried then
        session.base_tried = true
        local out = git.merge_file_diff3(vim.fs.dirname(sides.merged_path),
            sides.local_path, sides.base_path, sides.remote_path)
        if out then
            local texts = {}
            local lines = _blob_lines(out)
            for _, h in ipairs(_parse(lines)) do
                local t = {}
                if h.base then
                    for lnum = h.base[1], h.base[2] do t[#t + 1] = lines[lnum] end
                end
                texts[#texts + 1] = t
            end
            session.base_texts = texts
        end
    end

    local texts = session.base_texts
    if not texts or #texts ~= #session.hunks then return nil end
    return texts[idx]
end

--- The hunk containing the cursor, or the first one below it -- so the accept
--- maps do something sensible when fired from just outside a region.
---@param session GitTools.MergeSession
---@return GitTools.MergeHunk?
---@return integer? idx
local function _hunk_at_cursor(session)
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    for i, h in ipairs(session.hunks) do
        if lnum <= h.e_lnum then return h, i end
    end
    return nil, nil
end

--- Replace hunk `h` -- markers and all -- with `lines`, leaving the buffer
--- modified for the user to `:w`.
---@param session GitTools.MergeSession
---@param h       GitTools.MergeHunk
---@param lines   string[]
local function _replace(session, h, lines)
    vim.api.nvim_buf_set_lines(session.buf, h.s_lnum - 1, h.e_lnum, false, lines)
    _refresh(session)
    vim.api.nvim_win_set_cursor(0, { math.min(h.s_lnum, vim.api.nvim_buf_line_count(session.buf)), 0 })
end

---@param session GitTools.MergeSession
---@param which   "ours"|"theirs"|"both"|"base"
local function _accept(session, which)
    local h, idx = _hunk_at_cursor(session)
    if not h then
        _notify("No conflict at or below the cursor")
        return
    end

    local lines
    if which == "ours" then
        lines = _range_lines(session.buf, h.ours)
    elseif which == "theirs" then
        lines = _range_lines(session.buf, h.theirs)
    elseif which == "both" then
        lines = _range_lines(session.buf, h.ours)
        vim.list_extend(lines, _range_lines(session.buf, h.theirs))
    else
        if h.base then
            lines = _range_lines(session.buf, h.base)
        else
            lines = _base_fallback(session, idx --[[@as integer]])
            if not lines then
                _notify("No base text available for this conflict "
                    .. "(set merge.conflictStyle=zdiff3 to keep it in the file)",
                    vim.log.levels.WARN)
                return
            end
        end
    end

    _replace(session, h, lines)
end

--- Jump to the next (`dir` 1) or previous (`dir` -1) conflict, wrapping.
---@param session GitTools.MergeSession
---@param dir     integer
local function _jump(session, dir)
    local hunks = session.hunks
    if #hunks == 0 then
        _notify("No conflicts remaining")
        return
    end

    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    local target
    if dir > 0 then
        for _, h in ipairs(hunks) do
            if h.s_lnum > lnum then target = h break end
        end
        target = target or hunks[1]
    else
        for i = #hunks, 1, -1 do
            if hunks[i].e_lnum < lnum then target = hunks[i] break end
        end
        target = target or hunks[#hunks]
    end
    vim.api.nvim_win_set_cursor(0, { target.s_lnum, 0 })
end

--- A read-only scratch side for the three-way split.
---@param session GitTools.MergeSession
---@param path    string
---@param label   string
---@param ft      string
---@return integer bufnr
local function _make_side_buf(session, path, label, ft)
    local buf = vim.api.nvim_create_buf(false, true)
    local lines = vim.fn.filereadable(path) == 1 and vim.fn.readfile(path) or {}
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].buftype    = "nofile"
    vim.bo[buf].bufhidden  = "wipe"
    vim.bo[buf].swapfile   = false
    vim.bo[buf].filetype   = ft
    vim.bo[buf].modifiable = false
    -- set_lines marked the scratch buffer modified; clear it so window closes
    -- aren't blocked by E445 when 'hidden' is off.
    vim.bo[buf].modified   = false
    pcall(vim.api.nvim_buf_set_name, buf,
        ("gittools://merge/%d/%s"):format(buf, label))
    return buf
end

--- Give the three panes equal shares of the width they collectively occupy.
---
--- Worth doing explicitly. Each `vsplit` halves the window it splits, so the
--- panes are born 50/25/25; that only looks right when 'equalalways' happens to
--- be on, and even then it equalises every window in the tab, so an unrelated
--- split elsewhere quietly takes a share of the diff's space. Sizing them here
--- makes the layout the same either way.
---@param wins integer[]  the panes, left to right
local function _equalize(wins)
    local total = 0
    for _, win in ipairs(wins) do
        total = total + vim.api.nvim_win_get_width(win)
    end

    -- Widths exclude the separator columns between panes, which the splits
    -- already took out of the total, so thirds of what's left is the honest
    -- share. The middle pane absorbs the rounding remainder.
    local share = math.floor(total / 3)
    for _, win in ipairs({ wins[1], wins[3] }) do
        pcall(vim.api.nvim_win_set_width, win, share)
    end
end

--- Open `$LOCAL | $MERGED | $REMOTE` side by side, for hunks too gnarly to
--- resolve inline. The middle pane is the live file, so the inline bands and
--- maps keep working while the diff is up.
---
--- Both splits are made from the `$MERGED` window with explicit `leftabove` /
--- `rightbelow`, so the three land adjacent in that order regardless of
--- 'splitright' and of whatever else is already on screen.
---@param session GitTools.MergeSession
local function _open_diff(session)
    if session.diff_wins then
        _close_diff(session)
        return
    end

    local ft = vim.bo[session.buf].filetype
    local left  = _make_side_buf(session, session.sides.local_path, "local", ft)
    local right = _make_side_buf(session, session.sides.remote_path, "remote", ft)

    local mid = vim.api.nvim_get_current_win()
    vim.cmd("leftabove vsplit")
    local left_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(left_win, left)

    vim.api.nvim_set_current_win(mid)
    vim.cmd("rightbelow vsplit")
    local right_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(right_win, right)

    for _, win in ipairs({ left_win, mid, right_win }) do
        vim.api.nvim_win_call(win, vim.cmd.diffthis)
    end
    -- After diffthis: entering diff mode adds a foldcolumn, which shifts widths.
    _equalize({ left_win, mid, right_win })
    vim.api.nvim_set_current_win(mid)

    session.diff_wins = { left_win, mid, right_win }
    session.diff_bufs = { left, right }
    session.win = mid

    -- Defer teardown: closing further windows synchronously from WinClosed
    -- breaks Neovim's own mid-close bookkeeping (E445).
    for _, win in ipairs({ left_win, right_win }) do
        vim.api.nvim_create_autocmd("WinClosed", {
            group    = session.group,
            pattern  = tostring(win),
            callback = function()
                vim.schedule(function()
                    if _session == session then _close_diff(session) end
                end)
            end,
        })
    end
end

---@param session GitTools.MergeSession
local function _set_keymaps(session)
    local buf = session.buf
    local function map(lhs, fn, desc)
        vim.keymap.set("n", lhs, fn, { buffer = buf, desc = desc })
        session.maps[#session.maps + 1] = lhs
    end

    map("xo", function() _accept(session, "ours") end, "Accept ours (current) for this conflict")
    map("xt", function() _accept(session, "theirs") end, "Accept theirs (incoming) for this conflict")
    map("xb", function() _accept(session, "both") end, "Accept both sides, ours first")
    map("xa", function() _accept(session, "base") end, "Accept the common ancestor (base)")
    map("xd", function() _open_diff(session) end, "Toggle the $LOCAL | $MERGED | $REMOTE three-way diff")
    map("]x", function() _jump(session, 1) end, "Jump to the next conflict")
    map("[x", function() _jump(session, -1) end, "Jump to the previous conflict")
end

--- Write `blob` to a tempfile owned by `session`, for a side that only exists in
--- the index. `git merge-file` and the diff panes both want real paths.
---@param session GitTools.MergeSession
---@param blob    string
---@return string
local function _spill(session, blob)
    local path = vim.fn.tempname()
    local fd = assert(vim.uv.fs_open(path, "w", 420)) -- 0644
    vim.uv.fs_write(fd, blob)
    vim.uv.fs_close(fd)
    session.tmp[#session.tmp + 1] = path
    return path
end

--- Resolve the four sides from the current buffer's index stages: 1 = base,
--- 2 = ours, 3 = theirs, with `$MERGED` being the worktree file itself. Stage 1
--- is absent for an add/add conflict, which simply leaves the base unavailable.
---@param session GitTools.MergeSession
---@return GitTools.MergeSides?
local function _sides_from_index(session)
    local buf = vim.api.nvim_get_current_buf()
    if vim.bo[buf].buftype ~= "" then
        _notify("GitTool merge needs a normal file buffer", vim.log.levels.WARN)
        return nil
    end

    local abs = vim.api.nvim_buf_get_name(buf)
    if abs == "" then
        _notify("Current buffer has no file name", vim.log.levels.WARN)
        return nil
    end
    abs = vim.fn.fnamemodify(abs, ":p")

    local root = git.root(vim.fs.dirname(abs))
    if not root then
        _notify("Not inside a git repository", vim.log.levels.WARN)
        return nil
    end

    local rel = git.relpath(root, abs)
    if not rel then
        _notify("File is outside the repository: " .. abs, vim.log.levels.WARN)
        return nil
    end

    local unmerged = git.run(root, { "ls-files", "-u", "--", rel })
    if not unmerged or unmerged == "" then
        _notify("Not a conflicted file: " .. rel, vim.log.levels.WARN)
        return nil
    end

    local function stage(n)
        local blob = git.run_raw(root, { "show", (":%d:%s"):format(n, rel) })
        return blob and _spill(session, blob) or nil
    end

    local base_path = stage(1)
    local local_path = stage(2)
    local remote_path = stage(3)
    if not (local_path and remote_path) then
        _notify("Missing index stages for " .. rel, vim.log.levels.ERROR)
        return nil
    end

    return {
        local_path  = local_path,
        base_path   = base_path,
        remote_path = remote_path,
        merged_path = abs,
    }
end

---@class GitTools.MergeOpts
---@field paths string[]?  $LOCAL $BASE $REMOTE $MERGED; nil = infer from the buffer

--- Open the conflict view for `opts.paths`, or for the current buffer.
---@param opts GitTools.MergeOpts?
function M.merge(opts)
    opts = opts or {}
    _end_merge()

    local session = {
        tmp        = {},
        maps       = {},
        hunks      = {},
        base_tried = false,
    }

    local sides
    if opts.paths then
        local p = opts.paths
        local base = vim.fn.fnamemodify(p[2], ":p")
        -- git hands over a $BASE path even for an add/add conflict, where the
        -- file is empty; treat that as "no common ancestor".
        local has_base = vim.fn.filereadable(base) == 1 and vim.fn.getfsize(base) > 0
        sides = {
            local_path  = vim.fn.fnamemodify(p[1], ":p"),
            base_path   = has_base and base or nil,
            remote_path = vim.fn.fnamemodify(p[3], ":p"),
            merged_path = vim.fn.fnamemodify(p[4], ":p"),
        }
    else
        sides = _sides_from_index(session)
    end

    if not sides then
        for _, path in ipairs(session.tmp) do pcall(vim.uv.fs_unlink, path) end
        return
    end

    -- Open $MERGED as a real, writable file buffer: resolving is an edit, and
    -- `:w` is how it lands.
    local buf = vim.fn.bufadd(sides.merged_path)
    vim.fn.bufload(buf)
    if vim.api.nvim_get_current_buf() ~= buf then
        vim.api.nvim_win_set_buf(0, buf)
    end

    session.buf   = buf
    session.sides = sides
    session.win   = vim.api.nvim_get_current_win()
    session.group = vim.api.nvim_create_augroup("gittools.merge", { clear = true })
    _session      = session

    _refresh(session)
    _set_keymaps(session)

    if #session.hunks == 0 then
        _notify("No conflict markers found in " .. vim.fn.fnamemodify(sides.merged_path, ":."))
    else
        vim.api.nvim_win_set_cursor(session.win, { session.hunks[1].s_lnum, 0 })
    end

    -- Repaint on every edit so the bands follow both our resolutions and the
    -- user's own; schedule so the parse sees the settled buffer.
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
        group    = session.group,
        buffer   = buf,
        callback = function()
            vim.schedule(function()
                if _session == session then _refresh(session) end
            end)
        end,
    })
    vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
        group    = session.group,
        buffer   = buf,
        callback = function() vim.schedule(_end_merge) end,
    })
end

return M
