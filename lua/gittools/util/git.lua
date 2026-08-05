local M = {}

--- Low-level git plumbing shared by the GitTool subcommands: running git,
--- splitting its output, and resolving repo roots / paths / revisions. No UI.

--- Environment variables that pin git to one particular repository regardless
--- of the directory it runs in. Every question this module asks is of the form
--- "which repository is this path in, and what does it say", answered by the
--- `cwd` each command is given -- so an inherited scoping variable does not
--- refine that answer, it overrides it with a different repository's.
---
--- Neovim launched as a difftool or mergetool is the case that matters: `git
--- difftool` exports `GIT_DIR` and `GIT_WORK_TREE`, and with those set
--- `git -C <submodule> rev-parse --show-toplevel` reports the *parent* worktree
--- and `rev-parse HEAD` the parent's HEAD, so a submodule looks like it is not a
--- repository at all.
local _SCOPING_VARS = {
    "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_COMMON_DIR", "GIT_NAMESPACE",
    "GIT_PREFIX",
}

--- Options to hand `vim.system` so git discovers its repository from `cwd`
--- alone: the current environment minus `_SCOPING_VARS`. Returns just `text`
--- when none of them is set, which is the ordinary case -- the environment is
--- only rebuilt when there is something in it to drop.
---@return table
local function _sysopts(cwd)
    local dirty = false
    for _, name in ipairs(_SCOPING_VARS) do
        if vim.env[name] then
            dirty = true
            break
        end
    end
    if not dirty then return { text = true, cwd = cwd } end

    local env = vim.fn.environ()
    for _, name in ipairs(_SCOPING_VARS) do env[name] = nil end
    return { text = true, cwd = cwd, env = env, clear_env = true }
end

--- Run `git <args>` in `cwd`. Returns trimmed stdout on success, or nil with
--- the (trimmed) stderr on failure.
---@param cwd  string
---@param args string[]
---@return string? stdout
---@return string? stderr
function M.run(cwd, args)
    local cmd = { "git" }
    vim.list_extend(cmd, args)
    local res = vim.system(cmd, _sysopts(cwd)):wait()
    if res.code ~= 0 then
        return nil, vim.trim(res.stderr or "")
    end
    return vim.trim(res.stdout or ""), nil
end

--- Like `run`, but returns raw (untrimmed) stdout, so file blobs keep their
--- exact bytes (notably a trailing newline). Returns nil plus trimmed stderr
--- on failure. `stdin`, when given, is piped to git (e.g. `blame --contents -`).
---@param cwd   string
---@param args  string[]
---@param stdin string?
---@return string? stdout
---@return string? stderr
function M.run_raw(cwd, args, stdin)
    local cmd = { "git" }
    vim.list_extend(cmd, args)
    local opts = _sysopts(cwd)
    opts.stdin = stdin
    local res = vim.system(cmd, opts):wait()
    if res.code ~= 0 then
        return nil, vim.trim(res.stderr or "")
    end
    return res.stdout or "", nil
end

--- `git diff --no-index --name-status` between two filesystem paths (files or
--- directories) that need not lie inside any repository. Needs its own runner
--- rather than `run`: `git diff --no-index` exits 1 when the paths *differ*
--- (its normal "found a diff" status, not an error) and only >= 2 on a real
--- failure, which `run` would misreport. `core.quotePath=false` keeps non-ASCII
--- paths literal so the caller can strip prefixes from them. Returns the raw
--- name-status lines on stdout.
---@param a string absolute path (left)
---@param b string absolute path (right)
---@return string? stdout
---@return string? stderr
function M.diff_no_index(a, b)
    local res = vim.system({
        "git", "-c", "core.quotePath=false",
        "diff", "--no-index", "--name-status", "--", a, b,
    }, _sysopts(nil)):wait()
    if res.code >= 2 then
        return nil, vim.trim(res.stderr or "")
    end
    return res.stdout or "", nil
end

