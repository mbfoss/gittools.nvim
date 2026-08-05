local M       = {}

local git     = require("gittools.util.git")
local session = require("gittools.util.diffsession")

--- The path-backed front end for `:GitTool diffpaths`. It compares two
--- filesystem paths that need not lie in any git repository -- either two
--- files, or two directories (recursively) -- and hands the differing files to
--- the generic `gittools.util.diffsession` engine, the same one `gittools.diff`
--- uses. Each side is read straight off disk via a `path` Side.
---
--- Two directories are also how `git difftool --dir-diff` invokes a tool, so
--- this is the path a difftool takes; see `_GITLINK_LINE` for what that means
--- for the submodules in such a comparison.

---@param msg string
---@param level integer?
local function _notify(msg, level)
    vim.notify("[gittools] " .. msg, level or vim.log.levels.INFO)
end

--- `git difftool --dir-diff` (`git difftool -d`) checks both sides out into
--- temp trees and hands them to the tool as two directories -- which is how a
--- difftool ends up here rather than in `gittools.diff`. A submodule cannot be
--- checked out into such a tree, so git writes it as a plain one-line file
--- holding the gitlink exactly as a patch would show it, with an all-zero id
--- standing in for whichever side is the live working tree. That line is the
--- only trace of the submodule in the temp trees, so it is what identifies one.
local _GITLINK_LINE = "^Subproject commit (%x+)%s*$"

--- The commit id of the gitlink stand-in at `path`, or nil if it is an ordinary
--- file. Read at most once per side, and only for files small enough to be that
--- single line in the first place.
---@param path string?
---@return string? sha  as written, so an all-zero id comes back as such
local function _gitlink_sha(path)
    if not path then return nil end
    local st = vim.uv.fs_stat(path)
    if not st or st.type ~= "file" or st.size > 80 then return nil end
    local ok, lines = pcall(vim.fn.readfile, path, "", 2)
    if not ok or #lines ~= 1 then return nil end
    return lines[1]:match(_GITLINK_LINE)
end

---@param sha string?
---@return string?  nil for the all-zero placeholder
local function _real_sha(sha)
    if not sha or sha:match("^0+$") then return nil end
    return sha
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
--- --no-index`). Two directories give one list entry per differing file, in the
--- same side-by-side layout `:GitTool diff` uses; two files open the diff on its
--- own, with no file list. Both sides are the real files on
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

    -- The repo the tool was invoked from, which is where a gitlink stand-in
    -- found in the temp trees has its real submodule: `git difftool` always runs
    -- the tool from the top of the working tree, whichever directory the user
    -- ran it in. Resolved once, and only if a gitlink actually turns up -- a
    -- plain `:GitTool diffpaths` of two directories need not be in a repo at
    -- all, and without one there is no submodule to descend into, so those rows
    -- stay the ordinary files they look like.
    local repo_root, repo_looked_up
    local function _repo()
        if not repo_looked_up then
            repo_looked_up = true
            repo_root = git.root(vim.uv.cwd() or ".")
        end
        return repo_root
    end

    ---@type GitTools.DiffItem[]
    local items = {}
    for _, change in ipairs(changes) do
        local left_sha  = _gitlink_sha(change.left_path)
        local right_sha = _gitlink_sha(change.right_path)
        local submodule = (left_sha or right_sha) ~= nil and _repo() ~= nil
        items[#items + 1] = {
            status    = change.status,
            root      = submodule and _repo() or nil,
            left_rel  = change.left_rel,
            right_rel = change.right_rel,
            left      = { path = change.left_path },
            right     = { path = change.right_path },
            submodule = submodule or nil,
            left_sha  = submodule and _real_sha(left_sha) or nil,
            right_sha = submodule and _real_sha(right_sha) or nil,
        }
    end

    -- Two files are a single comparison: skip the file list, which would only
    -- be a one-line split taking up room below the diff.
    session.open(items, { list = a_dir })
end

return M
