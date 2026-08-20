local M        = {}

---@diagnostic disable-next-line: deprecated
local unpack   = table.unpack or unpack

local git      = require("gittools.util.git")
local difftool = require("gittools.diff")
local diffpaths = require("gittools.diffpaths")
local diffthis = require("gittools.diffthis")
local logtool  = require("gittools.log")
local blame    = require("gittools.blame")
local merge    = require("gittools.merge")

--- `:GitTool` -- a git-backed front end for Neovim's native diff facilities.
---   GitTool diff [--staged] [<rev> [<rev>]]   directory diff via the built-in
---                [-- <path>...]                difftool (file list + layout),
---                                             limited to <path> if given
---   GitTool diffpaths <a> <b>                 diff two files or two directories
---                                             off disk (no repository needed)
---   GitTool diffthis [<rev>]                  diff the current buffer (incl.
---                                             unsaved edits) in a side split
---   GitTool log [<opt>...] [<rev>]            browse commit history as an
---               [-- <path>]                   interactive flat list
---   GitTool graph [<opt>...] [<rev>]          like log, but with the commit
---                 [-- <path>]                 tree drawn alongside it
---                                             (<opt> is any `git log` option
---                                             that keeps one line per commit,
---                                             e.g. --all, --no-merges, -n 50)
---   GitTool stashlist                         browse `git stash list` the
---                                             same way as log
---   GitTool blame                             annotate the current buffer in
---                                             a scroll-bound blame sidebar
---   GitTool merge [<file> | $LOCAL $BASE      resolve conflicts inline in
---                 $REMOTE $MERGED]            $MERGED; given one file (or
---                                             none, meaning the current
---                                             buffer) the other three sides
---                                             are read from its index stages
--- This module owns only argument parsing and completion, as `M.run` and
--- `M.complete`; the command itself is registered in `plugin/gittools.lua`,
--- and the work lives in `gittools.diff` / `gittools.diffpaths` /
--- `gittools.diffthis` / `gittools.log` / `gittools.blame` / `gittools.merge`.

---@param msg string
---@param level integer?
local function _notify(msg, level)
    vim.notify("[gittools] " .. msg, level or vim.log.levels.INFO)
end

