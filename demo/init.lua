-- Scene-local config. `nvim-demo` has already added its own root to
-- 'runtimepath'; add the plugin and register `:Gittools` explicitly, since
-- `--clean -u` does not source plugin/ from the default runtimepath pass.
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")

vim.o.number = true
vim.o.termguicolors = true
vim.o.swapfile = false
vim.o.shadafile = "NONE"
vim.o.shortmess = vim.o.shortmess .. "I"
vim.o.signcolumn = "yes"
vim.o.cursorline = true
vim.o.updatetime = 100

vim.opt.rtp:append(here .. "/..")
vim.cmd("runtime plugin/gittools.lua")

require("nvim_demo").setup()
