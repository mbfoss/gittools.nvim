local M = {}

---@alias gittools.usercmd.subcommand_fn fun(cmd:string,rest:string[],arg_lead:string):string[]

---@alias gittools.usercmd.run_fn
---| fun(cmd:string,args:string[],opts:vim.api.keyset.create_user_command.command_args)

--- Completion for a command registered with `nargs = "*"`, to be called from
--- inside the `complete` callback so that this module -- and whatever
--- `subcommand_fn` closes over -- is only required once completion is first
--- attempted.
---@param arg_lead string
---@param cmd_line string
---@param subcommand_fn gittools.usercmd.subcommand_fn
---@return string[]
function M.complete(arg_lead, cmd_line, subcommand_fn)
    local function filter(strs)
        local out = {}
        for _, s in ipairs(strs or {}) do
            if not vim.startswith(s, '_') and vim.startswith(s, arg_lead) then
                table.insert(out, s)
            end
        end
        return out
    end

    -- Same splitting as the `fargs` the run callback gets, and the only way to
    -- reach it from here: a completion callback is handed the command line, not
    -- the parsed arguments.
    local ok, parsed = pcall(vim.api.nvim_parse_cmd, cmd_line, {})
    local cmd, args = ok and parsed.cmd or "", ok and parsed.args or {}
    if cmd_line:match("%s+$") then
        table.insert(args, ' ')
    end

    -- Drop the half-typed (or, with a trailing space, not yet started) final
    -- word; `rest` is the arguments it follows.
    args[#args] = nil
    return filter(subcommand_fn(cmd, args, arg_lead))
end

return M
