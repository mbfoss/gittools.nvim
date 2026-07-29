local M = {}

--- LSP-style hover for text that is worth a look but not worth a window of its
--- own -- the commit details behind a line in the log, the graph or the blame
--- sidebar. Built on `vim.lsp.util.open_floating_preview`, so it behaves like
--- every other hover in the editor: it opens at the cursor without taking
--- focus, closes as soon as the cursor moves, and pressing the same key again
--- while it is up jumps into it (for scrolling, yanking, ...), where `q` or
--- `<Esc>` closes it again.

local _FOCUS_ID = "gittools.hover"

---@class GitTools.HoverOpts
---@field title    string?  shown centred in the border
---@field syntax   string?  syntax for the preview buffer, e.g. "git"
---@field focus_id string?  hovers sharing an id replace/focus each other
---                         (default: one id for all of gittools)

--- Show `text` in a hover at the cursor. A second call from the same buffer
--- while the hover is up focuses it instead of opening another one.
---@param text string
---@param opts GitTools.HoverOpts?
---@return integer? buf
---@return integer? win  nil if there was nothing to show
function M.show(text, opts)
    opts = opts or {}
    local lines = vim.split(text, "\n", { trimempty = false })
    while #lines > 0 and vim.trim(lines[#lines]) == "" do
        lines[#lines] = nil
    end
    if #lines == 0 then return nil end

    local buf, win = vim.lsp.util.open_floating_preview(lines, opts.syntax or "", {
        border     = "rounded",
        title      = opts.title,
        focus_id   = opts.focus_id or _FOCUS_ID,
        wrap       = false,
        max_width  = math.floor(vim.o.columns * 0.8),
        max_height = math.floor(vim.o.lines * 0.8),
    })

    -- `q` comes with the preview; `<Esc>` is the other key a hover is expected
    -- to answer to. Both only matter once the hover has been focused.
    vim.keymap.set("n", "<Esc>", function()
        if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
        end
    end, { buffer = buf, nowait = true, silent = true, desc = "Close hover" })

    return buf, win
end

return M
