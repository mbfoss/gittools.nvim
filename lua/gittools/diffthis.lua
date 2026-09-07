local M   = {}

local git     = require("gittools.util.git")
local keyhelp = require("gittools.util.keyhelp")

--- The single-file feature behind `:Gittools diffthis [<rev>]`. It diffs the
--- *current buffer* -- including unsaved edits -- against its git version using
--- Neovim's native diff mode in a side split. No temp files and no quickfix:
--- for one file the built-in `:diffthis` is enough. The git side (default: the
--- index, i.e. a bare `git diff <file>`) is materialised in a read-only scratch
--- buffer on the left; the live buffer stays on the right, so the diff tracks
--- edits as you type.

---@param msg string
---@param level integer?
local function _notify(msg, level)
    vim.notify("[gittools] " .. msg, level or vim.log.levels.INFO)
end

--- Split a git blob into buffer lines, dropping the single trailing newline a
--- well-formed text file ends with (otherwise `split` yields a phantom blank
--- last line).
---@param blob string
---@return string[]
local function _blob_lines(blob)
    if blob:sub(-1) == "\n" then
        blob = blob:sub(1, -2)
    end
    return vim.split(blob, "\n", { plain = true })
end

--- The git side's lines: `rev:rel`, or the index stage when `rev` is nil.
---@param root string
---@param rev  string?
---@param rel  string
---@return string[]
local function _git_lines(root, rev, rel)
    local spec = rev and (rev .. ":" .. rel) or (":" .. rel)
    local blob = git.run_raw(root, { "show", spec })
    return blob and _blob_lines(blob) or {}
end

--- The active diffthis session. Only one exists at a time. nil when idle.
---@class GitTools.DiffThisSession
---@field buf      integer   the live file buffer
---@field base?    integer?  the gittools:// scratch buffer
---@field group    integer   the session's autocmd group
---@field base_win? number
---@field cur_win?  number
---@field root     string    repo root
---@field rel      string    the file's path in the repo
---@field rev?     string?   revision compared against; nil = the index
---@type GitTools.DiffThisSession?
local _session = nil

--- Tear down `session`'s diff. The `gittools://` side is a throwaway scratch
--- buffer, so drop it rather than leave it lingering in the buffer list.
local function _end_diff()
    if not _session then return end
    local buf, base, group = _session.buf, _session.base, _session.group
    vim.api.nvim_del_augroup_by_id(group)
    if _session and _session.base_win and _session.cur_win then
        vim.api.nvim_win_close(_session.base_win, false)
        _session.base_win = nil
    end
    if base then
        for _, win in ipairs(vim.fn.win_findbuf(base)) do
            if vim.api.nvim_buf_is_valid(buf) then
                vim.api.nvim_win_set_buf(win, buf)
            else
                vim.api.nvim_win_call(win, function() vim.cmd("enew") end)
            end
        end
        if _session and _session.base and vim.api.nvim_buf_is_valid(_session.base) then
            vim.api.nvim_buf_delete(_session.base, { force = true })
        end
    end

    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
        vim.api.nvim_win_call(win, function() vim.cmd("diffoff") end)
    end
    _session = nil
end

---@class GitTools.DiffThisOpts
---@field rev string?  revision to compare against; nil = the index

--- Diff the current buffer against `opts.rev` (default: the index).
---@param opts GitTools.DiffThisOpts?
local function _diffthis(opts)
    opts = opts or {}
    local rev = opts.rev

    local buf = vim.api.nvim_get_current_buf()
    if vim.bo[buf].buftype ~= "" then
        _notify("Gittools diffthis needs a normal file buffer", vim.log.levels.WARN)
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

    if rev and not git.verify_rev(root, rev) then
        _notify("Unknown revision: " .. rev, vim.log.levels.ERROR)
        return
    end

    local base_lines = _git_lines(root, rev, rel)

    local base = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(base, 0, -1, false, base_lines)
    vim.bo[base].buftype = "nofile"
    vim.bo[base].bufhidden = "wipe"
    vim.bo[base].swapfile = false
    vim.bo[base].filetype = vim.bo[buf].filetype
    vim.bo[base].modifiable = false
    pcall(vim.api.nvim_buf_set_name, base,
        ("gittools://%s/%s"):format(rev or "index", rel))

    local cur_win = vim.api.nvim_get_current_win()
    vim.cmd("leftabove vsplit")
    local base_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(0, base)
    vim.cmd("diffthis")
    vim.api.nvim_set_current_win(cur_win)
    vim.cmd("diffthis")

    local group = vim.api.nvim_create_augroup(
        ("gittools.diffthis.%d"):format(base), { clear = true })
    local session = {
        buf      = buf,
        base     = base,
        group    = group,
        cur_win  = cur_win,
        base_win = base_win,
        root     = root,
        rel      = rel,
        rev      = rev,
    }
    _session = session

    keyhelp.map(base, {}, {
        { "]c", "Jump to the next change" },
        { "[c", "Jump to the previous change" },
    })
    vim.api.nvim_create_autocmd("BufWipeout", {
        group    = group,
        buffer   = base,
        callback = function()
            session.base = nil
            _end_diff()
        end,
    })
    vim.api.nvim_create_autocmd("WinClosed", {
        group    = group,
        pattern  = tostring(cur_win),
        callback = function(args)
            local win = tonumber(args.match)
            if win == session.base_win then
                session.base_win = nil
            end
            if win == session.cur_win then
                session.cur_win = nil
            end
            _end_diff()
        end,
    })
end

--- Whether the current buffer belongs to a live diffthis session.
---@return boolean
function M.is_active()
    local s = _session
    if not s then return false end
    local buf = vim.api.nvim_get_current_buf()
    return buf == s.buf or buf == s.base
end

--- Refresh the active session's git side from the repository, keeping each
--- pane's cursor line where it still exists.
function M.refresh()
    if not M.is_active() then return end
    local s = _session
    ---@cast s GitTools.DiffThisSession
    if not (s.base and vim.api.nvim_buf_is_valid(s.base)) then return end

    local lines = _git_lines(s.root, s.rev, s.rel)
    local base = s.base
    ---@cast base integer

    local views = {}
    for _, win in ipairs(vim.fn.win_findbuf(base)) do
        views[win] = vim.api.nvim_win_call(win, vim.fn.winsaveview)
    end

    vim.bo[base].modifiable = true
    vim.api.nvim_buf_set_lines(base, 0, -1, false, lines)
    vim.bo[base].modifiable = false
    vim.bo[base].modified   = false

    for win, view in pairs(views) do
        if vim.api.nvim_win_is_valid(win) then
            local lnum = math.max(1, math.min(view.lnum or 1, #lines))
            view.lnum    = lnum
            view.topline = math.max(1, math.min(view.topline or 1, lnum))
            vim.api.nvim_win_call(win, function()
                vim.fn.winrestview(view)
                vim.cmd("diffupdate")
            end)
        end
    end
    return true
end

--- Diff the current buffer against `opts.rev` (default: the index).
---@param opts GitTools.DiffThisOpts?
function M.diffthis(opts)
    _end_diff()
    _diffthis(opts)
end

return M
