local M = {}

---@param listed boolean
---@param buffer_options vim.bo?
---@param on_delete function?
function M.create_scratch_buffer(listed, buffer_options, on_delete)
    local buf = vim.api.nvim_create_buf(listed, true)
    local bo = { ---@type vim.bo
        buftype = "nofile",
        swapfile = false,
        modeline = false,
    }
    if not listed then
        bo.bufhidden = 'wipe'
    end
    if buffer_options then
        for k, v in pairs(buffer_options) do
            bo[k] = v
        end
    end
    for k, v in pairs(bo) do
        vim.bo[buf][k] = v
    end
    if on_delete then
        vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
            buffer = buf,
            once = true,
            callback = function()
                on_delete()
            end,
        })
    end
    return buf
end

return M
