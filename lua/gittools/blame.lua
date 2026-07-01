local M        = {}

local git      = require("gittools.git")
local difftool = require("gittools.diff")

--- `:GitTool blame` -- annotate the current buffer with per-line commit info
--- in a scroll-bound sidebar, fugitive-style. The buffer's *live* contents are
--- piped to `git blame --contents -`, so unsaved edits stay line-aligned and
--- show up as "Not committed". In the sidebar: the commit summary is echoed as
--- the cursor moves, `<CR>` diffs the commit under the cursor against its
--- parent (via `gittools.diff`), and `q` closes the sidebar.

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
---@field hash    string
---@field author  string
---@field time    integer
---@field summary string

--- The active blame session. Only one exists at a time. nil when idle.
---@class GitTools.BlameSession
---@field group     integer
---@field file_win  integer?
---@field blame_win integer?
---@field blame_buf integer
---@field saved     table<string, any>  file-window options to restore on close
---@type GitTools.BlameSession?
local _session = nil

--- Tear down the active blame session: drop autocmds, close the sidebar, and
--- restore the file window's scroll options. Safe to call anytime.
local function _end_blame()
    if not _session then return end
    local s = _session
    _session = nil

    pcall(vim.api.nvim_del_augroup_by_id, s.group)

    if s.file_win and vim.api.nvim_win_is_valid(s.file_win) then
        for opt, val in pairs(s.saved) do
            vim.wo[s.file_win][opt] = val
        end
    end
    if s.blame_win and vim.api.nvim_win_is_valid(s.blame_win) then
        pcall(vim.api.nvim_win_close, s.blame_win, false)
    end
    if vim.api.nvim_buf_is_valid(s.blame_buf) then
        pcall(vim.api.nvim_buf_delete, s.blame_buf, { force = true })
    end
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
            local hash = line:match("^(%x+) %d+ %d+")
            if hash and #hash >= 8 then
                cur = { hash = hash, author = "", time = 0, summary = "" }
            elseif cur then
                local key, val = line:match("^([%w%-]+) (.*)$")
                if key == "author" then
                    cur.author = val
                elseif key == "author-time" then
                    cur.time = tonumber(val) or 0
                elseif key == "summary" then
                    cur.summary = val
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

--- Bind scrolling between the file window and the blame sidebar, saving the
--- file window's previous option values for restoration on teardown.
---@param session GitTools.BlameSession
local function _bind_windows(session)
    local fw, bw = session.file_win, session.blame_win
    ---@cast fw integer
    ---@cast bw integer
    for _, opt in ipairs({ "scrollbind", "cursorbind", "wrap", "foldenable" }) do
        session.saved[opt] = vim.wo[fw][opt]
    end
    for _, win in ipairs({ fw, bw }) do
        vim.wo[win].scrollbind = true
        vim.wo[win].cursorbind = true
        vim.wo[win].wrap       = false
        vim.wo[win].foldenable = false
    end
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
        file_win  = file_win,
        blame_win = blame_win,
        blame_buf = blame_buf,
        saved     = {},
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
                _end_blame()
            end,
        })
    end
    -- Editing the file invalidates line alignment; drop the sidebar.
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
        group    = group,
        buffer   = buf,
        callback = _end_blame,
    })

    vim.api.nvim_create_autocmd("CursorMoved", {
        group    = group,
        buffer   = blame_buf,
        callback = function()
            local lnum = vim.api.nvim_win_get_cursor(0)[1]
            local e = entries[lnum]
            if not e then return end
            local msg = _is_uncommitted(e) and "Not committed yet" or e.summary
            vim.api.nvim_echo({ { msg, "Normal" } }, false, {})
        end,
    })

    vim.keymap.set("n", "q", _end_blame,
        { buffer = blame_buf, desc = "Close blame sidebar" })
    vim.keymap.set("n", "<CR>", function()
        local lnum = vim.api.nvim_win_get_cursor(0)[1]
        local e = entries[lnum]
        if e then _diff_commit(root, e) end
    end, { buffer = blame_buf, desc = "Diff commit under cursor" })
end

return M
