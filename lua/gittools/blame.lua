local M        = {}

local git      = require("gittools.util.git")
local difftool = require("gittools.diff")
local hover    = require("gittools.util.hover")
local keyhelp  = require("gittools.util.keyhelp")

--- `:GitTool blame` -- annotate the current buffer with per-line commit info
--- in a scroll-bound sidebar, fugitive-style. The buffer's *live* contents are
--- piped to `git blame --contents -`, so unsaved edits stay line-aligned and
--- show up as "Not committed". In the sidebar: the commit summary is echoed as
--- the cursor moves, `<CR>` diffs the commit under the cursor against its
--- parent (via `gittools.diff`), `K` shows that commit's details in a float,
--- `R` re-blames the file as it was just before the commit under the cursor,
--- and `<BS>` steps back out of that. The annotations are a snapshot, so the
--- session ends as soon as they could go stale: either window closing, the
--- file being edited, reloaded or replaced in its window, and the buffer being
--- deleted.

local _EMPTY_TREE   = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
local _MAX_AUTHOR_W = 20

local _ns           = vim.api.nvim_create_namespace("gittools.blame")

---@param msg string
---@param level integer?
local function _notify(msg, level)
    vim.notify("[gittools] " .. msg, level or vim.log.levels.INFO)
end

--- One blamed line.
---@class GitTools.BlameEntry
---@field hash      string
---@field orig_lnum integer  the line's number in `hash`'s version of the file
---@field author    string
---@field time      integer
---@field summary   string
---@field prev_hash string?  the commit `hash` changed the line from, and the
---@field prev_path string?  file's path there; unset when the line is as old
---                          as the file (or uncommitted)

--- One level of the blame: the live buffer at the bottom, and above it one per
--- `R`, each a read-only copy of the file at an older commit.
---@class GitTools.BlameLayer
---@field buf     integer               shown in the file window at this level
---@field entries GitTools.BlameEntry[]  by line
---@field label   string                what the sidebar is named after, `path`
---                                     or `rev:path`
---@field view    table?                the file window's view, saved when a
---                                     level is pushed on top of this one

--- The active blame session. Only one exists at a time. nil when idle.
---@class GitTools.BlameSession
---@field group     integer
---@field root      string
---@field rel       string               the live file's path in the repo
---@field file_win  integer?
---@field file_buf  integer              the live buffer blame was started on
---@field shown_buf integer              the buffer the file window is meant to
---                                      be showing: `file_buf`, or a history
---                                      buffer after a `R`
---@field stack     GitTools.BlameLayer[] `stack[1]` is `file_buf`'s level
---@field entries   GitTools.BlameEntry[] the top level's, as shown in the sidebar
---@field blame_win integer?
---@field blame_buf integer
---@field saved     table<string, any>  file-window options to restore on close
---@field saved_side table<string, any> sidebar-window options, for the rare
---                                     teardown that leaves that window alive
---@type GitTools.BlameSession?
local _session = nil

---@param win   integer
---@param saved table<string, any>
local function _restore_opts(win, saved)
    for opt, val in pairs(saved) do
        pcall(function() vim.wo[win][opt] = val end)
    end
end

