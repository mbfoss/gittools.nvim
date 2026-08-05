if vim.fn.has("nvim-0.10") ~= 1 then
    error("gittools.nvim requires Neovim >= 0.10")
end

-- `:GitTool` is registered here, at startup, from the command plumbing alone:
-- `util/usercmd` splits the arguments and drives completion, and knows nothing
-- about what the subcommands do. The plugin proper -- `gittools` and the ~4k
-- lines of feature modules it pulls in -- is required by the two callbacks
-- below, so none of it is read until the command is first run or completed.
local usercmd = require("gittools.util.usercmd")

usercmd.register_user_cmd("GitTool", function(cmd, args, opts)
    return require("gittools").run(cmd, args, opts)
end, {
    desc          = "Git log, diff etc...",
    subcommand_fn = function(cmd, rest, arg_lead)
        return require("gittools").complete(cmd, rest, arg_lead)
    end,
})