--- Re-merge `local_path`/`base`/`remote` and return the result in diff3 style,
--- i.e. with `|||||||` base sections, on stdout. Used to recover base text for a
--- conflict when the repo's `merge.conflictStyle` left it out of the file.
---
--- Needs its own runner rather than `run_raw`: `git merge-file` exits with the
--- *number of conflicts* it found (truncated to 127) and only goes negative --
--- which the shell reports as >= 128 -- on a genuine error. A conflicted merge
--- therefore exits non-zero on success, which `run_raw` would report as failure.
---@param cwd        string
---@param local_path string
---@param base       string
---@param remote     string
---@return string? stdout
function M.merge_file_diff3(cwd, local_path, base, remote)
    local res = vim.system({
        "git", "merge-file", "--diff3", "-p", local_path, base, remote,
    }, _sysopts(cwd)):wait()
    if res.code < 0 or res.code >= 128 then return nil end
    return res.stdout or ""
end

--- Split git's newline-delimited path output into a list, dropping blanks.
---@param out string?
---@return string[]
function M.lines(out)
    if not out or out == "" then return {} end
    return vim.split(out, "\n", { trimempty = true })
end

--- Repo root containing `cwd` (default: the editor's cwd), or nil if `cwd` is
--- not inside a git repository.
---@param cwd string?
---@return string?
function M.root(cwd)
    return (M.run(cwd or vim.uv.cwd() or ".", { "rev-parse", "--show-toplevel" }))
end

--- The commit `dir` is checked out at, but only when `dir` is a repository root
--- in its own right. Asking `rev-parse HEAD` there directly would not do: git
--- walks upwards, so a submodule directory that is empty or uninitialized
--- answers with the enclosing repository's HEAD -- a plausible-looking hash
--- belonging to a different repo. Both facts come out of one call.
---@param dir string
---@return string? head
function M.head_at(dir)
    local out = M.run(dir, { "rev-parse", "--show-toplevel", "HEAD" })
    local lines = M.lines(out)
    if #lines < 2 or vim.fs.normalize(lines[1]) ~= vim.fs.normalize(dir) then
        return nil
    end
    return lines[2]
end

--- Whether `rev` resolves to a tree-ish (commit, tag, or tree object) in
--- `root`. Tree-ish rather than commit-only so this also accepts the
--- well-known empty-tree SHA used to diff a repository's root commit.
---@param root string
---@param rev  string
---@return boolean
function M.verify_rev(root, rev)
    return M.run(root, { "rev-parse", "--verify", "--quiet", rev .. "^{tree}" }) ~= nil
end

--- `git show` for `rev` without the patch: the commit header (hash, author and
--- committer with dates, ref decoration), the full message, and a diffstat of
--- what it changed. The patch itself is left out -- it is what `<CR>` opens a
--- real diff for, and a commit touching a few hundred files would bury the
--- message.
---
--- Every part of the header is pinned on the command line so the output does
--- not depend on the user's git config: `format.pretty` (or `log.format`) could
--- otherwise reduce this to a one-liner, `log.abbrevCommit` shorten the hash,
--- `log.date` reformat the dates and `log.showSignature` splice in signature
--- verification. `--pretty=fuller` is the widest built-in header, so the float
--- always shows author *and* committer.
---@param root string
---@param rev  string
---@return string? stdout
---@return string? stderr
function M.show(root, rev)
    return M.run(root, {
        "--no-pager", "show", "--no-color", "--no-patch", "--stat",
        "--pretty=fuller", "--no-abbrev-commit", "--no-show-signature",
        "--decorate=short", "--date=iso", rev,
    })
end

--- Local branch and tag names (plus `HEAD`) offered as revision completions.
--- Best-effort: empty outside a repository.
---@return string[]
function M.refs()
    local root = M.root()
    if not root then return {} end
    local names = { "HEAD" }
    vim.list_extend(names, M.lines(
        (M.run(root, { "for-each-ref", "--format=%(refname:short)", "refs/heads", "refs/tags" }))))
    return names
end

--- `abs` made relative to repo `root`, or nil if it lies outside `root`.
---@param root string
---@param abs  string
---@return string?
function M.relpath(root, abs)
    root = (root:gsub("/+$", ""))
    local prefix = root .. "/"
    if abs:sub(1, #prefix) == prefix then
        return abs:sub(#prefix + 1)
    end
    return nil
end

return M