--- Tear down the active blame session: drop autocmds, close the sidebar, and
--- restore the file window's scroll options. Safe to call anytime.
local function _end_blame()
    if not _session then return end
    local s = _session
    _session = nil

    pcall(vim.api.nvim_del_augroup_by_id, s.group)

    if s.file_win and vim.api.nvim_win_is_valid(s.file_win) then
        -- Deep in the history, the window shows a copy that is about to go;
        -- hand it back the file it was blaming.
        if vim.api.nvim_win_get_buf(s.file_win) ~= s.file_buf
            and vim.api.nvim_win_get_buf(s.file_win) == s.shown_buf then
            if vim.api.nvim_buf_is_valid(s.file_buf) then
                vim.api.nvim_win_set_buf(s.file_win, s.file_buf)
            else
                vim.api.nvim_win_call(s.file_win, function() vim.cmd("enew") end)
            end
        end
        _restore_opts(s.file_win, s.saved)
    end

    if s.blame_win and vim.api.nvim_win_is_valid(s.blame_win) then
        if vim.api.nvim_win_get_buf(s.blame_win) ~= s.blame_buf then
            -- Something else took the window over (`:edit` from inside the
            -- sidebar); it is the user's window now, so only undo our options.
            _restore_opts(s.blame_win, s.saved_side)
        elseif not pcall(vim.api.nvim_win_close, s.blame_win, false) then
            -- The sidebar is the last window in its tabpage -- the file window
            -- was the one closed -- so it can't be closed. Hand it back to the
            -- blamed file rather than leave the user in a bare annotation
            -- column.
            if vim.api.nvim_buf_is_valid(s.file_buf) then
                vim.api.nvim_win_set_buf(s.blame_win, s.file_buf)
            end
            _restore_opts(s.blame_win, s.saved_side)
        end
    end
    if vim.api.nvim_buf_is_valid(s.blame_buf) then
        pcall(vim.api.nvim_buf_delete, s.blame_buf, { force = true })
    end
    for i = 2, #s.stack do
        if vim.api.nvim_buf_is_valid(s.stack[i].buf) then
            pcall(vim.api.nvim_buf_delete, s.stack[i].buf, { force = true })
        end
    end
end

--- Defer teardown to the next event loop tick: the events that end a session
--- fire *mid*-close and mid-edit, where closing another window trips Neovim's
--- own bookkeeping (E445) and the window layout isn't settled yet.
---@param session GitTools.BlameSession
local function _end_soon(session)
    vim.schedule(function()
        if _session == session then _end_blame() end
    end)
end

