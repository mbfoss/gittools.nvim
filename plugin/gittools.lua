if vim.fn.has("nvim-0.10") ~= 1 then
    error("gittools.nvim requires Neovim >= 0.10")
end

-- `:GitTool` is registered here at startup without requiring any Lua: each
-- callback pulls in what it needs on first use. The run callback takes its
-- arguments from `opts.fargs`, so it only needs `gittools`, the plugin proper
-- -- some ~4k lines of feature modules. The completion callback additionally
-- needs `util/usercmd`, the command plumbing: it turns the command line into
-- arguments and filters the candidates, and knows nothing about what the
-- subcommands do. Neither is read until the command is first run or completed.
-- Both modules are cached in a local on first use, so the callbacks pay for a
-- `require` lookup once rather than on every invocation.
local usercmd ---@type table?
local gittools ---@type table?

---@return table
local function _usercmd()
    usercmd = usercmd or require("gittools.util.usercmd")
    return usercmd
end

---@return table
local function _gittools()
    gittools = gittools or require("gittools")
    return gittools
end

vim.api.nvim_create_user_command("GitTool", function(opts)
    local ok, err = pcall(_gittools().run, opts.name, opts.fargs, opts)
    if not ok then
        vim.notify(
            "[gittools.nvim] " .. opts.name .. " command error\n" .. tostring(err),
            vim.log.levels.ERROR
        )
    end
end, {
    nargs = "*",
    desc = "Git log, diff etc...",
    complete = function(arg_lead, cmd_line, _)
        return _usercmd().complete(arg_lead, cmd_line,
            function(cmd, rest, lead)
                return _gittools().complete(cmd, rest, lead)
            end)
    end,
})
