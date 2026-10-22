-- Minimal init for the end-to-end smoke test: lazy.nvim loads this checkout and its
-- dependencies xyno-rust.nvim and xyno-imports.nvim through `dir =` and calls setup().
-- XYNO_LAZY is the path of a lazy.nvim clone, XYNO_RUST_DIR / XYNO_IMPORTS_DIR the ones of the
-- dependencies (default: sibling checkouts).
-- Run:  XYNO_LAZY=/path/to/lazy.nvim nvim --headless -u tests/e2e/init.lua -c "luafile tests/e2e/smoke.lua"
local repo = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
local function dep(env, name)
  local dir = vim.env[env]
  if not dir or dir == "" then
    dir = vim.fs.dirname(repo) .. "/" .. name
  end
  return { dir = dir, name = name }
end
vim.o.swapfile = false
vim.opt.rtp:prepend(assert(vim.env.XYNO_LAZY, "XYNO_LAZY not set"))
if vim.env.XYNO_TEST_RTP and vim.env.XYNO_TEST_RTP ~= "" then
  vim.opt.rtp:append(vim.env.XYNO_TEST_RTP) -- e.g. a directory holding parser/rust.so
end
require("lazy").setup({
  {
    dir = repo,
    name = "xyno-macros.nvim",
    lazy = false,
    main = "xyno_macros",
    opts = {},
    dependencies = { dep("XYNO_RUST_DIR", "xyno-rust.nvim"), dep("XYNO_IMPORTS_DIR", "xyno-imports.nvim") },
  },
}, {
  install = { missing = false },
  checker = { enabled = false },
  change_detection = { enabled = false },
  performance = { reset_packpath = false, rtp = { reset = false } },
})
