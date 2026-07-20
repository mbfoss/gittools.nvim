local M       = {}

local git     = require("gittools.git")
local session = require("gittools.util.diffsession")

--- The path-backed front end for `:GitTool diffpaths`. It compares two
--- filesystem paths that need not lie in any git repository -- either two
--- files, or two directories (recursively) -- and hands the differing files to
--- the generic `gittools.util.diffsession` engine, the same one `gittools.diff`
--- uses. Each side is read straight off disk via a `path` Side.

---@param msg string
---@param level integer?
local function _notify(msg, level)
    vim.notify("[gittools] " .. msg, level or vim.log.levels.INFO)
end

--- One differing file between two paths, with the absolute on-disk path for
--- each side (nil where the file exists on only one side).
---@class GitTools.PathChange
---@field status     "A"|"M"|"D" single-letter status
---@field left_rel   string? display path on the left; nil if absent (added)
---@field right_rel  string? display path on the right; nil if absent (deleted)
---@field left_path  string? absolute on-disk path on the left; nil if absent
---@field right_path string? absolute on-disk path on the right; nil if absent

--- Recursively compare directories `a_abs` and `b_abs` via `git diff
--- --no-index`, returning one change per differing file. git reports an
--- added/deleted file under whichever directory it lives in, so the
--- surviving-side path is taken straight from git's output and the missing side
--- left nil; an in-place change (M) is reported under `a_abs`, from which the
--- right path is re-rooted under `b_abs`. Returns nil after notifying on a real
--- git failure.
---@param a_abs string absolute directory path (left)
---@param b_abs string absolute directory path (right)
---@return GitTools.PathChange[]? changes
local function _collect_dir_changes(a_abs, b_abs)
    local out, err = git.diff_no_index(a_abs, b_abs)
    if not out then
        _notify("git diff --no-index failed: " .. (err or "unknown error"), vim.log.levels.ERROR)
        return nil
    end

    local changes = {}
    for _, line in ipairs(git.lines(out)) do
        local parts  = vim.split(line, "\t", { plain = true })
        local status = parts[1]:sub(1, 1)
        if status == "D" then
            changes[#changes + 1] = {
                status    = "D",
                left_rel  = git.relpath(a_abs, parts[2]),
                left_path = parts[2],
            }
        elseif status == "A" then
            changes[#changes + 1] = {
                status     = "A",
                right_rel  = git.relpath(b_abs, parts[2]),
                right_path = parts[2],
            }
        else
            local rel = git.relpath(a_abs, parts[2])
            changes[#changes + 1] = {
                status     = "M",
                left_rel   = rel,
                right_rel  = rel,
                left_path  = parts[2],
                right_path = rel and (b_abs .. "/" .. rel) or nil,
            }
        end
    end

    table.sort(changes, function(x, y)
        return (x.right_rel or x.left_rel) < (y.right_rel or y.left_rel)
    end)
    return changes
end

--- Diff two filesystem paths that need not lie in any git repository: either
--- two files, or two directories (compared recursively via `git diff
--- --no-index`). Each differing file becomes a list entry in the same
--- side-by-side layout `:GitTool diff` uses. Both sides are the real files on
--- disk, so either can be edited and written from inside the diff (Neovim
--- marks a file it can't write 'readonly' as usual). The two paths must be the
--- same kind (both files or both directories).
---@param a string left path (file or directory)
---@param b string right path (file or directory)
function M.diffpaths(a, b)
    if not (a and b) or a == "" or b == "" then
        _notify("diffpaths needs two paths", vim.log.levels.ERROR)
        return
    end

    -- fnamemodify(":p") absolutises and keeps a trailing slash on directories;
    -- strip it so prefix arithmetic below is uniform for files and dirs.
    local a_abs = (vim.fn.fnamemodify(a, ":p"):gsub("/+$", ""))
    local b_abs = (vim.fn.fnamemodify(b, ":p"):gsub("/+$", ""))

    local a_dir = vim.fn.isdirectory(a_abs) == 1
    local b_dir = vim.fn.isdirectory(b_abs) == 1
    for path, is_dir in pairs({ [a_abs] = a_dir, [b_abs] = b_dir }) do
        if not is_dir and vim.fn.filereadable(path) == 0 then
            _notify("No such file or directory: " .. path, vim.log.levels.ERROR)
            return
        end
    end
    if a_dir ~= b_dir then
        _notify("Both paths must be files, or both must be directories", vim.log.levels.ERROR)
        return
    end

    ---@type GitTools.PathChange[]
    local changes
    if a_dir then
        local collected = _collect_dir_changes(a_abs, b_abs)
        if not collected then return end -- git failure, already notified
        if #collected == 0 then
            _notify("No changes found")
            return
        end
        changes = collected
    else
        changes = { {
            status     = "M",
            left_rel   = vim.fn.fnamemodify(a_abs, ":t"),
            right_rel  = vim.fn.fnamemodify(b_abs, ":t"),
            left_path  = a_abs,
            right_path = b_abs,
        } }
    end

    ---@type GitTools.DiffItem[]
    local items = {}
    for _, change in ipairs(changes) do
        items[#items + 1] = {
            status    = change.status,
            left_rel  = change.left_rel,
            right_rel = change.right_rel,
            left      = { path = change.left_path },
            right     = { path = change.right_path },
        }
    end

    session.open(items)
end

return M
