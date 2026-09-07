local M = {}

--- The tab's ordinary (non-floating) windows. Floating windows -- a completion
--- popup, a notification, a picker -- are transient overlays, not part of the
--- layout, so they never make a tab count as occupied.
---@param tabpage integer?  default: the current tab
---@return integer[]
local function _layout_wins(tabpage)
    local wins = {}
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tabpage or 0)) do
        if vim.api.nvim_win_get_config(win).relative == "" then
            wins[#wins + 1] = win
        end
    end
    return wins
end

--- Whether `buf` is the empty, unnamed, unmodified buffer Neovim starts a
--- window with -- i.e. a window showing it holds nothing the user would miss.
---@param buf integer
---@return boolean
function M.buf_is_blank(buf)
    if vim.api.nvim_buf_get_name(buf) ~= "" then return false end
    if vim.bo[buf].modified then return false end
    -- A terminal, a help page, or one of our own scratch views is something to
    -- keep even when it has no file name behind it.
    if vim.bo[buf].buftype ~= "" then return false end
    local lines = vim.api.nvim_buf_get_lines(buf, 0, 2, false)
    return #lines == 0 or (#lines == 1 and lines[1] == "")
end

--- Claim a tab for a view that wants the whole tab to itself (the diff layout,
--- the log). The current tab is reused only when it is a single window holding
--- a blank buffer -- an editor that hasn't been used yet; anything else (the
--- user's splits, a file they're reading) gets left alone and the view opens in
--- a new tab instead.
---@return boolean opened  whether a new tab was created
function M.claim_tab()
    local wins = _layout_wins()
    if #wins == 1 and M.buf_is_blank(vim.api.nvim_win_get_buf(wins[1])) then
        return false
    end
    vim.cmd("tabnew")
    return true
end

--- Close `win`, or -- when it is the last window of the last tab, which Neovim
--- won't close -- leave it on a fresh empty buffer instead, so the view it held
--- goes away either way.
---@param win integer?
function M.close_win(win)
    if not (win and vim.api.nvim_win_is_valid(win)) then return end
    local tab = vim.api.nvim_win_get_tabpage(win)
    if #vim.api.nvim_list_tabpages() == 1 and #_layout_wins(tab) == 1 then
        vim.api.nvim_win_call(win, function() vim.cmd("enew") end)
    else
        pcall(vim.api.nvim_win_close, win, false)
    end
end

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
