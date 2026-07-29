local M = {}
---Show the block in an LSP-style floating preview. Nothing is opened for an
---empty block, so a caller that found nothing to report can just show it.
---@param title string?
---@return integer? bufnr, integer? winid
function M.show(title)
    if self:is_empty() then return end
    return vim.lsp.util.open_floating_preview(self._lines, "plaintext", {
        border   = "rounded",
        title    = title,
        focus_id = self._focus_id,
    })
end

return M
