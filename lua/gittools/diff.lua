local M       = {}

local git     = require("gittools.git")
local session = require("gittools.util.diffsession")

--- The git-backed front end for `:GitTool diff`. It turns the requested
--- revision/index/working-tree comparison into the list of changed files, then
--- hands those to the generic `gittools.util.diffsession` engine, which owns the
--- split layout, the file-list picker, and the native diff. The Side/DiffItem
--- shapes it builds are defined by that engine.

---@param msg string
---@param level integer?
local function _notify(msg, level)
    vim.notify("[gittools] " .. msg, level or vim.log.levels.INFO)
end

--- Close the active diff session, if any (e.g. on VimLeavePre).
function M.clear_session()
    session.clear()
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
--- current window, driving a custom file list (in a bottom split) that selects
--- the file shown in a side-by-side native diff. It opens with the cursor in
--- the right (target) pane, showing the first changed file; `]f` / `[f` step
--- through the rest from there. `<C-w>j` drops into the list, where `<CR>`
--- shows the file under the cursor (staying in the list, so the user can flip
--- through files) and `q` closes the session. Closing either split window or
--- the file list collapses back to a single window, restoring the original
--- layout.
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

    ---@type GitTools.DiffItem[]
    local items = {}
    for _, change in ipairs(changes) do
        items[#items + 1] = {
            status    = change.status,
            root      = root,
            left_rel  = change.left_rel,
            right_rel = change.right_rel,
            left      = left,
            right     = right,
        }
    end

    session.open(items)
end

return M
