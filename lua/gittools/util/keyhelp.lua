local M = {}

local hover = require("gittools.util.hover")

--- `g?` in the plugin's own views: the keys that work there, in a hover.

--- Map `g?` in `buf` to list `extra` (global keys) then `keys`, the view's own
--- maps, with each map's `desc`. Keys are named rather than read off the
--- buffer, since other plugins map into it too.
---@param buf   integer
---@param keys  string[]              lhs of the view's own maps
---@param extra [string, string][]?  `{lhs, desc}` pairs
function M.map(buf, keys, extra)
    vim.keymap.set("n", "g?", function()
        local rows = {}
        for _, row in ipairs(extra or {}) do rows[#rows + 1] = row end
        for _, lhs in ipairs(vim.list_extend(vim.list_slice(keys), { "g?" })) do
            local map = vim.fn.maparg(lhs, "n", false, true)
            if map.buffer == 1 and map.desc then rows[#rows + 1] = { lhs, map.desc } end
        end

        -- Key names (`<CR>`, `]f`, ...) are ASCII, so their length is their width.
        local width = 0
        for _, row in ipairs(rows) do width = math.max(width, #row[1]) end
        local fmt = "%-" .. width .. "s  %s"
        local lines = {}
        for _, row in ipairs(rows) do lines[#lines + 1] = fmt:format(row[1], row[2]) end

        -- A focus id of its own, so `g?` over an open `K` hover replaces it
        -- rather than jumping into it.
        hover.show(table.concat(lines, "\n"), { title = "Keys", focus_id = "gittools.keys" })
    end, { buffer = buf, nowait = true, desc = "Show these keys" })
end

return M
