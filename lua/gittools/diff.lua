local M       = {}

local git     = require("gittools.util.git")
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

--- Close every live diff session (e.g. on VimLeavePre).
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

--- Split positional arguments that were given *without* a `--` separator into
--- revisions and pathspecs, the way git itself disambiguates them: leading
--- arguments that resolve to a tree-ish are revisions, and everything from the
--- first non-revision onwards is a pathspec. An argument that is neither a
--- known revision nor an existing path is rejected rather than silently kept
--- as a pathspec that can never match -- again mirroring git, which asks for an
--- explicit `--` in exactly that case (so do wildcards, which do not name an
--- existing file either).
---@param root string repo root
---@param cwd  string directory the pathspecs are relative to
---@param args string[]
---@return string[]? revs
---@return string[]? paths
---@return string?   err  set (with revs/paths nil) when an argument is ambiguous
local function _split_args(root, cwd, args)
    local revs, paths = {}, {}
    for _, a in ipairs(args) do
        if #paths == 0 and git.verify_rev(root, a) then
            revs[#revs + 1] = a
        elseif vim.uv.fs_stat(vim.fs.normalize(vim.fs.joinpath(cwd, a))) then
            paths[#paths + 1] = a
        else
            return nil, nil, ("ambiguous argument '%s': unknown revision or path not in the "
                .. "working tree; use '--' to separate paths from revisions"):format(a)
        end
    end
    return revs, paths, nil
end

---@class GitTools.Change
---@field left_rel  string? path on the left side; nil if the file was added
---@field right_rel string? path on the right side; nil if the file was deleted
---@field status     "A"|"M"|"D"|"R"|"C"|"?" single-letter status, mirroring
---                   `git status --short` (`?` for untracked)
---@field submodule boolean? the entry is a gitlink (a submodule), not a file
---@field left_sha  string? object recorded on the left; nil when the side has
---                  none of its own (an absent side, or the working tree)
---@field right_sha string? object recorded on the right; as above

-- The mode git gives a gitlink, i.e. a submodule reference. Such an entry is
-- not a file: its "content" is a commit id pointing into another repository.
local _GITLINK_MODE = "160000"

-- The well-known hash of git's empty tree, used as the left side when there is
-- nothing to compare against (a submodule that was only just added).
local _EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

--- A sha field of `git diff --raw`, or nil when it is the all-zeros placeholder
--- git prints for "no object here" -- a side the entry is absent from, or one
--- that is the live working tree rather than a recorded object.
---@param sha string?
---@return string?
local function _sha(sha)
    if not sha or sha:match("^0+$") then return nil end
    return sha
end

--- Parse `git diff --raw -M` output into per-file change records, keeping the
--- old and new paths of a rename/copy distinct instead of collapsing them into
--- a single name. `--raw` rather than `--name-status` for the two extra columns
--- it carries: the file modes (which is how a submodule is recognised) and the
--- object ids of each side (which is what a submodule's own diff is opened
--- between).
---
--- Each line is `:<srcmode> <dstmode> <srcsha> <dstsha> <status>` followed by a
--- tab and the path(s).
---@param out string?
---@return GitTools.Change[]
local function _parse_raw(out)
    local changes = {}
    for _, line in ipairs(git.lines(out)) do
        local parts     = vim.split(line, "\t", { plain = true })
        local meta      = vim.split(parts[1], " ", { trimempty = true })
        local status    = (meta[5] or ""):sub(1, 1)
        local common    = {
            submodule = meta[1]:sub(2) == _GITLINK_MODE or meta[2] == _GITLINK_MODE,
            left_sha  = _sha(meta[3]),
            right_sha = _sha(meta[4]),
        }
        local change
        if status == "R" or status == "C" then
            change = { left_rel = parts[2], right_rel = parts[3], status = status }
        elseif status == "A" then
            change = { right_rel = parts[2], status = status }
        elseif status == "D" then
            change = { left_rel = parts[2], status = status }
        else
            change = { left_rel = parts[2], right_rel = parts[2], status = "M" }
        end
        changes[#changes + 1] = vim.tbl_extend("error", change, common)
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
---
--- `paths`, when non-empty, restricts the result to the matching files. They
--- are git pathspecs, not plain paths, so they are handed to git verbatim and
--- resolved from `cwd` (git resolves pathspecs relative to the working
--- directory, not the repo root). `--full-name` keeps `ls-files` reporting
--- root-relative paths from a subdirectory, which is what `git diff` reports
--- unconditionally and what the rest of this module expects.
---@param root  string repo root
---@param left  GitTools.Side
---@param right GitTools.Side
---@param paths string[]? pathspecs limiting the diff
---@param cwd   string?   directory the pathspecs resolve from (default: `root`)
---@return GitTools.Change[] changes
local function _collect_changes(root, left, right, paths, cwd)
    paths = paths or {}
    -- Without pathspecs, run from the root: `ls-files` would otherwise report
    -- only what lies under `cwd`, while `git diff` always covers the whole tree.
    local runcwd = #paths > 0 and (cwd or root) or root

    --- Append `-- <pathspec>...` to a git argument list, if there are any.
    ---@param args string[]
    ---@return string[]
    local function limited(args)
        if #paths > 0 then
            args[#args + 1] = "--"
            vim.list_extend(args, paths)
        end
        return args
    end

    local args, include_untracked
    if right.worktree then
        args = { "diff", "--raw", "--no-abbrev", "-M" }
        if left.rev then args[#args + 1] = left.rev end
        include_untracked = true
    elseif right.index then
        args, include_untracked = { "diff", "--raw", "--no-abbrev", "-M", "--cached", left.rev }, false
    else
        args, include_untracked = { "diff", "--raw", "--no-abbrev", "-M", left.rev, right.rev }, false
    end
    args = limited(args)

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

    for _, change in ipairs(_parse_raw((git.run(runcwd, args)))) do add(change) end
    if include_untracked then
        for _, rel in ipairs(git.lines((git.run(runcwd,
            limited({ "ls-files", "--others", "--exclude-standard", "--full-name" }))))) do
            add({ right_rel = rel, status = "?" })
        end
        -- Dirty buffers carry no git status to filter on, so let git itself say
        -- which tracked files the pathspecs select and keep only those.
        local selected
        if #paths > 0 then
            selected = {}
            for _, rel in ipairs(git.lines((git.run(runcwd, limited({ "ls-files", "--full-name" }))))) do
                selected[rel] = true
            end
        end
        for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_is_loaded(bufnr)
                and vim.bo[bufnr].modified
                and vim.bo[bufnr].buftype == "" then
                local rel = git.relpath(root, vim.api.nvim_buf_get_name(bufnr))
                if rel and (not selected or selected[rel]) then
                    add({ left_rel = rel, right_rel = rel, status = "M" })
                end
            end
        end
    end

    table.sort(changes, function(a, b)
        return (a.right_rel or a.left_rel) < (b.right_rel or b.left_rel)
    end)
    return changes
end

--- Hand `changes` to the diff-session engine as items comparing `left` against
--- `right` in `root`.
---@param root    string repo root
---@param left    GitTools.Side
---@param right   GitTools.Side
---@param changes GitTools.Change[] non-empty
local function _open_changes(root, left, right, changes)
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
            submodule = change.submodule,
            left_sha  = change.left_sha,
            right_sha = change.right_sha,
        }
    end
    session.open(items)
end

--- The set of paths (relative to the repo root) that differ between `left`
--- and `right`. For renames/copies this reports only the new path; use
--- `_collect_changes` where the old path (for diffing against prior content)
--- is also needed.
---@param root  string repo root
---@param left  GitTools.Side
---@param right GitTools.Side
---@param paths string[]? pathspecs limiting the diff
---@param cwd   string?   directory the pathspecs resolve from (default: `root`)
---@return string[] rels
function M.changed_paths_between(root, left, right, paths, cwd)
    local rels = {}
    for _, change in ipairs(_collect_changes(root, left, right, paths, cwd)) do
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
---@field paths  string[]? pathspecs limiting the diff, i.e. git's `-- <path>...`
---@field args   string[]? positionals not yet split into revisions and
---                        pathspecs, for a command line that carried no `--`;
---                        mutually exclusive with `revs`/`paths`
---@field root   string?   repo root to diff in (default: the root containing the editor's cwd)

--- Diff the requested revisions/index/working-tree sides in a tab of its own
--- (the current tab is reused only when it's an unused editor), driving a
--- custom file list (in a bottom split) that selects the file shown in a
--- side-by-side native diff. It opens with the cursor in the right (target)
--- pane, showing the first changed file; `]f` / `[f` step through the rest from
--- there. `<C-w>j` drops into the list, where `<CR>` shows the file under the
--- cursor (staying in the list, so the user can flip through files) and `c`, on
--- a submodule row, opens a diff of the submodule itself in a further tab (see
--- `M.diff_submodule`). Closing either split window or the file list ends the
--- session and, with it, the tab it opened -- so the windows the diff was
--- launched from are left exactly as they were.
---
--- Arguments follow `git diff`: up to two revisions, optionally followed by
--- pathspecs limiting the diff, either after an explicit `--` or -- when they
--- are unambiguous -- straight after the revisions.
---@param opts GitTools.DiffOpts?
function M.diff(opts)
    opts = opts or {}
    local staged = opts.staged or false

    local root = opts.root or git.root()
    if not root then
        _notify("Not inside a git repository", vim.log.levels.WARN)
        return
    end

    -- Pathspecs are resolved from the editor's cwd, as they are on git's own
    -- command line -- unless that cwd sits outside the repo being diffed (a
    -- diff launched with an explicit `root`), where the root is all we have.
    local cwd = vim.uv.cwd() or root
    if cwd ~= root and not git.relpath(root, cwd) then cwd = root end

    local revs, paths = opts.revs or {}, opts.paths or {}
    if opts.args then
        local split_revs, split_paths, split_err = _split_args(root, cwd, opts.args)
        if split_err then
            _notify(split_err, vim.log.levels.ERROR)
            return
        end
        revs, paths = split_revs or {}, split_paths or {}
    end

    local left, right, err = _resolve_sides(staged, revs)
    if err then
        _notify(err, vim.log.levels.ERROR)
        return
    end
    ---@cast left GitTools.Side
    ---@cast right GitTools.Side

    for _, side in ipairs({ left, right }) do
        if side.rev and not git.verify_rev(root, side.rev) then
            _notify("Unknown revision: " .. side.rev, vim.log.levels.ERROR)
            return
        end
    end

    local changes = _collect_changes(root, left, right, paths, cwd)
    if #changes == 0 then
        _notify(#paths > 0 and "No changes found for the given paths" or "No changes found")
        return
    end

    _open_changes(root, left, right, changes)
end

--- Open a diff session over the submodule an entry of another diff session
--- points at -- what `c` does on a gitlink row of the file list, where the
--- parent's own diff is nothing but a pair of commit ids.
---
--- The submodule is diffed between the commits the two parent sides record, as
--- a repository in its own right. Where the parent's right side is the working
--- tree, so is the submodule's: that way a submodule dirtied by uncommitted
--- edits (and not by a new commit, so the parent records no second id at all)
--- still shows what actually changed.
---
--- Opens in a tab of its own, alongside the session it was launched from, which
--- stays exactly as it was.
---@param data GitTools.EntryData  the list entry's data, from the parent session
function M.diff_submodule(data)
    local rel = data.right_rel or data.left_rel
    if not rel then return end

    -- A submodule that was never initialized (or one just deleted) has no
    -- repository on disk to diff -- `git.root` would climb out of the empty
    -- directory and answer with the *parent* repo, so check what it returns.
    local sub_root = vim.fs.normalize(data.root .. "/" .. rel)
    local root = git.root(sub_root)
    if not root or vim.fs.normalize(root) ~= sub_root then
        _notify(("No checked-out repository at submodule '%s'"):format(rel), vim.log.levels.WARN)
        return
    end

    --- One side of the submodule's own comparison, from the corresponding side
    --- of the parent entry.
    ---@param side GitTools.Side
    ---@param sha  string?
    ---@return GitTools.Side? side  nil when the commit is missing locally
    local function _sub_side(side, sha)
        if side.worktree then return { worktree = true } end
        -- A `path` side that carries no commit is a `git difftool --dir-diff`
        -- gitlink stand-in with the all-zero id in it, which is how git spells
        -- "this side is the live working tree" there -- so that is what it
        -- compares against. Anything else without a commit is a side the
        -- submodule is simply absent from (it was added or removed), leaving
        -- nothing at all to compare with.
        if not sha and side.path then return { worktree = true } end
        if not sha then return { rev = _EMPTY_TREE } end
        if not git.verify_rev(root, sha) then
            _notify(("Submodule '%s' has no commit %s; fetch it first"):format(rel, sha),
                vim.log.levels.ERROR)
            return nil
        end
        return { rev = sha }
    end

    local left = _sub_side(data.left, data.left_sha)
    if not left then return end
    local right = _sub_side(data.right, data.right_sha)
    if not right then return end

    local changes = _collect_changes(root, left, right)
    if #changes == 0 then
        _notify(("No changes in submodule '%s'"):format(rel))
        return
    end

    _open_changes(root, left, right, changes)
end

return M
