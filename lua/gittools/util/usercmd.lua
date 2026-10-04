local M = {}

---@alias gittools.usercmd.subcommand_fn fun(cmd:string,rest:string[],arg_lead:string):string[]

---@alias gittools.usercmd.run_fn
---| fun(cmd:string,args:string[],opts:vim.api.keyset.create_user_command.command_args)

--- Escape `name` for use as one `<f-args>`-split command argument. Only
--- backslash and whitespace are special there, so escaping anything else (as
--- `fnameescape()` does) would corrupt the argument instead of protecting it.
---@param name string
---@return string
function M.escape_arg(name)
    return (name:gsub("\\", "\\\\"):gsub("[ \t]", { [" "] = "\\ ", ["\t"] = "\\\t" }))
end

--- Filename completion for a command argument. `arg_lead` arrives escaped as
--- typed, but `getcompletion()` returns nothing for a pattern ending in an
--- escaped whitespace ("a\ "), so spell whitespace literally there -- the
--- pattern means the same either way. Matches come back unescaped; escape them
--- so that `M.complete`'s filter and the command line both see valid arguments.
---@param arg_lead string
---@param type string e.g. "file", "dir"
---@return string[]
function M.complete_filename(arg_lead, type)
    local pattern = arg_lead:gsub("\\([ \t])", "%1")
    return vim.tbl_map(M.escape_arg, vim.fn.getcompletion(pattern, type))
end

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
    local cmd, rest = ok and parsed.cmd or "", ok and parsed.args or {}

    -- A non-empty `arg_lead` is the argument currently being completed, so the
    -- last parsed argument is that same word, not context for it. An empty
    -- `arg_lead` means a new argument has begun (or none was typed), leaving
    -- every parsed argument as context.
    if arg_lead ~= "" then
        rest[#rest] = nil
    end

    return filter(subcommand_fn(cmd, rest, arg_lead))
end

return M
