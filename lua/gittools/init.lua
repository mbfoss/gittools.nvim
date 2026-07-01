local M        = {}

local usercmd  = require("gittools.util.usercmd")
local git      = require("gittools.git")
local difftool = require("gittools.diff")
local diffthis = require("gittools.diffthis")

--- `:GitTool` -- a git-backed front end for Neovim's native diff facilities.
---   GitTool diff [--staged] [<rev> [<rev>]]   directory diff via the built-in
---                                             difftool (quickfix + layout)
---   GitTool diffthis [<rev>]                  diff the current buffer (incl.
---                                             unsaved edits) in a side split
--- This module owns only command registration and argument parsing; the work
--- lives in `gittools.diff` / `gittools.diffthis`.

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

local _USAGE = "Usage: GitTool diff [--staged] [<rev> [<rev>]]\n"
    .. "       GitTool diffthis [<rev>]"

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
        else
            _notify(_USAGE, vim.log.levels.WARN)
        end
    end, {
        desc          = "Git diff via Neovim's native diff tools",
        subcommand_fn = function(_, rest)
            if #rest == 0 then return { "diff", "diffthis" } end

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
            end
            return {}
        end,
    })
end

return M
