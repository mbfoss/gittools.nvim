local M        = {}

local usercmd  = require("gittools.util.usercmd")
local git      = require("gittools.git")
local difftool = require("gittools.diff")
local diffthis = require("gittools.diffthis")
local logtool  = require("gittools.log")
local blame    = require("gittools.blame")

--- `:GitTool` -- a git-backed front end for Neovim's native diff facilities.
---   GitTool diff [--staged] [<rev> [<rev>]]   directory diff via the built-in
---                                             difftool (loclist + layout)
---   GitTool diffthis [<rev>]                  diff the current buffer (incl.
---                                             unsaved edits) in a side split
---   GitTool log [<rev>] [-- <path>]           browse commit history as an
---                                             interactive flat list
---   GitTool graph [<rev>] [-- <path>]         like log, but with `git log
---                                             --graph` rail drawing
---   GitTool stashlist                         browse `git stash list` the
---                                             same way as log
---   GitTool blame                             annotate the current buffer in
---                                             a scroll-bound blame sidebar
--- This module owns only command registration and argument parsing; the work
--- lives in `gittools.diff` / `gittools.diffthis` / `gittools.log` /
--- `gittools.blame`.

local _AUGROUP = "gittools"

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
local function _split_sep(args)
    for i, a in ipairs(args) do
        if a == "--" then
            return { unpack(args, 1, i - 1) }, { unpack(args, i + 1) }
        end
    end
    return args, {}
end

local _USAGE = "Usage: GitTool diff [--staged] [<rev> [<rev>]]\n"
    .. "       GitTool diffthis [<rev>]\n"
    .. "       GitTool log [<rev>] [-- <path>]\n"
    .. "       GitTool graph [<rev>] [-- <path>]\n"
    .. "       GitTool stashlist\n"
    .. "       GitTool blame"

--- Register `:GitTool`. Auto-called by the central module loader.
function M.setup()
    local group = vim.api.nvim_create_augroup(_AUGROUP, { clear = true })
    vim.api.nvim_create_autocmd("VimLeavePre", {
        group    = group,
        callback = difftool.clear_session,
    })

    usercmd.register_user_cmd("GitTool", function(_, args)
        local sub = args[1]
        if sub == "diff" then
            local staged, revs = _parse_flags({ unpack(args, 2) })
            difftool.diff({ staged = staged, revs = revs })
        elseif sub == "diffthis" then
            local revs = { unpack(args, 2) }
            if #revs > 1 then
                _notify("GitTool diffthis takes at most one revision", vim.log.levels.ERROR)
                return
            end
            diffthis.diffthis({ rev = revs[1] })
        elseif sub == "log" or sub == "graph" then
            local revs, paths = _split_sep({ unpack(args, 2) })
            if #revs > 1 then
                _notify("GitTool " .. sub .. " takes at most one revision", vim.log.levels.ERROR)
                return
            end
            if #paths > 1 then
                _notify("GitTool " .. sub .. " takes at most one path", vim.log.levels.ERROR)
                return
            end
            local fn = sub == "log" and logtool.log or logtool.graph
            fn({ rev = revs[1], path = paths[1] })
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
        else
            _notify(_USAGE, vim.log.levels.WARN)
        end
    end, {
        desc          = "Git diff via Neovim's native diff tools",
        subcommand_fn = function(_, rest, arg_lead)
            if #rest == 0 then return { "diff", "diffthis", "log", "graph", "stashlist", "blame" } end

            local sub = rest[1]
            if sub == "diff" then
                local out = {}
                local has_flag = false
                for _, a in ipairs(rest) do
                    if a == "--staged" or a == "--cached" then has_flag = true end
                end
                if not has_flag then
                    out[#out + 1] = "--staged"
                    out[#out + 1] = "--cached"
                end
                vim.list_extend(out, git.refs())
                return out
            elseif sub == "diffthis" then
                return git.refs()
            elseif sub == "log" or sub == "graph" then
                local has_sep = false
                for _, a in ipairs(rest) do
                    if a == "--" then has_sep = true end
                end
                if has_sep then
                    return vim.fn.getcompletion(arg_lead, "file")
                end
                local out = { "--" }
                vim.list_extend(out, git.refs())
                return out
            end
            return {}
        end,
    })
end

return M