--- Parse `git blame --line-porcelain` output into one entry per final line.
--- In line-porcelain every content line (the `\t`-prefixed one) is preceded by
--- a full header block, so a header-then-content state machine suffices.
---@param out string
---@return GitTools.BlameEntry[]
local function _parse_blame(out)
    local entries = {}
    ---@type GitTools.BlameEntry?
    local cur
    for _, line in ipairs(vim.split(out, "\n", { plain = true })) do
        if line:sub(1, 1) == "\t" then
            if cur then entries[#entries + 1] = cur end
        else
            local hash, orig = line:match("^(%x+) (%d+) %d+")
            if hash and #hash >= 8 then
                cur = { hash = hash, orig_lnum = tonumber(orig) --[[@as integer]],
                    author = "", time = 0, summary = "" }
            elseif cur then
                local key, val = line:match("^([%w%-]+) (.*)$")
                if key == "author" then
                    cur.author = val
                elseif key == "author-time" then
                    cur.time = tonumber(val) or 0
                elseif key == "summary" then
                    cur.summary = val
                elseif key == "previous" then
                    cur.prev_hash, cur.prev_path = val:match("^(%x+) (.*)$")
                end
            end
        end
    end
    return entries
end

---@param entry GitTools.BlameEntry
---@return boolean
local function _is_uncommitted(entry)
    return entry.hash:match("^0+$") ~= nil
end

--- Render `entries` into aligned sidebar lines plus per-line highlight spans.
---@param entries GitTools.BlameEntry[]
---@return string[] lines
---@return integer  width  display width of the widest line
local function _format_lines(entries)
    local author_w = 0
    for _, e in ipairs(entries) do
        author_w = math.max(author_w, math.min(#e.author, _MAX_AUTHOR_W))
    end

    local lines = {}
    for _, e in ipairs(entries) do
        local author = e.author:sub(1, _MAX_AUTHOR_W)
        if _is_uncommitted(e) then author = "Not committed" end
        local date = e.time > 0 and os.date("%Y-%m-%d", e.time) or "----------"
        lines[#lines + 1] = string.format(
            "%s %s %-" .. author_w .. "s", e.hash:sub(1, 7), date, author)
    end
    return lines, 7 + 1 + 10 + 1 + author_w
end

--- Apply hash/date/author highlights to the sidebar buffer.
---@param buf     integer
---@param entries GitTools.BlameEntry[]
local function _highlight(buf, entries)
    for i, e in ipairs(entries) do
        local row = i - 1
        if _is_uncommitted(e) then
            vim.api.nvim_buf_set_extmark(buf, _ns, row, 0,
                { end_row = row, end_col = 0, hl_group = "Comment", hl_eol = true })
            vim.api.nvim_buf_set_extmark(buf, _ns, row, 0,
                { end_col = 7, hl_group = "Comment" })
        else
            vim.api.nvim_buf_set_extmark(buf, _ns, row, 0,
                { end_col = 7, hl_group = "Comment" })
            vim.api.nvim_buf_set_extmark(buf, _ns, row, 8,
                { end_col = 18, hl_group = "Number" })
            vim.api.nvim_buf_set_extmark(buf, _ns, row, 19,
                { end_row = row + 1, end_col = 0, hl_group = "Identifier", strict = false })
        end
    end
end

--- Diff `entry`'s commit against its first parent (or the empty tree for a
--- root commit) in a fresh tab via `gittools.diff`.
---@param root  string
---@param entry GitTools.BlameEntry
local function _diff_commit(root, entry)
    if _is_uncommitted(entry) then
        _notify("Line is not committed yet")
        return
    end
    if git.verify_rev(root, entry.hash .. "^") then
        difftool.diff({ revs = { entry.hash .. "^", entry.hash }, root = root })
    else
        difftool.diff({ revs = { _EMPTY_TREE, entry.hash }, root = root })
    end
end

--- Show the commit that last touched the line under the cursor -- header,
--- message and diffstat -- in a float over the sidebar, which is more of the
--- story than the one-line summary echoed on the command line.
---@param root  string
---@param entry GitTools.BlameEntry
local function _show_details(root, entry)
    if _is_uncommitted(entry) then
        _notify("Line is not committed yet")
        return
    end
    local out, err = git.show(root, entry.hash)
    if not out then
        _notify(err ~= "" and err or "git show failed", vim.log.levels.ERROR)
        return
    end
    hover.show(out, { title = entry.hash:sub(1, 7), syntax = "git" })
end

--- Bind scrolling between the file window and the blame sidebar, saving both
--- windows' previous option values for restoration on teardown.
---@param session GitTools.BlameSession
local function _bind_windows(session)
    local fw, bw = session.file_win, session.blame_win
    ---@cast fw integer
    ---@cast bw integer
    for _, opt in ipairs({ "scrollbind", "cursorbind", "wrap", "foldenable" }) do
        session.saved[opt] = vim.wo[fw][opt]
        session.saved_side[opt] = vim.wo[bw][opt]
    end
    for _, win in ipairs({ fw, bw }) do
        vim.wo[win].scrollbind = true
        vim.wo[win].cursorbind = true
        vim.wo[win].wrap       = false
        vim.wo[win].foldenable = false
    end
end

--- The file buffer leaving its window (`:edit other`, `:bdelete`, a `:close` we
--- didn't see) leaves the sidebar annotating something that is no longer on
--- screen. Re-check once the layout has settled: the same event fires when the
--- buffer is merely dropped from *another* window, which is not our business,
--- and when `_show_layer` swaps one level's buffer for another's.
---@param session GitTools.BlameSession
local function _check_file_win(session)
    vim.schedule(function()
        if _session ~= session then return end
        local fw = session.file_win
        if fw and vim.api.nvim_win_is_valid(fw)
            and vim.api.nvim_win_get_buf(fw) == session.shown_buf then
            return
        end
        _end_blame()
    end)
end

--- Write `entries` into the sidebar and fit its width to them.
---@param session GitTools.BlameSession
---@param entries GitTools.BlameEntry[]
local function _fill_sidebar(session, entries)
    local lines, width = _format_lines(entries)
    local buf = session.blame_buf
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].modified   = false
    vim.api.nvim_buf_clear_namespace(buf, _ns, 0, -1)
    _highlight(buf, entries)
    session.entries = entries
    if session.blame_win and vim.api.nvim_win_is_valid(session.blame_win) then
        vim.api.nvim_win_set_width(session.blame_win, width + 1)
    end
end

--- Show `layer` -- its file text in the file window, its annotations in the
--- sidebar -- with both windows on `view`'s line and scrolled alike.
---@param session GitTools.BlameSession
---@param layer   GitTools.BlameLayer
---@param view    table  a `winsaveview()`, or just `lnum` and `topline`
local function _show_layer(session, layer, view)
    local fw, bw = session.file_win, session.blame_win
    ---@cast fw integer
    ---@cast bw integer
    -- Before the swap: it is what the BufWinLeave check below compares with.
    session.shown_buf = layer.buf
    vim.api.nvim_win_set_buf(fw, layer.buf)
    -- A buffer new to the window may bring window options of its own.
    vim.wo[fw].scrollbind = true
    vim.wo[fw].cursorbind = true
    vim.wo[fw].wrap       = false
    vim.wo[fw].foldenable = false
    _fill_sidebar(session, layer.entries)
    pcall(vim.api.nvim_buf_set_name, session.blame_buf, "gittools://blame/" .. layer.label)

    local n = #layer.entries
    local lnum = math.max(1, math.min(view.lnum or 1, n))
    local top = math.max(1, math.min(view.topline or lnum, lnum))
    local restore = vim.tbl_extend("force", view, { lnum = lnum, topline = top })
    vim.api.nvim_win_call(fw, function() vim.fn.winrestview(restore) end)
    vim.api.nvim_win_call(bw, function()
        vim.fn.winrestview({ lnum = lnum, col = 0, topline = top })
        vim.cmd("syncbind")
    end)
end

--- The file window's view expressed from the sidebar's cursor, which is where
--- the user is when pressing `R` / `<BS>`.
---@param session GitTools.BlameSession
---@return integer lnum
---@return integer offset  cursor line minus the window's top line
local function _sidebar_pos(session)
    -- `nvim_win_call` hands back only the first of several return values.
    local pos = vim.api.nvim_win_call(session.blame_win, function()
        return { vim.fn.line("."), vim.fn.line("w0") }
    end)
    return pos[1], pos[1] - pos[2]
end

--- Re-blame the file as it stood just before the commit that last touched the
--- line under the cursor, stepping past that commit to whatever the line was
--- before it. The file window switches to a read-only copy of that version,
--- under its path there, so renames are followed. The cursor lands where the
--- line sat in the commit's own version, the closest thing the older one has
--- to it.
---@param session GitTools.BlameSession
local function _reblame(session)
    local lnum, offset = _sidebar_pos(session)
    local e = session.entries[lnum]
    if not e then return end
    if _is_uncommitted(e) then
        _notify("Line is not committed yet")
        return
    end
    if not e.prev_hash then
        _notify(("Nothing older to blame: %s added this line with the file")
            :format(e.hash:sub(1, 7)))
        return
    end

    local rev, path = e.prev_hash, e.prev_path
    local blob, err = git.run_raw(session.root, { "show", rev .. ":" .. path })
    local out
    if blob then
        out, err = git.run_raw(session.root, { "blame", "--line-porcelain", rev, "--", path })
    end
    if not out then
        _notify(err ~= "" and err or "git blame failed", vim.log.levels.ERROR)
        return
    end
    local entries = _parse_blame(out)
    if #entries == 0 then
        _notify("Nothing to blame at " .. rev:sub(1, 7))
        return
    end

    local ft = vim.bo[session.shown_buf].filetype
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false,
        vim.split((blob:gsub("\n$", "")), "\n", { plain = true }))
    vim.bo[buf].buftype    = "nofile"
    -- Kept while a later level covers it, so `<BS>` can come back to it.
    vim.bo[buf].bufhidden  = "hide"
    vim.bo[buf].swapfile   = false
    vim.bo[buf].filetype   = ft
    vim.bo[buf].modifiable = false
    vim.bo[buf].modified   = false
    pcall(vim.api.nvim_buf_set_name, buf, ("gittools://%s/%s"):format(rev:sub(1, 7), path))

    local below = session.stack[#session.stack]
    -- The sidebar's line rather than the file window's: the cursor is bound
    -- only to moves the user makes, so the two can differ.
    below.view = vim.tbl_extend("force",
        vim.api.nvim_win_call(session.file_win, vim.fn.winsaveview),
        { lnum = lnum, topline = lnum - offset })
    local layer = { buf = buf, entries = entries, label = rev:sub(1, 7) .. ":" .. path }
    session.stack[#session.stack + 1] = layer

    -- Losing this copy from the window ends the session the way losing the
    -- live buffer does; `_pop` clears these before it drops the copy itself.
    vim.api.nvim_create_autocmd("BufWinLeave", {
        group    = session.group,
        buffer   = buf,
        callback = function() _check_file_win(session) end,
    })
    vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
        group    = session.group,
        buffer   = buf,
        callback = function() _end_soon(session) end,
    })

    local at = math.max(1, e.orig_lnum)
    _show_layer(session, layer, { lnum = at, topline = at - offset })
    vim.api.nvim_echo({ { ("Blaming %s at %s  (<BS> to go back)"):format(path, rev:sub(1, 7)),
        "Normal" } }, false, {})
end

--- Step back down one level to the version `R` came from, where the cursor
--- was then.
---@param session GitTools.BlameSession
local function _pop(session)
    if #session.stack == 1 then
        _notify("Already blaming the working copy")
        return
    end
    local layer = table.remove(session.stack)
    local below = session.stack[#session.stack]
    _show_layer(session, below, below.view or { lnum = 1 })
    vim.api.nvim_clear_autocmds({ group = session.group, buffer = layer.buf })
    pcall(vim.api.nvim_buf_delete, layer.buf, { force = true })
end

--- Annotate the current buffer with `git blame` in a scroll-bound sidebar.
function M.blame()
    local buf = vim.api.nvim_get_current_buf()
    if vim.bo[buf].buftype ~= "" then
        _notify("GitTool blame needs a normal file buffer", vim.log.levels.WARN)
        return
    end

    local abs = vim.api.nvim_buf_get_name(buf)
    if abs == "" then
        _notify("Current buffer has no file name", vim.log.levels.WARN)
        return
    end
    abs = vim.fn.fnamemodify(abs, ":p")

    local root = git.root(vim.fs.dirname(abs))
    if not root then
        _notify("Not inside a git repository", vim.log.levels.WARN)
        return
    end

    local rel = git.relpath(root, abs)
    if not rel then
        _notify("File is outside the repository: " .. abs, vim.log.levels.WARN)
        return
    end

    -- Blame the buffer's live contents so unsaved edits stay aligned.
    local contents = table.concat(
        vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") .. "\n"
    local out, err = git.run_raw(root,
        { "blame", "--line-porcelain", "--contents", "-", "--", rel }, contents)
    if not out then
        _notify(err ~= "" and err or "git blame failed", vim.log.levels.ERROR)
        return
    end

    local entries = _parse_blame(out)
    if #entries == 0 then
        _notify("Nothing to blame")
        return
    end

    _end_blame()

    local lines, width = _format_lines(entries)

    local blame_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(blame_buf, 0, -1, false, lines)
    vim.bo[blame_buf].buftype    = "nofile"
    vim.bo[blame_buf].bufhidden  = "wipe"
    vim.bo[blame_buf].swapfile   = false
    vim.bo[blame_buf].modifiable = false
    vim.bo[blame_buf].filetype   = "gittoolsblame"
    pcall(vim.api.nvim_buf_set_name, blame_buf, "gittools://blame/" .. rel)
    _highlight(blame_buf, entries)

    local file_win = vim.api.nvim_get_current_win()
    local view = vim.fn.winsaveview()

    vim.cmd("leftabove vsplit")
    local blame_win = vim.api.nvim_get_current_win()

    -- Remember the fresh split's inherited options: teardown usually just
    -- closes this window, but not always (see `_end_blame`).
    local saved_side = {}
    for _, opt in ipairs({ "winfixwidth", "number", "relativenumber",
        "signcolumn", "foldcolumn", "list", "winbar" }) do
        saved_side[opt] = vim.wo[blame_win][opt]
    end

    vim.api.nvim_win_set_buf(blame_win, blame_buf)
    vim.api.nvim_win_set_width(blame_win, width + 1)
    vim.wo[blame_win].winfixwidth    = true
    vim.wo[blame_win].number         = false
    vim.wo[blame_win].relativenumber = false
    vim.wo[blame_win].signcolumn     = "no"
    vim.wo[blame_win].foldcolumn     = "0"
    vim.wo[blame_win].list           = false
    vim.wo[blame_win].winbar         = ""

    local group = vim.api.nvim_create_augroup("gittools.blame", { clear = true })
    local session = {
        group     = group,
        root      = root,
        rel       = rel,
        file_win  = file_win,
        file_buf  = buf,
        shown_buf = buf,
        stack     = { { buf = buf, entries = entries, label = rel } },
        entries   = entries,
        blame_win = blame_win,
        blame_buf = blame_buf,
        saved     = {},
        saved_side = saved_side,
    }
    _session = session

    _bind_windows(session)

    -- Line up the sidebar with the file view, then let scrollbind take over.
    vim.api.nvim_win_set_cursor(blame_win, { math.min(view.lnum, #lines), 0 })
    vim.fn.winrestview({ topline = view.topline })
    vim.api.nvim_set_current_win(file_win)
    vim.fn.winrestview(view)
    vim.cmd("syncbind")

    for _, win in ipairs({ file_win, blame_win }) do
        vim.api.nvim_create_autocmd("WinClosed", {
            group    = group,
            pattern  = tostring(win),
            callback = function()
                if win == session.file_win then session.file_win = nil end
                if win == session.blame_win then session.blame_win = nil end
                _end_soon(session)
            end,
        })
    end

    vim.api.nvim_create_autocmd("BufWinLeave", {
        group    = group,
        buffer   = buf,
        callback = function() _check_file_win(session) end,
    })
    -- Wiping the buffer while it is hidden never passes through BufWinLeave.
    vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
        group    = group,
        buffer   = buf,
        callback = function() _end_soon(session) end,
    })
    -- Editing or reloading the file invalidates line alignment; drop the
    -- sidebar. (`:edit!` rewrites the buffer without a TextChanged.)
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufReadPost" }, {
        group    = group,
        buffer   = buf,
        callback = function() _end_soon(session) end,
    })
    -- Something else took over the sidebar window (`:edit` from inside it):
    -- bufhidden=wipe destroys our annotations, so the session is over.
    vim.api.nvim_create_autocmd({ "BufWinLeave", "BufWipeout" }, {
        group    = group,
        buffer   = blame_buf,
        callback = function() _end_soon(session) end,
    })

    vim.api.nvim_create_autocmd("CursorMoved", {
        group    = group,
        buffer   = blame_buf,
        callback = function()
            local lnum = vim.api.nvim_win_get_cursor(0)[1]
            local e = session.entries[lnum]
            if not e then return end
            local msg = _is_uncommitted(e) and "Not committed yet" or e.summary
            vim.api.nvim_echo({ { msg, "Normal" } }, false, {})
        end,
    })

    vim.keymap.set("n", "<CR>", function()
        local lnum = vim.api.nvim_win_get_cursor(0)[1]
        local e = session.entries[lnum]
        if e then _diff_commit(root, e) end
    end, { buffer = blame_buf, desc = "Diff commit under cursor" })

    vim.keymap.set("n", "K", function()
        local lnum = vim.api.nvim_win_get_cursor(0)[1]
        local e = session.entries[lnum]
        if e then _show_details(root, e) end
    end, { buffer = blame_buf, desc = "Show details of commit under cursor" })

    vim.keymap.set("n", "R", function() _reblame(session) end,
        { buffer = blame_buf, desc = "Re-blame at the parent of the commit under cursor" })

    vim.keymap.set("n", "<BS>", function() _pop(session) end,
        { buffer = blame_buf, desc = "Back to the blame R came from" })

    keyhelp.map(blame_buf, { "<CR>", "K", "R", "<BS>" })
end

return M
