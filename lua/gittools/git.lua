local M = {}

--- Low-level git plumbing shared by the GitTool subcommands: running git,
--- splitting its output, and resolving repo roots / paths / revisions. No UI.

--- Run `git <args>` in `cwd`. Returns trimmed stdout on success, or nil with
--- the (trimmed) stderr on failure.
---@param cwd  string
---@param args string[]
---@return string? stdout
---@return string? stderr
function M.run(cwd, args)
    local cmd = { "git" }
    vim.list_extend(cmd, args)
    local res = vim.system(cmd, { text = true, cwd = cwd }):wait()
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
    local res = vim.system(cmd, { text = true, cwd = cwd, stdin = stdin }):wait()
    if res.code ~= 0 then
        return nil, vim.trim(res.stderr or "")
    end
    return res.stdout or "", nil
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

--- Whether `rev` resolves to a tree-ish (commit, tag, or tree object) in
--- `root`. Tree-ish rather than commit-only so this also accepts the
--- well-known empty-tree SHA used to diff a repository's root commit.
---@param root string
---@param rev  string
---@return boolean
function M.verify_rev(root, rev)
    return M.run(root, { "rev-parse", "--verify", "--quiet", rev .. "^{tree}" }) ~= nil
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
