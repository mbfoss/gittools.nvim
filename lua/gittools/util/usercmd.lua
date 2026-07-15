local M = {}

--- Split a command line into arguments on unescaped whitespace, honouring
--- backslash escapes and shell-style quoting. Quoting matters because git hands
--- paths to a mergetool pre-quoted (`cmd = ... "$LOCAL" "$MERGED"`) so that
--- paths containing spaces survive; without it those quotes would land inside
--- the argument and name a file that doesn't exist.
---@param str string
---@return string[]
local function _split_args(str)
    local args = {}
    local i = 1
    local len = #str
    local part = {}
    local quote = nil
    -- Tracked separately from `#part`, so a deliberately empty argument ("")
    -- still counts as one rather than vanishing.
    local started = false

    local function flush()
        if started then
            table.insert(args, table.concat(part))
            part, started = {}, false
        end
    end

    while i <= len do
        local c = str:sub(i, i)
        if c == '\\' and i < len then
            table.insert(part, str:sub(i + 1, i + 1))
            started = true
            i = i + 2
        elseif quote then
            -- Inside quotes whitespace is literal; only the matching close
            -- quote ends the run.
            if c == quote then quote = nil else table.insert(part, c) end
            i = i + 1
        elseif c == '"' or c == "'" then
            quote = c
            started = true
            i = i + 1
        elseif c:match('%s') then
            flush()
            i = i + 1
        else
            table.insert(part, c)
            started = true
            i = i + 1
        end
    end
    flush()
    return args
end

---@alias gittools.usercmd.subcommand_fn fun(cmd:string,rest:string[],arg_lead:string):string[]

---@alias gittools.usercmd.run_fn
---| fun(cmd:string,args:string[],opts:vim.api.keyset.create_user_command.command_args)

---@param subcommand_fn gittools.usercmd.subcommand_fn
local function _complete(subcommand_fn, arg_lead, cmd_line)
    local function filter(strs)
        local out = {}
        for _, s in ipairs(strs or {}) do
            if not vim.startswith(s, '_') and vim.startswith(s, arg_lead) then
                table.insert(out, s)
            end
        end
        return out
    end

    local args = _split_args(cmd_line)
    if cmd_line:match("%s+$") then
        table.insert(args, ' ')
    end

    local cmd = args[1]
    if #args == 1 then
        return filter(subcommand_fn(cmd, {}, arg_lead))
    elseif #args >= 2 then
        local rest = { unpack(args, 2) }
        rest[#rest] = nil
        return filter(subcommand_fn(cmd, rest, arg_lead))
    end
    return {}
end

---@param cmd string
---@param run_fn gittools.usercmd.run_fn
---@param opts vim.api.keyset.create_user_command.command_args
local function _dispatch(cmd, run_fn, opts)
    local args = _split_args(opts.args)
    local ok, err = pcall(run_fn, cmd, args, opts)
    if not ok then
        vim.notify(
            "[gittools.nvim] " .. cmd .. " command error\n" .. tostring(err),
            vim.log.levels.ERROR
        )
    end
end

---@param cmd string
---@param run_fn gittools.usercmd.run_fn
---@param opts {desc:string?,subcommand_fn:gittools.usercmd.subcommand_fn?}?
function M.register_user_cmd(cmd, run_fn, opts)
    opts = opts or {}
    vim.api.nvim_create_user_command(cmd, function(cmd_opts)
            _dispatch(cmd, run_fn, cmd_opts)
        end,
        {
            nargs = "*",
            complete = opts.subcommand_fn ~= nil and function(arg_lead, cmd_line, _)
                return _complete(opts.subcommand_fn, arg_lead, cmd_line)
            end or function() return {} end,
            desc = opts.desc,
        })
end

return M