--- Pull the `--staged`/`--cached` flag (if any) out of `args`, returning the
--- flag state and the remaining positional revisions.
---@param args string[]  arguments after the subcommand
---@return boolean staged
---@return string[] revs
local function _parse_flags(args)
    local staged = false
    local revs = {}
    for _, a in ipairs(args) do
        if a == "--staged" or a == "--cached" then
            staged = true
        else
            revs[#revs + 1] = a
        end
    end
    return staged, revs
end

--- Split `args` at a literal `--` into the positionals before it and after
--- it, mirroring git's own `<rev> -- <path>` convention.
---@param args string[]
---@return string[] before
---@return string[] after
---@return boolean  found  whether a `--` was present at all (an empty `after`
---                        alone cannot tell a trailing `--` from no separator)
local function _split_sep(args)
    for i, a in ipairs(args) do
        if a == "--" then
            return { unpack(args, 1, i - 1) }, { unpack(args, i + 1) }, true
        end
    end
    return args, {}, false
end

--- `git log` options that take their value as a separate argument when it is
--- not `=`-joined (`-n 20`, `--author Ada`), so that the value isn't mistaken
--- for a revision. Short options may also carry the value glued on (`-n20`),
--- which needs no entry here.
local _LOG_VALUE_OPTS = {
    ["-n"] = true, ["--max-count"] = true, ["--skip"] = true,
    ["--since"] = true, ["--after"] = true, ["--until"] = true,
    ["--before"] = true, ["--author"] = true, ["--committer"] = true,
    ["--grep"] = true, ["-S"] = true, ["-G"] = true, ["-L"] = true,
}

--- Options offered as completions for `log`/`graph` -- the `git log` flags
--- worth reaching for in a history browser. Those ending in `=` take a value.
local _LOG_OPTS = {
    "--all", "--branches", "--remotes", "--tags", "--first-parent",
    "--merges", "--no-merges", "--reflog", "--ancestry-path",
    "--author=", "--committer=", "--grep=", "--since=", "--until=",
    "--max-count=", "--skip=", "-n",
}

--- Split `args` into `git log` options and positional revisions, mirroring
--- git's own command line: anything starting with `-` is an option, and the
--- argument after a value-taking option belongs to it.
---@param args string[]
---@return string[] opts
---@return string[] revs
local function _split_opts(args)
    local opts, revs = {}, {}
    local i = 1
    while i <= #args do
        local a = args[i]
        if a:sub(1, 1) == "-" and a ~= "-" then
            opts[#opts + 1] = a
            if _LOG_VALUE_OPTS[a] and args[i + 1] then
                opts[#opts + 1] = args[i + 1]
                i = i + 1
            end
        else
            revs[#revs + 1] = a
        end
        i = i + 1
    end
    return opts, revs
end

--- `:GitTool`'s implementation, as a `gittools.usercmd.run_fn`. Exposed so that
--- `plugin/gittools.lua` can register the command without this module being
--- loaded: it hands `util/usercmd` a wrapper that requires us on the first
--- invocation.
---@type gittools.usercmd.run_fn
function M.run(_, args)
    local sub = args[1]
    if sub == "diff" then
        local before, paths, sep = _split_sep({ unpack(args, 2) })
        local staged, positionals = _parse_flags(before)
        -- Without a `--`, the positionals are still a mix of revisions and
        -- paths; only `gittools.diff` (which knows the repo) can tell them
        -- apart, so hand them over unsplit.
        difftool.diff(sep
            and { staged = staged, revs = positionals, paths = paths }
            or { staged = staged, args = positionals })
    elseif sub == "diffpaths" then
        local paths = { unpack(args, 2) }
        if #paths ~= 2 then
            _notify("GitTool diffpaths takes exactly two paths (two files or two directories)",
                vim.log.levels.ERROR)
            return
        end
        diffpaths.diffpaths(paths[1], paths[2])
    elseif sub == "diffthis" then
        local revs = { unpack(args, 2) }
        if #revs > 1 then
            _notify("GitTool diffthis takes at most one revision", vim.log.levels.ERROR)
            return
        end
        diffthis.diffthis({ rev = revs[1] })
    elseif sub == "log" or sub == "graph" then
        local before, paths, sep = _split_sep({ unpack(args, 2) })
        local log_opts, positionals = _split_opts(before)
        local fn = sub == "log" and logtool.log or logtool.graph
        if not sep then
            -- Without a `--`, the positionals are still a mix of a revision
            -- and a path, as they are on `git log`'s own command line; only
            -- `gittools.log` (which knows the repo) can tell them apart, so
            -- hand them over unsplit.
            fn({ unsplit = positionals, args = log_opts })
            return
        end
        if #positionals > 1 then
            _notify("GitTool " .. sub .. " takes at most one revision", vim.log.levels.ERROR)
            return
        end
        if #paths > 1 then
            _notify("GitTool " .. sub .. " takes at most one path", vim.log.levels.ERROR)
            return
        end
        fn({ rev = positionals[1], path = paths[1], args = log_opts })
    elseif sub == "stashlist" then
        if args[2] then
            _notify("GitTool stashlist takes no arguments", vim.log.levels.ERROR)
            return
        end
        logtool.stash_log()
    elseif sub == "blame" then
        if args[2] then
            _notify("GitTool blame takes no arguments", vim.log.levels.ERROR)
            return
        end
        blame.blame()
    elseif sub == "merge" then
        local paths = { unpack(args, 2) }
        if #paths <= 1 or #paths == 4 then
            merge.merge({ paths = paths })
        else
            _notify("GitTool merge takes no arguments, a single file, or "
                .. "exactly four ($LOCAL $BASE $REMOTE $MERGED)",
                vim.log.levels.ERROR)
        end
    else
        vim.api.nvim_echo({{"Argument required", "Error"}}, false, {})
    end
end

--- `:GitTool`'s completion, as a `gittools.usercmd.subcommand_fn`. Exposed for
--- the same reason as `M.run`.
---@type gittools.usercmd.subcommand_fn
function M.complete(_, rest, arg_lead)
    if #rest == 0 then return { "diff", "diffpaths", "diffthis", "log", "graph", "stashlist", "blame", "merge" } end

    local sub = rest[1]
    if sub == "diffpaths" then
        return vim.fn.getcompletion(arg_lead, "file")
    elseif sub == "diff" then
        local out = {}
        local has_flag, has_sep = false, false
        for _, a in ipairs(rest) do
            if a == "--staged" or a == "--cached" then has_flag = true end
            if a == "--" then has_sep = true end
        end
        if has_sep then
            return vim.fn.getcompletion(arg_lead, "file")
        end
        if not has_flag then
            out[#out + 1] = "--staged"
            out[#out + 1] = "--cached"
        end
        out[#out + 1] = "--"
        vim.list_extend(out, git.refs())
        return out
    elseif sub == "diffthis" then
        return git.refs()
    elseif sub == "merge" then
        return vim.fn.getcompletion(arg_lead, "file")
    elseif sub == "log" or sub == "graph" then
        local has_sep = false
        for _, a in ipairs(rest) do
            if a == "--" then has_sep = true end
        end
        if has_sep then
            return vim.fn.getcompletion(arg_lead, "file")
        end
        local out = { "--" }
        vim.list_extend(out, _LOG_OPTS)
        if sub == "log" then out[#out + 1] = "--reverse" end
        vim.list_extend(out, git.refs())
        -- The path can be given without a `--` (`gittools.log` tells the two
        -- apart), so files belong here alongside the refs rather than only
        -- after a separator.
        vim.list_extend(out, vim.fn.getcompletion(arg_lead, "file"))
        return out
    end
    return {}
end

return M
